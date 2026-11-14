# Porkfolio — Optional credentialed relayer for RedStone (Phase 1B-4.4)

> **Correction (G04, 2026-11-13).** The uncertainties below use the pre-G04 definition (measured from the mid on both
> sides). With the corrected multiplicative definition (`docs/security/G04_ORACLE_SAFETY.md` §5, F-1) the push-only
> reading is 8,268 pips instead of 8,200 and the fresh-tier reading 3,010 instead of 3,000. The trader-cost figures in
> §4 were measured with the earlier values.

**Status:**
- The fresh tier is **IMPLEMENTED** in `PriceRiskAdapter` and **TESTED** locally (mock feeds; real vault, hooks and
  PoolManager).
- Permissionless submission is **MEASURED** on Unichain (read-only; §2).
- **No relayer was operated and no credential was obtained.**
- Whether to use a relayer at all is decision R-5. The push feeds remain the permissionless fallback.

## 1. Four permissions, kept apart

| Permission | Who holds it | Evidence |
|---|---|---|
| **Obtain** fresh signed RedStone packages | whoever holds a RedStone gateway credential (HTTP 403 without one) | `FRESH_PRICE_EVALUATION.md` §6 (MEASURED, 1B-4.3) |
| **Submit** a package on-chain | **anyone**. RedStone's Unichain push adapter accepts the relayer's calldata from an unrelated sender | §2 below; 1B-4.3 `eth_call` replay from `0x…dEaD` |
| **Verify** the package | RedStone's on-chain adapter: authorised signer set, timestamps must increase (no roll-back). `PriceRiskAdapter` only reads the stored value and applies its own age, deviation and divergence rules; the vault re-checks the reading and enforces its floors | RedStone contract (external); `test/oracle/PriceRiskAdapter.t.sol` |
| **Trade** | anyone, through the hooks. No swap reads anything from a relayer, carries a payload, or waits for one | `test/integration/RelayerOutage.t.sol` |

**What a relayer can do:**
- choose *when* to submit a package;
- withhold packages.

**What it cannot do:**
- set a price;
- submit an older package;
- touch any vault, hook, governor or adapter state;
- change pricing policy, which is immutable in the adapter or governed through `VaultGovernor`.

Its worst behaviour is timing:
- submitting just before a trade it benefits from: the ordinary latency risk, bounded by the band and, beyond it, by
  the inventory floor;
- or stopping, which widens the band (§3).

## 2. Permissionless submission

- **1B-4.3.** The latest relayer calldata to RedStone's adapter `0xFB1267A29C0aa19daae4a483ea895862A69e4AA5`
  succeeded as an `eth_call` from an unrelated address at the previous block.
- **This phase: NOT reproduced.** I tried to turn that replay into a pinned fork test. A `cast logs` search of the
  adapter over the latest 1,500 blocks (head 63,694,217) returned no events, and a 3,000-block query timed out on the
  public RPC. Finding a fresh relayer transaction would need a block explorer or an indexed RPC, so the test was not
  written.
- **Evidence for permissionless submission therefore remains the 1B-4.3 measurement.** Re-check it on Sepolia before
  relying on it.

## 3. The gap this phase found, and the fix

**The gap: with the Phase 1B-4.3 adapter, a relayer could help only by making itself mandatory.** Each source had one
deviation and one staleness limit.
- To narrow the band, the RedStone source had to be configured with the relayer's cadence (for example 120 s).
- The moment the relayer stopped, that source went stale. With two sources required, every shared-core swap would
  halt.
- Configured with RedStone's own 6-hour heartbeat instead, the band never narrowed.

**The fix: an optional fresh tier per source** (`PriceRiskAdapter.Source.freshMaxAge`, `freshDeviation0/1`; zero
disables it). Each leg picks its tier from its own age:

| Leg age | Deviation used | Example (RedStone legs, fresh tier 120 s / ±15 bp) |
|---|---|---|
| ≤ `freshMaxAge` | `freshDeviation` | ±15 bp per leg |
| ≤ `maxAge` | `deviation` (the provider's push threshold + margin) | ±51 bp per leg |
| older | source not live | with `minSources = 2`, reads revert; with 1, Chainlink alone |

**Validation:** the fresh tier must be strictly shorter and no wider than the push tier, and all-zero when disabled
(`test_freshTier_configValidation`).

**What does not change:**
- the vault (0 bytes);
- the hooks;
- the governor.

A new adapter is still a governed `setRiskAdapter` (DELAY).

**Assumption, stated plainly.** `freshDeviation` assumes the market cannot move more than that within `freshMaxAge`.
It is not a provider guarantee. If the market moves faster, fills can be worse than the band says. The inventory floor
is what bounds that loss (`INVENTORY_PROTECTION.md`).

## 4. Failure and recovery (TESTED)

Covered by `test_freshTier_relayerOutageAndRecovery` (adapter) and
`test_relayerOutage_widensThenHaltsOnlyWithTheProvider_recoversByItself` (vault, both hooks, PoolManager).

| Phase | Band (uncertainty) | Swaps | LP exits |
|---|---|---|---|
| relayer running (legs 30 s old) | **±30 bp** (3,000 pips) | fill on both hooks | work |
| relayer stopped > 120 s | **±82 bp** (8,200 pips), exactly the push-only reading | fill on both hooks (worse quotes) | work |
| provider's own heartbeat also lapsed | none (`minSources = 2`) | refused, fail closed | **work** (no LP path reads the adapter) |
| anyone pushes again | ±30 bp | fill again, **no governance action** | work |

Trader cost for 200 tokens through Hook B at 1:1 (10 bp markup, 10 bp base spread):
- fresh: output 198.99, about 50 bp;
- push-only: output 197.96, about 102 bp.

## 5. Quote competitiveness and safe-trade availability (SYNTHETIC)

From the agent-based κ grid (`simulations/mm/results/phase144_kappa.md`). There, "fresh" means a 15 bp source
available 95% of the time:

| κ | push-only fill % (median) | push + fresh fill % (median) | push-only A4 compromise, worst bps | push + fresh A4 |
|---|---|---|---|---|
| 1% | 4.14 | 35.20 | −39.0 | −13.1 |
| 2% | 4.56 | 36.99 | −88.9 | −38.5 |
| 5% | 4.70 | 37.29 | −232.7 | −111.3 |

**Fresh prices are the largest single lever on availability (≈ 8×).** In these worlds they also reduce compromise
losses, because a narrower band leaves less room for a mispriced fill before the floor. These are synthetic worlds,
not order-flow data.

## 6. Recommendation (for R-5)

1. **Keep push-only as the permissionless base:**
   - Chainlink + RedStone;
   - RedStone's own heartbeat as `maxAge`.
2. **Optionally enable the fresh tier on the RedStone source** (for example 120 s / ±15 bp), fed by a relayer
   operated by a third party or by the operator under a RedStone credential.
   - Its outage costs quote quality, not availability.
   - Its compromise costs nothing beyond timing.
3. **Monitoring:**
   - relayer silence beyond `freshMaxAge`;
   - provider heartbeat;
   - the sequencer.
4. **Do not add Pyth or Data Streams.** No independent value was demonstrated: Pyth is not relayed on Unichain, and
   Data Streams needs a store contract.
