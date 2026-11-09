// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

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
import {IBenchVault, IBenchHook} from "./IBench.sol";
import {ReentrantToken, ReentryAgent} from "../utils/ReentrantToken.sol";
import {ScriptedHook} from "../utils/ScriptedHook.sol";

/// @title Production-artifact security tests
/// @notice Security-relevant paths run against the exact bytecode that would be deployed: the vault, HookA, HookB and
///         the pinned v4 PoolManager are each deployed from their production artifact file.
/// @dev Why this file exists. Functional test files import the vault source, so Foundry compiles them, together with
///      the hooks and the PoolManager they import, under the vault's optimizer profile (2,000 runs). Inside those
///      files the hooks and the PoolManager are therefore 2,000-run builds, not the production builds (44,444,444
///      runs). The vault itself has a single artifact, so it is the production build everywhere.
///
///      How production builds are guaranteed here. Contracts are deployed from explicit artifact paths
///      (`out/<File>.sol/<Name>.json`), not by name, so the result does not depend on the profile this file is
///      compiled under. `test_PA_deployedCodeIsProductionArtifacts` reads the optimizer settings recorded in each of
///      those artifact files and checks that each deployed code length equals its artifact's. It does not rely on the
///      2,000-run test builds being present in `out/`: other tools (for example Slither's `forge build --skip test`)
///      can remove them. Reading artifacts needs the read-only `fs_permissions` entry for `./out` in foundry.toml.
///
///      Test-only contracts used here (the router, `ScriptedHook`, `ReentrantToken`, `ReentryAgent`) are not
///      deployed by the project; their build settings do not matter.
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
    ///         cancun, no metadata hash, and the production optimizer runs), and the deployed code is that artifact's.
    function test_PA_deployedCodeIsProductionArtifacts() public view {
        _assertProduction(address(vault), VAULT_JSON, VAULT_RUNS);
        _assertProduction(hookA, HOOK_A_JSON, DEFAULT_RUNS);
        _assertProduction(hookB, HOOK_B_JSON, DEFAULT_RUNS);
        _assertProduction(address(manager), PM_JSON, DEFAULT_RUNS);
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
            scripted.exec(address(vault), abi.encodeCall(vault.allocate, (_request(keyS, c1, 10_000 ether))));
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
    // Helpers
    // ------------------------------------------------------------------

    function _assertProduction(address deployed, string memory artifact, uint256 runs) internal view {
        string memory json = vm.readFile(artifact);
        assertEq(vm.parseJsonUint(json, ".metadata.settings.optimizer.runs"), runs, string.concat(artifact, ": runs"));
        assertTrue(vm.parseJsonBool(json, ".metadata.settings.viaIR"), string.concat(artifact, ": viaIR"));
        assertEq(vm.parseJsonString(json, ".metadata.settings.evmVersion"), "cancun", string.concat(artifact, ": evm"));
        assertEq(deployed.code.length, vm.getDeployedCode(artifact).length, string.concat(artifact, ": code"));
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
        return vault.allocate(req);
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
