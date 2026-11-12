"""Phase 1B-4.4 inventory-tolerance calibration (SYNTHETIC; not historical data).

Two models, kept separate because they answer different questions:

  1. Agent-based (simulate.py, the Phase 1B-4.3 kappa grid, re-run unchanged): what kappa does to normal operation and
     to an oracle compromise. Per kappa, push-only and push + fresh source: successful trades (fill%), inventory
     depletion (max |deviation| of asset1 from target, also as a fraction of kappa), economic result (LP vs HODL),
     withdrawals (share of LP exits paid instantly), recovery (seconds from |dev| > 10% back to < 5%), and the worst
     seed of attack A4 (a malicious adapter halving the price for a day).
  2. Exact-integer adversary (floor_guarantee.py): the worst LP shortfall against its own entry value when the adversary
     owns every price, for each kappa and each guardian re-centring cadence. Without re-centring, gains lift holdings
     above target and the room above the floor grows past kappa (correction C4); re-centring is the policy lever.

Run from the repository root:  python3 simulations/mm/kappa_calibration.py > simulations/mm/results/phase144_kappa.md
(~1 min on 10 cores). Writes simulations/mm/results/phase144_kappa.json.
"""

from __future__ import annotations

import json
import os
import statistics
import sys

sys.path.insert(0, os.path.dirname(__file__))

import floor_guarantee as fg  # noqa: E402
import simulate as sim  # noqa: E402

CADENCES = (0, 50, 10)  # steps between re-centrings; 0 = never
SEEDS = range(60)


def recentring_table() -> dict:
    print("### Exact-integer adversary: worst LP shortfall / entry value, by kappa and re-centring cadence\n")
    print("The adversary sets every fill price (malicious adapter); honest flow pays a 30 bp fee; 60 random sequences of"
          " 300 steps per cell; the worst of 6 price vectors including a full depeg of either asset.\n")
    print("| kappa | never re-centred | re-centred every 50 steps | re-centred every 10 steps | T1 violations | T2 breaches |")
    print("|---|---|---|---|---|---|")
    out = {}
    for k in sim.KAPPAS:
        row, viol, br = {}, 0, 0
        for c in CADENCES:
            worst = 0.0
            for seed in SEEDS:
                v = fg.random_run(seed, steps=300, kappa=k, recentre_every=c)
                _, frac, b = v.t2_report(fg.PRICES)
                worst = max(worst, frac)
                viol += len(v.violations)
                br += b
            row[c] = worst
        out[k] = {"never": row[0], "every50": row[50], "every10": row[10], "t1_violations": viol, "t2_breaches": br}
        print(f"| {k / 1e4:g}% | {row[0]:.4f} ({row[0] / (k / 1e6):.2f} kappa) | {row[50]:.4f} ({row[50] / (k / 1e6):.2f}"
              f" kappa) | {row[10]:.4f} ({row[10] / (k / 1e6):.2f} kappa) | {viol} | {br} |")
    return out


def agent_table(workers=None) -> dict:
    cands = sim._cands_143()
    table = sim.run_grid(sim.REGIMES_141, sim.HELD_OUT_SEEDS, cands, workers)
    att = sim.run_grid(sim.ATTACKS, sim.HELD_OUT_SEEDS, cands, workers)
    print("\n### Agent-based model (held-out seeds", sim.HELD_OUT_SEEDS, ", 9 regimes; attacks: 7 x 4 seeds)\n")
    print("| candidate | fill% median | fill% worst regime | max dev% (asset1) | max dev / kappa | LP vs HODL bps median"
          " | LP exits paid instantly % (min) | recovery median s (episodes) | A4 worst bps | A4 / kappa |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    rows = {}
    for c in cands:
        per = [sim.summarise(table[(r.name, c.name)]) for r in sim.REGIMES_141]
        allr = [t for r in sim.REGIMES_141 for x in table[(r.name, c.name)] for t in x["recoveries"]]
        wd = [p["wd instant%"] for p in per if p["wd instant%"] is not None]
        a4 = sim.summarise(att[(sim.ATTACKS[3].name, c.name)])["LP vs HODL bps (worst)"]
        kappa = c.kappa / 1e6
        row = {
            "fill_med": statistics.median(p["fill%"] for p in per),
            "fill_worst": min(p["fill%"] for p in per),
            "max_dev": max(p["max |dev|%"] for p in per),
            "lp_med": statistics.median(p["LP vs HODL bps (median)"] for p in per),
            "wd_instant_min": min(wd) if wd else None,
            "recovery_med_s": statistics.median(allr) if allr else None,
            "episodes": len(allr),
            "a4_worst_bps": a4,
        }
        rows[c.name] = row
        rec = "-" if row["recovery_med_s"] is None else f"{row['recovery_med_s']:.0f}"
        print(f"| {c.name} | {row['fill_med']:.2f} | {row['fill_worst']:.2f} | {row['max_dev']:.2f} | "
              f"{row['max_dev'] / 100 / kappa:.2f} | {row['lp_med']:.1f} | "
              f"{'-' if row['wd_instant_min'] is None else round(row['wd_instant_min'], 1)} | {rec} ({row['episodes']}) | "
              f"{a4:.1f} | {-a4 / 1e4 / kappa:.2f} |")
    return rows


def main():
    print("# Phase 1B-4.4 inventory-tolerance calibration (SYNTHETIC)\n")
    rc = recentring_table()
    ag = agent_table()
    with open(os.path.join(os.path.dirname(__file__), "results", "phase144_kappa.json"), "w") as f:
        json.dump({"recentring": {str(k): v for k, v in rc.items()}, "agent": ag}, f, indent=1, sort_keys=True)


if __name__ == "__main__":
    main()
