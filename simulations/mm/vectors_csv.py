"""Flat CSV views of the JSON conformance vectors, for the Solidity tests.

Run from the repository root (after vectors.py and vectors_core.py):  python3 simulations/mm/vectors_csv.py

The JSON files are the source of truth. Foundry's JSON cheatcodes copy the whole document into memory on every call,
which runs out of memory over a few hundred cases; one CSV line per case is read once and split. Column order is fixed
below and in test/pricing/SharedCoreVectors.t.sol. Empty fields are "-".
"""

from __future__ import annotations

import json
import os

D = os.path.join(os.path.dirname(__file__), "vectors")
CFG = ["target_per_share", "depth_per_share", "depth_max", "base_spread", "min_edge", "max_spread", "max_deviation"]


def cfg_fields(c):
    """The seven integer fields plus band_edge (absent in the Phase 1B-4 v1 vectors, which are mid-edge: 0)."""
    return [c[k] for k in CFG] + ["1" if c.get("band_edge") is True else "0"]


def main():
    v1 = json.load(open(os.path.join(D, "inventory_quote_v1.json")))
    rows = []
    for q in v1["quotes"]:
        e = q["expect"]
        rows.append([str(int(q["zeroForOne"])), q["amountIn"], q["vault"]["n1"], q["vault"]["shares"],
                     q["reference"]["priceX96"], q["reference"]["uncertaintyPips"], *cfg_fields(q["config"]),
                     e.get("revert", "-"),
                     *([e[k] for k in ("amountOut", "inventoryBefore", "inventoryAfter", "halfSpreadPips", "cap",
                                       "depth")] if "revert" not in e else ["-"] * 6)])
    write("inventory_quote_v1.csv", rows)

    core = json.load(open(os.path.join(D, "shared_core_v1.json")))
    rows = []
    for c in core["strategies"]:
        st = c["strategy"]
        sp = ([st["baseFeePips"], st["maxFeePips"], st["scale0"], st["scale1"], st["levelNow"]] if c["hook"] == "A"
              else [st["markupPips"], st["maxTradeImpactPips"], "0", "0", "0"])
        e = c["expect"]
        rows.append([c["hook"], str(int(c["zeroForOne"])), c["amountIn"], c["vault"]["n1"], c["vault"]["shares"],
                     c["reference"]["priceX96"], c["reference"]["uncertaintyPips"], *cfg_fields(c["config"]),
                     *sp, str(e["revert"]),
                     *([e[k] for k in ("amountOut", "inventoryAfter", "fee", "newLevel", "cap")] if e["revert"] == 0
                       else ["-"] * 5)])
    write("shared_core_strategies_v1.csv", rows)

    rows = []
    for b in core["brackets"]:
        x = b["intersect"]
        e = x["expect"]
        rows.append([b["a0"], b["a1"], b["d0"], b["d1"], b["e"], b["low"], b["high"], x["low"], x["high"],
                     str(e["revert"]), *([e["mid"], e["uncertaintyPips"]] if e["revert"] == 0 else ["-", "-"])])
    write("shared_core_brackets_v1.csv", rows)


def write(name, rows):
    with open(os.path.join(D, name), "w") as f:
        f.write("\n".join(",".join(r) for r in rows))
    print(f"wrote {name}: {len(rows)} rows")


if __name__ == "__main__":
    main()
