# Porkfolio — Phase 1B-4.2 Report: Oracle Safety and Dynamic Floor Finalization

**Status: PASS (design and isolated implementation); production vault, hooks and authorization module NOT changed.**
Branch `phase-1b-4-2-oracle-risk-boundary` from `phase-1b-4-1-shared-economic-core` at `15e82e6`. Baseline verified
at the start: vault runtime 22,049 B, runtime keccak `0x5ab6d06f…db2b1e`, init-code keccak `0xcd95dfdd…e31787`
(identical to Phase 1B-3). The ±25% vault-floor relaxation was **not** implemented; this design has no static price
band at all. Labels: PROVEN, TESTED, MEASURED, ESTIMATE, SYNTHETIC, ASSUMPTION.

## 1. Recommendation

**An oracle risk boundary enforced by the vault, made of three independent rules, with no owner-maintained
price:**

1. **Validity and uncertainty breaker.** Two push providers through one immutable `IMarketRiskAdapter`, read by the
   vault itself. The adapter refuses on staleness, contradiction or a sequencer outage. The vault refuses above its
   own `maxUncertaintyPips`.
2. **Directional floor outside the reference band.** `F0 = ceil(P (1 + u + e))`, `F1 = ceil(ceil(2^192 / P) (1 + u + e))`.
   It is D14-consistent at every reference by construction (PROVEN), and the static vault floor is not consulted while
   an adapter is installed.
3. **Inventory floor with no price in it.** `L_a = ceil(S tau_a (1 − kappa_a))`; no fill may leave the vault below it.
   **Capital-at-risk theorem (PROVEN): whatever any price source, adapter or hook does, the value LPs can lose through
   trading is at most `sum_a (N_a − L_a) p_a`**, which is `kappa` of the vault's value at the target composition.

Recommended starting values: `kappa` = 5% (and the hooks' own caps ≤ 5%), `e` ≤ 1 pip below the hooks' edge,
`maxUncertaintyPips` ≈ 1.5× the normal band. Recommended operating mode: **push-only (permissionless)**, with a
credentialed fresh source considered later as an optional input only (§4).

## 2. Rejected alternatives

| Alternative | Why rejected | Evidence |
|---|---|---|
| ±25% static outer band (Phase 1B-4.1) | arbitrary; a static price the owner must maintain; does not bound loss under a wrong reference | owner decision |
| static D14 pivot only | one-sided as soon as the market moves | Phase 1B-4 C1: 4.7% fill |
| value-based inventory floor | depends on the very price it must survive | design |
| keeper-pushed floors | stale between updates; a new authority over prices | Phase 1B-4.1 §2 |
| oracle logic inside the vault | does not fit EIP-170 | §5 (even the minimal vault-side branch leaves 1,854 B at 2,000 runs) |
| external risk-guard contract | saves only about 110 B and adds a contract to the trust base | §5 |
| mandatory signed price payload | every fresh provider on Unichain requires credentials; swaps would stop being permissionless | `FRESH_PRICE_EVALUATION.md` |
| optional signed payload as a safety measure | an attacker omits it; it tightens quotes but adds no protection against push corruption | A4: −395 vs −514 bps |
| Uniswap v3 TWAP as a pricing source | about 1.36 M USD of liquidity, single sequencer | ON-CHAIN |

## 3. Reference-source evidence (VERIFIED read-only)

Chainlink and RedStone push feeds are live on Unichain, both with 0.5% triggers. The WETH/USDC band measured on the
fork is ±82 bps. RedStone's on-chain signed-payload verification costs 99,538 / 134,114 gas per relayer transaction
(two feeds each; MEASURED from mainnet receipts). Pyth (Hermes), RedStone pull (authenticated gateway, HTTP 403) and
Chainlink Data Streams (VerifierProxy 2.0.0 `0x60fA…E9EB`; API key and secret) all need credentials. A Uniswap v3
TWAP is available but thin. Details: `FRESH_PRICE_EVALUATION.md`, `ORACLE_VERIFICATION_UNICHAIN.md`.

## 4. Attack results

`CORRELATED_ORACLE_FAILURES.md`: ten scenarios, each with an analytic bound and its assumptions. Every simulated
extraction is inside its bound. Highlights:
- **Malicious adapter (price halved for a day):** 421.9 bps extracted at `kappa` 15% and 117.7 at `kappa` 5%; roughly
  2× more with no inventory floor.
- **Both sources wrong by 5% for 6 h:** 28.1 bps at `kappa` 15% (bound 31.4).
- **One source manipulated above about 1.84%:** refused.

Two push providers are operationally but **not informationally** independent (both aggregate exchange prices), and
the two Chainlink USDC/USD proxies are one source. Worst-case capital at risk (any price, any adapter): **`kappa` × vault
value** — 500 bps at `kappa` 5%. Fixed flow epochs let two caps through within a day, so flow caps do not lower this
bound; they only slow the loss.

## 5. Contract size and gas (MEASURED, scratch copy, production compiler settings)

Prototype `oracle-risk-boundary.patch`, not applied. Sizes are runtime bytes; headroom is against EIP-170 (24,576).
The project target is 2,048.

| Vault build | 2,000 runs | 200 runs |
|---|---|---|
| baseline (production) | **22,049** (2,527) | 19,618 (4,958) |
| oracle risk boundary, full (selected) | 25,269 (**−693: over EIP-170, not deployable**) | **22,424 (2,152) — meets target** |
| lean (one setter, one getter) | 25,119 (−543) | 22,268 (2,308) |
| external guard (+1,129 B guard contract) | 25,009 (−433) | 22,210 (2,366) |
| minimal branch, no governance (not viable) | 22,722 (1,854 — misses target) | — |

**At 2,000 runs no oracle-aware vault meets the target**; even the non-viable minimum does not. At 200 runs the full
design meets it. Init code: 22,658 → 23,054 B. Storage: the 25 existing layout entries are unchanged; slots 24–28 are
appended (`riskAdapter`, edge and bound packed in slot 24; pending change in 25; targets in 26–27; tolerances in 28).

Gas, production benchmark (`--isolate`), baseline at 2,000 runs vs the full design at 200 runs **with no adapter
installed**:

| Operation | Baseline | Proposal | Change |
|---|---|---|---|
| swap Hook B / Hook A | 244,885 / 262,580 | 247,922 / 265,618 | +3,037 / +3,038 (+1.2%) |
| deposit / redeem instant / redeem queued / claim | 149,223 / 160,392 / 147,673 / 135,857 | +895 / +551 / +596 / +207 | +0.15–0.60% |
| allocate (steady) / signed activation (EOA) | 293,921 / 314,088 | +2,948 / +2,770 | +1.0% / +0.9% |
| deploy vault | 4,919,363 | 5,024,589 | +2.14% |

With the adapter installed (prototype test, adapter and four mock feeds cold), a Hook A swap costs 197,680 → 251,889
(+54,209). On real Unichain feeds the adapter read alone is 76,446 cold / 24,506 warm. ESTIMATE for an integrated swap
on real feeds, where the hook's read warms the feeds for the vault: Hook B ≈ 245k + 3k + 76k + 24.5k + ≈ 4k ≈ 353k.
Behaviour of the full design at 200 runs (scratch copy, this branch's suite plus the prototype's four tests: the
vault refuses in-band quotes, the inventory floor binds, the timelock and guardian rules hold): 497 passed, 3 failed,
5 skipped. The three failures are the production-artifact checks that assert the 2,000-run setting; the skipped are
the fork tests without an RPC.

Trade-offs: 200 runs costs about 0.1–0.4% more gas on every operation; the alternative, a headroom exception at 2,000
runs, is not available because the design does not fit EIP-170 there at all. Maintainability: the change touches
`exchange`, `reserveFor` and adds five administrative functions. It does not touch LP accounting, the queue or
authorization.

## 6. Economic acceptance (SYNTHETIC, held-out seeds, 9 regimes)

| | Q1 push + boundary (`kappa` 15%) | Q3 push + fresh credentialed source + boundary (`kappa` 5%) |
|---|---|---|
| fill (median) | 4.8% | 37.3% |
| fill given a safe quote (median) | 4.8% | 38.0% |
| quoted cost (median) | 74.4 bps | 35.1 bps |
| worst-regime LP vs HODL | +15.6 bps | +113.2 bps |
| worst single world | −42.6 bps | +65.4 bps |
| refusals in the calm regime, oracle / vault limits (order counts, 4 seeds) | 0 / 0 | 0 / 285 (flow cap 260, inventory 25) |
| inventory recovery from >10% to <5% | median 7.7 h (68 episodes) | no episode above 10% |

Trader acceptance against quoted cost (demand ASSUMPTION: lognormal tolerance, median 30 bps, σ 0.6): 10 bps 96.6%,
20 bps 75.0%, 30 bps 50.0%, 35 bps 39.9%, 50 bps 19.7%, 75 bps 6.3%, 100 bps 2.2%. With a median tolerance of 15 bps,
75 bps quotes are accepted 0.4% of the time; at 60 bps, 35.5%. Push-only availability depends entirely on this
unmeasured demand curve.

Cross-hook (Q2 core): Hook B alone filled 37.6% (median LP +170.1, worst world −17.8 bps). Hook A (activity fee
0→20 bps) beside Hook B (10 bp markup) filled 33.1% (median LP +157.7, worst world **+72.2**).

Quote latency: Python reference 4.1 µs per quote (single core). Solidity core + strategy: 9.7–11.0k gas
(Phase 1B-4.1).

**Hook A vs Hook B.** On one shared core Hook A only adds a fee, so it is dominated unless Hook B charges more for
the flow Hook A is cheap for. Recommended differentiation, with no new feature and no inventory-blind path:
- **Hook B** charges a flat markup and serves size (per-trade impact bound).
- **Hook A** charges an activity fee that starts below that markup and rises with recent flow, so it is cheaper for
  sporadic small trades and dearer for bursts. Bursts are where informed flow concentrates, which is why the
  combination improved the worst world (+72 vs −18 bps).

Both keep the shared core spread as their floor and the vault's boundary as their limit.

## 7. Production implementation plan

| Step | Content | Gate (pass/fail) |
|---|---|---|
| 0 | Owner decisions R-1 … R-6 (§9) | written decisions |
| 1 | Vault: apply `oracle-risk-boundary.patch` (adapter governance, R2–R4 in `exchange`, `reserveFor` branch); compile at 200 runs; update the three production-artifact checks to the approved setting | full suite; storage-layout diff shows appended slots 24–28 only; size ≥ 2,048 B headroom; invariant campaign extended with "N_a never below min(N_a before, L_a)" under a handler that controls a malicious adapter, `fail_on_revert` |
| 2 | Adapter: deploy-time configuration for the launch pair (Chainlink + RedStone, thresholds + 1 bp, heartbeat + 30 min, sequencer, 1 h grace, 2 sources) | fork test reading the configured feeds at the launch block; `configVersion` recorded |
| 3 | Hooks: read `riskAdapter` from the vault; price with `InventoryPricing` (band mode) + `StrategyPricing`; Hook B with markup, Hook A with activity fee; caps ≤ `kappa`, edge > `e` | real-PoolManager tests: in-band quotes refused by the vault even from a scripted hook; cross-hook cycles lose; cap binds across hooks; vectors equal |
| 4 | Gas and size | production benchmark with an installed adapter on a Unichain fork; report against the ≈ 353k estimate |
| 5 | Testnet (approval required) | Unichain Sepolia: Chainlink testnet feeds read on-chain, RedStone testnet manifest verified; staged adapter install through the timelock; guardian cancel rehearsed |
| 6 | Optional fresh source (only if R-5 approves) | signer set, age window, replay and missing-payload policy as in `FRESH_PRICE_EVALUATION.md` §4; intersected with push brackets, never alone |

Separation: steps 1–4 are protocol correctness; steps 5–6 are deployment and product.

## 8. Unresolved risks

1. **Push-only economics** depend on an unmeasured demand curve; at the verified ±82 bps band they fill little.
2. **`kappa` is real capital at risk** under total oracle compromise (500 bps at 5%), until the guardian halts.
3. **Common-mode exchange errors** reach both push providers; only `kappa` bounds them.
4. **Owner loosening of vault bounds is immediate**, like every existing owner limit (R-3).
5. **Two flow caps per day** pass across a fixed epoch boundary; rolling windows are not implemented.
6. **200 optimizer runs** become a production setting if approved; the artifact checks must change with it.
7. All economics are SYNTHETIC; there is no historical replay.

## 9. Decisions requiring approval

- **R-1**: the oracle risk boundary and `docs/proposals/oracle-risk-boundary.patch`. This changes the vault's trust
  boundary (an adapter input), appends storage, and in adapter mode replaces the static floor with the dynamic floor
  plus the inventory floor.
- **R-2**: compile the vault at 200 runs (measured +0.1–0.4% gas per operation; required to fit at all).
- **R-3**: whether loosening `kappa`, `tau`, `e` or `maxUncertaintyPips` needs a timelock (not in the patch: costs size;
  recommended later via a governance timelock contract as owner).
- **R-4**: `kappa` = 5% to start, hooks' caps ≤ 5%.
- **R-5**: whether to obtain credentials for a fresh signed source, as an optional tightening input only.
- **R-6**: strategy differentiation: Hook B markup, Hook A activity fee starting below it.

## 10. Validation

Foundry 1.7.1, solc 0.8.26, Slither 0.11.6, Python 3.11.8. All local. The fork reads used the public Unichain RPC
read-only.

| Command | Result |
|---|---|
| `forge fmt --check` | clean |
| `forge test` (default profile) | 496 passed, 0 failed, 5 skipped (fork tests without an RPC), 44 suites |
| `bash test/bench/security.sh` (CI profile, 10,000 fuzz runs, forced rebuild, size gate) | exit 0; vault 22,049 B (margin 2,527); 496 passed, 0 failed |
| `FOUNDRY_INVARIANT_FAIL_ON_REVERT=true FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-contract VaultInvariantsTest` | 35/35; 30 invariants × 32,768 calls, 0 reverts |
| `FOUNDRY_FUZZ_RUNS=10000 forge test --match-path "test/risk/*"` | 5/5 (300 vectors equal to Python; floors consistent; inventory floor rounding; holding never below floor) |
| `UNICHAIN_RPC_URL=https://mainnet.unichain.org forge test --match-contract UnichainOraclesForkTest -vv` | 5/5 (adapter 76,446 cold / 24,506 warm; v3 TWAP 15,659) |
| mutation (10 mutants of `VaultRiskBoundary` and the adapter's pair/version code; scratch copy) | **10/10 killed**. A1 (identical pair accepted) and A2 (version ignoring the second source) survived the first run; two assertions were added to `test_pairAndConfigVersion` and kill both |
| `slither . --filter-paths "lib/\|test/" --exclude-dependencies` | 45 results, the same count as Phase 1B-4.1; no finding in `src/risk` or `IMarketRiskAdapter` |
| `python3 -m unittest discover -s simulations/mm` / `simulations/pricing` | 42 passed / 22 passed |
| `python3 simulations/mm/vectors_risk.py` (twice) | byte-identical |
| `python3 simulations/mm/simulate.py --phase142` | `results/phase142.md` (26 s) |
| production contracts vs `15e82e6` | vault, hooks, `CuratorAuthorization`, `VaultLens` and their interfaces: 0 diff lines; vault runtime 22,049 B and its keccak unchanged |
| scratch prototype (not in `src/`) | sizes, gas, storage layout and behaviour in §5 |

Commits on this branch: `9cd6ba5` risk-boundary equations; `4f7e8fa` adapter interface, pair and version; `b16bda3`
simulation and loss bounds; and the documentation commit carrying this report.
