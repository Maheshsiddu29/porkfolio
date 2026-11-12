// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {VaultGovernor} from "../../src/governance/VaultGovernor.sol";
import {DeploySystem} from "../../script/DeploySystem.s.sol";
import {ExecuteQueued} from "../../script/ExecuteQueued.s.sol";
import {VerifyDeployment} from "../../script/VerifyDeployment.s.sol";
import {Rehearse} from "../../script/Rehearse.s.sol";
import {TestnetAggregator} from "../../script/testnet/TestnetAggregator.sol";
import {ProductionArtifacts} from "../utils/ProductionArtifacts.sol";

/// @notice The rehearsal scripts run end to end on a local chain against the production PoolManager build: stage 1
///         deploys and hands over, the release gates fail before stage 2 (hooks not configured) and pass after it, and
///         every rehearsal stage (LP flows, signed activation, swaps on both hooks, queued exit and claim, emergency
///         controls, a governed change executed and one canceled) succeeds. Nothing leaves the test EVM.
contract DeployScriptsTest is Test {
    uint256 internal constant DEPLOYER_KEY = 0xD1;
    uint256 internal constant GUARDIAN_KEY = 0xD2;
    uint256 internal constant CURATOR_KEY = 0xD3;
    uint256 internal constant LP_KEY = 0xD4;
    uint256 internal constant TRADER_KEY = 0xD5;

    IPoolManager internal manager;
    DeploySystem internal ds;

    function setUp() public {
        vm.warp(1_800_000_000);
        manager = IPoolManager(deployCode(ProductionArtifacts.poolManager(), abi.encode(address(this))));
        vm.setEnv("POOL_MANAGER", vm.toString(address(manager)));
        vm.setEnv("DEPLOYER", vm.toString(vm.addr(DEPLOYER_KEY)));
        vm.setEnv("GOV_ADMIN", vm.toString(vm.addr(DEPLOYER_KEY))); // testnet only: deployer administers the governor
        vm.setEnv("GUARDIAN", vm.toString(vm.addr(GUARDIAN_KEY)));
        vm.setEnv("CURATOR", vm.toString(vm.addr(CURATOR_KEY)));
        vm.setEnv("DEPLOYER_KEY", vm.toString(DEPLOYER_KEY));
        vm.setEnv("GOV_ADMIN_KEY", vm.toString(DEPLOYER_KEY));
        vm.setEnv("GUARDIAN_KEY", vm.toString(GUARDIAN_KEY));
        vm.setEnv("CURATOR_KEY", vm.toString(CURATOR_KEY));
        vm.setEnv("LP_KEY", vm.toString(LP_KEY));
        vm.setEnv("TRADER_KEY", vm.toString(TRADER_KEY));
        ds = new DeploySystem();
    }

    function _exportDeployment(DeploySystem.Deployment memory d) internal {
        vm.setEnv("TOKEN0", vm.toString(d.token0));
        vm.setEnv("TOKEN1", vm.toString(d.token1));
        vm.setEnv("ADAPTER", vm.toString(d.adapter));
        vm.setEnv("VAULT", vm.toString(d.vault));
        vm.setEnv("AUTH_MODULE", vm.toString(d.auth));
        vm.setEnv("GOVERNOR", vm.toString(d.governor));
        vm.setEnv("HOOK_A", vm.toString(d.hookA));
        vm.setEnv("HOOK_B", vm.toString(d.hookB));
    }

    /// @dev The TEST feeds age; their operator (the deployer) re-posts 1.0 so the adapter stays live.
    function _refreshFeeds(DeploySystem.Deployment memory d) internal {
        for (uint256 i; i < 4; ++i) {
            vm.prank(vm.addr(DEPLOYER_KEY));
            TestnetAggregator(d.feeds[i]).set(1e8, block.timestamp);
        }
    }

    function test_fullRehearsal_localChain() public {
        DeploySystem.Deployment memory d = ds.run();
        _exportDeployment(d);
        VerifyDeployment verify = new VerifyDeployment();

        // Before stage 2 the hooks are not configured: the gate that checks it fails.
        vm.setEnv("EXPECT_HOOKS_CONFIGURED", "true");
        vm.expectRevert(bytes("gate 11: hooks not configured"));
        verify.run();

        vm.warp(block.timestamp + VaultGovernor(d.governor).DELAY());
        _refreshFeeds(d);
        new ExecuteQueued().run();
        verify.run(); // all gates, including deployed code = production builds

        Rehearse r = new Rehearse();
        PoolSwapTest router = new PoolSwapTest(manager); // the rehearsal's TEST router
        vm.setEnv("ROUTER", vm.toString(address(router)));
        r.run("lp");
        uint256 nextId = SharedCommitmentVault(d.vault).nextAllocationId();
        r.run("activate");
        vm.setEnv("ALLOCATION_A", vm.toString(nextId));
        vm.setEnv("ALLOCATION_B", vm.toString(nextId + 1));
        r.run("swap");
        r.run("exit");
        r.run("emergency");
        assertTrue(SharedCommitmentVault(d.vault).paused());
        vm.warp(block.timestamp + VaultGovernor(d.governor).DELAY());
        _refreshFeeds(d);
        r.run("recover");
        assertFalse(SharedCommitmentVault(d.vault).paused());
        verify.run();
    }

    /// @notice With a separate governor admin the deployer cannot accept for the governor, so the vault is only
    ///         nominated: gate 1 refuses until the admin accepts. Uses an explicit configuration (no environment).
    function test_gates_refuseUntilGovernorAccepts() public {
        DeploySystem.Config memory c = ds.loadConfig();
        c.admin = makeAddr("multisig");
        c.salt = keccak256("gates-test");
        DeploySystem.Deployment memory d = ds.runWith(c);
        VerifyDeployment.Expect memory e;
        (e.poolManager, e.admin, e.guardian, e.curator) = (c.poolManager, c.admin, c.guardian, c.curator);
        (e.kappaPips, e.edgePips, e.maxUncertaintyPips) = (c.kappaPips, c.edgePips, c.maxUncertaintyPips);
        VerifyDeployment verify = new VerifyDeployment();
        vm.expectRevert(bytes("gate 1: vault.owner() != governor"));
        verify.check(ds, d, e);
        assertEq(SharedCommitmentVault(d.vault).pendingOwner(), d.governor);
        vm.prank(c.admin);
        VaultGovernor(d.governor).acceptVaultOwnership();
        verify.check(ds, d, e); // every gate that applies before stage 2
    }

    /// @notice The scripts refuse Unichain mainnet (130) and every chain but Sepolia (1301) and local.
    function test_refusesMainnet() public {
        DeploySystem.Config memory c = ds.loadConfig();
        vm.chainId(130);
        vm.expectRevert(bytes("DeploySystem: Sepolia or local only"));
        ds.validate(c);
    }

    /// @notice Refused configurations: the deployer administering a governor with mainnet-length delays (it may only
    ///         administer a labelled test governor), and a guardian that is also the admin.
    function test_refusesUnsafeConfigurations() public {
        DeploySystem.Config memory c = ds.loadConfig();
        c.delay = 3 days;
        vm.expectRevert(bytes("DeploySystem: deployer as admin only with test delays"));
        ds.validate(c);
        c = ds.loadConfig();
        c.guardian = c.admin;
        vm.expectRevert(bytes("DeploySystem: guardian must differ from the governor admin"));
        ds.validate(c);
    }
}
