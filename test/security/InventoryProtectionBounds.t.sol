// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {MaliciousConsumerHook} from "../utils/MaliciousConsumerHook.sol";
import {MockRiskAdapter} from "../utils/MockRiskAdapter.sol";

/// @notice The four loss quantities of INVENTORY_PROTECTION.md are different, and the floor bounds only the first two.
///         Each test drives the real vault (production builds, real PoolManager) to a state where one quantity is
///         large while the floor's guarantees still hold, so none of them can be read as implying another.
///         Setup: two 18-decimal assets at 1:1, N0 = N1 = 1e24, S = 1e24, so tau = 1e18 (one raw unit per share,
///         WAD-scaled) and kappa = 5%: the floor per share is l = 0.95 raw units of each asset.
contract InventoryProtectionBoundsTest is VaultTestBase {
    uint256 internal constant Q96 = FixedPoint96.Q96;
    uint160 internal constant SWAP_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

    MockRiskAdapter internal adapter;
    MaliciousConsumerHook internal mal;
    PoolKey internal keyM;
    address internal guardian = makeAddr("guardian");
    uint256 internal tau;

    function setUp() public override {
        super.setUp();
        address m = address(uint160(0xBAD3 << 140) | SWAP_FLAGS);
        deployCodeTo("MaliciousConsumerHook.sol:MaliciousConsumerHook", abi.encode(manager, vault), m);
        mal = MaliciousConsumerHook(m);
        keyM = PoolKey(c0, c1, 3000, 60, IHooks(m));
        manager.initialize(keyM, SQRT_PRICE_1_1);
        adapter = new MockRiskAdapter(address(token0), address(token1), 18, 18, keccak256("bounds"));
        adapter.set(Q96, 0, type(uint256).max);
        tau = FullMath.mulDiv(vault.backing(c0), 1e18, vault.totalShares());
        assertEq(tau, 1e18);
        vm.startPrank(owner);
        vault.setConsumer(m, true);
        _openLimits(ISharedCommitmentVault.RiskScope.Hook, m);
        vault.setGuardian(guardian);
        vault.setCuratorCeiling(curator, c0, type(uint256).max);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        vault.setRiskBounds(0, 5000);
        vault.setInventoryBounds(tau, tau, 50_000, 50_000);
        vault.setRiskAdapter(adapter);
        vault.setSellFloor(c0, 0);
        vault.setSellFloor(c1, 0);
        vm.stopPrank();
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
    }

    // ------------------------------------------------------------------ helpers

    function _net(Currency c) internal view returns (uint256) {
        return vault.backing(c) - vault.claimableAssets(c);
    }

    /// @dev The vault sells `out` of one asset to the malicious consumer, which pays exactly the vault's floor at the
    ///      adapter price `priceX96` (asset1 per asset0, Q96, zero uncertainty, zero edge). Returns the input paid.
    function _fillAt(bool sellAsset1, uint256 out, uint256 priceX96) internal returns (uint256 amountIn) {
        adapter.set(priceX96, 0, type(uint256).max);
        uint256 id = _allocateAnyFloor(keyM, sellAsset1 ? c1 : c0, uint128(out));
        amountIn = FullMath.mulDivRoundingUp(out, lens.effectiveFloorX96(vault, id), Q96);
        _payFor(sellAsset1, out, amountIn, id);
    }

    /// @dev Same, but the trader pays `amountIn` of its own choosing (at least the floor).
    function _payFor(bool sellAsset1, uint256 out, uint256 amountIn, uint256 id) internal {
        token0.mint(address(this), amountIn);
        token1.mint(address(this), amountIn);
        mal.configure(MaliciousConsumerHook.Attack.ExactAmounts, id, out);
        swapRouter.swap(
            keyM,
            SwapParams({
                zeroForOne: sellAsset1,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: sellAsset1 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev An allocation for the malicious consumer with the smallest curator floor, so only the vault's own floors
    ///      (here: the adapter band and the inventory floor) bind.
    function _allocateAnyFloor(PoolKey memory key, Currency out, uint128 maxOut) internal returns (uint256 id) {
        ISharedCommitmentVault.AllocationRequest memory req = _request(key, out, maxOut);
        req.minInPerOutX96 = 1;
        vm.prank(curator);
        id = auth.activateDirect(req);
    }

    /// @dev Drain asset0 or asset1 to exactly its inventory floor at the "worthless" price for that asset.
    function _drainToFloor(bool asset1) internal returns (uint256 out) {
        out = lens.inventoryRoom(vault, asset1 ? c1 : c0);
        if (out != 0) _fillAt(asset1, out, asset1 ? 2 ** 160 : 1);
    }

    /// @dev Per-share holding of asset `i`, WAD.
    function _h(uint256 i) internal view returns (uint256) {
        return FullMath.mulDiv(_net(i == 0 ? c0 : c1), 1e18, vault.totalShares());
    }

    // ------------------------------------------------------------------ Q1 does not bound the fraction of value

    /// @notice Correction C4, reproduced on the vault. Gains lift holdings above target, so the room above the floor
    ///         exceeds kappa of the value. A corrupted oracle then takes 8.6% of the value at kappa = 5%. Throughout:
    ///         - Q1 holds (no holding goes below l);
    ///         - Q2 holds for an LP who entered before the gain (shortfall = its room 0.10/share);
    ///         - Q2 holds for an LP who entered after it (shortfall = its room 0.18/share, i.e. 8.6% of its entry
    ///           value).
    function test_Q1_holds_butLossFractionExceedsKappa_whenGainsLiftHoldings() public {
        address early = lp0; // entered at h = (1, 1)
        // An overpaying trade: the vault sells 40,000 asset1 for 120,000 asset0 (3x the fair amount).
        uint256 id = _allocateAnyFloor(keyM, c1, 40_000 ether);
        _payFor(true, 40_000 ether, 120_000 ether, id);
        assertEq(_h(0), 1.12e18);
        assertEq(_h(1), 0.96e18);
        address late = makeAddr("late");
        uint256 lateShares = 1e23;
        _depositShares(late, lateShares); // enters at h = (1.12, 0.96): room 0.17 + 0.01 per share

        uint256 valueBefore = _net(c0) + _net(c1); // at the true price 1:1
        uint256 out0 = _drainToFloor(false);
        uint256 out1 = _drainToFloor(true);
        uint256 lossFraction = FullMath.mulDiv(out0 + out1, 1e6, valueBefore); // pips; payments were ~0
        assertGt(lossFraction, 50_000, "more than kappa of value");
        assertApproxEqAbs(lossFraction, 86_538, 1, "0.18 / 2.08");
        assertGe(_h(0), 0.95e18, "Q1 asset0");
        assertGe(_h(1), 0.95e18, "Q1 asset1");

        // Q2: each LP's shortfall against its own entry basket equals its room, never more (plus one raw unit).
        (, uint256 e0, uint256 e1,) = _redeem(early, 1e22, false);
        assertGe(e0 + 1, FullMath.mulDiv(1e22, 0.95e18, 1e18));
        assertGe(e1 + 1, FullMath.mulDiv(1e22, 0.95e18, 1e18));
        (, uint256 l0, uint256 l1,) = _redeem(late, lateShares, false);
        uint256 lateEntryValue = FullMath.mulDiv(lateShares, 1.12e18 + 0.96e18, 1e18);
        uint256 lateShortfall = lateEntryValue - (l0 + l1);
        assertLe(lateShortfall, FullMath.mulDiv(lateShares, 0.18e18, 1e18) + 2, "within the late LP's room");
        assertGt(lateShortfall * 1e6, 50_000 * lateEntryValue, "late LP lost more than kappa of its entry value");
    }

    /// @notice The remedy for C4: after a gain lifts asset0 to 1.12 per share, the guardian raises tau_0 to the
    ///         holding (immediate, tightening only), and the room is kappa of the holding again (0.056 per share, not
    ///         0.17). Lowering a target below the holding is a loosening and the guardian cannot do it.
    function test_recentring_restoresKappaOfHolding() public {
        uint256 id = _allocateAnyFloor(keyM, c1, 40_000 ether);
        _payFor(true, 40_000 ether, 120_000 ether, id);
        assertApproxEqRel(lens.inventoryRoom(vault, c0), 0.17e24, 1e12);
        uint256 h0 = _h(0);
        vm.prank(guardian);
        vault.setInventoryBounds(h0, tau, 50_000, 50_000);
        assertApproxEqRel(lens.inventoryRoom(vault, c0), _net(c0) / 20, 1e12, "room = kappa of the holding");
        vm.prank(guardian);
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setInventoryBounds(h0, tau - 1, 50_000, 50_000);
    }

    // ------------------------------------------------------------------ Q3: cumulative realized loss

    /// @notice Cumulative realized loss is a flow, not a state, and it is not bounded by kappa of the starting value.
    ///         Sequence:
    ///         1. drain asset0;
    ///         2. new LPs double the share supply (they buy in at the drained basket);
    ///         3. honest flow refills asset0 from asset1's room;
    ///         4. drain asset0 again.
    ///         Realized loss 0.15e24 > kappa * V0 = 0.10e24. The seed LP's shortfall is still exactly its room (Q2),
    ///         and no holding goes below the floor (Q1).
    function test_Q3_cumulativeRealizedLoss_exceedsKappaOfStartingValue() public {
        uint256 v0 = _net(c0) + _net(c1); // 2e24
        uint256 loss = _drainToFloor(false); // ~0.05e24 of asset0 for 1 raw unit of asset1
        address newcomer = makeAddr("newcomer");
        _depositShares(newcomer, vault.totalShares());
        // Honest refill at the true price: the vault sells asset1 down to its floor and receives asset0 at 1:1 + floor.
        uint256 refill = lens.inventoryRoom(vault, c1);
        _fillAt(true, refill, Q96);
        loss += _drainToFloor(false);
        assertGt(loss, v0 / 20, "realized loss exceeds kappa of the starting value");
        assertApproxEqRel(loss, 0.15e24, 1e15);
        assertGe(_h(0), 0.95e18 - 1);
        assertGe(_h(1), 0.95e18 - 1);
        (, uint256 a0, uint256 a1,) = _redeem(lp0, 1e23, false); // seed LP, entry basket (1, 1) per share
        assertGe(a0 + a1 + 2, FullMath.mulDiv(1e23, 1.9e18, 1e18), "seed LP: shortfall <= 0.10 per share");
    }

    // ------------------------------------------------------------------ Q4: mark-to-market

    /// @notice A depeg is a mark-to-market loss the floor does not bound, and does not try to. asset1 keeps 1% of its
    ///         value; honest arbitrage at the true price sells asset1 to the vault until asset0 reaches its floor.
    ///         - Q1 holds.
    ///         - Q2 at the post-depeg price is about zero: the vault traded fairly.
    ///         - Q4, the seed LP's basket against its value before the depeg, loses about 49.5%, far beyond kappa.
    function test_Q4_depeg_markToMarketBeyondKappa_whileQ1Q2Hold() public {
        uint256 p = 100 * Q96; // 1 asset0 = 100 asset1 after the depeg
        uint256 room0 = lens.inventoryRoom(vault, c0);
        _fillAt(false, room0, p); // arbitrageur pays ~100 asset1 per asset0
        assertEq(_net(c0), 0.95e24, "asset0 at its floor");
        assertGe(_h(0), 0.95e18);

        (, uint256 a0, uint256 a1,) = _redeem(lp0, 1e23, false);
        // Values in asset0 units at the post-depeg price: entry basket 1 + 1/100 per share; payout ~0.95 + 6/100.
        uint256 payout = a0 + a1 / 100;
        uint256 entryAtNewPrice = FullMath.mulDiv(1e23, 1.01e18, 1e18);
        assertGe(payout + 2, entryAtNewPrice, "Q2 at the post-depeg price: no shortfall");
        uint256 entryBeforeDepeg = 2e23; // 1 + 1 per share, asset0 units, at 1:1
        assertGt(entryBeforeDepeg - payout, entryBeforeDepeg / 20, "Q4: mark-to-market loss beyond kappa");
        assertApproxEqRel(payout, 1.01e23, 1e15);
    }

    // ------------------------------------------------------------------ rounding: the smallest counterexample

    /// @notice The exact (unrounded) T2 statement "payout >= s * min(h, l)" is false by less than one raw unit. With
    ///         asset0 drained to exactly L = 0.95 S, redeeming 3 shares pays floor(3 * 0.95) = 2 raw units against the
    ///         exact 2.85. This is the "one raw unit per asset per payout" allowance; it cannot accumulate across
    ///         payouts because each redemption rounds against the redeemer and so never lowers N/S for anyone else.
    function test_rounding_exactT2FailsBySubUnit() public {
        _drainToFloor(false);
        assertEq(_net(c0), 0.95e24);
        uint256 hBefore = _h(0);
        (, uint256 a0,,) = _redeem(lp0, 3, false);
        assertEq(a0, 2, "floor(2.85)");
        assertLt(a0 * 100, 3 * 95, "below the exact bound 2.85");
        assertGe(a0 + 1, 3, "within one raw unit");
        assertGe(_h(0), hBefore, "remaining holders not diluted");
    }
}
