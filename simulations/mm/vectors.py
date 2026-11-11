"""Conformance vectors for the inventory quote (candidate C) and its reference resolution.

Run from the repository root:  python3 simulations/mm/vectors.py
Writes simulations/mm/vectors/inventory_quote_v1.json (deterministic: same bytes on every run).

Every implementation of the quote (Solidity settlement, this Python model, a future Rust or TypeScript quoter) must
reproduce each case exactly: the same integers, or a refusal with the same reason. Integers are decimal strings so
that no JSON reader rounds them. The format is specified in `docs/architecture/QUOTE_INTERFACE_SPEC.md`.
"""

from __future__ import annotations

import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(__file__))

from model import (  # noqa: E402
    MAX_AMOUNT,
    PIPS,
    Q96,
    WAD,
    FeedReading,
    InventoryConfig,
    Reference,
    ReferencePolicy,
    Revert,
    VaultSnapshot,
    depth_per_share_for,
    quote_inventory,
    resolve_reference,
)

E18, E6 = 10**18, 10**6
OUT = os.path.join(os.path.dirname(__file__), "vectors", "inventory_quote_v1.json")


def cfg(spread, dev, min_edge=100, tau=WAD, max_spread=50_000, depth_max=2**95 - 1):
    return InventoryConfig(tau, depth_per_share_for(tau, dev, spread, min_edge), depth_max, spread, min_edge,
                           max_spread, dev)


def s(x: int) -> str:
    return str(x)


def quote_case(c: InventoryConfig, snap: VaultSnapshot, ref: Reference, zfo: bool, amt: int, note: str) -> dict:
    case = {
        "note": note,
        "config": {k: s(v) for k, v in c.__dict__.items()},
        "vault": {"n0": s(snap.n0), "n1": s(snap.n1), "shares": s(snap.shares)},
        "reference": {"priceX96": s(ref.price_x96), "uncertaintyPips": s(ref.uncertainty)},
        "zeroForOne": zfo,
        "amountIn": s(amt),
    }
    try:
        q = quote_inventory(c, snap, ref, zfo, amt)
        case["expect"] = {"amountOut": s(q.amount_out), "inventoryBefore": s(q.i_before),
                          "inventoryAfter": s(q.i_after), "halfSpreadPips": s(q.half_spread), "cap": s(q.cap),
                          "depth": s(q.depth)}
    except Revert as e:
        case["expect"] = {"revert": e.name}
    return case


def reference_case(primary, secondary, now, pol, history, note) -> dict:
    case = {
        "note": note,
        "policy": {k: (v if isinstance(v, bool) else s(v)) for k, v in pol.__dict__.items()},
        "primary": {"priceX96": s(primary.price_x96), "updatedAt": s(primary.updated_at)},
        "secondary": None if secondary is None else {"priceX96": s(secondary.price_x96),
                                                     "updatedAt": s(secondary.updated_at)},
        "history": [{"priceX96": s(h.price_x96), "updatedAt": s(h.updated_at)} for h in history],
        "now": s(now),
    }
    try:
        r = resolve_reference(primary, secondary, now, pol, history)
        case["expect"] = {"priceX96": s(r.price_x96), "uncertaintyPips": s(r.uncertainty)}
    except Revert as e:
        case["expect"] = {"revert": e.name}
    return case


def main():
    quotes, refs = [], []
    base = cfg(2_000, 150_000)
    flat = VaultSnapshot(10**6 * E18, 10**6 * E18, 10**6 * E18)
    one = Reference(Q96, 0)
    # Hand-picked cases first: each exercises one rule.
    quotes += [
        quote_case(base, flat, one, True, 1_000 * E18, "balanced vault, vault sells currency1"),
        quote_case(base, flat, one, False, 1_000 * E18, "balanced vault, vault buys currency1"),
        quote_case(base, flat, one, True, 1, "dust: refused, never rounded toward the trader"),
        quote_case(base, flat, one, True, 0, "zero input"),
        quote_case(base, flat, one, True, MAX_AMOUNT + 1, "above int128"),
        quote_case(base, flat, one, True, 200_000 * E18, "would pass the inventory cap"),
        quote_case(base, VaultSnapshot(12 * 10**5 * E18, 8 * 10**5 * E18, 10**6 * E18), one, False, 50_000 * E18,
                   "beyond the cap (20% short currency1): inward trade priced on the linear extension"),
        quote_case(base, VaultSnapshot(12 * 10**5 * E18, 8 * 10**5 * E18, 10**6 * E18), one, True, 1_000 * E18,
                   "beyond the cap: outward trade refused"),
        quote_case(base, flat, Reference(Q96, 49_000), True, 1_000 * E18, "uncertainty pushes spread past max"),
        quote_case(base, VaultSnapshot(0, 0, 0), one, True, 1_000 * E18, "no shares: no depth"),
        quote_case(cfg(2_000, 150_000), VaultSnapshot(3_000_000 * E6, 1_000 * E18, 1_000 * E18),
                   Reference(Q96 * 10**12 // 3_000, 500), True, 10_000 * E6, "6/18 decimals, stable in"),
        quote_case(cfg(2_000, 150_000), VaultSnapshot(3_000_000 * E6, 1_000 * E18, 1_000 * E18),
                   Reference(Q96 * 10**12 // 3_000, 500), False, 3 * E18, "6/18 decimals, asset in"),
    ]
    rng = random.Random(20261110)
    for i in range(200):
        c = cfg(rng.choice([300, 1_000, 2_000, 5_000]), rng.choice([50_000, 150_000, 300_000]),
                min_edge=rng.choice([0, 1, 100]))
        base_n = rng.randint(10**3, 10**8) * E18
        dev = rng.uniform(-0.4, 0.4)
        snap = VaultSnapshot(int(base_n * (1 + dev)), int(base_n * (1 - dev)), base_n)
        ref = Reference(int(rng.uniform(0.05, 20) * Q96), rng.randint(0, 5_000))
        zfo = rng.random() < 0.5
        amt = rng.choice([rng.randint(1, 10**6), rng.randint(1, 10**4) * E18, rng.randint(1, base_n // 4)])
        quotes.append(quote_case(c, snap, ref, zfo, amt, f"random {i}"))

    pol = ReferencePolicy(max_age=3_600, max_divergence=10_000, secondary_max_age=86_400, missing_penalty=1_000,
                          age_widen=500, vol_mult=50, vol_horizon=300)
    p = FeedReading(Q96, 1_000)
    hist = [FeedReading(Q96 * 998 // 1000, 880), FeedReading(Q96 * 1001 // 1000, 940), p]
    refs += [
        reference_case(p, FeedReading(Q96 * 1003 // 1000, 900), 1_600, pol, hist, "fresh, 0.3% divergence, vol"),
        reference_case(p, None, 1_600, pol, [], "secondary missing: penalty, no history"),
        reference_case(p, p, 4_601, pol, [], "stale primary"),
        reference_case(FeedReading(0, 0), p, 1_600, pol, [], "primary unavailable"),
        reference_case(p, FeedReading(Q96 * 102 // 100, 900), 1_600, pol, [], "divergence above limit"),
        reference_case(FeedReading(Q96, 2_000), p, 1_600, pol, [], "primary timestamp in the future"),
    ]
    doc = {
        "format": "porkfolio.inventory-quote.vectors/1",
        "units": {"amounts": "raw token units", "priceX96": "raw currency1 per raw currency0, Q64.96",
                  "pips": "1,000,000 = 100%", "perShare": "WAD (1e18)"},
        "source": "simulations/mm/model.py (SYNTHETIC inputs; not market data)",
        "quotes": quotes,
        "references": refs,
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        json.dump(doc, f, indent=1, sort_keys=True)
        f.write("\n")
    n_rev = sum("revert" in q["expect"] for q in quotes)
    print(f"wrote {OUT}: {len(quotes)} quote cases ({n_rev} refusals), {len(refs)} reference cases")


if __name__ == "__main__":
    main()
