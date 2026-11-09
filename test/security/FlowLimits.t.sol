// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdError} from "forge-std/StdError.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {AuthModeHook} from "../utils/AuthModeHook.sol";
import {ScriptedHook} from "../utils/ScriptedHook.sol";
import {MaliciousConsumerHook} from "../utils/MaliciousConsumerHook.sol";
import {BatchSwapRouter} from "../utils/BatchSwapRouter.sol";

/// @notice Hierarchical gross-outflow limits (per hook, per curator, vault-wide) on the real PoolManager.
/// @dev Most tests trade through 1:1, fee-free test hooks (`AuthModeHook`), so the vault's output equals the swap's
///      input exactly and a limit can be hit to the last unit. `test_FL_normalSwap_recordsAllThreeScopes` uses the
///      production HookA. All amounts are in the vault's output asset (token1 unless stated).
///
///      What these tests establish:
///        - every successful `exchange` adds its exact output to all three records, and any one record at its cap
///          stops the trade;
///        - none of the bypass routes in `MODULAR_RISK_ENGINE.md` §7.1 works: more allocations, more pools on one
///          hook, more hooks for one curator, more curators, split trades in one or several transactions;
///        - usage is reset only by a new fixed window, never by inflows, closes, configuration changes, curator or
///          hook state changes, or LP operations;
///        - window arithmetic uses full timestamps: no reset at 2^32 (February 2106), fail closed when the epoch no
///          longer fits 40 bits;
///        - any revert rolls back every record.
contract FlowLimitsTest is VaultTestBase {
    ISharedCommitmentVault.RiskScope internal constant HOOK = ISharedCommitmentVault.RiskScope.Hook;
    ISharedCommitmentVault.RiskScope internal constant CURATOR = ISharedCommitmentVault.RiskScope.Curator;
    ISharedCommitmentVault.RiskScope internal constant VAULT = ISharedCommitmentVault.RiskScope.Vault;
    uint256 internal constant W = 1 days;

    address internal guardian = makeAddr("guardian");
    address internal curator2 = makeAddr("curator2");
    address internal e1;
    address internal e2;
    PoolKey internal keyE1; // hook e1, pool 1
    PoolKey internal keyE1b; // hook e1, pool 2 (same hook, different fee and tick spacing)
    PoolKey internal keyE2; // hook e2

    function setUp() public override {
        super.setUp();
        uint160 flags = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        e1 = address(uint160(0x0E1 << 140) | flags);
        e2 = address(uint160(0x0E2 << 140) | flags);
        deployCodeTo("AuthModeHook.sol:AuthModeHook", abi.encode(manager, vault, AuthModeHook.Mode.Operator), e1);
        deployCodeTo("AuthModeHook.sol:AuthModeHook", abi.encode(manager, vault, AuthModeHook.Mode.Operator), e2);
        keyE1 = PoolKey(c0, c1, 3000, 60, IHooks(e1));
        keyE1b = PoolKey(c0, c1, 500, 10, IHooks(e1));
        keyE2 = PoolKey(c0, c1, 3000, 60, IHooks(e2));
        manager.initialize(keyE1, SQRT_PRICE_1_1);
        manager.initialize(keyE1b, SQRT_PRICE_1_1);
        manager.initialize(keyE2, SQRT_PRICE_1_1);
        vm.startPrank(owner);
        vault.setGuardian(guardian);
        vault.setConsumer(e1, true);
        vault.setConsumer(e2, true);
        vault.setCurator(curator2, true);
        vault.setCuratorCeiling(curator2, c0, VAULT_FUNDING);
        vault.setCuratorCeiling(curator2, c1, VAULT_FUNDING);
        _openLimits(HOOK, e1);
        _openLimits(HOOK, e2);
        _openLimits(CURATOR, curator2);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Normal path and each limit on its own
    // ------------------------------------------------------------------

    /// @notice A HookA swap (production build) adds its exact output, as moved in ERC-6909 claims, to the hook's,
    ///         the curator's and the vault's records of the output asset, and to nothing else.
    function test_FL_normalSwap_recordsAllThreeScopes() public {
        uint256 id = _allocate(keyA, c1, 100_000 ether);
        uint256 claimsBefore = _claims(address(vault), c1);
        _swap(keyA, true, 1000 ether, id);
        uint256 out = claimsBefore - _claims(address(vault), c1);
        assertGt(out, 0);
        assertEq(vault.getAllocation(id).consumed, out);
        assertEq(_used(HOOK, address(hookA), c1), out, "hook");
        assertEq(_used(CURATOR, curator, c1), out, "curator");
        assertEq(_used(VAULT, address(0), c1), out, "vault");
        assertEq(vault.getRiskLimit(VAULT, address(0), c1).epoch, block.timestamp / W, "window recorded");
        // The input asset and unrelated scopes are untouched: inflows are never netted.
        assertEq(_used(HOOK, address(hookA), c0) + _used(CURATOR, curator, c0) + _used(VAULT, address(0), c0), 0);
        assertEq(_used(HOOK, address(hookB), c1), 0);
        _assertAccountingConsistent();
    }

    function test_FL_hookLimit_exhaustion() public {
        _setFlow(HOOK, e1, c1, 1000 ether);
        uint256 id = _alloc(curator, keyE1, c1, 5000 ether);
        _swapE(keyE1, id, 600 ether);
        _swapFlowReverts(keyE1, id, 401 ether, HOOK, e1, 400 ether);
        _swapE(keyE1, id, 400 ether); // exactly at the cap
        _swapFlowReverts(keyE1, id, 1, HOOK, e1, 0);
        assertEq(_used(HOOK, e1, c1), 1000 ether);
        assertEq(_used(CURATOR, curator, c1), 1000 ether);
        assertEq(_used(VAULT, address(0), c1), 1000 ether);
    }

    function test_FL_curatorLimit_acrossHooks() public {
        _setFlow(CURATOR, curator, c1, 1000 ether);
        uint256 a = _alloc(curator, keyE1, c1, 5000 ether);
        uint256 b = _alloc(curator, keyE2, c1, 5000 ether);
        _swapE(keyE1, a, 700 ether);
        _swapE(keyE2, b, 300 ether);
        _swapFlowReverts(keyE2, b, 1, CURATOR, curator, 0);
        _swapFlowReverts(keyE1, a, 1, CURATOR, curator, 0);
        // Another curator on the same hooks is not affected by this curator's limit.
        uint256 c = _alloc(curator2, keyE1, c1, 5000 ether);
        _swapE(keyE1, c, 2000 ether);
        assertEq(_used(HOOK, e1, c1), 2700 ether);
        assertEq(_used(HOOK, e2, c1), 300 ether);
        assertEq(_used(CURATOR, curator, c1), 1000 ether);
        assertEq(_used(CURATOR, curator2, c1), 2000 ether);
    }

    function test_FL_vaultLimit_acrossCurators() public {
        _setFlow(VAULT, address(0), c1, 1000 ether);
        uint256 a = _alloc(curator, keyE1, c1, 5000 ether);
        uint256 b = _alloc(curator2, keyE2, c1, 5000 ether);
        _swapE(keyE1, a, 600 ether);
        _swapE(keyE2, b, 400 ether);
        _swapFlowReverts(keyE2, b, 1, VAULT, address(0), 0);
        _swapFlowReverts(keyE1, a, 1, VAULT, address(0), 0);
        assertEq(_used(CURATOR, curator, c1) + _used(CURATOR, curator2, c1), _used(VAULT, address(0), c1));
    }

    /// @notice A configured cap of zero allows no output at all (D18: zero is not "unlimited").
    function test_FL_zeroCap_allowsNothing() public {
        _setFlow(HOOK, e1, c1, 0);
        uint256 id = _alloc(curator, keyE1, c1, 5000 ether); // reserving is allowed; trading is not
        _swapFlowReverts(keyE1, id, 1, HOOK, e1, 0);
    }

    // ------------------------------------------------------------------
    // Bypass attempts
    // ------------------------------------------------------------------

    /// @notice The curator ceiling bounds outstanding reservations, and consumption frees it, so a curator can keep
    ///         re-allocating. The curator flow limit bounds the volume regardless.
    function test_FL_repeatedAllocations_cannotBypassCuratorLimit() public {
        vm.startPrank(owner);
        vault.setCuratorCeiling(curator, c1, 100 ether);
        vm.stopPrank();
        _setFlow(CURATOR, curator, c1, 250 ether);
        for (uint256 i; i < 2; ++i) {
            uint256 id = _alloc(curator, keyE1, c1, 100 ether);
            _swapE(keyE1, id, 100 ether);
            assertEq(vault.curatorReserved(curator, c1), 0, "ceiling headroom fully restored");
        }
        uint256 last = _alloc(curator, keyE2, c1, 100 ether);
        _swapE(keyE2, last, 50 ether);
        _swapFlowReverts(keyE2, last, 1, CURATOR, curator, 0);
        assertEq(_used(CURATOR, curator, c1), 250 ether);
    }

    /// @notice One hook on two pools shares one hook record.
    function test_FL_multiplePoolsSameHook_shareHookLimit() public {
        _setFlow(HOOK, e1, c1, 1000 ether);
        uint256 a = _alloc(curator, keyE1, c1, 5000 ether);
        uint256 b = _alloc(curator2, keyE1b, c1, 5000 ether);
        _swapE(keyE1, a, 600 ether);
        _swapE(keyE1b, b, 400 ether);
        _swapFlowReverts(keyE1b, b, 1, HOOK, e1, 0);
        _swapFlowReverts(keyE1, a, 1, HOOK, e1, 0);
    }

    /// @notice Two swaps in one PoolManager unlock add up; when the second would exceed the curator limit the
    ///         whole transaction reverts, and the first swap's usage is rolled back with it.
    function test_FL_splitTradesInOneTransaction() public {
        _setFlow(CURATOR, curator, c1, 1000 ether);
        uint256 a = _alloc(curator, keyE1, c1, 5000 ether);
        uint256 b = _alloc(curator, keyE2, c1, 5000 ether);
        BatchSwapRouter.Step[] memory steps = new BatchSwapRouter.Step[](2);
        steps[0] = BatchSwapRouter.Step(keyE1, true, 600 ether, abi.encode(a));
        steps[1] = BatchSwapRouter.Step(keyE2, true, 400 ether, abi.encode(b));
        vm.prank(trader);
        batchRouter.run(steps, new uint256[](2), BatchSwapRouter.Mode.Settle);
        assertEq(_used(CURATOR, curator, c1), 1000 ether);

        vm.warp(block.timestamp + W);
        ISharedCommitmentVault.RiskLimit memory before = vault.getRiskLimit(CURATOR, curator, c1);
        steps[0].amountIn = 700 ether;
        steps[1].amountIn = 301 ether;
        _expectSwapRevert(e2, _flowErr(CURATOR, curator, c1, 301 ether, 300 ether));
        vm.prank(trader);
        batchRouter.run(steps, new uint256[](2), BatchSwapRouter.Mode.Settle);
        _assertSameRecord(before, vault.getRiskLimit(CURATOR, curator, c1));
        assertEq(_used(CURATOR, curator, c1), 0, "first swap rolled back");
        assertEq(_used(HOOK, e1, c1), 0, "hook usage rolled back");
        _assertAccountingConsistent();
    }

    /// @notice A hook that splits one swap into two `exchange` calls is charged for both.
    function test_FL_splitInsideOneSwap_byHook() public {
        address s = address(uint160(0x5C1 << 140) | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        deployCodeTo("ScriptedHook.sol:ScriptedHook", abi.encode(manager, vault), s);
        ScriptedHook sh = ScriptedHook(s);
        PoolKey memory keyS = PoolKey(c0, c1, 3000, 60, IHooks(s));
        manager.initialize(keyS, SQRT_PRICE_1_1);
        vm.startPrank(owner);
        vault.setConsumer(s, true);
        vault.setRiskLimit(HOOK, s, c1, 1000 ether, 10_000);
        vm.stopPrank();
        uint256 id = _alloc(curator, keyS, c1, 5000 ether);
        ScriptedHook.Call[] memory none = new ScriptedHook.Call[](0);
        // A hook trying to raise its own limit mid-swap is refused, and the swap reverts.
        ScriptedHook.Call[] memory raise = new ScriptedHook.Call[](1);
        raise[0] = ScriptedHook.Call(
            address(vault), abi.encodeCall(vault.setRiskLimit, (HOOK, s, c1, type(uint104).max, 10_000))
        );
        sh.script(none, raise, none, 100 ether);
        _expectSwapRevert(s, abi.encodeWithSelector(ISharedCommitmentVault.NotOwner.selector));
        _swapRaw(keyS, true, -int256(500 ether), abi.encode(id));

        sh.script(none, none, none, 400 ether);
        _swapRaw(keyS, true, -int256(1000 ether), abi.encode(id)); // 600 + 400
        assertEq(_used(HOOK, s, c1), 1000 ether);
        sh.script(none, none, none, 1);
        _expectSwapRevert(s, _flowErr(HOOK, s, c1, 1, 0));
        _swapRaw(keyS, true, -int256(2), abi.encode(id));
    }

    /// @notice A hook that takes the flow check but then fails to fund its input: the claim pull fails after the
    ///         flow records were written, and the whole transaction, records included, is rolled back.
    function test_FL_laterFailureRollsBackUsage() public {
        address m = address(uint160(0xBAD << 140) | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        deployCodeTo("MaliciousConsumerHook.sol:MaliciousConsumerHook", abi.encode(manager, vault), m);
        PoolKey memory keyM = PoolKey(c0, c1, 3000, 60, IHooks(m));
        manager.initialize(keyM, SQRT_PRICE_1_1);
        vm.prank(owner);
        vault.setConsumer(m, true);
        _openLimitsAsOwner(HOOK, m);
        uint256 id = _alloc(curator, keyM, c1, 5000 ether);
        MaliciousConsumerHook(m).configure(MaliciousConsumerHook.Attack.SkipInputFunding, id, 1000 ether);
        ISharedCommitmentVault.RiskLimit memory h = vault.getRiskLimit(HOOK, m, c1);
        ISharedCommitmentVault.RiskLimit memory v = vault.getRiskLimit(VAULT, address(0), c1);
        _expectSwapRevert(m, stdError.arithmeticError); // the claim pull underflows: the swap reverts as a whole
        _swapRaw(keyM, true, -int256(1000 ether), "");
        _assertSameRecord(h, vault.getRiskLimit(HOOK, m, c1));
        _assertSameRecord(v, vault.getRiskLimit(VAULT, address(0), c1));
        assertEq(vault.getAllocation(id).consumed, 0);
    }

    // ------------------------------------------------------------------
    // Windows and timestamps
    // ------------------------------------------------------------------

    /// @notice Window e is [e * W, (e + 1) * W - 1]. The last second still belongs to e; the next second starts a
    ///         fresh window. This is the documented boundary burst: two full caps within two seconds.
    function test_FL_windowBoundary_bothSides() public {
        _setFlow(HOOK, e1, c1, 1000 ether);
        uint256 e = block.timestamp / W + 1;
        vm.warp(e * W - 1);
        uint256 id = _alloc(curator, keyE1, c1, 5000 ether);
        _swapE(keyE1, id, 1000 ether);
        _swapFlowReverts(keyE1, id, 1, HOOK, e1, 0);
        assertEq(vault.getRiskLimit(HOOK, e1, c1).epoch, e - 1);

        vm.warp(e * W); // first second of window e
        assertEq(lens.flowAvailable(vault, HOOK, e1, c1), 1000 ether);
        _swapE(keyE1, id, 1000 ether);
        _swapFlowReverts(keyE1, id, 1, HOOK, e1, 0);
        assertEq(vault.getRiskLimit(HOOK, e1, c1).epoch, e);
        assertEq(vault.getAllocation(id).consumed, 2000 ether, "2 x cap within two seconds (fixed-window burst)");
    }

    /// @notice Gaps of many windows restart usage at zero in one step; usage from the old window is not added.
    function test_FL_skippedWindows() public {
        _setFlow(VAULT, address(0), c1, 1000 ether);
        uint256 id = _alloc(curator, keyE1, c1, 10_000 ether);
        _swapE(keyE1, id, 900 ether);
        vm.warp(block.timestamp + 10 * W + 12_345);
        assertEq(lens.flowUsed(vault, VAULT, address(0), c1), 0);
        assertEq(vault.getRiskLimit(VAULT, address(0), c1).flowUsed, 900 ether, "stale value kept in storage");
        _swapE(keyE1, id, 1000 ether);
        assertEq(_used(VAULT, address(0), c1), 1000 ether);
        _swapFlowReverts(keyE1, id, 1, VAULT, address(0), 0);
    }

    /// @notice 2^32 seconds (2106-02-07 06:28:16 UTC) falls inside window 49,710. Trades on both sides of it add
    ///         up in the same window; a 32-bit truncation would have produced a different window and reset usage.
    function test_FL_year2106_noResetAtUint32Wrap() public {
        uint256 wrap = 2 ** 32;
        assertEq((wrap - 10) / W, (wrap + 10) / W, "both sides in one window");
        _setFlow(CURATOR, curator, c1, 1000 ether);
        vm.warp(wrap - 10);
        uint256 id = _alloc(curator, keyE1, c1, 10_000 ether);
        _swapE(keyE1, id, 600 ether);
        vm.warp(wrap + 10);
        _swapFlowReverts(keyE1, id, 401 ether, CURATOR, curator, 400 ether);
        _swapE(keyE1, id, 400 ether);
        assertEq(vault.getRiskLimit(CURATOR, curator, c1).epoch, wrap / W);
        vm.warp((wrap / W + 1) * W); // next window
        _swapE(keyE1, id, 1000 ether);
        // Far beyond 2106 as well.
        vm.warp(253_402_300_800); // 10000-01-01
        id = _alloc(curator, keyE1, c1, 10_000 ether);
        _swapE(keyE1, id, 1000 ether);
        _swapFlowReverts(keyE1, id, 1, CURATOR, curator, 0);
    }

    /// @notice The last window whose index fits 40 bits works; from the next one on every consumption reverts with
    ///         `FlowEpochOutOfRange` instead of wrapping (fail closed). Allocations, closes and LP exits are not
    ///         flow-limited and keep working.
    function test_FL_epochAtUint40Limit_failsClosed() public {
        uint256 last = uint256(type(uint40).max);
        vm.warp(last * W + W - 1);
        uint256 id = _alloc(curator, keyE1, c1, 10_000 ether);
        _swapE(keyE1, id, 1 ether);
        assertEq(vault.getRiskLimit(VAULT, address(0), c1).epoch, type(uint40).max);

        vm.warp((last + 1) * W);
        _expectSwapRevert(e1, abi.encodeWithSelector(ISharedCommitmentVault.FlowEpochOutOfRange.selector, last + 1));
        _swapRaw(keyE1, true, -int256(1 ether), abi.encode(id));
        vm.prank(curator);
        vault.cancelAllocation(id);
        _redeem(lp0, 1000 ether, false);
    }

    /// @notice Near the end of 64-bit time (the allocation expiry type): still reverts cleanly, no overflow.
    function test_FL_nearUint64Timestamps_failClosed() public {
        uint256 t = uint256(type(uint64).max) - 30 days;
        vm.warp(t);
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyE1, c1, 1000 ether);
        req.expiry = type(uint64).max;
        req.deadline = type(uint64).max;
        vm.prank(curator);
        uint256 id = vault.allocate(req);
        _expectSwapRevert(e1, abi.encodeWithSelector(ISharedCommitmentVault.FlowEpochOutOfRange.selector, t / W));
        _swapRaw(keyE1, true, -int256(1 ether), abi.encode(id));
    }

    // ------------------------------------------------------------------
    // Administrative changes during a window
    // ------------------------------------------------------------------

    /// @notice Tightening below current usage blocks the rest of the window without touching usage; raising (owner
    ///         only) never erases usage; the next window starts at zero under the cap then in force.
    function test_FL_tighteningAndRaisingDuringWindow() public {
        _setFlow(HOOK, e1, c1, 1000 ether);
        uint256 id = _alloc(curator, keyE1, c1, 10_000 ether);
        _swapE(keyE1, id, 600 ether);

        vm.prank(guardian);
        vault.setRiskLimit(HOOK, e1, c1, 500 ether, 10_000);
        assertEq(_used(HOOK, e1, c1), 600 ether, "usage kept");
        _swapFlowReverts(keyE1, id, 1, HOOK, e1, 0);

        vm.prank(guardian);
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setRiskLimit(HOOK, e1, c1, 501 ether, 10_000);

        _setFlow(HOOK, e1, c1, 2000 ether); // owner raises
        assertEq(_used(HOOK, e1, c1), 600 ether, "raising does not reset usage");
        _swapFlowReverts(keyE1, id, 1401 ether, HOOK, e1, 1400 ether);
        _swapE(keyE1, id, 1400 ether);

        vm.prank(guardian);
        vault.setRiskLimit(HOOK, e1, c1, 300 ether, 10_000);
        vm.warp(block.timestamp + W);
        _swapFlowReverts(keyE1, id, 301 ether, HOOK, e1, 300 ether);
        _swapE(keyE1, id, 300 ether);
    }

    /// @notice Freeze, unfreeze, deregistration, re-registration, a generation bump and a consumer re-registration
    ///         leave every record unchanged; after unfreezing, only the remainder of the window is available.
    ///         Revocation stops the curator's old allocations whatever their remaining flow.
    function test_FL_lifecycleNeverResetsUsage() public {
        _setFlow(CURATOR, curator, c1, 1000 ether);
        uint256 id = _alloc(curator, keyE1, c1, 10_000 ether);
        _swapE(keyE1, id, 700 ether);
        bytes32 snap = _snap();

        vm.prank(guardian);
        vault.freezeCurator(curator);
        _expectSwapRevert(
            e1,
            abi.encodeWithSelector(
                ISharedCommitmentVault.CuratorRestricted.selector,
                curator,
                ISharedCommitmentVault.CuratorRestriction.Frozen
            )
        );
        _swapRaw(keyE1, true, -int256(1 ether), abi.encode(id));
        vm.startPrank(owner);
        vault.unfreezeCurator(curator);
        vault.setCurator(curator, false);
        vault.setCurator(curator, true);
        vault.setConsumer(e1, false);
        vault.setConsumer(e1, true);
        vm.stopPrank();
        vm.prank(curator);
        vault.bumpGeneration();
        assertEq(_snap(), snap, "no record changed");

        _swapFlowReverts(keyE1, id, 301 ether, CURATOR, curator, 300 ether);
        _swapE(keyE1, id, 300 ether);

        vm.warp(block.timestamp + W);
        vm.prank(guardian);
        vault.revokeCurator(curator);
        _expectSwapRevert(
            e1,
            abi.encodeWithSelector(
                ISharedCommitmentVault.CuratorRestricted.selector,
                curator,
                ISharedCommitmentVault.CuratorRestriction.Revoked
            )
        );
        _swapRaw(keyE1, true, -int256(1 ether), abi.encode(id));
    }

    /// @notice Cancellation, emergency release and expiry release return unused capacity but never flow: the
    ///         output already paid stays counted until the window ends.
    function test_FL_closesNeverRefundFlow() public {
        _setFlow(VAULT, address(0), c1, 1000 ether);
        uint256 a = _alloc(curator, keyE1, c1, 5000 ether);
        uint256 b = _alloc(curator2, keyE2, c1, 5000 ether);
        uint256 c = _alloc(curator, keyE2, c1, 5000 ether);
        _swapE(keyE1, a, 300 ether);
        _swapE(keyE2, b, 300 ether);
        _swapE(keyE2, c, 300 ether);
        bytes32 snap = _snap();
        vm.prank(curator);
        vault.cancelAllocation(a);
        vm.prank(owner);
        vault.release(b);
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyE1, c1, 100 ether);
        req.expiry = uint64(block.timestamp + 1);
        vm.prank(curator);
        uint256 d = vault.allocate(req);
        vm.warp(block.timestamp + 1);
        vault.release(d);
        assertEq(_snap(), snap, "closes moved no flow record");
        _swapFlowReverts(keyE2, c, 101 ether, VAULT, address(0), 100 ether);
        _swapE(keyE2, c, 100 ether);
    }

    /// @notice Pause stops trading before any record is touched, and keeps LP exits open.
    function test_FL_pauseStopsTrading_preservesUsage() public {
        uint256 id = _alloc(curator, keyE1, c1, 5000 ether);
        _swapE(keyE1, id, 100 ether);
        bytes32 snap = _snap();
        vm.prank(guardian);
        vault.setPaused(true);
        _expectSwapRevert(e1, abi.encodeWithSelector(ISharedCommitmentVault.Paused.selector));
        _swapRaw(keyE1, true, -int256(1 ether), abi.encode(id));
        (uint256 instant,,,) = _redeem(lp0, 1000 ether, false);
        assertEq(instant, 1000 ether);
        assertEq(_snap(), snap);
    }

    /// @notice LP deposits, instant and queued redemptions, queue processing, request cancellation and claims work
    ///         with every flow record exhausted or closed, and none of them changes any record.
    function test_FL_lpPathsIgnoreFlowLimits_atHighUtilization() public {
        address lp = makeAddr("lpX");
        _depositShares(lp, 200_000 ether);
        vm.prank(owner);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        _setFlow(VAULT, address(0), c1, 1000 ether);
        uint256 id = _alloc(curator, keyE1, c1, uint128(vault.admissibleCapacity(c1)));
        _swapE(keyE1, id, 1000 ether); // vault record exhausted, asset1 fully committed
        _setFlow(VAULT, address(0), c0, 0);
        bytes32 snap = _snap();

        (uint256 instant,,, uint256 req) = _redeem(lp, 100_000 ether, true);
        assertEq(instant, 0, "committed capacity is not paid out");
        assertGt(req, 0);
        _depositShares(makeAddr("lpY"), 1000 ether);
        (,,, uint256 req2) = _redeem(lp, 1000 ether, true);
        vm.prank(lp);
        vault.cancelRequest(req2);
        vm.prank(curator);
        vault.cancelAllocation(id);
        assertGt(vault.processQueue(3), 0);
        vm.prank(lp);
        vault.claim(req);
        assertEq(_snap(), snap, "LP operations changed a flow record");
        _assertEquations();
    }

    /// @notice Output of one asset never touches the other asset's records, and each asset has its own caps.
    function test_FL_crossAssetIsolation() public {
        _setFlow(HOOK, e1, c1, 1000 ether);
        _setFlow(HOOK, e1, c0, 50 ether);
        uint256 sell1 = _alloc(curator, keyE1, c1, 5000 ether);
        uint256 sell0 = _alloc(curator, keyE1, c0, 5000 ether);
        _swapE(keyE1, sell1, 1000 ether);
        assertEq(_used(HOOK, e1, c0), 0);
        _swapRaw(keyE1, false, -int256(50 ether), abi.encode(sell0));
        assertEq(_used(HOOK, e1, c0), 50 ether);
        assertEq(_used(HOOK, e1, c1), 1000 ether);
        _expectSwapRevert(e1, _flowErr(HOOK, e1, c0, 1, 0));
        _swapRaw(keyE1, false, -int256(1), abi.encode(sell0));
    }

    // ------------------------------------------------------------------
    // Configuration: fail closed, validation, roles
    // ------------------------------------------------------------------

    /// @notice D18: a path whose hook, curator or vault record was never configured can neither reserve nor trade.
    function test_FL_unconfigured_failsClosed() public {
        address e3 = address(uint160(0x0E3 << 140) | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        deployCodeTo("AuthModeHook.sol:AuthModeHook", abi.encode(manager, vault, AuthModeHook.Mode.Operator), e3);
        PoolKey memory keyE3 = PoolKey(c0, c1, 3000, 60, IHooks(e3));
        manager.initialize(keyE3, SQRT_PRICE_1_1);
        address fresh = makeAddr("freshCurator");
        vm.startPrank(owner);
        vault.setConsumer(e3, true);
        vault.setCurator(fresh, true);
        vault.setCuratorCeiling(fresh, c1, VAULT_FUNDING);
        vm.stopPrank();

        ISharedCommitmentVault.AllocationRequest memory req = _request(keyE3, c1, 1 ether);
        vm.prank(curator);
        vm.expectRevert(_notConfigured(HOOK, e3, c1));
        vault.allocate(req);
        req = _request(keyE1, c1, 1 ether);
        vm.prank(fresh);
        vm.expectRevert(_notConfigured(CURATOR, fresh, c1));
        vault.allocate(req);
        // Configuring one asset does not configure the other.
        vm.prank(owner);
        vault.setRiskLimit(CURATOR, fresh, c0, 1 ether, 10_000);
        vm.prank(fresh);
        vm.expectRevert(_notConfigured(CURATOR, fresh, c1));
        vault.allocate(req);

        // Vault scope, on a fresh vault whose hook and curator records are configured.
        SharedCommitmentVault v = new SharedCommitmentVault(manager, owner, c0, c1);
        vm.startPrank(owner);
        v.setConsumer(e1, true);
        v.setCurator(curator, true);
        v.setSellFloor(c1, PRICE_1_1_X96);
        v.setCuratorCeiling(curator, c1, VAULT_FUNDING);
        v.setRiskLimit(HOOK, e1, c1, 1 ether, 10_000);
        v.setRiskLimit(CURATOR, curator, c1, 1 ether, 10_000);
        token0.mint(owner, 1000 ether);
        token1.mint(owner, 1000 ether);
        token0.approve(address(v), type(uint256).max);
        token1.approve(address(v), type(uint256).max);
        v.initialDeposit(1000 ether, 1000 ether, owner);
        vm.stopPrank();
        vm.prank(curator);
        vm.expectRevert(_notConfigured(VAULT, address(0), c1));
        v.allocate(req);
    }

    /// @notice `exchange` itself fails closed on an unconfigured record, independently of `allocate`. Records cannot
    ///         be unconfigured through the interface, so the configured flag is cleared with `vm.store`.
    function test_FL_exchangeFailsClosedOnUnconfiguredRecord() public {
        uint256 id = _alloc(curator, keyE1, c1, 5000 ether);
        bytes32 slot = _recordSlot(HOOK, e1, c1);
        uint256 word = uint256(vm.load(address(vault), slot));
        assertEq(word & 0xff, 1, "configured flag is the lowest byte");
        vm.store(address(vault), slot, bytes32(word & ~uint256(0xff)));
        assertFalse(vault.getRiskLimit(HOOK, e1, c1).configured);
        _expectSwapRevert(e1, _notConfigured(HOOK, e1, c1));
        _swapRaw(keyE1, true, -int256(1 ether), abi.encode(id));
    }

    function test_FL_setterValidationAndRoles() public {
        vm.startPrank(owner);
        vm.expectRevert(ISharedCommitmentVault.InvalidRiskLimit.selector);
        vault.setRiskLimit(HOOK, e1, c1, uint256(type(uint104).max) + 1, 10_000);
        vm.expectRevert(ISharedCommitmentVault.InvalidRiskLimit.selector);
        vault.setRiskLimit(HOOK, e1, c1, 1, 10_001);
        vm.expectRevert(ISharedCommitmentVault.InvalidRiskLimit.selector);
        vault.setRiskLimit(VAULT, e1, c1, 1, 1);
        vm.expectRevert(ISharedCommitmentVault.InvalidRiskLimit.selector);
        vault.setRiskLimit(HOOK, address(0), c1, 1, 1);
        vm.expectRevert(ISharedCommitmentVault.InvalidRiskLimit.selector);
        vault.setRiskLimit(CURATOR, address(0), c1, 1, 1);
        vm.expectRevert(ISharedCommitmentVault.InvalidCurrency.selector);
        vault.setRiskLimit(HOOK, e1, Currency.wrap(address(0xdead)), 1, 1);
        vault.setRiskLimit(HOOK, e1, c1, type(uint104).max, 10_000); // upper bounds are accepted
        vm.stopPrank();

        vm.prank(attacker);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setRiskLimit(HOOK, e1, c1, 1, 1);
        vm.prank(e1); // a hook cannot configure itself
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setRiskLimit(HOOK, e1, c1, 1, 1);

        // Guardian: only tightens configured records, and only if neither value rises.
        vm.startPrank(guardian);
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setRiskLimit(HOOK, makeAddr("neverConfigured"), c1, 0, 0);
        vault.setRiskLimit(HOOK, e1, c1, 1000 ether, 5000);
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setRiskLimit(HOOK, e1, c1, 999 ether, 5001);
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setRiskLimit(HOOK, e1, c1, 1001 ether, 4999);
        vault.setRiskLimit(HOOK, e1, c1, 1000 ether, 5000); // same values: allowed
        vm.stopPrank();

        // A replaced guardian loses the role; the new one is bound by the same rule.
        address g2 = makeAddr("guardian2");
        vm.prank(owner);
        vault.setGuardian(g2);
        vm.prank(guardian);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setRiskLimit(HOOK, e1, c1, 0, 0);
        vm.prank(g2);
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setRiskLimit(HOOK, e1, c1, 2000 ether, 5000);
        // A new owner inherits the records unchanged.
        address o2 = makeAddr("owner2");
        vm.prank(owner);
        vault.transferOwnership(o2);
        vm.prank(o2);
        vault.acceptOwnership();
        ISharedCommitmentVault.RiskLimit memory r = vault.getRiskLimit(HOOK, e1, c1);
        assertEq(r.flowCap, 1000 ether);
        assertEq(r.maxReservedBps, 5000);
        vm.prank(owner);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setRiskLimit(HOOK, e1, c1, 0, 0);
    }

    /// @notice Usage just below the largest cap: arithmetic is done in 256 bits, so the last units are accepted
    ///         and one more is refused, with no overflow anywhere.
    function test_FL_largestCap_noOverflow() public {
        uint256 id = _alloc(curator, keyE1, c1, 5000 ether);
        _swapE(keyE1, id, 1); // stamps the current window in the hook record
        bytes32 slot = _recordSlot(HOOK, e1, c1);
        uint256 word = uint256(vm.load(address(vault), slot));
        // Layout: configured (8 bits) | epoch (40) | flowCap (104) | flowUsed (104), lowest bits first.
        uint256 usedMask = uint256(type(uint104).max) << 152;
        uint256 nearFull = uint256(type(uint104).max) - 5;
        vm.store(address(vault), slot, bytes32((word & ~usedMask) | (nearFull << 152)));
        assertEq(vault.getRiskLimit(HOOK, e1, c1).flowUsed, nearFull);
        _swapE(keyE1, id, 5);
        _swapFlowReverts(keyE1, id, 1, HOOK, e1, 0);
        assertEq(vault.getRiskLimit(HOOK, e1, c1).flowUsed, type(uint104).max);
    }

    // ------------------------------------------------------------------
    // Reference model
    // ------------------------------------------------------------------

    /// @notice Random sequences of time steps and trade sizes against one hook cap, compared with a reference
    ///         model written independently of the vault: per window w, accepted(w) <= cap, a trade is accepted iff
    ///         usage(w) + amount <= cap, and the stored usage equals the model's after every step.
    function testFuzz_FL_matchesReferenceModel(uint256 seed, uint96 cap) public {
        cap = uint96(bound(cap, 1, 5000 ether));
        _setFlow(HOOK, e1, c1, cap);
        uint256 id = _alloc(curator, keyE1, c1, 400_000 ether);
        uint256 modelWindow = type(uint256).max;
        uint256 modelUsed;
        for (uint256 i; i < 12; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 dt = seed % 4 == 0 ? (seed >> 8) % (3 * W) : (seed >> 8) % 600;
            // vm.getBlockTimestamp, not block.timestamp: via-IR may reuse one TIMESTAMP read across vm.warp calls
            // within this function.
            uint256 t = vm.getBlockTimestamp() + dt;
            vm.warp(t);
            uint256 amount = 1 + (seed >> 64) % (uint256(cap) * 2 / 3 + 1);
            uint256 w = t / W;
            uint256 used = w == modelWindow ? modelUsed : 0;
            bool accept = used + amount <= cap;
            if (accept) {
                _swapE(keyE1, id, amount);
                modelWindow = w;
                modelUsed = used + amount;
            } else {
                _swapFlowReverts(keyE1, id, amount, HOOK, e1, cap - used);
            }
            assertEq(_used(HOOK, e1, c1), w == modelWindow ? modelUsed : 0, "usage != model");
            assertLe(_used(HOOK, e1, c1), cap);
        }
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _setFlow(ISharedCommitmentVault.RiskScope scope, address account, Currency c, uint256 cap) internal {
        vm.prank(owner);
        vault.setRiskLimit(scope, account, c, cap, 10_000);
    }

    function _used(ISharedCommitmentVault.RiskScope scope, address account, Currency c)
        internal
        view
        returns (uint256)
    {
        return lens.flowUsed(vault, scope, account, c);
    }

    function _alloc(address who, PoolKey memory key, Currency out, uint128 maxOut) internal returns (uint256) {
        ISharedCommitmentVault.AllocationRequest memory req = _request(key, out, maxOut);
        req.expiry = uint64(block.timestamp + 30 days);
        req.deadline = uint64(block.timestamp);
        vm.prank(who);
        return vault.allocate(req);
    }

    /// @dev 1:1 swap selling token1 from the vault (the trader pays `amount` token0 and receives `amount` token1).
    function _swapE(PoolKey memory key, uint256 id, uint256 amount) internal {
        _swapRaw(key, true, -int256(amount), abi.encode(id));
    }

    function _swapFlowReverts(
        PoolKey memory key,
        uint256 id,
        uint256 amount,
        ISharedCommitmentVault.RiskScope scope,
        address account,
        uint256 available
    ) internal {
        bytes32 before = _snap();
        _expectSwapRevert(address(key.hooks), _flowErr(scope, account, c1, amount, available));
        _swapE(key, id, amount);
        assertEq(_snap(), before, "a refused swap changed a record");
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

    function _notConfigured(ISharedCommitmentVault.RiskScope scope, address account, Currency c)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(ISharedCommitmentVault.RiskLimitNotConfigured.selector, scope, account, c);
    }

    /// @dev Hash of every flow record these tests touch, in both assets.
    function _snap() internal view returns (bytes32 h) {
        address[7] memory hooks = [e1, e2, address(hookA), address(hookB), curator, curator2, address(0)];
        for (uint256 i; i < 7; ++i) {
            ISharedCommitmentVault.RiskScope scope = i < 4 ? HOOK : i < 6 ? CURATOR : VAULT;
            h = keccak256(
                abi.encode(h, vault.getRiskLimit(scope, hooks[i], c0), vault.getRiskLimit(scope, hooks[i], c1))
            );
        }
    }

    function _assertSameRecord(ISharedCommitmentVault.RiskLimit memory a, ISharedCommitmentVault.RiskLimit memory b)
        internal
        pure
    {
        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(b)), "record changed");
    }

    /// @dev Storage slot of a record's first word. `_riskLimits` is declared at slot 22 (`forge inspect
    ///      SharedCommitmentVault storageLayout`); tests that write to it first check the decoded value.
    function _recordSlot(ISharedCommitmentVault.RiskScope scope, address account, Currency c)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(keccak256(abi.encode(scope, account, c)), uint256(22)));
    }
}
