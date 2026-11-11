"""Vault risk boundary (Phase 1B-4.2): the capital-at-risk guarantee under arbitrary price corruption.

Run from the repository root:  python3 -m unittest discover -s simulations/mm -v

The central claim (`docs/architecture/ORACLE_RISK_BOUNDARY_SPEC.md` §3): with the inventory floor enforced by the
vault, the value LPs can lose through trading is at most sum_a (N_a - L_a) * p_a at the true prices, whatever the
reference says, whatever the hooks quote, and in whatever order trades arrive. These tests try to break it with an
adversary who controls the reference completely (a malicious or mistaken adapter, or every feed corrupted together).
Python model only; test/risk/ checks the Solidity equations.
"""

from __future__ import annotations

import os
import random
import sys
import unittest
from fractions import Fraction

sys.path.insert(0, os.path.dirname(__file__))

from model import (  # noqa: E402
    PIPS,
    Q96,
    WAD,
    Reference,
    Revert,
    dynamic_floors,
    floor_ok,
    inventory_floor,
    mul_div_up,
    vault_fill_check,
)

E18 = 10**18


class CapitalAtRisk(unittest.TestCase):
    def _attack(self, rng, steps, kappa, flip_every):
        """An adversary owns the reference (any price, any uncertainty it likes, here zero) and trades as greedily as
        the vault lets it: each step it asks for as much output as the floors allow, at the floor price the corrupted
        reference implies, alternating which asset it claims is worthless. The true price is fixed at 1:1."""
        n0 = n1 = s = 10**6 * E18
        tau = WAD
        l0 = inventory_floor(s, tau, kappa)
        l1 = inventory_floor(s, tau, kappa)
        true_value0 = Fraction(n0 + n1)
        for k in range(steps):
            cheap1 = (k // flip_every) % 2 == 0  # the reference says asset1 is (almost) worthless
            p = Q96 * rng.choice([10, 100, 10_000]) if cheap1 else Q96 // rng.choice([10, 100, 10_000])
            ref = Reference(p, 0)
            zfo = cheap1  # buy the asset the reference undervalues
            holding = n1 if zfo else n0
            want = rng.randint(1, 300_000) * E18
            out = min(want, holding)
            f0, f1 = dynamic_floors(p, 0, 0)
            amt_in = mul_div_up(out, f1 if zfo else f0, Q96)  # pay exactly the floor
            try:
                vault_fill_check(zfo, amt_in, out, ref, 0, PIPS, n0, n1, s, tau, tau, kappa, kappa)
            except Revert:
                continue
            if zfo:
                n0, n1 = n0 + amt_in, n1 - out
            else:
                n0, n1 = n0 - out, n1 + amt_in
            # The guarantee, after every fill: neither holding below its floor (both started above it).
            self.assertGreaterEqual(n0, l0)
            self.assertGreaterEqual(n1, l1)
        loss = true_value0 - (n0 + n1)
        bound = Fraction((10**6 * E18 - l0) + (10**6 * E18 - l1))
        return loss, bound

    def test_malicious_reference_loss_is_bounded(self):
        rng = random.Random(201)
        for kappa in (50_000, 150_000, 300_000):
            for flip in (1, 3, 50):
                loss, bound = self._attack(rng, 400, kappa, flip)
                self.assertLessEqual(loss, bound)
                # And the adversary does get close to it: the bound is not loose by orders of magnitude.
                self.assertGreater(loss, bound / 3)

    def test_inflows_are_never_limited_and_lp_flows_scale_the_floor(self):
        """A vault already below its floor (after a parameter change) still accepts inward trades; proportional LP
        flows scale L_a with S."""
        s = 10**6 * E18
        l = inventory_floor(s, WAD, 150_000)
        self.assertEqual(inventory_floor(2 * s, WAD, 150_000), 2 * l)
        ref = Reference(Q96, 0)
        # Holding 700k asset1 (floor 850k): buying more asset1 from the vault is refused, selling it to the vault is not.
        with self.assertRaises(Revert) as e:
            vault_fill_check(True, 2_000 * E18, 1_000 * E18, ref, 0, PIPS, s, 700_000 * E18, s, WAD, WAD, 150_000,
                             150_000)
        self.assertEqual(e.exception.name, "InventoryFloorBreached")
        vault_fill_check(False, 1_000 * E18, 900 * E18, ref, 0, PIPS, s, 700_000 * E18, s, WAD, WAD, 150_000, 150_000)


class DynamicFloors(unittest.TestCase):
    def test_floors_are_d14_consistent_at_every_reference(self):
        rng = random.Random(202)
        for _ in range(5_000):
            p = rng.randint(2**40, 2**159)
            u, e = rng.randint(0, 50_000), rng.randint(0, 1_000)
            f0, f1 = dynamic_floors(p, u, e)
            self.assertGreaterEqual(f0 * f1 * PIPS * PIPS, Q96 * Q96 * (PIPS + u + e) ** 2)

    def test_floors_refuse_every_price_inside_the_band(self):
        """A fill at any price inside P (1 +- (u + e)) is refused; at the band edge (rounded toward the vault) it
        passes."""
        rng = random.Random(203)
        for _ in range(2_000):
            p = rng.randint(2**90, 2**100)
            u = rng.randint(1, 20_000)
            out = rng.randint(10**15, 10**24)
            f0, f1 = dynamic_floors(p, u, 0)
            # Selling asset0 at exactly the mid (1 raw asset0 for P / 2^96 raw asset1): inside the band, refused.
            at_mid = out * p // Q96
            self.assertFalse(floor_ok(at_mid, out, f0))
            self.assertTrue(floor_ok(mul_div_up(out, f0, Q96), out, f0))
            at_mid1 = out * Q96 // p
            self.assertFalse(floor_ok(at_mid1, out, f1))

    def test_uncertainty_breaker(self):
        with self.assertRaises(Revert) as e:
            vault_fill_check(True, 2 * E18, E18, Reference(Q96, 8_201), 0, 8_200, E18, E18, E18, WAD, WAD, 0, 0)
        self.assertEqual(e.exception.name, "UncertaintyTooHigh")


if __name__ == "__main__":
    unittest.main()
