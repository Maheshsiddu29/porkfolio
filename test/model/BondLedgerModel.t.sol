// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {BondLedgerModel} from "./BondLedgerModel.sol";

/// @notice Checks of the PROPOSED V2 bond escrow accounting (G05_V2_ARCHITECTURE.md §4) on a test-only model. They
///         say nothing about `src/`, which has no bonds or reservation fees.
contract BondLedgerModelTest is Test {
    uint256 internal constant H = 1 hours;
    uint256 internal constant DAY = 1 days;
    uint256 internal constant T0 = 1_800_000_000; // an hour boundary
    /// @dev 1e-9 fee units per reserved unit per second (about 3.15% a year).
    uint256 internal constant RHO = 1e9;

    address internal payer = makeAddr("payer");
    address internal payer2 = makeAddr("payer2");

    function setUp() public {
        vm.warp(T0);
    }

    function _model() internal returns (BondLedgerModel) {
        return new BondLedgerModel(H, H, 1000, 1_000_000 ether, 1_000_000 ether);
    }

    /// @notice The escrow learns of a fill only when someone syncs. A sync one day late charges exactly the reserved
    ///         unit-seconds of that day on the consumed units: the payer, not the LPs, bears the delay, and can
    ///         avoid it by syncing in the fill's transaction.
    function test_lazySync_overchargeIsExact() public {
        BondLedgerModel prompt = _model();
        BondLedgerModel late = _model();
        uint64 expiry = uint64(T0 + 10 * DAY);
        prompt.create(payer, 100_000 ether, expiry, RHO);
        late.create(payer, 100_000 ether, expiry, RHO);

        vm.warp(T0 + 2 * DAY);
        prompt.vaultConsume(0, 30_000 ether);
        prompt.sync(0);
        late.vaultConsume(0, 30_000 ether);
        vm.warp(T0 + 3 * DAY);
        late.sync(0);

        vm.warp(expiry);
        prompt.settle(0);
        late.settle(0);
        // prompt: 100,000 * 2 d + 70,000 * 8 d = 760,000 token-days -> 65.664
        assertEq(prompt.get(0).charge, 65.664 ether);
        // late: + 30,000 token-days more -> + 2.592
        assertEq(late.get(0).charge - prompt.get(0).charge, 2.592 ether, "30,000 * 1 day * 1e-9");
    }

    /// @notice Example D again, now through aggregate realization: the escrow realizes on day 5 without touching the
    ///         reservation, and the LP and protocol totals at the end equal the per-reservation charge exactly.
    function test_aggregateRealization_matchesPerReservationCharge() public {
        BondLedgerModel m = _model();
        m.create(payer, 100_000 ether, uint64(T0 + 10 * DAY), RHO);
        vm.warp(T0 + 2 * DAY);
        m.vaultConsume(0, 30_000 ether);
        m.sync(0);
        vm.warp(T0 + 5 * DAY);
        m.realize(); // 100,000 * 2 d + 70,000 * 3 d = 410,000 token-days = 35.424
        assertEq(m.realized(), 35.424 ether);
        assertEq(m.lpMoved(), 31.8816 ether);
        vm.warp(T0 + 6 * DAY);
        m.close(0);
        m.settle(0);
        m.realize();
        assertEq(m.get(0).charge, 41.472 ether, "same charge as G03 example D");
        assertEq(m.realized(), 41.472 ether);
        assertEq(m.lpMoved(), 37.3248 ether);
        assertEq(m.protocolCredited(), 4.1472 ether);
        assertEq(m.refundOwed(payer), 86.4 ether - 41.472 ether);
        assertEq(m.escrow(), m.refundsOwedTotal() + m.protocolCredited() - m.protocolPaid());
    }

    /// @notice A just-in-time depositor cannot buy fees earned before it arrived: `deposit` realizes first, so the
    ///         earned 86.4 is already in N when the deposit is priced. Redeeming at once returns what was paid, less
    ///         at most one raw unit. (In G03's model without this step the same depositor took 43.2.)
    function test_jitDeposit_buysNoPastFees() public {
        BondLedgerModel m = new BondLedgerModel(H, H, 0, 1000 ether, 1000 ether);
        m.create(payer, 1000 ether, uint64(T0 + 10 * DAY), RHO);
        vm.warp(T0 + 10 * DAY);
        uint256 paid = m.deposit(1000 ether);
        assertEq(m.realized(), 0.864 ether, "earned fees realized before pricing");
        uint256 got = m.redeem(1000 ether);
        assertLe(got, paid);
        assertLe(paid - got, 1);
    }

    /// @notice An LP that exits before a realization forfeits its share of the unrealized fees to the shares that
    ///         stay; it can avoid this by calling `realize` first. The amount forfeited is exactly its pro-rata part of
    ///         `unrealized()` at exit, up to rounding.
    function test_exitBeforeRealization_forfeitsProRata() public {
        BondLedgerModel m = new BondLedgerModel(H, H, 0, 1000 ether, 1000 ether);
        m.create(payer, 1000 ether, uint64(T0 + 10 * DAY), RHO);
        vm.warp(T0 + 10 * DAY);
        uint256 u = m.unrealized();
        assertEq(u, 0.864 ether);
        uint256 got = m.redeem(500 ether); // half the supply, no realization
        assertEq(got, 500 ether);
        m.realize();
        uint256 rest = m.redeem(500 ether);
        assertEq(rest, 500 ether + u, "the shares that stayed took all of it");
    }

    // ------------------------------------------------------------------
    // Randomized schedules
    // ------------------------------------------------------------------

    /// @dev One random step. `withRealize` decides whether `realize` (and deposits, which realize) may be drawn.
    function _step(BondLedgerModel m, uint256 seed, bool withRealize) internal {
        uint256 kind = seed % 9;
        uint256 n = m.count();
        if (kind == 0 || (kind == 1 && n < 2)) {
            uint256 hrs = 1 + (seed >> 8) % (30 * 24);
            uint64 expiry = uint64((vm.getBlockTimestamp() / H + hrs) * H);
            uint128 amount = uint128(1 + (seed >> 24) % 1e24);
            uint256 rho = 1 + (seed >> 104) % 1e12;
            m.create((seed >> 160) % 2 == 0 ? payer : payer2, amount, expiry, rho);
        } else if (kind == 1 && n != 0) {
            uint256 id = (seed >> 8) % n;
            BondLedgerModel.Reservation memory j = m.get(id);
            if (j.closed || vm.getBlockTimestamp() >= j.expiry || j.vaultConsumed == j.amount) return;
            m.vaultConsume(id, uint128(1 + (seed >> 24) % (j.amount - j.vaultConsumed)));
        } else if (kind == 2 && n != 0) {
            uint256 id = (seed >> 8) % n;
            if (!m.get(id).settled) m.sync(id);
        } else if (kind == 3 && n != 0) {
            uint256 id = (seed >> 8) % n;
            BondLedgerModel.Reservation memory j = m.get(id);
            if (!j.closed && !j.settled) m.close(id);
        } else if (kind == 4 && n != 0) {
            uint256 id = (seed >> 8) % n;
            BondLedgerModel.Reservation memory j = m.get(id);
            if (!j.settled && (j.closed || vm.getBlockTimestamp() >= j.expiry)) m.settle(id);
        } else if (kind == 5) {
            if (withRealize) m.realize();
        } else if (kind == 6) {
            m.claimRefund((seed >> 8) % 2 == 0 ? payer : payer2);
            m.claimProtocol();
        } else {
            vm.warp(vm.getBlockTimestamp() + (seed >> 8) % (3 * DAY));
        }
    }

    function _checkLedger(BondLedgerModel m) internal view {
        assertEq(m.aggNow(), m.sumAccruedNow(), "aggregate == sum of per-reservation accruals");
        assertLe(m.realized(), m.settledCharges() + m.aggNow() / 1e18, "never realized beyond earned");
        // Exact identity of the escrow balance: escrow + realized = owed refunds + owed protocol fees + open bonds +
        // settled charges. Then the part of the escrow not yet owed to anyone, open bonds - (realized - settled
        // charges), is non-negative.
        assertEq(
            m.escrow() + m.realized(),
            m.refundsOwedTotal() + (m.protocolCredited() - m.protocolPaid()) + m.unsettledBonds() + m.settledCharges()
        );
        assertGe(m.unsettledBonds() + m.settledCharges(), m.realized(), "escrow covers every owed amount");
    }

    function _finish(BondLedgerModel m) internal {
        vm.warp(vm.getBlockTimestamp() + 31 * DAY);
        for (uint256 i; i < m.count(); ++i) {
            if (!m.get(i).settled) m.settle(i);
        }
        m.realize();
    }

    /// @notice After every step of a random schedule: the aggregate accrual equals the sum of the per-reservation
    ///         accruals exactly, nothing is realized before it is earned, and the escrow holds every owed refund and
    ///         protocol fee plus the unearned part of every open bond. At the end every bond is split exactly into
    ///         LP fees, protocol fees and refunds, and the escrow holds exactly what is still owed.
    function testFuzz_aggregateIsExactAndEscrowSolvent(uint256 seed) public {
        BondLedgerModel m = _model();
        for (uint256 i; i < 60; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            _step(m, seed, true);
            _checkLedger(m);
        }
        _finish(m);
        _checkLedger(m);
        uint256 charges;
        uint256 bonds;
        for (uint256 i; i < m.count(); ++i) {
            charges += m.get(i).charge;
            bonds += m.get(i).bond;
            assertLe(m.get(i).charge, m.get(i).bond, "charge never exceeds bond");
        }
        assertEq(m.realized(), charges);
        assertEq(m.lpMoved() + m.protocolCredited(), charges);
        assertEq(bonds, charges + m.refundsOwedTotal() + m.refundsPaid());
        assertEq(m.escrow(), m.refundsOwedTotal() + m.protocolCredited() - m.protocolPaid());
    }

    /// @notice Realization frequency changes nothing: the same schedule with `realize` drawn at random points and with
    ///         a single realization at the end gives the same charges, LP total, protocol total and refunds.
    function testFuzz_realizationFrequencyIsIrrelevant(uint256 seed) public {
        BondLedgerModel a = _model();
        BondLedgerModel b = _model();
        uint256 start = vm.getBlockTimestamp();
        for (uint256 i; i < 60; ++i) {
            uint256 s = uint256(keccak256(abi.encode(seed, i)));
            uint256 t = vm.getBlockTimestamp();
            _step(a, s, true);
            vm.warp(t);
            _step(b, s, false);
        }
        uint256 end = vm.getBlockTimestamp();
        _finish(a);
        vm.warp(end);
        _finish(b);
        assertGt(end, start, "time advanced");
        assertEq(a.lpMoved(), b.lpMoved());
        assertEq(a.protocolCredited(), b.protocolCredited());
        assertEq(a.refundsOwedTotal() + a.refundsPaid(), b.refundsOwedTotal() + b.refundsPaid());
        for (uint256 i; i < a.count(); ++i) {
            assertEq(a.get(i).charge, b.get(i).charge);
        }
    }

    /// @notice Non-vacuity of the randomized schedules: across 16 seeds, before the final settlement sweep, the steps
    ///         create reservations, consume in the vault, sync late, close early, settle, and realize a non-zero
    ///         amount, so the invariants above are checked on states that contain every kind of event.
    function test_schedulesExerciseEveryOperation() public {
        uint256 created;
        uint256 consumed;
        uint256 lagging;
        uint256 closed;
        uint256 settled;
        uint256 realizedMidway;
        for (uint256 seed; seed < 16; ++seed) {
            vm.warp(T0);
            BondLedgerModel m = _model();
            for (uint256 i; i < 60; ++i) {
                _step(m, uint256(keccak256(abi.encode(seed, i))), true);
                for (uint256 j; j < m.count(); ++j) {
                    BondLedgerModel.Reservation memory r = m.get(j);
                    if (r.vaultConsumed > r.synced) ++lagging;
                }
            }
            created += m.count();
            if (m.realized() != 0) ++realizedMidway;
            for (uint256 j; j < m.count(); ++j) {
                BondLedgerModel.Reservation memory r = m.get(j);
                if (r.vaultConsumed != 0) ++consumed;
                if (r.closed) ++closed;
                if (r.settled) ++settled;
            }
        }
        emit log_named_uint("reservations created", created);
        emit log_named_uint("with vault consumption", consumed);
        emit log_named_uint("reservation-steps with unsynced consumption", lagging);
        emit log_named_uint("closed early", closed);
        emit log_named_uint("settled before the final sweep", settled);
        emit log_named_uint("schedules with a non-zero realization before the sweep", realizedMidway);
        assertGt(consumed, 0);
        assertGt(lagging, 0);
        assertGt(closed, 0);
        assertGt(settled, 0);
        assertGt(realizedMidway, 0);
    }
}
