// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

import {InventoryPricing} from "../../src/pricing/InventoryPricing.sol";
import {StrategyPricing} from "../../src/pricing/StrategyPricing.sol";
import {ReferenceBracket} from "../../src/oracle/ReferenceBracket.sol";
import {PricingHarness} from "./PricingHarness.sol";

/// @notice Properties of the Solidity pricing core and strategies, fuzzed on the Solidity alone (independent of the
///         Python model). Each test names the property of docs/architecture/SHARED_ECONOMIC_CORE_SPEC.md it checks.
/// @dev The fuzz domain keeps `amountIn * priceX96 * 1e6` below 2^256 (amounts below 2^100, prices below 2^128) so
///      that the straddle inequality can be checked exactly in 256 bits; the libraries themselves accept the full
///      documented domain (vectors cover it).
contract SharedCorePropertiesTest is Test {
    uint256 internal constant PIPS = 1_000_000;
    uint256 internal constant WAD = 1e18;
    PricingHarness internal h;

    struct State {
        InventoryPricing.Config c;
        uint256 n1;
        uint256 shares;
        uint256 price;
        uint256 unc;
    }

    function setUp() public {
        h = new PricingHarness();
    }

    /// @dev A bounded random reserve: shares 1e21..1e30, deviation within +-40% of target, a depth per share between
    ///      10 and 1,000 (any depth is valid; the cap adapts), base spread 3..50 bps, edge 0..1 bp, uncertainty
    ///      0..60 bps, price 2^80..2^127.
    function _state(uint256 seed) internal pure returns (State memory s) {
        uint256 r = uint256(keccak256(abi.encode(seed)));
        s.shares = 1e21 + r % 1e30;
        s.c.targetPerShare = WAD;
        s.c.depthPerShare = (10 + (r >> 40) % 990) * WAD;
        s.c.depthMax = 2 ** 95 - 1;
        s.c.baseSpread = 300 + (r >> 60) % 4700;
        s.c.minEdge = (r >> 80) % 101;
        s.c.maxSpread = 60_000;
        s.c.maxDeviation = 50_000 + (r >> 90) % 250_000;
        uint256 dev = (r >> 110) % 800_001; // 0..80% of target, centred at 40%
        s.n1 = s.shares * (600_000 + dev) / PIPS;
        s.price = 2 ** 80 + (r >> 130) % (2 ** 127 - 2 ** 80);
        s.unc = (r >> 200) % 6001;
        s.c.bandEdge = (r >> 220) % 4 != 0;
    }

    /// @dev The edge every quote must keep from the mid: minEdge, plus the reference uncertainty in band mode.
    function _edge(State memory s) internal pure returns (uint256) {
        return s.c.minEdge + (s.c.bandEdge ? s.unc : 0);
    }

    function _fee(uint256 seed) internal pure returns (StrategyPricing.ActivityFee memory f) {
        uint256 r = uint256(keccak256(abi.encode(seed, "fee")));
        f.baseFeePips = r % 1000;
        f.maxFeePips = f.baseFeePips + (r >> 20) % 20_000;
        f.scale0 = 1e18 + (r >> 40) % 1e24;
        f.scale1 = 1e18 + (r >> 120) % 1e24;
    }

    function _quote(State memory s, bool useA, StrategyPricing.ActivityFee memory f, bool zfo, uint256 amt)
        internal
        view
        returns (bool ok, StrategyPricing.Quote memory q, uint256 cap)
    {
        bytes memory call = useA
            ? abi.encodeCall(h.hookA, (s.c, s.n1, s.shares, s.price, s.unc, f, 0, zfo, amt))
            : abi.encodeCall(h.hookB, (s.c, s.n1, s.shares, s.price, s.unc, 0, 999_999, zfo, amt));
        bytes memory ret;
        (ok, ret) = address(h).staticcall(call);
        if (ok) (q, cap) = abi.decode(ret, (StrategyPricing.Quote, uint256));
    }

    /// @notice P-3 straddle: every accepted quote of either strategy is on the vault's side of the reference by at
    ///         least minEdge, exactly. This single inequality is what makes cross-hook cycles lose and floors pivoted
    ///         at the reference accept every quote.
    function testFuzz_straddle_bothStrategies(uint256 seed, uint256 amt, bool zfo, bool useA) public view {
        State memory s = _state(seed);
        amt = bound(amt, 1, 2 ** 100);
        (bool ok, StrategyPricing.Quote memory q,) = _quote(s, useA, _fee(seed), zfo, amt);
        vm.assume(ok);
        if (zfo) {
            // amt * P * 1e6 >= out * 2^96 * (1e6 + minEdge)
            assertGe(amt * s.price * PIPS, q.amountOut * FixedPoint96.Q96 * (PIPS + _edge(s)));
        } else {
            // out * P * 1e6 <= amt * 2^96 * (1e6 - minEdge)
            assertLe(q.amountOut * s.price * PIPS, amt * FixedPoint96.Q96 * (PIPS - _edge(s)));
        }
    }

    /// @notice D14 floors pivoted at the reference (`F_sell0 = P`, `F_sell1 = ceil(2^192 / P)`) accept every accepted
    ///         quote, checked with the vault's own rounding (`amountIn >= ceil(amountOut * floor / 2^96)`), when
    ///         minEdge >= 1 pip.
    function testFuzz_quotesPassFloorsPivotedAtReference(uint256 seed, uint256 amt, bool zfo, bool useA) public view {
        State memory s = _state(seed);
        if (s.c.minEdge == 0) s.c.minEdge = 1;
        amt = bound(amt, 1, 2 ** 100);
        (bool ok, StrategyPricing.Quote memory q,) = _quote(s, useA, _fee(seed), zfo, amt);
        vm.assume(ok);
        uint256 floorX96 = zfo ? FullMath.mulDivRoundingUp(FixedPoint96.Q96, FixedPoint96.Q96, s.price) : s.price;
        assertGe(amt, FullMath.mulDivRoundingUp(q.amountOut, floorX96, FixedPoint96.Q96));
    }

    /// @notice Band mode against the proposed vault-side dynamic floor: the vault refuses any price inside the reference
    ///         band (`F_sell0 = ceil(P (1e6 + u) / 1e6)`, `F_sell1 = ceil(ceil(2^192 / P) (1e6 + u) / 1e6)`), and every
    ///         accepted band-mode quote passes it with the vault's own rounding. The hook keeps `minEdge >= 1` pip
    ///         beyond the band; that margin absorbs the floors' ceilings (up to about `2 * out / 2^96 + 1` raw units).
    ///         With the vault's edge equal to the hook's, the margin is zero and rounding alone can refuse a quote (a
    ///         case 2 wei short was found), so the vault's edge must stay strictly inside the hook's.
    function testFuzz_bandModePassesDynamicFloor(uint256 seed, uint256 amt, bool zfo, bool useA) public view {
        State memory s = _state(seed);
        s.c.bandEdge = true;
        if (s.c.minEdge == 0) s.c.minEdge = 1;
        amt = bound(amt, 1, 2 ** 100);
        (bool ok, StrategyPricing.Quote memory q,) = _quote(s, useA, _fee(seed), zfo, amt);
        vm.assume(ok);
        uint256 widen = PIPS + s.unc;
        uint256 floorX96 = zfo
            ? FullMath.mulDivRoundingUp(
                FullMath.mulDivRoundingUp(FixedPoint96.Q96, FixedPoint96.Q96, s.price), widen, PIPS
            )
            : FullMath.mulDivRoundingUp(s.price, widen, PIPS);
        assertGe(amt, FullMath.mulDivRoundingUp(q.amountOut, floorX96, FixedPoint96.Q96));
    }

    /// @notice P-9 shared cap: no strategy moves the inventory further out than max(cap, |I| before).
    function testFuzz_sharedCap(uint256 seed, uint256 amt, bool zfo, bool useA) public view {
        State memory s = _state(seed);
        amt = bound(amt, 1, 2 ** 100);
        (bool ok, StrategyPricing.Quote memory q, uint256 cap) = _quote(s, useA, _fee(seed), zfo, amt);
        vm.assume(ok);
        int256 before = int256(s.shares * s.c.targetPerShare / WAD) - int256(s.n1);
        uint256 absAfter = q.inventoryAfter >= 0 ? uint256(q.inventoryAfter) : uint256(-q.inventoryAfter);
        uint256 absBefore = before >= 0 ? uint256(before) : uint256(-before);
        assertLe(absAfter, cap > absBefore ? cap : absBefore);
    }

    /// @notice P-1 splitting within one strategy: two pieces from the state the first leaves never pay more than one
    ///         trade of the total (Hook A with its level carried between the pieces).
    function testFuzz_splitNeverGains(uint256 seed, uint256 a, uint256 b, bool zfo, bool useA) public view {
        State memory s = _state(seed);
        // Centred state and pieces below the smallest cap of the domain (about 0.1% of shares at a 3 bp base spread
        // and the shallowest depth), so refusals are rare and the property is exercised.
        s.n1 = s.shares * (PIPS - seed % 400) / PIPS;
        a = bound(a, 1, s.shares / 4000);
        b = bound(b, 1, s.shares / 4000);
        StrategyPricing.ActivityFee memory f = _fee(seed);
        (bool ok, StrategyPricing.Quote memory single,) = _quote(s, useA, f, zfo, a + b);
        vm.assume(ok);
        (bool ok1, StrategyPricing.Quote memory q1,) = _quote(s, useA, f, zfo, a);
        vm.assume(ok1);
        State memory s2 = s;
        s2.n1 = zfo ? s.n1 - q1.amountOut : s.n1 + a;
        bytes memory call = useA
            ? abi.encodeCall(h.hookA, (s2.c, s2.n1, s2.shares, s2.price, s2.unc, f, q1.newLevel, zfo, b))
            : abi.encodeCall(h.hookB, (s2.c, s2.n1, s2.shares, s2.price, s2.unc, 0, 999_999, zfo, b));
        (bool ok2, bytes memory ret) = address(h).staticcall(call);
        vm.assume(ok2);
        (StrategyPricing.Quote memory q2,) = abi.decode(ret, (StrategyPricing.Quote, uint256));
        assertLe(q1.amountOut + q2.amountOut, single.amountOut);
    }

    /// @notice P-2 across strategies: buying currency1 through one hook and selling the proceeds back through the
    ///         other at the same reference never returns more currency0 than was paid.
    function testFuzz_crossStrategyRoundTripLoses(uint256 seed, uint256 amt, bool aFirst) public view {
        State memory s = _state(seed);
        s.n1 = s.shares * (PIPS - seed % 400) / PIPS; // within 0.04% of target: inside every cap of the domain
        // The first leg's output (currency1) must fit the cap, which can be as small as ~0.1% of shares: bound the
        // currency0 input through the price.
        uint256 hi = FullMath.mulDiv(s.shares / 2000, FixedPoint96.Q96, s.price);
        vm.assume(hi > 1e6);
        amt = bound(amt, 1e6, hi);
        StrategyPricing.ActivityFee memory f = _fee(seed);
        (bool ok, StrategyPricing.Quote memory q1,) = _quote(s, aFirst, f, true, amt);
        vm.assume(ok);
        State memory s2 = s;
        s2.n1 = s.n1 - q1.amountOut;
        (bool ok2, StrategyPricing.Quote memory q2,) = _quote(s2, !aFirst, f, false, q1.amountOut);
        vm.assume(ok2);
        assertLt(q2.amountOut, amt);
    }

    /// @notice The potential is continuous at both edges of the cap and increasing, and its inverse is exact.
    function testFuzz_extCostContinuousMonotoneAndInverse(uint256 v, uint256 p, uint256 hb, int256 t) public view {
        v = bound(v, 1e6, 2 ** 95 - 1);
        p = bound(p, 2 ** 60, 2 ** 159);
        hb = bound(hb, 101, 50_000);
        uint256 c = h.straddleCap(v, hb, 100);
        vm.assume(c > 1);
        int256 ci = int256(c);
        assertLe(h.extCost(ci, v, p, c), h.extCost(ci + 1, v, p, c));
        assertLe(h.extCost(-ci - 1, v, p, c), h.extCost(-ci, v, p, c));
        assertLe(h.extCost(ci - 1, v, p, c), h.extCost(ci, v, p, c));
        int256 lo = h.extCost(-ci - int256(v / 2), v, p, c);
        // Precondition of the inverse: t < extCost(c + 1). (At large prices ceil(C) is flat and extCost(c) can equal
        // extCost(c + 1); `ask` refuses every target at or above extCost(c + 1) before inverting.)
        int256 hi = h.extCost(ci + 1, v, p, c) - 1;
        vm.assume(hi >= lo);
        t = bound(t, lo, hi);
        int256 i = h.extPositionForCost(t, v, p, c);
        assertLe(h.extCost(i, v, p, c), t);
        assertGt(h.extCost(i + 1, v, p, c), t);
    }

    /// @notice If every source is live, the market lies in each bracket, and `mid * (1 +- u)` covers it: a quote with
    ///         half-spread >= u cannot be arbitraged against any market price the sources allow.
    function testFuzz_bracketCoversMarket(uint256 m, uint256 x0, uint256 x1, uint256 dSeed) public view {
        m = bound(m, 2 ** 64, 2 ** 150);
        uint256 d0 = 1000 + dSeed % 9000;
        uint256 d1 = 1000 + (dSeed >> 32) % 9000;
        // Each source's answer p with the market inside its bracket: p (1 - d) <= m <= p (1 + d).
        uint256 p0 = FullMath.mulDiv(m, PIPS, PIPS + d0 - 2 * (x0 % d0)); // p0 in [m/(1+d0), m/(1-d0)]
        uint256 p1 = FullMath.mulDiv(m, PIPS, PIPS + d1 - 2 * (x1 % d1));
        uint256 lo0 = p0 * (PIPS - d0) / PIPS;
        uint256 hi0 = FullMath.mulDivRoundingUp(p0, PIPS + d0, PIPS);
        uint256 lo1 = p1 * (PIPS - d1) / PIPS;
        uint256 hi1 = FullMath.mulDivRoundingUp(p1, PIPS + d1, PIPS);
        vm.assume(lo0 <= m && m <= hi0 && lo1 <= m && m <= hi1);
        (uint256 mid, uint256 u) = h.midAndUncertainty(lo0 > lo1 ? lo0 : lo1, hi0 < hi1 ? hi0 : hi1);
        assertLe(mid * (PIPS - u), m * PIPS);
        assertGe(mid * (PIPS + u), m * PIPS);
    }

    /// @notice Dust and limits refuse rather than round in the trader's favour, through both strategies.
    function test_dustAndLimits() public view {
        State memory s = _state(1);
        s.n1 = s.shares; // balanced
        StrategyPricing.ActivityFee memory f = _fee(1);
        for (uint256 k; k < 4; ++k) {
            bool useA = k < 2;
            bool zfo = k % 2 == 0;
            (bool ok0,,) = _quote(s, useA, f, zfo, 0);
            (bool okMax,,) = _quote(s, useA, f, zfo, 2 ** 127);
            (bool okDust,,) = _quote(s, useA, f, zfo, 1);
            assertFalse(ok0);
            assertFalse(okMax);
            assertFalse(okDust);
        }
    }

    /// @notice Regression for the region the fuzzer found: at a price where one unit of inventory costs far less than
    ///         one unit of potential, ceil(C) is flat across the cap (extCost(c) == extCost(c + 1)). The inverse alone
    ///         would answer beyond the cap for such a target, but `ask` refuses every target at or above
    ///         extCost(c + 1) first, so no input moves the inventory past the cap.
    function test_flatSteps_askNeverPassesCap() public view {
        uint256 v = 63_813_666_325_658;
        uint256 p = 621_897_876_241_936_547_109_447_435_177_689_573_977_795_732_509;
        uint256 c = h.straddleCap(v, 12_176, 100);
        assertEq(h.extCost(int256(c), v, p, c), h.extCost(int256(c) + 1, v, p, c), "flat across the cap");
        uint256[5] memory inputs = [uint256(1), 2, 10, 1000, 1e18];
        for (uint256 k; k < 5; ++k) {
            for (uint256 back; back < 3; ++back) {
                InventoryPricing.Core memory core =
                    InventoryPricing.Core(int256(c) - int256(back * 1e9), v, 0, c, 12_176, p);
                try h.ask(core, inputs[k]) returns (uint256, int256 inventoryAfter) {
                    assertLe(inventoryAfter, int256(c));
                } catch (bytes memory reason) {
                    bytes4 sel = bytes4(reason);
                    assertTrue(
                        sel == InventoryPricing.InventoryLimit.selector || sel == InventoryPricing.ZeroOutput.selector
                    );
                }
            }
        }
    }
}
