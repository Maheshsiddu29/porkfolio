// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @notice Phase 1A-H Task A: queue griefing audit. Each test is labelled INTENDED (a fairness property that must
///         hold) or DOS (behaviour that would be an avoidable denial of service if it occurred).
contract QueueGriefingTest is VaultTestBase {
    address internal lpA = makeAddr("lpA");
    address internal lpB = makeAddr("lpB");
    address internal lpSmall = makeAddr("lpSmall");
    address internal whale = makeAddr("whale");

    function setUp() public override {
        super.setUp();
        vm.startPrank(owner);
        vault.setCuratorCeiling(curator, c0, type(uint256).max);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Commit every admissible unit of token1 so that F1 == 0 and nothing can be delivered in kind.
    function _lockToken1() internal returns (uint256 id) {
        id = _allocate(keyA, c1, uint128(vault.admissibleCapacity(c1)));
        assertEq(vault.freeInventory(c1), 0);
    }

    function _status(uint256 req) internal view returns (ISharedCommitmentVault.RequestStatus) {
        return vault.requestStatus(req);
    }

    // ------------------------------------------------------------------
    // DOS: a stale (already deliverable) queue entry must not block other LPs' instant exits
    // ------------------------------------------------------------------

    /// @notice A small LP queues while token1 is fully committed. The commitment is then released, so the small
    ///         request is fully deliverable, but nobody has called processQueue. Another LP's instant exit must
    ///         not be refused merely because that stale entry exists: the queue is served first, then the exit.
    function test_DOS_staleDeliverableEntry_doesNotBlockInstantExit() public {
        _depositShares(lpSmall, 1000 ether);
        uint256 id = _lockToken1();
        (uint256 instant,,, uint256 req) = _redeem(lpSmall, 1000 ether, true);
        assertEq(instant, 0);
        assertEq(vault.pendingShares(), 1000 ether);

        vm.prank(owner);
        vault.release(id); // inventory is back; the small request is deliverable but not yet processed

        _depositShares(lpA, 10_000 ether);
        vm.prank(lpA);
        (uint256 i2,,, uint256 r2) = vault.redeem(10_000 ether, 0, 0, lpA, false);
        assertEq(i2, 10_000 ether, "instant exit refused by a stale, deliverable queue entry");
        assertEq(r2, 0);
        // FIFO preserved: the earlier request was finalized first, in the same transaction.
        assertEq(uint8(_status(req)), uint8(ISharedCommitmentVault.RequestStatus.Claimable));
        assertEq(vault.pendingShares(), 0);
        _assertEquations();
    }

    // ------------------------------------------------------------------
    // INTENDED: a small LP cannot manufacture a queue entry while inventory exists
    // ------------------------------------------------------------------

    function test_INTENDED_smallLpCannotForceQueueWhileInventoryExists() public {
        _depositShares(lpSmall, 1 ether);
        (uint256 instant,,, uint256 req) = _redeem(lpSmall, 1 ether, true);
        assertEq(instant, 1 ether);
        assertEq(req, 0, "no queue entry was created");
        assertEq(vault.pendingShares(), 0);

        // Other LPs keep exiting instantly.
        (instant,,,) = _redeem(lp0, 100_000 ether, false);
        assertEq(instant, 100_000 ether);
    }

    // ------------------------------------------------------------------
    // Queue-and-cancel cycles
    // ------------------------------------------------------------------

    /// @notice An attacker repeatedly cancels and re-queues a tiny request around an honest large request.
    ///         INTENDED: the honest request keeps its FIFO position and is finalized as soon as inventory allows;
    ///         the attacker's re-queued entries go to the tail. The attacker can raise pending demand D (and so
    ///         reduce admissible capacity for curators) only by its own pro-rata claim. Processing cost of the
    ///         canceled entries is bounded per call by maxSteps.
    function test_queueAndCancelCycles_boundedImpact() public {
        _depositShares(attacker, 100 ether);
        _depositShares(lpA, 500_000 ether);
        uint256 id1 = _allocate(keyA, c1, 1_000_000 ether);
        _lockToken1();

        uint256 admBefore = vault.admissibleCapacity(c0);
        (,,, uint256 a) = _redeem(attacker, 100 ether, true);
        uint256 admDuring = vault.admissibleCapacity(c0);
        assertLe(admBefore - admDuring, 100 ether + 1, "attacker blocked more than its pro-rata claim");
        (,,, uint256 big) = _redeem(lpA, 500_000 ether, true);

        for (uint256 i; i < 20; ++i) {
            vm.prank(attacker);
            vault.cancelRequest(a);
            (,,, a) = _redeem(attacker, 100 ether, true);
        }
        assertGt(a, big, "re-queued entries are behind the honest request");

        vm.prank(owner);
        vault.release(id1); // 1M token1 freed
        // Head is the attacker's first (canceled) entry; canceled entries cost one step each.
        uint256 calls;
        while (vault.pendingShares() != 0 && calls < 10) {
            vault.processQueue(8);
            ++calls;
        }
        assertEq(vault.pendingShares(), 0);
        assertEq(uint8(_status(big)), uint8(ISharedCommitmentVault.RequestStatus.Claimable));
        console2.log("processQueue(8) calls to drain 1 honest + 21 attacker entries (20 canceled):", calls);
        _assertEquations();
    }

    // ------------------------------------------------------------------
    // INTENDED (documented tradeoff): head-of-line under strict FIFO
    // ------------------------------------------------------------------

    /// @notice A large head request absorbs every unit of newly freed token1; smaller requests and new instant
    ///         exits behind it wait, even though token0 inventory is plentiful (an in-kind exit needs both assets).
    ///         This is the FIFO head-of-line tradeoff: it is NOT eliminated, only documented.
    function test_INTENDED_headOfLine_largePartialHead() public {
        _depositShares(whale, 900_000 ether);
        _depositShares(lpSmall, 1 ether);
        uint256 id1 = _allocate(keyA, c1, 300_000 ether);
        uint256 id2 = _lockToken1();
        (,,, uint256 w) = _redeem(whale, 900_000 ether, true);
        (,,, uint256 s) = _redeem(lpSmall, 1 ether, true);

        vm.prank(owner);
        vault.release(id1);
        vault.processQueue(10);
        assertEq(vault.getRequest(w).sharesPending, 600_000 ether, "whale partially finalized");
        assertEq(vault.getRequest(s).sharesPending, 1 ether, "small request waits behind the whale");

        // A new LP deposits and tries to exit at once: its token1 goes to the head first.
        _depositShares(lpB, 1 ether);
        assertGt(vault.freeInventory(c0), 1_000_000 ether, "token0 is plentiful");
        vm.prank(lpB);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientLiquidity.selector, 1 ether, 0));
        vault.redeem(1 ether, 0, 0, lpB, false);

        vm.prank(owner);
        vault.release(id2);
        vault.processQueue(10);
        assertEq(vault.pendingShares(), 0);
        assertEq(uint8(_status(s)), uint8(ISharedCommitmentVault.RequestStatus.Claimable));
        _assertEquations();
    }

    // ------------------------------------------------------------------
    // Interleaving
    // ------------------------------------------------------------------

    /// @notice Deposits, swaps, cancellations and emergency releases interleaved with queued redemptions.
    ///         A deposit made while the queue is pending feeds the head first (INTENDED); the depositor exits only
    ///         from what is left. Equations are re-derived from raw balances after every step.
    function test_interleaved_depositSwapCancelEmergencyRelease() public {
        _depositShares(lpA, 100_000 ether);
        uint256 idA = _lockToken1();
        (,,, uint256 ra) = _redeem(lpA, 100_000 ether, true); // fully pending: F1 == 0
        assertEq(vault.getRequest(ra).sharesPending, 100_000 ether);
        _assertEquations();

        // lpB deposits 300k: its token1 raises F1; when lpB redeems, the head (lpA) is served first.
        _depositShares(lpB, 300_000 ether);
        _assertEquations();
        (uint256 ib,,, uint256 rb) = _redeem(lpB, 300_000 ether, true);
        assertEq(uint8(_status(ra)), uint8(ISharedCommitmentVault.RequestStatus.Claimable), "head served first");
        assertGt(ib, 0, "lpB gets what is left instantly");
        assertLt(ib, 300_000 ether);
        assertGt(rb, ra);
        _assertEquations();

        // A trade consumes part of the old commitment while lpB is queued.
        _swap(keyA, true, 50_000 ether, idA);
        _assertEquations();

        // A third LP queues and cancels; lpA claims; an emergency release frees the rest.
        _depositShares(lpSmall, 10 ether);
        (,,, uint256 rs) = _redeem(lpSmall, 10 ether, true);
        vm.prank(lpSmall);
        vault.cancelRequest(rs);
        vm.prank(lpA);
        vault.claim(ra);
        _assertEquations();
        vm.prank(owner);
        vault.release(idA);
        vault.processQueue(5);
        assertEq(vault.pendingShares(), 0);
        vm.prank(lpB);
        vault.claim(rb);
        _assertEquations();
        _assertAccountingConsistent();
    }

    // ------------------------------------------------------------------
    // Multi-transaction processing of a long queue
    // ------------------------------------------------------------------

    function test_processingAcrossTransactions_longQueue() public {
        _depositShares(lpSmall, 12 ether);
        uint256 id = _lockToken1();
        for (uint256 i; i < 12; ++i) {
            _redeem(lpSmall, 1 ether, true);
        }
        vm.prank(owner);
        vault.release(id);

        // A newcomer's redeem serves part of the queue, but cannot jump the rest.
        _depositShares(lpA, 10 ether);
        (uint256 instant,,, uint256 rx) = _redeem(lpA, 10 ether, true);
        assertEq(instant, 0, "queue still pending after the bounded inline step");
        assertEq(rx, 13);

        vault.processQueue(5);
        vault.processQueue(5);
        vault.processQueue(5);
        assertEq(vault.pendingShares(), 0);
        for (uint256 r = 1; r <= 13; ++r) {
            assertEq(vault.getRequest(r).sharesPending, 0);
        }
        _assertEquations();
    }

    // ------------------------------------------------------------------
    // FIFO bypass attempts (all INTENDED to fail)
    // ------------------------------------------------------------------

    function test_INTENDED_fifoBypassAttemptsFail() public {
        _depositShares(lpA, 200_000 ether);
        _depositShares(lpB, 200_000 ether);
        uint256 id = _lockToken1();
        (,,, uint256 ra) = _redeem(lpA, 200_000 ether, true);

        // (a) Instant-only exit while the head is undeliverable.
        vm.prank(lpB);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientLiquidity.selector, 1 ether, 0));
        vault.redeem(1 ether, 0, 0, lpB, false);

        // (b) Splitting into many small requests does not overtake an earlier request.
        for (uint256 i; i < 5; ++i) {
            _redeem(lpB, 1000 ether, true);
        }
        // (c) Escrowed shares cannot be redeemed again, and nothing is claimable before finalization.
        vm.prank(lpA);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientShares.selector, 1, 0));
        vault.redeem(1, 0, 0, lpA, true);
        vm.prank(lpA);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NothingToClaim.selector, ra));
        vault.claim(ra);

        // (d) processQueue(0) is a no-op.
        assertEq(vault.processQueue(0), 0);

        // (e) Partial release: only the head progresses.
        vm.prank(owner);
        vault.release(id);
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyB, c1, 0);
        req.maxOut = uint128(vault.admissibleCapacity(c1));
        if (req.maxOut > 0) {
            vm.prank(curator);
            vault.allocate(req); // cannot take what the queue needs: admission subtracts D
        }
        vault.processQueue(100);
        assertEq(vault.pendingShares(), 0, "all pending demand was protected from the new allocation");
        _assertEquations();
    }
}
