// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

/// @notice Paths of the production build artifacts, and a check that deployed code is exactly one of them.
/// @dev Why paths and not names. A test file that imports the vault source is compiled, together with everything it
///      imports, under the vault's optimizer profile (200 runs). In such a file `deployCode("HookA_DynamicFee.sol:
///      HookA_DynamicFee")` resolves to the hook's 200-run build, not to the 44,444,444-run build that would be
///      deployed. Deploying from an explicit artifact file avoids that: the bytecode is whatever that file holds,
///      whatever profile the calling test was compiled under. Reading `out/` needs the read-only `fs_permissions`
///      entry in foundry.toml.
///
///      Which file is the production build. The default profile writes `<Name>.json`; a second profile writes
///      `<Name>.<profile>.json`. The PoolManager is compiled under both profiles and Foundry then names the default
///      build `PoolManager.default.json`; if only the default build exists it is `PoolManager.json`. The vault has a
///      single artifact (its own restriction). `ProductionBuilds.t.sol` reads the optimizer settings recorded in each
///      file, so a wrong file fails a test rather than silently testing the wrong build.
library ProductionArtifacts {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string internal constant VAULT = "out/SharedCommitmentVault.sol/SharedCommitmentVault.json";
    string internal constant HOOK_A = "out/HookA_DynamicFee.sol/HookA_DynamicFee.json";
    string internal constant HOOK_B = "out/HookB_BoundedImpact.sol/HookB_BoundedImpact.json";
    string internal constant LENS = "out/VaultLens.sol/VaultLens.json";

    /// @dev Production optimizer runs from foundry.toml: the vault's compilation restriction and the default.
    uint256 internal constant VAULT_RUNS = 200;
    uint256 internal constant DEFAULT_RUNS = 44_444_444;

    /// @dev One immutable placeholder in an artifact's runtime code. Fields in alphabetical order, as
    ///      `vm.parseJson` decodes objects.
    struct ImmutableRef {
        uint256 length;
        uint256 start;
    }

    function poolManager() internal view returns (string memory) {
        string memory both = "out/PoolManager.sol/PoolManager.default.json";
        return VM.exists(both) ? both : "out/PoolManager.sol/PoolManager.json";
    }

    /// @dev The authorization module, compiled with the default settings. Like the PoolManager it is also compiled
    ///      under the vault's profile when a test file imports both, and the default build is then the
    ///      `.default.json` file.
    function authModule() internal view returns (string memory) {
        string memory both = "out/CuratorAuthorization.sol/CuratorAuthorization.default.json";
        return VM.exists(both) ? both : "out/CuratorAuthorization.sol/CuratorAuthorization.json";
    }

    /// @notice keccak256 of `code` with every immutable slot of `artifact` zeroed.
    /// @dev Immutables (the PoolManager and vault addresses in a hook, the pair in the vault) are written into the
    ///      runtime code at deployment, so deployed code differs from the artifact's `deployedBytecode` exactly at
    ///      the byte ranges listed in `deployedBytecode.immutableReferences`, where the artifact holds zeros. Zeroing
    ///      the same ranges in the deployed code makes the two comparable byte for byte: equal hashes mean the
    ///      deployed code is this artifact with some values for its immutables.
    function maskedRuntimeHash(bytes memory code, string memory artifact) internal view returns (bytes32) {
        string memory json = VM.readFile(artifact);
        string memory base = ".deployedBytecode.immutableReferences";
        string[] memory ids;
        // An artifact without immutables (the lens) stores `null` here, which has no keys.
        try VM.parseJsonKeys(json, base) returns (string[] memory keys) {
            ids = keys;
        } catch {}
        for (uint256 i; i < ids.length; ++i) {
            ImmutableRef[] memory refs =
                abi.decode(VM.parseJson(json, string.concat(base, ".", ids[i])), (ImmutableRef[]));
            for (uint256 j; j < refs.length; ++j) {
                for (uint256 k; k < refs[j].length; ++k) {
                    code[refs[j].start + k] = 0;
                }
            }
        }
        return keccak256(code);
    }

    /// @notice Hash of the artifact's own runtime code (immutables already zero there).
    function artifactRuntimeHash(string memory artifact) internal view returns (bytes32) {
        return keccak256(VM.getDeployedCode(artifact));
    }

    /// @notice Reverts unless `deployed` runs exactly the runtime code of `artifact` (immutables masked) and the
    ///         artifact records the production compiler settings: `runs` optimizer runs, via-IR, cancun and no
    ///         metadata hash.
    function requireProduction(address deployed, string memory artifact, uint256 runs) internal view {
        string memory json = VM.readFile(artifact);
        require(VM.parseJsonUint(json, ".metadata.settings.optimizer.runs") == runs, string.concat(artifact, ": runs"));
        require(VM.parseJsonBool(json, ".metadata.settings.optimizer.enabled"), string.concat(artifact, ": optimizer"));
        require(VM.parseJsonBool(json, ".metadata.settings.viaIR"), string.concat(artifact, ": viaIR"));
        require(
            keccak256(bytes(VM.parseJsonString(json, ".metadata.settings.evmVersion"))) == keccak256("cancun"),
            string.concat(artifact, ": evmVersion")
        );
        require(
            keccak256(bytes(VM.parseJsonString(json, ".metadata.settings.metadata.bytecodeHash"))) == keccak256("none"),
            string.concat(artifact, ": bytecodeHash")
        );
        require(
            maskedRuntimeHash(deployed.code, artifact) == artifactRuntimeHash(artifact),
            string.concat(artifact, ": deployed runtime code differs")
        );
    }
}
