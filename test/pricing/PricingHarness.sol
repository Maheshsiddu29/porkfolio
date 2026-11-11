// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {InventoryPricing} from "../../src/pricing/InventoryPricing.sol";
import {StrategyPricing} from "../../src/pricing/StrategyPricing.sol";
import {ReferenceBracket} from "../../src/oracle/ReferenceBracket.sol";

/// @notice External wrappers around the pricing libraries, so tests can catch each refusal and compare it with the
///         Python model's, and measure gas per call. Test-only.
contract PricingHarness {
    /// @notice The single-strategy inventory quote of `simulations/mm/model.py` (`quote_inventory`): amount checks,
    ///         core state, then `ask(amountIn)` or `bid(amountIn, amountIn)`.
    function quoteInventory(
        InventoryPricing.Config memory c,
        uint256 n1,
        uint256 shares,
        uint256 priceX96,
        uint256 uncertainty,
        bool zeroForOne,
        uint256 amountIn
    ) external pure returns (uint256 out, int256 iBefore, int256 iAfter, uint256 h, uint256 cap, uint256 depth) {
        if (amountIn == 0) revert InventoryPricing.ZeroInput();
        if (amountIn > InventoryPricing.MAX_AMOUNT) revert InventoryPricing.AmountTooLarge();
        InventoryPricing.Core memory core = InventoryPricing.coreState(c, n1, shares, priceX96, uncertainty);
        (out, iAfter) =
            zeroForOne ? InventoryPricing.ask(core, amountIn) : InventoryPricing.bid(core, amountIn, amountIn);
        return (out, core.inventory, iAfter, core.halfSpread, core.cap, core.depth);
    }

    function hookA(
        InventoryPricing.Config memory c,
        uint256 n1,
        uint256 shares,
        uint256 priceX96,
        uint256 uncertainty,
        StrategyPricing.ActivityFee memory fee,
        uint256 levelNow,
        bool zeroForOne,
        uint256 amountIn
    ) external pure returns (StrategyPricing.Quote memory q, uint256 cap) {
        InventoryPricing.Core memory core = InventoryPricing.coreState(c, n1, shares, priceX96, uncertainty);
        q = StrategyPricing.hookA(core, fee, levelNow, zeroForOne, amountIn);
        cap = core.cap;
    }

    function hookB(
        InventoryPricing.Config memory c,
        uint256 n1,
        uint256 shares,
        uint256 priceX96,
        uint256 uncertainty,
        uint256 markup,
        uint256 maxImpact,
        bool zeroForOne,
        uint256 amountIn
    ) external pure returns (StrategyPricing.Quote memory q, uint256 cap) {
        InventoryPricing.Core memory core = InventoryPricing.coreState(c, n1, shares, priceX96, uncertainty);
        q = StrategyPricing.hookB(core, markup, maxImpact, zeroForOne, amountIn);
        cap = core.cap;
    }

    function ask(InventoryPricing.Core memory core, uint256 netIn) external pure returns (uint256, int256) {
        return InventoryPricing.ask(core, netIn);
    }

    function pairBracket(uint256 a0, uint256 a1, uint256 d0, uint256 d1, int256 e)
        external
        pure
        returns (uint256, uint256)
    {
        return ReferenceBracket.pairBracket(a0, a1, d0, d1, e);
    }

    function midAndUncertainty(uint256 low, uint256 high) external pure returns (uint256, uint256) {
        return ReferenceBracket.midAndUncertainty(low, high);
    }

    function extCost(int256 i, uint256 v, uint256 p, uint256 c) external pure returns (int256) {
        return InventoryPricing.extCost(i, v, p, c);
    }

    function extPositionForCost(int256 t, uint256 v, uint256 p, uint256 c) external pure returns (int256) {
        return InventoryPricing.extPositionForCost(t, v, p, c);
    }

    function straddleCap(uint256 v, uint256 h, uint256 hMin) external pure returns (uint256) {
        return InventoryPricing.straddleCap(v, h, hMin);
    }

    /// @notice Gas of one Hook B quote from vault state to output, measured inside the call.
    function gasHookB(InventoryPricing.Config memory c, uint256 n1, uint256 shares, uint256 p, bool zfo, uint256 amt)
        external
        view
        returns (uint256 gasUsed)
    {
        uint256 g = gasleft();
        InventoryPricing.Core memory core = InventoryPricing.coreState(c, n1, shares, p, 0);
        StrategyPricing.hookB(core, 0, 999_999, zfo, amt);
        gasUsed = g - gasleft();
    }

    /// @notice Gas of one Hook A quote from vault state to output, measured inside the call.
    function gasHookA(
        InventoryPricing.Config memory c,
        uint256 n1,
        uint256 shares,
        uint256 p,
        StrategyPricing.ActivityFee memory fee,
        bool zfo,
        uint256 amt
    ) external view returns (uint256 gasUsed) {
        uint256 g = gasleft();
        InventoryPricing.Core memory core = InventoryPricing.coreState(c, n1, shares, p, 0);
        StrategyPricing.hookA(core, fee, 1000 ether, zfo, amt);
        gasUsed = g - gasleft();
    }
}
