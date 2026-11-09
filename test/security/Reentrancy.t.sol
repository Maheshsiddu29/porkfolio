// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {ReentrantToken, ReentryAgent} from "../utils/ReentrantToken.sol";
import {ScriptedHook} from "../utils/ScriptedHook.sol";
import {ClaimDonor} from "../utils/ClaimDonor.sol";
import {ProductionArtifacts} from "../utils/ProductionArtifacts.sol";

/// @notice Reentrancy: every external-call path of the vault, attacked from the two places foreign code can run.
/// @dev Two kinds of attacker, both against the real PoolManager:
///
///      1. A pair token with transfer callbacks (`ReentrantToken`). This is the only way foreign code runs while a
///         vault entry point is still executing: inside the deposit's `transferFrom` (B_a already raised, claims not
///         yet minted) and inside a payout's `transfer` (from the PoolManager's `take`). The callback re-enters
///         through `ReentryAgent`, an account that is a registered curator, consumer and LP and holds every
///         precondition (shares, a pending and a claimable request, live and expired allocations, input claims), so
///         without the lock each reentrant call would pass its own checks. The tests assert the inner call failed
///         with `ReentrantCall`, i.e. the lock and not some other check rejected it, and that the outer operation
///         completed with exact accounting. Removing the lock makes these tests fail (mutation R1 in the report).
///
///      2. A registered hook that runs scripted calls inside `beforeSwap` (`ScriptedHook`). The vault is not
///         executing at those points (its `exchange` has returned), so these calls are not reentrancy into the
///         vault. They test that sequences a hook can build inside one swap either work with exact accounting or
///         revert the whole swap: withdrawing or claiming mid-swap (the PoolManager's `AlreadyUnlocked`), cancelling
///         and then consuming again, calling the vault's settlement callback directly.
contract ReentrancyTest is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 internal constant PRICE_1_1_X96 = uint160(FixedPoint96.Q96);
    uint256 internal constant FUNDING = 1_000_000 ether;

    PoolManager internal manager;
    PoolSwapTest internal router;
    ReentrantToken internal t0;
    ReentrantToken internal t1;
    Currency internal c0;
    Currency internal c1;
    SharedCommitmentVault internal vault;
    ScriptedHook internal hook;
    ReentryAgent internal agent;
    PoolKey internal key; // pool of the scripted hook
    PoolKey internal agentKey; // never initialized: the agent calls `exchange` directly as its own consumer

    address internal owner = makeAddr("owner");
    address internal curator = makeAddr("curator");
    address internal trader = makeAddr("trader");
    address internal lp = makeAddr("lp");

    // Preconditions held by the agent, so that each reentrant call would otherwise succeed.
    uint256 internal expiredId; // past expiry: releasable by anyone
    uint256 internal agentAllocId; // the agent's own allocation: cancellable by it
    uint256 internal agentExchangeId; // consumer = agent: consumable by it
    uint256 internal claimableReq; // the agent's finalized request
    uint256 internal pendingReq; // the agent's pending request
    uint256 internal assetOneLock; // curator allocation that commits all free asset1, keeping `pendingReq` queued
    uint256 internal nonce;

    function setUp() public {
        vm.warp(1_700_000_000);
        manager = PoolManager(deployCode(ProductionArtifacts.poolManager(), abi.encode(address(this))));
        router = new PoolSwapTest(manager);
        ReentrantToken a = new ReentrantToken("A", "A");
        ReentrantToken b = new ReentrantToken("B", "B");
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        c0 = Currency.wrap(address(t0));
        c1 = Currency.wrap(address(t1));
        vault = new SharedCommitmentVault(manager, owner, c0, c1);
        agent = new ReentryAgent();

        address h = address(uint160(0x5C1 << 140) | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        deployCodeTo("ScriptedHook.sol:ScriptedHook", abi.encode(manager, vault), h);
        hook = ScriptedHook(h);
        key = PoolKey(c0, c1, 3000, 60, IHooks(h));
        agentKey = PoolKey(c0, c1, 3000, 60, IHooks(address(agent)));
        manager.initialize(key, SQRT_PRICE_1_1);

        vm.startPrank(owner);
        vault.setConsumer(h, true);
        vault.setConsumer(address(agent), true);
        vault.setSellFloor(c0, PRICE_1_1_X96);
        vault.setSellFloor(c1, PRICE_1_1_X96);
        address[3] memory curators = [curator, address(agent), h];
        for (uint256 i; i < 3; ++i) {
            vault.setCurator(curators[i], true);
            vault.setCuratorCeiling(curators[i], c0, type(uint256).max);
            vault.setCuratorCeiling(curators[i], c1, type(uint256).max);
        }
        vm.stopPrank();

        _fund(owner, FUNDING);
        vm.prank(owner);
        vault.initialDeposit(FUNDING, FUNDING, lp);
        _fund(trader, 10 * FUNDING);
        vm.startPrank(trader);
        t0.approve(address(router), type(uint256).max);
        t1.approve(address(router), type(uint256).max);
        vm.stopPrank();

        // Agent as LP.
        _fundAccount(address(agent), 100_000 ether);
        _as(address(agent), address(vault), abi.encodeCall(vault.deposit, (50_000 ether, 1e30, 1e30, address(agent))));

        // An allocation that will be expired.
        expiredId = _allocateAs(curator, key, c1, 1000 ether, 1 hours);
        vm.warp(block.timestamp + 2 hours);

        // A claimable request and a pending request of the agent: lock all asset1, queue, free, finalize, re-lock.
        uint256 lock = _allocateAs(curator, key, c1, uint128(vault.admissibleCapacity(c1)), 1 days);
        claimableReq = _redeemQueued(address(agent), 5000 ether);
        vm.prank(owner);
        vault.release(lock);
        vault.processQueue(1);
        assertGt(vault.getRequest(claimableReq).claimable1, 0);
        assetOneLock = _allocateAs(curator, key, c1, uint128(vault.admissibleCapacity(c1)), 1 days);
        pendingReq = _redeemQueued(address(agent), 5000 ether);

        // The agent's own allocations: one to cancel, one it can consume as its own consumer (it holds input claims
        // and has made the vault its operator, exactly as a hook would). There is still free asset0 to allocate.
        agentAllocId = _allocateAs(address(agent), agentKey, c0, 1000 ether, 1 days);
        agentExchangeId = _allocateAs(address(agent), agentKey, c0, 1000 ether, 1 days);
        ClaimDonor donor = new ClaimDonor(manager);
        t1.mint(address(this), 1000 ether);
        t1.approve(address(donor), type(uint256).max);
        donor.donate(c1, 1000 ether, address(agent));
        _as(address(agent), address(manager), abi.encodeCall(manager.setOperator, (address(vault), true)));
    }

    // ------------------------------------------------------------------
    // 1. Token callbacks: reentry while a vault entry point is executing
    // ------------------------------------------------------------------

    /// @notice Inside a deposit's `transferFrom` (B_a raised, claims not yet minted), every locked entry point
    ///         rejects the agent with `ReentrantCall`, and the deposit itself completes with exact accounting.
    function test_RE_depositWindow_everyLockedEntryPointRejectsReentry() public {
        bytes[] memory calls = _lockedCalls();
        for (uint256 i; i < calls.length; ++i) {
            uint256 snap = vm.snapshotState();
            _arm(t0, calls[i]);
            uint256 sharesBefore = vault.sharesOf(lp);
            (uint256 a0, uint256 a1) = _depositAsLp(1000 ether);
            assertEq(t0.attempts(), 1, "callback ran");
            assertEq(t0.lastSelector(), ISharedCommitmentVault.ReentrantCall.selector, _label(i));
            assertEq(vault.sharesOf(lp) - sharesBefore, 1000 ether, "deposit completed");
            assertGt(a0 + a1, 0);
            _assertBackingMatchesClaims();
            vm.revertToState(snap);
        }
    }

    /// @notice Inside an instant redemption's payout (`take` -> ERC-20 `transfer` to the receiver), the receiver
    ///         cannot re-enter any locked entry point, and the redemption pays exactly what it accounted for.
    function test_RE_payoutWindow_receiverCannotReenter() public {
        // Instant exits need an empty queue: free asset1 and finalize the pending request first.
        vm.prank(owner);
        vault.release(assetOneLock);
        vault.processQueue(10);
        assertEq(vault.pendingShares(), 0);
        bytes[] memory calls = _lockedCalls();
        for (uint256 i; i < calls.length; ++i) {
            uint256 snap = vm.snapshotState();
            _arm(t1, calls[i]);
            uint256 before1 = t1.balanceOf(lp);
            uint256 backing1 = vault.backing(c1);
            vm.prank(lp);
            (uint256 instant,, uint256 a1,) = vault.redeem(1000 ether, 0, 0, lp, false);
            assertEq(instant, 1000 ether);
            assertEq(t1.attempts(), 1, "callback ran");
            assertEq(t1.lastSelector(), ISharedCommitmentVault.ReentrantCall.selector, _label(i));
            assertEq(t1.balanceOf(lp) - before1, a1, "paid exactly the accounted amount");
            assertEq(backing1 - vault.backing(c1), a1);
            _assertBackingMatchesClaims();
            vm.revertToState(snap);
        }
    }

    /// @notice A request cannot be claimed twice: a reentrant claim from the payout's transfer callback is
    ///         rejected by the lock, and a later ordinary claim finds nothing left.
    function test_RE_claimTwice_reentrantAndSequential() public {
        uint256 c1Owed = vault.getRequest(claimableReq).claimable1;
        _arm(t1, abi.encodeCall(vault.claim, (claimableReq)));
        uint256 w1 = vault.claimableAssets(c1);
        bytes memory ret = _as(address(agent), address(vault), abi.encodeCall(vault.claim, (claimableReq)));
        (, uint256 paid1) = abi.decode(ret, (uint256, uint256));
        assertEq(paid1, c1Owed);
        assertEq(t1.lastSelector(), ISharedCommitmentVault.ReentrantCall.selector);
        assertEq(w1 - vault.claimableAssets(c1), c1Owed, "W fell by exactly one payment");
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NothingToClaim.selector, claimableReq));
        agent.exec(address(vault), abi.encodeCall(vault.claim, (claimableReq)));
        _assertBackingMatchesClaims();
    }

    /// @notice The lock's scope: functions that read no accounting stay callable from a callback (they cannot
    ///         exploit the window), `unlockCallback` still rejects anyone but the PoolManager, and setters still
    ///         apply their role checks rather than the lock.
    function test_RE_lockScope_unlockedFunctions() public {
        _arm(t0, abi.encodeCall(vault.bumpGeneration, ()));
        _depositAsLp(1000 ether);
        assertTrue(t0.lastOk(), "bumpGeneration is not locked");
        assertEq(vault.getCurator(address(agent)).generation, 1);

        _armDirect(t0, address(vault), abi.encodeCall(vault.unlockCallback, (abi.encode(uint8(1), lp, 1, 1))));
        _depositAsLp(1000 ether);
        assertEq(t0.lastSelector(), ISharedCommitmentVault.NotPoolManager.selector);

        _arm(t0, abi.encodeCall(vault.setPaused, (true)));
        _depositAsLp(1000 ether);
        assertEq(t0.lastSelector(), ISharedCommitmentVault.NotOwner.selector);
    }

    /// @notice The lock is released after each call: two `exchange` calls on the same allocation inside one
    ///         `beforeSwap` both succeed, and consumption equals their sum.
    function test_RE_lockReleasedBetweenCalls() public {
        _freeAssetOne();
        uint256 id = _allocateAs(curator, key, c1, 10_000 ether, 1 days);
        hook.script(_none(), _none(), _none(), 400 ether);
        _swap(1000 ether, id);
        assertEq(vault.getAllocation(id).consumed, 1000 ether);
        _assertBackingMatchesClaims();
    }

    // ------------------------------------------------------------------
    // 2. A malicious registered hook acting inside one swap
    // ------------------------------------------------------------------

    /// @notice Withdrawing while a swap is still being settled: the vault would need its own PoolManager unlock,
    ///         which the PoolManager refuses (`AlreadyUnlocked`). The whole swap reverts and nothing changes.
    function test_RE_hook_withdrawDuringSwap_reverts() public {
        _freeAssetOne();
        uint256 id = _allocateAs(curator, key, c1, 10_000 ether, 1 days);
        _fundAccount(address(hook), 100_000 ether);
        hook.exec(address(vault), abi.encodeCall(vault.deposit, (10_000 ether, 1e30, 1e30, address(hook))));
        ScriptedHook.Call[] memory between =
            _one(address(vault), abi.encodeCall(vault.redeem, (1000 ether, 0, 0, address(hook), false)));
        hook.script(_none(), between, _none(), 0);
        uint256[6] memory before = _state(id);
        _swapReverts(1000 ether, id, abi.encodeWithSelector(IPoolManager.AlreadyUnlocked.selector));
        _assertStateUnchanged(before, id);
    }

    /// @notice Claiming mid-swap fails the same way (`AlreadyUnlocked`), so the swap reverts and the request stays
    ///         claimable exactly once. Processing the queue mid-swap, by contrast, is an ordinary call: the vault's
    ///         accounting is complete once `exchange` returns, so it succeeds.
    function test_RE_hook_claimDuringSwap_reverts() public {
        uint256 id = _allocateAs(curator, key, c0, 10_000 ether, 1 days);
        _fundAccount(address(hook), 100_000 ether);
        hook.exec(address(vault), abi.encodeCall(vault.deposit, (10_000 ether, 1e30, 1e30, address(hook))));
        // The deposit added free asset1; commit it too so that the hook's redemption has to queue.
        uint256 lock2 = _allocateAs(curator, key, c1, uint128(vault.admissibleCapacity(c1)), 1 days);
        bytes memory r =
            hook.exec(address(vault), abi.encodeCall(vault.redeem, (1000 ether, 0, 0, address(hook), true)));
        (,,, uint256 req) = abi.decode(r, (uint256, uint256, uint256, uint256));
        assertGt(req, 0, "queued");

        vm.startPrank(owner);
        vault.release(assetOneLock);
        vault.release(lock2);
        vm.stopPrank();
        hook.script(_none(), _one(address(vault), abi.encodeCall(vault.processQueue, (10))), _none(), 0);
        _swap(1000 ether, id);
        ISharedCommitmentVault.WithdrawalRequest memory w = vault.getRequest(req);
        assertEq(w.sharesPending, 0, "finalized mid-swap");
        assertGt(w.claimable1, 0);

        hook.script(_none(), _one(address(vault), abi.encodeCall(vault.claim, (req))), _none(), 0);
        uint256[6] memory before = _state(id);
        _swapReverts(1000 ether, id, abi.encodeWithSelector(IPoolManager.AlreadyUnlocked.selector));
        _assertStateUnchanged(before, id);
        assertEq(vault.getRequest(req).claimable1, w.claimable1, "still claimable");

        hook.exec(address(vault), abi.encodeCall(vault.claim, (req)));
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NothingToClaim.selector, req));
        hook.exec(address(vault), abi.encodeCall(vault.claim, (req)));
        _assertBackingMatchesClaims();
    }

    /// @notice A hook that is also the allocation's curator cancels between two consumptions of the same
    ///         allocation. The second `exchange` reverts, so the whole swap reverts: the allocation stays open and
    ///         unconsumed. Cancelling after the last consumption is a valid sequence and releases exactly the rest.
    function test_RE_hook_cancelDuringConsumption() public {
        _freeAssetOne();
        uint256 id = _allocateAs(address(hook), key, c1, 10_000 ether, 1 days);
        hook.script(_none(), _one(address(vault), abi.encodeCall(vault.cancelAllocation, (id))), _none(), 400 ether);
        uint256[6] memory before = _state(id);
        _swapReverts(
            1000 ether, id, abi.encodeWithSelector(ISharedCommitmentVault.AllocationAlreadyReleased.selector, id)
        );
        _assertStateUnchanged(before, id);

        hook.script(_none(), _none(), _one(address(vault), abi.encodeCall(vault.cancelAllocation, (id))), 0);
        uint256 q = vault.reserved(c1);
        _swap(1000 ether, id);
        ISharedCommitmentVault.Allocation memory a = vault.getAllocation(id);
        assertTrue(a.released);
        assertEq(a.consumed, 1000 ether);
        assertEq(q - vault.reserved(c1), 10_000 ether, "1,000 consumed + 9,000 released");
        _assertBackingMatchesClaims();
    }

    /// @notice Changing the allocation before using it: the hook cancels it and tries to recreate it with the
    ///         same instruction (spent nonce), or calls the vault's settlement callback, or opens its own unlock.
    ///         Each attempt reverts the whole swap.
    function test_RE_hook_unexpectedNestedCalls_revertAtomically() public {
        _freeAssetOne();
        ISharedCommitmentVault.AllocationRequest memory req = _request(key, c1, 10_000 ether, 1 days);
        bytes memory ret = hook.exec(address(vault), abi.encodeCall(vault.allocate, (req)));
        uint256 id = abi.decode(ret, (uint256));
        uint256[6] memory before = _state(id);

        ScriptedHook.Call[] memory pre = new ScriptedHook.Call[](2);
        pre[0] = ScriptedHook.Call(address(vault), abi.encodeCall(vault.cancelAllocation, (id)));
        pre[1] = ScriptedHook.Call(address(vault), abi.encodeCall(vault.allocate, (req)));
        hook.script(pre, _none(), _none(), 0);
        _swapReverts(
            1000 ether,
            id,
            abi.encodeWithSelector(ISharedCommitmentVault.NonceAlreadyUsed.selector, address(hook), req.nonce)
        );
        _assertStateUnchanged(before, id);

        // Settlement can only be entered by the PoolManager, and only for the vault's own unlock.
        bytes memory settle = abi.encode(uint8(1), address(hook), uint256(1000 ether), uint256(1000 ether));
        hook.script(_none(), _one(address(vault), abi.encodeCall(vault.unlockCallback, (settle))), _none(), 0);
        _swapReverts(1000 ether, id, abi.encodeWithSelector(ISharedCommitmentVault.NotPoolManager.selector));
        hook.script(_none(), _one(address(manager), abi.encodeCall(manager.unlock, (""))), _none(), 0);
        _swapReverts(1000 ether, id, abi.encodeWithSelector(IPoolManager.AlreadyUnlocked.selector));
        _assertStateUnchanged(before, id);
    }

    /// @notice Two consumptions in one swap are fine within quota and revert the whole swap beyond it.
    function test_RE_hook_doubleExchange_quotaHolds() public {
        _freeAssetOne();
        uint256 id = _allocateAs(curator, key, c1, 1500 ether, 1 days);
        hook.script(_none(), _none(), _none(), 500 ether);
        _swap(1000 ether, id); // 500 + 500
        assertEq(vault.getAllocation(id).consumed, 1000 ether);
        hook.script(_none(), _none(), _none(), 600 ether);
        _swapReverts(
            1000 ether, id, abi.encodeWithSelector(ISharedCommitmentVault.QuotaExceeded.selector, 600 ether, 100 ether)
        ); // 400 then 600 > 1,500 - 1,400
        assertEq(vault.getAllocation(id).consumed, 1000 ether);
        _assertBackingMatchesClaims();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev One call per locked entry point, each made by the agent with every precondition satisfied.
    function _lockedCalls() internal returns (bytes[] memory c) {
        c = new bytes[](10);
        c[0] = abi.encodeCall(vault.deposit, (100 ether, 1e30, 1e30, address(agent)));
        c[1] = abi.encodeCall(vault.initialDeposit, (1 ether, 1 ether, address(agent)));
        c[2] = abi.encodeCall(vault.redeem, (10 ether, 0, 0, address(agent), true));
        c[3] = abi.encodeCall(vault.processQueue, (5));
        c[4] = abi.encodeCall(vault.cancelRequest, (pendingReq));
        c[5] = abi.encodeCall(vault.claim, (claimableReq));
        c[6] = abi.encodeCall(vault.allocate, (_request(agentKey, c0, 1 ether, 1 days)));
        c[7] = abi.encodeCall(vault.release, (expiredId));
        c[8] = abi.encodeCall(vault.cancelAllocation, (agentAllocId));
        c[9] = abi.encodeCall(vault.exchange, (agentKey, false, agentExchangeId, 10 ether, 10 ether));
    }

    /// @dev Releases the setUp allocation that commits all free asset1 and finalizes the queue behind it.
    function _freeAssetOne() internal {
        vm.prank(owner);
        vault.release(assetOneLock);
        vault.processQueue(10);
    }

    function _label(uint256 i) internal pure returns (string memory) {
        string[10] memory names = [
            "deposit",
            "initialDeposit",
            "redeem",
            "processQueue",
            "cancelRequest",
            "claim",
            "allocate",
            "release",
            "cancelAllocation",
            "exchange"
        ];
        return string.concat(names[i], ": reentry not rejected by the lock");
    }

    function _arm(ReentrantToken t, bytes memory vaultCall) internal {
        t.arm(address(agent), abi.encodeCall(agent.exec, (address(vault), vaultCall)));
    }

    function _armDirect(ReentrantToken t, address to, bytes memory data) internal {
        t.arm(to, data);
    }

    function _as(address who, address to, bytes memory data) internal returns (bytes memory) {
        return ReentryAgent(who).exec(to, data);
    }

    function _fund(address who, uint256 amount) internal {
        t0.mint(who, amount);
        t1.mint(who, amount);
        vm.startPrank(who);
        t0.approve(address(vault), type(uint256).max);
        t1.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Funds a contract account (agent or hook) and has it approve the vault itself.
    function _fundAccount(address who, uint256 amount) internal {
        t0.mint(who, amount);
        t1.mint(who, amount);
        ReentryAgent(who).exec(address(t0), abi.encodeCall(t0.approve, (address(vault), type(uint256).max)));
        ReentryAgent(who).exec(address(t1), abi.encodeCall(t1.approve, (address(vault), type(uint256).max)));
    }

    function _depositAsLp(uint256 shares) internal returns (uint256, uint256) {
        _fund(lp, 10_000 ether);
        vm.prank(lp);
        return vault.deposit(shares, 1e30, 1e30, lp);
    }

    function _redeemQueued(address who, uint256 shares) internal returns (uint256 requestId) {
        bytes memory r = _as(who, address(vault), abi.encodeCall(vault.redeem, (shares, 0, 0, who, true)));
        (,,, requestId) = abi.decode(r, (uint256, uint256, uint256, uint256));
        assertGt(requestId, 0);
    }

    function _request(PoolKey memory k, Currency out, uint128 maxOut, uint256 lifetime)
        internal
        returns (ISharedCommitmentVault.AllocationRequest memory)
    {
        return ISharedCommitmentVault.AllocationRequest({
            consumer: address(k.hooks),
            key: k,
            currencyOut: out,
            maxOut: maxOut,
            minInPerOutX96: PRICE_1_1_X96,
            expiry: uint64(block.timestamp + lifetime),
            nonce: nonce++,
            deadline: uint64(block.timestamp)
        });
    }

    function _allocateAs(address who, PoolKey memory k, Currency out, uint128 maxOut, uint256 lifetime)
        internal
        returns (uint256 id)
    {
        ISharedCommitmentVault.AllocationRequest memory req = _request(k, out, maxOut, lifetime);
        if (who.code.length != 0) {
            id = abi.decode(_as(who, address(vault), abi.encodeCall(vault.allocate, (req))), (uint256));
        } else {
            vm.prank(who);
            id = vault.allocate(req);
        }
    }

    /// @dev Like `_swap`, expecting the hook's revert `reason` wrapped by the PoolManager.
    function _swapReverts(uint256 amountIn, uint256 id, bytes memory reason) internal {
        _swap(amountIn, id, reason, true);
    }

    function _swap(uint256 amountIn, uint256 id) internal {
        _swap(amountIn, id, "", false);
    }

    function _swap(uint256 amountIn, uint256 id, bytes memory reason, bool reverts) internal {
        ISharedCommitmentVault.Allocation memory a = vault.getAllocation(id);
        bool zeroForOne = a.currencyOut == c1;
        if (reverts) _expectHookRevert(reason);
        vm.prank(trader);
        router.swap(
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

    function _expectHookRevert(bytes memory reason) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                reason,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function _none() internal pure returns (ScriptedHook.Call[] memory) {
        return new ScriptedHook.Call[](0);
    }

    function _one(address to, bytes memory data) internal pure returns (ScriptedHook.Call[] memory c) {
        c = new ScriptedHook.Call[](1);
        c[0] = ScriptedHook.Call(to, data);
    }

    function _state(uint256 id) internal view returns (uint256[6] memory s) {
        ISharedCommitmentVault.Allocation memory a = vault.getAllocation(id);
        s[0] = vault.backing(c0);
        s[1] = vault.backing(c1);
        s[2] = vault.reserved(c0) + vault.reserved(c1);
        s[3] = a.consumed;
        s[4] = a.released ? 1 : 0;
        s[5] = vault.totalShares() + vault.pendingShares();
    }

    function _assertStateUnchanged(uint256[6] memory before, uint256 id) internal view {
        uint256[6] memory afterSnap = _state(id);
        for (uint256 i; i < 6; ++i) {
            assertEq(afterSnap[i], before[i], "a reverted sequence left a trace");
        }
        _assertBackingMatchesClaims();
    }

    /// @dev B_a equals the vault's real ERC-6909 balance (no donations reach the vault in this file), Q_a + W_a fit
    ///      inside B_a, and the hook holds no leftover claims.
    function _assertBackingMatchesClaims() internal view {
        Currency[2] memory cs = [c0, c1];
        for (uint256 i; i < 2; ++i) {
            assertEq(vault.backing(cs[i]), manager.balanceOf(address(vault), cs[i].toId()), "B != claims");
            assertLe(vault.reserved(cs[i]) + vault.claimableAssets(cs[i]), vault.backing(cs[i]), "Q + W > B");
            assertEq(manager.balanceOf(address(hook), cs[i].toId()), 0, "hook kept claims");
        }
    }

    /// @notice This file builds its own fixture; its vault and PoolManager are the production builds.
    function test_RE_productionBuilds() public view {
        ProductionArtifacts.requireProduction(address(vault), ProductionArtifacts.VAULT, ProductionArtifacts.VAULT_RUNS);
        ProductionArtifacts.requireProduction(
            address(manager), ProductionArtifacts.poolManager(), ProductionArtifacts.DEFAULT_RUNS
        );
    }
}
