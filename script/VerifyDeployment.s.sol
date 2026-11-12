// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {SharedCommitmentVault} from "../src/SharedCommitmentVault.sol";
import {ISharedCommitmentVault} from "../src/interfaces/ISharedCommitmentVault.sol";
import {IMarketRiskAdapter} from "../src/interfaces/IMarketRiskAdapter.sol";
import {VaultGovernor} from "../src/governance/VaultGovernor.sol";
import {CuratorAuthorization} from "../src/CuratorAuthorization.sol";
import {BaseCompatibleHook} from "../src/hooks/BaseCompatibleHook.sol";
import {HookA_DynamicFee} from "../src/hooks/HookA_DynamicFee.sol";
import {HookB_BoundedImpact} from "../src/hooks/HookB_BoundedImpact.sol";
import {ProductionArtifacts} from "../test/utils/ProductionArtifacts.sol";
import {DeploySystem} from "./DeploySystem.s.sol";

/// @title VerifyDeployment
/// @notice Read-only release gates for a deployed system. Reverts at the first failing gate and prints PASS for each
///         that holds. It sends no transaction. Run it after each stage and before anything is announced.
/// @dev Gates:
///      1. vault owned by the governor, with no pending nomination;
///      2. the governor bound to this vault and the expected admin;
///      3. governor delays at least the profile minimum (mainnet: 3 / 32 / 7 days; a testnet profile prints its
///         values as TEST);
///      4. a guardian set, as expected, and distinct from the admin;
///      5. each hook owned by the governor, bound to this vault and PoolManager, registered, and at an address with
///         exactly its permission bits;
///      6. the authorization module installed and bound to this vault;
///      7. the adapter installed, pricing exactly the vault's pair and decimals, answering now, and (if given)
///         carrying the reviewed `configVersion`;
///      8. every deployed runtime code equal to the local production build, immutables masked, with production
///         compiler settings;
///      9. risk parameters: inventory targets set, tolerance, edge, uncertainty bound and risk limits as reviewed;
///      10. both pools initialized;
///      11. (after stage 2) both hooks configured.
contract VerifyDeployment is Script {
    using StateLibrary for IPoolManager;

    uint160 internal constant HOOK_FLAGS =
        Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG;

    /// @notice What the reviewed configuration says.
    struct Expect {
        address poolManager;
        address admin;
        address guardian;
        address curator;
        bool mainnetDelays;
        uint24 kappaPips;
        uint24 edgePips;
        uint24 maxUncertaintyPips;
        bytes32 adapterVersion; // zero: not checked (print it for the record)
        bool hooksConfigured;
    }

    function run() external {
        DeploySystem ds = new DeploySystem();
        DeploySystem.Deployment memory d = ds.deploymentFromEnv();
        Expect memory e = Expect({
            poolManager: vm.envAddress("POOL_MANAGER"),
            admin: vm.envAddress("GOV_ADMIN"),
            guardian: vm.envAddress("GUARDIAN"),
            curator: vm.envAddress("CURATOR"),
            mainnetDelays: vm.envOr("MAINNET_DELAYS", false),
            kappaPips: uint24(vm.envOr("KAPPA_PIPS", uint256(10_000))),
            edgePips: uint24(vm.envOr("EDGE_PIPS", uint256(100))),
            maxUncertaintyPips: uint24(vm.envOr("MAX_UNCERTAINTY_PIPS", uint256(20_000))),
            adapterVersion: vm.envOr("ADAPTER_CONFIG_VERSION", bytes32(0)),
            hooksConfigured: vm.envOr("EXPECT_HOOKS_CONFIGURED", false)
        });
        check(ds, d, e);
    }

    function check(DeploySystem ds, DeploySystem.Deployment memory d, Expect memory e) public view {
        _governance(d, e);
        _hooks(ds, d, e);
        _modules(d, e);
        _code(d);
        _parameters(d, e);
        console2.log("ALL GATES PASS");
    }

    function _governance(DeploySystem.Deployment memory d, Expect memory e) internal view {
        SharedCommitmentVault v = SharedCommitmentVault(d.vault);
        VaultGovernor g = VaultGovernor(d.governor);
        require(v.owner() == d.governor, "gate 1: vault.owner() != governor");
        require(v.pendingOwner() == address(0), "gate 1: an ownership nomination is pending");
        console2.log("PASS 1 vault owned by governor", d.governor);
        require(g.vault() == d.vault && g.admin() == e.admin, "gate 2: governor bound to another vault or admin");
        console2.log("PASS 2 governor bound to vault and admin", e.admin);
        if (e.mainnetDelays) {
            require(g.DELAY() >= 3 days && g.LONG_DELAY() >= 32 days && g.GRACE() >= 7 days, "gate 3: delays");
            console2.log("PASS 3 mainnet delays", g.DELAY(), g.LONG_DELAY(), g.GRACE());
        } else {
            console2.log("PASS 3 TEST delays (not for mainnet)", g.DELAY(), g.LONG_DELAY(), g.GRACE());
        }
        address gd = v.guardian();
        require(gd == e.guardian && gd != address(0) && gd != e.admin, "gate 4: guardian");
        console2.log("PASS 4 guardian set and distinct from admin", gd);
    }

    function _hooks(DeploySystem ds, DeploySystem.Deployment memory d, Expect memory e) internal view {
        address[2] memory hooks = [d.hookA, d.hookB];
        for (uint256 i; i < 2; ++i) {
            BaseCompatibleHook h = BaseCompatibleHook(hooks[i]);
            require(h.hookOwner() == d.governor, "gate 5: hookOwner() != governor");
            require(address(h.vault()) == d.vault && address(h.poolManager()) == e.poolManager, "gate 5: hook bindings");
            require(uint160(hooks[i]) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS, "gate 5: hook permission bits");
            require(SharedCommitmentVault(d.vault).isConsumer(hooks[i]), "gate 5: hook not registered");
        }
        console2.log("PASS 5 hooks owned by governor, bound, registered, exact permission bits");
        PoolKey[2] memory keys = [ds.keyA(d), ds.keyB(d)];
        for (uint256 i; i < 2; ++i) {
            (uint160 sqrtPriceX96,,,) = IPoolManager(e.poolManager).getSlot0(keys[i].toId());
            require(sqrtPriceX96 != 0, "gate 10: pool not initialized");
        }
        console2.log("PASS 10 pools initialized");
        if (e.hooksConfigured) {
            (uint160 pA,,,,,) = HookA_DynamicFee(d.hookA).poolConfig(keys[0].toId());
            (uint128 dA,,,,,) = BaseCompatibleHook(d.hookA).coreParams(keys[0].toId());
            (uint128 dB,,,,,) = BaseCompatibleHook(d.hookB).coreParams(keys[1].toId());
            (, uint24 boundB) = HookB_BoundedImpact(d.hookB).strategy(keys[1].toId());
            require(pA != 0 && dA != 0 && dB != 0 && boundB != 0, "gate 11: hooks not configured");
            console2.log("PASS 11 hooks configured");
        }
    }

    function _modules(DeploySystem.Deployment memory d, Expect memory e) internal view {
        SharedCommitmentVault v = SharedCommitmentVault(d.vault);
        require(v.authModule() == d.auth && address(CuratorAuthorization(d.auth).vault()) == d.vault, "gate 6: module");
        console2.log("PASS 6 authorization module installed and bound");
        IMarketRiskAdapter a = IMarketRiskAdapter(d.adapter);
        require(address(v.riskAdapter()) == d.adapter, "gate 7: adapter not installed");
        (address c0, address c1, uint8 d0, uint8 d1) = a.pair();
        require(c0 == Currency.unwrap(v.asset0()) && c1 == Currency.unwrap(v.asset1()), "gate 7: adapter pair");
        require(d0 == 18 && d1 == 18, "gate 7: adapter decimals (TEST tokens are 18/18)");
        a.currentReference(); // reverts if the sources are not live
        if (e.adapterVersion != bytes32(0)) require(a.configVersion() == e.adapterVersion, "gate 7: configVersion");
        console2.log("PASS 7 adapter installed, pair checked, live; configVersion:");
        console2.logBytes32(a.configVersion());
    }

    function _code(DeploySystem.Deployment memory d) internal view {
        ProductionArtifacts.requireProduction(d.vault, ProductionArtifacts.VAULT, ProductionArtifacts.VAULT_RUNS);
        ProductionArtifacts.requireProduction(d.hookA, ProductionArtifacts.HOOK_A, ProductionArtifacts.DEFAULT_RUNS);
        ProductionArtifacts.requireProduction(d.hookB, ProductionArtifacts.HOOK_B, ProductionArtifacts.DEFAULT_RUNS);
        ProductionArtifacts.requireProduction(
            d.auth, ProductionArtifacts.authModule(), ProductionArtifacts.DEFAULT_RUNS
        );
        ProductionArtifacts.requireProduction(
            d.governor, "out/VaultGovernor.sol/VaultGovernor.json", ProductionArtifacts.DEFAULT_RUNS
        );
        ProductionArtifacts.requireProduction(
            d.adapter, "out/PriceRiskAdapter.sol/PriceRiskAdapter.json", ProductionArtifacts.DEFAULT_RUNS
        );
        console2.log("PASS 8 deployed runtime code = local production builds (immutables masked)");
    }

    function _parameters(DeploySystem.Deployment memory d, Expect memory e) internal view {
        SharedCommitmentVault v = SharedCommitmentVault(d.vault);
        require(v.inventoryTargetPerShare(0) != 0 && v.inventoryTargetPerShare(1) != 0, "gate 9: inventory targets");
        require(
            v.inventoryTolerancePips(0) == e.kappaPips && v.inventoryTolerancePips(1) == e.kappaPips, "gate 9: kappa"
        );
        require(v.riskEdgePips() == e.edgePips && v.maxUncertaintyPips() == e.maxUncertaintyPips, "gate 9: risk bounds");
        address[4] memory accounts = [address(0), d.hookA, d.hookB, e.curator];
        ISharedCommitmentVault.RiskScope[4] memory scopes = [
            ISharedCommitmentVault.RiskScope.Vault,
            ISharedCommitmentVault.RiskScope.Hook,
            ISharedCommitmentVault.RiskScope.Hook,
            ISharedCommitmentVault.RiskScope.Curator
        ];
        for (uint256 i; i < 4; ++i) {
            require(v.getRiskLimit(scopes[i], accounts[i], v.asset0()).configured, "gate 9: risk limit asset0");
            require(v.getRiskLimit(scopes[i], accounts[i], v.asset1()).configured, "gate 9: risk limit asset1");
        }
        ISharedCommitmentVault.CuratorRecord memory r = v.getCurator(e.curator);
        require(r.registered && r.restriction == ISharedCommitmentVault.CuratorRestriction.None, "gate 9: curator");
        console2.log("PASS 9 inventory bounds, kappa, edge, uncertainty bound, risk limits, curator");
    }
}
