// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CumulativePricing
/// @notice Integer pricing curves whose cost depends only on a stored state, so that a trade costs the same in total
///         however it is split into pieces.
/// @dev The idea. A hook keeps a state `s` (how much has been traded, decaying over time) and a cost function
///      `C(s)`. A trade that moves the state from `a` to `b` costs `C(b) - C(a)`. If the hook rounds each trade's
///      cost on its own, the rounding depends on how the trade is split. Instead, each function here is one fixed
///      integer function of the state (`ceil(C(s))`), and a trade costs the difference of two of its values. Over any
///      sequence of pieces the differences telescope: `Σ [f(s_i+1) - f(s_i)] = f(s_n) - f(s_0)`, exactly the cost of
///      one trade from `s_0` to `s_n`. Rounding is therefore paid once per state, not once per piece.
///
///      Two curves:
///      - `cumulativeFee` (Hook A): the integral of a fee rate that rises linearly with the state and then stays at
///        its maximum.
///      - `positionCost` / `positionForCost` (Hook B): a virtual constant-product curve with depth `V` around a
///        reference price, defined for a signed position.
///
///      The functions are pure and check nothing about who calls them. The hooks state and enforce the
///      preconditions; every operation here uses checked arithmetic or FullMath, so a precondition violated by
///      mistake reverts instead of wrapping.
library CumulativePricing {
    /// @dev 1,000,000 pips = 100%.
    uint256 internal constant PIPS = 1_000_000;

    /// @dev Largest Hook B depth. With `V <= 2^95 - 1` and `|x| < V`, the denominators `P * (V - x)` and
    ///      `P * (V + |x|)` stay below `2^160 * 2^96 = 2^256` for every uint160 price `P`.
    uint256 internal constant MAX_DEPTH = 2 ** 95 - 1;

    /// @notice `positionCost` was asked for a state whose cost does not fit in an int256.
    error CostOutOfRange();

    /// @notice A level after linear decay toward zero.
    /// @dev Computes `max(0, level - floor(rate * elapsed / window))`. Rounding the decayed amount down keeps the
    ///      result at or above the exact linear decay, so a trader who arrives later never sees a lower level than the
    ///      exact model gives. The remainder is not carried over: each update can therefore forget less than one raw
    ///      unit of decay, which favours the level staying high. O(1) for any elapsed time; once `rate * elapsed`
    ///      reaches `level * window` the result is 0, never negative, and stays 0. `window == 0` disables decay.
    ///
    ///      Overflow: the hooks pass `rate < 2^128` and `elapsed < 2^64` (two uint64 timestamps), so the product is
    ///      below 2^192. Larger arguments revert on the checked multiplication.
    ///
    ///      Example: level 1,000, rate 600 per window of 60 s, 30 s elapsed: decay floor(600 * 30 / 60) = 300, result
    ///      700. After 120 s the decay is 1,200 and the result is 0.
    /// @param level Current level, raw units.
    /// @param rate Amount that decays per `window`, raw units.
    /// @param window Seconds over which `rate` decays. 0 disables decay.
    /// @param elapsed Seconds since the level was last updated.
    /// @return The decayed level, raw units.
    function decayed(uint256 level, uint256 rate, uint256 window, uint256 elapsed) internal pure returns (uint256) {
        if (window == 0) return level;
        uint256 d = rate * elapsed / window;
        return level > d ? level - d : 0;
    }

    /// @notice Hook A's cumulative fee at flow level `level`: the fee, in input units, owed for moving the level
    ///         from 0 to `level`, rounded up.
    /// @dev The marginal fee rate at level `u` (pips) is `m(u) = base + (max - base) * min(1, u / K)`: it rises
    ///      linearly from `base` at 0 to `max` at `K` and stays at `max` above. The real cumulative fee is
    ///
    ///        F(s) = (base * s + (max - base) * s^2 / (2K)) / PIPS                      for s <= K
    ///        F(s) = (K * (base + max) / 2 + max * (s - K)) / PIPS                      for s >  K
    ///
    ///      Both forms equal `K * (base + max) / (2 * PIPS)` at `s = K`, so this is one continuous function and its
    ///      ceiling is one integer function. A trade from level `a` to `b` pays `cumulativeFee(b) - cumulativeFee(a)`,
    ///      which telescopes over any split. Rounding up favours the vault: the integer fee over `[a, b]` is less than
    ///      the exact fee plus 1, and never more than `b - a` (because `max < PIPS`, the exact fee is below `b - a`).
    ///
    ///      Example (1:1 tokens, base 500, max 5,000 pips, K = 10,000): F(8,000) = 4 + 4,500 * 64,000,000 / 20,000 /
    ///      10^6 = 4 + 14.4 = 18.4, the same for one trade of 8,000 or any split of it.
    ///
    ///      Overflow: the caller keeps `level <= 2^128 - 1` and `scale <= 2^128 - 1`; fees are below 2^20. Then
    ///      `(max - base) * level + 2 * K * base < 2^150`, FullMath holds `level` times that in 512 bits, the
    ///      denominator `2 * K * PIPS` is below 2^150, and the result is at most `level`. Above `K` every term is
    ///      below 2^150.
    /// @param level Flow level, raw input units.
    /// @param scale `K`: the level at which the fee rate reaches `maxFeePips`, raw input units. Non-zero.
    /// @param baseFeePips Fee rate at level 0, pips.
    /// @param maxFeePips Fee rate at and above `K`, pips. At least `baseFeePips` and below `PIPS`.
    /// @return Cumulative fee, raw input units, rounded up.
    function cumulativeFee(uint256 level, uint256 scale, uint256 baseFeePips, uint256 maxFeePips)
        internal
        pure
        returns (uint256)
    {
        if (level <= scale) {
            return FullMath.mulDivRoundingUp(
                level, (maxFeePips - baseFeePips) * level + 2 * scale * baseFeePips, 2 * scale * PIPS
            );
        }
        return
            FullMath.mulDivRoundingUp(
                scale * (baseFeePips + maxFeePips) + 2 * maxFeePips * (level - scale), 1, 2 * PIPS
            );
    }

    /// @notice Hook B's cost of a position: the currency0 owed, at the curve's prices, for a net sale of `x` currency1
    ///         by the vault, rounded up. Negative `x` (the vault has bought currency1) gives a negative cost.
    /// @dev The curve is a constant product with virtual reserves `V` currency1 and `V / P` currency0 (in Q96 units
    ///      `V * 2^96 / P`). Removing `x` currency1 requires adding
    ///
    ///        C(x) = V * x * 2^96 / (P * (V - x))      currency0,   for x < V,
    ///
    ///      so the marginal price is `(2^96 / P) * (V / (V - x))^2` currency0 per currency1: the reference price at
    ///      `x = 0`, rising as the vault sells currency1 and falling as it buys it back. The function returns
    ///      `ceil(C(x))` for every integer `x` (for `x < 0`, `ceil` of a negative value is minus the floor of its
    ///      magnitude). Every trade is priced as a difference of two values of this one integer function, so trades
    ///      in either direction telescope: any sequence that moves the position from `a` to `b` exchanges exactly
    ///      `positionCost(b) - positionCost(a)` currency0, however it is split and in whatever order.
    ///
    ///      Example: V = 1,000,000, 1:1 price, x = 1,000 gives C = 10^9 / 999,000 = 1,001.001..., rounded up.
    ///
    ///      Preconditions: `V <= MAX_DEPTH`, `|x| < V`, `0 < P < 2^160`. Then `V * |x| < 2^190`, FullMath holds the
    ///      product with 2^96 in 512 bits, and the denominator is below 2^256 (see `MAX_DEPTH`). The hooks keep
    ///      `|x|` below about 0.3 V, where the result is below `2^96 * V / P < 2^191`. Closer to `V` the result grows
    ///      without bound; a value above `int256` max reverts with `CostOutOfRange` and FullMath reverts above 2^256.
    /// @param x Signed position, raw currency1: currency1 sold by the vault minus currency1 bought.
    /// @param depth `V`, raw currency1.
    /// @param priceX96 `P`, raw currency1 per raw currency0, Q64.96.
    /// @return Signed cost, raw currency0, rounded toward +infinity.
    function positionCost(int256 x, uint256 depth, uint256 priceX96) internal pure returns (int256) {
        if (x >= 0) {
            uint256 u = uint256(x);
            uint256 c = FullMath.mulDivRoundingUp(depth * u, FixedPoint96.Q96, priceX96 * (depth - u));
            if (c > uint256(type(int256).max)) revert CostOutOfRange();
            return int256(c);
        }
        uint256 y = uint256(-x);
        // Result < 2^96 * V / P < 2^191: the cast is safe.
        return -int256(FullMath.mulDiv(depth * y, FixedPoint96.Q96, priceX96 * (depth + y)));
    }

    /// @notice The largest position whose cost is at most `cost`: the inverse of `positionCost` for exact input.
    /// @dev Since `cost` is an integer, `ceil(C(x)) <= cost` exactly when `C(x) <= cost`, and
    ///
    ///        C(x) <= t   <=>   x * (V * 2^96 + t * P) <= t * P * V.
    ///
    ///      `V * 2^96 + t * P` is positive for every `t` above `C(-infinity) = -V * 2^96 / P`, so the answer is
    ///      `floor(t * P * V / (V * 2^96 + t * P))`, rounded toward -infinity for negative `t`. This is exact: the
    ///      result `x'` satisfies `positionCost(x') <= t < positionCost(x' + 1)` with no correction step and no
    ///      square root.
    ///
    ///      Example: V = 1,000,000, 1:1 price, t = 1,001.001001 * 10^18 (the cost of 1,000 * 10^18): returns
    ///      1,000 * 10^18.
    ///
    ///      Overflow: Hook B only calls this with `t` below the cost of its position cap plus one unit, where
    ///      `|t| * P` is below `2^96 * V + P < 2^192`; FullMath holds the product with `V` in 512 bits and the result
    ///      is below `V`. Outside that range the checked multiplication or subtraction reverts.
    /// @param cost Target cost `t`, raw currency0 (signed).
    /// @param depth `V`, raw currency1.
    /// @param priceX96 `P`, raw currency1 per raw currency0, Q64.96.
    /// @return The largest `x` with `positionCost(x) <= cost`.
    function positionForCost(int256 cost, uint256 depth, uint256 priceX96) internal pure returns (int256) {
        if (cost >= 0) {
            uint256 tp = uint256(cost) * priceX96;
            // Result <= V < 2^95: the cast is safe.
            return int256(FullMath.mulDiv(tp, depth, depth * FixedPoint96.Q96 + tp));
        }
        uint256 up = uint256(-cost) * priceX96;
        return -int256(FullMath.mulDivRoundingUp(up, depth, depth * FixedPoint96.Q96 - up));
    }

    /// @notice Hook B's position cap: the largest `x >= 0` at which the marginal price is at most
    ///         `1 + maxImpactPips / PIPS` times the reference price.
    /// @dev The marginal price ratio at `x` is `(V / (V - x))^2`, so the condition is
    ///      `(V - x)^2 * (PIPS + m) >= V^2 * PIPS`. With `r = ceil(V * sqrt(PIPS / (PIPS + m)))`, the smallest integer
    ///      with `r^2 * (PIPS + m) >= V^2 * PIPS`, the cap is `V - r`. `r` starts from `sqrt(floor(V^2 * PIPS /
    ///      (PIPS + m)))`, which is at most 2 below the target (the square roots of two numbers that differ by less
    ///      than 1, both >= 1, differ by less than 1), and is raised until the condition holds.
    ///
    ///      The same cap is used for negative positions. There the vault sells currency0, and the marginal premium on
    ///      currency0 is `((V + |x|) / V)^2 - 1`, which is smaller than `(V / (V - |x|))^2 - 1`, so the cap is
    ///      conservative on that side.
    ///
    ///      Example: V = 1,000,000, m = 20,000 (2%): r = ceil(990,147.54) = 990,148, cap 9,852.
    ///
    ///      Overflow: `V^2 * PIPS < 2^190 * 2^20`; `r <= V`, so `r^2 * (PIPS + m) < 2^190 * 2^21`.
    /// @param depth `V`, raw currency1. At most `MAX_DEPTH`.
    /// @param maxImpactPips Largest marginal premium, pips. Below `PIPS`.
    /// @return Cap on `|x|`, raw currency1. Below 0.3 V (at `m` just below 100% it is `V * (1 - 1/sqrt(2))`).
    function maxPosition(uint256 depth, uint256 maxImpactPips) internal pure returns (uint256) {
        uint256 num = depth * depth * PIPS;
        uint256 den = PIPS + maxImpactPips;
        uint256 r = Math.sqrt(num / den);
        while (r * r * den < num) {
            ++r;
        }
        return depth - r;
    }
}
