// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

import {CumulativePricing} from "../hooks/CumulativePricing.sol";
import {InventoryPricing} from "./InventoryPricing.sol";

/// @title StrategyPricing
/// @notice The two hook strategies on top of the shared core: Hook A (inventory-aware cumulative activity fee) and
///         Hook B (inventory-aware bounded impact). Both price through `InventoryPricing`, so both pay the core
///         half-spread and both stop at the same inventory cap.
/// @dev The rule that makes heterogeneous strategies safe together: a strategy may only add to the core price, never
///      subtract from it. Each one takes a fee from the trader's input (rounded toward the vault) and hands the rest
///      to `InventoryPricing.ask` or `bid`. Because the core's cap is computed for the core half-spread, a larger
///      total spread keeps every quote further on the vault's side of the reference. So cycles through any mix of
///      strategies at a fixed reference still lose, and no strategy can carry the inventory past the shared cap.
///
///      What a strategy may keep as its own state: Hook A keeps an activity level per direction (gross input,
///      decaying; the production Hook A's state). It is a price surcharge, not an inventory ledger, and it never
///      enters the core. Hook B keeps nothing.
///
///      Not guaranteed: that splitting an order across the two hooks never beats the best single hook. When Hook A's
///      fee starts below Hook B's markup and rises above it, routing the first part through A and the rest through B
///      pays less than either hook alone (counterexample in `simulations/mm/test_core.py`). That is a better route
///      between two venues; the core charge is still paid in full, and each hook's own fee telescopes on its own state.
library StrategyPricing {
    uint256 internal constant PIPS = 1_000_000;
    /// @dev Hook A's activity level is stored in 128 bits.
    uint256 internal constant MAX_LEVEL = type(uint128).max;

    /// @notice Hook A's activity fee (the production `HookA_DynamicFee` curve) on top of the core spread.
    /// @param baseFeePips Marginal fee at level 0, pips.
    /// @param maxFeePips Marginal fee at and above the scale, pips. At least `baseFeePips`, below 1e6.
    /// @param scale0 Level at which selling currency0 reaches `maxFeePips`, raw currency0. Non-zero.
    /// @param scale1 The same for selling currency1, raw currency1. Non-zero.
    struct ActivityFee {
        uint256 baseFeePips;
        uint256 maxFeePips;
        uint256 scale0;
        uint256 scale1;
    }

    /// @notice A strategy quote.
    /// @param amountOut Raw output.
    /// @param inventoryAfter Core inventory after the trade, raw currency1.
    /// @param fee Raw input units the strategy kept before the core priced the rest.
    /// @param newLevel Hook A: the activity level to store after settlement; Hook B: 0.
    struct Quote {
        uint256 amountOut;
        int256 inventoryAfter;
        uint256 fee;
        uint256 newLevel;
    }

    /// @notice Hook B refused a trade whose average price is further from the reference than its per-trade bound.
    /// @param amountOut Output the trade would get, raw.
    /// @param atReference Output at the reference mid, raw.
    error TradeImpactExceeded(uint256 amountOut, uint256 atReference);

    /// @notice Hook A: inventory-aware cumulative dynamic fee.
    /// @dev `fee = cumulativeFee(level + in) - cumulativeFee(level)` in input units (the production function, which
    ///      telescopes per direction, so splits pay the same fee); `net = in - fee` goes to the core. Selling currency0:
    ///      `InventoryPricing.ask(net)`. Selling currency1: the vault receives the whole input, so the core moves by
    ///      `in` and pays for `net` (`InventoryPricing.bid(in, net)`). The caller decays `levelNow` before the call and
    ///      stores `newLevel` only after the vault has settled the swap.
    ///
    ///      Example (1:1 reference, balanced 1,000,000-token vault, core half-spread 10 bps, fee 0 -> 30 bps over
    ///      50,000): 10,000 currency0 at level 0 pays a fee of 3 currency0 and gets 9,986.81 currency1.
    /// @param core Shared core state.
    /// @param fee Activity-fee parameters.
    /// @param levelNow Activity level in this direction after decay, raw input units.
    /// @param zeroForOne True if the trader sells currency0.
    /// @param amountIn Raw input. Non-zero, at most `2^127 - 1`.
    /// @return q The quote.
    function hookA(
        InventoryPricing.Core memory core,
        ActivityFee memory fee,
        uint256 levelNow,
        bool zeroForOne,
        uint256 amountIn
    ) internal pure returns (Quote memory q) {
        _checkAmount(amountIn);
        uint256 level = levelNow + amountIn;
        if (level > MAX_LEVEL) revert InventoryPricing.AmountTooLarge();
        uint256 k = zeroForOne ? fee.scale0 : fee.scale1;
        q.fee = CumulativePricing.cumulativeFee(level, k, fee.baseFeePips, fee.maxFeePips)
            - CumulativePricing.cumulativeFee(levelNow, k, fee.baseFeePips, fee.maxFeePips);
        q.newLevel = level;
        // fee <= amountIn (cumulativeFee charges below 100% at every level).
        uint256 net = amountIn - q.fee;
        (q.amountOut, q.inventoryAfter) =
            zeroForOne ? InventoryPricing.ask(core, net) : InventoryPricing.bid(core, amountIn, net);
    }

    /// @notice Hook B: inventory-aware bounded impact.
    /// @dev An optional flat markup on the input, `fee = in - floor(in * (1e6 - markup) / 1e6)` (rounded toward the
    ///      vault), the core's shared cap as the aggregate impact bound, and a per-trade bound: refused with
    ///      `TradeImpactExceeded` if `out * 1e6 < atReference * (1e6 - maxTradeImpact)`, where `atReference` is the
    ///      input converted at the reference mid (rounded down). The per-trade bound protects the trader from a single
    ///      large fill far from the mid; the shared cap protects the reserve.
    ///
    ///      Example (balanced vault as in `hookA`, no markup, bound 12 bps): 50,000 currency0 averages 11.5 bps from
    ///      the mid and passes; 100,000 averages 13.0 bps and is refused, although the inventory cap would allow it.
    /// @param core Shared core state.
    /// @param markupPips Flat markup, pips. Below 1e6.
    /// @param maxTradeImpactPips Largest accepted distance of the trade's average price from the mid, pips.
    /// @param zeroForOne True if the trader sells currency0.
    /// @param amountIn Raw input.
    /// @return q The quote (`newLevel` is 0).
    function hookB(
        InventoryPricing.Core memory core,
        uint256 markupPips,
        uint256 maxTradeImpactPips,
        bool zeroForOne,
        uint256 amountIn
    ) internal pure returns (Quote memory q) {
        _checkAmount(amountIn);
        uint256 net = amountIn * (PIPS - markupPips) / PIPS;
        q.fee = amountIn - net;
        uint256 atReference;
        if (zeroForOne) {
            (q.amountOut, q.inventoryAfter) = InventoryPricing.ask(core, net);
            atReference = FullMath.mulDiv(amountIn, core.priceX96, FixedPoint96.Q96);
        } else {
            (q.amountOut, q.inventoryAfter) = InventoryPricing.bid(core, amountIn, net);
            atReference = FullMath.mulDiv(amountIn, FixedPoint96.Q96, core.priceX96);
        }
        if (q.amountOut * PIPS < atReference * (PIPS - maxTradeImpactPips)) {
            revert TradeImpactExceeded(q.amountOut, atReference);
        }
    }

    function _checkAmount(uint256 amountIn) private pure {
        if (amountIn == 0) revert InventoryPricing.ZeroInput();
        if (amountIn > InventoryPricing.MAX_AMOUNT) revert InventoryPricing.AmountTooLarge();
    }
}
