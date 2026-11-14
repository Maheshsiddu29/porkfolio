// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {VaultStateReader} from "../../src/libraries/VaultStateReader.sol";

using VaultStateReader for SharedCommitmentVault;

/// @notice VaultLens: same results and reverts as the vault's own execution, and no state or authority of its own.
///         The invariant `invariant_lensPreviewsMatchExecution` repeats the execution comparison on every state the
///         stateful campaign reaches; this file covers the revert cases and a fuzzed multi-step scenario.
contract VaultLensTest is VaultTestBase {
    address internal lpA = makeAddr("lpA");

    function setUp() public override {
        super.setUp();
        vm.startPrank(owner);
        vault.setCuratorCeiling(curator, c0, type(uint256).max);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Same reverts as the vault
    // ------------------------------------------------------------------

    function test_previewDeposit_beforeInitialization_revertsLikeDeposit() public {
        SharedCommitmentVault fresh = new SharedCommitmentVault(manager, owner, c0, c1);
        vm.expectRevert(ISharedCommitmentVault.NotInitialized.selector);
        lens.previewDeposit(fresh, 1 ether);
        vm.expectRevert(ISharedCommitmentVault.NotInitialized.selector);
        fresh.deposit(1 ether, type(uint256).max, type(uint256).max, lpA);

        (uint256 a0, uint256 a1) = lens.previewRedeem(fresh, 1 ether);
        assertEq(a0 + a1, 0, "previewRedeem before initialization");
        assertEq(lens.deliverableShares(fresh), 0, "deliverableShares before initialization");
    }

    /// An unknown id has currencyOut = address(0), which has no sell policy, so the lens reverts the same way
    /// `exchange` would for an unconfigured direction.
    function test_effectiveFloor_unknownAllocation_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(ISharedCommitmentVault.PriceFloorNotConfigured.selector, Currency.wrap(address(0)))
        );
        lens.effectiveFloorX96(vault, 999);
    }

    function test_effectiveFloor_haltedDirection_revertsLikeExchange() public {
        uint256 id = _allocate(keyA, c1, 1000 ether);
        vm.prank(owner);
        vault.setSellHalted(c1, true);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.DirectionHalted.selector, c1));
        lens.effectiveFloorX96(vault, id);
        _expectSwapRevert(address(hookA), abi.encodeWithSelector(ISharedCommitmentVault.DirectionHalted.selector, c1));
        _swap(keyA, true, 1 ether, id);
    }

    /// The effective floor is max(live vault floor, curator floor), read at call time, as in `exchange`.
    function test_effectiveFloor_tracksLiveVaultFloor() public {
        uint256 id = _allocate(keyA, c1, 1000 ether);
        assertEq(lens.effectiveFloorX96(vault, id), PRICE_1_1_X96, "curator floor = vault floor");
        uint160 raised = uint160(FixedPoint96.Q96 * 11 / 10);
        vm.prank(owner);
        vault.setSellFloor(c1, raised);
        assertEq(lens.effectiveFloorX96(vault, id), raised, "raised vault floor applies to the allocation");
    }

    // ------------------------------------------------------------------
    // No state and no authority
    // ------------------------------------------------------------------

    /// Every lens function touches no storage slot of its own and writes no slot of the vault. Together with having
    /// no constructor, owner or token approvals, this is why the vault does not need to trust it.
    function test_lens_readsOnlyAndHasNoStorage() public {
        uint256 id = _allocate(keyA, c1, 1000 ether);
        (,,, uint256 requestId) = _redeem(lp0, 1000 ether, true);
        vm.record();
        lens.netAssets(vault, c0);
        lens.freeInventory(vault, c1);
        lens.pendingDemand(vault, c1);
        lens.deliverableShares(vault);
        lens.previewDeposit(vault, 1 ether);
        lens.previewRedeem(vault, 1 ether);
        lens.effectiveFloorX96(vault, id);
        lens.requestStatus(vault, requestId);
        (bytes32[] memory lensReads, bytes32[] memory lensWrites) = vm.accesses(address(lens));
        (, bytes32[] memory vaultWrites) = vm.accesses(address(vault));
        assertEq(lensReads.length, 0, "lens read its own storage");
        assertEq(lensWrites.length, 0, "lens wrote its own storage");
        assertEq(vaultWrites.length, 0, "a lens call wrote vault storage");
        assertEq(address(lens).balance, 0);
        assertEq(manager.balanceOf(address(lens), c0.toId()) + manager.balanceOf(address(lens), c1.toId()), 0);
    }

    // ------------------------------------------------------------------
    // Fuzzed scenario: previews equal execution
    // ------------------------------------------------------------------

    /// Builds a state with an extra LP, a partly consumed allocation and an optional queued redemption, then checks
    /// each lens value against the vault operation it predicts:
    ///   admissibleCapacity (vault) = max(0, N - Q - R - D) built from lens N and D, and `allocate` accepts exactly
    ///   that amount; `deposit` charges `previewDeposit`; processing the queue head or redeeming instantly delivers
    ///   min(pending or balance, `deliverableShares`) shares worth `previewRedeem`.
    function testFuzz_lensMatchesExecution(
        uint256 extraShares,
        uint256 allocOut,
        uint256 swapIn,
        uint256 queuedShares,
        uint256 buffer
    ) public {
        extraShares = bound(extraShares, 1, 500_000 ether);
        _depositShares(lpA, extraShares);
        allocOut = bound(allocOut, 2 ether, vault.admissibleCapacity(c1));
        uint256 id = _allocate(keyA, c1, uint128(allocOut));
        swapIn = bound(swapIn, 0, allocOut / 2);
        if (swapIn >= 1 ether) _swap(keyA, true, swapIn, id); // tiny inputs quote to zero output and revert
        queuedShares = bound(queuedShares, 0, vault.sharesOf(lp0));
        if (queuedShares != 0 && !_isDust(queuedShares)) _redeem(lp0, queuedShares, true);
        buffer = bound(buffer, 0, 2_000_000 ether);
        vm.prank(owner);
        vault.setBufferFloor(c1, buffer);

        _checkAdmission(c0);
        _checkAdmission(c1);
        _checkDepositPreview();
        if (vault.pendingShares() == 0) _checkInstantRedeem();
        else _checkHeadFinalization();
    }

    function _checkAdmission(Currency c) internal {
        uint256 n = lens.netAssets(vault, c);
        uint256 left = _sub0(_sub0(_sub0(n, vault.reserved(c)), vault.bufferFloor(c)), lens.pendingDemand(vault, c));
        assertEq(vault.admissibleCapacity(c), left, "admissibleCapacity != max(0, N - Q - R - D) from lens N, D");
        if (left == 0 || left > type(uint128).max - 1) return;
        uint256 snap = vm.snapshotState();
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c, uint128(left + 1));
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientBacking.selector, left + 1, left));
        auth.activateDirect(req);
        req = _request(keyA, c, uint128(left));
        vm.prank(curator);
        auth.activateDirect(req);
        vm.revertToState(snap);
    }

    function _checkDepositPreview() internal {
        uint256 snap = vm.snapshotState();
        uint256 shares = vault.totalShares() / 7 + 3;
        (uint256 p0, uint256 p1) = lens.previewDeposit(vault, shares);
        _fundLp(lpA, p0, p1);
        vm.prank(lpA);
        (uint256 a0, uint256 a1) = vault.deposit(shares, p0, p1, lpA);
        assertEq(a0, p0, "deposit asset0 != previewDeposit");
        assertEq(a1, p1, "deposit asset1 != previewDeposit");
        vm.revertToState(snap);
    }

    function _checkInstantRedeem() internal {
        uint256 bal = vault.sharesOf(lpA);
        uint256 inst = bal < lens.deliverableShares(vault) ? bal : lens.deliverableShares(vault);
        (uint256 e0, uint256 e1) = lens.previewRedeem(vault, inst);
        if (inst == 0 || (e0 == 0 && e1 == 0)) return; // dust paths are covered by the invariant and ShareSecurity
        if (inst < bal && _isDust(bal - inst)) return;
        uint256 snap = vm.snapshotState();
        vm.prank(lpA);
        (uint256 got, uint256 a0, uint256 a1,) = vault.redeem(bal, 0, 0, lpA, true);
        assertEq(got, inst, "instant shares != min(balance, deliverableShares)");
        assertEq(a0, e0, "instant asset0 != previewRedeem");
        assertEq(a1, e1, "instant asset1 != previewRedeem");
        vm.revertToState(snap);
    }

    function _checkHeadFinalization() internal {
        // Free the committed capacity so the head can make progress, then compare the finalized slice.
        uint256 snap = vm.snapshotState();
        vm.prank(owner);
        vault.release(1);
        ISharedCommitmentVault.WithdrawalRequest memory r = vault.getRequest(vault.queueHead());
        uint256 d = lens.deliverableShares(vault);
        uint256 s = r.sharesPending < d ? r.sharesPending : d;
        (uint256 e0, uint256 e1) = lens.previewRedeem(vault, s);
        vm.recordLogs();
        uint256 finalized = vault.processQueue(1);
        if (s == 0 || (e0 == 0 && e1 == 0 && s < r.sharesPending)) {
            assertEq(finalized, 0, "finalized although the lens predicts no progress");
        } else {
            assertEq(finalized, s, "finalized shares != min(pending, deliverableShares)");
            Vm.Log[] memory logs = vm.getRecordedLogs();
            (uint256 fs, uint256 f0, uint256 f1) = abi.decode(logs[logs.length - 1].data, (uint256, uint256, uint256));
            assertEq(fs, s);
            assertEq(f0, e0, "finalized asset0 != previewRedeem");
            assertEq(f1, e1, "finalized asset1 != previewRedeem");
        }
        vm.revertToState(snap);
    }

    function _isDust(uint256 shares) internal view returns (bool) {
        (uint256 a0, uint256 a1) = lens.previewRedeem(vault, shares);
        return a0 == 0 && a1 == 0;
    }

    function _sub0(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }
}
