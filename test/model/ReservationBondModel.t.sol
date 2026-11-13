// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {ReservationBondModel} from "./ReservationBondModel.sol";

/// @notice Checks of the PROPOSED reservation-bond accounting (FUTURE_CAPITAL_AND_YIELD_ACCOUNTING.md §2) on its
///         test-only reference model. These tests say nothing about `src/`, which has no bonds or reservation fees.
contract ReservationBondModelTest is Test {
    uint256 internal constant DAY = 1 days;
    uint256 internal constant WAD = 1e18;
    /// @dev 1e-9 fee units per reserved unit per second: 0.0864 bps of the reserved amount per day, about 3.15% a
    ///      year when the fee asset and the sold asset have the same value.
    uint256 internal constant RATE = 1e9;

    address internal hook = makeAddr("hook");
    address internal hook2 = makeAddr("hook2");
    address internal keeper = makeAddr("keeper");

    /// @notice Example D: a hook reserves 100,000 tokens for 10 days, sells 30,000 on day 2, a keeper checkpoints on
    ///         day 5, and the hook releases the rest early on day 6.
    /// @dev Fee = rho * (100,000 * 2 d + 70,000 * 4 d) = 41.472 tokens of the 86.4 posted; 10% to the protocol.
    ///      Every number is exact, so the doc can quote them.
    function test_exampleD_partialUseAndEarlyRelease() public {
        ReservationBondModel m = new ReservationBondModel(1_000_000 ether, 1000, 1 days);
        uint256 id = m.create(hook, 100_000 ether, uint64(10 * DAY), RATE, 0);
        assertEq(m.get(id).bond, 86.4 ether, "bond = 100,000 * 864,000 s * 1e-9");
        assertEq(m.reserved(), 100_000 ether);
        assertEq(m.admissible(), 900_000 ether, "the bond adds nothing to admissible capacity");

        m.consume(id, 30_000 ether, uint64(2 * DAY));
        assertEq(m.netSold(), 970_000 ether);
        assertEq(m.reserved(), 70_000 ether);

        m.checkpoint(id, uint64(5 * DAY)); // 100,000 * 2 d + 70,000 * 3 d = 410,000 token-days
        assertEq(m.get(id).realized, 35.424 ether);
        assertEq(m.lpFees(), 31.8816 ether);
        assertEq(m.protocolFees(), 3.5424 ether);

        vm.expectRevert(ReservationBondModel.NotPayer.selector);
        m.release(id, keeper, uint64(6 * DAY));
        m.release(id, hook, uint64(6 * DAY));
        assertEq(m.reserved(), 0);
        m.settle(id, uint64(6 * DAY));
        assertEq(m.get(id).realized, 41.472 ether, "100,000 * 2 d + 70,000 * 4 d = 480,000 token-days");
        assertEq(m.lpFees(), 37.3248 ether);
        assertEq(m.protocolFees(), 4.1472 ether);
        assertEq(m.refundOwed(hook), 44.928 ether);
        assertEq(m.lpFees() + m.escrow(), m.bondsPosted(), "nothing created or lost");

        vm.expectRevert(ReservationBondModel.AlreadySettled.selector);
        m.settle(id, uint64(7 * DAY));
        vm.expectRevert(ReservationBondModel.AlreadySettled.selector);
        m.checkpoint(id, uint64(7 * DAY));
    }

    /// @notice A reservation released one second after creation still pays the minimum charge, so reserving all
    ///         capacity briefly to push LPs into the queue or to block other curators is not free.
    function test_minimumCharge_onImmediateRelease() public {
        ReservationBondModel m = new ReservationBondModel(1_000_000 ether, 0, 1 days);
        uint256 id = m.create(hook, 1_000_000 ether, uint64(30 * DAY), RATE, 0);
        m.release(id, hook, 1);
        m.settle(id, 1);
        assertEq(m.get(id).realized, FullMath.mulDivRoundingUp(1_000_000 ether * DAY, RATE, WAD)); // 86.4 tokens
    }

    /// @notice After expiry anyone may settle, the charge stops at the expiry however late settlement comes, and
    ///         the refund goes to the payer, not to the caller.
    function test_permissionlessSettlementAfterExpiry_stopsAtExpiry() public {
        ReservationBondModel m = new ReservationBondModel(1_000_000 ether, 1000, 0);
        uint256 id = m.create(hook, 10_000 ether, uint64(3 * DAY), RATE, 0);
        vm.expectRevert(ReservationBondModel.NotExpired.selector);
        m.settle(id, uint64(3 * DAY - 1));
        m.settle(id, uint64(40 * DAY)); // 37 days late
        assertEq(m.get(id).realized, m.get(id).bond, "unused for its whole life: the full bond, not more");
        assertEq(m.refundOwed(hook), 0);
        assertEq(m.refundOwed(keeper), 0);
        assertEq(m.reserved(), 0);
    }

    /// @notice A bond is not backing. However large the escrow, a second hook cannot reserve more than N_a - Q_a, and
    ///         the first hook's bond cannot cover the second hook's reservation.
    function test_bondIsNeverBacking() public {
        ReservationBondModel m = new ReservationBondModel(100_000 ether, 0, 0);
        m.create(hook, 60_000 ether, uint64(30 * DAY), 1e15, 0); // bond 155,520,000 tokens, far above N_a
        assertGt(m.escrow(), m.netSold());
        assertEq(m.admissible(), 40_000 ether);
        vm.expectRevert(
            abi.encodeWithSelector(ReservationBondModel.InsufficientBacking.selector, 40_001 ether, 40_000 ether)
        );
        m.create(hook2, 40_001 ether, uint64(DAY), RATE, 0);
        m.create(hook2, 40_000 ether, uint64(DAY), RATE, 0);
        assertEq(m.reserved(), m.netSold());
    }

    /// @notice Fee attribution. A depositor who enters after fees accrued but before they are moved into the vault
    ///         takes a share of them, unless the vault checkpoints every reservation before the share supply changes.
    /// @dev 1,000 shares own 1,000,000 units of the fee asset. A reservation of 100,000 earns 86.4 units over 10 days.
    ///      A new LP buys 1,000 shares on day 10 and redeems after settlement. Without a checkpoint it gains 43.2
    ///      units, half of what the old LPs earned; with one it gains nothing and the old LPs keep all 86.4.
    function test_feeAttribution_requiresCheckpointBeforeSupplyChange() public {
        for (uint256 withCheckpoint; withCheckpoint < 2; ++withCheckpoint) {
            ReservationBondModel m = new ReservationBondModel(1_000_000 ether, 0, 0);
            m.seedShares(1000 ether, 1_000_000 ether);
            uint256 id = m.create(hook, 100_000 ether, uint64(20 * DAY), RATE, 0);
            if (withCheckpoint == 1) m.checkpoint(id, uint64(10 * DAY));
            uint256 paid = m.deposit(1000 ether);
            m.release(id, hook, uint64(10 * DAY));
            m.settle(id, uint64(10 * DAY));
            uint256 got = m.redeem(1000 ether);
            if (withCheckpoint == 0) {
                assertEq(got - paid, 43.2 ether, "JIT depositor takes half the fees earned before it entered");
                assertEq(m.lpNet(), 1_000_043.2 ether);
            } else {
                assertEq(got, paid, "nothing earned before entry reaches the new LP");
                assertEq(m.lpNet(), 1_000_086.4 ether, "old LPs keep all 86.4");
            }
        }
    }

    // ------------------------------------------------------------------
    // Properties over random schedules
    // ------------------------------------------------------------------

    struct Op {
        uint8 kind; // 0 consume, 1 checkpoint, 2 release by payer, 3 settle
        uint8 which;
        uint32 dt;
        uint128 x;
    }

    /// @dev Runs one schedule on `m`. With `checkpoints` false every checkpoint is skipped, so two runs differ only
    ///      in how often fees were moved.
    function _run(ReservationBondModel m, uint256 seed, bool checkpoints) internal returns (uint256[4] memory done) {
        uint64 t;
        for (uint256 i; i < 3; ++i) {
            uint256 h = uint256(keccak256(abi.encode(seed, "create", i)));
            uint128 amount = uint128(1 + h % 200_000 ether);
            uint64 dur = uint64(1 + (h >> 128) % (30 * DAY));
            uint256 rate = 1 + (h >> 64) % 1e12;
            m.create(i == 0 ? hook : hook2, amount, t + dur, rate, t);
        }
        for (uint256 i; i < 24; ++i) {
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            t += uint64(h % (3 * DAY));
            uint256 id = (h >> 32) % 3;
            ReservationBondModel.Reservation memory r = m.get(id);
            uint256 kind = (h >> 64) % 4;
            if (r.settled) continue;
            if (kind == 0 && !r.closed && t < r.expiry && r.remaining != 0) {
                m.consume(id, uint128(1 + (h >> 96) % r.remaining), t);
                ++done[0];
            } else if (kind == 1 && checkpoints) {
                m.checkpoint(id, t);
                ++done[1];
            } else if (kind == 2 && !r.closed) {
                m.release(id, r.payer, t);
                ++done[2];
            } else if (kind == 3 && (r.closed || t >= r.expiry)) {
                m.settle(id, t);
                ++done[3];
            }
            _checkLedgers(m);
        }
        // Settle whatever is left, after every expiry.
        t += uint64(31 * DAY);
        for (uint256 id; id < 3; ++id) {
            if (!m.get(id).settled) m.settle(id, t);
        }
        _checkLedgers(m);
    }

    function _checkLedgers(ReservationBondModel m) internal view {
        uint256 q;
        uint256 unearned;
        for (uint256 id; id < m.count(); ++id) {
            ReservationBondModel.Reservation memory r = m.get(id);
            q += r.remaining;
            assertLe(r.realized, r.bond, "charged more than the bond");
            assertLe(r.protocolRealized, r.realized);
            if (!r.settled) unearned += r.bond - r.realized;
        }
        assertEq(m.reserved(), q, "Q != sum of remaining");
        assertLe(m.reserved(), m.netSold(), "Q > N");
        // The escrow holds exactly: unearned bonds, unclaimed protocol fees and unclaimed refunds.
        assertEq(m.escrow(), unearned + m.protocolFees() + m.refundOwed(hook) + m.refundOwed(hook2));
        assertEq(m.lpFees() + m.escrow(), m.bondsPosted(), "bond conservation");
    }

    /// @notice Conservation over random schedules: bonds posted = fees moved to LPs + escrow; Q_a = sum of remaining
    ///         capacity; no reservation is charged more than its bond; each settled reservation is charged exactly
    ///         ceil(max(I, I_min) * rho / WAD).
    function testFuzz_conservationAndExactCharge(uint256 seed) public {
        ReservationBondModel m = new ReservationBondModel(1_000_000 ether, 1500, 1 hours);
        _run(m, seed, true);
        for (uint256 id; id < 3; ++id) {
            ReservationBondModel.Reservation memory r = m.get(id);
            uint256 billable = r.unitSeconds > r.minUnitSeconds ? r.unitSeconds : r.minUnitSeconds;
            assertEq(r.realized, FullMath.mulDivRoundingUp(billable, r.rateWad, WAD));
            assertEq(r.protocolRealized, r.realized * 1500 / 10_000);
        }
    }

    /// @notice Non-vacuity of the two fuzz tests above: over 32 schedules, every operation kind is executed many
    ///         times inside the schedule (not only in the final settlement sweep).
    function test_schedulesExerciseEveryOperation() public {
        uint256[4] memory total;
        for (uint256 seed; seed < 32; ++seed) {
            uint256[4] memory done = _run(new ReservationBondModel(1_000_000 ether, 1500, 1 hours), seed, true);
            for (uint256 k; k < 4; ++k) {
                total[k] += done[k];
            }
        }
        emit log_named_uint("consume", total[0]);
        emit log_named_uint("checkpoint", total[1]);
        emit log_named_uint("early or expiry release", total[2]);
        emit log_named_uint("settle", total[3]);
        for (uint256 k; k < 4; ++k) {
            assertGe(total[k], 32, "an operation kind is rarely reached");
        }
    }

    /// @notice Checkpoint frequency changes nothing: with or without intermediate checkpoints, every reservation is
    ///         charged the same, and LPs and the protocol receive the same totals to the unit.
    function testFuzz_checkpointsArePathIndependent(uint256 seed) public {
        ReservationBondModel a = new ReservationBondModel(1_000_000 ether, 1500, 1 hours);
        ReservationBondModel b = new ReservationBondModel(1_000_000 ether, 1500, 1 hours);
        _run(a, seed, true);
        _run(b, seed, false);
        assertEq(a.lpFees(), b.lpFees());
        assertEq(a.protocolFees(), b.protocolFees());
        assertEq(a.refundOwed(hook), b.refundOwed(hook));
        assertEq(a.refundOwed(hook2), b.refundOwed(hook2));
    }
}
