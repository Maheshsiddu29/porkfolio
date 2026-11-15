// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IBondEscrow} from "../../src/interfaces/IBondEscrow.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {BondLedgerModel} from "../model/BondLedgerModel.sol";
import {BondTestBase} from "../utils/BondTestBase.sol";

/// @notice Compares the production escrow, vault and PoolManager against an independent, unbounded bond ledger model
///         after randomized activation, fill, sync, cancellation, expiry, settlement, realization and claim steps.
/// @dev The model uses an ordinary mapping of expiry drops and walks every bucket; the escrow uses a 720-slot ring.
///      All bonds reserve asset1 at one fixed rate and minimum duration, so each model reservation maps to one vault
///      allocation. The model does not model swap prices or vault backing; the comparison covers bond accounting and
///      the actual escrow claim balance. The prelude makes late sync, early close, settlement and payout non-vacuous
///      even when a random schedule omits an action.
contract BondEscrowDifferentialTest is BondTestBase {
    BondLedgerModel internal model;
    uint256[] internal ids;
    uint256 internal posted;
    uint256 internal fills;
    uint256 internal syncs;
    uint256 internal closes;
    uint256 internal settlements;
    uint256 internal realizations;
    uint256 internal refunds;

    function setUp() public override {
        super.setUp();
        vm.warp(_hourAligned(vm.getBlockTimestamp()) + 1 hours);
        model = new BondLedgerModel(1 hours, T_MIN, PROTOCOL_BPS, lens.netAssets(vault, c1), lens.totalShares(vault));
    }

    function _post(uint128 amount, uint256 hoursAhead) internal {
        uint256 now_ = vm.getBlockTimestamp();
        uint64 expiry = uint64(uint256(_hourAligned(now_)) + hoursAhead * 1 hours);
        // The long schedule warps repeatedly in one test call. Build the request from the cheatcode's current time:
        // `_request` uses block.timestamp, which via-IR can reuse from before a warp in this test frame.
        ISharedCommitmentVault.AllocationRequest memory req = ISharedCommitmentVault.AllocationRequest({
            consumer: address(keyS.hooks),
            key: keyS,
            currencyOut: c1,
            maxOut: amount,
            minInPerOutX96: PRICE_1_1_X96,
            expiry: expiry,
            nonce: nextNonce++,
            deadline: uint64(now_)
        });
        vm.prank(curator);
        uint256 id = bonded.activateDirectBonded(req, type(uint256).max);
        uint256 mid = model.create(curator, amount, expiry, RHO);
        assertEq(mid, ids.length);
        ids.push(id);
        ++posted;
    }

    function _fill(uint256 mid, uint128 amount) internal {
        _swap(keyS, true, amount, ids[mid]);
        model.vaultConsume(mid, amount);
        ++fills;
    }

    function _sync(uint256 mid) internal {
        escrow.sync(ids[mid]);
        model.sync(mid);
        ++syncs;
    }

    function _close(uint256 mid) internal {
        vm.prank(curator);
        vault.cancelAllocation(ids[mid]);
        escrow.sync(ids[mid]);
        model.close(mid);
        ++closes;
    }

    function _settle(uint256 mid) internal {
        (uint256 charge, uint256 refund) = escrow.settle(ids[mid]);
        model.settle(mid);
        BondLedgerModel.Reservation memory m = model.get(mid);
        assertEq(charge, m.charge, "charge");
        assertEq(refund, m.bond - m.charge, "refund");
        ++settlements;
    }

    function _realize() internal {
        escrow.realize(type(uint256).max);
        model.realize();
        ++realizations;
    }

    /// @dev A full step check: historical aggregate state, the current unbounded accrual, all per-bond terms, every
    ///      money bucket, and the real PoolManager's escrow claims. The last equality catches value created or lost
    ///      even when the model's individual fee buckets happen to agree.
    function _check() internal view {
        IBondEscrow.Ledger memory l = escrow.getLedger(c1);
        assertEq(l.rate, model.rate(), "aggregate rate");
        assertEq(l.last, model.aggLast(), "aggregate last");
        assertEq(l.accrued, model.aggAccrued(), "aggregate accrued");
        assertEq(model.aggNow(), model.sumAccruedNow(), "model sum at now");
        assertEq(l.settledCharges, model.settledCharges(), "settled charges");
        assertEq(l.realized, model.realized(), "realized");
        assertEq(l.protocolOwed, model.protocolCredited() - model.protocolPaid(), "protocol owed");
        assertEq(l.refundsOwed, model.refundsOwedTotal(), "refunds owed");
        assertEq(l.openBonds, model.unsettledBonds(), "open bonds");
        assertEq(_claims(address(escrow), c1), model.escrow(), "actual escrow claims");
        assertEq(_claims(address(escrow), c0), 0, "no asset0 bond");
        (uint256 lp, uint256 protocolPart) = escrow.unrealized(c1);
        assertEq(lp + protocolPart, model.unrealized(), "unrealized");
        for (uint256 i; i < ids.length; ++i) {
            IBondEscrow.Bond memory b = escrow.getBond(ids[i]);
            BondLedgerModel.Reservation memory m = model.get(i);
            assertEq(b.payer, m.payer);
            assertEq(b.created, m.created);
            assertEq(b.expiry, m.expiry);
            assertEq(b.last, m.last);
            assertEq(b.rate, m.rho);
            assertEq(b.amount, m.amount);
            assertEq(b.synced, m.synced);
            assertEq(b.remaining, m.r);
            assertEq(b.bond, m.bond);
            assertEq(b.accrued, m.accrued);
            assertEq(b.charge, m.charge);
            assertEq(b.closed, m.closed);
            assertEq(b.settled, m.settled);
        }
    }

    function _randomStep(uint256 x) internal {
        uint256 n = ids.length;
        uint256 kind = x % 9;
        if (kind == 0 && n < 8) {
            _post(uint128((1 + (x >> 8) % 5000) * 1 ether), 1 + (x >> 24) % 72);
        } else if (kind == 1 && n != 0) {
            uint256 mid = (x >> 8) % n;
            BondLedgerModel.Reservation memory m = model.get(mid);
            if (!m.closed && !m.settled && vm.getBlockTimestamp() < m.expiry && m.vaultConsumed < m.amount) {
                uint128 amount = uint128(1 + (x >> 24) % (m.amount - m.vaultConsumed));
                _fill(mid, amount);
            }
        } else if (kind == 2 && n != 0) {
            uint256 mid = (x >> 8) % n;
            if (!model.get(mid).settled) _sync(mid);
        } else if (kind == 3 && n != 0) {
            uint256 mid = (x >> 8) % n;
            BondLedgerModel.Reservation memory m = model.get(mid);
            if (!m.closed && !m.settled && vm.getBlockTimestamp() < m.expiry) _close(mid);
        } else if (kind == 4 && n != 0) {
            uint256 mid = (x >> 8) % n;
            BondLedgerModel.Reservation memory m = model.get(mid);
            if (!m.settled && (m.closed || vm.getBlockTimestamp() >= m.expiry)) _settle(mid);
        } else if (kind == 5) {
            _realize();
        } else if (kind == 6 && model.refundOwed(curator) != 0) {
            vm.prank(curator);
            escrow.claimRefund(curator);
            model.claimRefund(curator);
            ++refunds;
        } else if (kind == 7 && model.protocolCredited() != model.protocolPaid()) {
            vm.prank(protocol);
            escrow.claimProtocol(protocol);
            model.claimProtocol();
        } else if (kind == 8) {
            vm.warp(vm.getBlockTimestamp() + 1 + (x >> 8) % 1 days);
        }
    }

    /// forge-config: default.fuzz.runs = 64
    /// forge-config: ci.fuzz.runs = 256
    /// @notice Random schedules are compared after every operation; every schedule also exercises a real fill that
    ///         is synced later, an early close, settlement, realization and a claim. At the end every remaining bond
    ///         expires and the sum of bonds is exactly LP fees plus protocol fees plus refunds.
    function testFuzz_realVaultMatchesBondModel(uint256 seed) public {
        _post(10_000 ether, 72);
        _fill(0, 1000 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _sync(0);
        _close(0);
        _settle(0);
        _realize();
        vm.prank(curator);
        escrow.claimRefund(curator);
        model.claimRefund(curator);
        ++refunds;
        _check();

        for (uint256 step; step < 24; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            _randomStep(seed);
            _check();
        }
        for (uint256 i; i < ids.length; ++i) {
            BondLedgerModel.Reservation memory m = model.get(i);
            if (vm.getBlockTimestamp() < m.expiry) vm.warp(m.expiry);
            if (!m.settled) _settle(i);
            _check();
        }
        _realize();
        if (model.refundOwed(curator) != 0) {
            vm.prank(curator);
            escrow.claimRefund(curator);
            model.claimRefund(curator);
            ++refunds;
        }
        if (model.protocolCredited() != model.protocolPaid()) {
            vm.prank(protocol);
            escrow.claimProtocol(protocol);
            model.claimProtocol();
        }
        _check();
        assertEq(model.posted(), model.lpMoved() + model.refundsPaid() + model.protocolPaid());
        assertEq(_claims(address(escrow), c1), 0);
        assertGt(posted, 0);
        assertGt(fills, 0);
        assertGt(syncs, 0);
        assertGt(closes, 0);
        assertGt(settlements, 0);
        assertGt(realizations, 0);
        assertGt(refunds, 0);
    }
}
