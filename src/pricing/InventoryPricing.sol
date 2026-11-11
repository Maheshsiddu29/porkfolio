// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {CumulativePricing} from "../hooks/CumulativePricing.sol";

/// @title InventoryPricing
/// @notice The shared economic core every hook on one vault reserve prices through: a quote skewed by the vault's
///         real inventory around a reference price, with a cap that keeps every quote on the vault's side of that
///         reference.
/// @dev State. The core keeps nothing. Its state is the vault's own: `n1` (net currency1, backing minus claimable) and
///      `shares` (total shares). The inventory deviation is `I = T_1 - n1`, where `T_1 = shares * targetPerShare /
///      1e18` is the target holding. `I > 0` means the vault holds less currency1 than its target. A trade moves `I`
///      by exactly the currency1 it moves. Proportional LP deposits and redemptions scale `n1`, `T_1` and the depth
///      together, so they leave the price unchanged up to one unit of rounding. Nothing decays.
///
///      Potential. Inside the cap `c` the cost of a position is Hook B's constant-product curve evaluated at `I`
///      (`CumulativePricing.positionCost`): `C(I) = V * I * 2^96 / (P * (V - I))` currency0. Outside `[-c, c]` it
///      continues linearly with the slope it has at the edge, so it is defined for every `I` and an inward trade from
///      beyond the cap can always be priced. Every trade is a difference of two values of the one integer function
///      `ceil(C)`, so trades telescope.
///
///      Straddle. `c` is the largest deviation at which the curve's skew still fits inside the half-spread `h`: the
///      bid at `+c` is `P * (1 - minEdge)` and the ask at `-c` is `P * (1 + minEdge)`. With the one-unit reserve on
///      each side (see `ask` and `bid`), every accepted trade is priced on the vault's side of `P` by at least
///      `minEdge`, whatever the state. Consequences: floors pivoted at `P` accept every quote; a closed cycle of trades
///      at a fixed `P` loses at least `2 * minEdge` of its volume; a hook that adds its own fee on top of `h` keeps
///      the property.
///
///      Trust. The functions are pure and check nothing about the caller. The reference price and the vault state
///      are inputs; the hook that uses this library must read the vault state in the same call that settles, and must
///      take the reference from a source that refuses stale or inconsistent data. The vault still enforces its own
///      floors, quota and flow limits; this library never replaces them.
///
///      Units: amounts raw; `priceX96` raw currency1 per raw currency0, Q64.96; spreads and caps in pips
///      (1,000,000 = 100%); per-share values WAD (1e18).
library InventoryPricing {
    /// @dev 1,000,000 pips = 100%.
    uint256 internal constant PIPS = 1_000_000;
    /// @dev 1e18: scale of the per-share parameters.
    uint256 internal constant WAD = 1e18;
    /// @dev Amounts must fit int128 (PoolManager deltas).
    uint256 internal constant MAX_AMOUNT = uint256(uint128(type(int128).max));

    /// @notice Parameters of the core. Shared by every hook on the reserve; none comes from the trader.
    /// @param targetPerShare `tau`: target currency1 per share, WAD.
    /// @param depthPerShare Curve depth per share, WAD. Derived off-chain from the risk cap and the base spread so that
    ///        the straddle cap at `baseSpread` reaches `maxDeviation`; about `2 * maxDeviation * tau /
    ///        (baseSpread - minEdge)`.
    /// @param depthMax Absolute cap on the depth `V`, raw currency1. At most `2^95 - 1`.
    /// @param baseSpread Half-spread before reference uncertainty, pips. Above `minEdge`.
    /// @param minEdge Smallest distance between any quote and the reference, pips.
    /// @param maxSpread Largest accepted half-spread (base plus uncertainty), pips. Below 1,000,000.
    /// @param maxDeviation Risk cap on `|I|`, pips of `T_1`.
    /// @param bandEdge True: every quote stays `minEdge` beyond the whole uncertainty band `P * (1 +- uncertainty)`,
    ///        not only beyond `P` (the cap is computed for an edge of `minEdge + uncertainty`). Required wherever the
    ///        vault independently refuses prices inside the band. False reproduces the earlier mid-only behaviour.
    struct Config {
        uint256 targetPerShare;
        uint256 depthPerShare;
        uint256 depthMax;
        uint256 baseSpread;
        uint256 minEdge;
        uint256 maxSpread;
        uint256 maxDeviation;
        bool bandEdge;
    }

    /// @notice The core's view of one reserve at one reference.
    /// @param inventory `I = T_1 - n1`, raw currency1 (signed).
    /// @param depth `V`, raw currency1.
    /// @param target `T_1`, raw currency1.
    /// @param cap `c`: inventory-increasing trades must end within `[-c, c]`, raw currency1.
    /// @param halfSpread `h = baseSpread + uncertainty`, pips: the least any strategy may charge.
    /// @param priceX96 Reference mid, raw currency1 per raw currency0, Q64.96.
    struct Core {
        int256 inventory;
        uint256 depth;
        uint256 target;
        uint256 cap;
        uint256 halfSpread;
        uint256 priceX96;
    }

    /// @notice The input was zero.
    error ZeroInput();
    /// @notice An amount above `2^127 - 1`.
    error AmountTooLarge();
    /// @notice Base spread plus reference uncertainty is above the configured maximum.
    /// @param halfSpread The half-spread that would have applied, pips.
    error SpreadTooWide(uint256 halfSpread);
    /// @notice The reserve has no shares, so it has no depth.
    error NoDepth();
    /// @notice The trade would leave the inventory beyond the cap in the direction it moves.
    /// @param inventory Inventory before the trade, raw currency1.
    /// @param cap The cap, raw currency1.
    error InventoryLimit(int256 inventory, uint256 cap);
    /// @notice The quote rounded to nothing; refused rather than paid.
    error ZeroOutput();

    /// @notice Builds the core's state from the vault's holdings and a reference.
    /// @dev Reverts with `SpreadTooWide` if `baseSpread + uncertainty > maxSpread` and with `NoDepth` if the depth is
    ///      zero. The cap is `min(straddleCap(V, h, edge), T_1 * maxDeviation / 1e6)` with `edge = minEdge`, or
    ///      `minEdge + uncertainty` when `bandEdge` is set. Both products are checked
    ///      arithmetic: `shares <= 2^127` (the vault's supply bound) and the per-share parameters are governance
    ///      values; an unreasonable value reverts instead of wrapping.
    ///
    ///      Example: 1,000,000 shares holding 1,000,000 currency1 with `tau` = 1 and the calibrated depth per share
    ///      158.0013 give `T_1` = 1,000,000, `V` = 158,001,289, `I` = 0; at `h` = 20 bps and `minEdge` = 1 bp the
    ///      straddle cap is 150,015 and a 15% risk cap makes `c` = 150,000.
    /// @param cfg Core parameters.
    /// @param n1 Vault net currency1 (`backing - claimableAssets`), raw.
    /// @param shares Vault `totalShares`.
    /// @param priceX96 Reference mid, Q64.96. Non-zero.
    /// @param uncertainty Reference uncertainty, pips.
    /// @return core The state every strategy prices from.
    function coreState(Config memory cfg, uint256 n1, uint256 shares, uint256 priceX96, uint256 uncertainty)
        internal
        pure
        returns (Core memory core)
    {
        uint256 h = cfg.baseSpread + uncertainty;
        if (h > cfg.maxSpread) revert SpreadTooWide(h);
        uint256 t1 = shares * cfg.targetPerShare / WAD;
        uint256 v = shares * cfg.depthPerShare / WAD;
        if (v > cfg.depthMax) v = cfg.depthMax;
        if (v == 0) revert NoDepth();
        uint256 c = straddleCap(v, h, cfg.bandEdge ? cfg.minEdge + uncertainty : cfg.minEdge);
        uint256 riskCap = t1 * cfg.maxDeviation / PIPS;
        if (riskCap < c) c = riskCap;
        // t1, n1 < 2^255: both are bounded by the vault's MAX_AMOUNT-sized balances and supply.
        // forge-lint: disable-next-line(unsafe-typecast)
        core = Core(int256(t1) - int256(n1), v, t1, c, h, priceX96);
    }

    /// @notice The vault sells currency1: output for `netIn` currency0 after any strategy fee.
    /// @dev `t = ceil(C(I)) + floor(netIn * 1e6 / (1e6 + h)) - 1`; the new inventory is the largest `I'` with
    ///      `ceil(C(I')) <= t`; refused with `InventoryLimit` if `I >= c` or `I' > c`; `out = I' - I`, refused with
    ///      `ZeroOutput` if zero.
    ///
    ///      Rounding, all toward the vault: the spread credit rounds down, the inverse rounds down, and one more unit
    ///      of potential is withheld. That unit is what makes the straddle exact for every size: `ceil(C)` can exceed
    ///      `C` by just under one unit, and without the reserve a dust trade could land one wei on the trader's side
    ///      of the reference. A split into `n` pieces therefore loses at most a few units per piece and never gains.
    ///
    ///      Example (state of `coreState`'s example, `P` = 1): 10,000 currency0 in buys 9,979.4096 currency1, an average
    ///      of 1.002063 currency0 each.
    /// @param core State from `coreState`.
    /// @param netIn Currency0 credited to the curve, raw (the trader's input less any strategy fee).
    /// @return amountOut Currency1 out, raw.
    /// @return inventoryAfter `I'`, raw currency1.
    function ask(Core memory core, uint256 netIn) internal pure returns (uint256 amountOut, int256 inventoryAfter) {
        if (netIn > MAX_AMOUNT) revert AmountTooLarge();
        int256 i = core.inventory;
        // c < 0.3 V < 2^95: the cast is safe.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 c = int256(core.cap);
        // credit < 2^127 and |extCost(i)| < 2^224 (see extCost): the sum fits.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 t = extCost(i, core.depth, core.priceX96, core.cap) + int256(netIn * PIPS / (PIPS + core.halfSpread)) - 1;
        if (i >= c || t >= extCost(c + 1, core.depth, core.priceX96, core.cap)) revert InventoryLimit(i, core.cap);
        inventoryAfter = extPositionForCost(t, core.depth, core.priceX96, core.cap);
        // t >= ceil(C(i)) - 1, so inventoryAfter >= i - 1; an input too small to buy one unit leaves it at or below i.
        if (inventoryAfter <= i) revert ZeroOutput();
        amountOut = uint256(inventoryAfter - i);
    }

    /// @notice The vault buys currency1: output for `moved` currency1 in, of which `priced` is paid on the curve.
    /// @dev The inventory moves by the full `moved`, because that is what the vault now holds; `moved - priced` is a
    ///      strategy fee received in currency1. `out = floor((ceil(C(I)) - ceil(C(I - priced))) * (1e6 - h) / 1e6) - 1`,
    ///      refused with `InventoryLimit` if `I - moved < -c` and with `ZeroOutput` if zero. The segment priced,
    ///      `[I - priced, I]`, lies inside the segment moved through, so a fee can only lower the output; the curve's
    ///      marginal price falls as `I` falls, so a later trade from the lower state is paid less (splits never gain).
    ///
    ///      Example (state of `coreState`'s example, `P` = 1): 10,000 currency1 in pays 9,979.3684 currency0. With
    ///      the vault 10% short currency1 (`I` = 100,000) the same trade pays 9,992.0120: the inventory-reducing side
    ///      of the skew, still below the reference.
    /// @param core State from `coreState`.
    /// @param moved Currency1 the vault receives, raw.
    /// @param priced Part of `moved` priced on the curve, raw. At most `moved`.
    /// @return amountOut Currency0 out, raw.
    /// @return inventoryAfter `I - moved`, raw currency1.
    function bid(Core memory core, uint256 moved, uint256 priced)
        internal
        pure
        returns (uint256 amountOut, int256 inventoryAfter)
    {
        if (moved > MAX_AMOUNT) revert AmountTooLarge();
        // moved < 2^127: the casts are safe; priced <= moved.
        // forge-lint: disable-next-line(unsafe-typecast)
        inventoryAfter = core.inventory - int256(moved);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (inventoryAfter < -int256(core.cap)) revert InventoryLimit(core.inventory, core.cap);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 gross = extCost(core.inventory, core.depth, core.priceX96, core.cap)
            - extCost(core.inventory - int256(priced), core.depth, core.priceX96, core.cap);
        // gross >= 0 (C is increasing) and below 2^225: the product with (1e6 - h) fits.
        uint256 paid = uint256(gross) * (PIPS - core.halfSpread) / PIPS;
        if (paid <= 1) revert ZeroOutput();
        amountOut = paid - 1;
    }

    /// @notice `ceil(C_ext(I))`: the potential, Hook B's curve inside `[-c, c]` and its tangent continuation outside.
    /// @dev Inside the cap this is `CumulativePricing.positionCost` exactly. Outside, with `c` = cap:
    ///
    ///        I >  c:  C =  2^96 * V * (I * V - c^2)   / (P * (V - c)^2)
    ///        I < -c:  C = -2^96 * V * (|I| * V + c^2) / (P * (V + c)^2)
    ///
    ///      Both equal `C(+-c)` at the edge. The denominator `P * (V -+ c)^2` can reach 2^350, so each branch divides
    ///      in two exact steps, using `ceil(ceil(x / d1) / d2) = ceil(x / (d1 * d2))` for positive integers (and the
    ///      same with floor). The positive branch rounds up; the negative branch is minus a floor, i.e. also rounded
    ///      toward +infinity. Overflow, for `V <= 2^95 - 1`, `c < 0.3 V`, `|I| < 2^127`, `P < 2^160`: `I * V < 2^222`,
    ///      `V * 2^96 < 2^191`, so FullMath's product is below 2^413; the first quotient is about
    ///      `2^96 * |I| * (V / (V -+ c))^2 < 2^225`.
    ///
    ///      Example: `V` = 1,000, `c` = 100, `P` = 2^96 (1:1): `C(100)` = 111.11; `C(200)` = 111.11 + 100 * (1,000 /
    ///      900)^2 = 234.57.
    /// @param i Inventory, raw currency1 (signed). `|i| < 2^127`.
    /// @param v Depth, raw currency1. At most `2^95 - 1`.
    /// @param p Price, Q64.96. Non-zero, below 2^160.
    /// @param c Cap, raw currency1. Below `0.3 * v`.
    /// @return The potential, raw currency0, rounded toward +infinity.
    function extCost(int256 i, uint256 v, uint256 p, uint256 c) internal pure returns (int256) {
        // c < 2^95: the casts are safe.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 ci = int256(c);
        if (i >= -ci && i <= ci) return CumulativePricing.positionCost(i, v, p);
        if (i > ci) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 y = FullMath.mulDivRoundingUp(uint256(i) * v - c * c, v * FixedPoint96.Q96, (v - c) * (v - c));
            // y < 2^225: the result fits int256.
            // forge-lint: disable-next-line(unsafe-typecast)
            return int256(y / p + (y % p == 0 ? 0 : 1));
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 z = FullMath.mulDiv(uint256(-i) * v + c * c, v * FixedPoint96.Q96, (v + c) * (v + c));
        // forge-lint: disable-next-line(unsafe-typecast)
        return -int256(z / p);
    }

    /// @notice The largest `I` with `extCost(I) <= t`: the exact inverse of `extCost`, for `t < extCost(c + 1)`.
    /// @dev For integer `t`, `ceil(C) <= t` exactly when `C <= t`. If `t >= extCost(-c)` the answer is in `[-c, c]` and
    ///      `CumulativePricing.positionForCost` returns it (its overflow precondition holds because `t` is below the
    ///      cost of `c + 1`). Below `extCost(-c)` the answer is on the linear part: the smallest `y = -I` with
    ///      `2^96 * V * (y * V + c^2) >= -t * P * (V + c)^2`, which is
    ///      `y = ceil((ceil(-t * P * (V + c)^2 / (2^96 * V)) - c^2) / V)` (two exact steps as in `extCost`).
    ///      Overflow: `-t * P` is about `2^96 * y * (V / (V + c))^2 < 2^224` for `y < 2^127`; the checked
    ///      multiplication reverts on anything larger.
    /// @param t Target potential, raw currency0.
    /// @param v Depth.
    /// @param p Price, Q64.96.
    /// @param c Cap.
    /// @return The largest inventory whose potential is at most `t`.
    function extPositionForCost(int256 t, uint256 v, uint256 p, uint256 c) internal pure returns (int256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        if (t >= extCost(-int256(c), v, p, c)) return CumulativePricing.positionForCost(t, v, p);
        // t < extCost(-c) < 0 here.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 z = FullMath.mulDivRoundingUp(uint256(-t) * p, (v + c) * (v + c), FixedPoint96.Q96 * v);
        // z > c^2 on this branch (the answer lies below -c).
        uint256 y = Math.ceilDiv(z - c * c, v);
        // y < 2^127 for every reachable target: the cast is safe.
        // forge-lint: disable-next-line(unsafe-typecast)
        return -int256(y);
    }

    /// @notice Largest inventory deviation at which the curve's skew stays inside the half-spread.
    /// @dev Returns the largest `c` with both
    ///
    ///        (1 - h) * (V / (V - c))^2 <= 1 - hMin   <=>  (V - c)^2 * (1e6 - hMin) >= V^2 * (1e6 - h)
    ///        (1 + h) * (V / (V + c))^2 >= 1 + hMin   <=>  (V + c)^2 * (1e6 + hMin) <= V^2 * (1e6 + h)
    ///
    ///      i.e. the bid at `+c` is at most `P(1 - hMin)` and the ask at `-c` at least `P(1 + hMin)`. Each side starts
    ///      from an integer square root (at most two units from the answer) and corrects it; the ask side is always
    ///      the tighter one. Returns 0 if `h <= hMin`. Overflow: `V^2 * (1e6 + h) < 2^190 * 2^21`.
    ///
    ///      Example: `V` = 158,001,289 tokens, `h` = 2,000, `hMin` = 100 pips: 150,015 tokens.
    /// @param v Depth, raw currency1. At most `2^95 - 1`.
    /// @param h Half-spread, pips. Below 1e6.
    /// @param hMin Minimum edge, pips.
    /// @return The cap, raw currency1.
    function straddleCap(uint256 v, uint256 h, uint256 hMin) internal pure returns (uint256) {
        if (h <= hMin || v == 0) return 0;
        uint256 vv = v * v;
        // Bid side: smallest r = V - c with r^2 (1e6 - hMin) >= V^2 (1e6 - h).
        uint256 num = vv * (PIPS - h);
        uint256 den = PIPS - hMin;
        uint256 r = Math.sqrt(num / den);
        while (r * r * den < num) {
            ++r;
        }
        // Ask side: largest s = V + c with s^2 (1e6 + hMin) <= V^2 (1e6 + h).
        uint256 num2 = vv * (PIPS + h);
        uint256 den2 = PIPS + hMin;
        uint256 s = Math.sqrt(num2 / den2);
        while ((s + 1) * (s + 1) * den2 <= num2) {
            ++s;
        }
        while (s * s * den2 > num2) {
            --s;
        }
        uint256 cBid = v - r;
        if (s <= v) return 0;
        uint256 cAsk = s - v;
        return cBid < cAsk ? cBid : cAsk;
    }
}
