"""Conformance vectors for the vault risk boundary (`src/risk/VaultRiskBoundary.sol`).

Run from the repository root:  python3 simulations/mm/vectors_risk.py
Writes simulations/mm/vectors/vault_risk_v1.json (source of truth) and vault_risk_v1.csv (its view for Solidity, one
case per line: price, uncertainty, edge, F0, F1, shares, target, tolerance, L, holding, amountOut, refused 0/1).
Deterministic.
"""

from __future__ import annotations

import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(__file__))

from model import Q96, WAD, Revert, check_inventory, dynamic_floors, inventory_floor  # noqa: E402

D = os.path.join(os.path.dirname(__file__), "vectors")


def main():
    rng = random.Random(20261112)
    cases = []
    for i in range(300):
        p = rng.choice([Q96, rng.randint(1, 2**160 - 1), rng.randint(2**60, 2**130)])
        u, e = rng.choice([0, rng.randint(0, 60_000)]), rng.choice([0, rng.randint(0, 1_000)])
        f0, f1 = dynamic_floors(p, u, e)
        shares = rng.choice([1_000, rng.randint(10**18, 10**30)])
        tau = rng.choice([WAD, rng.randint(1, 10**24)])
        kappa = rng.choice([0, 150_000, rng.randint(0, 1_000_000)])
        floor_ = inventory_floor(shares, tau, kappa)
        holding = rng.choice([floor_, floor_ + rng.randint(0, 10**24), max(0, floor_ - rng.randint(0, 10**18))])
        out = rng.choice([0, rng.randint(0, holding + 1), holding - floor_ if holding >= floor_ else 1])
        try:
            check_inventory(holding, out, floor_)
            refused = 0
        except Revert:
            refused = 1
        cases.append({k: str(v) for k, v in dict(priceX96=p, uncertainty=u, edge=e, floor0=f0, floor1=f1, shares=shares,
                                                   target=tau, tolerance=kappa, inventoryFloor=floor_, holding=holding,
                                                   amountOut=out, refused=refused).items()})
    os.makedirs(D, exist_ok=True)
    with open(os.path.join(D, "vault_risk_v1.json"), "w") as f:
        json.dump({"format": "porkfolio.vault-risk.vectors/1", "source": "simulations/mm/model.py", "cases": cases}, f,
                  indent=1, sort_keys=True)
        f.write("\n")
    keys = ["priceX96", "uncertainty", "edge", "floor0", "floor1", "shares", "target", "tolerance", "inventoryFloor",
            "holding", "amountOut", "refused"]
    with open(os.path.join(D, "vault_risk_v1.csv"), "w") as f:
        f.write("\n".join(",".join(c[k] for k in keys) for c in cases))
    print(f"wrote vault_risk_v1.json and .csv: {len(cases)} cases, {sum(c['refused'] == '1' for c in cases)} refusals")


if __name__ == "__main__":
    main()
