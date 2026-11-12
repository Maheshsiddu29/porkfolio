"""Phase 1B-4.4: Hook A / Hook B calibration on the same trade sequences, with routers (SYNTHETIC, exact integers).

Both hooks price from one shared core on one reserve (`model.core_state`); Hook A adds its cumulative activity fee
(`model.hook_a_quote`), Hook B a flat markup with a per-trade impact bound (`model.hook_b_quote`). Every trade of a
seeded stream is offered to three routers, each on its own copy of the reserve:

  R1 best single hook   quote both, take the larger output (what an aggregator does by default);
  R2 best split         try every split f in {0, 0.1, ..., 1} of the trade, A first or B first, take the best;
  core                  the same trade, from R2's state, on the strategy-free core (no activity fee, no markup): the
                        shared economic constraint. No route may beat it; any routed output above it is a violation.

Reported per parameter set: who wins the flow (share of filled notional routed to Hook A by R1, by trade size), the
traders' execution cost against the reference mid, how much R2 gains over R1 (the value of routing across hooks), the
LP result (reserve value at mid against holding), refusals, and core violations (must be 0).

Run from the repository root:  python3 simulations/mm/hook_routing.py > simulations/mm/results/phase144_routing.md
(~1-2 min on 10 cores). Writes simulations/mm/results/phase144_routing.json. Not historical order flow.
"""

from __future__ import annotations

import json
import math
import os
import random
import statistics
import sys
from concurrent.futures import ProcessPoolExecutor
from dataclasses import dataclass

sys.path.insert(0, os.path.dirname(__file__))

from model import (  # noqa: E402
    PIPS,
    Q96,
    WAD,
    ActivityFeeConfig,
    InventoryConfig,
    Reference,
    Revert,
    VaultSnapshot,
    core_state,
    decayed,
    depth_per_share_for,
    hook_a_quote,
    hook_b_quote,
)

E18 = 10**18
INIT = 1_000_000 * E18
SEEDS = (301, 302, 303)
TRADES = 1_200  # per seed, ~2 days at one trade per ~2.4 min
MIN_EDGE = 200
BASE_SPREAD = 3_000
B_IMPACT = 20_000


@dataclass(frozen=True)
class Params:
    name: str
    kappa: int
    u: int  # reference uncertainty, pips (8,105 = the measured push-only band; 1,500 = a fresh source)
    a_max: int  # Hook A maximum activity fee, pips (base 0)
    a_scale: int  # tokens of decayed flow at which Hook A reaches a_max
    b_markup: int  # Hook B flat markup, pips


class Book:
    """One reserve and Hook A's activity levels; the core is shared, Hook B keeps no state."""

    def __init__(self, p: Params, fee_on=True, markup_on=True):
        self.n0, self.n1, self.s = INIT, INIT, INIT
        self.cfg = InventoryConfig(WAD, depth_per_share_for(WAD, p.kappa, BASE_SPREAD, MIN_EDGE), 2**95 - 1,
                                   BASE_SPREAD, MIN_EDGE, 60_000, p.kappa, True)
        self.fee = ActivityFeeConfig(0, p.a_max if fee_on else 0, p.a_scale * E18, p.a_scale * E18, 3_600)
        self.markup = p.b_markup if markup_on else 0
        self.ref = Reference(Q96, p.u)
        self.level = {True: 0, False: 0}
        self.updated = {True: 0, False: 0}

    def copy(self):
        b = Book.__new__(Book)
        b.__dict__ = {**self.__dict__, "level": dict(self.level), "updated": dict(self.updated)}
        return b

    def quote(self, hook: str, zfo: bool, amt: int, now: int) -> int:
        cs = core_state(self.cfg, VaultSnapshot(self.n0, self.n1, self.s), self.ref)
        if hook == "A":
            k = self.fee.scale0 if zfo else self.fee.scale1
            lvl = decayed(self.level[zfo], k, self.fee.window, now - self.updated[zfo])
            q = hook_a_quote(cs, self.fee, lvl, zfo, amt)
            return q.amount_out, q.new_level
        return hook_b_quote(cs, self.markup, B_IMPACT, zfo, amt).amount_out, 0

    def swap(self, hook: str, zfo: bool, amt: int, now: int) -> int:
        out, lvl = self.quote(hook, zfo, amt, now)
        if hook == "A":
            self.level[zfo], self.updated[zfo] = lvl, now
        if zfo:
            self.n0, self.n1 = self.n0 + amt, self.n1 - out
        else:
            self.n0, self.n1 = self.n0 - out, self.n1 + amt
        return out

    def value(self) -> int:
        return self.n0 + self.n1  # at the reference mid 1:1


def _strip(book: Book) -> Book:
    """The same reserve with both strategies removed (no activity fee, no markup): the shared core alone."""
    b = book.copy()
    b.fee = ActivityFeeConfig(0, 0, b.fee.scale0, b.fee.scale1, b.fee.window)
    b.markup = 0
    return b


def _try(book: Book, legs, zfo, now) -> int | None:
    b = book.copy()
    total = 0
    try:
        for hook, amt in legs:
            if amt:
                total += b.swap(hook, zfo, amt, now)
    except Revert:
        return None
    return total


def stream(seed: int):
    rng = random.Random(seed)
    now, zfo = 0, True
    for _ in range(TRADES):
        now += max(1, int(rng.expovariate(1 / 144)))
        if rng.random() > 0.7:
            zfo = not zfo
        size = min(30_000.0, math.exp(rng.gauss(math.log(1_500), 1.2)))
        yield now, zfo, int(size * E18)


def run(p: Params, seed: int) -> dict:
    r1, r2 = Book(p), Book(p)
    res = {"notional": 0, "filled": 0, "refused": 0, "a_notional": {"small": 0, "mid": 0, "large": 0},
           "notional_by": {"small": 0, "mid": 0, "large": 0}, "cost_bps_x_notional": 0.0,
           "r2_gain_bps_x_notional": 0.0, "r2_gain_max_bps": 0.0, "violations": 0, "split_used": 0}
    for now, zfo, amt in stream(seed):
        res["notional"] += amt
        bucket = "small" if amt < 1_000 * E18 else ("mid" if amt < 5_000 * E18 else "large")
        # R1: best single hook
        qa = _try(r1, [("A", amt)], zfo, now)
        qb = _try(r1, [("B", amt)], zfo, now)
        if qa is None and qb is None:
            res["refused"] += 1
            continue
        hook = "A" if (qb is None or (qa is not None and qa >= qb)) else "B"
        out1 = r1.swap(hook, zfo, amt, now)
        res["filled"] += amt
        res["notional_by"][bucket] += amt
        if hook == "A":
            res["a_notional"][bucket] += amt
        res["cost_bps_x_notional"] += (amt - out1) / amt * 1e4 * amt / E18
        # R2: best split, on its own book (same stream)
        best, best_legs = None, None
        for i in range(11):
            a_part = amt * i // 10
            for order in (("A", "B"), ("B", "A")):
                parts = {"A": a_part, "B": amt - a_part}
                legs = [(h, parts[h]) for h in order]
                got = _try(r2, legs, zfo, now)
                if got is not None and (best is None or got > best):
                    best, best_legs = got, legs
        # The core bound is taken on R2's own state: the strategy-free price for the same total, same inventory.
        cbest = _try(_strip(r2), [("B", amt)], zfo, now)
        if best is not None:
            singles = [x for x in (_try(r2, [("A", amt)], zfo, now), _try(r2, [("B", amt)], zfo, now)) if x is not None]
            gain = (best - max(singles)) / amt * 1e4 if singles else 0.0
            res["r2_gain_bps_x_notional"] += gain * amt / E18
            res["r2_gain_max_bps"] = max(res["r2_gain_max_bps"], gain)
            if cbest is not None and best > cbest:
                res["violations"] += 1
            if all(a for _, a in best_legs):
                res["split_used"] += 1
            for h, a in best_legs:
                if a:
                    r2.swap(h, zfo, a, now)
    res["lp_vs_hold_bps_r1"] = (r1.value() - 2 * INIT) / (2 * INIT) * 1e4
    res["lp_vs_hold_bps_r2"] = (r2.value() - 2 * INIT) / (2 * INIT) * 1e4
    return res


def grid() -> list[Params]:
    out = []
    for kappa in (10_000, 20_000):
        for u in (1_500, 8_105):
            for a_max in (2_000, 5_000):
                for markup in (0, 500, 1_000, 2_000):
                    out.append(Params(f"k{kappa // 10_000}% u{u} A<= {a_max / 100:g}bp B+{markup / 100:g}bp",
                                      kappa, u, a_max, 20_000, markup))
    return out


def _job(args):
    p, seed = args
    return p.name, run(p, seed)


def main():
    params = grid()
    jobs = [(p, s) for p in params for s in SEEDS]
    with ProcessPoolExecutor() as ex:
        results = list(ex.map(_job, jobs))
    by = {}
    for name, r in results:
        by.setdefault(name, []).append(r)
    print("# Hook A / Hook B on the same trade sequences (SYNTHETIC; seeds", SEEDS, f", {TRADES} trades each)\n")
    print("Reference fixed at 1:1 with uncertainty u; base spread 30 bp, edge 2 bp, Hook B per-trade bound 2%; Hook A"
          " fee 0 -> max over 20,000 tokens of decayed flow (1 h). Sizes lognormal, median 1,500 tokens, max 30,000;"
          " 70% of trades continue the previous direction.\n")
    print("| parameters | filled % | A share of filled notional (small / mid / large) | trader cost bps (R1) |"
          " R2 gain over R1 bps (mean / max) | split trades % | LP vs hold bps (R1 / R2) | core violations |")
    print("|---|---|---|---|---|---|---|---|")
    summary = {}
    for p in params:
        rs = by[p.name]
        n = sum(r["notional"] for r in rs)
        f = sum(r["filled"] for r in rs)
        share = {b: sum(r["a_notional"][b] for r in rs) / max(1, sum(r["notional_by"][b] for r in rs))
                 for b in ("small", "mid", "large")}
        cost = sum(r["cost_bps_x_notional"] for r in rs) / max(1e-9, f / E18)
        gain = sum(r["r2_gain_bps_x_notional"] for r in rs) / max(1e-9, f / E18)
        gmax = max(r["r2_gain_max_bps"] for r in rs)
        split = 100 * sum(r["split_used"] for r in rs) / (TRADES * len(rs))
        lp1 = statistics.mean(r["lp_vs_hold_bps_r1"] for r in rs)
        lp2 = statistics.mean(r["lp_vs_hold_bps_r2"] for r in rs)
        viol = sum(r["violations"] for r in rs)
        summary[p.name] = {"filled%": 100 * f / n, "a_share": share, "cost_bps": cost, "r2_gain_mean_bps": gain,
                           "r2_gain_max_bps": gmax, "split%": split, "lp_r1_bps": lp1, "lp_r2_bps": lp2,
                           "violations": viol}
        print(f"| {p.name} | {100 * f / n:.1f} | {share['small']:.2f} / {share['mid']:.2f} / {share['large']:.2f} | "
              f"{cost:.1f} | {gain:.2f} / {gmax:.1f} | {split:.1f} | {lp1:.1f} / {lp2:.1f} | {viol} |")
    with open(os.path.join(os.path.dirname(__file__), "results", "phase144_routing.json"), "w") as fh:
        json.dump(summary, fh, indent=1, sort_keys=True)


if __name__ == "__main__":
    main()
