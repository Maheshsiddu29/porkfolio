"""Regression tests for the inventory-floor guarantee model (`floor_guarantee.py`).

These pin what the stateful search established: T1 and T2 hold under an adversary that controls every trade price and
mixes deposits, redemptions, queueing, cancellation, claims, commitments and honest refills; the stronger claim T3
("loss at most kappa of value") does not hold, and each counterexample is reproduced exactly.
"""

import unittest

import floor_guarantee as fg


class FloorGuaranteeTest(unittest.TestCase):
    def test_t1_t2_hold_under_random_adversary(self):
        for seed in range(40):
            v = fg.random_run(seed, steps=300)
            _, _, breaches = v.t2_report(fg.PRICES)
            self.assertEqual(v.violations, [], seed)
            self.assertEqual(breaches, 0, seed)
            # rounding against an LP never exceeds one raw unit per asset per payout
            self.assertLessEqual(v.worst_deficit, 2.0, seed)

    def test_hill_climb_cannot_exceed_bound(self):
        # Each candidate sequence asserts T1 and T2 inside `play`; the ratio is shortfall / bound for bounds that are
        # well above rounding, so anything materially above 1 would be a counterexample.
        for seed in range(3):
            self.assertLessEqual(fg.hill_climb(seed, iters=60), 1.0 + 1e-6)

    def test_flash_deposit_does_not_enlarge_existing_lps_loss(self):
        # A deposit in the same transaction as a drain raises S and the floor together (pro-rata basket, rounded up),
        # so the existing LP's per-share holding still ends at or above the floor.
        v = fg.fresh()
        h0 = v.h(0)
        v.deposit(9, v.S * 5)
        v.exchange(0, v.max_out(0), 0)
        v.redeem(9, v.shares_of(9))
        self.assertGreaterEqual(v.h(0), min(h0, v.ell(0)))
        self.assertEqual(v.violations, [])

    def test_counterexamples_to_stronger_claims(self):
        self.assertGreater(fg.ce_fee_accrual(), 0.05)
        self.assertGreater(fg.ce_skewed_composition(), 0.05)
        self.assertEqual(fg.ce_loosen_bounds_immediately(), 1.0)
        self.assertEqual(fg.ce_static_mode_without_floor(), 0.5)
        self.assertIn("finalized at 0 asset0", fg.ce_queued_lp_cannot_escape())


if __name__ == "__main__":
    unittest.main()
