// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {AuthModeHook} from "../utils/AuthModeHook.sol";

/// @notice Curator cancellation and the shared close path (`_close`) behind cancel, expiry release, emergency
///         release and revoked-curator cleanup.
/// @dev What these tests pin down:
///        - only the allocation's own curator can cancel, and it can do so in every curator and vault state;
///        - every close path releases exactly maxOut - consumed, once, and moves no assets;
///        - a closed allocation can never be consumed, closed again or reopened, and its nonce stays spent;
///        - the order of a close and a swap in the same block only decides how much is consumed, never whether
///          capacity is counted twice.
contract CuratorCancellationTest is VaultTestBase {
    address internal guardian = makeAddr("guardian");
    address internal curator2 = makeAddr("curator2");
    address internal lpA = makeAddr("lpA");

    /// @dev Pool of a 1:1, fee-free test hook, so consumption amounts are exact.
    PoolKey internal keyE;

    function setUp() public override {
        super.setUp();
        address e = address(uint160(0x0E1 << 140) | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        deployCodeTo("AuthModeHook.sol:AuthModeHook", abi.encode(manager, vault, AuthModeHook.Mode.Operator), e);
        keyE = PoolKey(c0, c1, 3000, 60, IHooks(e));
        manager.initialize(keyE, SQRT_PRICE_1_1);
        vm.startPrank(owner);
        vault.setConsumer(e, true);
        vault.setGuardian(guardian);
        vault.setCurator(curator2, true);
        _openLimits(ISharedCommitmentVault.RiskScope.Hook, e);
        _openLimits(ISharedCommitmentVault.RiskScope.Curator, curator2);
        vault.setCuratorCeiling(curator2, c0, VAULT_FUNDING);
        vault.setCuratorCeiling(curator2, c1, VAULT_FUNDING);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // T-08: cancellation after partial consumption
    // ------------------------------------------------------------------

    function test_CC_cancelAfterPartial_releasesExactRemainder() public {
        uint256 id = _allocate(keyE, c1, 10_000 ether);
        _swap(keyE, true, 3500 ether, id);
        uint256[10] memory before = _snapshot();

        vm.expectEmit(true, true, false, true, address(vault));
        emit ISharedCommitmentVault.AllocationReleased(
            id, curator, 6500 ether, ISharedCommitmentVault.CloseReason.Canceled
        );
        vm.prank(curator);
        vault.cancelAllocation(id);

        ISharedCommitmentVault.Allocation memory a = vault.getAllocation(id);
        assertTrue(a.released);
        assertEq(a.consumed, 3500 ether, "consumed is never refunded");
        assertEq(before[6] - vault.reserved(c1), 6500 ether, "Q fell by exactly maxOut - consumed");
        assertEq(vault.curatorReserved(curator, c1), 0);
        _assertAssetsUnchanged(before);
        _assertEquations();
    }

    function test_CC_cancelThenExchange_reverts() public {
        uint256 id = _allocate(keyA, c1, 10_000 ether);
        _swap(keyA, true, 100 ether, id);
        vm.prank(curator);
        vault.cancelAllocation(id);
        _expectSwapRevert(
            address(hookA), abi.encodeWithSelector(ISharedCommitmentVault.AllocationAlreadyReleased.selector, id)
        );
        _swap(keyA, true, 100 ether, id);
    }

    /// @notice A second close by any path fails, so capacity can be released at most once per allocation.
    function test_CC_doubleCloseFailsOnEveryPath() public {
        uint256 id = _allocate(keyA, c1, 10_000 ether);
        vm.prank(curator);
        vault.cancelAllocation(id);
        bytes memory closed = abi.encodeWithSelector(ISharedCommitmentVault.AllocationAlreadyReleased.selector, id);
        vm.prank(curator);
        vm.expectRevert(closed);
        vault.cancelAllocation(id);
        vm.prank(owner);
        vm.expectRevert(closed);
        vault.release(id);
        vm.warp(block.timestamp + 2 days);
        vm.prank(attacker);
        vm.expectRevert(closed);
        vault.release(id);
        vm.prank(guardian);
        vault.revokeCurator(curator);
        vm.prank(attacker);
        vm.expectRevert(closed);
        vault.release(id);
        vm.prank(curator);
        vm.expectRevert(closed);
        vault.cancelAllocation(id);

        // The other order: released first, cancel second.
        uint256 id2 = _allocateAs(curator2, keyA, c1, 1000 ether);
        vm.prank(guardian);
        vault.release(id2);
        vm.prank(curator2);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.AllocationAlreadyReleased.selector, id2));
        vault.cancelAllocation(id2);
        assertEq(vault.reserved(c1), 0);
        _assertEquations();
    }

    /// @notice A canceled allocation is never reopened: its id stays closed, the same instruction cannot be
    ///         submitted again (its nonce is spent), and a new instruction gets a new id and must pass admission
    ///         and the ceiling again.
    function test_CC_cancelThenResubmitSameInstruction_reverts() public {
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, 10_000 ether);
        vm.prank(curator);
        uint256 id = vault.allocate(req);
        vm.prank(curator);
        vault.cancelAllocation(id);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NonceAlreadyUsed.selector, curator, req.nonce));
        vault.allocate(req);
        uint256 id2 = _allocate(keyA, c1, 10_000 ether);
        assertGt(id2, id, "ids are never reused");
        assertTrue(vault.getAllocation(id).released, "old id stays closed");
    }

    function test_CC_nonCuratorCannotCancel() public {
        uint256 id = _allocate(keyA, c1, 10_000 ether);
        address[6] memory others = [owner, guardian, address(hookA), curator2, attacker, lp0];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NotAllocationCurator.selector, id, others[i]));
            vault.cancelAllocation(id);
        }
        // Even revoking the curator does not let anyone else use the curator's own cancel entry point.
        vm.prank(guardian);
        vault.revokeCurator(curator);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NotAllocationCurator.selector, id, attacker));
        vault.cancelAllocation(id);
        assertFalse(vault.getAllocation(id).released);
    }

    function test_CC_cancelUnknownAllocation_reverts() public {
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.UnknownAllocation.selector, 99));
        vault.cancelAllocation(99);
    }

    /// @notice A curator can always reduce its own exposure: cancellation works while paused, with the direction
    ///         halted, the hook deregistered, after expiry, and while the curator is deregistered, frozen or revoked.
    function test_CC_cancelAvailableInEveryRestrictedState() public {
        uint256[6] memory ids;
        for (uint256 i; i < 6; ++i) {
            ids[i] = _allocate(keyA, c1, 1000 ether);
        }
        vm.startPrank(guardian);
        vault.setPaused(true);
        vault.setSellHalted(c1, true);
        vault.setConsumer(address(hookA), false);
        vm.stopPrank();
        _cancel(curator, ids[0]); // paused, halted, hook deregistered
        vm.prank(guardian);
        vault.setCurator(curator, false);
        _cancel(curator, ids[1]); // deregistered
        vm.prank(guardian);
        vault.freezeCurator(curator);
        _cancel(curator, ids[2]); // frozen
        vm.warp(block.timestamp + 2 days);
        _cancel(curator, ids[3]); // frozen and expired
        vm.prank(guardian);
        vault.revokeCurator(curator);
        _cancel(curator, ids[4]); // revoked
        vm.prank(attacker);
        vault.release(ids[5]); // and anyone may clean up the rest
        assertEq(vault.reserved(c1), 0);
        assertEq(vault.curatorReserved(curator, c1), 0);
        _assertEquations();
    }

    /// @notice Each close path records its own reason; all four apply the same accounting.
    function test_CC_closeReasons() public {
        uint256 expired = _allocate(keyA, c1, 1000 ether);
        vm.warp(block.timestamp + 2 days);
        uint256 emergency = _allocate(keyA, c1, 1000 ether);
        uint256 canceled = _allocate(keyA, c1, 1000 ether);
        uint256 revoked = _allocateAs(curator2, keyA, c1, 1000 ether);

        _expectClose(expired, attacker, ISharedCommitmentVault.CloseReason.Expired);
        vm.prank(attacker);
        vault.release(expired);
        _expectClose(emergency, guardian, ISharedCommitmentVault.CloseReason.Emergency);
        vm.prank(guardian);
        vault.release(emergency);
        _expectClose(canceled, curator, ISharedCommitmentVault.CloseReason.Canceled);
        vm.prank(curator);
        vault.cancelAllocation(canceled);
        vm.prank(guardian);
        vault.revokeCurator(curator2);
        _expectClose(revoked, attacker, ISharedCommitmentVault.CloseReason.CuratorRevoked);
        vm.prank(attacker);
        vault.release(revoked);
        assertEq(vault.reserved(c1), 0);
        _assertEquations();
    }

    /// @notice Closing one allocation leaves every other allocation of the same curator, and of other curators,
    ///         exactly as it was.
    function test_CC_allocationsAreIndependent() public {
        uint256 a1 = _allocate(keyE, c1, 10_000 ether);
        uint256 a2 = _allocate(keyE, c1, 20_000 ether);
        uint256 a3 = _allocate(keyE, c0, 5000 ether);
        uint256 b1 = _allocateAs(curator2, keyE, c1, 7000 ether);
        _swap(keyE, true, 4000 ether, a2);
        vm.prank(curator);
        vault.cancelAllocation(a2);
        assertEq(vault.curatorReserved(curator, c1), 10_000 ether, "a1 still reserved");
        assertEq(vault.curatorReserved(curator, c0), 5000 ether, "a3 still reserved");
        assertEq(vault.curatorReserved(curator2, c1), 7000 ether, "other curator untouched");
        assertEq(vault.reserved(c1), 17_000 ether);
        _swap(keyE, true, 1000 ether, a1);
        _swap(keyE, false, 1000 ether, a3);
        _swap(keyE, true, 1000 ether, b1);
        _assertEquations();
    }

    // ------------------------------------------------------------------
    // T-09: races in the same block, both orders
    // ------------------------------------------------------------------

    /// @notice Cancel vs swap. Cancel first: the swap reverts and the whole remainder is released. Swap first: the
    ///         swap consumes and the cancel releases the smaller remainder. In both orders consumed + released
    ///         equals maxOut.
    function test_CC_race_cancelVsSwap_bothOrders() public {
        uint256 id = _allocate(keyE, c1, 10_000 ether);
        uint256 snap = vm.snapshotState();

        vm.prank(curator);
        vault.cancelAllocation(id);
        _expectSwapRevert(
            address(keyE.hooks), abi.encodeWithSelector(ISharedCommitmentVault.AllocationAlreadyReleased.selector, id)
        );
        _swap(keyE, true, 2000 ether, id);
        assertEq(vault.getAllocation(id).consumed, 0);
        assertEq(vault.reserved(c1), 0);
        _assertEquations();

        vm.revertToState(snap);
        _swap(keyE, true, 2000 ether, id);
        uint256 q = vault.reserved(c1);
        vm.prank(curator);
        vault.cancelAllocation(id);
        assertEq(vault.getAllocation(id).consumed, 2000 ether);
        assertEq(q - vault.reserved(c1), 8000 ether, "released the smaller remainder");
        _assertEquations();
    }

    function test_CC_race_emergencyVsSwap_bothOrders() public {
        uint256 id = _allocate(keyE, c1, 10_000 ether);
        uint256 snap = vm.snapshotState();
        vm.prank(guardian);
        vault.release(id);
        _expectSwapRevert(
            address(keyE.hooks), abi.encodeWithSelector(ISharedCommitmentVault.AllocationAlreadyReleased.selector, id)
        );
        _swap(keyE, true, 2000 ether, id);
        assertEq(vault.reserved(c1), 0);

        vm.revertToState(snap);
        _swap(keyE, true, 2000 ether, id);
        vm.prank(guardian);
        vault.release(id);
        assertEq(vault.getAllocation(id).consumed, 2000 ether);
        assertEq(vault.reserved(c1), 0);
        _assertEquations();
    }

    // ------------------------------------------------------------------
    // LP protection and fuzzing
    // ------------------------------------------------------------------

    /// @notice Closing allocations never touches assets already finalized for queued redemptions (W_a), and the
    ///         freed capacity lets the queue progress.
    function test_CC_closeDoesNotTouchClaimableAssets() public {
        _depositShares(lpA, 100_000 ether);
        vm.prank(owner);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        uint256 lock = _allocate(keyA, c1, uint128(vault.admissibleCapacity(c1)));
        (,,, uint256 req) = _redeem(lpA, 60_000 ether, true);
        vm.prank(guardian);
        vault.release(lock);
        vault.processQueue(1);
        uint256 w1 = vault.claimableAssets(c1);
        assertGt(w1, 0);

        uint256 other = _allocate(keyA, c1, 1000 ether);
        _swap(keyA, true, 100 ether, other);
        vm.prank(curator);
        vault.cancelAllocation(other);
        assertEq(vault.claimableAssets(c1), w1, "W_a unchanged by cancellation");
        vm.prank(lpA);
        vault.claim(req);
        _assertEquations();
        _assertAccountingConsistent();
    }

    /// @notice For any partial consumption and any close path, consumed + released == maxOut, Q returns to its
    ///         prior value, a second close of any kind reverts, and no asset moves during the close.
    function testFuzz_CC_partialConsumptionThenClose(uint256 consume, uint8 path) public {
        uint128 maxOut = 50_000 ether;
        uint256 q0 = vault.reserved(c1);
        uint256 id = _allocate(keyE, c1, maxOut);
        consume = bound(consume, 0, maxOut);
        if (consume != 0) _swap(keyE, true, consume, id);
        uint256[10] memory before = _snapshot();

        path = path % 4;
        if (path == 0) {
            vm.prank(curator);
            vault.cancelAllocation(id);
        } else if (path == 1) {
            vm.prank(guardian);
            vault.release(id);
        } else if (path == 2) {
            vm.warp(vault.getAllocation(id).expiry);
            vm.prank(attacker);
            vault.release(id);
        } else {
            vm.prank(owner);
            vault.revokeCurator(curator);
            vm.prank(attacker);
            vault.release(id);
        }
        ISharedCommitmentVault.Allocation memory a = vault.getAllocation(id);
        assertEq(a.consumed, consume);
        assertEq(before[6] - vault.reserved(c1), maxOut - consume, "released != maxOut - consumed");
        assertEq(vault.reserved(c1), q0);
        _assertAssetsUnchanged(before);

        vm.prank(path == 0 ? curator : owner);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.AllocationAlreadyReleased.selector, id));
        if (path == 0) vault.cancelAllocation(id);
        else vault.release(id);
        _assertEquations();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _allocateAs(address who, PoolKey memory key, Currency out, uint128 maxOut) internal returns (uint256) {
        ISharedCommitmentVault.AllocationRequest memory req = _request(key, out, maxOut);
        vm.prank(who);
        return vault.allocate(req);
    }

    function _cancel(address who, uint256 id) internal {
        vm.prank(who);
        vault.cancelAllocation(id);
        assertTrue(vault.getAllocation(id).released);
    }

    function _expectClose(uint256 id, address by, ISharedCommitmentVault.CloseReason reason) internal {
        ISharedCommitmentVault.Allocation memory a = vault.getAllocation(id);
        vm.expectEmit(true, true, false, true, address(vault));
        emit ISharedCommitmentVault.AllocationReleased(id, by, a.maxOut - a.consumed, reason);
    }

    /// @dev Real balances, B_a, W_a, shares (indices 0-5, 7-9) and Q_1 (index 6, which a close is meant to lower).
    function _snapshot() internal view returns (uint256[10] memory s) {
        s[0] = _claims(address(vault), c0);
        s[1] = _claims(address(vault), c1);
        s[2] = MockERC20(Currency.unwrap(c0)).balanceOf(address(manager));
        s[3] = MockERC20(Currency.unwrap(c1)).balanceOf(address(manager));
        s[4] = vault.backing(c0);
        s[5] = vault.backing(c1);
        s[6] = vault.reserved(c1);
        s[7] = vault.claimableAssets(c0) + vault.claimableAssets(c1);
        s[8] = vault.totalShares();
        s[9] = vault.pendingShares();
    }

    function _assertAssetsUnchanged(uint256[10] memory before) internal view {
        uint256[10] memory afterSnap = _snapshot();
        for (uint256 i; i < 10; ++i) {
            if (i == 6) continue;
            assertEq(afterSnap[i], before[i], "a close moved assets or shares");
        }
    }
}
