// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, stdError} from "forge-std/Test.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

import {CumulativePricing} from "../../src/hooks/CumulativePricing.sol";
import {PricingVectors} from "../utils/PricingVectors.sol";

/// @dev External wrappers so that reverts inside the internal library functions can be caught.
contract PricingHarness {
    function decayed(uint256 l, uint256 r, uint256 w, uint256 e) external pure returns (uint256) {
        return CumulativePricing.decayed(l, r, w, e);
    }

    function fee(uint256 l, uint256 k, uint256 b, uint256 m) external pure returns (uint256) {
        return CumulativePricing.cumulativeFee(l, k, b, m);
    }

    function cost(int256 x, uint256 v, uint256 p) external pure returns (int256) {
        return CumulativePricing.positionCost(x, v, p);
    }

    function inverse(int256 t, uint256 v, uint256 p) external pure returns (int256) {
        return CumulativePricing.positionForCost(t, v, p);
    }

    function maxPosition(uint256 v, uint256 m) external pure returns (uint256) {
        return CumulativePricing.maxPosition(v, m);
    }
}

/// @notice CumulativePricing against the independent Python model's integers, plus properties checked on-chain that
///         do not depend on the model: the inverse is exact, the cap is exact, fees and costs telescope and are
///         monotone, and out-of-range inputs revert instead of wrapping.
contract CumulativePricingTest is Test {
    uint256 internal constant PIPS = 1_000_000;
    uint256 internal constant MAX_DEPTH = 2 ** 95 - 1;
    uint256 internal constant Q96 = FixedPoint96.Q96;

    PricingHarness internal h;

    function setUp() public {
        h = new PricingHarness();
    }

    // ------------------------------------------------------------------
    // Differential: Python reference model vectors
    // ------------------------------------------------------------------

    function test_vectors_fee() public view {
        PricingVectors.Fee[] memory v = PricingVectors.fee();
        for (uint256 i; i < v.length; ++i) {
            assertEq(h.fee(v[i].level, v[i].scale, v[i].baseFeePips, v[i].maxFeePips), v[i].expected, vm.toString(i));
        }
    }

    function test_vectors_cost() public view {
        PricingVectors.Cost[] memory v = PricingVectors.cost();
        for (uint256 i; i < v.length; ++i) {
            assertEq(h.cost(v[i].x, v[i].depth, v[i].priceX96), v[i].expected, vm.toString(i));
        }
    }

    function test_vectors_inverse() public view {
        PricingVectors.Inverse[] memory v = PricingVectors.inverse();
        for (uint256 i; i < v.length; ++i) {
            assertEq(h.inverse(v[i].cost, v[i].depth, v[i].priceX96), v[i].expected, vm.toString(i));
        }
    }

    function test_vectors_maxPosition() public view {
        PricingVectors.MaxPos[] memory v = PricingVectors.maxPosition();
        for (uint256 i; i < v.length; ++i) {
            assertEq(h.maxPosition(v[i].depth, v[i].maxImpactPips), v[i].expected, vm.toString(i));
        }
    }

    function test_vectors_decay() public view {
        PricingVectors.Decay[] memory v = PricingVectors.decay();
        for (uint256 i; i < v.length; ++i) {
            assertEq(h.decayed(v[i].level, v[i].rate, v[i].window, v[i].elapsed), v[i].expected, vm.toString(i));
        }
    }

    // ------------------------------------------------------------------
    // Hook A fee
    // ------------------------------------------------------------------

    /// @dev The worked example in the library NatSpec and CUMULATIVE_PRICING_SPEC.md section 5.
    function test_fee_specExample() public view {
        assertEq(h.fee(8000 ether, 10_000 ether, 500, 5000), 18.4 ether);
        assertEq(h.fee(0, 10_000 ether, 500, 5000), 0);
    }

    /// @dev Monotone, never more than the input it is charged on, and continuous across K (the two branches agree,
    ///      so the fee for the unit that crosses K is at most one unit's worth of max fee plus rounding).
    function testFuzz_fee_monotoneBoundedContinuous(uint128 k, uint24 base, uint24 max, uint128 a, uint128 d)
        public
        view
    {
        k = uint128(bound(k, 1, type(uint128).max));
        max = uint24(bound(max, 0, PIPS - 1));
        base = uint24(bound(base, 0, max));
        a = uint128(bound(a, 0, type(uint128).max - 1));
        d = uint128(bound(d, 1, type(uint128).max - a));
        uint256 fa = h.fee(a, k, base, max);
        uint256 fb = h.fee(uint256(a) + d, k, base, max);
        assertGe(fb, fa, "monotone");
        assertLe(fb - fa, d, "fee <= input");
        // Exact fee over [a, a+d] is at most d * max / PIPS; the integer difference adds less than one unit.
        assertLe(fb - fa, uint256(d) * max / PIPS + 1, "fee <= max rate + 1");
        // Continuity at K: crossing K by one unit costs at most one unit at the max rate, rounded up.
        assertLe(h.fee(uint256(k) + 1, k, base, max) - h.fee(k, k, base, max), 1);
    }

    // ------------------------------------------------------------------
    // Hook B curve
    // ------------------------------------------------------------------

    /// @dev Exactness of the inverse without the model: positionCost(x') <= t < positionCost(x' + 1). This is the
    ///      property that makes exact-input trades telescope (each piece reaches the largest state its input pays for).
    function testFuzz_inverse_isExact(uint96 v, uint160 p, uint24 m, uint256 seed) public view {
        v = uint96(bound(v, 4, MAX_DEPTH));
        p = uint160(bound(p, 1, type(uint160).max));
        m = uint24(bound(m, 1, PIPS - 1));
        uint256 xm = h.maxPosition(v, m);
        if (xm == 0) return;
        int256 lo = h.cost(-int256(xm), v, p);
        int256 hi = h.cost(int256(xm) + 1, v, p);
        // Every target the hook can ask about lies in [cost(-xm), cost(xm + 1)).
        int256 t = lo + int256(bound(seed, 0, uint256(hi - lo - 1)));
        int256 x = h.inverse(t, v, p);
        assertLe(h.cost(x, v, p), t, "cost(x') <= t");
        assertGt(h.cost(x + 1, v, p), t, "cost(x' + 1) > t");
    }

    /// @dev Monotone in x, zero at zero, and the cost of a positive position is at least its value at the reference
    ///      price (the curve never sells currency1 below P) while a negative position is bought at or below it.
    function testFuzz_cost_monotoneAndAboveReference(uint96 v, uint160 p, uint256 seed) public view {
        v = uint96(bound(v, 4, MAX_DEPTH));
        p = uint160(bound(p, 1, type(uint160).max));
        uint256 xm = h.maxPosition(v, PIPS - 1);
        int256 x = int256(bound(seed, 0, 2 * xm)) - int256(xm);
        assertEq(h.cost(0, v, p), 0);
        assertGe(h.cost(x + 1, v, p), h.cost(x, v, p), "monotone");
        // L(x) = x * 2^96 / P. Positive side: cost >= ceil-free L; negative side: |cost| <= |L|.
        if (x > 0) assertGe(uint256(h.cost(x, v, p)), uint256(x) * Q96 / p, "sells at or above P");
        if (x < 0) assertLe(uint256(-h.cost(x, v, p)), uint256(-x) * Q96 / p + 1, "buys at or below P");
    }

    /// @dev The cap is exact: marginal ratio (V/(V-x))^2 <= 1 + m at the cap and > 1 + m one unit past it.
    function testFuzz_maxPosition_isExactCap(uint96 v, uint24 m) public view {
        v = uint96(bound(v, 2, MAX_DEPTH));
        m = uint24(bound(m, 0, PIPS - 1));
        uint256 xm = h.maxPosition(v, m);
        uint256 lhs = uint256(v) * v * PIPS;
        assertGe((v - xm) * (v - xm) * (PIPS + m), lhs, "within cap");
        if (xm + 1 < v) assertLt((v - xm - 1) * (v - xm - 1) * (PIPS + m), lhs, "one past the cap");
        assertLe(xm * 1000, uint256(v) * 293, "cap below 0.293 V");
    }

    function test_cost_specExamples() public view {
        assertEq(h.cost(1000 ether, 1e6 ether, Q96), 1_001_001_001_001_001_001_002);
        assertEq(h.inverse(1_001_001_001_001_001_001_002, 1e6 ether, Q96), 1000 ether);
        assertEq(h.maxPosition(1e6, 20_000), 9852);
    }

    // ------------------------------------------------------------------
    // Decay
    // ------------------------------------------------------------------

    /// @dev Monotone in time, never below the exact linear decay, never negative, no reset past the window.
    function testFuzz_decay_monotoneNoReset(uint128 level, uint128 rate, uint32 window, uint64 e1, uint64 e2)
        public
        view
    {
        (e1, e2) = e1 <= e2 ? (e1, e2) : (e2, e1);
        uint256 a = h.decayed(level, rate, window, e1);
        uint256 b = h.decayed(level, rate, window, e2);
        assertLe(b, a, "monotone");
        assertLe(a, level);
        if (window != 0) {
            // a >= level - rate * e1 / window (exact): a * window + rate * e1 >= level * window.
            assertGe(a * window + uint256(rate) * e1, uint256(level) * window, "not below exact decay");
        } else {
            assertEq(a, level, "window 0 disables decay");
        }
    }

    // ------------------------------------------------------------------
    // Extremes: revert, never wrap
    // ------------------------------------------------------------------

    function test_extremes_revertInsteadOfWrapping() public {
        // x == V: zero denominator; FullMath reverts with no data. x > V: checked subtraction underflows.
        vm.expectRevert(bytes(""));
        h.cost(int256(uint256(1000)), 1000, Q96);
        vm.expectRevert(stdError.arithmeticError);
        h.cost(int256(uint256(1001)), 1000, Q96);
        // Near V with the smallest price: a cost in (2^255, 2^256) gets the explicit error instead of a wrapped sign
        // (x = V - 3 * 2^29 gives about 2^255.4); a cost above 2^256 is refused by FullMath itself.
        vm.expectRevert(CumulativePricing.CostOutOfRange.selector);
        h.cost(int256(MAX_DEPTH - 3 * 2 ** 29), MAX_DEPTH, 1);
        vm.expectRevert(bytes(""));
        h.cost(int256(MAX_DEPTH - 1), MAX_DEPTH, 1);
        // A target at C(-infinity) has no answer: zero denominator. Below it the subtraction underflows.
        vm.expectRevert(bytes(""));
        h.inverse(-int256(1000 * Q96), 1000, 1);
        vm.expectRevert(stdError.arithmeticError);
        h.inverse(-int256(1000 * Q96 + 1), 1000, 1);
        // t * P beyond 256 bits; negating int256.min.
        vm.expectRevert(stdError.arithmeticError);
        h.inverse(type(int256).max, MAX_DEPTH, type(uint160).max);
        vm.expectRevert(stdError.arithmeticError);
        h.inverse(type(int256).min, MAX_DEPTH, 1);
        // Decay rate * elapsed beyond 256 bits.
        vm.expectRevert(stdError.arithmeticError);
        h.decayed(1, type(uint256).max, 1, 2);
        // Largest legal arguments stay exact.
        assertEq(h.decayed(type(uint128).max, type(uint128).max, 1, type(uint64).max), 0);
        assertEq(
            h.fee(type(uint128).max, type(uint128).max, 0, PIPS - 1),
            170_141_013_319_285_771_262_455_572_028_580_389_844
        );
    }
}
