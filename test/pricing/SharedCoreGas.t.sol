// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

import {InventoryPricing} from "../../src/pricing/InventoryPricing.sol";
import {StrategyPricing} from "../../src/pricing/StrategyPricing.sol";
import {PricingHarness} from "./PricingHarness.sol";

/// @notice Gas of the shared core and the two strategies, measured inside one call (no external-call overhead), on the
///         calibrated configuration of a balanced 1,000,000-token vault. Logged for the report; asserts only loose
///         upper bounds so that a large regression is visible.
contract SharedCoreGasTest is Test {
    PricingHarness internal h;
    InventoryPricing.Config internal cfg;

    function setUp() public {
        h = new PricingHarness();
        // Band mode, 5 bp base spread, 1 bp edge, 15% cap: depth per share from simulations/mm (depth_per_share_for).
        cfg = InventoryPricing.Config(1e18, 750_225_007_501_078_307_485, 2 ** 95 - 1, 500, 100, 40_000, 150_000, true);
    }

    function test_gas_strategies() public {
        uint256 s = 1_000_000 ether;
        StrategyPricing.ActivityFee memory f = StrategyPricing.ActivityFee(0, 2000, 20_000 ether, 20_000 ether);
        uint256 bAsk = h.gasHookB(cfg, s, s, FixedPoint96.Q96, true, 1000 ether);
        uint256 bBid = h.gasHookB(cfg, s, s, FixedPoint96.Q96, false, 1000 ether);
        uint256 aAsk = h.gasHookA(cfg, s, s, FixedPoint96.Q96, f, true, 1000 ether);
        uint256 aBid = h.gasHookA(cfg, s, s, FixedPoint96.Q96, f, false, 1000 ether);
        emit log_named_uint("Hook B strategy, vault sells currency1 (core state + quote)", bAsk);
        emit log_named_uint("Hook B strategy, vault buys currency1", bBid);
        emit log_named_uint("Hook A strategy, vault sells currency1", aAsk);
        emit log_named_uint("Hook A strategy, vault buys currency1", aBid);
        assertLt(bAsk, 20_000);
        assertLt(aAsk, 25_000);
    }
}
