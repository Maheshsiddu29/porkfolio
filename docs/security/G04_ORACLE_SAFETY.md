# Porkfolio — G04: Oracle Safety and Fallback

**Status: PASS (local), awaiting owner review.** This report covers the G04 review and its closeout.

**The review.**
- It reconstructed the oracle trust boundary from the source.
- It reproduced ten failure scenarios with deterministic tests through the real adapter, vault and PoolManager.
- It found one defect, F-1: the asset1 price floor, and the hooks' asset1 quote at the inventory cap, could sit inside
  the reference band.

**The closeout** made four changes:
- **F-1 corrected at its source.** The shared reference uncertainty is now multiplicative; §5 has the proof.
  - The fix is in the adapter, so both hooks and the vault inherit it.
  - Vault and hook bytecode are unchanged.
- **Sequencer initialization.** The adapter now refuses an uninitialized or future-dated sequencer status round.
- **Deployment gates.** They now check feed identity, an independent price, and the fixed-floor fall-back
  requirements.
- **Models and specifications.** The Python model, conformance vectors and specifications are updated.

Decisions R-19 … R-23 remain with the owner (§11).

Production contracts changed: `src/oracle/ReferenceBracket.sol` and `src/oracle/PriceRiskAdapter.sol`.
- Comment-only edits in `IMarketRiskAdapter`, `VaultRiskBoundary` and `InventoryPricing` leave every runtime and init
  bytecode unchanged (§10.3).
- Vault EIP-170 headroom is unchanged at 2,136 bytes.

Labels used below:
- **ENFORCED**: a check in this repository's code.
- **PROVEN**: holds for every input in the stated domain, with the argument given here.
- **TESTED**: a deterministic or fuzz test in this repository.
- **ARGUED**: reasoning from the code, with no dedicated test.
- **ASSUMED**: a property of an external provider, relayer or operator that no code here checks.

## 1. Starting state

- `main` = `origin/main` = `f557664` (the G02 tip). **G03 is not in `main`:** its branch `phase-2-g03-lp-accounting`
  (`4dbe6b9`) is ahead of `main` and has not been integrated.
- G03 changed no production code (`git diff f557664 4dbe6b9 -- src` is empty), and G04 relies on G03's admission-floor
  counterexamples (`test/security/ReservationDeliverability.t.sol`). I therefore branched
  `phase-2-g04-oracle-safety` from the G03 tip instead of from `main`.
- **Effect on review.** Integrating G04 brings G03's commits with it unless G03 is integrated first.

## 2. Oracle trust boundary

### 2.1 Who provides prices, and who can change what

| Component | Role | Who can change it | How |
|---|---|---|---|
| Push feeds (Chainlink, RedStone; `IAggregatorV3`) | `latestRoundData` answers, one per USD leg | provider (and, for RedStone, anyone submitting signed packages) | external; nothing here can write to a feed |
| L2 sequencer uptime feed | up/down status and restart time | Chainlink | external; on Unichain not provider-supported (§2.4) |
| `PriceRiskAdapter` | turns 2 sources × 2 legs into `(priceX96, uncertaintyPips, validUntil, liveSources)` or reverts | nobody: no owner, no setter; every parameter immutable, hashed into `configVersion` | redeploy |
| `ReferenceBracket` (library inside the adapter) | per-source bracket, intersection, mid and uncertainty | — | redeploy the adapter |
| `SharedCommitmentVault.riskAdapter` | the one adapter every fill and every core-mode hook reads | owner only (`setRiskAdapter`); the guardian cannot | `VaultGovernor` DELAY (3 d proposed); the vault checks `pair()`, token decimals and one valid reading at installation; deployment gate 7 checks the feeds and an independent price (§6) |
| `riskEdgePips`, `maxUncertaintyPips` | vault edge `e` and uncertainty bound | owner any way; guardian only raises `e` / lowers the bound | DELAY / immediate for the guardian |
| `tau_a`, `kappa_a` | inventory floor | owner any way; guardian only tightens | LONG_DELAY (32 d proposed) with the queue check / immediate for the guardian |
| stored sell floors | static floors, and extra lower bounds in adapter mode | owner opens or lowers; guardian only raises a floor that is **already set** | DELAY / immediate |
| hook core parameters | spreads, depth, `minEdge` ≥ vault edge + 1 | hook owner (the governor) | DELAY |
| relayer (optional) | submits RedStone packages more often | anyone; holds no role here | none |

### 2.2 How a fill reads the oracle

1. **The hook prices the swap.** In `beforeSwap`, `_coreState` calls `vault.coreInputs()`, which returns the adapter
   address, the edge, `kappa_1`, `tau_1`, `N_1` and `S`. The hook then calls `adapter.currentReference()`.
   - If the vault has no adapter, the hook prices from its own stored `priceX96` (static mode).
   - The hook makes no validity check of its own. A revert from the adapter reverts the swap.
2. **The vault checks the price.** `exchange` → `_floorForFill` → `_reading` calls the same adapter again, in the
   same transaction.
   - It refuses `priceX96 == 0`, `validUntil < now`, and `uncertaintyPips > maxUncertaintyPips`.
   - The fill must pay `ceil(amountOut × max(stored floor or 1, curator floor, dynamic floor) / 2^96)`.
3. **Inventory floor.** `_floorForFill` also checks the price-free floor `N_a − out ≥ L_a`.
   - In adapter mode, an asset with no target is refused outright.

Both reads are `view` calls in one transaction, so the hook and the vault see the same answers (ENFORCED: the adapter
makes only `staticcall`s). A hook cannot name a different adapter, because it reads the address from the vault.

### 2.3 Authentication of signed prices

Nothing in this repository verifies a signature.
- **RedStone push.** The provider's on-chain adapter verifies its signer set and refuses packages older than the
  stored one (ASSUMED; `ORACLE_RELAYER.md` §1).
- **Chainlink push.** Answers are written by its own transmitters (ASSUMED).
- **What `PriceRiskAdapter` sees.** It reads only the stored `(answer, updatedAt)`.

Consequences, TESTED in `test_freshnessIsTheFeedsClaim_replayAndRollback`:
- **A leg's age is whatever `updatedAt` the feed reports.**
  - A feed that stored an old price with a new `updatedAt` gets the fresh tier's narrow band around that old price.
  - A feed that rolled back to an older answer, with its older `updatedAt`, is accepted while that age is within the
    push tier.
  - The adapter cannot detect either case. No-replay and no-rollback are provider properties.
- **Not verified.** I did not verify which timestamp RedStone's push feed reports as `updatedAt`: the block time of the
  submission or the signed package's own timestamp. If it is the block time, a package signed up to the provider's
  maximum delay before submission looks age 0, and the fresh tier's `freshMaxAge` understates how old the price
  really is. This must be measured before the fresh tier is enabled (decision R-5, §9).

### 2.4 Freshness and sequencer rules (ENFORCED, TESTED)

| Rule | Code | Boundary |
|---|---|---|
| leg answer must be in `(0, 2^128)`, `updatedAt` non-zero and `≤ now`; ≥ 160 bytes returned; round id ≤ 2^80 | `PriceRiskAdapter._read` | otherwise `FeedUnusable(feed)`: the **whole read** reverts |
| fresh tier: `now ≤ updatedAt + freshMaxAge` → `freshDeviation` | `_tier` | inclusive (`test_freshTier_boundaryIsInclusive`, `test_freshTierBoundary_staleNarrowBandCannotAuthorize`) |
| push tier: `now ≤ updatedAt + maxAge` → `deviation` | `_tier`, `_source` | inclusive; one second later the source is not live |
| source live only if both legs are within a tier | `_source` | |
| `liveSources ≥ minSources` | `currentReference` | else `InsufficientSources` |
| `validUntil` = earliest time any used leg leaves the tier it was read in | `_source`, `currentReference` | vault refuses `validUntil < now` (inclusive at equality, matching the adapter) |
| sequencer status must be 0 or 1, with `0 < startedAt ≤ now` | `_read` (status branch) | otherwise `FeedUnusable(sequencerFeed)` (**closeout**: `startedAt` 0 or in the future used to read as up) |
| sequencer down → refuse; up → refuse while `now − startedAt ≤ sequencerGrace` | `currentReference` | **closeout**: refused at exactly the grace, as Chainlink's reference consumer does (`timeSinceUp <= GRACE_PERIOD_TIME`); it was accepted at equality before |

**Sequencer feed findings.** Chainlink's L2 Sequencer Uptime Feeds page (`docs.chain.link/data-feeds/l2-sequencer-feeds`,
read 2026-11-13) says three things:
- **When `startedAt` is 0.** It "returns `0` only on Arbitrum when the Sequencer Uptime contract is not yet initialized";
  on other L2 chains it "is set to `block.timestamp` on construction and … is never `0`".
- **Supported networks.** It lists uptime feeds for Arbitrum, Base, Celo, Mantle, MegaETH, Metis, OP, Scroll, Soneium,
  X Layer and zkSync. **Unichain is not listed, mainnet or Sepolia.**
- **No new networks.** It says Chainlink "is no longer expanding L2 Sequencer Uptime Feeds to additional networks".

On Unichain mainnet, `0x495639D9914e7D270c5dCC641BfB1d807423F813` exists on-chain. It came from Chainlink's general
feed directory in Phase 1B-4.1. Read-only at block 63,868,968 (2026-11-13), it answers status 0, `startedAt`
1,793,291,075, `description()` "L2 Sequencer Uptime Status Feed". I did not invent or assume an address. That contract
is present and initialized, but it is **not a provider-supported feed**: its maintenance, alerting and status updates
are not documented commitments. The Sepolia rehearsal configures no sequencer feed.

**Residual risk without a reliable uptime feed:**
- **What goes undetected.** A sequencer outage and restart are not detected on-chain.
- **What protects LPs instead.** After a restart, push answers that are still within their staleness limits may lag the
  market by more than their thresholds until providers push again. Fills in that window are priced from those answers,
  bounded only by:
  - the dynamic floor around them;
  - the staleness limits;
  - the flow caps;
  - the inventory floor (O-9).
  In the bad case the vault sells the inventory room at the stale band, as in scenario 8.
- **Mitigations:**
  - the guardian pauses or halts on an announced outage;
  - operator monitoring of the sequencer;
  - shorter staleness limits;
  - a provider-supported uptime source if one becomes available.

Deployment gate 7 requires the reviewed sequencer address, and under mainnet delays an explicit
`ACCEPT_NO_SEQUENCER_FEED=true` when none is configured (§6).

**Configured tolerances** (`script/DeploySystem.s.sol` rehearsal; Unichain records):

| Parameter | Value |
|---|---|
| Chainlink-like legs | ±3,100 / ±5,100 pips, `maxAge` 88,200 s |
| RedStone-like legs | ±5,100 / ±5,100 pips, `maxAge` 12,600 / 23,400 s |
| RedStone fresh tier | `freshMaxAge` 120 s, ±1,500 pips |
| Sources required | `minSources` = 2 |
| Sequencer | none on Sepolia; mainnet feed not provider-supported (above) |
| Vault | `e` = 100 pips, `maxUncertaintyPips` = 20,000, `kappa` = 10,000 pips (1%) |
| Hooks | base spread 3,000 pips, `minEdge` 200, `maxSpread` 40,000; Hook B markup 1,000 and per-trade bound 20,000 |

### 2.5 Uncertainty (definition corrected in the closeout)

For the intersection `[L, H]` of the live sources' brackets (Q64.96, raw currency1 per raw currency0),
`ReferenceBracket.midAndUncertainty` returns

```
M = L + floor((H − L) / 2)
u = max( ceil((H − M) · 1e6 / M),  ceil((M − L) · 1e6 / L) )       pips
```

**What `u` means.** `u` is the smallest multiplicative half-width with `M / (1 + u) ≤ L` and `M (1 + u) ≥ H`: the range
`[M / (1 + u), M (1 + u)]` covers the band read as currency1 per currency0 **and** as currency0 per currency1.
- **What changed.** Before the closeout the second term divided by `M`. That made `u` the half-width relative to the
  mid, which covers the band in the first reading only (F-1).
- **Interface.** `IMarketRiskAdapter.Reading.uncertaintyPips` keeps its type and name; only its documented meaning
  changed. No interface change was needed.

**Effect on readings.** `u` grows by about `u²`:

| Reading | Before | After |
|---|---|---|
| Unichain Chainlink + RedStone, push tier (fork, 2026-11-13) | 8,200 | **8,268** |
| fresh tier (RedStone 15 bps per leg) | 3,000 | 3,010 |
| one source, RedStone alone, push tier | 10,200 | 10,305 |
| one source, 96.5 bps per leg (near the vault bound) | 19,298 | 19,678 |
| Python example, Chainlink 2,048.39 / RedStone 2,050.31, 50 bps | 4,532 | 4,553 |

**Thresholds in deployed configurations.**
- **No threshold value changed.** The vault's `maxUncertaintyPips` (20,000) and the hooks' `maxSpread` (40,000) are
  untouched.
- **Rehearsal configuration.** With two sources required, `u ≤` about 8,270 pips, so the vault bound never binds and
  normal trading is unaffected.
- **Near the vault bound.** A configuration whose readings sat close to 20,000 pips can now cross it, because the
  increase there is about 400 pips.
- **Hook B's 2% per-trade bound.** It admits `3,000 + u + 1,000 < 20,000`, i.e. `u` below about 16,000. This was true
  before (19,298 was refused too) and is shown in the matrix (§4).

### 2.6 Normalization across decimals (ENFORCED, TESTED)

- **The shift.** `e = (feed decimals 1 + token decimals 1) − (feed decimals 0 + token decimals 0)`.
  - Feed decimals are read once at construction.
  - Token decimals are constructor arguments, checked against `ERC20.decimals()` by `setRiskAdapter` and by gate 7.
  - `|e| ≤ 30`, else `InvalidConfig`.
- **Rounding.** Brackets round outward, the mid rounds down, `u` rounds up, the floors round up, and the fill's
  required input rounds up.
- **Fuzz result.** `testFuzz_normalizedFloorNeverInsideTheBand` checks every fill against each live source's exact
  rational bracket (512-bit cross-multiplication), over random answers, thresholds (≤ 5%), feed and token decimals
  (0–24), edges (0–1%) and one or two sources.
  - Since the closeout it asserts **both directions for every edge, including 0**.
  - Its non-vacuity companion checks 300 derived cases: 11 refused, asset0 checked 148 times (one source) and 141 times
    (two), asset1 checked 289 times.
  - 80 of those asset1 cases lie in the region where the old definition failed (`e·(1e6 − u) < u²`).

What is not checked on-chain:
- **Leg order and feed identity.** Covered by deployment gate 7 (CE-O2).
- **Feed decimals changing after construction.**

### 2.7 What each kind of bad data does

| Data | Adapter | Vault | Evidence |
|---|---|---|---|
| zero, negative, ≥ 2^128, `updatedAt` 0 or in the future | `FeedUnusable`, whole read | fill refused | `test_unusableLegReverts` |
| feed reverts, short return data, burns gas | `FeedUnusable` / out of gas | fill refused | `test_feedRevertOrShortReturnReverts`, `test_gasBurningFeedOnlyFails` |
| leg older than `maxAge` | source dropped; refused below `minSources` | fill refused | `test_staleSource` |
| a **broken** second source when one would suffice (`minSources` = 1) | whole read refused, not dropped | fill refused | `test_unavailableFallback_haltsEvenWhenOneSourceSuffices` |
| brackets do not intersect | `ReferenceDivergence` | fill refused | `test_divergenceReverts` |
| intersection low end 0 | `DegenerateBracket` | fill refused | ARGUED (`midAndUncertainty`); skipped cases of the fuzz test |
| `u` too large for 256 bits (a low end near 0) | FullMath reverts | fill refused | ARGUED (`midAndUncertainty` overflow note) |
| sequencer status not 0/1; `startedAt` 0 or in the future | `FeedUnusable` | fill refused | `test_sequencer_initializationAndGrace` |
| sequencer down, or up for no more than the grace | `SequencerUnavailable` | fill refused | `test_sequencer_initializationAndGrace`, `test_sequencerDownOrInGrace` |
| reading with `priceX96 = 0`, past `validUntil`, or `u` above the bound (any adapter) | — | `InvalidReference` / `UncertaintyTooHigh` | `test_invalidReadings_refused`, `test_atVaultBound_acceptsThenRefusesOnePipLower` |
| arbitrary price from a malicious or wrong adapter | — | priced at that reference; stops at the inventory floor | `test_maliciousAdapter_stopsAtInventoryFloor`, `test_swappedLegs_passInstallation_boundedByInventoryFloor` |

The vault does not read `liveSources`. Requiring two sources is the adapter's job.

### 2.8 Fallbacks

There is **no fallback price** anywhere: no stored last-good price and no default. There are three fallback paths:
1. **Second source within the adapter.** With `minSources = 1`, one stale source is dropped and the other prices
   alone, which widens the band. This applies only to staleness; a broken source halts the read (CE-O1).
2. **Static mode.** The owner removes the adapter (DELAY).
   - Fills then use stored floors only; a direction without a stored floor closes.
   - Inventory floors with a target keep applying. An asset without a target loses all inventory protection (CE-O4).
   - Deployment gate 13 must pass before this fall-back is queued and again before it is executed (§6).
3. **No fallback at all.** With `minSources = 2` (configured), trading stops until both sources are live. Recovery
   needs no governance action (`test_relayerOutage_widensThenHaltsOnlyWithTheProvider_recoversByItself`).

### 2.9 Decisions that use the oracle

| Uses the adapter | Does not |
|---|---|
| `exchange`: dynamic floor and validity checks | `deposit`, `initialDeposit`, `redeem` (instant and queued), `processQueue`, `claim`, `cancelRequest` |
| hook quotes in core mode (`_coreState`) | allocation admission (`reserveFor`): `N − Q − R − D`, exposure caps |
| `setRiskAdapter` installation check | inventory floor `L_a` (no price) |
| `VaultLens.effectiveFloorX96` (view) | flow limits, exposure limits, pause, halt, release, cancel, curator lifecycle, every governance call |

### 2.10 Enforced guarantees versus assumptions

- **ENFORCED.**
  - Every adapter-mode fill re-reads the adapter in the same transaction and fails closed on any revert, zero price,
    expired reading or excessive `u`.
  - The fill price is at least the maximum of the stored, curator and dynamic floors, and the dynamic floor lies
    outside every live source's bracket in both directions (§5).
  - The inventory floor is applied in every mode once a target is set.
  - No LP path reads the adapter.
  - The adapter is immutable and its installation is owner-only and timelocked.
  - Hooks cannot choose another adapter.
- **ASSUMED (providers).**
  - Push feeds keep the market within their deviation threshold while live.
  - Feeds do not replay or roll back.
  - `updatedAt` is honest.
  - The two sources fail independently (they do not: both use centralised-exchange data, `CORRELATED_ORACLE_FAILURES.md`
    §1).
  - A configured sequencer feed reports outages.
- **ASSUMED (operators).**
  - The reviewed feed in each slot (now checked by gate 7).
  - The relayer, if any, only adds availability; it cannot set a price.
  - The guardian reacts within the flow-cap window.

## 3. Failure scenarios (Task 2)

All with the production `PriceRiskAdapter` over mock feeds, unless noted.

| # | Scenario | What happens | Test |
|---|---|---|---|
| 1 | stale primary | stale source dropped; two required → every fill refused. At the fresh-tier boundary + 1 s the narrow-band fill is refused (`PriceBelowFloor` against the wider push band) | `test_staleSource`; `test_freshTierBoundary_staleNarrowBandCannotAuthorize`; `test_relayerOutage_…` |
| 2 | unavailable fallback | `minSources` = 1: a stale fallback is dropped; a reverting or zero-answering fallback halts every read (CE-O1) | `test_unavailableFallback_haltsEvenWhenOneSourceSuffices` |
| 3 | conflicting sources | empty intersection → `ReferenceDivergence`. Within both error bounds (≤ about 1.84%) a disagreement only shifts the mid (CORRELATED_ORACLE_FAILURES.md, scenario 1) | `test_divergenceReverts` |
| 4 | valid but very uncertain | refused above `maxUncertaintyPips`; below it, quotes widen with `u` and every fill stays outside the band in both directions (F-1 corrected) | `test_F1_asset1FloorCoversBandBottom_aboveOldFailureThreshold`, `test_atVaultBound_…`, the hook matrix |
| 5 | wrong direction or decimals | wrong token decimals or a swapped pair: refused at installation. **Swapped legs pass installation** and invert the price; the loss stops at the inventory floor; deployment gate 7 refuses them (CE-O2) | `test_setRiskAdapter_validation`, `test_swappedLegs_…`, `test_gates_oracleIdentityAndFixedFloorFallback` |
| 6 | zero, negative, malformed | `FeedUnusable`, for price legs and for the sequencer feed (status ∉ {0, 1}, `startedAt` 0 or in the future) | `test_unusableLegReverts`, `test_sequencer_initializationAndGrace` |
| 7 | replayed or expired signed updates | expired → dropped; future-dated → `FeedUnusable`; replay or rollback by the feed → accepted (provider assumption) | `test_freshnessIsTheFeedsClaim_replayAndRollback` |
| 8 | large move or depeg | feeds 8% behind the market inside their staleness limits: buyers take the inventory room at the stale band's top (about 1.0085 for an asset worth 1.08), and one more raw unit is refused. Loss about 716 per 10,000 of room, below `(δ − band)·room` | `test_jumpTheFeedsMissed_lossStopsAtInventoryRoom`; depeg: `test_Q4_depeg_markToMarketBeyondKappa_whileQ1Q2Hold` |
| 9 | price update between reservation and execution | the allocation fixes no price: after a move up the reservation-time price is refused; after a move down a lower price is accepted; only the curator floor is fixed | `test_priceMoveBetweenReservationAndExecution`, `test_replaceAdapter_duringActiveAllocation` |
| 10 | oracle failure during queued withdrawals | fills stop; `Q` stays reserved, so the LP's instant part is limited to `F` and the rest queues; queue, claims, deposits, cancellation and guardian tools work; a guardian release finalizes the queue; trading resumes when a source pushes | `test_outageWithReservation_exitsQueueBehindItUntilReleased`, `test_lpPaths_independentOfAdapter` |

## 4. Execution guarantees (Task 3) and hook regression

| Property | Status | Evidence |
|---|---|---|
| **O-1** Unsafe swaps fail closed: any adapter revert, zero price, expired reading or `u` above the bound refuses the fill and changes nothing | ENFORCED, TESTED | §2.7 |
| **O-2** Stale data cannot authorize a fill the fresh data would refuse: the tier and `validUntil` are inclusive in both contracts; one second later the wider band applies | ENFORCED, TESTED | `test_freshTierBoundary_…`, `test_freshTier_boundaryIsInclusive` |
| **O-3** A fallback cannot loosen inventory protection: the inventory floor contains no price and applies in every mode once a target exists; adapter mode refuses an asset without a target. The static fall-back with an asset without a target (CE-O4) is closed by gate 13 at deployment, not by the vault | ENFORCED, TESTED | `test_inventoryFloor_appliesInStaticMode`, `test_adapterRemoval_assetWithoutTarget_losesInventoryFloor`, `test_gates_oracleIdentityAndFixedFloorFallback` |
| **O-4** A fallback to fewer sources keeps each floor beyond the **remaining** sources' band. Relative to the two-source floor, the asset0 floor loses `e·(mid₂ − mid₁)` and gains from the wider `u`. At the configured 1 bp edge it now rises (about 49 pips in the test); with a 5% edge it falls. The asset1 floor rises | PROVEN (§5), TESTED | `test_fallbackToOneSource_staysOutsideRemainingBand` |
| **O-5** Hook A and Hook B are held to identical vault rules, and neither quotes inside the vault's floor | ENFORCED, TESTED | hook matrix below; `test_hookEdge_isVaultEdgePlusOne`, `test_inventoryCap_sharedAcrossHooks` |
| **O-6** Oracle failure never blocks claims or LP withdrawals that free inventory can pay | ENFORCED (no LP path reads the adapter), TESTED | `test_lpPaths_independentOfAdapter`, `invariant_lpPathsIndependentOfAdapter`, `test_outageWithReservation_…` |
| **O-7** Guardian restrictions survive oracle failure and adapter transitions: pause, halt, raising stored floors, raising `e`, lowering the bound, tightening inventory bounds and early release read no price | ENFORCED, TESTED | `test_haltAndPause_surviveTransitions`, `test_guardianRaisedFloor_survivesInstall`, `test_outageWithReservation_…`, `test_atVaultBound_…` |
| **O-8** Normalization and rounding never put a fill inside the band, in either direction, for any edge ≥ 0 | PROVEN (§5), TESTED (exact fuzz) | `testFuzz_normalizedFloorNeverInsideTheBand`, `test_normalizedFloor_checksAreExercised` |
| **O-9** Whatever any price input says, no fill takes `N_a` below `L_a` | ENFORCED, TESTED | `invariant_holdingsAtOrAboveInventoryFloor`, `test_maliciousAdapter_…`, `test_swappedLegs_…`, `test_jumpTheFeedsMissed_…` |

**Hook regression matrix** (`test/integration/OracleBandHooks.t.sol`). It runs the production Hook A and Hook B in
shared-core mode with the production adapter, vault and PoolManager, in the rehearsal configuration.

**Setup:**
- **Decimals:** two token-decimal pairs, 18/18 at 1:1 and 6/18 at 3,000 USD per 18-decimal token.
- **Six reference states:**
  - two sources, push tier: `u` = 8,268;
  - two sources, fresh tier: 3,010;
  - Chainlink alone: 8,268;
  - one source near the old failure point: 10,040 (old definition 9,942);
  - RedStone alone, above it: 10,305 (old 10,200);
  - one source near the vault bound: 19,678.
- **Cells:** both hooks × both directions.

**Procedure.** Each cell trades in one direction, a dust-sized trade first and then 0.2% of the input holding at a
time, until something refuses. For every attempt:
- if the hook quotes, the vault's own effective floor accepts the quoted input;
- every fill equals the quote and is outside every live source's exact bracket;
- no refusal is `PriceBelowFloor`.

**Results:**

| | 18/18 | 6/18 |
|---|---|---|
| fills checked | 121 | 121 |
| cells ending at the hook's inventory cap (`InventoryLimit`, which binds at or before the vault's 1% floor) | 22 | 22 |
| cells ending at Hook B's 2% per-trade bound (`TradeImpactExceeded`, only at `u` = 19,678, where Hook B quotes nothing) | 2 | 2 |
| hook quotes the vault refused on price | 0 | 0 |

- **Every other state:** Hook A and Hook B fill in both directions (6 and 5 fills per direction).
- **At the vault bound:** `test_atVaultBound_acceptsThenRefusesOnePipLower` shows that with `maxUncertaintyPips` equal
  to the reading's `u` Hook A fills; one pip lower, the guardian's tightening refuses every swap on both hooks, and
  nothing moves.
- **The vault's own floor edge:** the edge of the vault's inventory floor itself is tested with exact amounts in
  `OracleFailureExecution.t.sol` and `OracleRiskBoundary.t.sol`.

## 5. F-1 and its correction

### 5.1 The defect (reproduced first)

**Before the closeout:**
- `u = max(⌈(H − M)·1e6/M⌉, ⌈(M − L)·1e6/M⌉)`.
- The vault's asset1 floor is `F1 = ⌈⌈2^192/M⌉·(1e6 + u + e)/1e6⌉`, and the band's top in that direction is `2^192/L`.
- `(1/M)(1 + u) ≥ 1/L` needs `u ≥ (M − L)/L`, but `u` was only `≥ (M − L)/M`, short by
  `(M − L)²/(L·M) ≈ u²/(1 − u)`.
- So `F1` lay outside the band only when `e·(1e6 − u) ≥ u²`, i.e. `u ≤ 9,950` pips at `e` = 100.

**Reproduction:**
- The pre-closeout `test_F1_asset1FloorInsideBand_whenUncertaintyExceedsEdgeBound` sold 1,000 asset1 for 4.84·10^15 raw
  asset0 below the least price RedStone allowed. That was RedStone alone, push tier, `u` = 10,200, accepted under the
  20,000 bound.
- The current test recomputes that reading from the same bracket and shows the old floor inside the band.
- The hooks' asset1 ask at the cap edge, `(1/P)(1 + minEdge + u)`, had the same gap.

### 5.2 The correction

One line in `ReferenceBracket.midAndUncertainty`, in the adapter only. The lower term divides by `L` instead of `M`:

```
u = max( ceil((H − M) · 1e6 / M),  ceil((M − L) · 1e6 / L) )
```

The vault, the hooks, the lens and every API are unchanged. Both hooks and the vault read `u` from the adapter, so all
three are corrected together.

**Rejected alternatives:**
- Widening the vault's asset1 floor alone would push it above the hooks' asset1 quotes at the cap edge, so the vault
  would refuse them.
- Raising the edge, or capping `maxUncertaintyPips` at 9,950, would only hide the gap for current fixtures.

### 5.3 Proof that both directional floors lie outside the bracket (PROVEN)

Domain:
- `0 < L ≤ H`; otherwise `DegenerateBracket` or `ReferenceDivergence`.
- `M = L + ⌊(H − L)/2⌋`, so `L ≤ M ≤ H`.
- `e ≥ 0`.
- All quantities are integers; `u` as above.

**Step 1 (upper term).** `u ≥ ⌈(H − M)·1e6/M⌉ ≥ (H − M)·1e6/M`. Therefore

```
M·(1e6 + u) ≥ M·1e6 + (H − M)·1e6 = H·1e6                                          (1)
```

**Step 2 (inverse term).** `u ≥ ⌈(M − L)·1e6/L⌉ ≥ (M − L)·1e6/L`. Therefore

```
L·(1e6 + u) ≥ L·1e6 + (M − L)·1e6 = M·1e6                                          (2)
```

**Step 3 (selling asset0).** By (1):

```
F0 = ⌈M·(1e6 + u + e)/1e6⌉ ≥ M·(1e6 + u)/1e6 + M·e/1e6 ≥ H + M·e/1e6
```

**Step 4 (selling asset1).** `⌈2^192/M⌉ ≥ 2^192/M`, and by (2), `(1e6 + u)/(1e6·M) ≥ 1/L`. Therefore

```
F1 = ⌈⌈2^192/M⌉·(1e6 + u + e)/1e6⌉ ≥ 2^192·(1e6 + u)/(1e6·M) + 2^192·e/(1e6·M) ≥ 2^192/L + 2^192·e/(1e6·M)
```

**Step 5 (the fill).** The vault requires `in ≥ ⌈out·F/2^96⌉ ≥ out·F/2^96`.
- Each live source `s` has an exact bracket `[l_s, h_s]`.
- `pairBracket` rounds outward, so `L = max_s ⌊l_s·2^96⌋ ≤ l_{s*}·2^96` for the source `s*` that sets `L`, and
  `H = min_s ⌈h_s·2^96⌉ ≥ h_{s'}·2^96` for the source `s'` that sets `H`.
- **Selling asset0:** `in/out ≥ H/2^96 ≥ h_{s'}`, at or above the top of the band every live source allows.
- **Selling asset1:** `in/out ≥ 2^96/L ≥ 1/l_{s*}`, at or above the reciprocal of the band's bottom.

Both hold for **every** `e ≥ 0`, including 0. The edge then adds `M·e/1e6` (or `2^192·e/(1e6·M)`) beyond the band.

**Step 6 (hooks).**
- The hooks' band-edge cap keeps the ask at the cap edge at `(1/P)(1 + minEdge + u)` currency0 per currency1. By (2)
  that is `≥ 1/L + minEdge/P`.
- The bid at the cap edge is `(1/P)(1 − minEdge − u)` currency0 per currency1. The vault therefore sells asset0 at
  `≥ P/(1 − u − minEdge) ≥ P(1 + u + minEdge) ≥ H + minEdge·P`, using (1).
- Hook quotes inside the cap carry `baseSpread > minEdge` on top.
- `minEdge ≥ e + 1` (`_coreState`), so each hook quote also clears the vault floor. That is ARGUED from the formulas and
  TESTED by the matrix (§4) and `testFuzz_bandModePassesDynamicFloor`.

**Checked by:**
- `testFuzz_normalizedFloorNeverInsideTheBand` (exact, 1,000 runs default, 10,000 in CI, both directions, edge 0–1%);
- `test_uncertainty_covers_bracket_both_directions` (Python, 5,000 random brackets). The old definition fails (2) in
  more than 100 of them.

## 6. Counterexamples, deployment gates and corrections

| Id | Statement | Test | Status after the closeout |
|---|---|---|---|
| CE-O1 | **A broken fallback halts.** With one source required, a reverting or zero-answering second source makes every read revert, although the first alone would suffice | `test_unavailableFallback_…` | **Kept and documented** (R-21). The adapter drops a **stale** source under the configured `minSources`; it **never ignores a malformed or reverting** one, because a feed that answers garbage is not known to be merely late. ORACLE_RISK_BOUNDARY_SPEC.md §5 is corrected |
| CE-O2 | **Swapped legs pass installation.** An adapter built with leg0 and leg1 exchanged reports `1/P`; `setRiskAdapter` checks only the pair, token decimals and that a reading exists. At a true price of 2 the vault sold its whole asset0 room (10,000) for 5,041.7 asset1 | `test_swappedLegs_…`; `test_gates_oracleIdentityAndFixedFloorFallback` | **Deployment gate 7** now requires each of the four legs and the sequencer feed at the reviewed address and slot, token decimals from the tokens, and the reading within a reviewed tolerance of an independently obtained price (`FEED_0…3`, `SEQUENCER_FEED`, `INDEPENDENT_PRICE_X96`, `INDEPENDENT_PRICE_TOLERANCE_PIPS`). Near 1:1 an inverted price passes the price comparison, so the slot check is the one that catches it there |
| CE-O3 | **No guardian price floor in adapter-only mode.** The rehearsal deploys with no stored floors. The guardian may only raise a stored floor that exists, so against a wrong but valid price its tools are halt and pause | `test_swappedLegs_…` (second half) | Open (R-19). Gate 13 requires stored floors before any fixed-floor fall-back |
| CE-O4 | **Static fall-back drops protection for an asset without a target.** After `setRiskAdapter(0)` (DELAY) and with a stored floor, an asset with `tau = 0` trades with no inventory floor | `test_adapterRemoval_assetWithoutTarget_losesInventoryFloor` | **Gate 13** (`fixedFloorFallback()`) requires both inventory targets and both stored floors before `setRiskAdapter(address(0))` is queued and again before it is executed; tested refusing and passing. A vault-side check remains R-20 |
| CE-O5 | **Freshness is the feed's claim.** Replays and rollbacks by a feed are accepted (§2.3) | `test_freshnessIsTheFeedsClaim_…` | provider assumption; RedStone's `updatedAt` semantics must be measured before the fresh tier is enabled |
| CE-O6 | **Sequencer `startedAt = 0` read as "up since 1970".** | `test_sequencer_initializationAndGrace` | **Fixed** in the adapter (§2.4) |
| CE-O7 | **A fallback can move one floor either way.** O-4 | `test_fallbackToOneSource_…` | accepted; each floor stays beyond the remaining band |
| CE-O8 | **An unexecutable reservation still withholds inventory.** During an outage `Q` is not reduced, so LP instant exits are limited to `F = N − Q` until the allocation is released or expires (≤ 30 days) | `test_outageWithReservation_…` | by design (G03 G-11); matters for fees on reserved capacity (§8) |

**Corrections to earlier documents.** Specifications are corrected in place; historical reports get a dated note at
the top and their measurements are left as recorded.
- `ORACLE_RISK_BOUNDARY_SPEC.md`: corrections 6–8; the `u` definition in §2 and §4; the §5 row on missing or malformed
  legs.
- `SHARED_ECONOMIC_CORE_SPEC.md` §4: the band is `[P/(1+u), P(1+u)]`.
- `ORACLE_VERIFICATION_UNICHAIN.md` and `ORACLE_RELAYER.md`: correction notes, 8,200 → 8,268 and 3,000 → 3,010;
  Unichain's uptime feed is not provider-supported.
- `src/` NatSpec: `IMarketRiskAdapter.Reading.uncertaintyPips`, `VaultRiskBoundary` rule 2 and `InventoryPricing`
  band-edge mode describe the multiplicative definition (comment-only; bytecode unchanged).
- The synthetic results in `simulations/mm/results/` (attack bounds, κ calibration, fill rates) used the earlier `u`.
  The difference is about `u²` (0.7 bp at 8,200 pips). They were not regenerated.

## 7. Safety invariants

The invariants that hold under every oracle input, with the evidence for each:
1. **`N_a ≥ min(N_a before the fill, L_a)` after every fill, in every mode with a target.** ENFORCED;
   `invariant_holdingsAtOrAboveInventoryFloor`, `invariant_Q1_perShareFloor`, `invariant_noFillUnderAdapterFault`.
2. **No fill without a valid reading in adapter mode.** ENFORCED; §2.7.
3. **Each fill pays at least `ceil(out × max(stored, curator, dynamic) / 2^96)`, on the exact claims moved.** ENFORCED;
   `test_dynamicFloor_bothDirections_exactBoundary`.
4. **No LP or claim path depends on the oracle.** ENFORCED; `invariant_lpPathsIndependentOfAdapter`.
5. **The adapter, hook and vault read one configuration in one transaction.** ENFORCED; `test_coreInputs_matchGetters`,
   `test_quotesFollowTheVaultsAdapter`.
6. **Both directional floors are beyond every live source's bracket, for every edge ≥ 0.** PROVEN (§5.3); TESTED (exact
   fuzz, hook matrix).

## 8. LP protection limits and future commitments

### 8.1 LP protection is in inventory units, not value

These are inventory-unit guarantees, not value guarantees (G03 G-9, G-10; `INVENTORY_FLOOR_GUARANTEE.md`).

**What the inventory floor promises.** Each share keeps at least `tau_a·(1 − kappa_a)` of each asset it had at least
that much of, whatever the oracle says.

What it does not promise:
- **Value loss is not bounded by `kappa`.** Loss as a fraction of value can exceed `kappa`.
- **Cumulative realized loss is unbounded.**
- **A depeg** marks the held units down with no limit.
- **The value at risk from a wrong price** is up to `Σ_a (N_a − L_a)·p_a` at the true prices, per re-centring.

The price checks bound each fill's price only to the extent the providers' assumptions hold (§2.10).

### 8.2 Four guarantees a reservation might mean

| Guarantee | Today | Why |
|---|---|---|
| **Exclusive accounting capacity** | **yes** | `Q_a ≤ N_a`; no two allocations count the same unit (G03 G-3); capacity stays reserved through oracle outages (CE-O8) |
| **Immediate physical availability** | **yes, as custody** | `Q_a + W_a ≤ B_a ≤` vault's ERC-6909 balance (G03 G-1, G-2): the claims exist in the PoolManager. Not the same as being payable |
| **Execution only while price conditions hold** | **yes, but no price is fixed** | every fill needs a valid reading and pays at least the dynamic floor at execution time; the reservation fixes only the curator floor (scenario 9) |
| **A bounded quantity of guaranteed executable output** | **no: 0 in the worst case** | executable output = `min(remaining, N_a − L_a, flow caps, exposure)` at execution time, and `N_a − L_a` is shared by every allocation and shrinks with other hooks' fills and with LP exits (G03 CE-1, CE-2); an outage makes it 0 for its duration |

### 8.3 What a commitment engine must enforce

**At admission:**
1. The existing rule `q ≤ N − Q − R − D` and the exposure caps.
2. **Room-aware admission (R-15).** `Q_a + q ≤ N_a − L_a`, if the engine sells executable output rather than capacity.
   On its own this is not enough, because LP exits shrink `N_a − L_a` (G03 CE-2). Either:
   - commitments reserve their own room that exits respect (a vault change); or
   - commitments are defined as capacity, with fees charged only on what was executable (design note §2.10, D-6).
3. **A valid reading at admission**, if the commitment is priced.
4. **A curator floor stated explicitly.** It is the only price a reservation fixes.
5. **A rule for fees during oracle outages (R-23).**

**At execution:** everything `exchange` already enforces. With the corrected `u`, the band the vault refuses is the
whole bracket in both directions.

**What the engine must not promise:** a price, a quantity above `N_a − L_a`, or execution through an oracle outage.

## 9. Remaining oracle risks and deployment blockers

None of these can be removed within G04.
1. **No provider-supported sequencer uptime feed on Unichain** (§2.4). A deployment must either:
   - accept and record the residual risk (`ACCEPT_NO_SEQUENCER_FEED`); or
   - use the existing but unsupported feed with monitoring of its own.
2. **RedStone `updatedAt` semantics** are not measured; this blocks enabling the fresh tier (§2.3).
3. **The two sources share upstream data.** A common-mode error inside both brackets is undetected and bounded only by
   the inventory floor (`CORRELATED_ORACLE_FAILURES.md`, scenario 3).
4. **Stored sanity floors** are absent in the rehearsal configuration. The guardian's response to a wrong-but-valid
   price is halt and pause (CE-O3, R-19).
5. **Adapter replacement is DELAY, not LONG_DELAY**, and re-prices every live allocation at once
   (`test_replaceAdapter_duringActiveAllocation`).
6. **Gate 7's independent price** is only as good as the source the operator takes it from. At pairs near 1:1 it
   cannot detect an inversion, so the slot check must not be skipped.
7. **Synthetic results** in `simulations/mm/results/` predate the corrected `u` (§6).

## 10. Validation

### 10.1 Commands and results (closeout)

| Command | Result |
|---|---|
| `forge fmt --check`; `forge build` | clean |
| `forge test` | 669 passed, 0 failed, 8 skipped (fork tests, no RPC); 66 suites |
| `FOUNDRY_PROFILE=ci forge test --match-contract "OracleFailure\|OracleBandHooks\|PriceRiskAdapter\|OracleRiskBoundary\|VaultRiskBoundary\|SharedCoreHooks\|SharedCoreVectors\|SharedCoreProperties\|RelayerOutage\|HookPriceBands\|InventoryProtectionBounds\|ReservationDeliverability\|DeployScripts\|PricingAdversarial\|PricePolicy"` | 136 passed, 0 failed (17 suites) |
| `FOUNDRY_PROFILE=ci forge test --match-contract "OracleRiskInvariants\|InventoryProtectionInvariants\|VaultInvariants"` | 3 + 6 + 35 passed; every invariant 128 runs × 16,384 calls, 0 reverts |
| `python3 test/invariant/coverage.py` (64 seeds, depth 128) | every gate passed |
| `cd simulations/mm && python3 -m unittest test_core test_risk test_floor_guarantee test_mm` | 47 passed |
| `python3 simulations/mm/vectors_core.py && python3 simulations/mm/vectors_csv.py` | regenerated: only the 61 bracket cases' uncertainty column changed (`shared_core_v1.json`, `shared_core_brackets_v1.csv`); a second run leaves the files unchanged; `SharedCoreVectors` passes against them |
| `UNICHAIN_RPC_URL=https://mainnet.unichain.org forge test --match-contract UnichainOraclesForkTest -vv` (public RPC, read-only) | 5 passed; corrected adapter on real feeds: `u` = 8,268 pips, 2 live sources, `currentReference` 75,875 gas cold / 23,935 warm |
| `UNICHAIN_RPC_URL=https://mainnet.unichain.org forge test --match-contract UnichainIntegratedSwap -vv` | 3 passed (shared-core swap gas, static-mode gas, quotes beyond the band on real feeds) |
| `cast call 0x4956…F813 "latestRoundData()…"`, `description()` (public RPC) | status 0, `startedAt` 1,793,291,075, "L2 Sequencer Uptime Status Feed", block 63,868,968 |

### 10.2 Mutation checks of the new tests

| Mutant | Killed by |
|---|---|
| `VaultRiskBoundary.dynamicFloor` without `+ uncertainty` (review) | fuzz test, non-vacuity test, fallback test, F-1 test (two-source half), jump test |
| `PriceRiskAdapter._tier` fresh boundary `<=` → `<` (review) | `test_freshTierBoundary_staleNarrowBandCannotAuthorize`, `test_freshTier_boundaryIsInclusive` |
| `midAndUncertainty` lower term divided by `mid` (the pre-closeout code; run after the closeout and restored) | `test_F1_…`, `testFuzz_normalizedFloorNeverInsideTheBand` (asset1 sold inside the band), `test_normalizedFloor_checksAreExercised`, `test_fallbackToOneSource_…`, `SharedCoreVectors.test_vectors_brackets` (row 0: 8,000 ≠ 8,065); the Python model's `test_uncertainty_covers_bracket_both_directions` checks the same property. **Not killed by the hook matrix**: the hooks' 30 bps base spread covers the `u²` gap at the quotes the matrix reaches, so the matrix shows compatibility, not the floor's exact edge |

### 10.3 Bytecode, size and gas

| Artifact (production build) | Before G04 | After | Change |
|---|---|---|---|
| `PriceRiskAdapter` runtime | 5,552 B | 5,581 B | +29 B (F-1: −2 B; sequencer checks: +31 B) |
| `PriceRiskAdapter.currentReference`, warm, two sources + sequencer (mock feeds) | 12,955 gas | 13,031 gas | +76 gas (F-1: −6; sequencer: +82) |
| `SharedCommitmentVault` runtime | 22,440 B, headroom 2,136 B | unchanged (same runtime and init hash) | 0 |
| `HookA_DynamicFee`, `HookB_BoundedImpact`, `VaultLens`, `CuratorAuthorization`, `VaultGovernor` | — | runtime and init hashes unchanged | 0 |

The comment-only `src/` edits were checked by hashing every production artifact's runtime and init bytecode before
and after; all are identical.

### 10.4 Deliberately not run

| Check | Why |
|---|---|
| deep suite (`test/deep.sh`), full mutation campaign, Slither | not requested; the change is confined to the adapter's two functions, covered by targeted, fuzz, invariant, vector and fork runs |
| benchmarks (`test/bench/`) | vault and hook bytecode unchanged; adapter gas measured directly |
| `UNICHAIN_SEPOLIA` fork | no Sepolia oracle feeds are used (the rehearsal deploys TEST feeds) |
| re-running the synthetic simulations | out of scope (§6) |

## 11. Owner decisions

Numbered after G03's R-17. The wording below is the original, unchanged. The closeout's recommendation and status
follow each item.

- **R-18.** F-1: option A (recommended), B or C; apply C now if any configuration can exceed 9,950 pips.
  - **Status:** resolved by the closeout instruction. Option A is implemented (§5); C is no longer needed.
- **R-19.** Stored sanity floors at deployment (recommended), or accept halt and pause as the guardian's only response
  to a wrong-but-valid price.
- **R-20.** Static fall-back: require both inventory targets before `setRiskAdapter(0)` executes (a vault check), or
  rely on deployment verification (recommended for now).
  - **Status:** the deployment verification exists now (gate 13).
- **R-21.** A broken source with `minSources = 1`: keep halting (current), or drop the source as the spec says.
- **R-22.** Sequencer `startedAt = 0`: a deployment check (current recommendation), or a one-line adapter refusal.
  - **Status:** resolved by the closeout instruction. The adapter refuses it (§2.4); gate 7 checks the configured feed.
- **R-23.** Commitment fees during oracle outages (§8.2, item 5).
  - **Note:** after the closeout restructuring, that item is §8.3, item 5.

Recommendations and security consequences for R-19 … R-23 are in the completion report and repeated here.

| Decision | Recommendation | Security consequence |
|---|---|---|
| R-19 | **Set stored sanity floors at deployment**, wide enough not to bind in normal markets (e.g. about 10% below the reference in each direction, consistent under D14), and require them in gate 9 for mainnet | With them, the guardian can raise a floor within one block against a wrong-but-valid price, and the static fall-back has floors; without them its only tools are halt and pause, which stop all trading in that direction. A floor set too tight stops trading in fast markets; it binds only at the floor, so it cannot loosen anything |
| R-20 | **Keep gate 13 (deployment verification) for now**; add the vault check only if the vault is changed for another reason | Gate 13 depends on operators running it before queueing and executing; a mis-step leaves an asset without an inventory floor after the fall-back. A vault check would be unconditional but costs vault bytes (2,136 B headroom) and a re-review of the vault |
| R-21 | **Keep halting** on a broken source | Fail-closed: a feed returning garbage or reverting is not known to be merely late, and dropping it would let one compromised feed silently reduce the sources to one. Cost: with `minSources = 1`, one broken feed halts trading although the other would suffice; with the configured `minSources = 2` the behaviour is the same either way |
| R-22 | **Done**; keep the adapter refusal and the gate 7 sequencer check | An uninitialized uptime round can no longer read as "up since 1970"; on chains without a supported feed the residual risk in §2.4 remains and must be accepted explicitly |
| R-23 | **Hooks pay for reserved capacity through outages; do not suspend fees on-chain** in the first version, and state it in the commitment terms | An on-chain outage record would need a permissionless checkpoint that proves continuous failure, which a view call cannot; suspending fees without it invites griefing (a caller timing a failing read). Paying through outages makes outage risk a cost the hook prices, and keeps LP fee accounting deterministic |

## 12. Result

**G04: PASS (local), awaiting owner review.**
- **The oracle trust boundary** is documented: freshness rules, fallbacks and ten failure scenarios, each with
  deterministic tests.
- **F-1 is corrected** at the shared reference, with a proof that both directional floors lie outside every live
  source's bracket for every edge. It is tested by an exact fuzz, a Hook A / Hook B matrix over two decimal pairs and
  six reference states, regenerated conformance vectors and real-feed fork runs.
- **The sequencer feed** can no longer be read as up when uninitialized.
- **Deployment gates** check feed identity, an independent price and the fixed-floor fall-back.
- **Still open:** R-19 … R-23 and the blockers in §9 are the owner's decisions.

## 13. Commits

Listed in the completion report.
