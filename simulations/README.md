# simulations/

Python models that sit beside the Solidity code. Nothing here is historical market data.

| Path | What it is |
|---|---|
| `pricing/cumulative.py` | Integer reference model of Hook A and Hook B cumulative pricing, mirroring the Solidity arithmetic operation by operation, plus the pricing it replaced and the vault's price-floor check |
| `pricing/test_cumulative.py` | Economic-consistency and adversarial checks of that model (split invariance, round trips, sandwiches against the vault floors, decay, parameter changes, rounding) |
| `pricing/vectors.py` | Generates `test/utils/PricingVectors.sol`, the expected integers for the Solidity differential tests |
| `pricing/economics.py` | Synthetic comparison of old and new pricing on identical generated trade sequences |
| `mm/model.py` | Integer model of the Phase 1B-4 market-making candidates (Hook B, Hook B with spread, inventory potential with an external reference) and of the fail-closed reference resolution |
| `mm/rootcause.py` | Why Hook B refuses inventory-reducing trades: worked example and attribution over the Phase 1B-3 sequences |
| `mm/test_mm.py` | Property and adversarial checks of the candidates (straddle bound, splits, cycles, shared inventory, references, Solidity forms) |
| `mm/vectors.py` | Writes `mm/vectors/inventory_quote_v1.json`, integer conformance vectors for any implementation of the quote |
| `mm/test_core.py` | Shared economic core: Hook A and Hook B strategies on one reserve, bracket reference (Phase 1B-4.1) |
| `mm/vectors_core.py`, `mm/vectors_csv.py` | Shared-core conformance vectors (JSON) and their CSV views read by `test/pricing/` |
| `mm/simulate.py` | Matched synthetic simulation of the candidates on a model of the shared vault; calibration grids; writes `mm/results/` |

Standard library only (Python 3.11). `simulate.py` uses `concurrent.futures` processes; results do not depend on the
number of workers. From the repository root:

```
python3 -m unittest discover -s simulations/pricing -v
python3 simulations/pricing/vectors.py      # rewrites test/utils/PricingVectors.sol
python3 simulations/pricing/economics.py    # prints the synthetic comparison tables

python3 -m unittest discover -s simulations/mm -v
python3 simulations/mm/rootcause.py
python3 simulations/mm/vectors.py           # rewrites simulations/mm/vectors/inventory_quote_v1.json
python3 simulations/mm/simulate.py --calibrate > simulations/mm/results/calibration.md   # ~4 min on 10 cores
python3 simulations/mm/simulate.py > simulations/mm/results/heldout.md                   # ~1 min on 10 cores
python3 simulations/mm/vectors_core.py && python3 simulations/mm/vectors_csv.py
python3 simulations/mm/simulate.py --phase141 > simulations/mm/results/phase141.md         # ~75 s on 10 cores
```

Every random choice uses a fixed seed, so each command prints the same result on every run.
