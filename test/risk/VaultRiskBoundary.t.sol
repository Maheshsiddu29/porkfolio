// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

import {VaultRiskBoundary} from "../../src/risk/VaultRiskBoundary.sol";

/// @notice External wrapper so tests can catch the library's refusals.
contract RiskHarness {
    function checkInventory(uint256 holding, uint256 out, uint256 floor_) external pure {
        VaultRiskBoundary.checkInventory(holding, out, floor_);
    }

    function checkUncertainty(uint256 u, uint256 maxU) external pure {
        VaultRiskBoundary.checkUncertainty(u, maxU);
    }
}

/// @notice The vault risk boundary's equations: equal to the Python model on 300 vectors, and the properties the
///         proposed vault relies on, fuzzed on the Solidity alone.
contract VaultRiskBoundaryTest is Test {
    uint256 internal constant PIPS = 1_000_000;
    RiskHarness internal h;

    function setUp() public {
        h = new RiskHarness();
    }

    /// @notice Every floor, inventory floor and refusal of vault_risk_v1.json (its CSV view) is reproduced exactly.
    function test_vectors_vaultRisk() public view {
        string[] memory rows = vm.split(vm.readFile("simulations/mm/vectors/vault_risk_v1.csv"), "\n");
        assertEq(rows.length, 300);
        for (uint256 r; r < rows.length; ++r) {
            string[] memory f = vm.split(rows[r], ",");
            string memory where = string.concat("risk row ", vm.toString(r));
            (uint256 f0, uint256 f1) =
                VaultRiskBoundary.dynamicFloors(vm.parseUint(f[0]), vm.parseUint(f[1]), vm.parseUint(f[2]));
            assertEq(f0, vm.parseUint(f[3]), where);
            assertEq(f1, vm.parseUint(f[4]), where);
            uint256 l = VaultRiskBoundary.inventoryFloor(vm.parseUint(f[5]), vm.parseUint(f[6]), vm.parseUint(f[7]));
            assertEq(l, vm.parseUint(f[8]), where);
            (bool ok,) =
                address(h).staticcall(abi.encodeCall(h.checkInventory, (vm.parseUint(f[9]), vm.parseUint(f[10]), l)));
            assertEq(ok, vm.parseUint(f[11]) == 0, where);
        }
    }

    /// @notice At every reference the dynamic floors satisfy the directional-consistency rule with room to spare:
    ///         F0 * F1 >= 2^192 * ((1e6 + u + e) / 1e6)^2. So no cycle of fills at one reference can profit, without
    ///         any owner-set price.
    function testFuzz_floorsConsistent(uint256 p, uint256 u, uint256 e) public pure {
        p = bound(p, 1, type(uint160).max);
        u = bound(u, 0, 100_000);
        e = bound(e, 0, 10_000);
        (uint256 f0, uint256 f1) = VaultRiskBoundary.dynamicFloors(p, u, e);
        uint256 w = PIPS + u + e;
        // f0 * f1 / 2^192 >= (w / 1e6)^2, compared without overflow: f0 * f1 / 2^192 computed in 512 bits.
        uint256 lhs = FullMath.mulDiv(f0, f1, FixedPoint96.Q96);
        uint256 rhs = FullMath.mulDivRoundingUp(FixedPoint96.Q96 * w, w, PIPS * PIPS);
        assertGe(lhs + 1, rhs);
    }

    /// @notice The one-direction floor the vault uses is exactly the matching `dynamicFloors` result, so computing only
    ///         the needed direction changes no fill.
    function testFuzz_dynamicFloorEqualsPair(uint256 p, uint256 u, uint256 e) public pure {
        p = bound(p, 1, type(uint160).max);
        u = bound(u, 0, 1e6);
        e = bound(e, 0, 1e6);
        (uint256 f0, uint256 f1) = VaultRiskBoundary.dynamicFloors(p, u, e);
        assertEq(VaultRiskBoundary.dynamicFloor(p, u, e, false), f0);
        assertEq(VaultRiskBoundary.dynamicFloor(p, u, e, true), f1);
    }

    /// @notice The inventory floor is never below the exact value (rounded up) and scales with the share supply.
    function testFuzz_inventoryFloorRoundsUp(uint256 s, uint256 tau, uint256 k) public pure {
        s = bound(s, 1, 2 ** 127);
        tau = bound(tau, 1, 2 ** 100);
        k = bound(k, 0, PIPS);
        uint256 l = VaultRiskBoundary.inventoryFloor(s, tau, k);
        assertGe(l * 1e18 * PIPS, s * tau * (PIPS - k));
        assertLt((l - (l > 0 ? 1 : 0)) * 1e18 * PIPS, s * tau * (PIPS - k) + (l > 0 ? 0 : 1));
    }

    /// @notice The capital-at-risk invariant on the Solidity check: whatever outflows an adversary requests, each one
    ///         accepted leaves the holding at or above the floor, so a run of accepted outflows never ends below it.
    function testFuzz_holdingNeverEndsBelowFloor(uint256 holding, uint256 floor_, uint256[8] memory outs) public view {
        holding = bound(holding, 0, 2 ** 127);
        floor_ = bound(floor_, 0, holding);
        for (uint256 k; k < 8; ++k) {
            uint256 out = bound(outs[k], 0, holding);
            (bool ok,) = address(h).staticcall(abi.encodeCall(h.checkInventory, (holding, out, floor_)));
            if (ok) holding -= out;
            assertGe(holding, floor_);
        }
    }

    function test_uncertaintyBreaker() public {
        h.checkUncertainty(8200, 8200);
        vm.expectRevert(abi.encodeWithSelector(VaultRiskBoundary.UncertaintyTooHigh.selector, 8201, 8200));
        h.checkUncertainty(8201, 8200);
    }
}
