"""Writes test/utils/PricingVectors.sol: expected integers from the Python reference model for the Solidity
differential tests. Run from the repository root:  python3 simulations/pricing/vectors.py

Library vectors cover each CumulativePricing function at random and boundary inputs. Scenario vectors are sequences
of swaps (direction, input, seconds elapsed) with the expected output, revert reason and pricing state after each,
for the fixtures in test/integration/CumulativePricingModel.t.sol (vault floors 1:1 in both directions).
"""

from __future__ import annotations

import os
import random
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))

from cumulative import (  # noqa: E402
    MAX_DEPTH,
    PIPS,
    Q96,
    HookA,
    HookAConfig,
    HookB,
    HookBConfig,
    Revert,
    cumulative_fee,
    decayed,
    floor_ok,
    max_position,
    position_cost,
    position_for_cost,
)

E18 = 10**18
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "test", "utils", "PricingVectors.sol")

# Revert codes used by the scenario vectors.
OK, CAP, FLOOR, ZERO = 0, 1, 2, 3


def prices(rng):
    return rng.choice([Q96, rng.randrange(Q96 // 10**6, Q96 * 10**6), Q96 * 10**12, Q96 // 10**12, 1, 2**160 - 1])


def fee_vectors(rng):
    rows = []
    for k, base, mx, level in [
        (1, 0, 0, 0), (1, 0, PIPS - 1, 1), (10**22, 500, 5000, 8000 * E18), (10**22, 500, 5000, 10**22),
        (10**22, 500, 5000, 10**22 + 1), (2**128 - 1, 0, PIPS - 1, 2**128 - 1), (2**128 - 1, 999_999, 999_999, 2**127),
        (3, 1, 2, 2**128 - 1),
    ]:
        rows.append((level, k, base, mx, cumulative_fee(level, k, base, mx)))
    while len(rows) < 48:
        k = rng.randrange(1, 2**128)
        base = rng.randrange(0, PIPS)
        mx = rng.randrange(base, PIPS)
        level = rng.randrange(0, min(2**128, 3 * k))
        rows.append((level, k, base, mx, cumulative_fee(level, k, base, mx)))
    return rows


def cost_vectors(rng):
    rows = []
    v = 10**6 * E18
    for x in (0, 1, -1, 1000 * E18, -1000 * E18, 9852 * E18, -9852 * E18):
        rows.append((x, v, Q96, position_cost(x, v, Q96)))
    for p in (1, 2**160 - 1):
        xm = max_position(MAX_DEPTH, PIPS - 1)
        for x in (xm, -xm, 1, -1):
            rows.append((x, MAX_DEPTH, p, position_cost(x, MAX_DEPTH, p)))
    while len(rows) < 48:
        v = rng.randrange(2, MAX_DEPTH + 1)
        xm = max_position(v, rng.randrange(1, PIPS))
        x = rng.randrange(-xm, xm + 2)
        if abs(x) >= v:
            continue
        p = prices(rng)
        rows.append((x, v, p, position_cost(x, v, p)))
    return rows


def inverse_vectors(rng):
    rows = []
    while len(rows) < 48:
        v = rng.choice([rng.randrange(2, 10**6), rng.randrange(10**6, MAX_DEPTH + 1), MAX_DEPTH])
        p = prices(rng)
        xm = max_position(v, rng.randrange(1, PIPS))
        lo, hi = position_cost(-xm, v, p), position_cost(xm + 1, v, p)
        if hi <= lo:
            continue
        t = rng.choice([lo, hi - 1, 0, rng.randrange(lo, hi)])
        rows.append((t, v, p, position_for_cost(t, v, p)))
    return rows


def max_position_vectors(rng):
    rows = [(v, m, max_position(v, m)) for v, m in
            ((10**6, 20_000), (10**6 * E18, 20_000), (200_000 * E18, 10_000), (2, PIPS - 1), (4, PIPS - 1),
             (MAX_DEPTH, 1), (MAX_DEPTH, PIPS - 1), (MAX_DEPTH, 0))]
    while len(rows) < 32:
        v, m = rng.randrange(2, MAX_DEPTH + 1), rng.randrange(0, PIPS)
        rows.append((v, m, max_position(v, m)))
    return rows


def decay_vectors(rng):
    rows = [(l, r, w, e, decayed(l, r, w, e)) for l, r, w, e in
            ((1000, 600, 60, 30), (1000, 600, 60, 120), (1000, 600, 0, 10**9), (2**128 - 1, 2**128 - 1, 1, 2**64 - 1),
             (2**128 - 1, 1, 2**32 - 1, 2**64 - 1), (5, 7, 3, 2), (0, 10, 10, 10))]
    while len(rows) < 32:
        r, w = rng.randrange(0, 2**128), rng.randrange(0, 2**32)
        rows.append((rng.randrange(0, 2**128), r, w, rng.randrange(0, 2**64), 0))
        l, r, w, e, _ = rows[-1]
        rows[-1] = (l, r, w, e, decayed(l, r, w, e))
    return rows


# ---------------------------------------------------------------------------------------------------------------
# Scenarios through the real vault. Fixture constants must match CumulativePricingModel.t.sol.
# ---------------------------------------------------------------------------------------------------------------

A_CFG = HookAConfig(Q96, 500, 5000, 10_000 * E18, 20_000 * E18, 3600)
B_CFG = HookBConfig(Q96, 10**6 * E18, 20_000, 3600)
FLOOR_X96 = Q96  # vault floors 1:1 in both directions, as in VaultTestBase


def scenario_a(rng, n):
    h = HookA()
    h.configure(A_CFG, 0)
    now, rows = 0, []
    for _ in range(n):
        dt = rng.choice([0, 0, 1, 60, 900, 3600, 7200])
        now += dt
        zfo = rng.random() < 0.5
        amt = rng.randrange(1, 6000) * E18 + rng.randrange(0, E18)
        out, _fee, _lvl = h.quote(zfo, amt, now)
        code = OK
        if out == 0:
            code = ZERO
        elif not floor_ok(amt, out, FLOOR_X96):
            code = FLOOR
        if code == OK:
            h.swap(zfo, amt, now)
        rows.append((dt, zfo, amt, out if code == OK else 0, code, h.level[True], h.level[False]))
    return rows


def scenario_b(rng, n):
    h = HookB()
    h.configure(B_CFG, 0)
    now, rows = 0, []
    for _ in range(n):
        dt = rng.choice([0, 0, 1, 60, 900, 3600])
        now += dt
        zfo = rng.random() < 0.55
        amt = rng.randrange(1, 4000) * E18 + rng.randrange(0, E18)
        code, out = OK, 0
        try:
            out, _x2, _ = h.quote(zfo, amt, now)
            if out == 0:
                code = ZERO
            elif not floor_ok(amt, out, FLOOR_X96):
                code = FLOOR
        except Revert as e:
            assert e.name == "ImpactBoundExceeded"
            code = CAP
        if code == OK:
            h.swap(zfo, amt, now)
        else:
            out = 0
        # The state committed is the stored one; a failed swap leaves it as it was.
        rows.append((dt, zfo, amt, out, code, h.x))
    return rows


def sol_int(v):
    return f"int256({v})" if v >= 0 else f"-int256({-v})" if v != -(2**255) else "type(int256).min"


def main():
    rng = random.Random(0xC0FFEE)
    fee, cost, inv, xmax, dec = (fee_vectors(rng), cost_vectors(rng), inverse_vectors(rng),
                                 max_position_vectors(rng), decay_vectors(rng))
    sa, sb = scenario_a(rng, 60), scenario_b(rng, 60)
    codes_b = [r[4] for r in sb]
    assert codes_b.count(OK) >= 20 and codes_b.count(FLOOR) >= 3, codes_b  # the scenario must exercise both

    L = []
    w = L.append
    w("// SPDX-License-Identifier: MIT")
    w("// GENERATED by simulations/pricing/vectors.py from the Python reference model. Do not edit by hand.")
    w("pragma solidity 0.8.26;")
    w("")
    w("/// @notice Expected integers from the independent Python model (simulations/pricing/cumulative.py).")
    w("library PricingVectors {")
    w("    struct Fee { uint256 level; uint256 scale; uint256 baseFeePips; uint256 maxFeePips; uint256 expected; }")
    w("    struct Cost { int256 x; uint256 depth; uint256 priceX96; int256 expected; }")
    w("    struct Inverse { int256 cost; uint256 depth; uint256 priceX96; int256 expected; }")
    w("    struct MaxPos { uint256 depth; uint256 maxImpactPips; uint256 expected; }")
    w("    struct Decay { uint256 level; uint256 rate; uint256 window; uint256 elapsed; uint256 expected; }")
    w("    /// @dev code: 0 ok, 1 ImpactBoundExceeded, 2 PriceBelowFloor, 3 ZeroOutput.")
    w("    struct StepA { uint256 dt; bool zeroForOne; uint256 amountIn; uint256 amountOut; uint8 code;"
      " uint256 level0; uint256 level1; }")
    w("    struct StepB { uint256 dt; bool zeroForOne; uint256 amountIn; uint256 amountOut; uint8 code;"
      " int256 position; }")
    w("")

    def emit(name, typ, rows, fmt):
        w(f"    function {name}() internal pure returns ({typ}[] memory v) {{")
        w(f"        v = new {typ}[]({len(rows)});")
        for i, r in enumerate(rows):
            w(f"        v[{i}] = {typ}({fmt(r)});")
        w("    }")
        w("")

    emit("fee", "Fee", fee, lambda r: ", ".join(str(x) for x in r))
    emit("cost", "Cost", cost, lambda r: f"{sol_int(r[0])}, {r[1]}, {r[2]}, {sol_int(r[3])}")
    emit("inverse", "Inverse", inv, lambda r: f"{sol_int(r[0])}, {r[1]}, {r[2]}, {sol_int(r[3])}")
    emit("maxPosition", "MaxPos", xmax, lambda r: ", ".join(str(x) for x in r))
    emit("decay", "Decay", dec, lambda r: ", ".join(str(x) for x in r))
    emit("scenarioA", "StepA", sa,
         lambda r: f"{r[0]}, {str(r[1]).lower()}, {r[2]}, {r[3]}, {r[4]}, {r[5]}, {r[6]}")
    emit("scenarioB", "StepB", sb,
         lambda r: f"{r[0]}, {str(r[1]).lower()}, {r[2]}, {r[3]}, {r[4]}, {sol_int(r[5])}")
    L[-1:] = ["}"]
    with open(OUT, "w") as f:
        f.write("\n".join(L) + "\n")
    if shutil.which("forge"):  # keep `forge fmt --check` clean; formatting does not change any value
        for _ in range(3):  # forge fmt needs more than one pass on long literal rows to reach a fixed point
            if subprocess.run(["forge", "fmt", "--check", OUT], capture_output=True).returncode == 0:
                break
            subprocess.run(["forge", "fmt", OUT], check=True, capture_output=True)
    print(f"wrote {os.path.normpath(OUT)}: {len(fee)} fee, {len(cost)} cost, {len(inv)} inverse, "
          f"{len(xmax)} maxPosition, {len(dec)} decay; scenario A {len(sa)} steps "
          f"(codes {[r[4] for r in sa].count(0)} ok), scenario B {len(sb)} steps "
          f"(ok {codes_b.count(OK)}, cap {codes_b.count(CAP)}, floor {codes_b.count(FLOOR)}, zero {codes_b.count(ZERO)})")


if __name__ == "__main__":
    main()
