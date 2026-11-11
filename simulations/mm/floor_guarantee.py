"""Stateful adversarial model of the vault's inventory floor (Phase 1B-4.3, Task 1).

Exact integer model of every path in `SharedCommitmentVault` that changes N_a = B_a - W_a or S:
initial deposit, deposit (ceil), instant redeem (floor), queue + finalization (floor), claim, request cancellation and
`exchange`. The adversary controls the price of every `exchange` completely, which is what a malicious or corrupted
market-risk adapter can do: the dynamic floor is computed from its price, so it can be made ~0.

Claims checked (SYNTHETIC adversary, exact arithmetic):

  T1 (per-share depletion). For every asset a and every pair of times t0 <= t1 during which the floor parameters do not
     loosen:  N_a(t1)/S(t1) >= min(N_a(t0)/S(t0), l_a), where l_a = tau_a (1 - kappa_a) is the per-share floor.
  T2 (economic shortfall). An LP holding s shares from t0 to t1 is paid, at t1, a basket whose value at ANY price vector
     p is at least  s * sum_a min(h_a(t0), l_a) p_a  - 2 raw units of rounding.  So its shortfall against holding the
     entry basket is at most  s * sum_a (h_a(t0) - l_a)^+ p_a.
  T3 is what is NOT claimed: that the shortfall is at most kappa of the entry value. It is not; see `ce_*`.

Run:  python3 simulations/mm/floor_guarantee.py      (prints the search summary; ~20 s)
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field
from fractions import Fraction as Fr

PIPS = 1_000_000
WAD = 10**18
MIN_SHARES = 1000


def ceil_div(a: int, b: int) -> int:
    return -(-a // b)


def inventory_floor(shares: int, target: int, tol: int) -> int:
    """VaultRiskBoundary.inventoryFloor: ceil(shares * target * (1e6 - tol) / (1e18 * 1e6))."""
    return ceil_div(shares * target * (PIPS - tol), WAD * PIPS)


@dataclass
class Tranche:
    """Shares an LP bought at one time, with the per-share basket at entry (exact rationals)."""
    lp: int
    shares: int
    h0: Fr
    h1: Fr
    floor_min0: Fr  # lowest per-share floor in force since entry (tracks governance changes)
    floor_min1: Fr


@dataclass
class Request:
    lp: int
    pending: int
    c0: int = 0
    c1: int = 0
    tranches: list = field(default_factory=list)  # (Tranche, shares) escrowed in this request
    canceled: bool = False


class Vault:
    def __init__(self, a0: int, a1: int, target0: int, target1: int, tol0: int, tol1: int, floor_on_trades=True):
        root = int((a0 * a1) ** 0.5)
        while root * root > a0 * a1:
            root -= 1
        while (root + 1) * (root + 1) <= a0 * a1:
            root += 1
        assert root > MIN_SHARES
        self.B = [a0, a1]
        self.W = [0, 0]
        self.Q = [0, 0]
        self.S = root
        self.P = 0
        self.target = [target0, target1]
        self.tol = [tol0, tol1]
        self.floor_on_trades = floor_on_trades
        self.requests: list[Request] = []
        self.head = 0
        self.free: dict[int, list[Tranche]] = {}
        self.violations: list[str] = []
        self.payouts: list[tuple[Tranche, int, int, int]] = []  # (tranche, shares, paid0, paid1)
        self._add_tranche(0, root - MIN_SHARES)

    # -- derived quantities ------------------------------------------------------------------------------------
    def N(self, a: int) -> int:
        return self.B[a] - self.W[a]

    def h(self, a: int) -> Fr:
        return Fr(self.N(a), self.S)

    def ell(self, a: int) -> Fr:
        return Fr(self.target[a] * (PIPS - self.tol[a]), WAD * PIPS)

    def _add_tranche(self, lp: int, shares: int):
        t = Tranche(lp, shares, self.h(0), self.h(1), self.ell(0), self.ell(1))
        self.free.setdefault(lp, []).append(t)

    def _take_tranches(self, lp: int, shares: int) -> list:
        out, left = [], shares
        lst = self.free.get(lp, [])
        while left:
            t = lst[0]
            take = min(left, t.shares)
            out.append((t, take))
            t.shares -= take
            left -= take
            if t.shares == 0:
                lst.pop(0)
        return out

    def shares_of(self, lp: int) -> int:
        return sum(t.shares for t in self.free.get(lp, []))

    def _snapshot(self):
        return (self.h(0), self.h(1))

    def _check_monotone(self, before, op: str, traded_out: int | None):
        for a in (0, 1):
            hb, ha = before[a], self.h(a)
            if a == traded_out and self.floor_on_trades:
                if ha < min(hb, self.ell(a)):
                    self.violations.append(f"{op}: asset{a} per-share {float(ha):.6g} < min(before, floor)")
            elif a != traded_out and ha < hb:
                self.violations.append(f"{op}: asset{a} per-share fell without a trade ({float(hb)} -> {float(ha)})")

    # -- LP paths (mirror the Solidity rounding) ---------------------------------------------------------------
    def deposit(self, lp: int, shares: int):
        before = self._snapshot()
        amts = [ceil_div(shares * self.N(a), self.S) for a in (0, 1)]
        self.S += shares
        for a in (0, 1):
            self.B[a] += amts[a]
        self._check_monotone(before, "deposit", None)
        self._add_tranche(lp, shares)

    def _deliverable(self) -> int:
        cap = self.S
        for a in (0, 1):
            n, f = self.N(a), self.N(a) - self.Q[a]
            if n == 0:
                continue
            # largest s with floor(s n / S) <= f
            s = ((f + 1) * self.S - 1) // n
            cap = min(cap, s)
        return max(cap, 0)

    def redeem(self, lp: int, shares: int, queue: bool = True):
        bal = self.shares_of(lp)
        shares = min(shares, bal)
        if shares == 0:
            return
        if self.P:
            self.process(4)
        before = self._snapshot()
        instant = 0
        if self.P == 0:
            instant = min(shares, self._deliverable())
            if instant:
                amts = [instant * self.N(a) // self.S for a in (0, 1)]
                if amts == [0, 0]:
                    instant = 0
        rem = shares - instant
        if rem and not queue:
            return
        taken = self._take_tranches(lp, shares)
        if instant:
            amts = [instant * self.N(a) // self.S for a in (0, 1)]
            self.S -= instant
            for a in (0, 1):
                self.B[a] -= amts[a]
            self._record(taken, instant, amts)
            taken = self._consume(taken, instant)
        if rem:
            self.P += rem
            self.requests.append(Request(lp, rem, tranches=taken))
        self._check_monotone(before, "redeem", None)

    def _consume(self, taken, n):
        out, left = [], n
        for t, s in taken:
            if left >= s:
                left -= s
                continue
            out.append((t, s - left))
            left = 0
        return out

    def _record(self, taken, n, amts):
        """Split a payout of n shares across the tranches it came from, pro rata (for the T2 check)."""
        left = n
        for t, s in taken:
            if left == 0:
                break
            k = min(s, left)
            self.payouts.append((t, k, amts[0] * k / n, amts[1] * k / n))
            left -= k

    def process(self, steps: int):
        before = self._snapshot()
        while steps and self.head < len(self.requests):
            r = self.requests[self.head]
            if r.canceled or r.pending == 0:
                self.head += 1
                steps -= 1
                continue
            s = min(r.pending, self._deliverable())
            if s == 0:
                break
            e = [s * self.N(a) // self.S for a in (0, 1)]
            if e == [0, 0] and s < r.pending:
                break
            r.pending -= s
            self.P -= s
            self.S -= s
            for a in (0, 1):
                self.W[a] += e[a]
            r.c0 += e[0]
            r.c1 += e[1]
            self._record(r.tranches, s, e)
            r.tranches = self._consume(r.tranches, s)
            steps -= 1
            if r.pending:
                break
            self.head += 1
        self._check_monotone(before, "process", None)

    def claim(self, i: int):
        r = self.requests[i]
        before = self._snapshot()
        for a, c in ((0, r.c0), (1, r.c1)):
            self.W[a] -= c
            self.B[a] -= c
        r.c0 = r.c1 = 0
        self._check_monotone(before, "claim", None)

    def cancel(self, i: int):
        r = self.requests[i]
        if r.canceled or r.pending == 0:
            return
        self.P -= r.pending
        for t, s in r.tranches:
            self.free.setdefault(r.lp, []).insert(0, Tranche(r.lp, s, t.h0, t.h1, t.floor_min0, t.floor_min1))
        r.pending = 0
        r.tranches = []
        r.canceled = True

    # -- trading ----------------------------------------------------------------------------------------------
    def exchange(self, out: int, amount_out: int, amount_in: int) -> bool:
        """Any price: the adversary picks amount_in freely (a corrupted adapter can make the dynamic floor ~0)."""
        n = self.N(out)
        if amount_out == 0 or amount_out > n - self.Q[out] + self.Q[out]:
            return False
        if self.floor_on_trades and self.target[out]:
            if n - amount_out < inventory_floor(self.S, self.target[out], self.tol[out]):
                return False
        before = self._snapshot()
        self.B[out] -= amount_out
        self.B[1 - out] += amount_in
        self._check_monotone(before, "exchange", out)
        return True

    def max_out(self, out: int) -> int:
        n = self.N(out)
        if not (self.floor_on_trades and self.target[out]):
            return n
        return max(0, n - inventory_floor(self.S, self.target[out], self.tol[out]))

    def set_bounds(self, target0, target1, tol0, tol1):
        self.target, self.tol = [target0, target1], [tol0, tol1]
        for lst in self.free.values():
            for t in lst:
                t.floor_min0 = min(t.floor_min0, self.ell(0))
                t.floor_min1 = min(t.floor_min1, self.ell(1))
        for r in self.requests:
            for t, _ in r.tranches:
                t.floor_min0 = min(t.floor_min0, self.ell(0))
                t.floor_min1 = min(t.floor_min1, self.ell(1))

    # -- T2: economic check at exit ------------------------------------------------------------------------------
    def t2_report(self, prices: list[tuple[float, float]]):
        """Worst ratio shortfall / bound over all payouts and price vectors; and worst shortfall / entry value."""
        worst_ratio, worst_frac, breaches = 0.0, 0.0, 0
        self.worst_deficit = 0.0  # largest (guaranteed - paid) in raw units, i.e. rounding against the LP
        for t, s, p0, p1 in self.payouts:
            g0, g1 = min(t.h0, t.floor_min0), min(t.h1, t.floor_min1)
            for q0, q1 in prices:
                entry = float(s * t.h0) * q0 + float(s * t.h1) * q1
                paid = p0 * q0 + p1 * q1
                guaranteed = float(s * g0) * q0 + float(s * g1) * q1
                bound = entry - guaranteed
                short = entry - paid
                if paid < guaranteed - 2 * (q0 + q1):  # 1 raw unit of rounding per asset per payout, x2 margin
                    breaches += 1
                if q0 + q1 > 0:
                    self.worst_deficit = max(self.worst_deficit, (guaranteed - paid) / max(q0, q1))
                # Ratios are only meaningful when the bound is well above rounding (1 raw unit per asset).
                if bound > 1_000 * (q0 + q1):
                    worst_ratio = max(worst_ratio, short / bound)
                if entry > 0 and s > 10_000:
                    worst_frac = max(worst_frac, short / entry)
        return worst_ratio, worst_frac, breaches


# ---------------------------------------------------------------------------------------------------------------
# Adversaries
# ---------------------------------------------------------------------------------------------------------------

PRICES = [(1.0, 1.0), (1.0, 0.0), (0.0, 1.0), (3.0, 1.0), (1.0, 3.0), (1.0, 0.5)]  # incl. depeg of either asset


def fresh(kappa=50_000, scale=10**6, floor_on_trades=True) -> Vault:
    a0, a1 = 1_000 * scale, 1_000 * scale  # equal raw amounts; S = 1e9 shares when scale = 1e6
    v = Vault(a0, a1, 0, 0, 0, 0, floor_on_trades)
    # target per share = current holding per share (WAD), i.e. the vault starts at its target
    v.set_bounds(a0 * WAD // v.S, a1 * WAD // v.S, kappa, kappa)
    for t in v.free[0]:
        t.floor_min0, t.floor_min1 = v.ell(0), v.ell(1)
    return v


def random_run(seed: int, steps: int = 400, kappa: int = 50_000, honest_fee_pips: int = 3_000) -> Vault:
    rng = random.Random(seed)
    v = fresh(kappa)
    lps = [0, 1, 2, 3]
    for _ in range(steps):
        op = rng.random()
        lp = rng.choice(lps)
        if op < 0.18:
            v.deposit(lp, rng.randint(1, v.S // 3 + 1))
        elif op < 0.33:
            bal = v.shares_of(lp)
            if bal:
                v.redeem(lp, rng.randint(1, bal), queue=rng.random() < 0.8)
        elif op < 0.40:
            v.process(rng.randint(1, 6))
        elif op < 0.45 and v.requests:
            v.claim(rng.randrange(len(v.requests)))
        elif op < 0.48 and v.requests:
            v.cancel(rng.randrange(len(v.requests)))
        elif op < 0.55:
            # commitments: reserve part of N (affects only instant-exit availability)
            for a in (0, 1):
                v.Q[a] = rng.randint(0, v.N(a)) if rng.random() < 0.5 else 0
        elif op < 0.80:
            # adversarial fill at an arbitrary price: take as much as allowed, pay almost nothing (or a random amount)
            out = rng.randrange(2)
            x = v.max_out(out)
            if x:
                if rng.random() < 0.7:
                    x = rng.randint(1, x)
                pay = 0 if rng.random() < 0.6 else rng.randint(0, x * 2)
                v.exchange(out, x, pay)
        else:
            # honest flow at price 1 with a fee: refills the asset the adversary drained
            out = rng.randrange(2)
            x = rng.randint(0, v.max_out(out))
            if x:
                v.exchange(out, x, ceil_div(x * (PIPS + honest_fee_pips), PIPS))
    # everyone exits as far as possible at the end
    for lp in lps:
        bal = v.shares_of(lp)
        if bal:
            v.redeem(lp, bal)
    for i in range(len(v.requests)):
        v.Q = [0, 0]
        v.process(10)
        v.claim(i)
    return v


def hill_climb(seed: int, iters: int = 150) -> float:
    """Mutate a sequence of drain / replenish / deposit / redeem actions to maximise shortfall / bound."""
    rng = random.Random(seed)
    acts = ["drain0", "drain1", "honest0", "honest1", "dep", "red", "proc", "flash"]

    def play(seq):
        v = fresh()
        for a in seq:
            if a == "drain0" or a == "drain1":
                out = int(a[-1])
                x = v.max_out(out)
                if x:
                    v.exchange(out, x, 0)
            elif a.startswith("honest"):
                out = int(a[-1])
                x = v.max_out(out) // 2
                if x:
                    v.exchange(out, x, x)
            elif a == "dep":
                v.deposit(1, v.S // 2)
            elif a == "red":
                b = v.shares_of(1)
                if b:
                    v.redeem(1, b)
            elif a == "proc":
                v.process(5)
            elif a == "flash":  # deposit, drain both, redeem in the same "transaction"
                v.deposit(2, v.S)
                for out in (0, 1):
                    x = v.max_out(out)
                    if x:
                        v.exchange(out, x, 0)
                b = v.shares_of(2)
                if b:
                    v.redeem(2, b)
        for lp in (0, 1, 2):
            b = v.shares_of(lp)
            if b:
                v.redeem(lp, b)
        v.Q = [0, 0]
        for i in range(len(v.requests)):
            v.process(10)
            v.claim(i)
        ratio, _, breaches = v.t2_report(PRICES)
        return ratio, breaches, v.violations

    best = [rng.choice(acts) for _ in range(12)]
    best_score, breaches, viol = play(best)
    assert not breaches and not viol, (breaches, viol)
    for _ in range(iters):
        cand = list(best)
        i = rng.randrange(len(cand))
        cand[i] = rng.choice(acts)
        if rng.random() < 0.3:
            cand.insert(rng.randrange(len(cand)), rng.choice(acts))
        score, breaches, viol = play(cand)
        assert not breaches and not viol, (cand, breaches, viol)
        if score >= best_score:
            best, best_score = cand, score
    return best_score


# ---------------------------------------------------------------------------------------------------------------
# Counterexamples to the stronger claims (each one is a design correction, not a breach of T1/T2)
# ---------------------------------------------------------------------------------------------------------------

def ce_fee_accrual(kappa=50_000) -> float:
    """Honest fees push holdings above target; the room above the fixed floor then exceeds kappa of holdings."""
    v = fresh(kappa)
    for _ in range(40):  # honest round trips at a 1% fee grow both holdings
        for out in (0, 1):
            x = v.N(out) // 50
            v.exchange(out, x, x + x // 100)
    entry = float(v.h(0) + v.h(1))
    for out in (0, 1):
        v.exchange(out, v.max_out(out), 0)
    return 1 - float(v.h(0) + v.h(1)) / entry  # fraction of value lost, at p = (1, 1)


def ce_skewed_composition(kappa=50_000) -> float:
    """Honest flow leaves the vault heavy in asset0 (asset1 at its floor); room in asset0 is then far above kappa."""
    v = fresh(kappa)
    x = v.max_out(1)
    v.exchange(1, x, x)  # vault sold asset1 down to its floor at a fair price, holds more asset0
    entry0 = v.N(0)
    lost = v.max_out(0)
    return lost / entry0  # fraction of the asset0 holding extractable


def ce_loosen_bounds_immediately(kappa=50_000) -> float:
    """An owner who may lower tau or raise kappa at once opens the whole reserve: the floor is only as good as its
    governance."""
    v = fresh(kappa)
    v.set_bounds(0, 0, kappa, kappa)  # target 0 -> floor 0
    start = v.N(0) + v.N(1)
    for out in (0, 1):
        v.exchange(out, v.max_out(out), 0)
    return 1 - (v.N(0) + v.N(1)) / start


def ce_static_mode_without_floor(kappa=50_000) -> float:
    """The Phase 1B-4.2 patch applied the inventory floor only while an adapter was installed. A stale or wrong static
    floor after the adapter is removed then has no inventory backstop."""
    v = fresh(kappa, floor_on_trades=False)
    start = v.N(0) + v.N(1)
    v.exchange(0, v.N(0), 0)
    return 1 - (v.N(0) + v.N(1)) / start


def ce_queued_lp_cannot_escape(kappa=50_000) -> str:
    """A loosening announced with a delay protects only LPs who can actually leave within the delay. Queued shares stay
    in S and keep bearing losses until finalized, and finalization waits for free inventory (allocations may hold it up
    to MAX_HORIZON = 30 days)."""
    v = fresh(kappa)
    v.deposit(1, v.S)
    v.Q = [v.N(0), v.N(1)]  # everything committed to allocations
    v.redeem(1, v.shares_of(1))
    queued = v.P
    v.set_bounds(0, 0, kappa, kappa)  # the delayed loosening takes effect while the LP is still queued
    v.exchange(0, v.max_out(0), 0)
    v.Q = [0, 0]
    v.process(10)
    r = v.requests[0]
    return f"queued {queued} shares; finalized at {r.c0} asset0 + {r.c1} asset1 (entry about {queued} of each)"


def main():
    import time

    t = time.time()
    worst_ratio = worst_frac = 0.0
    total_breaches = 0
    total_viol = 0
    n_payouts = 0
    deficit = 0.0
    for seed in range(300):
        v = random_run(seed)
        r, f, b = v.t2_report(PRICES)
        deficit = max(deficit, v.worst_deficit)
        worst_ratio, worst_frac = max(worst_ratio, r), max(worst_frac, f)
        total_breaches += b
        total_viol += len(v.violations)
        n_payouts += len(v.payouts)
    hc = max(hill_climb(s) for s in range(12))
    print("# Inventory-floor guarantee: stateful adversarial search (SYNTHETIC, exact integers)\n")
    print(f"random sequences: 300 x 400 steps; payouts checked: {n_payouts}; price vectors per payout: {len(PRICES)}")
    print(f"T1 violations (per-share holding fell below min(previous, floor)): {total_viol}")
    print(f"T2 breaches (paid < guaranteed basket - 2 units): {total_breaches}")
    print(f"largest rounding deficit against an LP (guaranteed - paid): {deficit:.3f} raw units of the dearer asset")
    print(f"worst shortfall / T2 bound (bounds > 1,000 units), random: {worst_ratio:.6f}; hill-climbed: {hc:.6f}")
    print(f"worst shortfall / entry value, random (kappa 5%): {worst_frac:.4f}  <- exceeds kappa: T3 is false")
    print()
    print("Counterexamples to stronger claims (kappa 5%):")
    print(f"  fee accrual then drain: value lost {ce_fee_accrual():.4f} of the post-fee value (> 0.05)")
    print(f"  skewed composition: {ce_skewed_composition():.4f} of the asset0 holding extractable (> 0.05)")
    print(f"  owner loosens tau immediately: {ce_loosen_bounds_immediately():.4f} of the reserve extractable")
    print(f"  static mode without the inventory floor: {ce_static_mode_without_floor():.4f} extractable")
    print(f"  queued LP during a delayed loosening: {ce_queued_lp_cannot_escape()}")
    print(f"\n({time.time() - t:.1f} s)")


if __name__ == "__main__":
    main()
