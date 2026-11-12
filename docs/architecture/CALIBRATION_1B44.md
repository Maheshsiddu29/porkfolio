# Porkfolio — κ and hook calibration (Phase 1B-4.4)

**Status: SYNTHETIC research.** All worlds and trade streams are generated with fixed seeds. They are not historical
order flow. **Recommendations here are inputs to R-4 and R-6, not approved configuration.** No tolerance is hardcoded
in the protocol: `kappa` is a governed vault parameter (`setInventoryBounds`).

Commands (from the repository root):
- `python3 simulations/mm/kappa_calibration.py > simulations/mm/results/phase144_kappa.md` (~40 s on 10 cores);
- `python3 simulations/mm/hook_routing.py > simulations/mm/results/phase144_routing.md` (~4 s).

## 1. Inventory tolerance κ ∈ {1, 2, 5, 10, 15}%

### 1.1 Normal operation and compromise (agent-based model; held-out seeds; 9 regimes; attacks 7 × 4 seeds)

| κ | fill % median, push-only / + fresh | max depletion / κ | LP vs HODL bps median, push / fresh | LP exits instant | recovery episodes (>10% → <5%) | A4 compromise worst bps, push / fresh | A4 / κ |
|---|---|---|---|---|---|---|---|
| 1% | 4.14 / 35.20 | 0.99 / 1.00 | 32.0 / 127.3 | 100% | 0 | −39 / −13 | 0.39 / 0.13 |
| 2% | 4.56 / 36.99 | 0.99 / 1.00 | 40.6 / 151.5 | 100% | 0 | −89 / −39 | 0.44 / 0.19 |
| 5% | 4.70 / 37.29 | 0.99 / 1.00 | 48.5 / 166.9 | 100% | 0 | −233 / −111 | 0.47 / 0.22 |
| 10% | 4.81 / 37.49 | 0.99 / 1.00 | 51.4 / 169.7 | 100% | 0 | −386 / −254 | 0.39 / 0.25 |
| 15% | 4.81 / 37.61 | 0.99 / 1.00 | 52.7 / 170.1 | 100% | 68 / 107 | −514 / −395 | 0.34 / 0.26 |

**Readings:**
- **Inventory depletion always reaches the tolerance.** Max deviation / κ ≈ 1.0 at every κ: ordinary flow drives
  inventory to the floor, so κ is capital that *will* be used, not a tail limit.
- **Availability barely depends on κ.** Push-only fill rises from 4.1% to 4.8% between 1% and 15%; with fresh prices,
  from 35% to 38%. What moves availability is the reference width (§ORACLE_RELAYER), not κ.
- **Economic result rises with κ, with diminishing returns.** Push-only LP vs HODL rises from +32 to +53 bps; most of
  the gain is reached by 5%.
- **Compromise loss is close to linear in κ:** about 0.35–0.47 κ push-only, 0.13–0.26 κ with fresh prices.
- **Withdrawals** are 100% instant at every κ in these worlds.
- **Recovery episodes** (deviation above 10% then back below 5%) occur only when κ > 10%.

### 1.2 Worst LP shortfall against its own entry value (exact-integer adversary owning every price)

| κ | never re-centred | re-centred every 50 steps | every 10 steps |
|---|---|---|---|
| 1% | 2.39% (2.39 κ) | 2.39% | 2.35% (2.35 κ) |
| 2% | 5.51% (2.76 κ) | 5.52% | 4.64% (2.32 κ) |
| 5% | 11.18% (2.24 κ) | 11.18% | 9.49% (1.90 κ) |
| 10% | 20.99% (2.10 κ) | 20.99% | 18.12% (1.81 κ) |
| 15% | 40.98% (2.73 κ) | 41.13% | 28.69% (1.91 κ) |

- **Validation:** 0 T1 violations and 0 T2 breaches in every cell. That is 60 sequences × 300 steps per cell, with the
  worst of 6 price vectors, including a full depeg of either asset.
- **Re-centring helps less than hoped.** The dominant effect is structural:
  - honest flow can lift one asset to `τ (1 + κ)` while the other sits at its floor;
  - so an LP entering then has up to `2κ` of that asset above the floor;
  - measured at a price vector where the other asset is worthless, that is about `2κ` of its entry value.
- **Re-centring removes only the fee/gain part.** That is why it helps most at high κ.
- **Plan for a per-LP worst case of about 2–3 κ**, not κ.

### 1.3 Recommendation (R-4)

- **First mainnet candidate: κ = 1%,** with the vault-scope exposure cap ≤ 50% (which also bounds the governor's
  queue-check griefing; `GOVERNANCE_SECURITY.md` §3.3).
  - **Costs:** about 0.4–0.7 percentage points of fill against 5–15%, and about 16–20 bps of LP vs HODL against 5%.
  - **Buys:** a compromise loss about 6× smaller than at 5% (−39 vs −233 bps) and a per-LP worst case of about 2.4% of
    entry value.
- **κ = 2%** is the next step once the system has run without incident.
- **5%, 10% and 15%:** testnet stress scenarios only, labelled as such.
- **Re-centring policy:** the guardian or a keeper raises `τ_a` to the current holding whenever it exceeds `τ_a` by
  more than κ/2, at least daily. It is immediate and tightening-only.

**Limitations:**
- synthetic worlds;
- no gas or MEV model;
- the fresh-price columns assume 95% relayer availability;
- the adversary in §1.2 owns every price but not governance.

## 2. Hook A and Hook B on the same trade sequences

Both hooks price from the **same shared core** (`InventoryPricing`). That is unchanged and is the economic risk
constraint. The strategies:

| Hook | Strategy | Justification |
|---|---|---|
| **A** | cumulative activity fee: 0 → max over 20,000 tokens of decayed same-direction flow (1 h window), taken from the input before the core prices the rest | **activity-sensitive.** Bursts of one-directional flow are more likely informed; isolated trades pay almost nothing extra |
| **B** | flat markup on the input; refuses a trade more than 2% worse than the reference | **bounded impact.** A predictable, size-independent surcharge; very large trades are refused instead of filled deep into the curve |

### 2.1 Routing study

Setup: 3 seeds × 1,200 trades, lognormal sizes with median 1,500 tokens, 70% direction persistence, 1:1 reference.
`simulations/mm/results/phase144_routing.md`.

- **Core violations: 0 in all 32 parameter sets.** No router (best single hook, or the best of 22 splits across A and
  B in either order) ever received more than the strategy-free core pays for the same total from the same state.
- **Solidity counterpart:** `testFuzz_routingAcrossHooks_neverBeatsTheCore`, real hooks, 1–8 random pieces, random
  hooks, up to an hour between pieces; 1,000 runs, 0 failures.
- **Routing value is small and bounded by the difference between the strategies.** Splitting across hooks beats the
  better single hook by at most **0.53 bps on average** and **4.9 bps on one trade** (Hook A ≤ 50 bp, Hook B + 20 bp).
- **That is two venues competing, not an exploit.** The core charge is paid in full, and each hook's fee telescopes on
  its own state. The Python counterexample `test_counterexample_split_across_hooks_can_beat_the_best_single_hook`
  shows the mechanism.

**Differentiation needs `0 < B markup < A maximum fee`:**
- **B markup 0:** B always wins, and A receives no flow.
- **B markup ≥ A's maximum:** A always wins.
- **In between:** A wins small and medium trades (its fee is low at low activity), B wins large ones (A's cumulative
  fee rises over the trade).

| Setting (κ 1%, fresh u = 15 bp) | A's share of filled notional: small / mid / large | trader cost bps | LP vs hold bps |
|---|---|---|---|
| A ≤ 20 bp, B + 10 bp | 0.91 / 0.85 / 0.75 | 51.0 | 48.3 |
| A ≤ 50 bp, B + 10 bp | 0.89 / 0.75 / 0.28 | 52.2 | 49.1 |
| A ≤ 50 bp, B + 20 bp | 0.90 / 0.83 / 0.66 | 57.6 | 54.6 |

### 2.2 Recommendation (R-6)

- **Hook A:** base 0, maximum 50 bp over 20,000 tokens per hour.
- **Hook B:** 10 bp markup, 2% per-trade bound.

With these, A serves small and medium flow and B serves large trades. Routing gains stay under 3 bps per trade. The
1B-4.3 setting (A ≤ 20 bp) leaves B with only a quarter of large trades. No new feature was added to make the hooks
differ.

**Limitations:**
- fixed reference;
- no external market;
- the "filled %" column is the share of offered notional the shared inventory cap allows (about 51% at κ 1%, 73% at
  2%), not a market fill rate.
