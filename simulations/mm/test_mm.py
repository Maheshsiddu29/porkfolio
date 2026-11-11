"""Economic-consistency and adversarial checks of the Phase 1B-4 candidates (integer model).

Run from the repository root:  python3 -m unittest discover -s simulations/mm -v

Each test states the property it checks and why it matters. Randomised tests use fixed seeds, so every run checks the
same cases. A failure here is a counterexample to a claim in `docs/architecture/INVENTORY_PRICING_SPEC.md`.
"""

from __future__ import annotations

import os
import random
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))

from model import (  # noqa: E402
    MAX_AMOUNT,
    PIPS,
    Q96,
    WAD,
    FeedReading,
    HookB,
    HookBConfig,
    InventoryConfig,
    Reference,
    ReferencePolicy,
    Revert,
    TwoSidedCurve,
    TwoSidedCurveConfig,
    VaultSnapshot,
    depth_per_share_for,
    ext_cost,
    ext_position_for_cost,
    floor_ok,
    floors_from_pivot,
    inventory_state,
    mul_div_up,
    position_cost,
    quote_inventory,
    resolve_reference,
    straddle_cap,
)

E18 = 10**18
E6 = 10**6


def cfg(spread=2_000, dev=300_000, min_edge=100, tau=WAD, max_spread=50_000):
    return InventoryConfig(tau, depth_per_share_for(tau, dev, spread, min_edge), 2**95 - 1, spread, min_edge,
                           max_spread, dev)


class Vault:
    """Minimal vault for the model: applies a C quote's amounts to N_0, N_1 exactly as `exchange` would."""

    def __init__(self, n0, n1, shares):
        self.n0, self.n1, self.s = n0, n1, shares

    def snap(self):
        return VaultSnapshot(self.n0, self.n1, self.s)

    def swap(self, c, ref, zfo, amt):
        q = quote_inventory(c, self.snap(), ref, zfo, amt)
        if zfo:
            self.n0, self.n1 = self.n0 + amt, self.n1 - q.amount_out
        else:
            self.n0, self.n1 = self.n0 - q.amount_out, self.n1 + amt
        return q.amount_out


def rand_vault(rng, scale=E18):
    base = rng.randint(10**4, 10**7) * scale
    s = base
    dev = rng.uniform(-0.25, 0.25)
    return Vault(base, int(base * (1 - dev)), s)


def rand_ref(rng, decimals_gap=0):
    p = rng.uniform(0.2, 5.0) * 10 ** (-decimals_gap)
    return Reference(int(p * Q96), rng.randint(0, 3_000))


class StraddleTheorem(unittest.TestCase):
    """At a fixed reference M every accepted C trade is priced on the vault's side of M by at least h_min:
    the vault never buys currency1 above M(1 - h_min) or sells it below M(1 + h_min). This is what makes C compatible
    with D14 floors pivoted at M, and what makes every closed trading cycle at fixed M a loss for the trader, whatever
    the state, parameters, hook or allocation (`test_cycles_*`)."""

    def _check(self, zfo, amt, out, ref, h_min):
        # Execution price against the reference, exactly: zfo pays amt c0 for out c1 at M = P/Q96 c1 per c0.
        if zfo:  # vault sells currency1: needs amt >= out / M * (1 + h_min)
            return amt * ref.price_x96 * PIPS >= out * Q96 * (PIPS + h_min)
        return out * ref.price_x96 * PIPS <= amt * Q96 * (PIPS - h_min)

    def test_every_accepted_quote_straddles_the_reference(self):
        rng = random.Random(1)
        bad, ok = [], 0
        for _ in range(4000):
            c = cfg(spread=rng.choice([300, 1_000, 2_000, 5_000]), dev=rng.choice([50_000, 150_000, 300_000]),
                    min_edge=rng.choice([0, 10, 100]))
            v = rand_vault(rng)
            ref = rand_ref(rng)
            zfo = rng.random() < 0.5
            amt = int(rng.lognormvariate(10, 3) * E18 // 1000) + 1
            try:
                out = quote_inventory(c, v.snap(), ref, zfo, amt).amount_out
            except Revert:
                continue
            ok += 1
            if not self._check(zfo, amt, out, ref, c.min_edge):
                bad.append((zfo, amt, out))
        self.assertGreater(ok, 1500)
        self.assertEqual(bad, [])

    def test_dust_trades_also_straddle(self):
        """The exact straddle bound holds for dust too (the one-unit reserve on each side)."""
        rng = random.Random(21)
        n = 0
        for _ in range(4000):
            c = cfg(spread=rng.choice([300, 2_000]), min_edge=rng.choice([0, 1, 100]))
            v, ref = rand_vault(rng), rand_ref(rng)
            zfo = rng.random() < 0.5
            amt = rng.randint(1, 10**5)
            try:
                out = quote_inventory(c, v.snap(), ref, zfo, amt).amount_out
            except Revert:
                continue
            n += 1
            self.assertTrue(self._check(zfo, amt, out, ref, c.min_edge), (zfo, amt, out))
        self.assertGreater(n, 500)

    def test_quotes_pass_d14_floors_pivoted_at_the_reference(self):
        """Same property on the vault's own integer floor check, including dust-sized trades. The floor F_sell1 is
        itself a ceiling of 2^192 / K, so the vault can demand a fraction of a unit more than the exact price; the
        straddle edge h_min covers that once out * h_min >= 1, and the one-unit reserve covers it below."""
        rng = random.Random(2)
        fails, ok = 0, 0
        for _ in range(3000):
            c = cfg(spread=rng.choice([300, 2_000]), min_edge=rng.choice([1, 100]))
            v = rand_vault(rng)
            ref = rand_ref(rng)
            f0, f1 = floors_from_pivot(ref.price_x96)
            zfo = rng.random() < 0.5
            amt = rng.choice([1, 7, 10**3, 10**9, 10**15, 10**21])
            try:
                out = quote_inventory(c, v.snap(), ref, zfo, amt).amount_out
            except Revert:
                continue
            ok += 1
            fails += not floor_ok(amt, out, f1 if zfo else f0)
        self.assertGreater(ok, 1000)
        self.assertEqual(fails, 0)

    def test_inward_trades_from_beyond_the_cap_are_priced_and_straddle(self):
        """A vault pushed beyond the cap (by a parameter change or a shrinking share supply) must still accept trades
        that reduce the imbalance, at prices that respect the straddle; it must refuse every trade that adds to it."""
        rng = random.Random(3)
        for _ in range(500):
            c = cfg()
            v = Vault(10**6 * E18, int(10**6 * E18 * rng.uniform(0.2, 0.6)), 10**6 * E18)  # far short currency1
            ref = Reference(Q96, 0)
            i, _, t1 = inventory_state(c, v.snap())
            self.assertGreater(i, t1 * c.max_deviation // PIPS)
            amt = rng.randint(1, 50_000) * E18
            out = quote_inventory(c, v.snap(), ref, False, amt).amount_out
            self.assertTrue(self._check(False, amt, out, ref, c.min_edge))
            with self.assertRaises(Revert):
                quote_inventory(c, v.snap(), ref, True, 10 * E18)


class SplitAndPath(unittest.TestCase):
    """Fixed vault composition and reference: the cost of a sequence of trades is a potential difference plus the
    spread on its total variation. So splitting never gains, and any detour costs at least the direct path."""

    def test_split_never_gains_and_loses_little(self):
        rng = random.Random(4)
        for _ in range(600):
            c = cfg(spread=rng.choice([300, 2_000, 5_000]))
            v0 = rand_vault(rng)
            ref = rand_ref(rng)
            zfo = rng.random() < 0.5
            total = rng.randint(1, 30_000) * E18 + rng.randint(0, E18)
            n = rng.randint(2, 50)
            cuts = sorted({rng.randint(1, total - 1) for _ in range(n - 1)})
            n = len(cuts) + 1
            parts = [b - a for a, b in zip([0] + cuts, cuts + [total])]
            v1 = Vault(v0.n0, v0.n1, v0.s)
            try:
                single = v1.swap(c, ref, zfo, total)
            except Revert:
                continue
            v2 = Vault(v0.n0, v0.n1, v0.s)
            got = 0
            try:
                for p in parts:
                    got += v2.swap(c, ref, zfo, p)
            except Revert:
                continue
            self.assertLessEqual(got, single)
            # Each piece loses the floor of its spread credit, the one-unit reserve and the inversion's remainder:
            # under 3 units of potential per piece, converted at a price within [0.2, 5] -> at most 16 raw units.
            self.assertLessEqual(single - got, 16 * n)

    def test_cycles_at_fixed_reference_always_lose(self):
        """Random walks of trades in both directions that return the vault's currency1 to its start: the trader must
        end with less currency0 (by at least about 2 h_min of the currency1 moved). Includes changes of spread,
        risk cap and target between legs, which the straddle theorem says cannot open a profitable cycle."""
        rng = random.Random(5)
        for _ in range(300):
            ref = rand_ref(rng)
            v = rand_vault(rng)
            start1 = v.n1
            trader0, moved = 0, 0
            for _ in range(rng.randint(2, 12)):
                c = cfg(spread=rng.choice([300, 2_000]), dev=rng.choice([50_000, 300_000]), min_edge=100,
                        tau=rng.choice([WAD, WAD * 9 // 10, WAD * 11 // 10]))
                zfo = rng.random() < 0.5
                amt = rng.randint(1, 20_000) * E18
                try:
                    before0 = v.n0
                    v.swap(c, ref, zfo, amt)
                    trader0 += before0 - v.n0  # currency0 the trader received (negative: paid)
                    moved += abs(v.n1 - start1)
                except Revert:
                    continue
            # Close the loop exactly in currency1 with one trade under the base parameters.
            c = cfg(spread=2_000, dev=300_000, min_edge=100)
            gap = v.n1 - start1
            if gap == 0:
                continue
            try:
                if gap > 0:  # vault holds extra currency1: trader buys it back with currency0 (exact output by search)
                    lo, hi = 1, 10**30
                    while lo < hi:
                        mid = (lo + hi) // 2
                        if quote_inventory(c, v.snap(), ref, True, mid).amount_out >= gap:
                            hi = mid
                        else:
                            lo = mid + 1
                    before0 = v.n0
                    v.swap(c, ref, True, lo)
                    trader0 += before0 - v.n0
                    surplus1 = start1 - v.n1  # trader may have received a little more than the gap
                    self.assertGreaterEqual(surplus1, 0)
                else:
                    before0 = v.n0
                    v.swap(c, ref, False, -gap)
                    trader0 += before0 - v.n0
            except Revert:
                continue
            self.assertLessEqual(trader0, 0, "a closed cycle at a fixed reference never pays the trader")

    def test_lp_flows_do_not_move_the_price(self):
        """Proportional deposits and redemptions scale N_1, T_1 and V together, so the quote for the same fraction of
        the vault is unchanged up to rounding: pricing state cannot be reset by LP flows."""
        rng = random.Random(6)
        for _ in range(300):
            c = cfg()
            v = rand_vault(rng)
            ref = rand_ref(rng)
            k = rng.choice([2, 3, 10])
            big = Vault(v.n0 * k, v.n1 * k, v.s * k)
            amt = rng.randint(1, 10_000) * E18
            try:
                a = quote_inventory(c, v.snap(), ref, False, amt).amount_out
                b = quote_inventory(c, big.snap(), ref, False, amt * k).amount_out
            except Revert:
                continue
            self.assertLessEqual(abs(b - a * k), 4 * k)

    def test_time_does_not_change_the_price(self):
        """C has no decay: with the same vault state and reference, the quote is the same at any time. Waiting does
        not restore inventory and does not cheapen an inventory-increasing trade."""
        c, v, ref = cfg(), Vault(10**6 * E18, 9 * 10**5 * E18, 10**6 * E18), Reference(Q96, 0)
        self.assertEqual(quote_inventory(c, v.snap(), ref, True, 1_000 * E18),
                         quote_inventory(c, v.snap(), ref, True, 1_000 * E18))


class SharedInventory(unittest.TestCase):
    """Two hooks over the same reserve."""

    def test_per_hook_state_lets_flow_through_two_hooks_double_the_vault_exposure(self):
        """Production Hook B: each pool has its own position, so a buyer can take each hook to its cap. The vault's
        real exposure is the sum, while each hook's price says "at the cap". With C both hooks read the same vault
        inventory, so the second hook is already at the cap."""
        V = 10**6 * E18
        hb = [HookB(), HookB()]
        for h in hb:
            h.configure(HookBConfig(Q96, V, 20_000, 3600), 0)
        sold = 0
        for h in hb:
            amt = position_cost(h.cfg.xmax, V, Q96) - E18
            sold += h.swap(True, amt, 0)
        self.assertGreater(sold, 19_000 * E18)  # about 2 x 9,852
        c = cfg(spread=2_000, dev=9_852 * PIPS // 1_000_000)
        v = Vault(10**6 * E18, 10**6 * E18, 10**6 * E18)
        ref = Reference(Q96, 0)
        total = 0
        for _hook in range(2):
            try:
                total += v.swap(c, ref, True, 9_000 * E18)
                total += v.swap(c, ref, True, 9_000 * E18)
            except Revert:
                pass
        _, _, t1 = inventory_state(c, v.snap())
        self.assertLessEqual(total, t1 * c.max_deviation // PIPS)

    def test_cross_hook_cycles_lose_with_different_spreads(self):
        """Hooks may quote different spreads around the same reference and inventory; buying from the tighter one and
        selling to the other still loses, because each quote straddles the reference."""
        rng = random.Random(7)
        for _ in range(300):
            v, ref = rand_vault(rng), rand_ref(rng)
            ca, cb = cfg(spread=300, min_edge=10), cfg(spread=3_000, min_edge=100)
            amt = rng.randint(1, 5_000) * E18
            n0 = v.n0
            try:
                got1 = v.swap(ca, ref, True, amt)
                v.swap(cb, ref, False, got1)
            except Revert:
                continue
            self.assertGreaterEqual(v.n0, n0)  # the vault ends with at least the currency0 it started with


class ReferenceFailClosed(unittest.TestCase):
    POL = ReferencePolicy(max_age=3600, max_divergence=10_000, secondary_max_age=86_400, missing_penalty=1_000)

    def test_stale_missing_divergent(self):
        p = FeedReading(Q96, 1_000)
        with self.assertRaises(Revert) as e:
            resolve_reference(FeedReading(0, 0), p, 2_000, self.POL)
        self.assertEqual(e.exception.name, "ReferenceUnavailable")
        with self.assertRaises(Revert) as e:
            resolve_reference(p, p, 1_000 + 3_601, self.POL)
        self.assertEqual(e.exception.name, "StaleReference")
        with self.assertRaises(Revert) as e:
            resolve_reference(p, FeedReading(Q96 * 102 // 100, 1_000), 1_500, self.POL)
        self.assertEqual(e.exception.name, "ReferenceDivergence")
        r = resolve_reference(p, None, 1_500, self.POL)
        self.assertEqual(r.uncertainty, 1_000)  # missing secondary widens, does not invent a price
        with self.assertRaises(Revert):
            resolve_reference(p, None, 1_500, ReferencePolicy(3600, 10_000, 86_400, require_secondary=True))
        with self.assertRaises(Revert):  # a timestamp from the future is not a fresh price
            resolve_reference(FeedReading(Q96, 2_000), p, 1_500, self.POL)

    def test_divergence_is_uncertainty(self):
        r = resolve_reference(FeedReading(Q96, 100), FeedReading(Q96 * 1003 // 1000, 100), 200, self.POL)
        self.assertEqual(r.uncertainty, 3_000)

    def test_manipulated_primary_is_refused_not_traded(self):
        """A primary pushed 3% from an honest secondary exceeds a 1% divergence limit: the hook refuses rather than
        quote around the manipulated mid. If both feeds are corrupted together nothing here detects it; the vault's
        floors and flow caps are then the bound (documented risk)."""
        with self.assertRaises(Revert):
            resolve_reference(FeedReading(Q96 * 103 // 100, 100), FeedReading(Q96, 100), 200, self.POL)


class LegacyRootCause(unittest.TestCase):
    """The reverse-trade refusal of the production Hook B, reduced to its mechanism."""

    def test_reverse_leg_is_above_reference_whenever_position_is_positive(self):
        V = 10**6 * E18
        for x in (1, 10**18, 500 * E18, 9_000 * E18):
            # Marginal price of the reverse leg exceeds the reference: (V/(V-x))^2 > 1, so any 1:1-pivot floor
            # refuses an exact reversal, and a spread fixes it only while (1-h)(V/(V-x))^2 <= 1.
            out = position_cost(x, V, Q96) - position_cost(0, V, Q96)
            self.assertFalse(floor_ok(x, out, Q96) and out > x)
            self.assertGreaterEqual(out, x)

    def test_d14_floors_cannot_bracket_the_market(self):
        """For any D14-consistent pair, the vault cannot both sell currency1 below the pivot and buy it above it."""
        rng = random.Random(8)
        for _ in range(1000):
            f0 = rng.randint(2**80, 2**110)
            f1 = mul_div_up(Q96, Q96, f0) + rng.randint(0, 2**60)
            self.assertGreaterEqual(f0 * f1, Q96 * Q96)
            # Vault buys currency1 at most 1/F0... no: sells currency0 for >= F0 currency1 each; sells currency1 for
            # >= F1 currency0 each. A round trip of one currency1 through both floors cannot gain currency0.
            self.assertGreaterEqual(f1 * f0 // Q96, Q96 - 1)

    def test_two_sided_curve_with_spread_reverse_boundary(self):
        """B: a reverse leg passes 1:1 floors exactly while the accumulated curve premium stays below the spread."""
        V = 10**6 * E18
        c = TwoSidedCurve(TwoSidedCurveConfig(Q96, V, 20_000, 0, 3_000))
        got, x2 = c.quote(True, 1_000 * E18, 0)
        c.commit(x2, 0)
        out, _ = c.quote(False, 100 * E18, 0)
        self.assertTrue(floor_ok(100 * E18, out, Q96))  # premium ~0.2% < 0.3%
        got, x2 = c.quote(True, 4_000 * E18, 0)
        c.commit(x2, 0)
        out, _ = c.quote(False, 100 * E18, 0)
        self.assertFalse(floor_ok(100 * E18, out, Q96))  # premium ~1% > 0.3%


class ValueTargetCounterexample(unittest.TestCase):
    """Rejected alternative: measuring the deviation against a *value* target theta * (N_1 + N_0 / M) instead of a
    per-share unit target. Every trade then moves the target by theta times the spread it earned, so the state does
    not move by exactly the traded amount; for the vault's bid this lets a split be paid more than one trade."""

    def test_split_gains_under_value_target(self):
        P = Q96
        V = 10**8 * E18

        def i_val(n0, n1):  # theta = 1/2: target currency1 = (N_1 + N_0 * P / Q96) / 2
            return (n1 + n0 * P // Q96) // 2 - n1

        def bid(n0, n1, q, h=3_000):
            i = i_val(n0, n1)
            cap = 10**7 * E18
            g = ext_cost(i, V, P, cap) - ext_cost(i - q, V, P, cap)
            return g * (PIPS - h) // PIPS

        n0 = n1 = 10**6 * E18  # balanced: the vault's bid is below the reference, so the leak has a positive sign
        total = 100_000 * E18
        single = bid(n0, n1, total)
        a0, a1, got = n0, n1, 0
        for _ in range(100):
            o = bid(a0, a1, total // 100)
            got += o
            a0, a1 = a0 - o, a1 + total // 100
        self.assertGreater(got, single, "the counterexample: the split is paid more")
        self.split_gain = got - single


class Extremes(unittest.TestCase):
    def test_dust_and_maximum(self):
        c, v, ref = cfg(), Vault(10**6 * E18, 10**6 * E18, 10**6 * E18), Reference(Q96, 0)
        with self.assertRaises(Revert):
            quote_inventory(c, v.snap(), ref, True, 0)
        with self.assertRaises(Revert):
            quote_inventory(c, v.snap(), ref, True, MAX_AMOUNT + 1)
        for zfo in (True, False):
            with self.assertRaises(Revert) as e:
                quote_inventory(c, v.snap(), ref, zfo, MAX_AMOUNT)
            self.assertEqual(e.exception.name, "InventoryLimit")
            # 1 wei pays nothing out (refused as ZeroOutput) rather than rounding in the trader's favour.
            with self.assertRaises(Revert) as e:
                quote_inventory(c, v.snap(), ref, zfo, 1)
            self.assertEqual(e.exception.name, "ZeroOutput")

    def test_mixed_decimals_usdc_weth(self):
        """currency0 = 6-decimal stable, currency1 = 18-decimal asset at 3,000 stable per asset. Raw price =
        (1/3,000) * 10^18 / 10^6 currency1 per currency0. The straddle and the floors must hold on raw units."""
        p = Q96 * 10**12 // 3_000
        ref = Reference(p, 500)
        n0, n1 = 3_000_000 * E6, 1_000 * E18
        s = n1  # shares: any scale; tau = N_1 / S
        c = cfg(tau=WAD)
        v = Vault(n0, n1, s)
        f0, f1 = floors_from_pivot(p)
        rng = random.Random(9)
        for _ in range(500):
            zfo = rng.random() < 0.5
            amt = rng.randint(1, 50_000) * E6 if zfo else rng.randint(1, 20) * E18 // rng.randint(1, 100)
            try:
                q = quote_inventory(c, v.snap(), ref, zfo, amt)
            except Revert:
                continue
            self.assertTrue(floor_ok(amt, q.amount_out, f1 if zfo else f0))

    def test_overflow_envelope(self):
        """Largest intermediate products of the C formulas under the documented bounds (V <= 2^95 - 1, |I| within the
        cap or up to V, P < 2^160, amounts < 2^127): the Solidity needs each product below 2^512 for FullMath and
        each FullMath result below 2^256."""
        V, P, cap = 2**95 - 1, 2**160 - 1, (2**95 - 1) * 3 // 10
        # linear extension numerator: V * Q96 * (c (V - c) + (I - c) V) with I up to 2^127 (worst trade size)
        num = V * Q96 * (cap * (V - cap) + (2**127) * V)
        den = 1 * (V - cap) ** 2
        self.assertLess(num.bit_length(), 512)
        self.assertLess(den.bit_length(), 256)
        self.assertLess((P * (V + cap) ** 2).bit_length(), 352)  # needs mulDiv in two steps in Solidity (see spec)
        self.assertLess(straddle_cap(V, 50_000, 0), V)


class InversionExact(unittest.TestCase):
    def test_ext_position_for_cost_is_exact_inverse(self):
        rng = random.Random(10)
        for _ in range(2000):
            V = rng.randint(10**3, 10**9) * E18
            P = int(rng.uniform(0.1, 10) * Q96)
            cap = straddle_cap(V, rng.choice([500, 2_000]), 100)
            lo = ext_cost(-cap - rng.randint(0, V // 2), V, P, cap)
            hi = ext_cost(cap + 1, V, P, cap) - 1
            t = rng.randint(lo, hi)
            i = ext_position_for_cost(t, V, P, cap)
            self.assertLessEqual(ext_cost(i, V, P, cap), t)
            self.assertGreater(ext_cost(i + 1, V, P, cap), t)


class SolidityFormEquivalence(unittest.TestCase):
    """The specification's Solidity forms of the linear extension (two FullMath steps, every operand and result below
    2^256) must equal the model's single-step integers exactly, so that one set of vectors serves both. The identity
    used: for positive integers, ceil(ceil(x / d1) / d2) = ceil(x / (d1 d2)) and the same with floor."""

    @staticmethod
    def pos_two_step(i, V, P, c):  # I > c:  ceil(ceil((I V - c^2) * (V Q96) / (V - c)^2) / P)
        a, b, d1 = i * V - c * c, V * Q96, (V - c) ** 2
        assert a < 2**256 and b < 2**256 and d1 < 2**256
        y = -(-a * b // d1)
        assert y < 2**256
        return -(-y // P)

    @staticmethod
    def neg_two_step(i, V, P, c):  # I < -c: -floor(floor((|I| V + c^2) * (V Q96) / (V + c)^2) / P)
        a, b, d1 = -i * V + c * c, V * Q96, (V + c) ** 2
        assert a < 2**256 and b < 2**256 and d1 < 2**256
        y = a * b // d1
        assert y < 2**256
        return -(y // P)

    @staticmethod
    def neg_inverse_two_step(t, V, P, c):  # largest I with C_ext(I) <= t, t < C_hat(-c)
        a, b, d = -t * P, (V + c) ** 2, V * Q96
        assert a < 2**256 and b < 2**256 and d < 2**256
        z = -(-a * b // d)  # ceil(|t| P (V + c)^2 / (Q96 V))
        assert z < 2**256
        return -(-(-(z - c * c) // V))

    def test_two_step_forms_match_the_model(self):
        rng = random.Random(11)
        for _ in range(3000):
            V = rng.randint(10**3, 2**95 - 1)
            P = rng.randint(2**40, 2**160 - 1)
            c = straddle_cap(V, rng.choice([300, 2_000, 50_000]), rng.choice([0, 100]))
            if c == 0:
                continue
            ip = rng.randint(c + 1, 2**127 - 1)
            self.assertEqual(self.pos_two_step(ip, V, P, c), ext_cost(ip, V, P, c))
            ineg = -rng.randint(c + 1, 2**127 - 1)
            self.assertEqual(self.neg_two_step(ineg, V, P, c), ext_cost(ineg, V, P, c))
            t = ext_cost(ineg, V, P, c) + rng.randint(0, 3)
            if t < ext_cost(-c, V, P, c):
                self.assertEqual(self.neg_inverse_two_step(t, V, P, c), ext_position_for_cost(t, V, P, c))


if __name__ == "__main__":
    unittest.main()
