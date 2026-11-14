"""Shared economic core: two strategies (Hook A, Hook B) on one reserve (integer model).

Run from the repository root:  python3 -m unittest discover -s simulations/mm -v

These tests check the claims of `docs/architecture/SHARED_ECONOMIC_CORE_SPEC.md` §6 on the Python model only. They are
not evidence about the Solidity; `test/pricing/` checks the Solidity against the same vectors.
"""

from __future__ import annotations

import os
import random
import sys
import unittest
from fractions import Fraction

sys.path.insert(0, os.path.dirname(__file__))

from model import (  # noqa: E402
    MAX_AMOUNT,
    PIPS,
    Q96,
    WAD,
    ActivityFeeConfig,
    BracketSource,
    InventoryConfig,
    Reference,
    Revert,
    SequencerStatus,
    VaultSnapshot,
    bracket_reference,
    core_state,
    decayed,
    depth_per_share_for,
    hook_a_quote,
    hook_b_quote,
    mid_and_uncertainty,
    mul_div_up,
)

E18 = 10**18
FEE_A = ActivityFeeConfig(base=0, mx=3_000, scale0=50_000 * E18, scale1=50_000 * E18, window=3_600)


def cfg(base=1_000, dev=150_000, min_edge=100, tau=WAD, max_spread=60_000, band=False):
    return InventoryConfig(tau, depth_per_share_for(tau, dev, base, min_edge), 2**95 - 1, base, min_edge,
                           max_spread, dev, band)


class Reserve:
    """One vault reserve with two hooks: A keeps its activity levels (strategy state, not inventory), B none.
    Every quote reads the same N_0, N_1, S; every fill applies exactly the amounts `exchange` would move."""

    def __init__(self, n0, n1, s, c=None, fee_a=FEE_A, markup_b=0, impact_b=PIPS - 1):
        self.n0, self.n1, self.s = n0, n1, s
        self.c = c or cfg()
        self.fee_a, self.markup_b, self.impact_b = fee_a, markup_b, impact_b
        self.level = {True: 0, False: 0}
        self.updated = {True: 0, False: 0}

    def snap(self):
        return VaultSnapshot(self.n0, self.n1, self.s)

    def level_now(self, zfo, now):
        k = self.fee_a.scale0 if zfo else self.fee_a.scale1
        return decayed(self.level[zfo], k, self.fee_a.window, now - self.updated[zfo])

    def quote(self, hook, ref, zfo, amt, now=0):
        cs = core_state(self.c, self.snap(), ref)
        if hook == "A":
            return hook_a_quote(cs, self.fee_a, self.level_now(zfo, now), zfo, amt)
        return hook_b_quote(cs, self.markup_b, self.impact_b, zfo, amt)

    def swap(self, hook, ref, zfo, amt, now=0):
        q = self.quote(hook, ref, zfo, amt, now)
        if hook == "A":
            self.level[zfo], self.updated[zfo] = q.new_level, now
        if zfo:
            self.n0, self.n1 = self.n0 + amt, self.n1 - q.amount_out
        else:
            self.n0, self.n1 = self.n0 - q.amount_out, self.n1 + amt
        return q.amount_out

    def deposit(self, frac_num, frac_den):
        """Proportional LP deposit or redemption: N_a and S scale by (1 + num/den), rounded as the vault rounds
        (deposits up, shares named exactly)."""
        ds = self.s * frac_num // frac_den
        self.n0 += -(-ds * self.n0 // self.s) if ds > 0 else ds * self.n0 // self.s
        self.n1 += -(-ds * self.n1 // self.s) if ds > 0 else ds * self.n1 // self.s
        self.s += ds


def rand_reserve(rng, **kw):
    base = rng.randint(10**4, 10**7) * E18
    dev = rng.uniform(-0.2, 0.2)
    return Reserve(int(base * (1 + dev)), int(base * (1 - dev)), base, **kw)


def rand_ref(rng):
    return Reference(int(rng.uniform(0.2, 5.0) * Q96), rng.randint(0, 3_000))


def straddles(zfo, amt, out, ref, h_min):
    """The P-3 bound in exact integers: the vault sells currency1 at >= M(1 + h_min) and buys it at <= M(1 - h_min)."""
    if zfo:
        return amt * ref.price_x96 * PIPS >= out * Q96 * (PIPS + h_min)
    return out * ref.price_x96 * PIPS <= amt * Q96 * (PIPS - h_min)


class BothStrategiesStraddle(unittest.TestCase):
    """Every fill from either strategy, from any state the other strategy left, respects the shared straddle bound.
    This is the property that makes cross-hook cycles lose and keeps floors pivoted at the reference satisfied."""

    def test_interleaved_hooks_alternating_directions(self):
        rng = random.Random(101)
        fills = 0
        for _ in range(200):
            r = rand_reserve(rng, markup_b=rng.choice([0, 500, 2_000]), fee_a=ActivityFeeConfig(
                rng.choice([0, 300]), rng.choice([1_000, 5_000]), 20_000 * E18, 20_000 * E18, 3_600))
            ref = rand_ref(rng)
            for step in range(30):
                hook, zfo = rng.choice("AB"), rng.random() < 0.5
                amt = rng.choice([rng.randint(1, 10**6), rng.randint(1, 30_000) * E18])
                try:
                    out = r.swap(hook, ref, zfo, amt, now=step * 7)
                except Revert:
                    continue
                fills += 1
                self.assertTrue(straddles(zfo, amt, out, ref, r.c.min_edge), (hook, zfo, amt, out))
        self.assertGreater(fills, 2_000)

    def test_band_mode_straddles_the_whole_band(self):
        """Production mode: every fill of either strategy is min_edge beyond M (1 +- u), not only beyond M, so a vault
        that refuses any price inside the band accepts every hook quote."""
        rng = random.Random(109)
        fills = 0
        for _ in range(200):
            r = rand_reserve(rng)
            r.c = cfg(base=rng.choice([500, 1_000, 3_000]), band=True)
            ref = Reference(int(rng.uniform(0.2, 5.0) * Q96), rng.randint(0, 9_000))
            for step in range(20):
                hook, zfo = rng.choice("AB"), rng.random() < 0.5
                amt = rng.randint(1, 30_000) * E18
                try:
                    out = r.swap(hook, ref, zfo, amt, now=step)
                except Revert:
                    continue
                fills += 1
                self.assertTrue(straddles(zfo, amt, out, ref, r.c.min_edge + ref.uncertainty))
        self.assertGreater(fills, 1_000)

    def test_shared_cap_binds_every_strategy(self):
        """Pushing inventory outward through A, then B, then A: the vault's deviation never passes the cap that both
        compute from the same vault state, and inward trades through either hook are still priced."""
        rng = random.Random(102)
        for _ in range(100):
            r = rand_reserve(rng)
            ref = Reference(Q96, rng.randint(0, 2_000))
            start_i = core_state(r.c, r.snap(), ref).i
            for k in range(200):
                hook = "AB"[k % 2]
                try:
                    r.swap(hook, ref, True, rng.randint(1, 50_000) * E18)
                except Revert as e:
                    self.assertIn(e.name, ("InventoryLimit", "ZeroOutput"))
            cs = core_state(r.c, r.snap(), ref)
            # A vault that started beyond the cap may only have moved inward; otherwise it stays within the cap.
            self.assertLessEqual(cs.i, max(cs.cap, start_i))
            for hook in "AB":
                with self.assertRaises(Revert):
                    r.quote(hook, ref, True, max(cs.cap - cs.i, 0) + 10**21)
                r.quote(hook, ref, False, 1_000 * E18)  # inward is priced: no exception


class Cycles(unittest.TestCase):
    def _close(self, r, ref, start1, hook):
        gap = r.n1 - start1
        if gap > 0:  # trader buys the extra currency1 back (search for the exact-output equivalent)
            lo, hi = 1, 10**31
            while lo < hi:
                mid = (lo + hi) // 2
                if r.quote(hook, ref, True, mid).amount_out >= gap:
                    hi = mid
                else:
                    lo = mid + 1
            before = r.n0
            r.swap(hook, ref, True, lo)
            return before - r.n0
        if gap < 0:
            before = r.n0
            r.swap(hook, ref, False, -gap)
            return before - r.n0
        return 0

    def test_fixed_reference_cycles_across_hooks_and_parameter_changes_lose(self):
        """Random sequences through both hooks, with spread, markup, fee curve, cap, target and an LP deposit changing
        between legs, closed in currency1 through either hook: the trader never ends with more currency0."""
        rng = random.Random(103)
        done = 0
        for _ in range(250):
            ref = rand_ref(rng)
            r = rand_reserve(rng)
            start1, start0, start_s = r.n1, r.n0, r.s
            trader0 = 0
            for step in range(rng.randint(2, 10)):
                r.c = cfg(base=rng.choice([300, 1_000, 3_000]), dev=rng.choice([50_000, 150_000]),
                          tau=rng.choice([WAD, WAD * 95 // 100, WAD * 105 // 100]))
                r.markup_b = rng.choice([0, 1_000])
                hook, zfo = rng.choice("AB"), rng.random() < 0.5
                try:
                    before = r.n0
                    r.swap(hook, ref, zfo, rng.randint(1, 20_000) * E18, now=step)
                    trader0 += before - r.n0
                except Revert:
                    pass
            r.c = cfg()
            try:
                trader0 += self._close(r, ref, start1, rng.choice("AB"))
            except Revert:
                continue
            self.assertLessEqual(r.n1, start1)  # the loop is closed: the vault holds no more currency1 than before
            self.assertLessEqual(trader0, 0)
            done += 1
        self.assertGreater(done, 100)

    def test_cycle_across_reference_update_is_bounded_by_the_move(self):
        """Not path-independent across a new reference round: buy at M_1, sell at M_2. The trader's profit is at most
        the volume times (M_1 / M_2 - 1 - 2 h_min) in the favourable direction, and negative for moves under 2 h_min:
        latency arbitrage against the reference, priced by the spread, not a mechanical cycle."""
        rng = random.Random(104)
        for _ in range(300):
            r = rand_reserve(rng)
            p1 = int(rng.uniform(0.5, 2) * Q96)
            move = rng.uniform(-0.03, 0.03)
            ref1, ref2 = Reference(p1, 0), Reference(int(p1 * (1 + move)), 0)
            amt = rng.randint(100, 20_000) * E18
            try:
                got1 = r.swap(rng.choice("AB"), ref1, True, amt)  # pays amt currency0 for got1 currency1
                back0 = r.swap(rng.choice("AB"), ref2, False, got1)
            except Revert:
                continue
            profit = Fraction(back0 - amt, amt)
            bound = Fraction(p1, ref2.price_x96) - 1 - Fraction(2 * r.c.min_edge, PIPS)
            self.assertLessEqual(profit, max(bound, Fraction(0)) + Fraction(1, 10**12))
            if abs(move) < 2 * r.c.min_edge / PIPS:
                self.assertLess(back0, amt)


class Splitting(unittest.TestCase):
    def test_same_hook_split_never_gains(self):
        rng = random.Random(105)
        n_ok = 0
        for _ in range(300):
            r0 = rand_reserve(rng)
            ref = rand_ref(rng)
            hook, zfo = rng.choice("AB"), rng.random() < 0.5
            total = rng.randint(2, 40_000) * E18
            n = rng.randint(2, 20)
            parts = [total // n] * n
            parts[-1] += total - sum(parts)
            a = Reserve(r0.n0, r0.n1, r0.s)
            b = Reserve(r0.n0, r0.n1, r0.s)
            try:
                single = a.swap(hook, ref, zfo, total)
                got = sum(b.swap(hook, ref, zfo, p) for p in parts)
            except Revert:
                continue
            n_ok += 1
            self.assertLessEqual(got, single)
        self.assertGreater(n_ok, 200)

    def test_cross_hook_split_pays_the_core_charge_in_full(self):
        """Splitting across hooks cannot avoid the inventory charge: the output of any split across A and B is at most
        what the same pieces would get on a markup-free core (the core telescopes on the shared inventory; each
        strategy only removes value)."""
        rng = random.Random(106)
        for _ in range(300):
            r0 = rand_reserve(rng, markup_b=rng.choice([0, 1_000]))
            ref = rand_ref(rng)
            zfo = rng.random() < 0.5
            parts = [rng.randint(1, 10_000) * E18 for _ in range(rng.randint(2, 8))]
            mixed = Reserve(r0.n0, r0.n1, r0.s, markup_b=r0.markup_b)
            core_only = Reserve(r0.n0, r0.n1, r0.s, fee_a=ActivityFeeConfig(0, 0, E18, E18, 0), markup_b=0)
            try:
                got = sum(mixed.swap(rng.choice("AB"), ref, zfo, p) for p in parts)
                bound = core_only.swap("B", ref, zfo, sum(parts))
            except Revert:
                continue
            self.assertLessEqual(got, bound)

    def test_counterexample_split_across_hooks_can_beat_the_best_single_hook(self):
        """Not every desirable property holds. When Hook A's activity fee starts below Hook B's markup and rises above
        it, routing the first part through A and the rest through B beats either hook alone. That is a better route
        between two venues, not a bypass: the core charge is paid in full (previous test) and each hook's own fee
        telescopes on its own state."""
        r0 = Reserve(10**6 * E18, 10**6 * E18, 10**6 * E18, markup_b=1_500,
                     fee_a=ActivityFeeConfig(0, 5_000, 20_000 * E18, 20_000 * E18, 3_600))
        ref = Reference(Q96, 0)
        total = 40_000 * E18
        only_a = Reserve(r0.n0, r0.n1, r0.s, fee_a=r0.fee_a, markup_b=r0.markup_b).swap("A", ref, True, total)
        only_b = Reserve(r0.n0, r0.n1, r0.s, fee_a=r0.fee_a, markup_b=r0.markup_b).swap("B", ref, True, total)
        mix = Reserve(r0.n0, r0.n1, r0.s, fee_a=r0.fee_a, markup_b=r0.markup_b)
        # A's marginal fee reaches B's 15 bp markup at level 6,000 (5,000 pips x 6,000 / 20,000).
        routed = mix.swap("A", ref, True, 6_000 * E18) + mix.swap("B", ref, True, total - 6_000 * E18)
        self.assertGreater(routed, max(only_a, only_b))


class TimeAndLiquidity(unittest.TestCase):
    def test_waiting_lowers_only_the_activity_fee(self):
        """Hook A's fee decays with time (intended, as in production); the core charge does not: with the activity
        fee disabled, the same trade after an hour gets exactly the same output."""
        r = Reserve(10**6 * E18, 10**6 * E18, 10**6 * E18)
        ref = Reference(Q96, 0)
        r.swap("A", ref, True, 40_000 * E18, now=0)
        hot = r.quote("A", ref, True, 10_000 * E18, now=1).amount_out
        cool = r.quote("A", ref, True, 10_000 * E18, now=7_200).amount_out
        self.assertGreater(cool, hot)
        self.assertEqual(r.quote("B", ref, True, 10_000 * E18, now=1).amount_out,
                         r.quote("B", ref, True, 10_000 * E18, now=7_200).amount_out)

    def test_lp_flows_between_trades_keep_the_bound(self):
        rng = random.Random(107)
        for _ in range(200):
            r = rand_reserve(rng)
            ref = rand_ref(rng)
            for _step in range(10):
                if rng.random() < 0.3:
                    r.deposit(rng.choice([1, -1]) * rng.randint(1, 30), 100)
                hook, zfo = rng.choice("AB"), rng.random() < 0.5
                amt = rng.randint(1, 20_000) * E18
                try:
                    out = r.swap(hook, ref, zfo, amt)
                except Revert:
                    continue
                self.assertTrue(straddles(zfo, amt, out, ref, r.c.min_edge))

    def test_dust_and_maximum_through_both_hooks(self):
        r, ref = Reserve(10**6 * E18, 10**6 * E18, 10**6 * E18), Reference(Q96, 0)
        for hook in "AB":
            for zfo in (True, False):
                for amt, name in ((0, "ZeroInput"), (MAX_AMOUNT + 1, "AmountTooLarge"), (1, "ZeroOutput")):
                    with self.assertRaises(Revert) as e:
                        r.quote(hook, ref, zfo, amt)
                    self.assertEqual(e.exception.name, name)

    def test_hook_b_trade_impact_bound(self):
        """Per-trade bound of 12 bps on a balanced vault (core half-spread 10 bps): 50,000 averages 11.5 bps worse than
        the mid and passes; 100,000 averages 13.0 bps and is refused, although the inventory cap (150,000) allows it."""
        r = Reserve(10**6 * E18, 10**6 * E18, 10**6 * E18, impact_b=1_200)
        ref = Reference(Q96, 0)
        r.quote("B", ref, True, 50_000 * E18)
        with self.assertRaises(Revert) as e:
            r.quote("B", ref, True, 100_000 * E18)
        self.assertEqual(e.exception.name, "TradeImpactExceeded")


class BracketReference(unittest.TestCase):
    def test_observed_unichain_example(self):
        """Chainlink 2,048.39 and RedStone 2,050.31 (ETH/USD, Unichain, 2026-11-10), both 50 bps triggers."""
        src = [BracketSource(int(2048.39 * Q96), 100, 5_000, 90_000), BracketSource(int(2050.31 * Q96), 100, 5_000,
                                                                                         90_000)]
        r = bracket_reference(src, 200)
        self.assertEqual(r.uncertainty, 4_553)  # 4,532 before G04 F-1 (lower term measured from the mid)
        self.assertAlmostEqual(r.price_x96 / Q96, 2049.345, places=2)

    def test_refusals(self):
        a = BracketSource(Q96, 100, 5_000, 1_000)
        b = BracketSource(Q96 * 1011 // 1000, 100, 5_000, 1_000)
        with self.assertRaises(Revert) as e:
            bracket_reference([a, b], 200)
        self.assertEqual(e.exception.name, "ReferenceDivergence")
        with self.assertRaises(Revert) as e:
            bracket_reference([a, a], 2_000)
        self.assertEqual(e.exception.name, "InsufficientSources")
        with self.assertRaises(Revert) as e:
            bracket_reference([a, a], 200, sequencer=SequencerStatus(False, 100))
        self.assertEqual(e.exception.name, "SequencerDown")
        for since in (0, 201):
            with self.assertRaises(Revert) as e:
                bracket_reference([a, a], 200, sequencer=SequencerStatus(True, since))
            self.assertEqual(e.exception.name, "SequencerUnusable")
        with self.assertRaises(Revert) as e:
            bracket_reference([a, a], 3_700, sequencer=SequencerStatus(True, 100), grace=3_600)  # exactly the grace
        self.assertEqual(e.exception.name, "SequencerGracePeriod")
        bracket_reference([a, a], 1_000, sequencer=SequencerStatus(True, 100), grace=899)  # one second past it
        with self.assertRaises(Revert) as e:
            bracket_reference([a, a], 200, sequencer=SequencerStatus(True, 150), grace=3_600)
        self.assertEqual(e.exception.name, "SequencerGracePeriod")
        with self.assertRaises(Revert) as e:
            bracket_reference([BracketSource(Q96, 300, 5_000, 1_000), a], 200)
        self.assertEqual(e.exception.name, "ReferenceUnavailable")

    def test_bracket_covers_every_consistent_market(self):
        """If every source is live (market within its own bracket), then M (1 +- u) contains the market: quotes with
        half-spread >= u cannot be arbitraged against any market the sources allow."""
        rng = random.Random(108)
        for _ in range(2_000):
            m = rng.randint(2**90, 2**110)
            srcs = []
            for _s in range(rng.randint(2, 3)):
                d = rng.choice([3_000, 5_000])
                # The market lies in this source's bracket: m = p (1 + x) with |x| < d.
                p = int(m / (1 + rng.uniform(-d, d) / PIPS * 0.9999))
                srcs.append(BracketSource(p, 0, d, 10))
            r = bracket_reference(srcs, 1)
            self.assertLessEqual(r.price_x96 * (PIPS - r.uncertainty), m * PIPS)
            self.assertGreaterEqual(r.price_x96 * (PIPS + r.uncertainty), m * PIPS)
            # Read in the other direction: M / (1 + u) <= m, i.e. (1 / M)(1 + u) >= 1 / m (G04 F-1).
            self.assertLessEqual(r.price_x96 * PIPS, m * (PIPS + r.uncertainty))

    def test_uncertainty_covers_bracket_both_directions(self):
        """For any bracket, M (1 + u) >= H and M <= L (1 + u), exactly in integers. The second fails for the earlier
        mid-relative definition once the bracket is wide enough (G04 F-1)."""
        rng = random.Random(2004)
        old_fails = 0
        for _ in range(5_000):
            lo = rng.randint(1, 2**160)
            hi = lo + rng.randint(0, lo // rng.choice([10, 100, 1_000, 10**6]) + 1)
            m, u = mid_and_uncertainty(lo, hi)
            self.assertGreaterEqual(m * (PIPS + u), hi * PIPS)
            self.assertLessEqual(m * PIPS, lo * (PIPS + u))
            u_old = max(mul_div_up(hi - m, PIPS, m), mul_div_up(m - lo, PIPS, m))
            old_fails += m * PIPS > lo * (PIPS + u_old)
        self.assertGreater(old_fails, 100)


if __name__ == "__main__":
    unittest.main()
