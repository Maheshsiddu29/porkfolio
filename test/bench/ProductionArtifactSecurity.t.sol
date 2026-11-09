// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {ICuratorAuthorization} from "../../src/interfaces/ICuratorAuthorization.sol";
import {IBenchVault, IBenchHook} from "./IBench.sol";
import {ReentrantToken, ReentryAgent} from "../utils/ReentrantToken.sol";
import {ScriptedHook} from "../utils/ScriptedHook.sol";
import {ProductionArtifacts} from "../utils/ProductionArtifacts.sol";
import {Mock1271Wallet} from "../utils/Mock1271Wallet.sol";
import {MaliciousAuthModule} from "../utils/MaliciousAuthModule.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title Production-artifact security tests
/// @notice Security-relevant paths run against the exact bytecode that would be deployed: the vault, HookA, HookB and
///         the authorization module and the pinned v4 PoolManager are each deployed from their production artifact
///         file.
/// @dev Why this file exists. It imports no project source, only interfaces, so it compiles under the default
///      profile and talks to the vault only through its ABI; the functional suite (`VaultTestBase`) also deploys the
///      production builds now, but compiles the vault source into its files. This file is the ABI-level check.
///
///      How production builds are guaranteed here. Contracts are deployed from explicit artifact paths
///      (`out/<File>.sol/<Name>.json`), not by name, so the result does not depend on the profile this file is
///      compiled under. `test_PA_deployedCodeIsProductionArtifacts` reads the compiler settings recorded in each of
///      those artifact files and checks that each deployed runtime code equals its artifact's with immutables masked.
///      It does not rely on the 2,000-run test builds being present in `out/`: other tools (for example Slither's
///      `forge build --skip test`) can remove them. Reading artifacts needs the read-only `fs_permissions` entry for
///      `./out` in foundry.toml.
///
///      Test-only contracts used here (the router, `ScriptedHook`, `ReentrantToken`, `ReentryAgent`, `Mock1271Wallet`,
///      `MaliciousAuthModule`) are not deployed by the project; their build settings do not matter.
contract ProductionArtifactSecurityTest is Test {
    using TransientStateLibrary for IPoolManager;

    string internal constant VAULT_JSON = "out/SharedCommitmentVault.sol/SharedCommitmentVault.json";
    string internal constant HOOK_A_JSON = "out/HookA_DynamicFee.sol/HookA_DynamicFee.json";
    string internal constant HOOK_B_JSON = "out/HookB_BoundedImpact.sol/HookB_BoundedImpact.json";
    string internal constant PM_JSON = "out/PoolManager.sol/PoolManager.default.json";
    /// @dev Production optimizer settings from foundry.toml: the vault's compilation restriction and the default.
    uint256 internal constant VAULT_RUNS = 2000;
    uint256 internal constant DEFAULT_RUNS = 44_444_444;

    uint160 internal constant HOOK_FLAGS =
        Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 internal constant PRICE_1_1_X96 = uint160(FixedPoint96.Q96);
    uint256 internal constant FUNDING = 1_000_000 ether;

    IPoolManager internal manager;
    PoolSwapTest internal router;
    ReentrantToken internal t0;
    ReentrantToken internal t1;
    Currency internal c0;
    Currency internal c1;
    IBenchVault internal vault;
    ICuratorAuthorization internal auth;
    address internal hookA;
    address internal hookB;
    ScriptedHook internal scripted;
    PoolKey internal keyA;
    PoolKey internal keyB;
    PoolKey internal keyS;

    address internal owner = makeAddr("vaultOwner");
    address internal guardian = makeAddr("guardian");
    address internal hookOwner = makeAddr("hookOwner");
    address internal curator = makeAddr("curator");
    address internal curator2 = makeAddr("curator2");
    address internal trader = makeAddr("trader");
    address internal lp = makeAddr("lp");
    address internal stranger = makeAddr("stranger");
    uint256 internal nonce;

    function setUp() public {
        vm.warp(1_700_000_000);
        manager = IPoolManager(deployCode(PM_JSON, abi.encode(address(this))));
        router = new PoolSwapTest(manager);
        ReentrantToken a = new ReentrantToken("A", "A");
        ReentrantToken b = new ReentrantToken("B", "B");
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        c0 = Currency.wrap(address(t0));
        c1 = Currency.wrap(address(t1));

        vault = IBenchVault(deployCode(VAULT_JSON, abi.encode(manager, owner, c0, c1)));
        auth = _deployAuth(vault);
        hookA = address(uint160(0xA11CE << 140) | HOOK_FLAGS);
        hookB = address(uint160(0xB0B << 140) | HOOK_FLAGS);
        deployCodeTo(HOOK_A_JSON, abi.encode(manager, vault, hookOwner), hookA);
        deployCodeTo(HOOK_B_JSON, abi.encode(manager, vault, hookOwner), hookB);
        address s = address(uint160(0x5C1 << 140) | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        deployCodeTo("ScriptedHook.sol:ScriptedHook", abi.encode(manager, vault), s);
        scripted = ScriptedHook(s);

        keyA = PoolKey(c0, c1, 3000, 60, IHooks(hookA));
        keyB = PoolKey(c0, c1, 500, 10, IHooks(hookB));
        keyS = PoolKey(c0, c1, 3000, 60, IHooks(s));
        manager.initialize(keyA, SQRT_PRICE_1_1);
        manager.initialize(keyB, SQRT_PRICE_1_1);
        manager.initialize(keyS, SQRT_PRICE_1_1);
        vm.startPrank(hookOwner);
        IBenchHook(hookA).configurePool(keyA, PRICE_1_1_X96, 500, 5000);
        IBenchHook(hookB).configurePool(keyB, PRICE_1_1_X96, 10_000, 20_000);
        vm.stopPrank();

        vm.startPrank(owner);
        vault.setGuardian(guardian);
        vault.setAuthModule(address(auth));
        vault.setConsumer(hookA, true);
        vault.setConsumer(hookB, true);
        vault.setConsumer(s, true);
        vault.setSellFloor(c0, PRICE_1_1_X96);
        vault.setSellFloor(c1, PRICE_1_1_X96);
        address[3] memory cs = [curator, curator2, s];
        for (uint256 i; i < 3; ++i) {
            vault.setCurator(cs[i], true);
            vault.setCuratorCeiling(cs[i], c0, type(uint256).max);
            vault.setCuratorCeiling(cs[i], c1, type(uint256).max);
            _openLimits(ISharedCommitmentVault.RiskScope.Curator, cs[i]);
        }
        _openLimits(ISharedCommitmentVault.RiskScope.Vault, address(0));
        _openLimits(ISharedCommitmentVault.RiskScope.Hook, hookA);
        _openLimits(ISharedCommitmentVault.RiskScope.Hook, hookB);
        _openLimits(ISharedCommitmentVault.RiskScope.Hook, s);
        vm.stopPrank();

        _fund(owner, address(vault), FUNDING);
        vm.prank(owner);
        vault.initialDeposit(FUNDING, FUNDING, lp);
        _fund(trader, address(router), 10 * FUNDING);
        _fund(lp, address(vault), FUNDING);
    }

    // ------------------------------------------------------------------
    // The code under test is the production code
    // ------------------------------------------------------------------

    /// @notice Each contract under test came from an artifact compiled with its production settings (via-IR,
    ///         cancun, no metadata hash, and the production optimizer runs), and the deployed runtime code is that
    ///         artifact's byte for byte, immutables masked (`ProductionArtifacts.requireProduction`). The masked
    ///         runtime hashes are logged so a CI run records exactly which builds it tested.
    function test_PA_deployedCodeIsProductionArtifacts() public view {
        _assertProduction(address(vault), VAULT_JSON, VAULT_RUNS);
        _assertProduction(hookA, HOOK_A_JSON, DEFAULT_RUNS);
        _assertProduction(hookB, HOOK_B_JSON, DEFAULT_RUNS);
        _assertProduction(address(manager), PM_JSON, DEFAULT_RUNS);
        _assertProduction(address(auth), ProductionArtifacts.authModule(), DEFAULT_RUNS);
        ProductionArtifacts.requireProduction(address(vault), VAULT_JSON, VAULT_RUNS);
        ProductionArtifacts.requireProduction(hookA, HOOK_A_JSON, DEFAULT_RUNS);
        ProductionArtifacts.requireProduction(hookB, HOOK_B_JSON, DEFAULT_RUNS);
        ProductionArtifacts.requireProduction(address(manager), PM_JSON, DEFAULT_RUNS);
        ProductionArtifacts.requireProduction(address(auth), ProductionArtifacts.authModule(), DEFAULT_RUNS);
        console2.log("runtime keccak256 (immutables masked):");
        console2.logBytes32(ProductionArtifacts.artifactRuntimeHash(VAULT_JSON));
        console2.logBytes32(ProductionArtifacts.artifactRuntimeHash(HOOK_A_JSON));
        console2.logBytes32(ProductionArtifacts.artifactRuntimeHash(HOOK_B_JSON));
        console2.logBytes32(ProductionArtifacts.artifactRuntimeHash(PM_JSON));
        console2.logBytes32(ProductionArtifacts.artifactRuntimeHash(ProductionArtifacts.authModule()));
    }

    // ------------------------------------------------------------------
    // Settlement and currency-delta conservation
    // ------------------------------------------------------------------

    /// @notice A HookA swap (asset0 in) and a HookB swap (asset1 in) on production builds. For each: the trader's
    ///         ERC-20 movements equal the swap's BalanceDelta; the vault's claims move by exactly the accounted
    ///         amounts (B_a follows them); the PoolManager's ERC-20 holdings move by exactly what the trader paid
    ///         and received; Q_out and the allocation fall and rise by the output; the hook ends with no claims; and
    ///         every PoolManager currency delta is zero after the unlock.
    function test_PA_hookA_hookB_settlementConservation() public {
        _assertConservedSwap(keyA, true, _allocate(curator, keyA, c1, 100_000 ether), 1000 ether);
        _assertConservedSwap(keyB, false, _allocate(curator, keyB, c0, 100_000 ether), 2500 ether);
        _assertConservedSwap(keyA, false, _allocate(curator2, keyA, c0, 100_000 ether), 777 ether);
        _assertAccounting();
    }

    // ------------------------------------------------------------------
    // Curator restrictions
    // ------------------------------------------------------------------

    function test_PA_frozenCurator_executionRejected() public {
        uint256 idA = _allocate(curator, keyA, c1, 100_000 ether);
        uint256 idB = _allocate(curator, keyB, c0, 100_000 ether);
        _swap(keyA, true, 1000 ether, idA);
        vm.prank(guardian);
        vault.freezeCurator(curator);
        bytes memory frozen = abi.encodeWithSelector(
            ISharedCommitmentVault.CuratorRestricted.selector, curator, ISharedCommitmentVault.CuratorRestriction.Frozen
        );
        _swapReverts(keyA, true, 1000 ether, idA, frozen);
        _swapReverts(keyB, false, 1000 ether, idB, frozen);
        vm.prank(owner);
        vault.unfreezeCurator(curator);
        _swap(keyB, false, 1000 ether, idB);
        _assertAccounting();
    }

    function test_PA_revokedCurator_executionRejected_thenCleanup() public {
        uint256 idA = _allocate(curator, keyA, c1, 100_000 ether);
        uint256 idB = _allocate(curator, keyB, c0, 50_000 ether);
        _swap(keyA, true, 1000 ether, idA);
        vm.prank(guardian);
        vault.revokeCurator(curator);
        bytes memory revoked = abi.encodeWithSelector(
            ISharedCommitmentVault.CuratorRestricted.selector,
            curator,
            ISharedCommitmentVault.CuratorRestriction.Revoked
        );
        _swapReverts(keyA, true, 1000 ether, idA, revoked);
        _swapReverts(keyB, false, 1000 ether, idB, revoked);

        ISharedCommitmentVault.Allocation memory a = vault.getAllocation(idA);
        uint256 q1 = vault.reserved(c1);
        vm.prank(stranger);
        vault.release(idA);
        assertEq(q1 - vault.reserved(c1), a.maxOut - a.consumed, "exact remainder released");
        vm.prank(stranger);
        vault.release(idB);
        assertEq(vault.curatorReserved(curator, c0) + vault.curatorReserved(curator, c1), 0);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.InvalidCuratorTransition.selector,
                curator,
                ISharedCommitmentVault.CuratorRestriction.Revoked
            )
        );
        vault.setCurator(curator, true);
        _assertAccounting();
    }

    function test_PA_partialConsumptionThenCancellation() public {
        uint256 id = _allocate(curator, keyB, c0, 20_000 ether);
        _swap(keyB, false, 5000 ether, id);
        ISharedCommitmentVault.Allocation memory a = vault.getAllocation(id);
        assertGt(a.consumed, 0);
        uint256 q0 = vault.reserved(c0);
        uint256 b0 = vault.backing(c0);
        vm.prank(curator);
        vault.cancelAllocation(id);
        assertEq(q0 - vault.reserved(c0), a.maxOut - a.consumed);
        assertEq(vault.backing(c0), b0, "cancellation moved no assets");
        assertEq(vault.getAllocation(id).consumed, a.consumed);
        _swapReverts(
            keyB,
            false,
            1 ether,
            id,
            abi.encodeWithSelector(ISharedCommitmentVault.AllocationAlreadyReleased.selector, id)
        );
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.AllocationAlreadyReleased.selector, id));
        vault.cancelAllocation(id);
        _assertAccounting();
    }

    // ------------------------------------------------------------------
    // Reentrancy and a malicious registered hook
    // ------------------------------------------------------------------

    /// @notice A hook that is also the allocation's curator cancels between two consumptions inside one swap: the
    ///         swap reverts atomically. Withdrawing inside a swap fails at the production PoolManager
    ///         (`AlreadyUnlocked`). A pair-token callback during a deposit cannot re-enter the production vault.
    function test_PA_maliciousHookAndTokenReentrancy() public {
        bytes memory r =
            scripted.exec(address(auth), abi.encodeCall(auth.activateDirect, (_request(keyS, c1, 10_000 ether))));
        uint256 id = abi.decode(r, (uint256));
        ScriptedHook.Call[] memory none = new ScriptedHook.Call[](0);
        ScriptedHook.Call[] memory cancel = new ScriptedHook.Call[](1);
        cancel[0] = ScriptedHook.Call(address(vault), abi.encodeCall(vault.cancelAllocation, (id)));
        scripted.script(none, cancel, none, 400 ether);
        uint256 q1 = vault.reserved(c1);
        _swapReverts(
            keyS,
            true,
            1000 ether,
            id,
            abi.encodeWithSelector(ISharedCommitmentVault.AllocationAlreadyReleased.selector, id)
        );
        assertEq(vault.reserved(c1), q1, "nothing changed");
        assertFalse(vault.getAllocation(id).released);

        // The hook, holding shares as an LP, tries to redeem mid-swap.
        ScriptedHook.Call[] memory withdraw = new ScriptedHook.Call[](1);
        _fund(address(scripted), address(0), 100_000 ether);
        scripted.exec(address(t0), abi.encodeCall(t0.approve, (address(vault), type(uint256).max)));
        scripted.exec(address(t1), abi.encodeCall(t1.approve, (address(vault), type(uint256).max)));
        scripted.exec(address(vault), abi.encodeCall(vault.deposit, (1000 ether, 1e30, 1e30, address(scripted))));
        withdraw[0] = ScriptedHook.Call(
            address(vault), abi.encodeCall(vault.redeem, (100 ether, 0, 0, address(scripted), false))
        );
        scripted.script(none, withdraw, none, 0);
        _swapReverts(keyS, true, 1000 ether, id, abi.encodeWithSelector(IPoolManager.AlreadyUnlocked.selector));

        // Token callback during a deposit into the production vault.
        ReentryAgent agent = new ReentryAgent();
        t0.arm(address(agent), abi.encodeCall(agent.exec, (address(vault), abi.encodeCall(vault.processQueue, (1)))));
        vm.prank(lp);
        vault.deposit(1000 ether, 1e30, 1e30, lp);
        assertEq(t0.lastSelector(), ISharedCommitmentVault.ReentrantCall.selector);
        _assertAccounting();
    }

    // ------------------------------------------------------------------
    // LP exits under restricted trading
    // ------------------------------------------------------------------

    /// @notice Pause, a halted direction, a frozen curator and then a revoked one: LP exits keep working the whole
    ///         time. Committed capacity is not paid to redeemers while it is reserved; once a stranger releases the
    ///         revoked curator's allocation, the queue finalizes and is claimed; instant exits and request
    ///         cancellation work while paused.
    function test_PA_lpWithdrawalDuringRestrictedTrading() public {
        vm.prank(lp);
        vault.deposit(100_000 ether, 1e30, 1e30, lp);
        uint256 lock = _allocate(curator, keyA, c1, uint128(vault.admissibleCapacity(c1)));
        _swap(keyA, true, 1000 ether, lock);

        vm.startPrank(guardian);
        vault.setPaused(true);
        vault.setSellHalted(c1, true);
        vault.freezeCurator(curator);
        vm.stopPrank();

        vm.prank(lp);
        (uint256 instant,,, uint256 req) = vault.redeem(50_000 ether, 0, 0, lp, true);
        assertEq(instant, 0, "reserved capacity is not paid out");
        vm.prank(guardian);
        vault.revokeCurator(curator);
        vm.prank(stranger);
        vault.release(lock);
        assertGt(vault.processQueue(5), 0);
        uint256 bal1 = t1.balanceOf(lp);
        vm.prank(lp);
        (, uint256 o1) = vault.claim(req);
        assertEq(t1.balanceOf(lp) - bal1, o1);
        assertGt(o1, 0);

        vm.prank(lp);
        (uint256 instant2,,, uint256 req2) = vault.redeem(10_000 ether, 0, 0, lp, true);
        assertEq(instant2, 10_000 ether, "instant exit while paused");
        assertEq(req2, 0);
        _assertAccounting();
    }

    // ------------------------------------------------------------------
    // Hierarchical flow limits and exposure caps
    // ------------------------------------------------------------------

    /// @notice All three flow limits on production HookA and HookB. Each limit is driven to refusal by the route
    ///         that bypasses the level below it: a second swap on the same hook (hook limit), the same curator on
    ///         another hook (curator limit), another curator (vault limit). Each refusal reports exactly cap - used
    ///         as available, and a new window restores trading.
    function test_PA_flowLimits_allThreeLevels() public {
        _setLimit(HOOK, hookA, c1, 1500 ether, 10_000);
        _setLimit(CURATOR, curator, c1, 2500 ether, 10_000);
        _setLimit(VAULT, address(0), c1, 3200 ether, 10_000);
        uint256 a = _allocate(curator, keyA, c1, 100_000 ether);
        uint256 b = _allocate(curator, keyB, c1, 100_000 ether);
        uint256 c = _allocate(curator2, keyB, c1, 100_000 ether);

        _swap(keyA, true, 1000 ether, a);
        _swapRefusedByFlow(keyA, 1000 ether, a, HOOK, hookA);
        _swap(keyB, true, 1000 ether, b);
        _swapRefusedByFlow(keyB, 1000 ether, b, CURATOR, curator);
        _swap(keyB, true, 1000 ether, c);
        _swapRefusedByFlow(keyB, 1000 ether, c, VAULT, address(0));

        uint256 total = _used(VAULT, address(0), c1);
        assertEq(_used(HOOK, hookA, c1) + _used(HOOK, hookB, c1), total, "hooks sum to vault");
        assertEq(_used(CURATOR, curator, c1) + _used(CURATOR, curator2, c1), total, "curators sum to vault");
        assertEq(_used(VAULT, address(0), c0), 0, "other asset untouched");

        vm.warp((block.timestamp / 1 days + 1) * 1 days); // first second of the next window
        _swap(keyA, true, 1000 ether, a);
        assertLt(_used(VAULT, address(0), c1), total, "new window restarted usage");
        _assertAccounting();
    }

    /// @notice A hook that splits one swap into two `exchange` calls is charged for both; if the total exceeds the
    ///         limit the whole swap reverts and no record changes. Usage then accumulates across transactions.
    function test_PA_flowLimits_splitTradesAndRollback() public {
        _setLimit(HOOK, address(scripted), c1, 1000 ether, 10_000);
        bytes memory r =
            scripted.exec(address(auth), abi.encodeCall(auth.activateDirect, (_request(keyS, c1, 10_000 ether))));
        uint256 id = abi.decode(r, (uint256));
        ScriptedHook.Call[] memory none = new ScriptedHook.Call[](0);
        scripted.script(none, none, none, 500 ether);
        ISharedCommitmentVault.RiskLimit memory before = vault.getRiskLimit(VAULT, address(0), c1);
        _swapReverts(keyS, true, 1001 ether, id, _flowErr(HOOK, address(scripted), c1, 500 ether, 499 ether));
        assertEq(keccak256(abi.encode(vault.getRiskLimit(VAULT, address(0), c1))), keccak256(abi.encode(before)));
        assertEq(_used(HOOK, address(scripted), c1), 0, "first half rolled back");
        _swap(keyS, true, 600 ether, id); // two exchanges: 100 + 500
        assertEq(_used(HOOK, address(scripted), c1), 600 ether);
        scripted.script(none, none, none, 0);
        _swap(keyS, true, 400 ether, id); // a separate transaction
        assertEq(_used(HOOK, address(scripted), c1), 1000 ether, "accumulates across transactions");
        _swapReverts(keyS, true, 1, id, _flowErr(HOOK, address(scripted), c1, 1, 0));
    }

    /// @notice Exposure cap on production builds: at the cap, one unit above, after a deposit and after an instant
    ///         redemption. An allocation left above a tightened cap stays consumable.
    function test_PA_exposureCaps() public {
        _setLimit(VAULT, address(0), c1, type(uint104).max, 2500); // E = 1,000,000 ether: limit 250,000 ether
        _allocateRefusedByExposure(curator, keyA, 250_000 ether + 1, VAULT, address(0), 250_000 ether);
        uint256 a = _allocate(curator, keyA, c1, 250_000 ether);
        _allocateRefusedByExposure(curator2, keyB, 1, VAULT, address(0), 0);

        vm.prank(lp);
        vault.deposit(1_000_000 ether, type(uint256).max, type(uint256).max, lp); // E doubles
        _allocate(curator2, keyB, c1, 250_000 ether);
        vm.prank(lp);
        vault.redeem(1_000_000 ether, 0, 0, lp, false); // E back to 1,000,000 ether; 500,000 ether stay reserved
        assertEq(vault.reserved(c1), 500_000 ether);
        _allocateRefusedByExposure(curator, keyA, 1, VAULT, address(0), 0);
        vm.prank(guardian);
        vault.setRiskLimit(HOOK, hookA, c1, type(uint104).max, 0);
        _swap(keyA, true, 1000 ether, a); // existing commitment still executes
        assertEq(vault.hookReserved(hookA, c1), 250_000 ether - vault.getAllocation(a).consumed);
        _assertAccounting();
    }

    /// @notice Freeze, unfreeze, revocation and pause on production builds never change recorded usage, and LP
    ///         exits keep working with every flow record exhausted.
    function test_PA_flowUsageSurvivesLifecycle_lpExitsUnaffected() public {
        _setLimit(CURATOR, curator, c1, 1500 ether, 10_000);
        uint256 a = _allocate(curator, keyA, c1, 100_000 ether);
        _swap(keyA, true, 1000 ether, a);
        bytes32 snap = _flowSnap();
        vm.prank(guardian);
        vault.freezeCurator(curator);
        vm.prank(owner);
        vault.unfreezeCurator(curator);
        assertEq(_flowSnap(), snap);
        _swapRefusedByFlow(keyA, 1000 ether, a, CURATOR, curator);
        vm.startPrank(guardian);
        vault.revokeCurator(curator);
        vault.setRiskLimit(VAULT, address(0), c0, 0, 10_000);
        vault.setRiskLimit(VAULT, address(0), c1, 0, 10_000);
        vault.setPaused(true);
        vm.stopPrank();
        snap = _flowSnap();
        vm.prank(stranger);
        vault.release(a); // revoked curator: anyone may clean up
        vm.prank(lp);
        (uint256 instant,,,) = vault.redeem(10_000 ether, 0, 0, lp, false);
        assertEq(instant, 10_000 ether, "instant exit while paused with every flow cap at zero");
        assertEq(_flowSnap(), snap, "closes and LP exits changed no record");
    }

    /// @notice A second production vault with only the vault-wide record missing refuses to reserve (fail closed),
    ///         and window arithmetic on production builds survives 2^32 and fails closed past the 40-bit epoch.
    function test_PA_failClosedAndTimestampBoundaries() public {
        IBenchVault v = IBenchVault(deployCode(VAULT_JSON, abi.encode(manager, owner, c0, c1)));
        ICuratorAuthorization av = _deployAuth(v);
        vm.startPrank(owner);
        v.setAuthModule(address(av));
        v.setConsumer(hookA, true);
        v.setCurator(curator, true);
        v.setSellFloor(c1, PRICE_1_1_X96);
        v.setCuratorCeiling(curator, c1, type(uint256).max);
        v.setRiskLimit(HOOK, hookA, c1, 1 ether, 10_000);
        v.setRiskLimit(CURATOR, curator, c1, 1 ether, 10_000);
        vm.stopPrank();
        _fund(owner, address(v), 1000 ether);
        vm.prank(owner);
        v.initialDeposit(1000 ether, 1000 ether, owner);
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, 1 ether);
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(ISharedCommitmentVault.RiskLimitNotConfigured.selector, VAULT, address(0), c1)
        );
        av.activateDirect(req);

        _setLimit(CURATOR, curator, c1, 1500 ether, 10_000);
        vm.warp(2 ** 32 - 10);
        uint256 a = _allocate(curator, keyA, c1, 100_000 ether);
        _swap(keyA, true, 1000 ether, a);
        vm.warp(2 ** 32 + 10); // same window: no reset at the 32-bit wrap
        _swapRefusedByFlow(keyA, 1000 ether, a, CURATOR, curator);

        vm.warp((uint256(type(uint40).max) + 1) * 1 days);
        a = _allocate(curator, keyA, c1, 100_000 ether);
        _swapReverts(
            keyA,
            true,
            1000 ether,
            a,
            abi.encodeWithSelector(ISharedCommitmentVault.FlowEpochOutOfRange.selector, uint256(type(uint40).max) + 1)
        );
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // Curator authorization module (production build)
    // ------------------------------------------------------------------

    /// @notice A signed EOA instruction and an ERC-1271 wallet instruction, each submitted by a relayer, become
    ///         exactly the signed allocations and are consumed through HookA and HookB. The wallet then withdraws its
    ///         approval: a new instruction fails, while its existing allocation stays consumable and cancellable.
    function test_PA_auth_signedEoaAnd1271_activateAndSwap() public {
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(curator, keyA, c1, 100_000 ether);
        uint256 id = _activateSigned(a, keyA, _signAuth(_curatorKey(), a));
        ISharedCommitmentVault.Allocation memory al = vault.getAllocation(id);
        assertEq(al.curator, curator);
        assertEq(al.consumer, hookA);
        assertEq(al.maxOut, a.maxOut);
        assertEq(al.expiry, a.expiry);
        assertTrue(auth.isNonceUsed(curator, a.nonce));
        _assertConservedSwap(keyA, true, id, 1000 ether);

        Mock1271Wallet w = _walletCurator();
        ICuratorAuthorization.AllocationAuthorization memory b = _authz(address(w), keyB, c0, 50_000 ether);
        w.approve(auth.hashAuthorization(b), true);
        uint256 wid = _activateSigned(b, keyB, "");
        _assertConservedSwap(keyB, false, wid, 1000 ether);
        ICuratorAuthorization.AllocationAuthorization memory b2 = _authz(address(w), keyB, c0, 50_000 ether);
        vm.prank(stranger);
        vm.expectRevert(ICuratorAuthorization.InvalidSignature.selector);
        auth.activate(b2, keyB, "");
        _swap(keyB, false, 1000 ether, wid);
        w.exec(address(vault), abi.encodeCall(vault.cancelAllocation, (wid)));
        assertTrue(vault.getAllocation(wid).released);
        _assertAccounting();
    }

    /// @notice Replay and binding on the production module: wrong signer, a 64-byte signature, another chain,
    ///         another vault, an edited field, outside the time window, a spent and an invalidated nonce, a stale
    ///         generation, frozen and revoked curators, and a reservation the vault rejects (paused), which spends no
    ///         nonce.
    function test_PA_auth_replayAndBindingMatrix() public {
        uint256 k = _curatorKey();
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(curator, keyA, c1, 10_000 ether);
        bytes memory sig = _signAuth(k, a);
        (, uint256 otherKey) = makeAddrAndKey("other");
        bytes memory otherSig = _signAuth(otherKey, a);
        _activateReverts(a, keyA, otherSig, abi.encodeWithSelector(ICuratorAuthorization.InvalidSignature.selector));
        _activateReverts(
            a, keyA, _first64(sig), abi.encodeWithSelector(ICuratorAuthorization.InvalidSignature.selector)
        );
        vm.chainId(130);
        _activateReverts(a, keyA, sig, abi.encodeWithSelector(ICuratorAuthorization.InvalidSignature.selector));
        vm.chainId(31_337);
        ICuratorAuthorization.AllocationAuthorization memory e = _copyAuth(a);
        e.vault = stranger;
        _activateReverts(e, keyA, sig, abi.encodeWithSelector(ICuratorAuthorization.WrongVault.selector, stranger));
        e = _copyAuth(a);
        e.maxOut += 1;
        _activateReverts(e, keyA, sig, abi.encodeWithSelector(ICuratorAuthorization.InvalidSignature.selector));
        vm.warp(a.deadline + 1);
        _activateReverts(
            a, keyA, sig, abi.encodeWithSelector(ICuratorAuthorization.AuthorizationExpired.selector, a.deadline)
        );
        vm.warp(a.validAfter);

        ICuratorAuthorization.AllocationAuthorization memory late = _authz(curator, keyA, c1, 10_000 ether);
        late.validAfter = a.validAfter + 60;
        bytes memory lateSig = _signAuth(k, late);
        _activateReverts(
            late,
            keyA,
            lateSig,
            abi.encodeWithSelector(ICuratorAuthorization.AuthorizationNotYetValid.selector, late.validAfter)
        );

        vm.prank(guardian);
        vault.setPaused(true);
        _activateReverts(a, keyA, sig, abi.encodeWithSelector(ISharedCommitmentVault.Paused.selector));
        assertFalse(auth.isNonceUsed(curator, a.nonce), "rejected reservation spends no nonce");
        vm.prank(owner);
        vault.setPaused(false);
        _activateSigned(a, keyA, sig);
        _activateReverts(
            a, keyA, sig, abi.encodeWithSelector(ICuratorAuthorization.NonceAlreadyUsed.selector, curator, a.nonce)
        );

        ICuratorAuthorization.AllocationAuthorization memory inv = _authz(curator, keyA, c1, 10_000 ether);
        bytes memory invSig = _signAuth(k, inv);
        vm.prank(curator);
        auth.invalidateNonces(inv.nonce >> 8, 1 << (inv.nonce & 0xff));
        _activateReverts(
            inv,
            keyA,
            invSig,
            abi.encodeWithSelector(ICuratorAuthorization.NonceAlreadyUsed.selector, curator, inv.nonce)
        );

        ICuratorAuthorization.AllocationAuthorization memory g = _authz(curator, keyA, c1, 10_000 ether);
        bytes memory gSig = _signAuth(k, g);
        vm.prank(curator);
        vault.bumpGeneration();
        _activateReverts(
            g,
            keyA,
            gSig,
            abi.encodeWithSelector(
                ISharedCommitmentVault.StaleGeneration.selector, curator, g.generation, g.generation + 1
            )
        );

        vm.prank(guardian);
        vault.freezeCurator(curator);
        ICuratorAuthorization.AllocationAuthorization memory f = _authz(curator, keyA, c1, 10_000 ether);
        bytes memory fSig = _signAuth(k, f);
        _activateReverts(
            f,
            keyA,
            fSig,
            abi.encodeWithSelector(
                ISharedCommitmentVault.CuratorRestricted.selector,
                curator,
                ISharedCommitmentVault.CuratorRestriction.Frozen
            )
        );
        vm.prank(guardian);
        vault.revokeCurator(curator);
        _activateReverts(
            f,
            keyA,
            fSig,
            abi.encodeWithSelector(
                ISharedCommitmentVault.CuratorRestricted.selector,
                curator,
                ISharedCommitmentVault.CuratorRestriction.Revoked
            )
        );
    }

    /// @notice The guardian disables the production module: signed and direct activation stop, while swaps,
    ///         cancellation, release and every LP path keep working. The owner installs a new production module; the
    ///         old one can never come back, old signatures fail on the new domain, and new ones work.
    function test_PA_auth_disableReplaceAndLpPaths() public {
        uint256 id = _allocate(curator, keyA, c1, 100_000 ether);
        uint256 id2 = _allocate(curator2, keyB, c0, 100_000 ether);
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(curator, keyA, c1, 1000 ether);
        bytes memory oldSig = _signAuth(_curatorKey(), a);
        vm.prank(guardian);
        vault.setAuthModule(address(0));

        _activateReverts(
            a, keyA, oldSig, abi.encodeWithSelector(ISharedCommitmentVault.NotAuthModule.selector, address(auth))
        );
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyA, c1, 1000 ether);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NotAuthModule.selector, address(auth)));
        auth.activateDirect(r);

        _swap(keyA, true, 1000 ether, id);
        vm.prank(curator2);
        vault.cancelAllocation(id2);
        vm.prank(lp);
        vault.deposit(1000 ether, type(uint256).max, type(uint256).max, lp);
        vm.prank(lp);
        (,,, uint256 req) = vault.redeem(500 ether, 0, 0, lp, true);
        vault.processQueue(5);
        if (req != 0) {
            vm.prank(lp);
            vault.claim(req);
        }
        vm.prank(guardian);
        vault.release(id);

        ICuratorAuthorization m2 = _deployAuth(vault);
        vm.prank(owner);
        vault.setAuthModule(address(m2));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.AuthModuleRetired.selector, address(auth)));
        vault.setAuthModule(address(auth));
        vm.prank(stranger);
        vm.expectRevert(ICuratorAuthorization.InvalidSignature.selector);
        m2.activate(a, keyA, oldSig);
        (uint8 v, bytes32 rr, bytes32 s) = vm.sign(_curatorKey(), m2.hashAuthorization(a));
        vm.prank(stranger);
        uint256 nid = m2.activate(a, keyA, abi.encodePacked(rr, s, v));
        _swap(keyA, true, 500 ether, nid);
        _assertAccounting();
    }

    /// @notice The same request through the signed and the direct path gives the same allocation and reservation
    ///         changes. Two instructions competing for the last backing: the first wins, the second fails admission
    ///         and keeps its nonce. A signature does not lift the exposure cap or the flow cap.
    function test_PA_auth_equivalenceCompetitionAndCaps() public {
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(curator, keyB, c0, 25_000 ether);
        bytes memory sig = _signAuth(_curatorKey(), a);
        uint256 snap = vm.snapshotState();
        uint256 idS = _activateSigned(a, keyB, sig);
        bytes32 viaSigned =
            keccak256(abi.encode(vault.getAllocation(idS), vault.reserved(c0), vault.curatorReserved(curator, c0)));
        vm.revertToState(snap);
        vm.prank(curator);
        uint256 idD = auth.activateDirect(
            ISharedCommitmentVault.AllocationRequest({
                consumer: a.hook,
                key: keyB,
                currencyOut: a.currencyOut,
                maxOut: a.maxOut,
                minInPerOutX96: a.minInPerOutX96,
                expiry: a.expiry,
                nonce: a.nonce,
                deadline: a.deadline
            })
        );
        assertEq(idD, idS);
        assertEq(
            keccak256(abi.encode(vault.getAllocation(idD), vault.reserved(c0), vault.curatorReserved(curator, c0))),
            viaSigned
        );

        uint256 room = vault.admissibleCapacity(c0);
        ICuratorAuthorization.AllocationAuthorization memory big = _authz(curator, keyA, c0, uint128(room - 5));
        ICuratorAuthorization.AllocationAuthorization memory rival = _authz(curator, keyA, c0, 10);
        bytes memory bigSig = _signAuth(_curatorKey(), big);
        bytes memory rivalSig = _signAuth(_curatorKey(), rival);
        _activateSigned(big, keyA, bigSig);
        _activateReverts(
            rival, keyA, rivalSig, abi.encodeWithSelector(ISharedCommitmentVault.InsufficientBacking.selector, 10, 5)
        );
        assertFalse(auth.isNonceUsed(curator, rival.nonce));

        _setLimit(CURATOR, curator2, c1, 300 ether, 100); // 1% exposure, 300 flow per window
        uint256 cap = vault.getRiskLimit(CURATOR, curator2, c1).maxReservedBps
            * (vault.backing(c1) - vault.claimableAssets(c1)) / 10_000;
        (address c2, uint256 k2) = makeAddrAndKey("curator2");
        assertEq(c2, curator2);
        ICuratorAuthorization.AllocationAuthorization memory over = _authz(curator2, keyA, c1, uint128(cap + 1));
        bytes memory overSig = _signAuth(k2, over);
        _activateReverts(
            over,
            keyA,
            overSig,
            abi.encodeWithSelector(
                ISharedCommitmentVault.ExposureCapExceeded.selector, CURATOR, curator2, c1, cap + 1, cap
            )
        );
        ICuratorAuthorization.AllocationAuthorization memory ok = _authz(curator2, keyA, c1, uint128(cap));
        uint256 id = _activateSigned(ok, keyA, _signAuth(k2, ok));
        _swapRefusedByFlow(keyA, 1000 ether, id, CURATOR, curator2); // the flow cap binds a signed allocation
    }

    /// @notice A malicious module installed by mistake forges `reserveFor` against the production vault: every
    ///         vault-side check still applies, it cannot touch allocations or limits, and the guardian removes it.
    function test_PA_auth_compromisedModuleBounded() public {
        MaliciousAuthModule mal = new MaliciousAuthModule(ISharedCommitmentVault(address(vault)));
        vm.prank(owner);
        vault.setAuthModule(address(mal));
        vm.prank(owner);
        vault.setCuratorCeiling(curator2, c1, 1000 ether);
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyA, c1, 1001 ether);
        vm.expectRevert(
            abi.encodeWithSelector(ISharedCommitmentVault.CuratorCeilingExceeded.selector, 1001 ether, 1000 ether)
        );
        mal.forge(r, curator2, 0);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.CuratorNotRegistered.selector, stranger));
        mal.forge(_request(keyA, c1, 1 ether), stranger, 0);
        r = _request(keyA, c1, 1 ether);
        r.minInPerOutX96 = PRICE_1_1_X96 - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.FloorBelowVaultMinimum.selector, PRICE_1_1_X96 - 1, PRICE_1_1_X96
            )
        );
        mal.forge(r, curator2, 0);
        uint256 id = mal.forge(_request(keyA, c1, 1000 ether), curator2, 0);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NotAllocationCurator.selector, id, address(mal)));
        mal.exec(address(vault), abi.encodeCall(vault.cancelAllocation, (id)));
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.ConsumerNotRegistered.selector, address(mal)));
        mal.exec(address(vault), abi.encodeCall(vault.exchange, (keyA, true, id, 1 ether, 1 ether)));
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        mal.exec(address(vault), abi.encodeCall(vault.setCuratorCeiling, (curator2, c1, type(uint256).max)));
        vm.startPrank(guardian);
        vault.setAuthModule(address(0));
        vault.release(id);
        vm.stopPrank();
        _assertAccounting();
    }

    /// @notice A curator wallet that tries to cancel its own allocation from inside `isValidSignature` cannot: the
    ///         call runs under `staticcall`, the wallet's strict mode rejects its own instruction, and the allocation
    ///         is untouched.
    function test_PA_auth_reentrantWalletIsStatic() public {
        Mock1271Wallet w = _walletCurator();
        ICuratorAuthorization.AllocationAuthorization memory a0 = _authz(address(w), keyB, c0, 5000 ether);
        w.approve(auth.hashAuthorization(a0), true);
        uint256 live = _activateSigned(a0, keyB, "");
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(address(w), keyB, c0, 5000 ether);
        w.approve(auth.hashAuthorization(a), true);
        w.setMode(Mock1271Wallet.Mode.ReenterStrict);
        w.setReentry(address(vault), abi.encodeCall(vault.cancelAllocation, (live)));
        vm.prank(stranger);
        (bool ok, bytes memory ret) = address(auth).call{gas: 5_000_000}(abi.encodeCall(auth.activate, (a, keyB, "")));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(ICuratorAuthorization.InvalidSignature.selector));
        assertFalse(vault.getAllocation(live).released);
        assertFalse(auth.isNonceUsed(address(w), a.nonce));
    }

    ISharedCommitmentVault.RiskScope internal constant HOOK = ISharedCommitmentVault.RiskScope.Hook;
    ISharedCommitmentVault.RiskScope internal constant CURATOR = ISharedCommitmentVault.RiskScope.Curator;
    ISharedCommitmentVault.RiskScope internal constant VAULT = ISharedCommitmentVault.RiskScope.Vault;

    function _setLimit(ISharedCommitmentVault.RiskScope scope, address account, Currency c, uint256 cap, uint16 bps)
        internal
    {
        vm.prank(owner);
        vault.setRiskLimit(scope, account, c, cap, bps);
    }

    /// @dev Current-window usage, from the stored record (all tests here stay within known windows).
    function _used(ISharedCommitmentVault.RiskScope scope, address account, Currency c)
        internal
        view
        returns (uint256)
    {
        ISharedCommitmentVault.RiskLimit memory r = vault.getRiskLimit(scope, account, c);
        return r.epoch == block.timestamp / 1 days ? r.flowUsed : 0;
    }

    function _flowErr(
        ISharedCommitmentVault.RiskScope scope,
        address account,
        Currency c,
        uint256 requested,
        uint256 available
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            ISharedCommitmentVault.FlowLimitExceeded.selector, scope, account, c, requested, available
        );
    }

    /// @dev Expects a swap selling token1 through a production hook to be refused by the given flow record. The
    ///      hook's exact output is not known in advance, so the wrapped reason is decoded: it must be
    ///      FlowLimitExceeded for this record, with `available` equal to cap - used read just before, and with a
    ///      requested amount above that. No record may change.
    function _swapRefusedByFlow(
        PoolKey memory key,
        uint256 amountIn,
        uint256 id,
        ISharedCommitmentVault.RiskScope scope,
        address account
    ) internal {
        ISharedCommitmentVault.RiskLimit memory r = vault.getRiskLimit(scope, account, c1);
        uint256 used = _used(scope, account, c1);
        uint256 available = r.flowCap > used ? r.flowCap - used : 0;
        bytes32 snap = _flowSnap();
        vm.prank(trader);
        try router.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(id)
        ) {
            assertTrue(false, "swap was not refused");
        } catch (bytes memory err) {
            assertEq(bytes4(err), CustomRevert.WrappedError.selector, "not a wrapped hook revert");
            (address hook,, bytes memory reason,) = abi.decode(_tail(err), (address, bytes4, bytes, bytes));
            assertEq(hook, address(key.hooks));
            assertEq(bytes4(reason), ISharedCommitmentVault.FlowLimitExceeded.selector, "not a flow refusal");
            (ISharedCommitmentVault.RiskScope s_, address a_, Currency c_, uint256 req, uint256 avail) =
                abi.decode(_tail(reason), (ISharedCommitmentVault.RiskScope, address, Currency, uint256, uint256));
            assertEq(uint8(s_), uint8(scope), "scope");
            assertEq(a_, account, "account");
            assertEq(Currency.unwrap(c_), Currency.unwrap(c1), "currency");
            assertEq(avail, available, "available != cap - used");
            assertGt(req, avail);
        }
        assertEq(_flowSnap(), snap, "a refused swap changed a record");
    }

    function _allocateRefusedByExposure(
        address who,
        PoolKey memory key,
        uint128 maxOut,
        ISharedCommitmentVault.RiskScope scope,
        address account,
        uint256 available
    ) internal {
        ISharedCommitmentVault.AllocationRequest memory req = _request(key, c1, maxOut);
        vm.prank(who);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.ExposureCapExceeded.selector, scope, account, c1, maxOut, available
            )
        );
        auth.activateDirect(req);
    }

    /// @dev Hash of every flow record the fixture uses, in both assets.
    function _flowSnap() internal view returns (bytes32 h) {
        address[6] memory accounts = [hookA, hookB, address(scripted), curator, curator2, address(0)];
        for (uint256 i; i < 6; ++i) {
            ISharedCommitmentVault.RiskScope scope = i < 3 ? HOOK : i < 5 ? CURATOR : VAULT;
            h = keccak256(
                abi.encode(h, vault.getRiskLimit(scope, accounts[i], c0), vault.getRiskLimit(scope, accounts[i], c1))
            );
        }
    }

    function _tail(bytes memory data) internal pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[i + 4];
        }
    }

    function _assertProduction(address deployed, string memory artifact, uint256 runs) internal view {
        string memory json = vm.readFile(artifact);
        assertEq(vm.parseJsonUint(json, ".metadata.settings.optimizer.runs"), runs, string.concat(artifact, ": runs"));
        assertTrue(vm.parseJsonBool(json, ".metadata.settings.viaIR"), string.concat(artifact, ": viaIR"));
        assertEq(vm.parseJsonString(json, ".metadata.settings.evmVersion"), "cancun", string.concat(artifact, ": evm"));
        assertEq(deployed.code.length, vm.getDeployedCode(artifact).length, string.concat(artifact, ": code"));
    }

    function _curatorKey() internal returns (uint256 k) {
        address a;
        (a, k) = makeAddrAndKey("curator");
        assertEq(a, curator);
    }

    function _authz(address cur, PoolKey memory key, Currency out, uint128 maxOut)
        internal
        returns (ICuratorAuthorization.AllocationAuthorization memory)
    {
        uint256 now_ = vm.getBlockTimestamp();
        return ICuratorAuthorization.AllocationAuthorization({
            curator: cur,
            generation: vault.getCurator(cur).generation,
            vault: address(vault),
            poolId: key.toId(),
            hook: address(key.hooks),
            currencyIn: out == key.currency1 ? key.currency0 : key.currency1,
            currencyOut: out,
            zeroForOne: out == key.currency1,
            maxOut: maxOut,
            minInPerOutX96: PRICE_1_1_X96,
            expiry: uint64(now_ + 1 days),
            validAfter: uint64(now_),
            deadline: uint64(now_ + 1 hours),
            nonce: nonce++
        });
    }

    function _signAuth(uint256 k, ICuratorAuthorization.AllocationAuthorization memory a)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(k, auth.hashAuthorization(a));
        return abi.encodePacked(r, s, v);
    }

    function _activateSigned(
        ICuratorAuthorization.AllocationAuthorization memory a,
        PoolKey memory key,
        bytes memory sig
    ) internal returns (uint256) {
        vm.prank(stranger);
        return auth.activate(a, key, sig);
    }

    function _activateReverts(
        ICuratorAuthorization.AllocationAuthorization memory a,
        PoolKey memory key,
        bytes memory sig,
        bytes memory err
    ) internal {
        vm.prank(stranger);
        vm.expectRevert(err);
        auth.activate(a, key, sig);
    }

    function _copyAuth(ICuratorAuthorization.AllocationAuthorization memory a)
        internal
        pure
        returns (ICuratorAuthorization.AllocationAuthorization memory)
    {
        return abi.decode(abi.encode(a), (ICuratorAuthorization.AllocationAuthorization));
    }

    function _first64(bytes memory sig) internal pure returns (bytes memory out) {
        out = new bytes(64);
        for (uint256 i; i < 64; ++i) {
            out[i] = sig[i];
        }
    }

    /// @dev A contract-wallet curator registered with open limits.
    function _walletCurator() internal returns (Mock1271Wallet w) {
        w = new Mock1271Wallet();
        vm.startPrank(owner);
        vault.setCurator(address(w), true);
        vault.setCuratorCeiling(address(w), c0, type(uint256).max);
        vault.setCuratorCeiling(address(w), c1, type(uint256).max);
        _openLimits(ISharedCommitmentVault.RiskScope.Curator, address(w));
        vm.stopPrank();
    }

    function _deployAuth(IBenchVault v) internal returns (ICuratorAuthorization) {
        return ICuratorAuthorization(deployCode(ProductionArtifacts.authModule(), abi.encode(v)));
    }

    function _fund(address who, address spender, uint256 amount) internal {
        t0.mint(who, amount);
        t1.mint(who, amount);
        if (spender == address(0)) return;
        vm.startPrank(who);
        t0.approve(spender, type(uint256).max);
        t1.approve(spender, type(uint256).max);
        vm.stopPrank();
    }

    function _request(PoolKey memory key, Currency out, uint128 maxOut)
        internal
        returns (ISharedCommitmentVault.AllocationRequest memory)
    {
        return ISharedCommitmentVault.AllocationRequest({
            consumer: address(key.hooks),
            key: key,
            currencyOut: out,
            maxOut: maxOut,
            minInPerOutX96: PRICE_1_1_X96,
            expiry: uint64(block.timestamp + 1 days),
            nonce: nonce++,
            deadline: uint64(block.timestamp)
        });
    }

    function _allocate(address who, PoolKey memory key, Currency out, uint128 maxOut) internal returns (uint256) {
        ISharedCommitmentVault.AllocationRequest memory req = _request(key, out, maxOut);
        vm.prank(who);
        return auth.activateDirect(req);
    }

    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn, uint256 id)
        internal
        returns (BalanceDelta d)
    {
        vm.prank(trader);
        d = router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(id)
        );
    }

    function _swapReverts(PoolKey memory key, bool zeroForOne, uint256 amountIn, uint256 id, bytes memory reason)
        internal
    {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(key.hooks),
                IHooks.beforeSwap.selector,
                reason,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        _swap(key, zeroForOne, amountIn, id);
    }

    function _assertConservedSwap(PoolKey memory key, bool zeroForOne, uint256 id, uint256 amountIn) internal {
        (Currency cin, Currency cout) = zeroForOne ? (c0, c1) : (c1, c0);
        ReentrantToken tin = zeroForOne ? t0 : t1;
        ReentrantToken tout = zeroForOne ? t1 : t0;
        uint256[8] memory p = [
            tin.balanceOf(trader),
            tout.balanceOf(trader),
            tin.balanceOf(address(manager)),
            tout.balanceOf(address(manager)),
            manager.balanceOf(address(vault), cin.toId()),
            manager.balanceOf(address(vault), cout.toId()),
            vault.reserved(cout),
            uint256(vault.getAllocation(id).consumed)
        ];
        BalanceDelta d = _swap(key, zeroForOne, amountIn, id);
        (int128 dIn, int128 dOut) = zeroForOne ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        assertEq(dIn, -int128(int256(amountIn)), "exact input");
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 out = uint256(int256(dOut));
        assertGt(out, 0);
        assertEq(p[0] - tin.balanceOf(trader), amountIn, "trader paid exactly the input");
        assertEq(tout.balanceOf(trader) - p[1], out, "trader received exactly the output");
        assertEq(tin.balanceOf(address(manager)) - p[2], amountIn, "PM ERC-20 in");
        assertEq(p[3] - tout.balanceOf(address(manager)), out, "PM ERC-20 out");
        assertEq(manager.balanceOf(address(vault), cin.toId()) - p[4], amountIn, "vault claims in");
        assertEq(p[5] - manager.balanceOf(address(vault), cout.toId()), out, "vault claims out");
        assertEq(p[6] - vault.reserved(cout), out, "Q_out fell by the output");
        assertEq(vault.getAllocation(id).consumed - p[7], out, "allocation consumed the output");
        address[4] memory accounts = [address(key.hooks), address(vault), address(router), trader];
        for (uint256 i; i < 4; ++i) {
            assertEq(manager.currencyDelta(accounts[i], c0), 0, "open delta asset0");
            assertEq(manager.currencyDelta(accounts[i], c1), 0, "open delta asset1");
        }
        assertEq(manager.getNonzeroDeltaCount(), 0, "non-zero deltas remain");
        assertFalse(manager.isUnlocked(), "PoolManager left unlocked");
    }

    /// @dev B_a equals the vault's real claim balance (no donations here), Q_a + W_a <= B_a, the PoolManager holds
    ///      at least the ERC-20 behind the vault's claims, and no hook keeps claims.
    function _assertAccounting() internal view {
        Currency[2] memory cs = [c0, c1];
        address[3] memory hooks = [hookA, hookB, address(scripted)];
        for (uint256 i; i < 2; ++i) {
            Currency c = cs[i];
            uint256 claims = manager.balanceOf(address(vault), c.toId());
            assertEq(vault.backing(c), claims, "B != claims");
            assertLe(vault.reserved(c) + vault.claimableAssets(c), vault.backing(c), "Q + W > B");
            assertGe(ReentrantToken(Currency.unwrap(c)).balanceOf(address(manager)), claims, "PM ERC-20 < claims");
            for (uint256 j; j < 3; ++j) {
                assertEq(manager.balanceOf(hooks[j], c.toId()), 0, "hook kept claims");
            }
        }
    }

    /// @dev Configures `account` at `scope` in both assets with the widest limits (largest flow cap, 100% exposure).
    ///      Caller must already be pranking as the owner.
    function _openLimits(ISharedCommitmentVault.RiskScope scope, address account) internal {
        vault.setRiskLimit(scope, account, c0, type(uint104).max, 10_000);
        vault.setRiskLimit(scope, account, c1, type(uint104).max, 10_000);
    }
}
