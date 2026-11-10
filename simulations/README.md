# simulations/

Python models that sit beside the Solidity code. Nothing here is historical market data.

| Path | What it is |
|---|---|
| `pricing/cumulative.py` | Integer reference model of Hook A and Hook B cumulative pricing, mirroring the Solidity arithmetic operation by operation, plus the pricing it replaced and the vault's price-floor check |
| `pricing/test_cumulative.py` | Economic-consistency and adversarial checks of that model (split invariance, round trips, sandwiches against the vault floors, decay, parameter changes, rounding) |
| `pricing/vectors.py` | Generates `test/utils/PricingVectors.sol`, the expected integers for the Solidity differential tests |
| `pricing/economics.py` | Synthetic comparison of old and new pricing on identical generated trade sequences |

Standard library only (Python 3.11). From the repository root:

```
python3 -m unittest discover -s simulations/pricing -v
python3 simulations/pricing/vectors.py      # rewrites test/utils/PricingVectors.sol
python3 simulations/pricing/economics.py    # prints the synthetic comparison tables
```

Every random choice uses a fixed seed, so each command prints the same result on every run.
