// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {IMarketRiskAdapter} from "../../src/interfaces/IMarketRiskAdapter.sol";
import {VaultGovernor} from "../../src/governance/VaultGovernor.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {MockRiskAdapter} from "../utils/MockRiskAdapter.sol";
import {AdminBatch, QueueGriefer} from "../utils/GovernanceActors.sol";

/// @notice Withdrawal-queue griefing against `VaultGovernor`'s LONG_DELAY queue check, played deterministically
///         against the real vault, PoolManager and authorization module.
///
///         The check (`execute` reverts while `vault.pendingShares() != 0`) is a liveness hazard only if someone can keep
///         a request undeliverable. Free inventory protects every request that existed when a commitment was admitted
///         (admission subtracts the queue's pro-rata claim D_a), so a request can be held only by commitments that
///         are older than it. These tests measure what that takes, show the case where it can be sustained without
///         end (a curator that is also an LP), and show the governance actions that end it without touching any LP's
///         protection.
contract GovernanceLivenessTest is VaultTestBase {
    address internal signer = makeAddr("adminSigner");
    address internal guardian = makeAddr("guardian");
    address internal lpA = makeAddr("lpA");
    AdminBatch internal admin;
    VaultGovernor internal gov;
    QueueGriefer internal griefer;
    uint256 internal tau;
    address internal v;
    bytes internal loosen; // LONG_DELAY: tolerance 5% -> 10% on both assets

    function setUp() public override {
        super.setUp();
        v = address(vault);
        tau = FullMath.mulDiv(vault.backing(c0), 1e18, vault.totalShares());
        admin = new AdminBatch(signer);
        gov = new VaultGovernor(v, address(admin), 3 days, 32 days, 7 days);
        griefer = new QueueGriefer(vault, auth, keyA, c0);
        token0.mint(address(griefer), 1000);
        token1.mint(address(griefer), 1000);

        vm.startPrank(owner);
        vault.setGuardian(guardian);
        vault.setInventoryBounds(tau, tau, 50_000, 50_000);
        vault.setCurator(address(griefer), true);
        vault.setCuratorCeiling(address(griefer), c0, type(uint256).max);
        vault.setCuratorCeiling(curator, c0, type(uint256).max);
        _openLimits(ISharedCommitmentVault.RiskScope.Curator, address(griefer));
        vault.transferOwnership(address(gov));
        vm.stopPrank();
        _run1(address(gov), abi.encodeCall(gov.acceptVaultOwnership, ()));
        loosen = abi.encodeCall(vault.setInventoryBounds, (tau, tau, 100_000, 100_000));
    }

    // =================================================================== admin helpers

    function _run1(address target, bytes memory data) internal {
        AdminBatch.Call[] memory calls = new AdminBatch.Call[](1);
        calls[0] = AdminBatch.Call(target, data);
        vm.prank(signer);
        admin.run(calls);
    }

    function _queueGov(bytes memory data) internal returns (uint256 eta) {
        eta = vm.getBlockTimestamp() + gov.delayFor(v, data);
        _run1(address(gov), abi.encodeCall(gov.queue, (v, data)));
    }

    /// @dev Unreleased allocations whose expiry has passed: anyone may release them.
    function _expired() internal view returns (uint256[] memory ids) {
        uint256 n = vault.nextAllocationId();
        ids = new uint256[](n);
        uint256 k;
        for (uint256 id = 1; id < n; ++id) {
            ISharedCommitmentVault.Allocation memory a = vault.getAllocation(id);
            if (!a.released && vm.getBlockTimestamp() >= a.expiry) ids[k++] = id;
        }
        assembly ("memory-safe") {
            mstore(ids, k)
        }
    }

    /// @dev The prescribed admin transaction: release every expired commitment (permissionless), process the queue,
    ///      execute. Atomic: if `execute` reverts, the releases and processing revert with it.
    function _tryExecute(bytes memory data, bool releaseExpired) internal returns (bool ok, bytes memory err) {
        uint256[] memory ids = releaseExpired ? _expired() : new uint256[](0);
        AdminBatch.Call[] memory calls = new AdminBatch.Call[](ids.length + 2);
        for (uint256 i; i < ids.length; ++i) {
            calls[i] = AdminBatch.Call(v, abi.encodeCall(vault.release, (ids[i])));
        }
        calls[ids.length] = AdminBatch.Call(v, abi.encodeCall(vault.processQueue, (256)));
        calls[ids.length + 1] = AdminBatch.Call(address(gov), abi.encodeCall(gov.execute, (v, data)));
        vm.prank(signer);
        try admin.run(calls) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
    }

    function _assertBlocked(bytes memory data) internal {
        (bool ok, bytes memory err) = _tryExecute(data, true);
        assertFalse(ok, "LONG_DELAY change executed");
        assertEq(bytes4(err), VaultGovernor.PendingWithdrawals.selector, "refused for another reason");
    }

    function _assertExecutes(bytes memory data) internal {
        (bool ok, bytes memory err) = _tryExecute(data, true);
        if (!ok) {
            emit log_named_bytes("revert", err);
            fail();
        }
        assertEq(vault.pendingShares(), 0);
    }

    /// @dev The honest fixture curator commits every admissible unit of asset0 for `horizon` seconds.
    function _commitAll(uint256 horizon) internal returns (uint256 id) {
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyA, c0, uint128(vault.admissibleCapacity(c0)));
        r.expiry = uint64(vm.getBlockTimestamp() + horizon);
        vm.prank(curator);
        id = auth.activateDirect(r);
    }

    // =================================================================== single-shot blocking

    /// @notice With the fixture's limits (vault-scope exposure cap 100%, no buffer floor), an honest curator that commits
    ///         all free asset0 leaves nothing deliverable, and one share queued behind it holds a LONG_DELAY change until
    ///         the commitment expires and is released. Capital: one share, bought for one raw unit of each asset,
    ///         bought before the commitment (bought after, it would bring its own free inventory and redeem instantly).
    ///         An expired commitment keeps blocking until someone releases it, which the admin's batch does.
    function test_oneShare_holdsLongChange_whileFullyCommitted() public {
        uint256 t0 = T0;
        uint256 eta = _queueGov(loosen);
        (uint256 paid0, uint256 paid1) = _depositShares(attacker, 1);
        assertEq(paid0 + paid1, 2, "capital: one raw unit of each asset");

        vm.warp(t0 + 5 days);
        uint256 id = _commitAll(30 days); // honest: lasts until t0 + 35 days, past eta
        assertEq(lens.deliverableShares(vault), 0);
        _redeem(attacker, 1, true);
        console2.log("gas, queuing one share:", vm.lastCallGas().gasTotalUsed);
        assertEq(vault.pendingShares(), 1);

        vm.warp(eta);
        _assertBlocked(loosen);

        vm.warp(t0 + 35 days); // expired, not yet released
        (bool ok, bytes memory err) = _tryExecute(loosen, false);
        assertFalse(ok);
        assertEq(err, abi.encodeWithSelector(VaultGovernor.PendingWithdrawals.selector, 1), "lazy expiry still blocks");
        assertEq(_expired()[0], id);
        _assertExecutes(loosen); // the same batch with the release included
        assertEq(vault.inventoryTolerancePips(0), 100_000);
    }

    /// @notice A share bought after the commitment brings its own free inventory: depositing x shares raises the
    ///         deliverable count by exactly x, so the deposit's own redemption is always instant.
    function test_sharesBoughtAfterCommitment_redeemInstantly() public {
        _commitAll(30 days);
        assertEq(lens.deliverableShares(vault), 0);
        _depositShares(attacker, 1000);
        assertEq(lens.deliverableShares(vault), 1000);
        (uint256 instant,,, uint256 rid) = _redeem(attacker, 1000, true);
        assertEq(instant, 1000);
        assertEq(rid, 0);
    }

    /// @notice The vault-scope exposure cap b sets the capital a lone LP needs. With b = 50% and every allowed unit
    ///         committed, the deliverable share count is half the supply. A holder of exactly that many shares
    ///         redeems them all instantly; one share more leaves exactly one share queued, and that share blocks.
    ///         So a lone LP needs more than (1 - b) of all shares, held before the commitment was made.
    function test_exposureCap_setsCapitalNeededToHoldTheQueue() public {
        vm.startPrank(address(gov)); // configuration shortcut; the governor's delays are not under test here
        vault.setRiskLimit(ISharedCommitmentVault.RiskScope.Vault, address(0), c0, MAX_FLOW_CAP, 5000);
        vault.setRiskLimit(ISharedCommitmentVault.RiskScope.Vault, address(0), c1, MAX_FLOW_CAP, 5000);
        vm.stopPrank();
        address whale = makeAddr("whale");
        _depositShares(whale, 1_500_000 ether);
        uint256 eta = _queueGov(loosen);
        vm.warp(eta - 1 days);
        uint256 cap = lens.exposureAvailable(vault, ISharedCommitmentVault.RiskScope.Vault, address(0), c0);
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyA, c0, uint128(cap));
        r.expiry = uint64(vm.getBlockTimestamp() + 30 days);
        vm.prank(curator);
        auth.activateDirect(r);

        uint256 supply = vault.totalShares();
        uint256 deliverable = lens.deliverableShares(vault);
        console2.log("supply / deliverable shares:", supply, deliverable);
        assertApproxEqAbs(deliverable, supply / 2, 1, "(1 - b) of the supply is deliverable");

        uint256 snap = vm.snapshotState();
        (uint256 instant,,, uint256 rid) = _redeem(whale, deliverable, true);
        assertEq(instant, deliverable);
        assertEq(rid, 0, "at the threshold nothing is queued");
        vm.warp(eta);
        _assertExecutes(loosen);

        vm.revertToState(snap);
        (instant,,, rid) = _redeem(whale, deliverable + 1, true);
        assertEq(instant, deliverable);
        assertEq(vault.getRequest(rid).sharesPending, 1, "one share over the threshold is queued");
        vm.warp(eta);
        _assertBlocked(loosen);
    }

    // =================================================================== sustained blocking

    /// @notice Counterexample: a curator that is also an LP blocks a LONG_DELAY change for as long as it keeps
    ///         rotating. Each `rotate` (one transaction) cancels its commitment, commits everything admissible again
    ///         and queues one more share. The new commitment is admitted against the shares already queued, so those
    ///         become deliverable; the share queued right after it is not, and every later attempt finds it pending.
    ///         The change is refused at eta, inside GRACE and after re-queuing, across 115 days.
    ///
    ///         Per-request liveness is unaffected: an honest LP who queued behind the first commitment is finalized at
    ///         the first rotation, 9 days later, while governance stays blocked. Withdrawal liveness and LONG_DELAY
    ///         liveness are different properties; only the second fails here.
    function test_curatorLpCoalition_blocksLongChangeWhileRotating() public {
        uint256 t0 = T0;
        griefer.deposit(100); // 100 raw units of each asset, bought before any commitment
        _depositShares(lpA, 10_000 ether);
        uint256 eta = _queueGov(loosen);
        griefer.rotate(30 days, 1);
        vm.warp(t0 + 1 days);
        (,,, uint256 honest) = _redeem(lpA, 10_000 ether, true);
        assertEq(vault.getRequest(honest).sharesPending, 10_000 ether, "the honest LP is queued");

        uint256 rotations = 1;
        uint256 rotateGas;
        for (uint256 round; round < 3; ++round) {
            // Rotate every 9 days until the window opens, then probe the window at eta, mid-GRACE and its last second.
            while (vm.getBlockTimestamp() + 9 days < eta) {
                vm.warp(vm.getBlockTimestamp() + 9 days);
                griefer.rotate(30 days, 1);
                rotateGas = vm.lastCallGas().gasTotalUsed;
                ++rotations;
                if (rotations == 2) {
                    assertEq(vault.getRequest(honest).sharesPending, 0, "honest LP finalized at the first rotation");
                }
            }
            for (uint256 k; k < 3; ++k) {
                vm.warp(eta + k * 7 days / 2);
                _assertBlocked(loosen);
            }
            vm.warp(eta + 7 days + 1);
            vm.expectRevert(); // NotExecutable: the window closed
            _run1(address(gov), abi.encodeCall(gov.execute, (v, loosen)));
            _run1(address(gov), abi.encodeCall(gov.cancel, (v, loosen)));
            eta = _queueGov(loosen);
        }
        assertGt(vm.getBlockTimestamp(), t0 + 115 days);
        console2.log("rotations / gas of the last rotation:", rotations, rotateGas);
        console2.log("griefer shares still held:", vault.sharesOf(address(griefer)));
        _assertEquations();
    }

    /// @notice Restricting new commitments ends the coalition's blocking within MAX_HORIZON, with each of the
    ///         guardian's immediate levers: a buffer floor at the maximum, a vault-scope exposure cap of zero, a pause,
    ///         or deregistering the curator. None of them touches an LP: exits, queue processing and claims stay open.
    ///         The coalition keeps queuing shares, even in the block of the admin's transaction, and the change still
    ///         executes at eta, because the commitment those shares wait behind expires before eta and the batch
    ///         releases it.
    function test_restrictingNewCommitments_endsBlockingWithinMaxHorizon() public {
        griefer.deposit(100);
        griefer.rotate(30 days, 1);
        vm.warp(vm.getBlockTimestamp() + 9 days);
        griefer.rotate(30 days, 1);
        uint256 lastExpiry = vault.getAllocation(griefer.liveAllocation()).expiry;

        for (uint256 lever; lever < 4; ++lever) {
            uint256 snap = vm.snapshotState();
            vm.startPrank(guardian);
            if (lever == 0) {
                vault.setBufferFloor(c0, type(uint256).max);
            } else if (lever == 1) {
                vault.setRiskLimit(ISharedCommitmentVault.RiskScope.Vault, address(0), c0, MAX_FLOW_CAP, 0);
            } else if (lever == 2) {
                vault.setPaused(true);
            } else {
                vault.setCurator(address(griefer), false);
            }
            vm.stopPrank();
            uint256 eta = _queueGov(loosen); // queued as the lever is applied: eta is 32 days out, MAX_HORIZON is 30

            vm.warp(vm.getBlockTimestamp() + 9 days);
            vm.expectRevert(); // the coalition can no longer re-commit
            griefer.rotate(30 days, 1);
            griefer.queue(1); // but it can still queue

            vm.warp(eta);
            assertLe(lastExpiry, eta);
            griefer.queue(1); // front-runs the admin in the same block
            _assertExecutes(loosen);
            vm.revertToState(snap);
        }
    }

    /// @notice The guardian's emergency release ends the blocking in the same block, provided new commitments are
    ///         stopped first. A release alone does not: the coalition re-commits and re-queues before the admin's
    ///         transaction. Releasing breaks the commitment to its hook, which is why it is an emergency power.
    function test_emergencyRelease_endsBlockingInOneBlock_onlyWithARestriction() public {
        griefer.deposit(100);
        uint256 eta = _queueGov(loosen);
        vm.warp(eta - 1 days);
        griefer.rotate(30 days, 1);
        vm.warp(eta);

        uint256 snap = vm.snapshotState();
        uint256 id = griefer.liveAllocation();
        vm.prank(guardian);
        vault.release(id);
        griefer.commitAll(30 days); // front-run
        griefer.queue(1);
        _assertBlocked(loosen);

        vm.revertToState(snap);
        vm.startPrank(guardian);
        vault.setBufferFloor(c0, type(uint256).max);
        vault.release(griefer.liveAllocation());
        vm.stopPrank();
        vm.expectRevert();
        griefer.commitAll(30 days);
        vm.expectRevert(bytes("not queued")); // inventory is free again: a new redemption is paid at once
        griefer.queue(1);
        _assertExecutes(loosen);
    }

    // =================================================================== other orderings

    /// @notice Requests submitted just before the admin's transaction do not block when they are deliverable: a stale
    ///         request (deliverable but never processed) and several new redemptions from different accounts in the
    ///         same block are all finalized or paid by the batch, which then executes.
    function test_deliverableRequestsBeforeExecution_areProcessedByTheBatch() public {
        _depositShares(lpA, 1000 ether);
        uint256 eta = _queueGov(loosen);
        uint256 id = _commitAll(2 days);
        _redeem(lpA, 1000 ether, true);
        vm.warp(eta);
        vault.release(id); // expired and released, but nobody processed the queue
        assertEq(vault.pendingShares(), 1000 ether);
        for (uint256 i; i < 5; ++i) {
            address lp = makeAddr(string.concat("late", vm.toString(i)));
            _depositShares(lp, 10 ether);
            _redeem(lp, 10 ether, true); // inline processing serves the stale request first, then pays instantly
        }
        _assertExecutes(loosen);
    }

    /// @notice Many accounts each queue one share behind a full commitment. Measures the attacker's cost per request
    ///         and the admin's cost per finalized entry, and shows the batch clears all of them once the commitment is
    ///         released.
    function test_queueFlood_manyAccounts_costPerEntry() public {
        uint256 n = 100;
        address[] memory lps = new address[](n);
        for (uint256 i; i < n; ++i) {
            lps[i] = makeAddr(string.concat("flood", vm.toString(i)));
            _depositShares(lps[i], 1);
        }
        uint256 eta = _queueGov(loosen);
        vm.warp(eta - 1 days);
        _commitAll(30 days);
        uint256 queueGas;
        for (uint256 i; i < n; ++i) {
            _redeem(lps[i], 1, true);
            queueGas += vm.lastCallGas().gasTotalUsed;
        }
        assertEq(vault.pendingShares(), n);
        vm.warp(eta);
        _assertBlocked(loosen);

        // The commitment lasts 30 days from eta - 1 day, so the window [eta, eta + GRACE] closes first; the guardian
        // releases it (emergency) and the batch clears all n entries in one transaction.
        vm.warp(eta + 1 days);
        vm.prank(guardian);
        vault.release(1);
        uint256 snap = vm.snapshotState();
        vault.processQueue(n);
        uint256 processGas = vm.lastCallGas().gasTotalUsed;
        vm.revertToState(snap);
        console2.log(
            "entries / attacker gas per request / admin gas per finalized entry:", n, queueGas / n, processGas / n
        );
        _assertExecutes(loosen);
    }

    /// @notice A partially finalized head request still blocks, with the exact remainder reported; it unblocks when
    ///         the rest of its basket is freed.
    function test_partialFulfillment_blocksWithExactRemainder() public {
        _depositShares(lpA, 1_000_000 ether);
        uint256 eta = _queueGov(loosen);
        vm.warp(eta - 20 days);
        uint256 quarter = vault.admissibleCapacity(c0) / 4;
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyA, c0, uint128(quarter));
        r.expiry = uint64(vm.getBlockTimestamp() + 10 days); // expires before eta
        vm.prank(curator);
        auth.activateDirect(r);
        _commitAll(30 days); // the rest: expires after the window
        (,,, uint256 rid) = _redeem(lpA, 1_000_000 ether, true);

        vm.warp(eta);
        vault.release(_expired()[0]);
        vault.processQueue(8);
        ISharedCommitmentVault.WithdrawalRequest memory q = vault.getRequest(rid);
        assertGt(q.claimable0, 0, "partially finalized");
        assertGt(q.sharesPending, 0);
        (bool ok, bytes memory err) = _tryExecute(loosen, true);
        assertFalse(ok);
        assertEq(err, abi.encodeWithSelector(VaultGovernor.PendingWithdrawals.selector, q.sharesPending));

        vm.prank(guardian);
        vault.release(2);
        _assertExecutes(loosen);
        assertEq(vault.getRequest(rid).sharesPending, 0);
    }

    /// @notice A change blocked through its whole window expires. It cannot be re-armed while the stale record exists
    ///         (`AlreadyQueued`); after a cancel (admin or guardian), queuing it again starts a full LONG_DELAY.
    function test_expiredOperation_requeueStartsAFullDelay() public {
        _depositShares(lpA, 1000 ether);
        uint256 eta = _queueGov(loosen);
        vm.warp(eta - 1 days);
        _commitAll(30 days);
        _redeem(lpA, 1000 ether, true);
        vm.warp(eta + 7 days);
        _assertBlocked(loosen);
        vm.warp(eta + 7 days + 1);
        (bool ok, bytes memory err) = _tryExecute(loosen, true);
        assertFalse(ok);
        assertEq(bytes4(err), VaultGovernor.NotExecutable.selector);

        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.AlreadyQueued.selector, gov.operationId(v, loosen)));
        _run1(address(gov), abi.encodeCall(gov.queue, (v, loosen)));
        vm.prank(guardian);
        gov.cancel(v, loosen);
        uint256 eta2 = _queueGov(loosen);
        assertEq(eta2, vm.getBlockTimestamp() + 32 days);
    }

    /// @notice An oracle outage stops fills but neither LP exits nor governance: with the adapter reverting, the
    ///         queued LP is finalized and claims, and the LONG_DELAY change executes once the commitment is released.
    function test_oracleFailure_doesNotHoldTheQueueOrGovernance() public {
        MockRiskAdapter adapter = new MockRiskAdapter(address(token0), address(token1), 18, 18, keccak256("g02"));
        adapter.set(FixedPoint96.Q96, 1000, type(uint256).max);
        vm.startPrank(address(gov)); // configuration shortcut; the governor's delays are not under test here
        vault.setRiskBounds(100, 5000);
        vault.setRiskAdapter(IMarketRiskAdapter(address(adapter)));
        vm.stopPrank();

        _depositShares(lpA, 1000 ether);
        uint256 eta = _queueGov(loosen);
        vm.warp(eta - 10 days);
        uint256 id = _commitAll(5 days);
        (,,, uint256 rid) = _redeem(lpA, 1000 ether, true);
        adapter.setBroken(true);
        vm.expectRevert();
        lens.effectiveFloorX96(vault, id); // no fill can be priced

        vm.warp(eta);
        _assertExecutes(loosen);
        vm.prank(lpA);
        vault.claim(rid);
        assertGt(token0.balanceOf(lpA), 0);
    }
}
