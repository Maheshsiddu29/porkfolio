// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {SharedCommitmentVault} from "../src/SharedCommitmentVault.sol";
import {ISharedCommitmentVault} from "../src/interfaces/ISharedCommitmentVault.sol";
import {IVaultState} from "../src/interfaces/IVaultState.sol";
import {IMarketRiskAdapter} from "../src/interfaces/IMarketRiskAdapter.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {PriceRiskAdapter} from "../src/oracle/PriceRiskAdapter.sol";
import {VaultGovernor} from "../src/governance/VaultGovernor.sol";
import {BaseCompatibleHook} from "../src/hooks/BaseCompatibleHook.sol";
import {HookA_DynamicFee} from "../src/hooks/HookA_DynamicFee.sol";
import {HookB_BoundedImpact} from "../src/hooks/HookB_BoundedImpact.sol";
import {ProductionArtifacts} from "../test/utils/ProductionArtifacts.sol";
import {TestnetAggregator} from "./testnet/TestnetAggregator.sol";

/// @title DeploySystem
/// @notice Stage 1 of the Unichain Sepolia rehearsal. Deploys the system, hands the vault to the governor, and queues
///         the hooks' configuration. **Never run against mainnet:** the script refuses any chain but Unichain Sepolia
///         (1301) and a local chain (31337).
/// @dev What it deploys:
///      - two TEST tokens and four owner-set TEST feeds (labelled; the rehearsal does not depend on third-party feeds);
///      - `PriceRiskAdapter`;
///      - the vault, the authorization module and `VaultGovernor`;
///      - Hook A and Hook B, at mined addresses whose low 14 bits are exactly their permission flags, with
///        `hookOwner = governor`.
///      Every contract comes from the production artifact files through the deterministic CREATE2 factory, so its code
///      is the reviewed build and its address is reproducible.
///
///      What it then does:
///      - initializes one pool per hook at 1:1;
///      - configures the vault as its temporary owner (the broadcaster);
///      - sets the inventory target to the holding the seed will give each share, and a non-zero buffer floor in
///        each asset, before any share exists (release checklist G-6, G-7);
///      - seeds it with `initialDeposit` and checks the target against the minted shares;
///      - installs the adapter;
///      - nominates the governor.
///      If the broadcaster is also the governor's admin (allowed only with labelled testnet delays), it also accepts
///      ownership for the governor and queues the hooks' configuration.
///      `ExecuteQueued` applies that configuration after DELAY.
///
///      Keys: none in this repository. Run with `--account`, `--ledger` or an ephemeral `--private-key` from the
///      shell. Broadcasting needs explicit owner approval (CLAUDE.md rule 2).
contract DeploySystem is Script {
    /// @dev Production artifacts (default profile, 44,444,444 runs). Files with a `.vault.json` suffix are the 200-run
    ///      builds produced when a file compiled under the vault's profile imports these contracts; never deployed.
    string internal constant GOVERNOR_ARTIFACT = "out/VaultGovernor.sol/VaultGovernor.json";
    string internal constant ADAPTER_ARTIFACT = "out/PriceRiskAdapter.sol/PriceRiskAdapter.json";
    // CREATE2_FACTORY (0x4e59b448...) is inherited from forge-std: the deterministic deployer present on most chains
    // and in every Foundry test EVM.
    uint160 internal constant HOOK_FLAGS =
        Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint256 internal constant Q96 = 2 ** 96;
    uint256 internal constant UNICHAIN_SEPOLIA = 1301;
    uint256 internal constant LOCAL = 31_337;

    /// @notice Every choice the deployment makes, read from the environment (defaults are the labelled testnet set).
    struct Config {
        address poolManager;
        address deployer; // the broadcaster, temporary vault owner
        address admin; // governor admin
        address guardian;
        address curator;
        uint256 delay;
        uint256 longDelay;
        uint256 grace;
        uint256 seed; // raw units of each test token for initialDeposit
        uint24 kappaPips;
        uint24 edgePips;
        uint24 maxUncertaintyPips;
        uint256 flowCap; // per scope, per asset, per day, raw units
        uint16 exposureBps;
        uint256 bufferFloor; // raw units per asset that new commitments must leave free
        bytes32 salt; // namespace for every CREATE2 salt
    }

    /// @notice Addresses produced by stage 1.
    struct Deployment {
        address token0;
        address token1;
        address[4] feeds; // clUsd0, clUsd1, rsUsd0, rsUsd1 (TEST feeds)
        address adapter;
        address vault;
        address auth;
        address governor;
        address hookA;
        address hookB;
    }

    function run() external returns (Deployment memory d) {
        return runWith(loadConfig());
    }

    /// @notice Stage 1 with an explicit configuration (validated again here), broadcast from `c.deployer`.
    function runWith(Config memory c) public returns (Deployment memory d) {
        validate(c);
        vm.startBroadcast(c.deployer);
        d = deploy(c);
        vm.stopBroadcast();
        log(d);
    }

    /// @notice The configuration from the environment. POOL_MANAGER is required outside a local chain and must be the
    ///         address Uniswap publishes for the chain (release checklist D-4).
    function loadConfig() public view returns (Config memory c) {
        if (block.chainid != UNICHAIN_SEPOLIA && block.chainid != LOCAL) revert("DeploySystem: Sepolia or local only");
        c.poolManager = vm.envAddress("POOL_MANAGER");
        c.deployer = vm.envOr("DEPLOYER", msg.sender);
        c.admin = vm.envOr("GOV_ADMIN", c.deployer);
        c.guardian = vm.envAddress("GUARDIAN");
        c.curator = vm.envAddress("CURATOR");
        // TESTNET delays by default (labelled); a mainnet-like run sets 259200 / 2764800 / 604800.
        c.delay = vm.envOr("GOV_DELAY", uint256(10 minutes));
        c.longDelay = vm.envOr("GOV_LONG_DELAY", uint256(1 hours));
        c.grace = vm.envOr("GOV_GRACE", uint256(1 days));
        c.seed = vm.envOr("SEED_AMOUNT", uint256(1_000_000 ether));
        c.kappaPips = uint24(vm.envOr("KAPPA_PIPS", uint256(10_000))); // 1% (R-4 candidate)
        c.edgePips = uint24(vm.envOr("EDGE_PIPS", uint256(100)));
        c.maxUncertaintyPips = uint24(vm.envOr("MAX_UNCERTAINTY_PIPS", uint256(20_000)));
        c.flowCap = vm.envOr("FLOW_CAP", c.seed * 4 / 10);
        c.exposureBps = uint16(vm.envOr("EXPOSURE_BPS", uint256(5000)));
        c.bufferFloor = vm.envOr("BUFFER_FLOOR", c.seed / 10);
        c.salt = vm.envOr("SALT_NAMESPACE", keccak256("porkfolio.rehearsal.v1"));
        validate(c);
    }

    /// @notice Refuses a configuration the rehearsal must never use: a chain other than Sepolia or local, a guardian
    ///         that is the governor admin, the deployer administering a governor with non-test delays, or a zero
    ///         buffer floor.
    function validate(Config memory c) public view {
        if (block.chainid != UNICHAIN_SEPOLIA && block.chainid != LOCAL) revert("DeploySystem: Sepolia or local only");
        if (c.bufferFloor == 0) revert("DeploySystem: buffer floor must be non-zero");
        if (c.admin == c.guardian) revert("DeploySystem: guardian must differ from the governor admin");
        if (c.admin == c.deployer && c.delay >= 1 days) {
            revert("DeploySystem: deployer as admin only with test delays");
        }
    }

    /// @notice Stage 1. Called inside a broadcast by `run`, and directly by the local test.
    function deploy(Config memory c) public returns (Deployment memory d) {
        require(CREATE2_FACTORY.code.length != 0, "DeploySystem: no CREATE2 factory on this chain");
        _namespace = c.salt;
        _deployTestAssets(c, d);
        _deployCore(c, d);
        _deployHooks(c, d);
        _configureVault(c, d);
        if (c.admin == c.deployer) {
            VaultGovernor(d.governor).acceptVaultOwnership();
            bytes[] memory calls = hookCalls(d);
            for (uint256 i; i < calls.length; ++i) {
                VaultGovernor(d.governor).queue(i < 2 ? d.hookA : d.hookB, calls[i]);
            }
        }
    }

    // ------------------------------------------------------------------ stage-1 steps

    function _deployTestAssets(Config memory c, Deployment memory d) internal {
        address a = _create2(
            "tokenA", abi.encodePacked(type(MockERC20).creationCode, abi.encode("Porkfolio TEST A", "PTA", 18))
        );
        address b = _create2(
            "tokenB", abi.encodePacked(type(MockERC20).creationCode, abi.encode("Porkfolio TEST B", "PTB", 18))
        );
        (d.token0, d.token1) = a < b ? (a, b) : (b, a);
        for (uint256 i; i < 4; ++i) {
            d.feeds[i] = _create2(
                string.concat("feed", vm.toString(i)),
                abi.encodePacked(type(TestnetAggregator).creationCode, abi.encode(c.deployer, uint8(8)))
            );
            TestnetAggregator(d.feeds[i]).set(1e8, block.timestamp);
        }
        PriceRiskAdapter.Source memory push = PriceRiskAdapter.Source(
            IAggregatorV3(d.feeds[0]), IAggregatorV3(d.feeds[1]), 3100, 5100, 88_200, 88_200, 0, 0, 0
        );
        PriceRiskAdapter.Source memory fresh = PriceRiskAdapter.Source(
            IAggregatorV3(d.feeds[2]), IAggregatorV3(d.feeds[3]), 5100, 5100, 12_600, 23_400, 120, 1500, 1500
        );
        d.adapter = _create2(
            "adapter",
            abi.encodePacked(
                vm.getCode(ADAPTER_ARTIFACT),
                abi.encode(push, fresh, d.token0, d.token1, uint8(18), uint8(18), IAggregatorV3(address(0)), 0, 2)
            )
        );
    }

    function _deployCore(Config memory c, Deployment memory d) internal {
        d.vault = _create2(
            "vault",
            abi.encodePacked(
                vm.getCode(ProductionArtifacts.VAULT),
                abi.encode(c.poolManager, c.deployer, Currency.wrap(d.token0), Currency.wrap(d.token1))
            )
        );
        d.auth = _create2(
            "auth", abi.encodePacked(vm.getCode(ProductionArtifacts.authModule()), abi.encode(IVaultState(d.vault)))
        );
        d.governor = _create2(
            "governor",
            abi.encodePacked(vm.getCode(GOVERNOR_ARTIFACT), abi.encode(d.vault, c.admin, c.delay, c.longDelay, c.grace))
        );
    }

    function _deployHooks(Config memory c, Deployment memory d) internal {
        bytes memory args = abi.encode(c.poolManager, d.vault, d.governor);
        d.hookA = _deployMined(abi.encodePacked(vm.getCode(ProductionArtifacts.HOOK_A), args), "hookA");
        d.hookB = _deployMined(abi.encodePacked(vm.getCode(ProductionArtifacts.HOOK_B), args), "hookB");
        IPoolManager(c.poolManager).initialize(keyA(d), SQRT_PRICE_1_1);
        IPoolManager(c.poolManager).initialize(keyB(d), SQRT_PRICE_1_1);
    }

    function _configureVault(Config memory c, Deployment memory d) internal {
        SharedCommitmentVault v = SharedCommitmentVault(d.vault);
        Currency c0 = Currency.wrap(d.token0);
        Currency c1 = Currency.wrap(d.token1);
        v.setAuthModule(d.auth);
        v.setConsumer(d.hookA, true);
        v.setConsumer(d.hookB, true);
        v.setCurator(c.curator, true);
        v.setCuratorCeiling(c.curator, c0, c.seed / 5);
        v.setCuratorCeiling(c.curator, c1, c.seed / 5);
        _limits(v, ISharedCommitmentVault.RiskScope.Vault, address(0), c);
        _limits(v, ISharedCommitmentVault.RiskScope.Hook, d.hookA, c);
        _limits(v, ISharedCommitmentVault.RiskScope.Hook, d.hookB, c);
        _limits(v, ISharedCommitmentVault.RiskScope.Curator, c.curator, c);
        v.setGuardian(c.guardian);
        v.setRiskBounds(c.edgePips, c.maxUncertaintyPips);
        v.setBufferFloor(c0, c.bufferFloor);
        v.setBufferFloor(c1, c.bufferFloor);
        // initialDeposit(seed, seed) mints sqrt(seed * seed) = seed shares, so each share starts with exactly one raw
        // unit of each asset: the per-share target (1e18 fixed point) is 1e18. Set before any share exists, so no LP
        // can ever hold a share without an inventory floor.
        uint256 tau = 1e18;
        v.setInventoryBounds(tau, tau, c.kappaPips, c.kappaPips);

        MockERC20(d.token0).mint(c.deployer, c.seed);
        MockERC20(d.token1).mint(c.deployer, c.seed);
        MockERC20(d.token0).approve(d.vault, c.seed);
        MockERC20(d.token1).approve(d.vault, c.seed);
        v.initialDeposit(c.seed, c.seed, c.deployer);
        require(
            FullMath.mulDiv(c.seed, 1e18, v.totalShares()) == tau, "DeploySystem: inventory target != seeded holding"
        );
        v.setRiskAdapter(IMarketRiskAdapter(d.adapter));
        v.transferOwnership(d.governor);
    }

    function _limits(SharedCommitmentVault v, ISharedCommitmentVault.RiskScope s, address a, Config memory c) internal {
        v.setRiskLimit(s, a, v.asset0(), c.flowCap, c.exposureBps);
        v.setRiskLimit(s, a, v.asset1(), c.flowCap, c.exposureBps);
    }

    // ------------------------------------------------------------------ shared with ExecuteQueued and VerifyDeployment

    function keyA(Deployment memory d) public pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(d.token0), Currency.wrap(d.token1), 3000, 60, IHooks(d.hookA));
    }

    function keyB(Deployment memory d) public pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(d.token0), Currency.wrap(d.token1), 500, 10, IHooks(d.hookB));
    }

    /// @notice The hooks' configuration, as the exact calldata the governor queues (A: 2 calls, B: 3 calls).
    /// @dev Values from CALIBRATION_1B44.md: Hook A fee 0 -> 50 bp over 20,000 tokens per hour; Hook B 10 bp markup
    ///      with a 2% per-trade bound; core depth 10 x target per share, base spread 30 bp, minimum edge 2 bp.
    function hookCalls(Deployment memory d) public pure returns (bytes[] memory calls) {
        BaseCompatibleHook.CoreParams memory p = BaseCompatibleHook.CoreParams({
            depthPerShare: 10e18,
            depthMax: uint128(2 ** 95 - 1),
            baseSpreadPips: 3000,
            minEdgePips: 200,
            maxSpreadPips: 40_000,
            maxDeviationPips: 50_000
        });
        calls = new bytes[](5);
        calls[0] = abi.encodeCall(
            HookA_DynamicFee.configurePool, (keyA(d), uint160(Q96), 0, 5000, 20_000e18, 20_000e18, 3600)
        );
        calls[1] = abi.encodeCall(BaseCompatibleHook.configureCore, (keyA(d), p));
        calls[2] =
            abi.encodeCall(HookB_BoundedImpact.configurePool, (keyB(d), uint160(Q96), 1_000_000e18, 20_000, 3600));
        calls[3] = abi.encodeCall(BaseCompatibleHook.configureCore, (keyB(d), p));
        calls[4] = abi.encodeCall(HookB_BoundedImpact.configureStrategy, (keyB(d), 1000, 20_000));
    }

    /// @notice A stage-1 deployment read back from the environment (the addresses `run` printed).
    function deploymentFromEnv() public view returns (Deployment memory d) {
        d.token0 = vm.envAddress("TOKEN0");
        d.token1 = vm.envAddress("TOKEN1");
        d.adapter = vm.envAddress("ADAPTER");
        d.vault = vm.envAddress("VAULT");
        d.auth = vm.envAddress("AUTH_MODULE");
        d.governor = vm.envAddress("GOVERNOR");
        d.hookA = vm.envAddress("HOOK_A");
        d.hookB = vm.envAddress("HOOK_B");
    }

    function log(Deployment memory d) public pure {
        console2.log("TEST token0", d.token0);
        console2.log("TEST token1", d.token1);
        console2.log("adapter (TEST feeds)", d.adapter);
        console2.log("vault", d.vault);
        console2.log("auth module", d.auth);
        console2.log("governor", d.governor);
        console2.log("hook A", d.hookA);
        console2.log("hook B", d.hookB);
    }

    // ------------------------------------------------------------------ CREATE2

    /// @dev Namespace of every CREATE2 salt in this deployment (`Config.salt`).
    bytes32 internal _namespace;

    function _salt(string memory label) internal view returns (bytes32) {
        return keccak256(abi.encode(_namespace, label));
    }

    function _create2(string memory label, bytes memory initCode) internal returns (address addr) {
        addr = _deployAt(_salt(label), initCode);
    }

    function _deployAt(bytes32 salt, bytes memory initCode) internal returns (address addr) {
        addr = vm.computeCreate2Address(salt, keccak256(initCode), CREATE2_FACTORY);
        if (addr.code.length != 0) return addr; // already deployed with this exact code and salt
        (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(salt, initCode));
        require(ok && addr.code.length != 0, "DeploySystem: CREATE2 failed");
    }

    /// @notice A salt whose CREATE2 address has exactly HOOK_FLAGS in its low 14 bits (all other permission bits clear),
    ///         as the PoolManager requires. About 16,384 tries on average; deterministic for given code and namespace.
    function mineHookSalt(bytes memory initCode, string memory label) public view returns (bytes32 salt, address addr) {
        bytes32 codeHash = keccak256(initCode);
        bytes32 base = _salt(label);
        for (uint256 i; i < 400_000; ++i) {
            salt = keccak256(abi.encode(base, i));
            addr = vm.computeCreate2Address(salt, codeHash, CREATE2_FACTORY);
            if (uint160(addr) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS) return (salt, addr);
        }
        revert("DeploySystem: no hook salt found");
    }

    function _deployMined(bytes memory initCode, string memory label) internal returns (address addr) {
        (bytes32 salt,) = mineHookSalt(initCode, label);
        addr = _deployAt(salt, initCode);
    }
}
