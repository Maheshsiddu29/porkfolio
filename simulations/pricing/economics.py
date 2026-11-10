"""Synthetic economic comparison of the replaced (per-swap) and the cumulative pricing, on identical generated trade
sequences. Run from the repository root:  python3 simulations/pricing/economics.py

SYNTHETIC ONLY. Every trade, size, arrival time and market price below is generated from the stated distributions
with fixed seeds. Nothing here is historical Uniswap data, and the results say nothing about real fee income or LP
returns. They compare two pricing rules under the same assumptions, nothing more.

Model
-----
- One vault pool per hook, 18-decimal tokens, hook reference price P = 1 (1:1), vault floors 1:1 in both directions
  (as in the test fixture), so the vault refuses any trade priced below 1:1 for it.
- Order flow: exact-input orders with lognormal sizes and exponential inter-arrival times; direction persistence and
  size mixture vary by regime. "Splitters" divide an order into n equal pieces in one transaction.
- Market price M (currency0 per currency1) is P in the static regimes and drifts or jumps in the stale regimes, where a
  greedy arbitrageur trades whenever a trade is profitable at M, in 1,000-token pieces (old rules: splitting lowers its
  cost) or, for the new Hook B, straight to the curve point where the marginal price meets M or the cap.
- Old rules (HookA/HookB before this change) price against an allocation of 10,000 tokens per direction. The curator
  opens a fresh one after 24 h, or whenever an order fails on quota or on the per-swap impact cap (the allocation
  shopping the old rules allowed); the order then retries once.
- The vault holds 1,000,000 tokens of each asset at the start and cannot pay out more than it holds. No vault flow
  limits are modelled; in the contracts they would bound the stale-price losses further. New rules use the fixture parameters (Hook A: 5 -> 50 bps over K = 10,000,
  decay 1 h; Hook B: depth 1,000,000, 2% cap, decay 1 h). Pricing variants share identical sequences.
- Valuation: each fill is valued at the market price at that moment. LP revenue = value received - value paid. The
  trader's execution cost is the same number with the opposite sign, so it is reported once. Inventory is the vault's
  net change in currency1 (positive: it sold currency1).
"""

from __future__ import annotations

import math
import os
import random
import sys
import zlib
from dataclasses import dataclass, field

sys.path.insert(0, os.path.dirname(__file__))

from cumulative import (  # noqa: E402
    Q96,
    HookA,
    HookAConfig,
    HookB,
    HookBConfig,
    Revert,
    floor_ok,
    max_position,
    old_hook_a_out,
    old_hook_b_out,
    position_cost,
)

E18 = 10**18
QUOTA = 10_000 * E18
REFRESH = 86_400


@dataclass
class Order:
    t: int
    zfo: bool  # trader sells currency0, buys currency1
    amount: int
    pieces: int
    market: float  # currency0 per currency1 at time t


@dataclass
class Regime:
    name: str
    n: int = 4000
    persist: float = 0.5  # probability the next order has the previous direction
    median: float = 400.0  # tokens
    sigma: float = 1.0
    whale_p: float = 0.0
    whale_median: float = 8000.0
    split_p: float = 0.0
    split_n: tuple = (5, 10)
    mean_gap: float = 180.0
    drift_per_hour: float = 0.0  # market log-price volatility per hour
    jump_at: float | None = None  # fraction of the run when a market jump happens
    jump: float = 0.0
    arb: bool = False


REGIMES = [
    Regime("balanced"),
    Regime("one-sided (80% one way)", persist=0.8),
    Regime("whales (5% x 8,000 median)", whale_p=0.05),
    Regime("splitters (50% split 5-10)", split_p=0.5),
    Regime("stale drift + arbitrage", drift_per_hour=0.004, arb=True),
    Regime("stale jump +2% + arbitrage", jump_at=0.3, jump=0.02, arb=True),
]
SEEDS = (11, 22, 33)


def generate(reg: Regime, seed: int) -> list[Order]:
    rng = random.Random(seed * 7919 + zlib.crc32(reg.name.encode()))  # str hash() is salted per process
    out, t, zfo, logm = [], 0, rng.random() < 0.5, 0.0
    for i in range(reg.n):
        gap = int(rng.expovariate(1 / reg.mean_gap)) + 1
        t += gap
        if reg.drift_per_hour:
            logm += rng.gauss(0, reg.drift_per_hour * math.sqrt(gap / 3600))
        if reg.jump_at is not None and i == int(reg.jump_at * reg.n):
            logm += math.log1p(reg.jump)
        zfo = zfo if rng.random() < reg.persist else not zfo
        med = reg.whale_median if rng.random() < reg.whale_p else reg.median
        size = max(1.0, rng.lognormvariate(math.log(med), reg.sigma))
        pieces = rng.choice(reg.split_n) if rng.random() < reg.split_p else 1
        out.append(Order(t, zfo, int(size * E18), pieces, math.exp(logm)))
    return out


# ------------------------------------------------------------------------------------------------------------------
# Pricing engines with a common interface: quote(zfo, amount, t) -> out, commit(...)
# ------------------------------------------------------------------------------------------------------------------


class OldEngine:
    """Per-swap pricing against a refreshed allocation per direction (the replaced HookA / HookB)."""

    def __init__(self, kind: str):
        self.kind = kind
        self.consumed = {True: 0, False: 0}
        self.opened = {True: 0, False: 0}
        self.refreshes = 0

    def _refresh_if_due(self, zfo, t):
        if t - self.opened[zfo] >= REFRESH:
            self.consumed[zfo], self.opened[zfo] = 0, t
            self.refreshes += 1

    def swap(self, zfo: bool, amount: int, t: int) -> int:
        self._refresh_if_due(zfo, t)
        for attempt in range(2):
            c = self.consumed[zfo]
            try:
                if self.kind == "A":
                    out = old_hook_a_out(Q96, 500, 5000, zfo, amount, c, QUOTA)
                else:
                    out = old_hook_b_out(Q96, 10_000, 20_000, zfo, amount, c, QUOTA)
                if out > QUOTA - c:
                    raise Revert("QuotaExceeded")
                break
            except Revert:
                if attempt == 1:
                    raise
                # The curator opens a fresh allocation and the order retries once.
                self.consumed[zfo], self.opened[zfo] = 0, t
                self.refreshes += 1
        if out == 0:
            raise Revert("ZeroOutput")
        if not floor_ok(amount, out, Q96):
            raise Revert("PriceBelowFloor")
        self.consumed[zfo] += out
        return out


class NewEngine:
    def __init__(self, kind: str, a_cfg: HookAConfig | None = None, b_cfg: HookBConfig | None = None):
        self.kind = kind
        if kind == "A":
            self.h = HookA()
            self.h.configure(a_cfg or HookAConfig(Q96, 500, 5000, 10_000 * E18, 10_000 * E18, 3600), 0)
        else:
            self.h = HookB()
            self.h.configure(b_cfg or HookBConfig(Q96, 10**6 * E18, 20_000, 3600), 0)

    def swap(self, zfo: bool, amount: int, t: int) -> int:
        out = self.h.quote(zfo, amount, t)[0]
        if out == 0:
            raise Revert("ZeroOutput")
        if not floor_ok(amount, out, Q96):
            raise Revert("PriceBelowFloor")
        self.h.swap(zfo, amount, t)
        return out


# ------------------------------------------------------------------------------------------------------------------
# Simulation
# ------------------------------------------------------------------------------------------------------------------


@dataclass
class Result:
    bal0: int = 1_000_000 * E18  # vault inventory
    bal1: int = 1_000_000 * E18
    attempted: int = 0
    filled: int = 0
    notional: float = 0.0  # tokens, at market
    revenue: float = 0.0  # LP revenue at market, tokens of currency0
    inv1: float = 0.0  # net currency1 sold by the vault, tokens
    max_abs_inv1: float = 0.0
    arb_revenue: float = 0.0  # LP revenue from arbitrage fills only (negative = loss)
    split_orders: int = 0
    split_discount: float = 0.0  # sum over split orders of (single-trade cost - split cost), tokens
    reasons: dict = field(default_factory=dict)


def _value(zfo: bool, amt_in: int, amt_out: int, m: float) -> float:
    """LP revenue of one fill at market m (currency0 per currency1), tokens of currency0."""
    if zfo:  # vault receives currency0, pays currency1
        return amt_in / E18 - amt_out / E18 * m
    return amt_in / E18 * m - amt_out / E18


def _fill(engine, res: Result, zfo, amount, t, m, arb=False) -> int | None:
    snap = _snapshot(engine)
    try:
        out = engine.swap(zfo, amount, t)
        if out > (res.bal1 if zfo else res.bal0):
            _restore(engine, snap)
            raise Revert("InsufficientInventory")
    except Revert as e:
        res.reasons[e.name] = res.reasons.get(e.name, 0) + 1
        return None
    if zfo:
        res.bal0, res.bal1 = res.bal0 + amount, res.bal1 - out
    else:
        res.bal0, res.bal1 = res.bal0 - out, res.bal1 + amount
    v = _value(zfo, amount, out, m)
    res.revenue += v
    if arb:
        res.arb_revenue += v
    sold1 = out if zfo else -amount
    res.inv1 += sold1 / E18
    res.max_abs_inv1 = max(res.max_abs_inv1, abs(res.inv1))
    res.notional += (amount / E18) if zfo else amount / E18 * m
    return out


def _arbitrage(engine, res: Result, t: int, m: float, kind_new_b: bool):
    if abs(m - 1) < 1e-9:
        return
    zfo = m > 1  # currency1 worth more than P: buy currency1
    if kind_new_b:
        h = engine.h
        x = h.position_now(t)
        cap = h.cfg.xmax
        if zfo:  # buy currency1 until (V / (V - x))^2 = m
            xs = min(cap, max_position(h.cfg.depth, min(int((m - 1) * 1e6), 999_999)))
        else:  # sell currency1 until (V / (V + |x|))^2 = m, i.e. |x| = V (1 / sqrt(m) - 1)
            xs = min(cap, int(h.cfg.depth * (1 / math.sqrt(m) - 1)))
        if zfo and xs > x:
            amt = position_cost(xs, h.cfg.depth, Q96) - position_cost(x, h.cfg.depth, Q96)
            if amt > 0:
                _fill(engine, res, True, amt, t, m, arb=True)
        elif not zfo and -xs < x:
            _fill(engine, res, False, x + xs, t, m, arb=True)
        return
    chunk = 1000 * E18
    for _ in range(50):  # greedy: keep buying 1,000-token pieces while each is profitable at m
        snap = _snapshot(engine)
        try:
            out = engine.swap(zfo, chunk, t)
        except Revert:
            return
        profit = (out / E18 * m - chunk / E18) if zfo else (out / E18 - chunk / E18 * m)
        _restore(engine, snap)
        if profit <= 0 or _fill(engine, res, zfo, chunk, t, m, arb=True) is None:
            return


def _snapshot(engine):
    if isinstance(engine, OldEngine):
        return (dict(engine.consumed), dict(engine.opened), engine.refreshes)
    h = engine.h
    if isinstance(h, HookA):
        return (dict(h.level), dict(h.updated))
    return (h.x, h.updated)


def _restore(engine, snap):
    if isinstance(engine, OldEngine):
        engine.consumed, engine.opened, engine.refreshes = dict(snap[0]), dict(snap[1]), snap[2]
        return
    h = engine.h
    if isinstance(h, HookA):
        h.level, h.updated = dict(snap[0]), dict(snap[1])
    else:
        h.x, h.updated = snap


def simulate(orders: list[Order], make_engine, reg: Regime, new_b: bool) -> Result:
    eng, res = make_engine(), Result()
    for o in orders:
        res.attempted += 1
        if o.pieces > 1:
            # Counterfactual: the same order as one trade from the same state, for the split discount.
            snap = _snapshot(eng)
            try:
                single = eng.swap(o.zfo, o.amount, o.t)
            except Revert:
                single = None
            _restore(eng, snap)
            piece, outs, ok = o.amount // o.pieces, 0, True
            snap = _snapshot(eng)
            for _ in range(o.pieces):
                try:
                    outs += eng.swap(o.zfo, piece, o.t)
                except Revert as e:
                    ok = False
                    res.reasons[e.name] = res.reasons.get(e.name, 0) + 1
                    break
            _restore(eng, snap)
            if ok:
                filled = all(_fill(eng, res, o.zfo, piece, o.t, o.market) is not None for _ in range(o.pieces))
                res.filled += 1 if filled else 0
                if single is not None:
                    res.split_orders += 1
                    res.split_discount += _value(o.zfo, piece * o.pieces, single, o.market) - _value(
                        o.zfo, piece * o.pieces, outs, o.market)
        elif _fill(eng, res, o.zfo, o.amount, o.t, o.market) is not None:
            res.filled += 1
        if reg.arb:
            _arbitrage(eng, res, o.t, o.market, new_b)
    return res


def run_all(regimes=REGIMES, seeds=SEEDS):
    variants = {
        "A old": (lambda: OldEngine("A"), False),
        "A new": (lambda: NewEngine("A"), False),
        "B old": (lambda: OldEngine("B"), False),
        "B new": (lambda: NewEngine("B"), True),
    }
    table = {}
    for reg in regimes:
        for name, (mk, new_b) in variants.items():
            agg = []
            for seed in seeds:
                agg.append(simulate(generate(reg, seed), mk, reg, new_b))
            table[(reg.name, name)] = agg
    return table


def summarise(rs: list[Result]) -> dict:
    n = len(rs)
    att = sum(r.attempted for r in rs)
    fil = sum(r.filled for r in rs)
    notional = sum(r.notional for r in rs)
    rev = sum(r.revenue for r in rs)
    reasons: dict = {}
    for r in rs:
        for k, v in r.reasons.items():
            reasons[k] = reasons.get(k, 0) + v
    return {
        "fill%": 100 * fil / att,
        "LP rev/seed": rev / n,
        "rev bps": 1e4 * rev / notional if notional else 0.0,
        "arb P&L/seed": sum(r.arb_revenue for r in rs) / n,
        "max|inv1|": max(r.max_abs_inv1 for r in rs),
        "split disc bps": (1e4 * sum(r.split_discount for r in rs) / max(1e-9, sum(
            r.notional for r in rs if r.split_orders))) if any(r.split_orders for r in rs) else None,
        "worst seed rev": min(r.revenue for r in rs),
        "refusals": reasons,
    }


def sensitivity():
    """Hook B and Hook A parameter variants on two regimes: revenue is reported next to fill rate and arbitrage loss,
    so that no setting is chosen on revenue alone."""
    rows = []
    for reg in (REGIMES[0], REGIMES[5]):
        for depth in (5 * 10**5, 10**6, 2 * 10**6):
            rs = [simulate(generate(reg, s), lambda d=depth: NewEngine("B", b_cfg=HookBConfig(Q96, d * E18, 20_000, 3600)),
                           reg, True) for s in SEEDS]
            rows.append((reg.name, f"B depth {depth:,}", summarise(rs)))
        for window in (600, 14_400):
            rs = [simulate(generate(reg, s), lambda w=window: NewEngine("B", b_cfg=HookBConfig(Q96, 10**6 * E18, 20_000, w)),
                           reg, True) for s in SEEDS]
            rows.append((reg.name, f"B depth 1,000,000, decay {window} s", summarise(rs)))
        for mx in (5000, 9500):
            rs = [simulate(generate(reg, s), lambda m=mx: NewEngine(
                "A", a_cfg=HookAConfig(Q96, 500, m, 10_000 * E18, 10_000 * E18, 3600)), reg, False) for s in SEEDS]
            rows.append((reg.name, f"A max {mx} pips", summarise(rs)))
    return rows


def fmt(v):
    if v is None:
        return "n/a"
    if isinstance(v, float):
        return f"{v:,.2f}"
    return str(v)


def main():
    print("SYNTHETIC trade sequences (not historical data). 6 regimes x 3 seeds x 4,000 orders; identical sequences "
          "for every pricing variant.\n")
    table = run_all()
    cols = ["fill%", "LP rev/seed", "rev bps", "arb P&L/seed", "max|inv1|", "split disc bps", "worst seed rev"]
    print("| regime | rule | " + " | ".join(cols) + " | refusals (all seeds) |")
    print("|---" * (len(cols) + 3) + "|")
    for (reg, name), rs in table.items():
        s = summarise(rs)
        print(f"| {reg} | {name} | " + " | ".join(fmt(s[c]) for c in cols) + f" | {s['refusals']} |")
    print("\nParameter sensitivity (new rules):\n")
    print("| regime | setting | " + " | ".join(cols) + " |")
    print("|---" * (len(cols) + 2) + "|")
    for reg, name, s in sensitivity():
        print(f"| {reg} | {name} | " + " | ".join(fmt(s[c]) for c in cols) + " |")


if __name__ == "__main__":
    main()
