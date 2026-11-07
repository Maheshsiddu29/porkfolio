// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {AuthModeHook} from "../utils/AuthModeHook.sol";
import {MaliciousConsumerHook} from "../utils/MaliciousConsumerHook.sol";

/// @notice Phase 1A-H Task B: zero-asset, depleted and dust states, reached through the real PoolManager.
///         A test-only 1:1 hook drains an asset exactly; a registered malicious hook with a curator floor of 0
///         models a legitimate (authorised) but catastrophic economic loss. After every step the accounting
///         equations are re-derived from raw balances (`_assertEquations`): losses must be economic, never
///         accounting errors.
contract ZeroAssetStatesTest is VaultTestBase {
    uint160 internal constant SWAP_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

    address internal lpA = makeAddr("lpA");
    address internal lpSmall = makeAddr("lpSmall");
    PoolKey internal keyE; // 1:1 test hook
    PoolKey internal keyM; // malicious registered hook
    MaliciousConsumerHook internal mal;

    function setUp() public override {
        super.setUp();
        vm.startPrank(owner);
        vault.setCuratorCeiling(curator, c0, type(uint256).max);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        vm.stopPrank();

        address e = address(uint160(0x0E1 << 140) | SWAP_FLAGS);
        deployCodeTo("AuthModeHook.sol:AuthModeHook", abi.encode(manager, vault, AuthModeHook.Mode.Operator), e);
        keyE = PoolKey(c0, c1, 3000, 60, IHooks(e));
        manager.initialize(keyE, SQRT_PRICE_1_1);

        address m = address(uint160(0xBAD << 140) | SWAP_FLAGS);
        deployCodeTo("MaliciousConsumerHook.sol:MaliciousConsumerHook", abi.encode(manager, vault), m);
        mal = MaliciousConsumerHook(m);
        keyM = PoolKey(c0, c1, 3000, 60, IHooks(m));
        manager.initialize(keyM, SQRT_PRICE_1_1);

        vm.startPrank(owner);
        vault.setConsumer(e, true);
        vault.setConsumer(m, true);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Sell every admissible unit of `out` at exactly 1:1 (value-neutral at the hooks' reference price).
    function _drainOneToOne(Currency out) internal {
        uint256 q = vault.admissibleCapacity(out);
        uint256 id = _allocate(keyE, out, uint128(q));
        _swap(keyE, out == c1, q, id);
    }

    /// @dev A curator authorises floor 0; the registered hook takes every admissible unit of `out` for 1 wei.
    function _drainForOneWei(Currency out) internal {
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyM, out, uint128(vault.admissibleCapacity(out)));
        r.minInPerOutX96 = 0;
        vm.prank(curator);
        uint256 id = vault.allocate(r);
        mal.configure(MaliciousConsumerHook.Attack.BelowFloor, id, r.maxOut);
        _swapRaw(keyM, out == c1, -1, "");
    }

    // ------------------------------------------------------------------
    // One asset at zero net backing
    // ------------------------------------------------------------------

    function test_asset1AtZero_definedBehaviour() public {
        _drainOneToOne(c1);
        assertEq(vault.netAssets(c1), 0);
        assertEq(vault.netAssets(c0), 2 * VAULT_FUNDING);
        _assertEquations();

        // Views: no division by zero; token1 imposes no delivery constraint.
        assertEq(vault.freeInventory(c1), 0);
        assertEq(vault.pendingDemand(c1), 0);
        assertEq(vault.admissibleCapacity(c1), 0);
        assertEq(vault.deliverableShares(), vault.totalShares());
        (uint256 p0, uint256 p1) = vault.previewRedeem(1000 ether);
        assertEq(p0, 2000 ether);
        assertEq(p1, 0);

        // No commitment of an asset the vault does not hold.
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyA, c1, 1);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientBacking.selector, 1, 0));
        vault.allocate(r);

        // Deposits pay only token0 and are fully backed; instant redemptions pay only token0.
        (uint256 d0, uint256 d1) = _depositShares(lpA, 1000 ether);
        assertEq(d0, 2000 ether);
        assertEq(d1, 0);
        (uint256 instant, uint256 r0, uint256 r1,) = _redeem(lp0, 100_000 ether, false);
        assertEq(instant, 100_000 ether);
        assertEq(r0, 200_000 ether);
        assertEq(r1, 0);
        _assertEquations();

        // Queue path with a zero asset: queued, finalized and claimed with a zero token1 leg.
        uint256 lock = _allocate(keyA, c0, uint128(vault.admissibleCapacity(c0)));
        uint256 req;
        (instant,,, req) = _redeem(lpA, 1000 ether, true);
        assertEq(instant, 0);
        vm.prank(owner);
        vault.release(lock);
        vault.processQueue(1);
        vm.prank(lpA);
        (uint256 c0Out, uint256 c1Out) = vault.claim(req);
        assertEq(c0Out, 2000 ether);
        assertEq(c1Out, 0);
        _assertEquations();

        // Token1 re-enters through a trade; both legs are live again.
        uint256 id = _allocate(keyE, c0, 10_000 ether);
        _swap(keyE, false, 10_000 ether, id);
        (p0, p1) = vault.previewRedeem(1000 ether);
        assertGt(p0, 0);
        assertGt(p1, 0);
        _assertEquations();
        _assertAccountingConsistent();
    }

    function test_asset0AtZero_mirror() public {
        _drainOneToOne(c0);
        assertEq(vault.netAssets(c0), 0);
        (uint256 d0, uint256 d1) = _depositShares(lpA, 1000 ether);
        assertEq(d0, 0);
        assertEq(d1, 2000 ether);
        (, uint256 r0, uint256 r1,) = _redeem(lpA, 1000 ether, false);
        assertEq(r0, 0);
        assertEq(r1, 2000 ether);
        _assertEquations();
    }

    // ------------------------------------------------------------------
    // Both assets at zero: unreachable; near-total depletion: legitimate loss, correct accounting
    // ------------------------------------------------------------------

    /// @notice Every trade adds at least 1 wei of the input asset, and a redemption can never take all of a
    ///         positive balance (the locked MIN_SHARES keep a pro-rata residual). So N0 + N1 > 0 after
    ///         initialization. Here both assets are drained as far as possible: N = (0, 1 wei).
    function test_bothAssetsZero_unreachable_nearTotalDepletionIsEconomic() public {
        _drainOneToOne(c1); // N = (2M, 0)
        _drainForOneWei(c0); // registered hook, curator floor 0: takes 2M token0 for 1 wei token1
        assertEq(vault.netAssets(c0), 0);
        assertEq(vault.netAssets(c1), 1);
        _assertEquations();

        // Every holder's claim now rounds to zero in both assets: redemption reverts instead of burning shares
        // for nothing. This is an economic loss (authorised trade at floor 0), not an accounting error.
        uint256 s = vault.sharesOf(lp0);
        (uint256 e0, uint256 e1) = vault.previewRedeem(s);
        assertEq(e0 + e1, 0);
        vm.prank(lp0);
        vm.expectRevert(ISharedCommitmentVault.DustRedemption.selector);
        vault.redeem(s, 0, 0, lp0, true);

        // New assets can still enter, priced at the depleted per-share basket and fully backed.
        (uint256 d0, uint256 d1) = vault.previewDeposit(vault.totalShares());
        assertEq(d0, 0);
        assertEq(d1, 1, "S new shares cost 1 wei: the per-share basket is 1/S wei");
        _depositShares(lpA, vault.totalShares());
        // But the share price is so low that the int128 share cap bounds further deposits (terminal in practice).
        uint256 room = vault.MAX_AMOUNT() - vault.totalShares();
        (uint256 m0, uint256 m1) = _fundAndPreviewMax(room);
        assertLt(m0 + m1, 1e18, "max depositable value after depletion is tiny");
        _assertEquations();
    }

    /// @notice A request queued before a drain keeps its FIFO position and its capacity is protected from the
    ///         drain by D, but its VALUE shares the loss pro rata (queued shares carry P&L until finalized).
    function test_pendingRequest_capacityProtected_valueSharesLoss() public {
        _depositShares(lpA, 100_000 ether); // S = 1.1M, N = (1.1M, 1.1M)
        uint256 lock = _allocate(keyA, c1, uint128(vault.admissibleCapacity(c1)));
        (uint256 instant,,, uint256 req) = _redeem(lpA, 100_000 ether, true);
        assertEq(instant, 0);
        uint256 d0 = vault.pendingDemand(c0);
        assertEq(d0, 100_000 ether);

        _drainForOneWei(c0); // takes N0 - D0 = 1M token0 for 1 wei token1
        assertEq(vault.netAssets(c0), d0, "the drain could not touch pending demand");
        _assertEquations();

        vm.prank(owner);
        vault.release(lock);
        uint256 S = vault.totalShares();
        uint256 n0 = vault.netAssets(c0);
        vault.processQueue(1);
        ISharedCommitmentVault.WithdrawalRequest memory w = vault.getRequest(req);
        assertEq(w.sharesPending, 0, "finalized, not trapped");
        assertEq(w.claimable0, 100_000 ether * n0 / S, "pro-rata share of what is left, not 100k");
        vm.prank(lpA);
        vault.claim(req);
        _assertEquations();
    }

    /// @notice A pending request whose entitlement falls to zero in both assets is finalized at zero (status
    ///         Completed): it is neither trapped nor left blocking the queue.
    function test_dustPendingRequest_finalizesAtZero_notTrapped() public {
        _drainOneToOne(c1); // N = (2M, 0), S = 1M
        _depositShares(lpSmall, 1); // 1 share costs 2 wei of token0
        _depositShares(lpA, 1000 ether);
        uint256 lock = _allocate(keyA, c0, uint128(vault.admissibleCapacity(c0)));
        (uint256 instant,,, uint256 req) = _redeem(lpSmall, 1, true);
        assertEq(instant, 0);
        (,,, uint256 reqA) = _redeem(lpA, 1000 ether, true); // queued behind the tiny request
        uint256 d0 = vault.pendingDemand(c0);
        vm.prank(owner);
        vault.release(lock);
        _drainForOneWei(c0); // takes everything except the protected pending demand
        assertEq(vault.netAssets(c0), d0);

        (uint256 e0, uint256 e1) = vault.previewRedeem(1);
        assertEq(e0 + e1, 0, "1 share is now worth < 1 wei in both assets");

        vault.processQueue(5);
        assertEq(uint8(vault.requestStatus(req)), uint8(ISharedCommitmentVault.RequestStatus.Completed));
        assertEq(uint8(vault.requestStatus(reqA)), uint8(ISharedCommitmentVault.RequestStatus.Claimable));
        assertEq(vault.pendingShares(), 0, "the dust request did not block the queue");
        vm.prank(lpSmall);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NothingToClaim.selector, req));
        vault.claim(req);
        vm.prank(lpA);
        vault.claim(reqA);
        _assertEquations();
    }

    /// @notice Guard: a partial slice of the head request whose entitlement rounds to zero in BOTH assets is not
    ///         finalized (that would burn the requester's shares for nothing); the head waits for more inventory.
    ///         State: per-share value < 1 wei in both assets and exactly 1 wei of free token0.
    function test_dustPartialSlice_isNotFinalized() public {
        _drainOneToOne(c1); // N = (2M, 0)
        // A registered hook takes 1.5M token0 for 1 wei token1 (curator floor 0): N = (0.5M, 1 wei), S = 1M.
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyM, c0, 1_500_000 ether);
        r.minInPerOutX96 = 0;
        vm.prank(curator);
        uint256 id = vault.allocate(r);
        mal.configure(MaliciousConsumerHook.Attack.BelowFloor, id, 1_500_000 ether);
        _swapRaw(keyM, false, -1, "");
        // Lock all but 1 wei of token0.
        _allocate(keyA, c0, uint128(vault.admissibleCapacity(c0) - 1));
        assertEq(vault.freeInventory(c0), 1);

        // lp0 exits: a 2-share instant slice takes the free wei, the rest is queued.
        (uint256 instant,,, uint256 req) = _redeem(lp0, vault.sharesOf(lp0), true);
        assertEq(instant, 2);
        assertEq(vault.freeInventory(c0), 0);
        uint256 pendingBefore = vault.getRequest(req).sharesPending;

        // 1 wei of token0 becomes free again (a 1-share deposit). The deliverable slice is 1 share, worth
        // floor(1 * N_a / S) = 0 wei in both assets: it must NOT be finalized.
        _depositShares(lpA, 1);
        assertEq(vault.freeInventory(c0), 1);
        assertEq(vault.deliverableShares(), 1);
        (uint256 e0, uint256 e1) = vault.previewRedeem(1);
        assertEq(e0 + e1, 0);
        assertEq(vault.processQueue(5), 0, "no shares burned for nothing");
        assertEq(vault.getRequest(req).sharesPending, pendingBefore);
        _assertEquations();
    }

    // ------------------------------------------------------------------
    // Empty vault (only the locked MIN_SHARES remain) and uninitialized vault
    // ------------------------------------------------------------------

    function test_emptiedVault_reentry() public {
        _redeem(lp0, vault.sharesOf(lp0), false);
        assertEq(vault.totalShares(), vault.MIN_SHARES());
        assertEq(vault.netAssets(c0), vault.MIN_SHARES());
        (uint256 p0, uint256 p1) = _depositShares(lpA, 500_000 ether);
        assertEq(p0, 500_000 ether);
        assertEq(p1, 500_000 ether);
        (, uint256 r0, uint256 r1,) = _redeem(lpA, 500_000 ether, false);
        assertEq(r0, p0);
        assertEq(r1, p1);
        _assertEquations();
    }

    function test_uninitializedVault_viewsAndCallsNeverDivideByZero() public {
        SharedCommitmentVault v = new SharedCommitmentVault(manager, owner, c0, c1);
        vm.expectRevert(ISharedCommitmentVault.NotInitialized.selector);
        v.previewDeposit(1);
        (uint256 a, uint256 b) = v.previewRedeem(1);
        assertEq(a + b, 0);
        assertEq(v.deliverableShares(), 0);
        assertEq(v.pendingDemand(c0), 0);
        assertEq(v.admissibleCapacity(c0), 0);
        assertEq(v.netAssets(c1), 0);
        assertEq(v.freeInventory(c1), 0);
        assertEq(v.processQueue(10), 0);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientShares.selector, 1, 0));
        v.redeem(1, 0, 0, address(this), true);
    }

    function _fundAndPreviewMax(uint256 room) internal view returns (uint256, uint256) {
        return vault.previewDeposit(room);
    }
}
