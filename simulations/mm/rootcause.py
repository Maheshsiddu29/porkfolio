"""Why Hook B refuses inventory-reducing trades: worked examples and an attribution over the Phase 1B-3 sequences.

Run from the repository root:  python3 simulations/mm/rootcause.py

Part 1 is exact integer arithmetic on the test fixture (depth 1,000,000 tokens, 2% cap, 1 h decay, P = 1, vault
floors 1:1). Part 2 replays the exact synthetic order sequences of `simulations/pricing/economics.py` (6 regimes x
3 seeds x 4,000 orders, SYNTHETIC) through the production Hook B model and through counterfactual variants that each
remove one suspected cause, and classifies every `PriceBelowFloor` refusal. Nothing here is historical data.
"""

from __future__ import annotations

import os
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "pricing"))

from model import (  # noqa: E402
    PIPS,
    Q96,
    HookB,
    HookBConfig,
    Revert,
    TwoSidedCurve,
    TwoSidedCurveConfig,
    debit_out,
    floor_ok,
    position_cost,
)
from economics import REGIMES, SEEDS, generate  # noqa: E402

E18 = 10**18
V = 10**6 * E18
CFG = HookBConfig(Q96, V, 20_000, 3600)


def tok(x: int) -> str:
    return f"{x / E18:,.4f}"


def part1():
    print("## Part 1: one sale, then its reverse (exact integers, fixture parameters)\n")
    h = HookB()
    h.configure(CFG, 0)
    paid = 5_000 * E18
    got = h.swap(True, paid, 0)  # trader sells currency0, vault sells currency1
    x = h.x
    print(f"- Trader pays {tok(paid)} currency0, receives {tok(got)} currency1. Position x = {tok(x)}.")
    num, den = V * V, (V - x) ** 2
    print(f"- Marginal price of currency1 at x: (V/(V-x))^2 = {num / den:.6f} currency0, reference 1.000000.")
    q = 1_000 * E18
    out_rev = h.quote(False, q, 0)[0]
    print(f"- Reverse: trader sells {tok(q)} currency1. Curve pays {tok(out_rev)} currency0 "
          f"(average {out_rev / q:.6f} currency0 per currency1).")
    print(f"- Vault floor for selling currency0 is 1 currency1 per currency0: needs in >= out. "
          f"{tok(q)} >= {tok(out_rev)} is {floor_ok(q, out_rev, Q96)} -> PriceBelowFloor.")
    need_h = 1 - q / out_rev
    print(f"- Half-spread that would make this reverse pass the 1:1 floor: h >= {need_h * 1e4:.1f} bps "
          f"(= the curve premium already accumulated).")
    print(f"- If the floors were absent and P were the market price, the reverse seller would earn "
          f"{tok(out_rev - q)} currency0 against the market on this trade: the curve's buy-back is itself an "
          f"arbitrage, which the floor is refusing.")
    # Smallest decay that lets the same reverse through.
    lo, hi = 0, 3600
    while lo < hi:
        mid = (lo + hi) // 2
        try:
            o = h.quote(False, q, mid)[0]
            ok = floor_ok(q, o, Q96)
        except Revert:
            ok = False
        if ok:
            hi = mid
        else:
            lo = mid + 1
    print(f"- With no other trade, the same reverse passes after {lo} s of decay (position then "
          f"{tok(h.position_now(lo))}): the position has to fall to where the reverse trade's average price is at "
          f"or below the reference.")
    # Real inventory versus virtual position after decay.
    print("\n### Virtual position versus real inventory\n")
    h2 = HookB()
    h2.configure(CFG, 0)
    sold, t = 0, 0
    for hour in range(24):
        t = hour * 3600
        amt = position_cost(CFG.xmax, V, Q96) - position_cost(h2.position_now(t), V, Q96) - E18
        if amt > 0:
            sold += h2.swap(True, amt, t)
    print(f"- One buyer of currency1 per hour, each pushing x to just below the cap (decay 1 h): after 24 h the vault "
          f"has sold {tok(sold)} currency1 net, while x never exceeded the cap of {tok(CFG.xmax)} and is now "
          f"{tok(h2.position_now(t + 3600))} one hour later.")
    print("- x measures recent trading pressure, not what the vault holds: decay returns the price to the reference "
          "without returning any inventory, and the next buyer is priced as if the vault were flat.")
    # A spread alone.
    print("\n### Does a bid-ask spread alone fix it?\n")
    for hb in (10, 30, 100, 200):
        c = TwoSidedCurve(TwoSidedCurveConfig(Q96, V, 20_000, 3600, hb * 100))
        g, x2 = c.quote(True, paid, 0)
        c.commit(x2, 0)
        o, _ = c.quote(False, q, 0)
        print(f"- half-spread {hb:>3} bps: after the same sale, reverse of 1,000 pays {tok(o)} -> floor "
              f"{'passes' if floor_ok(q, o, Q96) else 'refuses'}.")
    print("- A constant spread passes reverse trades only while the accumulated curve premium is below it. With the "
          "2% cap, only a spread of about 2% makes every reverse pass; a smaller spread moves the boundary, it does "
          "not remove it.\n")


def classify_run(orders, variant: str):
    """Replay `orders` (single trades only; splits are replayed as one trade) through a Hook B variant with 1:1
    floors, valuing nothing: only fills and refusals. Returns Counter of outcomes and the refusal classification."""
    if variant == "hookB":
        eng = HookB()
        eng.configure(CFG, 0)
        quote = lambda z, a, t: eng.quote(z, a, t)[:2]  # noqa: E731
        pos = eng.position_now
        commit = lambda x2, t: (setattr(eng, "x", x2), setattr(eng, "updated", t))  # noqa: E731
    else:
        hb = {"spread30": 3000, "spread200": 20000}.get(variant, 0)
        window = 0 if variant == "nodecay" else 3600
        eng = TwoSidedCurve(TwoSidedCurveConfig(Q96, V, 20_000, window, hb))
        quote, pos, commit = eng.quote, eng.position_now, eng.commit
    floors = variant != "nofloor"
    out = Counter()
    cls = Counter()
    real_sold1 = 0  # vault's real net currency1 sold since the start
    for o in orders:
        out["orders"] += 1
        x = pos(o.t)
        reduces_x = (x > 0 and not o.zfo) or (x < 0 and o.zfo)
        reduces_real = (real_sold1 > 0 and not o.zfo) or (real_sold1 < 0 and o.zfo)
        try:
            got, x2 = quote(o.zfo, o.amount, o.t)
        except Revert as e:
            out[e.name] += 1
            continue
        if got == 0:
            out["ZeroOutput"] += 1
            continue
        if floors and not floor_ok(o.amount, got, Q96):
            out["PriceBelowFloor"] += 1
            cls["reduces |x|" if reduces_x else "does not reduce |x|"] += 1
            cls["reduces real imbalance" if reduces_real else "does not reduce real imbalance"] += 1
            if reduces_x and x2 * x < 0:
                cls["crosses zero"] += 1
            # Would the same trade pass from x = 0 (i.e. is the refusal caused by the stored state)?
            probe = TwoSidedCurve(TwoSidedCurveConfig(Q96, V, 20_000, 3600, 0))
            try:
                g0, _ = probe.quote(o.zfo, o.amount, 0)
                cls["passes from x = 0"] += floor_ok(o.amount, g0, Q96)
            except Revert:
                pass
            for hb in (30, 100, 200):
                cls[f"passes with {hb} bps half-spread"] += floor_ok(o.amount, debit_out(got, hb * 100), Q96)
            continue
        commit(x2, o.t)
        out["filled"] += 1
        real_sold1 += got if o.zfo else -o.amount
        if reduces_real:
            out["filled, reduces real imbalance"] += 1
    return out, cls


def part2():
    print("## Part 2: attribution over the Phase 1B-3 synthetic sequences (SYNTHETIC)\n")
    print("Same generator, regimes and seeds as `simulations/pricing/economics.py`; arbitrage is not replayed (the "
          "static regimes are the ones where the 59-67% fill rate was reported). Split orders are replayed as one "
          "trade. Floors 1:1.\n")
    variants = ["hookB", "nofloor", "nodecay", "spread30", "spread200"]
    print("| regime | " + " | ".join(f"fill% {v}" for v in variants) + " |")
    print("|---" * (len(variants) + 1) + "|")
    totals = Counter()
    for reg in REGIMES:
        if reg.arb:
            continue
        row = []
        for v in variants:
            agg = Counter()
            for s in SEEDS:
                o, cls = classify_run(generate(reg, s), v)
                agg.update(o)
                if v == "hookB":
                    totals.update(cls)
                    totals["refusals"] += o["PriceBelowFloor"]
            row.append(f"{100 * agg['filled'] / agg['orders']:.2f}")
        print(f"| {reg.name} | " + " | ".join(row) + " |")
    n = totals["refusals"]
    print(f"\nClassification of all {n:,} `PriceBelowFloor` refusals of the production Hook B in these regimes:\n")
    for k in ["reduces |x|", "does not reduce |x|", "crosses zero", "reduces real imbalance",
              "does not reduce real imbalance", "passes from x = 0", "passes with 30 bps half-spread",
              "passes with 100 bps half-spread", "passes with 200 bps half-spread"]:
        print(f"- {k}: {totals[k]:,} ({100 * totals[k] / n:.1f}%)")
    print("\n(Half-spread rows apply the spread to the refused trade's own output from the same state; they do not "
          "re-run the history, which the spread30 and spread200 columns above do.)")


if __name__ == "__main__":
    part1()
    part2()
