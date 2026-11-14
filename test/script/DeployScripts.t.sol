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
import {VaultStateReader} from "../../src/libraries/VaultStateReader.sol";

using VaultStateReader for SharedCommitmentVault;

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
        for (uint256 i; i < 4; ++i) {
            vm.setEnv(string.concat("FEED_", vm.toString(i)), vm.toString(d.feeds[i]));
        }
        // The TEST feeds post 1.0 for both tokens; a real deployment takes this from a source outside the adapter.
        vm.setEnv("INDEPENDENT_PRICE_X96", vm.toString(uint256(2 ** 96)));
    }

    /// @dev The oracle expectations of gate 7 that match a rehearsal deployment.
    function _oracleExpect(DeploySystem.Deployment memory d, VerifyDeployment.Expect memory e) internal pure {
        e.feeds = d.feeds;
        e.independentPriceX96 = 2 ** 96;
        e.independentTolerancePips = 20_000;
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
        (e.exposureBps, e.bufferFloor) = (c.exposureBps, c.bufferFloor);
        _oracleExpect(d, e);
        VerifyDeployment verify = new VerifyDeployment();
        vm.expectRevert(bytes("gate 1: vault.owner() != governor"));
        verify.check(ds, d, e);
        assertEq(SharedCommitmentVault(d.vault).pendingOwner(), d.governor);
        vm.prank(c.admin);
        VaultGovernor(d.governor).acceptVaultOwnership();
        verify.check(ds, d, e); // every gate that applies before stage 2
    }

    /// @dev A deployment administered by a separate admin with mainnet-length delays, accepted by that admin, and the
    ///      expectations that match it.
    function _mainnetLike() internal returns (DeploySystem.Deployment memory d, VerifyDeployment.Expect memory e) {
        DeploySystem.Config memory c = ds.loadConfig();
        (c.admin, c.delay, c.longDelay, c.grace) = (makeAddr("multisig"), 3 days, 32 days, 7 days);
        c.salt = keccak256("mainnet-like");
        d = ds.runWith(c);
        vm.prank(c.admin);
        VaultGovernor(d.governor).acceptVaultOwnership();
        (e.poolManager, e.admin, e.guardian, e.curator, e.mainnetDelays) =
        (c.poolManager, c.admin, c.guardian, c.curator, true);
        (e.kappaPips, e.edgePips, e.maxUncertaintyPips) = (c.kappaPips, c.edgePips, c.maxUncertaintyPips);
        (e.exposureBps, e.bufferFloor) = (c.exposureBps, c.bufferFloor);
        _oracleExpect(d, e);
        e.acceptNoSequencer = true; // the Sepolia rehearsal has no uptime feed (G04 report §2.4)
    }

    /// @notice Deployment policies as gates. The seed never exists without an inventory target or a buffer floor: both
    ///         are set before `initialDeposit`. With mainnet delays the admin must be a contract (a multisig can execute
    ///         release, processQueue and execute, or a nomination and its acceptance, in one transaction). The
    ///         vault-scope exposure cap and the buffer floor must equal the reviewed values; a zero buffer floor is
    ///         refused by the deployment and by the gate. The cap's value is whatever was reviewed, not a constant.
    function test_gates_deploymentPolicies() public {
        (DeploySystem.Deployment memory d, VerifyDeployment.Expect memory e) = _mainnetLike();
        SharedCommitmentVault v = SharedCommitmentVault(d.vault);
        assertEq(v.inventoryTargetPerShare(0), 1e18, "target equals the seeded holding per share");
        assertEq(v.bufferFloor(v.asset0()), e.bufferFloor);
        VerifyDeployment verify = new VerifyDeployment();

        vm.expectRevert(bytes("gate 2: admin must be a contract (multisig) to batch"));
        verify.check(ds, d, e);
        vm.etch(e.admin, hex"00");
        verify.check(ds, d, e);

        uint256 snap = vm.snapshotState();
        e.exposureBps = 3000;
        vm.expectRevert(bytes("gate 9: vault exposure cap"));
        verify.check(ds, d, e);
        vm.revertToState(snap);
        e.bufferFloor = 0;
        vm.expectRevert(bytes("gate 9: reviewed buffer floor is zero"));
        verify.check(ds, d, e);

        DeploySystem.Config memory c = ds.loadConfig();
        c.bufferFloor = 0;
        vm.expectRevert(bytes("DeploySystem: buffer floor must be non-zero"));
        ds.validate(c);
    }

    /// @notice Gate 7's oracle identity checks and gate 13. A deployment whose adapter has two legs in each other's
    ///         slot, a sequencer feed other than the reviewed one, no sequencer feed without an acknowledgement under
    ///         mainnet delays, or a reading off the independent price by more than the tolerance is refused. Gate 13
    ///         refuses a fall-back to fixed floors while a stored floor or an inventory target is unset, and passes
    ///         once both are set.
    function test_gates_oracleIdentityAndFixedFloorFallback() public {
        (DeploySystem.Deployment memory d, VerifyDeployment.Expect memory e) = _mainnetLike();
        vm.etch(e.admin, hex"00");
        VerifyDeployment verify = new VerifyDeployment();
        verify.check(ds, d, e);

        // `check` is a view: each case changes one expectation and restores it (memory is not part of a snapshot).
        (e.feeds[0], e.feeds[1]) = (e.feeds[1], e.feeds[0]);
        vm.expectRevert(bytes("gate 7: feed identity"));
        verify.check(ds, d, e);
        (e.feeds[0], e.feeds[1]) = (e.feeds[1], e.feeds[0]);

        e.sequencerFeed = makeAddr("uptimeFeed");
        vm.expectRevert(bytes("gate 7: sequencer feed"));
        verify.check(ds, d, e);
        e.sequencerFeed = address(0);

        e.acceptNoSequencer = false;
        vm.expectRevert(bytes("gate 7: no sequencer feed"));
        verify.check(ds, d, e);
        e.acceptNoSequencer = true;

        e.independentPriceX96 = uint256(2 ** 96) * 103 / 100; // 3% away, tolerance 2%
        vm.expectRevert(bytes("gate 7: reading differs from the independent price"));
        verify.check(ds, d, e);
        e.independentPriceX96 = 0;
        vm.expectRevert(bytes("gate 7: no independent price"));
        verify.check(ds, d, e);
        e.independentPriceX96 = 2 ** 96;
        verify.check(ds, d, e);

        // Gate 13: the rehearsal sets inventory targets but no stored floors.
        vm.expectRevert(bytes("gate 13: stored sell floors"));
        verify.checkFixedFloorFallback(d.vault);
        SharedCommitmentVault v = SharedCommitmentVault(d.vault);
        vm.startPrank(d.governor); // the vault's owner, standing in for two executed governor calls
        v.setSellFloor(v.asset0(), uint160(uint256(2 ** 96) * 9 / 10));
        v.setSellFloor(v.asset1(), uint160(uint256(2 ** 96) * 10 / 9 + 1));
        vm.stopPrank();
        verify.checkFixedFloorFallback(d.vault);
        vm.prank(d.governor);
        v.setInventoryBounds(1e18, 0, e.kappaPips, e.kappaPips);
        vm.expectRevert(bytes("gate 13: inventory targets"));
        verify.checkFixedFloorFallback(d.vault);
    }

    /// @notice Gate 12 accepts as nominee only a production `VaultGovernor` for this vault, administered by the expected
    ///         admin, with mainnet delay minimums: an externally owned account, a governor for someone else's admin
    ///         and a governor with short delays are all refused.
    function test_gate12_nomineeMustBeAReviewedGovernor() public {
        (DeploySystem.Deployment memory d, VerifyDeployment.Expect memory e) = _mainnetLike();
        VerifyDeployment verify = new VerifyDeployment();
        address next = makeAddr("nextMultisig");
        string memory artifact = "out/VaultGovernor.sol/VaultGovernor.json";
        address good = deployCode(artifact, abi.encode(d.vault, next, 3 days, 32 days, 7 days));
        address otherAdmin = deployCode(artifact, abi.encode(d.vault, e.admin, 3 days, 32 days, 7 days));
        address fast = deployCode(artifact, abi.encode(d.vault, next, 3 days, 3 days, 7 days));

        verify.checkNominee(d.vault, good, next, true);
        vm.expectRevert();
        verify.checkNominee(d.vault, makeAddr("eoa"), next, true);
        vm.expectRevert(bytes("gate 12: nominee bound to another vault or admin"));
        verify.checkNominee(d.vault, otherAdmin, next, true);
        vm.expectRevert(bytes("gate 12: nominee delays"));
        verify.checkNominee(d.vault, fast, next, true);
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
