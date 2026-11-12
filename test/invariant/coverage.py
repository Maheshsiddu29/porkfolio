#!/usr/bin/env python3
"""Non-vacuity gate for the stateful invariant campaigns.

An invariant that holds over 32,768 calls proves little if most of those calls changed nothing. Foundry prints the
handler counters of the last run only, so this script runs many single-run campaigns, one per seed, and reads the
`COV <name> <value>` lines each test contract's `afterInvariant` prints. For every counter it reports the fraction of
runs in which that operation never succeeded, and fails if a fraction exceeds the gate below.

The gates were set in the G01 baseline (docs/security/G01_BASELINE.md, section 4): each is at least four standard
deviations (binomial, 64 seeds) above the fraction observed when it was set, which is noted next to it. The seed list
is fixed. Two runs of the same handler code gave close but not identical counts (191 and 188 successful vault swaps
over 64 runs), so the gates keep that margin; a gate failure after a change most likely means the change made a
campaign less active.

Usage (from the repository root; standard library only):
    python3 test/invariant/coverage.py                # 64 seeds, depth 128
    python3 test/invariant/coverage.py --seeds 16 --depth 64

Builds nothing itself: run `forge build` first. Writes nothing.
"""

import argparse
import os
import re
import subprocess
import sys

# campaign -> (contract regex, one invariant to run, {counter: max fraction of runs with zero})
CAMPAIGNS = {
    "vault": (
        "^VaultInvariantsTest$",
        "invariant_ghostLedgerConservation",
        {  # gate, then the fraction observed with the default 64 seeds at depth 128 when the gate was set
            "swapsOk": 0.40,  # 0.17
            "pricingSwapsOk": 0.60,  # 0.30
            "allocationsOk": 0.15,  # 0.00
            "depositsOk": 0.15,  # 0.02
            "instantOk": 0.25,  # 0.06
            "queuedOk": 0.45,  # 0.23
            "finalizedOk": 0.70,  # 0.42
            "claimsOk": 0.85,  # 0.59
            "releasesOk": 0.25,  # 0.06
        },
    ),
    "oracle": (
        "^OracleRiskInvariantsTest$",
        "invariant_accountingConsistent",
        {
            "fills": 0.20,  # 0.05
            "refusedAtFloor": 0.10,  # 0.00
        },
    ),
    "inventory": (
        "^InventoryProtectionInvariantsTest$",
        "invariant_accountingConsistent",
        {
            "fillsA": 0.25,  # 0.08
            "fillsB": 0.20,  # 0.03
            "fillsMal": 0.20,  # 0.00
            "refusedAtFloor": 0.20,  # 0.05
            "loosenings": 0.10,  # 0.00
            "looseningsBlocked": 0.25,  # 0.05
            "payoutsChecked": 0.15,  # 0.02
            "slicesChecked": 0.40,  # 0.14
            "refusedUnderFault": 0.35,  # 0.11
        },
    ),
}

COV = re.compile(r"^\s*COV (\w+) (\d+)\s*$")


def run_once(contract, test, seed, depth):
    env = dict(os.environ, FOUNDRY_INVARIANT_RUNS="1", FOUNDRY_INVARIANT_DEPTH=str(depth))
    cmd = ["forge", "test", "--match-contract", contract, "--match-test", test, "--fuzz-seed", seed, "-vv"]
    out = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if out.returncode != 0:
        sys.stdout.write(out.stdout[-4000:] + out.stderr[-2000:])
        raise SystemExit(f"coverage.py: campaign failed: {' '.join(cmd)}")
    counters = {}
    for line in out.stdout.splitlines():
        m = COV.match(line)
        if m:
            counters[m.group(1)] = int(m.group(2))
    if not counters:
        raise SystemExit(f"coverage.py: no COV lines from {' '.join(cmd)}")
    return counters


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=64)
    ap.add_argument("--depth", type=int, default=128)
    ap.add_argument("--campaign", choices=sorted(CAMPAIGNS), action="append")
    args = ap.parse_args()
    seeds = [hex(i * 7919 + 13) for i in range(1, args.seeds + 1)]
    failed = False
    for name in args.campaign or CAMPAIGNS:
        contract, test, gates = CAMPAIGNS[name]
        runs = [run_once(contract, test, s, args.depth) for s in seeds]
        print(f"== {name}: {len(runs)} single-run campaigns, depth {args.depth}, seeds {seeds[0]}..{seeds[-1]}")
        print(f"   {'counter':22s} {'zero-runs':>10s} {'gate':>6s} {'median':>7s} {'total':>7s}")
        for counter in sorted({k for r in runs for k in r}):
            xs = sorted(r.get(counter, 0) for r in runs)
            zero = sum(1 for x in xs if x == 0) / len(xs)
            gate = gates.get(counter)
            status = ""
            if gate is not None and zero > gate:
                status = "  FAIL"
                failed = True
            gate_s = f"{gate:.2f}" if gate is not None else "-"
            print(f"   {counter:22s} {zero:10.2f} {gate_s:>6s} {xs[len(xs) // 2]:7d} {sum(xs):7d}{status}")
        missing = set(gates) - {k for r in runs for k in r}
        if missing:
            print(f"   missing counters: {sorted(missing)}  FAIL")
            failed = True
    if failed:
        raise SystemExit("coverage.py: a campaign is less active than its gate allows")
    print("coverage.py: every gate passed")


if __name__ == "__main__":
    main()
