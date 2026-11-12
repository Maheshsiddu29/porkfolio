// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {VaultGovernor} from "../src/governance/VaultGovernor.sol";
import {DeploySystem} from "./DeploySystem.s.sol";

/// @title ExecuteQueued
/// @notice Stage 2 of the rehearsal: the governor's admin executes the hook configuration that `DeploySystem` queued,
///         once DELAY has passed. Each call is the exact calldata that was queued (`DeploySystem.hookCalls`), so a
///         mismatch is `NotQueued`, not a different configuration. Sepolia or local only.
/// @dev Reads the deployment from the environment (`DeploySystem.deploymentFromEnv`). Run as `GOV_ADMIN`.
contract ExecuteQueued is Script {
    function run() external {
        DeploySystem ds = new DeploySystem();
        DeploySystem.Deployment memory d = ds.deploymentFromEnv();
        vm.startBroadcast(vm.envAddress("GOV_ADMIN"));
        execute(ds, d);
        vm.stopBroadcast();
    }

    /// @notice Executes every queued hook call, in order. Reverts with the governor's error if one is not ready.
    function execute(DeploySystem ds, DeploySystem.Deployment memory d) public {
        if (block.chainid != 1301 && block.chainid != 31_337) revert("ExecuteQueued: Sepolia or local only");
        bytes[] memory calls = ds.hookCalls(d);
        for (uint256 i; i < calls.length; ++i) {
            address target = i < 2 ? d.hookA : d.hookB;
            VaultGovernor(d.governor).execute(target, calls[i]);
            console2.log("executed hook call", i, target);
        }
    }
}
