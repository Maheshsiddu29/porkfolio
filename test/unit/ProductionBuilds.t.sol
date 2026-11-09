// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {ProductionArtifacts} from "../utils/ProductionArtifacts.sol";

/// @notice The shared functional fixture runs the production builds of every deployable contract.
/// @dev Every test that extends `VaultTestBase` (unit, integration, security, fuzz and the invariant campaign) uses
///      this fixture. If this test passes, those tests exercised the vault built at 2,000 runs, the hooks, the lens and
///      the authorization module at 44,444,444 runs and the pinned PoolManager at its upstream setting, each byte for byte as recorded in its
///      artifact file (immutables masked). Test-only contracts the fixture also deploys (routers, malicious hooks)
///      are compiled into the test files and are never deployed by the project.
contract ProductionBuildsTest is VaultTestBase {
    function test_fixtureDeploysProductionBuilds() public view {
        ProductionArtifacts.requireProduction(address(vault), ProductionArtifacts.VAULT, ProductionArtifacts.VAULT_RUNS);
        ProductionArtifacts.requireProduction(
            address(hookA), ProductionArtifacts.HOOK_A, ProductionArtifacts.DEFAULT_RUNS
        );
        ProductionArtifacts.requireProduction(
            address(hookB), ProductionArtifacts.HOOK_B, ProductionArtifacts.DEFAULT_RUNS
        );
        ProductionArtifacts.requireProduction(address(lens), ProductionArtifacts.LENS, ProductionArtifacts.DEFAULT_RUNS);
        ProductionArtifacts.requireProduction(
            address(manager), ProductionArtifacts.poolManager(), ProductionArtifacts.DEFAULT_RUNS
        );
        ProductionArtifacts.requireProduction(
            address(auth), ProductionArtifacts.authModule(), ProductionArtifacts.DEFAULT_RUNS
        );
    }

    /// @notice Size limits on the deployed production code: the vault keeps at least 2,048 bytes under the EIP-170
    ///         runtime limit (24,576), the project's margin for later fixes; every other production contract fits
    ///         EIP-170. Deployed code has the artifact's length (immutables are filled in place), so this is the size
    ///         that would be deployed.
    function test_productionSizesWithinLimits() public view {
        assertLe(address(vault).code.length, 24_576 - 2048, "vault margin below 2,048 bytes");
        address[4] memory others = [address(hookA), address(hookB), address(lens), address(auth)];
        for (uint256 i; i < others.length; ++i) {
            assertLe(others[i].code.length, 24_576, "over EIP-170");
        }
    }

    /// @notice The check is not vacuous: the 2,000-run hook build that a by-name `deployCode` would return inside this
    ///         file differs from the production build, and the masked comparison tells them apart.
    function test_maskedHashDistinguishesBuilds() public view {
        string memory testBuild = "out/HookA_DynamicFee.sol/HookA_DynamicFee.vault.json";
        if (!vm.exists(testBuild)) return; // removed by a `--skip test` build; nothing to compare
        assertTrue(
            ProductionArtifacts.maskedRuntimeHash(address(hookA).code, ProductionArtifacts.HOOK_A)
                != ProductionArtifacts.artifactRuntimeHash(testBuild),
            "production and test builds are indistinguishable"
        );
        assertEq(
            ProductionArtifacts.maskedRuntimeHash(address(hookA).code, ProductionArtifacts.HOOK_A),
            ProductionArtifacts.artifactRuntimeHash(ProductionArtifacts.HOOK_A)
        );
    }
}
