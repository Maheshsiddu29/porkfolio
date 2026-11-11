// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {InventoryPricing} from "../../src/pricing/InventoryPricing.sol";
import {StrategyPricing} from "../../src/pricing/StrategyPricing.sol";
import {ReferenceBracket} from "../../src/oracle/ReferenceBracket.sol";
import {PricingHarness} from "./PricingHarness.sol";

/// @notice The Solidity pricing libraries against the Python model's integer vectors, case by case: every output, every
///         state value and every refusal reason must be equal. The cases come from the JSON files the model writes
///         (`simulations/mm/vectors.py`, `vectors_core.py`), read through their CSV views (`vectors_csv.py`), so all
///         implementations share one source of truth.
/// @dev Passing here shows the two implementations compute the same integers on these inputs. It does not show either
///      is economically right; that is what the property tests are for.
contract SharedCoreVectorsTest is Test {
    PricingHarness internal h;

    function setUp() public {
        h = new PricingHarness();
    }

    function _rows(string memory file) internal view returns (string[] memory) {
        return vm.split(vm.readFile(string.concat("simulations/mm/vectors/", file)), "\n");
    }

    function _u(string memory s) internal pure returns (uint256) {
        return vm.parseUint(s);
    }

    function _i(string memory s) internal pure returns (int256) {
        return vm.parseInt(s);
    }

    function _cfg(string[] memory f, uint256 o) internal pure returns (InventoryPricing.Config memory c) {
        c = InventoryPricing.Config(
            _u(f[o]),
            _u(f[o + 1]),
            _u(f[o + 2]),
            _u(f[o + 3]),
            _u(f[o + 4]),
            _u(f[o + 5]),
            _u(f[o + 6]),
            _u(f[o + 7]) == 1
        );
    }

    function _selectorFor(string memory name) internal pure returns (bytes4) {
        bytes32 k = keccak256(bytes(name));
        if (k == keccak256("ZeroInput")) return InventoryPricing.ZeroInput.selector;
        if (k == keccak256("AmountTooLarge")) return InventoryPricing.AmountTooLarge.selector;
        if (k == keccak256("SpreadTooWide")) return InventoryPricing.SpreadTooWide.selector;
        if (k == keccak256("NoDepth")) return InventoryPricing.NoDepth.selector;
        if (k == keccak256("InventoryLimit")) return InventoryPricing.InventoryLimit.selector;
        if (k == keccak256("ZeroOutput")) return InventoryPricing.ZeroOutput.selector;
        revert(string.concat("unmapped revert ", name));
    }

    function _selectorForCode(uint256 code) internal pure returns (bytes4) {
        if (code == 1) return InventoryPricing.ZeroInput.selector;
        if (code == 2) return InventoryPricing.AmountTooLarge.selector;
        if (code == 5) return ReferenceBracket.ReferenceDivergence.selector;
        if (code == 7) return InventoryPricing.SpreadTooWide.selector;
        if (code == 8) return InventoryPricing.NoDepth.selector;
        if (code == 9) return InventoryPricing.InventoryLimit.selector;
        if (code == 10) return InventoryPricing.ZeroOutput.selector;
        if (code == 11) return StrategyPricing.TradeImpactExceeded.selector;
        if (code == 12) return ReferenceBracket.DegenerateBracket.selector;
        revert("unmapped code");
    }

    function _sel(bytes memory reason) internal pure returns (bytes4 s) {
        if (reason.length >= 4) s = bytes4(reason);
    }

    /// @notice All 212 single-strategy quotes of inventory_quote_v1.json (Phase 1B-4) through the Solidity core.
    /// @dev Columns: zfo, amountIn, n1, shares, price, uncertainty, config x7, revert name, out, iBefore, iAfter, h,
    ///      cap, depth.
    function test_vectors_inventoryQuoteV1() public view {
        string[] memory rows = _rows("inventory_quote_v1.csv");
        assertEq(rows.length, 212);
        for (uint256 r; r < rows.length; ++r) {
            string[] memory f = vm.split(rows[r], ",");
            bytes memory call = abi.encodeCall(
                h.quoteInventory, (_cfg(f, 6), _u(f[2]), _u(f[3]), _u(f[4]), _u(f[5]), _u(f[0]) == 1, _u(f[1]))
            );
            (bool ok, bytes memory ret) = address(h).staticcall(call);
            string memory where = string.concat("v1 row ", vm.toString(r));
            if (keccak256(bytes(f[14])) != keccak256("-")) {
                assertFalse(ok, where);
                assertEq(_sel(ret), _selectorFor(f[14]), where);
                continue;
            }
            assertTrue(ok, where);
            (uint256 out, int256 ib, int256 ia, uint256 hs, uint256 cap, uint256 depth) =
                abi.decode(ret, (uint256, int256, int256, uint256, uint256, uint256));
            assertEq(out, _u(f[15]), where);
            assertEq(ib, _i(f[16]), where);
            assertEq(ia, _i(f[17]), where);
            assertEq(hs, _u(f[18]), where);
            assertEq(cap, _u(f[19]), where);
            assertEq(depth, _u(f[20]), where);
        }
    }

    /// @notice All 240 strategy quotes of shared_core_v1.json (Hook A and Hook B, both directions, refusals included).
    /// @dev Columns: hook, zfo, amountIn, n1, shares, price, uncertainty, config x7, strategy x5, revert code, out,
    ///      iAfter, fee, newLevel, cap.
    function test_vectors_strategies() public view {
        string[] memory rows = _rows("shared_core_strategies_v1.csv");
        assertEq(rows.length, 240);
        for (uint256 r; r < rows.length; ++r) {
            string[] memory f = vm.split(rows[r], ",");
            bool zfo = _u(f[1]) == 1;
            bytes memory call;
            if (keccak256(bytes(f[0])) == keccak256("A")) {
                StrategyPricing.ActivityFee memory fee =
                    StrategyPricing.ActivityFee(_u(f[15]), _u(f[16]), _u(f[17]), _u(f[18]));
                call = abi.encodeCall(
                    h.hookA, (_cfg(f, 7), _u(f[3]), _u(f[4]), _u(f[5]), _u(f[6]), fee, _u(f[19]), zfo, _u(f[2]))
                );
            } else {
                call = abi.encodeCall(
                    h.hookB, (_cfg(f, 7), _u(f[3]), _u(f[4]), _u(f[5]), _u(f[6]), _u(f[15]), _u(f[16]), zfo, _u(f[2]))
                );
            }
            (bool ok, bytes memory ret) = address(h).staticcall(call);
            string memory where = string.concat("strategy row ", vm.toString(r));
            uint256 code = _u(f[20]);
            if (code != 0) {
                assertFalse(ok, where);
                assertEq(_sel(ret), _selectorForCode(code), where);
                continue;
            }
            assertTrue(ok, where);
            (StrategyPricing.Quote memory q, uint256 cap) = abi.decode(ret, (StrategyPricing.Quote, uint256));
            assertEq(q.amountOut, _u(f[21]), where);
            assertEq(q.inventoryAfter, _i(f[22]), where);
            assertEq(q.fee, _u(f[23]), where);
            assertEq(q.newLevel, _u(f[24]), where);
            assertEq(cap, _u(f[25]), where);
        }
    }

    /// @notice All 61 bracket cases: pair brackets from two USD legs, and mid/uncertainty of an intersection.
    /// @dev Columns: a0, a1, d0, d1, e, low, high, intersection low, intersection high, revert code, mid, uncertainty.
    function test_vectors_brackets() public view {
        string[] memory rows = _rows("shared_core_brackets_v1.csv");
        assertEq(rows.length, 61);
        for (uint256 r; r < rows.length; ++r) {
            string[] memory f = vm.split(rows[r], ",");
            string memory where = string.concat("bracket row ", vm.toString(r));
            (uint256 lo, uint256 hi) = h.pairBracket(_u(f[0]), _u(f[1]), _u(f[2]), _u(f[3]), _i(f[4]));
            assertEq(lo, _u(f[5]), where);
            assertEq(hi, _u(f[6]), where);
            (bool ok, bytes memory ret) =
                address(h).staticcall(abi.encodeCall(h.midAndUncertainty, (_u(f[7]), _u(f[8]))));
            uint256 code = _u(f[9]);
            if (code != 0) {
                assertFalse(ok, where);
                assertEq(_sel(ret), _selectorForCode(code), where);
                continue;
            }
            (uint256 m, uint256 u) = abi.decode(ret, (uint256, uint256));
            assertEq(m, _u(f[10]), where);
            assertEq(u, _u(f[11]), where);
        }
    }
}
