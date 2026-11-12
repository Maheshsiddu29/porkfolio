#!/usr/bin/env python3
"""Non-vacuity gate for the stateful invariant campaigns.

An invariant that holds over 32,768 calls proves little if most of those calls changed nothing. Foundry prints the
handler counters of the last run only, so this script runs many single-run campaigns, one per seed, and reads the
`COV <name> <value>` lines each test contract's `afterInvariant` prints. For every counter it reports the fraction of
runs in which that operation never succeeded, and fails if a fraction exceeds the gate below.

The gates were set in the G01 baseline (docs/security/G01_BASELINE.md, section 4): each is at least four standard
deviations (binomial, 64 seeds) above the worst fraction observed over four seed families (bases 13, 101, 4001, 65537),
noted next to it. The runs are reproducible: the Foundry profile and `include_storage = false` are pinned (see
`run_once`), and two complete runs give identical output. A gate failure after a change means the change made a
campaign less active. Counters in MUST_BE_ZERO fail the gate if any run records one.

Usage (from the repository root; standard library only):
    python3 test/invariant/coverage.py                # 64 seeds, depth 128
    python3 test/invariant/coverage.py --seeds 16 --depth 64
    python3 test/invariant/coverage.py --seed-base 101 # another seed family, to look for false failures

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
        {  # gate; fraction observed with the default seeds (base 13), and the range over bases 13, 101, 4001, 65537
            "swapsOk": 0.40,  # 0.19 (0.14-0.19)
            "pricingSwapsOk": 0.65,  # 0.33 (0.33-0.39)
            "allocationsOk": 0.20,  # 0.02 (0.02-0.05)
            "depositsOk": 0.15,  # 0.02 (0.00-0.02)
            "instantOk": 0.25,  # 0.06 (0.03-0.06)
            "queuedOk": 0.50,  # 0.19 (0.17-0.25)
            "finalizedOk": 0.80,  # 0.42 (0.38-0.55)
            "claimsOk": 0.85,  # 0.45 (0.45-0.58)
            "releasesOk": 0.35,  # 0.08 (0.08-0.16)
        },
    ),
    "oracle": (
        "^OracleRiskInvariantsTest$",
        "invariant_accountingConsistent",
        {
            "fills": 0.20,  # 0.03 (0.02-0.06)
            "refusedAtFloor": 0.10,  # 0.00 (0.00)
        },
    ),
    "inventory": (
        "^InventoryProtectionInvariantsTest$",
        "invariant_accountingConsistent",
        {
            "fillsA": 0.30,  # 0.09 (0.03-0.11)
            "fillsB": 0.30,  # 0.03 (0.02-0.12)
            "fillsMal": 0.20,  # 0.00 (0.00-0.06)
            "refusedAtFloor": 0.25,  # 0.05 (0.02-0.09)
            "loosenings": 0.10,  # 0.00 (0.00)
            "looseningsBlocked": 0.35,  # 0.05 (0.05-0.14)
            "payoutsChecked": 0.20,  # 0.02 (0.02-0.05)
            "slicesChecked": 0.40,  # 0.17 (0.14-0.20)
            "refusedUnderFault": 0.40,  # 0.11 (0.06-0.17)
        },
    ),
    "liveness": (
        "^GovernanceLivenessInvariantsTest$",
        "invariant_accountingConsistent",
        {  # set in G02 (docs/security/G02_GOVERNANCE_LIVENESS.md), same method and seed families
            "commitsOk": 0.10,  # 0.00 (0.00-0.02)
            "depositsOk": 0.20,  # 0.00 (0.00-0.05)
            "swapsOk": 0.15,  # 0.03 (0.02-0.03)
            "queuedOk": 0.60,  # 0.36 (0.25-0.36)
            "finalizedOk": 0.30,  # 0.09 (0.06-0.12)
            "prefixChecks": 0.20,  # 0.05 (0.05)
            "rotationsOk": 0.10,  # 0.00 (0.00-0.02)
            "preEtaRotations": 0.80,  # 0.52 (0.41-0.52)
            "execAttempts": 0.35,  # 0.03 (0.03-0.14)
            "longExecuted": 0.45,  # 0.05 (0.05-0.22)
            "restrictedExecutions": 0.85,  # 0.36 (0.36-0.58)
            "expiredOps": 0.80,  # 0.53 (0.41-0.53)
            # 0.80 (0.69-0.80). Four standard deviations above 0.80 is 1.0, which would gate nothing; 0.98 (3.6 sigma)
            # fails only when at most one run in 64 reaches a blocked LONG_DELAY attempt.
            "longBlocked": 0.98,
        },
    ),
}

# Counters that must stay zero in every run: an operation that failed for a reason the handler does not expect.
MUST_BE_ZERO = {"inventory": ("looseningsFailedOther",), "liveness": ("otherFailures",)}

PROFILE = "default"

COV = re.compile(r"^\s*COV (\w+) (\d+)\s*$")


def run_once(contract, test, seed, depth):
    # Pinned for reproducibility. The profile: the gates were set under `default`. `include_storage = false`: with
    # Foundry 1.7.1, values the fuzzer collects from contract storage are sampled in an order that changes between
    # identical runs, so a few arguments (and a few counts) differed run to run; without them, every run with the same
    # seed is identical. The CI and deep campaigns keep the default (storage values on); only this measurement turns
    # them off.
    env = dict(
        os.environ,
        FOUNDRY_PROFILE=PROFILE,
        FOUNDRY_INVARIANT_INCLUDE_STORAGE="false",
        FOUNDRY_INVARIANT_RUNS="1",
        FOUNDRY_INVARIANT_DEPTH=str(depth),
    )
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
    # Seeds are i * 7919 + base. The gates were set with base 13; other bases check them for false failures.
    ap.add_argument("--seed-base", type=int, default=13)
    args = ap.parse_args()
    seeds = [hex(i * 7919 + args.seed_base) for i in range(1, args.seeds + 1)]
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
        for counter in MUST_BE_ZERO.get(name, ()):
            if any(r.get(counter, 0) for r in runs):
                print(f"   {counter} must be 0 in every run  FAIL")
                failed = True
        missing = set(gates) - {k for r in runs for k in r}
        if missing:
            print(f"   missing counters: {sorted(missing)}  FAIL")
            failed = True
    if failed:
        raise SystemExit("coverage.py: a campaign is less active than its gate allows")
    print("coverage.py: every gate passed")


if __name__ == "__main__":
    main()
