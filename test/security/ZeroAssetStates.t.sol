// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {AuthModeHook} from "../utils/AuthModeHook.sol";
import {MaliciousConsumerHook} from "../utils/MaliciousConsumerHook.sol";
import {VaultStateReader} from "../../src/libraries/VaultStateReader.sol";

using VaultStateReader for SharedCommitmentVault;

/// @notice Zero-asset, depleted and dust states, reached through the real PoolManager.
///         A test-only 1:1 hook drains an asset exactly. A zero vault floor cannot be configured, so near-total
///         depletion is reached by a registered hook trading EXACTLY at the most permissive floor the owner can
///         legally configure: f_v(out) = 2^32 + 1 against f_v(opposite) = 2^160 - 1 (directional consistency
///         forces f_out >= ceil(2^192 / f_opp)), i.e. ~2^-64 raw input per raw output. This models an authorised but
///         catastrophic economic loss that now requires an explicit owner decision. After every step the accounting
///         equations are re-derived from raw balances (`_assertEquations`): losses must be economic, never
///         accounting errors.
contract ZeroAssetStatesTest is VaultTestBase {
    /// @dev Largest representable floor, and the smallest floor directional consistency then allows in the
    ///      opposite direction.
    uint160 internal constant MAX_FLOOR = type(uint160).max;
    uint160 internal constant MIN_CONSISTENT_FLOOR = 2 ** 32 + 1; // ceil(2^192 / (2^160 - 1))

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
        _openLimits(ISharedCommitmentVault.RiskScope.Hook, e);
        _openLimits(ISharedCommitmentVault.RiskScope.Hook, m);
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

    /// @dev The owner deliberately opens the most permissive legal floor for selling `out`: the opposite direction
    ///      is raised to the maximum floor first (otherwise the consistency check rejects the change), then `out`
    ///      is lowered.
    function _ownerOpensExtremeFloor(Currency out) internal {
        vm.startPrank(owner);
        vault.setSellFloor(out == c0 ? c1 : c0, MAX_FLOOR);
        vault.setSellFloor(out, MIN_CONSISTENT_FLOOR);
        vm.stopPrank();
    }

    /// @dev A curator authorises the minimum legal floor; the registered hook takes `amountOut` of `out` paying
    ///      exactly ceil(amountOut * F / 2^96) of the other asset. Returns the input paid.
    function _drainAtFloor(Currency out, uint256 amountOut) internal returns (uint256 pay) {
        _ownerOpensExtremeFloor(out);
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyM, out, uint128(amountOut));
        r.minInPerOutX96 = MIN_CONSISTENT_FLOOR;
        vm.prank(curator);
        uint256 id = auth.activateDirect(r);
        pay = FullMath.mulDivRoundingUp(amountOut, MIN_CONSISTENT_FLOOR, FixedPoint96.Q96);
        mal.configure(MaliciousConsumerHook.Attack.ExactAmounts, id, amountOut);
        _swapRaw(keyM, out == c1, -int256(pay), "");
    }

    /// @dev Sell every admissible unit of `out` at the most permissive legal floor.
    function _drainAdmissibleAtFloor(Currency out) internal returns (uint256) {
        return _drainAtFloor(out, vault.admissibleCapacity(out));
    }

    // ------------------------------------------------------------------
    // One asset at zero net backing
    // ------------------------------------------------------------------

    function test_asset1AtZero_definedBehaviour() public {
        _drainOneToOne(c1);
        assertEq(lens.netAssets(vault, c1), 0);
        assertEq(lens.netAssets(vault, c0), 2 * VAULT_FUNDING);
        _assertEquations();

        // Views: no division by zero; token1 imposes no delivery constraint.
        assertEq(lens.freeInventory(vault, c1), 0);
        assertEq(lens.pendingDemand(vault, c1), 0);
        assertEq(vault.admissibleCapacity(c1), 0);
        assertEq(lens.deliverableShares(vault), vault.totalShares());
        (uint256 p0, uint256 p1) = lens.previewRedeem(vault, 1000 ether);
        assertEq(p0, 2000 ether);
        assertEq(p1, 0);

        // No commitment of an asset the vault does not hold.
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyA, c1, 1);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientBacking.selector, 1, 0));
        auth.activateDirect(r);

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
        (p0, p1) = lens.previewRedeem(vault, 1000 ether);
        assertGt(p0, 0);
        assertGt(p1, 0);
        _assertEquations();
        _assertAccountingConsistent();
    }

    function test_asset0AtZero_mirror() public {
        _drainOneToOne(c0);
        assertEq(lens.netAssets(vault, c0), 0);
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
    ///         initialization. Here both assets are drained as far as the price policy allows. The second drain
    ///         cannot be "everything for 1 wei": even the most permissive legal floor makes the hook pay
    ///         ceil(2M ether * (2^32 + 1) / 2^96) = ~108k wei of token1.
    function test_bothAssetsZero_unreachable_nearTotalDepletionIsEconomic() public {
        _drainOneToOne(c1); // N = (2M, 0)
        uint256 sold = vault.admissibleCapacity(c0);
        uint256 paid = _drainAdmissibleAtFloor(c0); // registered hook at the most permissive legal floor
        assertEq(lens.netAssets(vault, c0), 0);
        assertEq(lens.netAssets(vault, c1), paid);
        assertGe(paid * FixedPoint96.Q96, sold * MIN_CONSISTENT_FLOOR, "paid at least the floor");
        assertGt(paid, 0);
        _assertEquations();

        // A unit of 1e18 shares is now worth < 1 wei in both assets: redeeming it reverts instead of burning shares
        // for nothing. This is an economic loss (authorised trade at an owner-approved floor), not an accounting
        // error.
        (uint256 e0, uint256 e1) = lens.previewRedeem(vault, 1 ether);
        assertEq(e0 + e1, 0);
        vm.prank(lp0);
        vm.expectRevert(ISharedCommitmentVault.DustRedemption.selector);
        vault.redeem(1 ether, 0, 0, lp0, true);

        // New assets can still enter, priced at the depleted per-share basket and fully backed.
        uint256 S = vault.totalShares();
        (uint256 d0, uint256 d1) = lens.previewDeposit(vault, S);
        assertEq(d0, 0);
        assertEq(d1, paid, "S new shares cost exactly the remaining basket");
        _depositShares(lpA, S);
        // The share price is so low that the int128 share cap bounds further deposits (terminal in practice).
        uint256 room = vault.MAX_AMOUNT() - vault.totalShares();
        (uint256 m0, uint256 m1) = _fundAndPreviewMax(room);
        assertEq(m0, 0);
        assertEq(m1, FullMath.mulDivRoundingUp(room, lens.netAssets(vault, c1), vault.totalShares()));
        assertLt(m1, VAULT_FUNDING / 10_000, "max depositable value after depletion < 0.01% of the original pool");
        _assertEquations();
    }

    /// @notice A request queued before a drain keeps its FIFO position and its capacity is protected from the
    ///         drain by D, but its VALUE shares the loss pro rata (queued shares carry P&L until finalized).
    function test_pendingRequest_capacityProtected_valueSharesLoss() public {
        _depositShares(lpA, 100_000 ether); // S = 1.1M, N = (1.1M, 1.1M)
        uint256 lock = _allocate(keyA, c1, uint128(vault.admissibleCapacity(c1)));
        (uint256 instant,,, uint256 req) = _redeem(lpA, 100_000 ether, true);
        assertEq(instant, 0);
        uint256 d0 = lens.pendingDemand(vault, c0);
        assertEq(d0, 100_000 ether);

        _drainAdmissibleAtFloor(c0); // takes N0 - D0 = 1M token0 at the most permissive legal floor
        assertEq(lens.netAssets(vault, c0), d0, "the drain could not touch pending demand");
        _assertEquations();

        vm.prank(owner);
        vault.release(lock);
        uint256 S = vault.totalShares();
        uint256 n0 = lens.netAssets(vault, c0);
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
        uint256 d0 = lens.pendingDemand(vault, c0);
        vm.prank(owner);
        vault.release(lock);
        _drainAdmissibleAtFloor(c0); // takes everything except the protected pending demand
        assertEq(lens.netAssets(vault, c0), d0);

        (uint256 e0, uint256 e1) = lens.previewRedeem(vault, 1);
        assertEq(e0 + e1, 0, "1 share is now worth < 1 wei in both assets");

        vault.processQueue(5);
        assertEq(uint8(lens.requestStatus(vault, req)), uint8(ISharedCommitmentVault.RequestStatus.Completed));
        assertEq(uint8(lens.requestStatus(vault, reqA)), uint8(ISharedCommitmentVault.RequestStatus.Claimable));
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
        // A registered hook takes 1.5M token0 at the most permissive legal floor: N = (0.5M, ~81k wei), S = 1M.
        _drainAtFloor(c0, 1_500_000 ether);
        // Lock all but 1 wei of token0.
        _allocate(keyA, c0, uint128(vault.admissibleCapacity(c0) - 1));
        assertEq(lens.freeInventory(vault, c0), 1);

        // lp0 exits: a 2-share instant slice takes the free wei, the rest is queued.
        (uint256 instant,,, uint256 req) = _redeem(lp0, vault.sharesOf(lp0), true);
        assertEq(instant, 2);
        assertEq(lens.freeInventory(vault, c0), 0);
        uint256 pendingBefore = vault.getRequest(req).sharesPending;

        // 1 wei of token0 becomes free again (a 1-share deposit). The deliverable slice is 1 share, worth
        // floor(1 * N_a / S) = 0 wei in both assets: it must NOT be finalized.
        _depositShares(lpA, 1);
        assertEq(lens.freeInventory(vault, c0), 1);
        assertEq(lens.deliverableShares(vault), 1);
        (uint256 e0, uint256 e1) = lens.previewRedeem(vault, 1);
        assertEq(e0 + e1, 0);
        assertEq(vault.processQueue(5), 0, "no shares burned for nothing");
        assertEq(vault.getRequest(req).sharesPending, pendingBefore);
        _assertEquations();
    }

    // ------------------------------------------------------------------
    // Empty vault (only the locked MIN_SHARES remain) and uninitialized vault
    // ------------------------------------------------------------------

    /// @notice After every redeemable share has left, only the locked MIN_SHARES and their 1,000 wei of each asset
    ///         remain. A new depositor is priced from that residual basket and can exit with exactly what it paid,
    ///         so an emptied vault is reusable rather than stuck.
    function test_emptiedVault_reentry() public {
        _redeem(lp0, vault.sharesOf(lp0), false);
        assertEq(vault.totalShares(), vault.MIN_SHARES());
        assertEq(lens.netAssets(vault, c0), vault.MIN_SHARES());
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
        lens.previewDeposit(v, 1);
        (uint256 a, uint256 b) = lens.previewRedeem(v, 1);
        assertEq(a + b, 0);
        assertEq(lens.deliverableShares(v), 0);
        assertEq(lens.pendingDemand(v, c0), 0);
        assertEq(v.admissibleCapacity(c0), 0);
        assertEq(lens.netAssets(v, c1), 0);
        assertEq(lens.freeInventory(v, c1), 0);
        assertEq(v.processQueue(10), 0);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientShares.selector, 1, 0));
        v.redeem(1, 0, 0, address(this), true);
    }

    function _fundAndPreviewMax(uint256 room) internal view returns (uint256, uint256) {
        return lens.previewDeposit(vault, room);
    }
}
