// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

/// @title ReferenceBracket
/// @notice Turns live push-feed answers into a reference mid and an uncertainty that covers every market price the
///         feeds allow, or refuses.
/// @dev Why brackets. A push feed with deviation threshold `d` writes a new answer when the market moves more than
///      `d` from its last answer, so while the feed is live the market is within `[p(1 - d), p(1 + d)]` of its last
///      answer `p`. Several independent feeds are all true at once, so the market is in the intersection of their
///      brackets. The intersection gives the mid `M` (its centre) and the uncertainty `u` (its half-width relative to
///      `M`). If the intersection is empty, the feeds contradict their own error bounds: one is wrong or not live, and
///      the reference is refused. The threshold is a configuration of the feed, not a measurement; the adapter adds a
///      margin for publication latency.
///
///      A pool price is a ratio of two USD legs. For one source with leg answers `a0` (currency0/USD) and `a1`
///      (currency1/USD), each with its own threshold, the ratio bracket is `[a0 lo / a1 hi, a0 hi / a1 lo]`, converted
///      to raw currency1 per raw currency0 by `10^e`, `e = (feed decimals 1 + token decimals 1) - (feed decimals 0 +
///      token decimals 0)`. Everything rounds outward (low end down, high end up), so the bracket only grows.
library ReferenceBracket {
    uint256 internal constant PIPS = 1_000_000;
    /// @dev Bound on `|e|` that keeps every product below 2^256 for answers below 2^128 (see `pairBracket`).
    int256 internal constant MAX_DECIMAL_SHIFT = 30;

    /// @notice A decimal shift beyond `MAX_DECIMAL_SHIFT` in either direction.
    error DecimalShiftOutOfRange(int256 shift);
    /// @notice The live sources' brackets do not intersect.
    error ReferenceDivergence(uint256 low, uint256 high);
    /// @notice The intersection's low end is zero, so it has no usable centre (a threshold of nearly 100%, or an
    ///         answer too small for the pair's decimals).
    error DegenerateBracket();
    /// @notice Fewer live sources than required.
    error InsufficientSources(uint256 live, uint256 required);

    /// @notice The bracket one source allows for the pool price, raw currency1 per raw currency0, Q64.96.
    /// @dev With `x_lo = a0 (1e6 - d0)`, `x_hi = a0 (1e6 + d0)`, `y_lo = a1 (1e6 - d1)`, `y_hi = a1 (1e6 + d1)`:
    ///
    ///        e >= 0:  low = floor(x_lo * 2^96 * 10^e / y_hi)    high = ceil(x_hi * 2^96 * 10^e / y_lo)
    ///        e <  0:  low = floor(x_lo * 2^96 / (y_hi * 10^-e))  high = ceil(x_hi * 2^96 / (y_lo * 10^-e))
    ///
    ///      Overflow, for answers below 2^128, thresholds below 1e6 and `|e| <= 30`: `x, y < 2^149`; `2^96 * 10^30 <
    ///      2^196`; FullMath's product is below 2^345; `y * 10^30 < 2^249`. Results are checked against the caller's
    ///      bound (`priceX96` below 2^160 for the pricing core).
    ///
    ///      Example: USDC/USD 0.99972 (18 decimals), ETH/USD 2,048.39 (18 decimals), USDC 6 and WETH 18 decimals
    ///      (`e` = 12), thresholds 30 and 50 bps: about 4.8806 * 10^8 raw WETH per raw USDC at the centre, bracket
    ///      roughly -0.80% / +0.80%.
    /// @param a0 Answer of the currency0/USD leg. Positive, below 2^128.
    /// @param a1 Answer of the currency1/USD leg. Positive, below 2^128.
    /// @param d0 Threshold plus margin of leg 0, pips. Below 1e6.
    /// @param d1 Threshold plus margin of leg 1, pips. Below 1e6.
    /// @param e Decimal shift, see above. `|e| <= 30`, else `DecimalShiftOutOfRange`.
    /// @return low Low end, Q64.96, rounded down.
    /// @return high High end, Q64.96, rounded up.
    function pairBracket(uint256 a0, uint256 a1, uint256 d0, uint256 d1, int256 e)
        internal
        pure
        returns (uint256 low, uint256 high)
    {
        uint256 xLo = a0 * (PIPS - d0);
        uint256 xHi = a0 * (PIPS + d0);
        uint256 yLo = a1 * (PIPS - d1);
        uint256 yHi = a1 * (PIPS + d1);
        if (e > MAX_DECIMAL_SHIFT || e < -MAX_DECIMAL_SHIFT) revert DecimalShiftOutOfRange(e);
        if (e >= 0) {
            // 0 <= e <= 30: the cast is safe.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 m = FixedPoint96.Q96 * 10 ** uint256(e);
            low = FullMath.mulDiv(xLo, m, yHi);
            high = FullMath.mulDivRoundingUp(xHi, m, yLo);
        } else {
            // -30 <= e < 0: the cast is safe.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 s = 10 ** uint256(-e);
            low = FullMath.mulDiv(xLo, FixedPoint96.Q96, yHi * s);
            high = FullMath.mulDivRoundingUp(xHi, FixedPoint96.Q96, yLo * s);
        }
    }

    /// @notice Mid and uncertainty of the intersection `[low, high]` of the live sources' brackets.
    /// @dev Reverts with `ReferenceDivergence` if `low > high` and with `DegenerateBracket` if `low` is 0. `mid = floor((low + high) / 2)` and
    ///      `u = max(ceil((high - mid) * 1e6 / mid), ceil((mid - low) * 1e6 / mid))`, so `mid * (1 +- u)` covers the
    ///      whole intersection: a quote whose half-spread is at least `u` straddles every market price the sources
    ///      allow.
    ///
    ///      Example (Unichain ETH/USD, 2026-11-10): Chainlink 2,048.39 and RedStone 2,050.31, both 50 bps: the
    ///      intersection is [2,040.06, 2,058.63], mid 2,049.35, `u` = 4,532 pips.
    /// @param low Largest low end over the live sources, Q64.96.
    /// @param high Smallest high end over the live sources, Q64.96.
    /// @return mid Reference mid, Q64.96.
    /// @return uncertainty Half-width relative to the mid, pips, rounded up.
    function midAndUncertainty(uint256 low, uint256 high) internal pure returns (uint256 mid, uint256 uncertainty) {
        if (low > high) revert ReferenceDivergence(low, high);
        if (low == 0) revert DegenerateBracket();
        mid = low + (high - low) / 2;
        uint256 up = FullMath.mulDivRoundingUp(high - mid, PIPS, mid);
        uint256 down = FullMath.mulDivRoundingUp(mid - low, PIPS, mid);
        uncertainty = up > down ? up : down;
    }
}
