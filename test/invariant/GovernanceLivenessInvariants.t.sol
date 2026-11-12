// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultLens} from "../../src/VaultLens.sol";
import {CuratorAuthorization} from "../../src/CuratorAuthorization.sol";
import {VaultGovernor} from "../../src/governance/VaultGovernor.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {QueueGriefer} from "../utils/GovernanceActors.sol";

/// @notice Handler for the governance-liveness campaign: LPs (deposit, redeem and queue, cancel, claim), honest curators
///         (commit, cancel), fills through both hooks, a curator that is also an LP rotating its commitments, the
///         guardian (stop new commitments, emergency release), the governor (queue a LONG_DELAY change; attempt it
///         later through the prescribed batch; lift a restriction through DELAY), and time. Queuing and executing are
///         separate calls so that commitments and requests can be created in between, which is the only way a request
///         can still be held at eta.
///
///         After every call the handler checks L1, the per-request liveness property: a request is held only by
///         commitments that existed when it was queued. Formally, with w(a) the request id the vault would have
///         assigned next when allocation a was created, every pending request with an id below min w(a) over the
///         unreleased allocations was queued before all of them, and the vault can deliver the whole queue up to it
///         now: `deliverableShares >= sum of their pending shares`. The handler records w(a) as `nextRequestId` at the
///         start of the call that created a; a request created earlier in the same call then counts as newer, which
///         only shortens the checked prefix.
contract GovernanceLivenessHandler is Test {
    SharedCommitmentVault internal immutable vault;
    VaultLens internal immutable lens;
    CuratorAuthorization internal immutable auth;
    VaultGovernor internal immutable gov;
    PoolSwapTest internal immutable router;
    QueueGriefer internal immutable griefer;
    MockERC20 internal immutable t0;
    MockERC20 internal immutable t1;
    Currency internal immutable c0;
    Currency internal immutable c1;
    address internal immutable govAdmin;
    address internal immutable guardian;
    uint256 internal immutable tau;

    PoolKey internal keyA;
    PoolKey internal keyB;
    address[2] internal curators;
    address[3] internal lps;
    uint256 internal nonce = 1 << 128;

    uint256[] internal allocations; // unreleased allocation ids (pruned lazily)
    mapping(uint256 id => uint256) public watermark; // w(a)
    uint256[] internal requests; // every request id created through the handler's LPs
    mapping(uint256 rid => address) internal requestLp;

    bool public restricted; // new commitments are stopped by a guardian lever
    bool internal paused; // the lever in force is a pause (otherwise buffer floors at the maximum)
    uint256 public restrictedAt; // when the lever in force was applied
    bool internal toggle;
    bytes internal op; // the outstanding LONG_DELAY change
    uint256 internal opQueuedAt; // zero: none outstanding
    uint256 internal opEta;

    // ---- violations (each must stay 0)
    uint256 public prefixViolations; // L1
    uint256 public longWhilePending; // S1: a LONG_DELAY change executed with shares queued
    uint256 public delayViolations; // S2: a change executed outside [queued + class delay, + GRACE]
    uint256 public livenessViolations; // L2: refused although every older commitment had expired
    uint256 public otherFailures; // a governed call refused for a reason the handler does not expect

    // ---- activity (read by test/invariant/coverage.py)
    uint256 public depositsOk;
    uint256 public queuedOk;
    uint256 public finalizedOk;
    uint256 public commitsOk;
    uint256 public rotationsOk;
    uint256 public swapsOk;
    uint256 public longExecuted;
    uint256 public longBlocked;
    uint256 public restrictedExecutions; // L2 cases: executions the property required
    uint256 public expiredOps; // changes canceled after their window closed
    uint256 public preEtaRotations; // `rotateBeforeEta` calls that rotated
    uint256 public execAttempts; // `govExecute` calls that reached `execute`
    uint256 public prefixChecks; // L1 checks with a non-empty prefix
    uint256 public calls;

    constructor(
        SharedCommitmentVault vault_,
        VaultLens lens_,
        CuratorAuthorization auth_,
        VaultGovernor gov_,
        PoolSwapTest router_,
        QueueGriefer griefer_,
        PoolKey[2] memory keys,
        address[2] memory curators_,
        address guardian_,
        uint256 tau_
    ) {
        (vault, lens, auth, gov, router, griefer) = (vault_, lens_, auth_, gov_, router_, griefer_);
        (keyA, keyB) = (keys[0], keys[1]);
        curators = curators_;
        guardian = guardian_;
        tau = tau_;
        govAdmin = gov_.admin();
        c0 = vault_.asset0();
        c1 = vault_.asset1();
        t0 = MockERC20(Currency.unwrap(c0));
        t1 = MockERC20(Currency.unwrap(c1));
        lps = [makeAddr("gLp0"), makeAddr("gLp1"), makeAddr("gLp2")];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(lps[i]);
            t0.approve(address(vault_), type(uint256).max);
            t1.approve(address(vault_), type(uint256).max);
            vm.stopPrank();
        }
        t0.approve(address(router_), type(uint256).max);
        t1.approve(address(router_), type(uint256).max);
    }

    // =================================================================== bookkeeping

    modifier step() {
        ++calls;
        uint256 w = vault.nextRequestId();
        uint256 firstNew = vault.nextAllocationId();
        _;
        uint256 end = vault.nextAllocationId();
        for (uint256 id = firstNew; id < end; ++id) {
            watermark[id] = w;
            allocations.push(id);
        }
        _checkPrefix();
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    /// @dev L1. Also prunes released allocations from the list.
    function _checkPrefix() internal {
        uint256 wMin = type(uint256).max;
        for (uint256 k = allocations.length; k > 0; --k) {
            uint256 id = allocations[k - 1];
            if (vault.getAllocation(id).released) {
                allocations[k - 1] = allocations[allocations.length - 1];
                allocations.pop();
            } else if (watermark[id] < wMin) {
                wMin = watermark[id];
            }
        }
        uint256 end = vault.nextRequestId();
        if (wMin < end) end = wMin;
        uint256 prefix;
        for (uint256 r = vault.queueHead(); r < end; ++r) {
            prefix += vault.getRequest(r).sharesPending;
        }
        if (prefix == 0) return;
        ++prefixChecks;
        if (lens.deliverableShares(vault) < prefix) ++prefixViolations;
    }

    /// @dev Anyone may release an expired commitment.
    function _releaseExpired() internal {
        for (uint256 k; k < allocations.length; ++k) {
            ISharedCommitmentVault.Allocation memory a = vault.getAllocation(allocations[k]);
            if (!a.released && _now() >= a.expiry) vault.release(allocations[k]);
        }
    }

    /// @dev The admin's processing step: as many entries as the queue holds (each call visits at most 256).
    function _drainQueue() internal {
        for (uint256 k; k < 8 && vault.pendingShares() != 0; ++k) {
            if (vault.processQueue(256) != 0) ++finalizedOk;
        }
    }

    // =================================================================== LPs

    function deposit(uint256 who, uint256 sharesSeed) external step {
        address lp = lps[who % 3];
        uint256 shares = bound(sharesSeed, 1e18, 100_000 ether);
        (uint256 a0, uint256 a1) = lens.previewDeposit(vault, shares);
        t0.mint(lp, a0);
        t1.mint(lp, a1);
        vm.prank(lp);
        try vault.deposit(shares, a0, a1, lp) {
            ++depositsOk;
        } catch {}
    }

    /// @notice With `queue`, the amount is drawn from just above the current deliverable count up to the balance, so a
    ///         request is created whenever the LP holds more than can be paid now; without it, any amount, instant only.
    function redeem(uint256 who, uint256 fracSeed, bool queue) external step {
        address lp = lps[who % 3];
        uint256 bal = vault.sharesOf(lp);
        if (bal == 0) return;
        uint256 lo = queue ? lens.deliverableShares(vault) + 1 : 1;
        uint256 shares = bound(fracSeed, lo < bal ? lo : bal, bal);
        vm.prank(lp);
        try vault.redeem(shares, 0, 0, lp, queue) returns (uint256, uint256, uint256, uint256 rid) {
            if (rid != 0) {
                ++queuedOk;
                requests.push(rid);
                requestLp[rid] = lp;
            }
        } catch {}
    }

    function cancelRequest(uint256 idx) external step {
        if (requests.length == 0) return;
        uint256 rid = requests[idx % requests.length];
        vm.prank(requestLp[rid]);
        try vault.cancelRequest(rid) {} catch {}
    }

    function claim(uint256 idx) external step {
        if (requests.length == 0) return;
        uint256 rid = requests[idx % requests.length];
        vm.prank(requestLp[rid]);
        try vault.claim(rid) {} catch {}
    }

    function processQueue(uint256 steps) external step {
        try vault.processQueue(bound(steps, 1, 16)) returns (uint256 f) {
            if (f != 0) ++finalizedOk;
        } catch {}
    }

    // =================================================================== curators and fills

    /// @notice An honest curator commits part of the admissible capacity of one asset (all of it one time in three,
    ///         otherwise 10%..100%) for 1 hour .. MAX_HORIZON.
    function commit(uint256 curatorIdx, bool sellAsset1, bool useB, uint256 fracSeed, uint256 horizonSeed)
        external
        step
    {
        Currency out = sellAsset1 ? c1 : c0;
        uint256 cap = vault.admissibleCapacity(out) * (fracSeed % 3 == 0 ? 100 : bound(fracSeed, 10, 100)) / 100;
        if (cap == 0) return;
        PoolKey memory key = useB ? keyB : keyA;
        ISharedCommitmentVault.AllocationRequest memory r = ISharedCommitmentVault.AllocationRequest({
            consumer: address(key.hooks),
            key: key,
            currencyOut: out,
            maxOut: uint128(cap),
            minInPerOutX96: uint160(1 << 96),
            expiry: uint64(_now() + bound(horizonSeed, 1 hours, 30 days)),
            nonce: nonce++,
            deadline: uint64(_now())
        });
        vm.prank(curators[curatorIdx % 2]);
        try auth.activateDirect(r) {
            ++commitsOk;
        } catch {}
    }

    function cancelCommit(uint256 idx) external step {
        if (allocations.length == 0) return;
        uint256 id = allocations[idx % allocations.length];
        vm.prank(vault.getAllocation(id).curator);
        try vault.cancelAllocation(id) {} catch {}
    }

    /// @notice A fill against a live commitment through its hook, 0.001 .. 1,000 tokens in.
    function swap(uint256 idx, uint256 amountSeed) external step {
        if (allocations.length == 0) return;
        uint256 id = allocations[idx % allocations.length];
        ISharedCommitmentVault.Allocation memory a = vault.getAllocation(id);
        if (a.released || _now() >= a.expiry) return;
        PoolKey memory key = a.consumer == address(keyA.hooks) ? keyA : keyB;
        bool zeroForOne = a.currencyOut == c1;
        uint256 amountIn = bound(amountSeed, 1e15, 1000 ether);
        t0.mint(address(this), amountIn);
        t1.mint(address(this), amountIn);
        try router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(id)
        ) {
            ++swapsOk;
        } catch {}
    }

    /// @notice The curator-LP coalition: cancel its commitments, commit everything admissible for MAX_HORIZON and queue
    ///         ten shares, in one transaction. Ten rather than one because rounding in earlier finalizations can leave a
    ///         share or two deliverable, which would pay a one-share redemption at once instead of queuing it.
    function rotate() external step {
        if (vault.sharesOf(address(griefer)) == 0) return;
        try griefer.rotate(30 days, 10) {
            ++rotationsOk;
        } catch {}
    }

    /// @notice The coalition's best timing: one day before the outstanding change's eta, rotate, so the share it
    ///         queues waits behind a commitment that outlives the whole window.
    function rotateBeforeEta() external step {
        if (opQueuedAt == 0 || _now() + 1 days >= opEta || vault.sharesOf(address(griefer)) == 0) return;
        vm.warp(opEta - 1 days);
        _releaseExpired();
        try griefer.rotate(30 days, 10) {
            ++rotationsOk;
            ++preEtaRotations;
        } catch {}
    }

    // =================================================================== guardian and governor

    /// @notice The guardian stops new commitments: buffer floors at the maximum (mode even) or a pause (mode odd).
    function restrict(uint256 mode) external step {
        if (restricted) return;
        paused = mode % 2 == 1;
        vm.startPrank(guardian);
        if (paused) {
            vault.setPaused(true);
        } else {
            vault.setBufferFloor(c0, type(uint256).max);
            vault.setBufferFloor(c1, type(uint256).max);
        }
        vm.stopPrank();
        restricted = true;
        restrictedAt = _now();
    }

    /// @notice The admin lifts the restriction through the governor (DELAY), executed at eta.
    function lift() external step {
        if (!restricted) return;
        bytes[] memory data = new bytes[](paused ? 1 : 2);
        if (paused) {
            data[0] = abi.encodeCall(vault.setPaused, (false));
        } else {
            data[0] = abi.encodeCall(vault.setBufferFloor, (c0, 0));
            data[1] = abi.encodeCall(vault.setBufferFloor, (c1, 0));
        }
        uint256 queuedAt = _now();
        uint256 eta;
        for (uint256 i; i < data.length; ++i) {
            vm.prank(govAdmin);
            (, eta) = gov.queue(address(vault), data[i]);
        }
        vm.warp(eta);
        _releaseExpired();
        for (uint256 i; i < data.length; ++i) {
            vm.prank(govAdmin);
            try gov.execute(address(vault), data[i]) {
                if (_now() < queuedAt + gov.DELAY()) ++delayViolations;
            } catch {
                ++otherFailures;
            }
        }
        restricted = false;
    }

    function emergencyRelease(uint256 idx) external step {
        if (allocations.length == 0) return;
        vm.prank(guardian);
        try vault.release(allocations[idx % allocations.length]) {} catch {}
    }

    /// @notice The admin queues a LONG_DELAY change (tolerance alternating 5% / 6%) if none is outstanding.
    function govQueue() external step {
        if (opQueuedAt != 0) return;
        toggle = !toggle;
        uint24 k = toggle ? 60_000 : 50_000;
        op = abi.encodeCall(vault.setInventoryBounds, (tau, tau, k, k));
        opQueuedAt = _now();
        vm.prank(govAdmin);
        (, opEta) = gov.queue(address(vault), op);
    }

    /// @notice The admin's batch for the outstanding LONG_DELAY change, at the current time or, before eta, at a point
    ///         inside the window: release what has expired, process the whole queue, execute. Refused only with
    ///         `PendingWithdrawals`, and never when new commitments have been stopped for MAX_HORIZON (L2). A refused
    ///         change stays queued for a later attempt; one past its window is canceled.
    function govExecute(uint256 offsetSeed) external step {
        if (opQueuedAt == 0) return;
        if (_now() < opEta) vm.warp(opEta + bound(offsetSeed, 0, gov.GRACE()));
        if (_now() > opEta + gov.GRACE()) {
            vm.prank(govAdmin);
            gov.cancel(address(vault), op);
            opQueuedAt = 0;
            ++expiredOps;
            return;
        }
        bool required = restricted && restrictedAt + vault.MAX_HORIZON() <= _now();
        _releaseExpired();
        _drainQueue();
        ++execAttempts;
        vm.prank(govAdmin);
        try gov.execute(address(vault), op) {
            ++longExecuted;
            if (required) ++restrictedExecutions;
            if (vault.pendingShares() != 0) ++longWhilePending;
            if (_now() < opQueuedAt + gov.LONG_DELAY() || _now() > opQueuedAt + gov.LONG_DELAY() + gov.GRACE()) {
                ++delayViolations;
            }
            opQueuedAt = 0;
        } catch (bytes memory err) {
            if (bytes4(err) == VaultGovernor.PendingWithdrawals.selector) {
                ++longBlocked;
                if (required) ++livenessViolations;
            } else {
                ++otherFailures;
            }
        }
    }

    function warp(uint256 secondsSeed) external step {
        vm.warp(_now() + bound(secondsSeed, 1 hours, 10 days));
        _releaseExpired();
    }
}

/// @notice Stateful campaign for withdrawal and governance liveness under `VaultGovernor`. Invariants:
///         L1  per-request liveness (see the handler): commitments created after a request never hold it;
///         L2  a LONG_DELAY change executes whenever new commitments have been stopped since at least MAX_HORIZON
///             before its eta, whatever the LPs and the curator-LP coalition do;
///         S1  no LONG_DELAY change executes while shares are queued;
///         S2  every executed change waited its class's delay and ran inside its window;
///         plus the vault's accounting equations.
contract GovernanceLivenessInvariantsTest is VaultTestBase {
    GovernanceLivenessHandler internal handler;
    VaultGovernor internal gov;
    QueueGriefer internal griefer;
    address internal guardian = makeAddr("guardian");
    address internal curator2 = makeAddr("curator2");
    address internal govAdmin = makeAddr("govAdmin");

    function setUp() public override {
        super.setUp();
        uint256 tau = FullMath.mulDiv(vault.backing(c0), 1e18, vault.totalShares());
        griefer = new QueueGriefer(vault, auth, keyA, c0);
        token0.mint(address(griefer), 1000);
        token1.mint(address(griefer), 1000);
        griefer.deposit(500);

        vm.startPrank(owner);
        vault.setGuardian(guardian);
        vault.setInventoryBounds(tau, tau, 50_000, 50_000);
        vault.setCurator(curator2, true);
        vault.setCurator(address(griefer), true);
        _openLimits(ISharedCommitmentVault.RiskScope.Curator, curator2);
        _openLimits(ISharedCommitmentVault.RiskScope.Curator, address(griefer));
        address[3] memory cs = [curator, curator2, address(griefer)];
        for (uint256 i; i < 3; ++i) {
            vault.setCuratorCeiling(cs[i], c0, type(uint256).max);
            vault.setCuratorCeiling(cs[i], c1, type(uint256).max);
        }
        gov = new VaultGovernor(address(vault), govAdmin, 3 days, 32 days, 7 days);
        vault.transferOwnership(address(gov));
        vm.stopPrank();
        vm.prank(govAdmin);
        gov.acceptVaultOwnership();
        _deepenHookB();
        for (uint256 i; i < 3; ++i) {
            _depositShares(makeAddr(string.concat("gLp", vm.toString(i))), 300_000 ether);
        }

        handler = new GovernanceLivenessHandler(
            vault, lens, auth, gov, swapRouter, griefer, [keyA, keyB], [curator, curator2], guardian, tau
        );
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](21);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.redeem.selector;
        selectors[2] = handler.redeem.selector; // weighted: queued requests are what the properties are about
        selectors[3] = handler.cancelRequest.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.processQueue.selector;
        selectors[6] = handler.commit.selector;
        selectors[7] = handler.commit.selector;
        selectors[8] = handler.cancelCommit.selector;
        selectors[9] = handler.swap.selector;
        selectors[10] = handler.swap.selector;
        selectors[11] = handler.rotate.selector;
        selectors[12] = handler.restrict.selector;
        selectors[13] = handler.lift.selector;
        selectors[14] = handler.emergencyRelease.selector;
        selectors[15] = handler.govQueue.selector;
        selectors[16] = handler.govExecute.selector;
        selectors[17] = handler.warp.selector;
        selectors[18] = handler.warp.selector;
        selectors[19] = handler.rotate.selector;
        selectors[20] = handler.rotateBeforeEta.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice L1: a request is delivered as soon as every commitment older than it is closed.
    function invariant_L1_requestsHeldOnlyByOlderCommitments() public view {
        assertEq(handler.prefixViolations(), 0);
    }

    /// @notice L2: stopping new commitments for MAX_HORIZON always lets a LONG_DELAY change execute.
    function invariant_L2_longChangeExecutesOnceCommitmentsAreStopped() public view {
        assertEq(handler.livenessViolations(), 0);
    }

    /// @notice S1: no LONG_DELAY change executes while shares are queued.
    function invariant_S1_noLongChangeWithQueuedShares() public view {
        assertEq(handler.longWhilePending(), 0);
    }

    /// @notice S2: every executed change waited its delay class and ran inside its window; no unexpected refusal.
    function invariant_S2_delaysAndWindowsHold() public view {
        assertEq(handler.delayViolations(), 0);
        assertEq(handler.otherFailures(), 0);
    }

    function invariant_accountingConsistent() public view {
        _assertAccountingConsistent();
    }

    /// @notice Non-vacuity counters, read by test/invariant/coverage.py.
    function afterInvariant() external view {
        console2.log("COV depositsOk", handler.depositsOk());
        console2.log("COV queuedOk", handler.queuedOk());
        console2.log("COV finalizedOk", handler.finalizedOk());
        console2.log("COV commitsOk", handler.commitsOk());
        console2.log("COV rotationsOk", handler.rotationsOk());
        console2.log("COV swapsOk", handler.swapsOk());
        console2.log("COV longExecuted", handler.longExecuted());
        console2.log("COV longBlocked", handler.longBlocked());
        console2.log("COV restrictedExecutions", handler.restrictedExecutions());
        console2.log("COV expiredOps", handler.expiredOps());
        console2.log("COV preEtaRotations", handler.preEtaRotations());
        console2.log("COV execAttempts", handler.execAttempts());
        console2.log("COV prefixChecks", handler.prefixChecks());
        console2.log("COV otherFailures", handler.otherFailures());
        console2.log("calls", handler.calls());
    }
}

/// @notice Guards against a vacuous campaign: one scripted sequence through the handler reaches every branch the
///         invariants depend on, with no violation: queued requests checked by L1, a LONG_DELAY change blocked by the
///         coalition, the same change executing once new commitments were stopped (an L2 case), fills, rotations and
///         a lifted restriction.
contract GovernanceLivenessCampaignTest is GovernanceLivenessInvariantsTest {
    function test_handler_reachesEveryBranch() public {
        handler.deposit(0, 50_000 ether);
        handler.deposit(1, 50_000 ether);
        handler.govQueue(); // t0; eta t0 + 32 days
        handler.warp(5 days);
        handler.rotate(); // the coalition commits all free asset0 until t0 + 35 days and queues a share
        handler.redeem(0, 10_000 ether, true); // queued behind it
        handler.commit(1, true, true, 50, 10 days); // asset1 to hook B, admitted against the queue
        handler.swap(1, 100 ether); // a fill from the asset1 commitment
        handler.warp(5 days);
        handler.rotate(); // re-commits until t0 + 40 days: lp0 is finalized, a new share is queued
        handler.redeem(1, 1000 ether, true); // queued behind the new commitment
        handler.govExecute(0); // at eta: refused
        handler.restrict(0); // buffer floors at the maximum, t0 + 32 days
        handler.rotate(); // refused: no new commitment
        handler.warp(8 days); // the last commitment expires and is released; the window has closed
        handler.govExecute(0); // canceled as expired
        handler.govQueue(); // t0 + 40 days
        handler.govExecute(3 days); // restricted since t0 + 32 days: required to execute, and does (L2)
        handler.lift();
        handler.commit(0, false, true, 50, 1 days);
        handler.emergencyRelease(0);
        handler.processQueue(4);
        handler.cancelRequest(0);
        handler.claim(0);
        handler.warp(2 days);

        assertGt(handler.prefixChecks(), 0, "L1 checked with a non-empty prefix");
        assertGt(handler.queuedOk(), 0);
        assertGt(handler.finalizedOk(), 0);
        assertGt(handler.swapsOk(), 0, "a fill");
        assertEq(handler.rotationsOk(), 2);
        assertEq(handler.longBlocked(), 1, "blocked by the coalition");
        assertEq(handler.expiredOps(), 1);
        assertEq(handler.restrictedExecutions(), 1, "executed once commitments were stopped");
        assertEq(handler.prefixViolations(), 0);
        assertEq(handler.livenessViolations(), 0);
        assertEq(handler.longWhilePending(), 0);
        assertEq(handler.delayViolations(), 0);
        assertEq(handler.otherFailures(), 0);
        _assertAccountingConsistent();
    }
}
