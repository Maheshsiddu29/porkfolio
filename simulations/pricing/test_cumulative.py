"""Economic-consistency and adversarial checks of the cumulative pricing model (Stage 1 gate).

Run from the repository root:  python3 -m unittest discover -s simulations/pricing -v

Every check is deterministic (fixed seeds). A failure here means the candidate formula is unsound and the Solidity
implementation must not proceed. Amounts are raw units of 18-decimal tokens unless stated.
"""

from __future__ import annotations

import random
import unittest
from fractions import Fraction

from cumulative import (
    PIPS,
    Q96,
    HookA,
    HookAConfig,
    HookB,
    HookBConfig,
    Revert,
    cost_real,
    cumulative_fee,
    decayed,
    fee_real,
    floor_ok,
    floors_consistent,
    max_position,
    mul_div_up,
    old_hook_a_out,
    old_hook_b_out,
    position_cost,
    position_for_cost,
)

E18 = 10**18
P1 = Q96  # 1:1 reference price


def partition(rng: random.Random, total: int, n: int) -> list[int]:
    """Random partition of `total` into `n` positive pieces (total >= n)."""
    cuts: set[int] = set()
    while len(cuts) < n - 1:
        cuts.add(rng.randrange(1, total))
    edges = [0, *sorted(cuts), total]
    return [b - a for a, b in zip(edges, edges[1:])]


def random_price(rng: random.Random) -> int:
    """Reference prices from 1e-6 to 1e6 currency1 per currency0, plus both decimal-mismatch extremes."""
    choice = rng.randrange(4)
    if choice == 0:
        return P1
    if choice == 1:
        return rng.randrange(Q96 // 10**6, Q96 * 10**6)
    if choice == 2:
        return Q96 * 10**12  # 6-decimal currency0 vs 18-decimal currency1, 1:1 in value
    return Q96 // 10**12


class IntegerFunctions(unittest.TestCase):
    """The integer functions are the exact ceilings / inverses the specification defines."""

    def test_fee_is_ceiling_and_continuous(self):
        rng = random.Random(1)
        for _ in range(3000):
            k = rng.randrange(1, 10**24)
            base = rng.randrange(0, 50_000)
            mx = rng.randrange(base, PIPS)
            s = rng.randrange(0, 3 * k)
            f = cumulative_fee(s, k, base, mx)
            exact = fee_real(s, k, base, mx)
            self.assertTrue(f - 1 < exact <= f)
            # Both branches describe the same real function at s = K.
            self.assertEqual(fee_real(k, k, base, mx), Fraction(k * (base + mx), 2 * PIPS))
            # A fee difference never exceeds the input it is charged on (max < 100%).
            d = rng.randrange(1, 10**20)
            self.assertLessEqual(cumulative_fee(s + d, k, base, mx) - f, d)

    def test_position_cost_is_ceiling(self):
        rng = random.Random(2)
        for _ in range(3000):
            v = rng.randrange(10, 2**95)
            p = random_price(rng)
            xm = max_position(v, rng.randrange(1, PIPS))
            x = rng.randrange(-xm, xm + 2)
            c = position_cost(x, v, p)
            exact = cost_real(x, v, p)
            self.assertTrue(c - 1 < exact <= c, (x, v, p))

    def test_position_for_cost_matches_bisection(self):
        """positionForCost(t) is the largest x with C_hat(x) <= t, found here independently by bisection."""
        rng = random.Random(3)
        for _ in range(1500):
            v = rng.randrange(10, 2**95)
            p = random_price(rng)
            xm = max_position(v, rng.randrange(1, PIPS))
            lo_t, hi_t = position_cost(-xm, v, p), position_cost(xm + 1, v, p)
            t = rng.randrange(lo_t, hi_t)
            got = position_for_cost(t, v, p)
            lo, hi = -xm - 1, xm + 1  # C_hat(lo) <= t < C_hat(hi + 1) is not assumed; bisection on [lo, hi]
            assert position_cost(lo, v, p) <= t
            while lo < hi:
                mid = (lo + hi + 1) // 2
                if position_cost(mid, v, p) <= t:
                    lo = mid
                else:
                    hi = mid - 1
            self.assertEqual(got, lo, (t, v, p))

    def test_max_position_is_exact_cap(self):
        """Marginal impact (V/(V-x))^2 - 1 is <= m at xmax and > m at xmax + 1 (exact rationals)."""
        rng = random.Random(4)
        for _ in range(3000):
            v = rng.randrange(4, 2**95)
            m = rng.randrange(1, PIPS)
            xm = max_position(v, m)
            lim = Fraction(PIPS + m, PIPS)
            self.assertLessEqual(Fraction(v, v - xm) ** 2, lim)
            self.assertGreater(Fraction(v, v - xm - 1) ** 2, lim)
            # On the negative side the vault sells currency0; its marginal premium at -xmax is smaller still.
            self.assertLessEqual(Fraction(v + xm, v) ** 2, lim)


class SplitInvariance(unittest.TestCase):
    """Unchanged pricing state, no elapsed time: one trade versus the same total in 1..50 pieces."""

    def test_hook_a_split(self):
        rng = random.Random(10)
        worst = 0
        for _ in range(1500):
            cfg = HookAConfig(random_price(rng), rng.randrange(0, 5000), 0, rng.randrange(1, 10**24),
                              rng.randrange(1, 10**24), 0)
            cfg.mx = rng.randrange(cfg.base, PIPS)
            zfo = rng.random() < 0.5
            pre = rng.randrange(0, 2 * cfg.scale(zfo))
            total = rng.randrange(10**3, 10**24)
            n = rng.randrange(1, 51)
            single, split = HookA(), HookA()
            for h in (single, split):
                h.configure(cfg, 0)
                h.level[zfo] = pre
            out1, fee1, _ = single.quote(zfo, total, 0)
            out_n = fee_n = 0
            for piece in partition(rng, total, n):
                o, f, s2 = split.quote(zfo, piece, 0)
                out_n += o
                fee_n += f
                split.level[zfo] = s2
            self.assertEqual(fee_n, fee1, "fees telescope exactly")
            self.assertEqual(split.level[zfo], pre + total)
            self.assertLessEqual(out_n, out1, "splitting never pays more output")
            self.assertLessEqual(out1 - out_n, n - 1, "gap <= n - 1 raw output units (one floor per piece)")
            worst = max(worst, out1 - out_n - (n - 1))
        self.assertLessEqual(worst, 0)

    def test_hook_b_split_zero_for_one(self):
        """Selling currency1: the split ends at a position no higher than the single trade, and the value it forgoes
        is exactly the exact-input remainders the pieces left behind."""
        rng = random.Random(11)
        for _ in range(1500):
            v = rng.randrange(10**6, 2**95)
            p = random_price(rng)
            cfg = HookBConfig(p, v, rng.randrange(1000, 200_000), 0)
            xm = cfg.xmax
            if xm < 100:
                continue
            x0 = rng.randrange(-xm, xm // 2)
            room = position_cost(xm, v, p) - position_cost(x0, v, p)
            if room < 100:
                continue
            total = rng.randrange(50, room)
            n = rng.randrange(1, min(51, total))
            single, split = HookB(), HookB()
            for h in (single, split):
                h.configure(cfg, 0)
                h.x = x0
            out1, x1, _ = single.quote(True, total, 0)
            outs, slack_sum, slack_bound = 0, 0, 0
            for piece in partition(rng, total, n):
                try:
                    o, x2, sl = split.quote(True, piece, 0)
                except Revert:
                    self.fail("a piece of an in-cap trade cannot exceed the cap")
                outs += o
                slack_sum += sl
                # Each remainder is below the integer cost of one more unit at the piece's end.
                slack_bound += position_cost(x2 + 1, v, p) - position_cost(x2, v, p) - 1
                split.x = x2
            xn = split.x
            self.assertLessEqual(xn, x1)
            self.assertEqual(outs, xn - x0)
            self.assertLessEqual(position_cost(x1, v, p) - position_cost(xn, v, p), slack_sum)
            self.assertLessEqual(slack_sum, slack_bound)
            # Output-unit form: gap * c_lo < n * (ceil(c_hi) - 1) + 1, c = real marginal unit cost.
            c_lo = cost_real(xn + 1, v, p) - cost_real(xn, v, p)
            c_hi = cost_real(x1 + 2, v, p) - cost_real(x1 + 1, v, p) if x1 + 2 < v else c_lo
            ceil_hi = -((-c_hi.numerator) // c_hi.denominator)
            self.assertLess((x1 - xn) * c_lo, n * (ceil_hi - 1) + 1 + 1, (x1 - xn, n, c_lo, c_hi))

    def test_hook_b_split_one_for_zero_is_exact(self):
        rng = random.Random(12)
        for _ in range(1500):
            v = rng.randrange(10**6, 2**95)
            p = random_price(rng)
            cfg = HookBConfig(p, v, rng.randrange(1000, 200_000), 0)
            xm = cfg.xmax
            if xm < 100:
                continue
            x0 = rng.randrange(-xm // 2, xm + 1)
            total = rng.randrange(50, x0 + xm)
            n = rng.randrange(1, min(51, total))
            single, split = HookB(), HookB()
            for h in (single, split):
                h.configure(cfg, 0)
                h.x = x0
            out1, x1, _ = single.quote(False, total, 0)
            outs = 0
            for piece in partition(rng, total, n):
                o, x2, _ = split.quote(False, piece, 0)
                outs += o
                split.x = x2
            self.assertEqual(split.x, x1)
            self.assertEqual(outs, out1, "currency1 input is exact, so buy-backs telescope with no remainder")

    def test_hook_b_cap_is_aggregate(self):
        """No partition of a flow that would end past xmax executes in full (inverts the per-swap cap)."""
        rng = random.Random(13)
        v = 200_000 * E18
        cfg = HookBConfig(P1, v, 10_000, 0)  # TRADE_SPLITTING 4.3: k = 5% > cap = 1%
        xm = cfg.xmax
        self.assertEqual(xm // E18, 992)  # spec: |x| <= 992.6
        for n in (1, 2, 5, 10, 100):
            h = HookB()
            h.configure(cfg, 0)
            reverted = False
            for piece in partition(rng, 5000 * E18, n):
                try:
                    h.swap(True, piece, 0)
                except Revert as e:
                    self.assertEqual(e.name, "ImpactBoundExceeded")
                    reverted = True
                    break
            self.assertTrue(reverted)
            self.assertLessEqual(h.x, xm)


class InterleavedAndRoundTrips(unittest.TestCase):
    def test_hook_b_any_sequence_telescopes(self):
        """For any sequence of trades in both directions with no elapsed time, the trader pays exactly
        C_hat(x_end) - C_hat(x_start) currency0 plus the exact-input remainders, and receives x_end - x_start
        currency1. Corollary: a sequence returning x to its start never leaves the trader with more of either asset."""
        rng = random.Random(20)
        for _ in range(400):
            v = rng.randrange(10**8, 10**28)
            p = random_price(rng)
            cfg = HookBConfig(p, v, rng.randrange(1000, 300_000), 0)
            xm = cfg.xmax
            h = HookB()
            h.configure(cfg, 0)
            x0 = h.x = rng.randrange(-xm, xm + 1)
            paid0 = recv1 = slack = 0
            for _ in range(rng.randrange(1, 40)):
                zfo = rng.random() < 0.5
                amt = rng.randrange(1, max(2, xm // 3)) if not zfo else rng.randrange(1, max(2, position_cost(xm, v, p) // 3))
                try:
                    out, x2, sl = h.quote(zfo, amt, 0)
                except Revert:
                    continue
                if out == 0:
                    continue
                h.x = x2
                if zfo:
                    paid0 += amt
                    recv1 += out
                    slack += sl
                else:
                    paid0 -= out
                    recv1 -= amt
            self.assertEqual(paid0, position_cost(h.x, v, p) - position_cost(x0, v, p) + slack)
            self.assertEqual(recv1, h.x - x0)
            # Close the loop with one more trade and value the trader's result at the reference price P.
            # Exact input in currency0 lands on the largest x with C_hat(x) <= target, which can be past x0 where
            # C_hat is flat (currency1 cheaper than one raw currency0): the extra currency1 is worth < 1 raw currency0.
            gap = h.x - x0
            if gap > 0:
                out, x2, _ = h.quote(False, gap, 0)
                paid0 -= out
                recv1 -= gap
                h.x = x2
            elif gap < 0:
                need = position_cost(x0, v, p) - position_cost(h.x, v, p)
                out, x2, _ = h.quote(True, need, 0)
                paid0 += need
                recv1 += out
                h.x = x2
            self.assertGreaterEqual(h.x, x0)
            self.assertEqual(recv1, h.x - x0)
            self.assertEqual(position_cost(h.x, v, p), position_cost(x0, v, p), "overshoot only across a flat step")
            self.assertGreaterEqual(paid0, 0, "a closed cycle never pays the trader currency0")
            # Valued at P the flat-step units are worth < 1 raw currency0 of curve cost, scaled by at most the
            # marginal ratio (V + |x|)^2 / V^2 <= 1 + maxImpact on the negative side. Once per sequence, not per cycle.
            self.assertLess(Fraction(recv1 * Q96, p) - paid0, Fraction(PIPS + cfg.max_impact, PIPS))

    def test_hook_b_single_actor_cycles_with_decay(self):
        """One actor alone on a pool from x = 0, P fixed, decay between trades: valued at P, the actor's holdings
        never rise by one raw currency0 or more. Random strategies of up to 12 trades plus a closing trade."""
        rng = random.Random(21)
        best = None
        for _ in range(4000):
            v = rng.randrange(10**6, 10**24)
            p = random_price(rng)
            cfg = HookBConfig(p, v, rng.randrange(1000, 300_000), rng.randrange(1, 10**6))
            h = HookB()
            h.configure(cfg, 0)
            now = 0
            d0 = d1 = 0  # actor's holdings change
            xm = cfg.xmax
            for _ in range(rng.randrange(1, 12)):
                now += rng.choice([0, 0, 1, rng.randrange(1, 2 * cfg.window + 2)])
                zfo = rng.random() < 0.5
                amt = rng.randrange(1, max(2, position_cost(xm, v, p) // 2 if zfo else xm // 2))
                try:
                    out = h.swap(zfo, amt, now)
                except Revert:
                    continue
                if zfo:
                    d0, d1 = d0 - amt, d1 + out
                else:
                    d0, d1 = d0 + out, d1 - amt
            now += rng.choice([0, 1, cfg.window])
            try:
                if d1 > 0:
                    d0, d1 = d0 + h.swap(False, d1, now), 0
                elif d1 < 0:
                    x = h.position_now(now)
                    need = position_cost(x - d1, v, p) - position_cost(x, v, p)
                    d0, d1 = d0 - need, d1 + h.swap(True, need, now)
            except Revert:
                continue
            self.assertGreaterEqual(d1, 0)
            value = d0 + Fraction(d1 * Q96, p)
            best = value if best is None else max(best, value)
            self.assertLess(value, 1, "single-actor cycle gained a raw currency0 unit or more at P")
        print(f"\n  single-actor cycles with decay: best result {float(best):.6g} raw currency0 at P (< 1 required)")

    def test_hook_a_round_trip_pays_both_fees(self):
        cfg = HookAConfig(P1, 500, 5000, 10_000 * E18, 10_000 * E18, 0)
        h = HookA()
        h.configure(cfg, 0)
        out1 = h.swap(True, 1000 * E18, 0)
        out2 = h.swap(False, out1, 0)
        f1 = cumulative_fee(1000 * E18, cfg.scale0, 500, 5000)
        f2 = cumulative_fee(out1, cfg.scale1, 500, 5000)
        self.assertEqual(out2, out1 - f2)
        self.assertEqual(1000 * E18 - out2, f1 + f2)
        self.assertEqual(h.level, {True: 1000 * E18, False: out1})


class FloorsAndSandwiches(unittest.TestCase):
    def test_reversal_needs_matching_floor(self):
        """A trade that reverses a Hook B move is priced on the same curve segment, so its average price equals the
        reversed trade's. With D14-consistent floors (F0 * F1 >= 2^192) both legs pass only if that price is exactly
        the floor. Shown on a grid of floors and positions at a 1:1 reference."""
        v = 10**6 * E18
        cfg = HookBConfig(P1, v, 20_000, 0)
        for f1_bps in (9_800, 9_900, 10_000, 10_100):
            f1 = Q96 * f1_bps // 10_000
            f0 = mul_div_up(Q96, Q96, f1)
            self.assertTrue(floors_consistent(f0, f1))
            for q in (1 * E18, 1000 * E18, 5000 * E18):
                h = HookB()
                h.configure(cfg, 0)
                cost = position_cost(q, v, P1)
                out = h.swap(True, cost, 0)
                leg1 = floor_ok(cost, out, f1)  # vault sells currency1
                back = h.quote(False, out, 0)[0]
                leg2 = floor_ok(out, back, f0)  # vault sells currency0
                self.assertFalse(leg1 and leg2 and back >= cost, "a zero-cost round trip passed both floors")

    def test_sandwich_back_run_is_refused_by_floors(self):
        """Hook-level sandwich (front-run buy of currency1, victim buy, back-run sale) is profitable on the curve
        alone, as for any path-independent AMM. The vault's consistent floors refuse every back-run that would
        realise a profit: the back-run's average price is above the front-run's, which is >= F1 >= 1/F0."""
        rng = random.Random(30)
        profitable_on_curve = refused = 0
        for _ in range(2000):
            v = rng.randrange(10**4, 10**8) * E18
            cfg = HookBConfig(P1, v, rng.randrange(5_000, 100_000), 0)
            f1 = Q96 * rng.randrange(9_000, 11_000) // 10_000
            f0 = mul_div_up(Q96, Q96, f1)
            h = HookB()
            h.configure(cfg, 0)
            xm = cfg.xmax
            cap_cost = position_cost(xm, v, P1)
            a_in, v_in = rng.randrange(1, cap_cost // 2), rng.randrange(1, cap_cost // 2)
            try:
                a_out = h.swap(True, a_in, 0)
                h.swap(True, v_in, 0)
                back = h.quote(False, a_out, 0)[0]
            except Revert:
                continue
            if back > a_in:
                profitable_on_curve += 1
                front_ok = floor_ok(a_in, a_out, f1)
                back_ok = floor_ok(a_out, back, f0)
                self.assertFalse(front_ok and back_ok, "profitable sandwich passed both floors")
                refused += 1
        self.assertGreater(profitable_on_curve, 100)
        print(f"\n  sandwiches profitable on the curve alone: {profitable_on_curve}; refused by floors: {refused}")

    def test_min_out_protects_victim(self):
        v = 10**6 * E18
        cfg = HookBConfig(P1, v, 20_000, 0)
        h = HookB()
        h.configure(cfg, 0)
        expected = h.quote(True, 1000 * E18, 0)[0]
        h.swap(True, 4000 * E18, 0)  # front-run
        with self.assertRaises(Revert) as ctx:
            h.swap(True, 1000 * E18, 0, min_out=expected)
        self.assertEqual(ctx.exception.name, "InsufficientOutput")


class DecayAndParameters(unittest.TestCase):
    def test_decay_monotone_no_reset(self):
        for level, rate, window in ((10**21, 10**22, 3600), (5, 7, 1), (2**127, 2**128 - 1, 86400)):
            prev = level
            for dt in sorted({0, 1, window - 1, window, window + 1, 2**32, 2**64 - 1}):
                d = decayed(level, rate, window, dt)
                self.assertLessEqual(d, prev)
                self.assertGreaterEqual(d, 0)
                self.assertGreaterEqual(d, level - Fraction(rate * dt, window))
                prev = d

    def test_decay_split_gain_bounded(self):
        """Waiting dt between pieces lets the price recover by at most rate * dt of level (+1 unit of rounding)."""
        rng = random.Random(40)
        for _ in range(500):
            cfg = HookAConfig(P1, 500, 5000, 10_000 * E18, 10_000 * E18, rng.randrange(60, 86_400))
            a, b = HookA(), HookA()
            a.configure(cfg, 0)
            b.configure(cfg, 0)
            g1 = rng.randrange(1, 20_000) * E18
            g2 = rng.randrange(1, 20_000) * E18
            dt = rng.randrange(0, 2 * cfg.window)
            a.swap(True, g1, 0)
            a_out = a.swap(True, g2, dt)
            b.swap(True, g1, 0)
            b_out = b.swap(True, g2, 0)
            # The waiting trader's second piece starts at a level lower by at most rate*dt; its fee is lower by at
            # most the max-fee charge on that much flow, plus one unit of rounding.
            saved_fee = (a_out - b_out)
            bound = (cfg.scale0 * dt // cfg.window) * cfg.mx // PIPS + 2
            self.assertLessEqual(saved_fee, bound)

    def test_depth_change_rescale_keeps_price_and_avoids_giveaway(self):
        """Rule chosen: on a depth change, x is rescaled by V_new / V_old, so the marginal price is continuous. The
        rejected alternative keeps raw x; tightening V then re-marks x on a steep part of the curve, and a buy-back is
        paid far above the price at which the vault sold the last unit."""
        v_old, v_new = 10**6 * E18, 10**5 * E18
        sold, part = 20_000 * E18, 1000 * E18
        marginal_at_sale = Fraction(v_old, v_old - sold) ** 2  # currency0 per currency1 for the last unit sold
        payouts = {}
        for rescale in (True, False):
            h = HookB(rescale_on_depth_change=rescale)
            h.configure(HookBConfig(P1, v_old, 300_000, 0), 0)
            h.swap(True, position_cost(sold, v_old, P1), 0)
            before = Fraction(v_old, v_old - h.x) ** 2
            h.configure(HookBConfig(P1, v_new, 300_000, 0), 0)
            if rescale:
                self.assertEqual(h.x, sold // 10)
                self.assertLess(abs(Fraction(v_new, v_new - h.x) ** 2 - before), Fraction(1, 10**12))
            payouts[rescale] = h.quote(False, part, 0)[0]
        self.assertLessEqual(Fraction(payouts[True], part), marginal_at_sale, "rescaled: no buy-back premium")
        self.assertGreater(Fraction(payouts[False], part), Fraction(3, 2), "raw rule pays > 1.5 per unit")
        print(f"\n  buy-back of 1,000 after V/10: rescaled {payouts[True] / E18:.4f}, raw {payouts[False] / E18:.4f}"
              f" currency0 (last unit sold at {float(marginal_at_sale):.4f} per unit)")

    def test_cap_tightening_allows_only_inward_trades(self):
        v = 10**6 * E18
        h = HookB()
        h.configure(HookBConfig(P1, v, 20_000, 0), 0)
        h.swap(True, position_cost(9000 * E18, v, P1), 0)
        h.configure(HookBConfig(P1, v, 5_000, 0), 0)  # new cap ~ 2,490
        self.assertGreater(h.x, h.cfg.xmax)
        with self.assertRaises(Revert):
            h.swap(True, E18, 0)
        h.swap(False, E18, 0)  # inward trade allowed

    def test_hook_a_scale_change_keeps_level(self):
        h = HookA()
        cfg = HookAConfig(P1, 500, 5000, 10_000 * E18, 10_000 * E18, 3600)
        h.configure(cfg, 0)
        h.swap(True, 5000 * E18, 0)
        h.configure(HookAConfig(P1, 500, 5000, 5000 * E18, 10_000 * E18, 3600), 1800)
        self.assertEqual(h.level[True], 5000 * E18 - 10_000 * E18 * 1800 // 3600)  # decayed under the old K/W
        tight = h.quote(True, 1000 * E18, 1800)[1]
        h2 = HookA()
        h2.configure(cfg, 0)
        h2.swap(True, 5000 * E18, 0)
        loose = h2.quote(True, 1000 * E18, 1800)[1]
        self.assertGreater(tight, loose, "smaller K charges more at the same level")


class AllocationIndependence(unittest.TestCase):
    def test_old_pricing_rewards_allocation_shopping_new_does_not(self):
        """Old: the fee/impact depends on the chosen allocation's consumed/maxOut, so a fresh allocation resets it.
        New: the pricing state is per pool and direction; the allocation id is not an input."""
        used, fresh = (8_000 * E18, 10_000 * E18), (0, 10_000 * E18)
        a_used = old_hook_a_out(P1, 500, 5000, True, 1000 * E18, *used)
        a_fresh = old_hook_a_out(P1, 500, 5000, True, 1000 * E18, *fresh)
        self.assertGreater(a_fresh, a_used)
        b_used = old_hook_b_out(P1, 10_000, 20_000, True, 1000 * E18, 8_000 * E18, 10_000 * E18)
        b_fresh = old_hook_b_out(P1, 10_000, 20_000, True, 1000 * E18, 0, 10_000 * E18)
        self.assertGreater(b_fresh, b_used)
        # New pricing: identical by construction (no allocation argument); the Solidity tests check it end to end.


class SpecExamples(unittest.TestCase):
    """Reproduces CUMULATIVE_PRICING_SPEC.md section 5 (1:1, 18-decimal tokens)."""

    def test_hook_a_8000(self):
        cfg = HookAConfig(P1, 500, 5000, 10_000 * E18, 10_000 * E18, 0)
        for n in (1, 8, 1000):
            h = HookA()
            h.configure(cfg, 0)
            out = sum(h.swap(True, 8000 * E18 // n, 0) for _ in range(n))
            self.assertEqual(8000 * E18 - out - (8000 * E18 - 8000 * E18 // n * n), 18_400_000_000_000_000_000)

    def test_hook_b_examples(self):
        v = 10**6 * E18
        cfg = HookBConfig(P1, v, 20_000, 0)
        self.assertEqual(position_cost(1000 * E18, v, P1), 1_001_001_001_001_001_001_002)
        self.assertEqual(cfg.xmax, 9_852_457_023_325_690_846_726)  # spec: 9,852.5
        self.assertAlmostEqual(cfg.xmax / E18, 10**6 * (1 - 1.02**-0.5), places=6)
        self.assertEqual(position_cost(5000 * E18, v, P1) - 5000 * E18, 25_125_628_140_703_517_588)  # 25.1256


if __name__ == "__main__":
    unittest.main()
