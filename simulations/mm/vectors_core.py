"""Conformance vectors for the shared economic core: Hook A and Hook B strategies and the reference brackets.

Run from the repository root:  python3 simulations/mm/vectors_core.py
Writes simulations/mm/vectors/shared_core_v1.json (deterministic). The Solidity libraries in src/pricing/ and
src/oracle/ReferenceBracket.sol are checked against it by test/pricing/SharedCoreVectors.t.sol, and any future
off-chain quoter must reproduce it exactly. Integers are decimal strings.
"""

from __future__ import annotations

import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(__file__))

from model import (  # noqa: E402
    MAX_AMOUNT,
    Q96,
    WAD,
    ActivityFeeConfig,
    InventoryConfig,
    Reference,
    Revert,
    VaultSnapshot,
    core_state,
    depth_per_share_for,
    hook_a_quote,
    hook_b_quote,
    mid_and_uncertainty,
    pair_bracket,
)

E18, E6 = 10**18, 10**6
OUT = os.path.join(os.path.dirname(__file__), "vectors", "shared_core_v1.json")
REVERT_CODES = {"ZeroInput": 1, "AmountTooLarge": 2, "SpreadTooWide": 7, "NoDepth": 8, "InventoryLimit": 9,
                "ZeroOutput": 10, "TradeImpactExceeded": 11, "ReferenceDivergence": 5,
                "DegenerateBracket": 12}


def s(x) -> str:
    return str(int(x))


def cfg(base, dev, min_edge=100, tau=WAD, max_spread=60_000, band=True):
    return InventoryConfig(tau, depth_per_share_for(tau, dev, base, min_edge), 2**95 - 1, base, min_edge,
                           max_spread, dev, band)


def strategy_case(rng, i):
    c = cfg(rng.choice([300, 1_000, 2_000, 5_000]), rng.choice([50_000, 150_000, 300_000]),
            min_edge=rng.choice([0, 1, 100]), band=i % 4 != 3)
    base = rng.randint(10**3, 10**8) * E18
    dev = rng.uniform(-0.35, 0.35)
    snap = VaultSnapshot(int(base * (1 + dev)), int(base * (1 - dev)), base)
    ref = Reference(int(rng.uniform(0.05, 20) * Q96), rng.randint(0, 6_000))
    zfo = rng.random() < 0.5
    amt = rng.choice([0, 1, rng.randint(1, 10**6), rng.randint(1, 10**4) * E18, rng.randint(1, base // 3),
                      MAX_AMOUNT, MAX_AMOUNT + 1]) if i % 10 == 0 else rng.choice(
        [rng.randint(1, 10**6), rng.randint(1, 10**4) * E18, rng.randint(1, base // 4)])
    hook = "A" if i % 2 == 0 else "B"
    case = {"note": f"random {i}", "hook": hook, "config": {k: (v if isinstance(v, bool) else s(v)) for k, v in c.__dict__.items()},
            "vault": {"n1": s(snap.n1), "shares": s(snap.shares)},
            "reference": {"priceX96": s(ref.price_x96), "uncertaintyPips": s(ref.uncertainty)},
            "zeroForOne": zfo, "amountIn": s(amt)}
    fee = ActivityFeeConfig(rng.choice([0, 100, 500]), rng.choice([1_000, 5_000, 20_000]),
                            rng.randint(1, 10**5) * E18, rng.randint(1, 10**5) * E18, 0)
    level = rng.choice([0, rng.randint(0, 2 * 10**5) * E18])
    markup = rng.choice([0, 0, 500, 2_000])
    impact = rng.choice([999_999, 20_000, 3_000])
    case["strategy"] = ({"baseFeePips": s(fee.base), "maxFeePips": s(fee.mx), "scale0": s(fee.scale0),
                         "scale1": s(fee.scale1), "levelNow": s(level)} if hook == "A"
                        else {"markupPips": s(markup), "maxTradeImpactPips": s(impact)})
    try:
        cs = core_state(c, snap, ref)
        q = (hook_a_quote(cs, fee, level, zfo, amt) if hook == "A"
             else hook_b_quote(cs, markup, impact, zfo, amt))
        case["expect"] = {"revert": 0, "amountOut": s(q.amount_out), "inventoryAfter": s(q.i_after),
                          "fee": s(q.fee), "newLevel": s(q.new_level), "cap": s(cs.cap)}
    except Revert as e:
        case["expect"] = {"revert": REVERT_CODES[e.name]}
    return case


def bracket_case(rng, i):
    e = rng.choice([12, 0, -12, 30, -30, 6])
    a0 = rng.randint(10**6, 10**30)
    a1 = rng.randint(10**6, 10**30)
    d0, d1 = rng.choice([0, 3_000, 5_000, 999_999]), rng.choice([0, 3_000, 5_000])
    lo, hi = pair_bracket(a0, a1, d0, d1, e)
    case = {"note": f"bracket {i}", "a0": s(a0), "a1": s(a1), "d0": s(d0), "d1": s(d1), "e": s(e),
            "low": s(lo), "high": s(hi)}
    lo2 = lo + rng.randint(0, max(1, (hi - lo)))
    hi2 = hi - rng.randint(0, max(1, (hi - lo))) if rng.random() < 0.8 else lo2 - 1
    case["intersect"] = {"low": s(lo2), "high": s(max(hi2, 0))}
    try:
        m, u = mid_and_uncertainty(lo2, max(hi2, 0))
        case["intersect"]["expect"] = {"revert": 0, "mid": s(m), "uncertaintyPips": s(u)}
    except Revert as err:
        case["intersect"]["expect"] = {"revert": REVERT_CODES[err.name]}
    return case


def main():
    rng = random.Random(20261111)
    strategies = [strategy_case(rng, i) for i in range(240)]
    brackets = [bracket_case(rng, i) for i in range(60)]
    # The observed Unichain example (2026-11-10): USDC/USD 0.99972, ETH/USD 2,048.39, both 18 decimals.
    lo, hi = pair_bracket(999_720_000_000_000_000, 2_048_390_000_000_000_000_000, 3_000, 5_000, 12)
    m, u = mid_and_uncertainty(lo, hi)
    brackets.insert(0, {"note": "Unichain Chainlink USDC/USD and ETH/USD, WETH per USDC raw",
                        "a0": s(999_720_000_000_000_000), "a1": s(2_048_390_000_000_000_000_000), "d0": "3000",
                        "d1": "5000", "e": "12", "low": s(lo), "high": s(hi),
                        "intersect": {"low": s(lo), "high": s(hi),
                                      "expect": {"revert": 0, "mid": s(m), "uncertaintyPips": s(u)}}})
    doc = {"format": "porkfolio.shared-core.vectors/1", "source": "simulations/mm/model.py (SYNTHETIC inputs)",
           "revertCodes": REVERT_CODES, "strategies": strategies, "brackets": brackets}
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        json.dump(doc, f, indent=1, sort_keys=True)
        f.write("\n")
    n_rev = sum(c["expect"]["revert"] != 0 for c in strategies)
    print(f"wrote {OUT}: {len(strategies)} strategy cases ({n_rev} refusals), {len(brackets)} bracket cases")


if __name__ == "__main__":
    main()
