# Porkfolio — G04: Oracle Safety and Fallback

**Status: PASS (local), with one defect open for an owner decision (F-1, §5).** I reconstructed the oracle trust
boundary from the source. Ten failure scenarios now have deterministic tests through the real adapter, vault and
PoolManager.

**F-1, the defect.** The vault's asset1 directional floor, and the hooks' asset1 quote at the inventory cap, can sit
inside the reference band. The amount is the second-order term `u² / (1 − u)` less the edge.
- **Not exposed in the rehearsal configuration.** With two sources required, `u` stays near 8,200 pips. At the
  configured 1 bp edge, `u` must exceed 9,950 pips before the gap appears.
- **Exposed whenever a reading's `u` exceeds 9,950 pips.** The vault itself accepts readings up to 20,000 pips.
- **Why it is not fixed here.** The fix changes what the reference uncertainty means for both hooks and for the pricing
  model, so I stopped for review as the brief requires.
- **Mitigation available now.** The guardian can lower `maxUncertaintyPips` to 9,950, a tightening-only call.

No production contract was changed. `git diff 4dbe6b9 -- src script` is empty.

Labels used below:
- **ENFORCED**: a check in this repository's code.
- **TESTED**: a deterministic or fuzz test in this repository.
- **ARGUED**: reasoning from the code, with no dedicated test.
- **ASSUMED**: a property of an external provider, relayer or operator that no code here checks.

## 1. Starting state

- `main` = `origin/main` = `f557664` (the G02 tip). **G03 is not in `main`:** its branch `phase-2-g03-lp-accounting`
  (`4dbe6b9`) is ahead of `main` and has not been integrated.
- G03 changed no production code (`git diff f557664 4dbe6b9 -- src` is empty), and G04 relies on G03's admission-floor
  counterexamples (`test/security/ReservationDeliverability.t.sol`). I therefore branched
  `phase-2-g04-oracle-safety` from the G03 tip instead of from `main`.
- **Effect on review.** The production code reviewed here is byte-identical to `main`. Integrating G04 brings G03's
  commits with it unless G03 is integrated first.

## 2. Oracle trust boundary

### 2.1 Who provides prices, and who can change what

| Component | Role | Who can change it | How |
|---|---|---|---|
| Push feeds (Chainlink, RedStone; `IAggregatorV3`) | `latestRoundData` answers, one per USD leg | provider (and, for RedStone, anyone submitting signed packages) | external; nothing here can write to a feed |
| L2 sequencer uptime feed | up/down status and restart time | Chainlink | external |
| `PriceRiskAdapter` | turns 2 sources × 2 legs into `(priceX96, uncertaintyPips, validUntil, liveSources)` or reverts | nobody: no owner, no setter; every parameter immutable, hashed into `configVersion` | redeploy |
| `ReferenceBracket` (library inside the adapter) | per-source bracket, intersection, mid and uncertainty | — | redeploy the adapter |
| `SharedCommitmentVault.riskAdapter` | the one adapter every fill and every core-mode hook reads | owner only (`setRiskAdapter`); the guardian cannot | `VaultGovernor` DELAY (3 d proposed); the vault checks `pair()`, token decimals and one valid reading at installation |
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

### 2.4 Freshness rules (ENFORCED, TESTED)

| Rule | Code | Boundary |
|---|---|---|
| leg answer must be in `(0, 2^128)`, `updatedAt` non-zero and `≤ now`; ≥ 160 bytes returned; round id ≤ 2^80 | `PriceRiskAdapter._read` | otherwise `FeedUnusable(feed)`: the **whole read** reverts |
| fresh tier: `now ≤ updatedAt + freshMaxAge` → `freshDeviation` | `_tier` | inclusive (`test_freshTier_boundaryIsInclusive`, `test_freshTierBoundary_staleNarrowBandCannotAuthorize`) |
| push tier: `now ≤ updatedAt + maxAge` → `deviation` | `_tier`, `_source` | inclusive; one second later the source is not live |
| source live only if both legs are within a tier | `_source` | |
| `liveSources ≥ minSources` | `currentReference` | else `InsufficientSources` |
| `validUntil` = earliest time any used leg leaves the tier it was read in | `_source`, `currentReference` | vault refuses `validUntil < now` (inclusive at equality, matching the adapter) |
| sequencer: answer 0 or 1; down → refuse; up but `now < startedAt + grace` → refuse | `currentReference`, `_read` | `startedAt` in the future also refuses; **`startedAt == 0` is accepted as up** (§5, CE-O6) |

The configured tolerances from `script/DeploySystem.s.sol` (rehearsal) and the Unichain records:

| Parameter | Value |
|---|---|
| Chainlink-like legs | ±3,100 / ±5,100 pips, `maxAge` 88,200 s |
| RedStone-like legs | ±5,100 / ±5,100 pips, `maxAge` 12,600 / 23,400 s |
| RedStone fresh tier | `freshMaxAge` 120 s, ±1,500 pips |
| Sources required | `minSources` = 2 |
| Sequencer | grace 3,600 s on Unichain mainnet; the Sepolia rehearsal has no sequencer feed |
| Vault | `e` = 100 pips, `maxUncertaintyPips` = 20,000, `kappa` = 10,000 pips (1%) |

### 2.5 Uncertainty

`u = max(⌈(high − mid)·1e6 / mid⌉, ⌈(mid − low)·1e6 / mid⌉)`, a half-width measured relative to the mid
(`ReferenceBracket.midAndUncertainty`).
- **Two sources required.** The intersection lies inside the narrower bracket, so `u ≤` about 8,250 pips with the
  configured thresholds. The vault's 20,000 bound **never binds** in the rehearsal configuration; it is a guardian
  lever.
- **Guardian use of the bound.** Lowering it to 5,000 refuses push-only readings (about 8,200 pips) and keeps
  fresh-tier readings (about 3,000 pips).

### 2.6 Normalization across decimals (ENFORCED, TESTED)

- **The shift.** `e = (feed decimals 1 + token decimals 1) − (feed decimals 0 + token decimals 0)`.
  - Feed decimals are read once at construction.
  - Token decimals are constructor arguments, checked against `ERC20.decimals()` by `setRiskAdapter`.
  - `|e| ≤ 30`, else `InvalidConfig`.
- **Rounding.** Brackets round outward, the mid rounds down, `u` rounds up, the floors round up, and the fill's
  required input rounds up.
- **Fuzz result.** `testFuzz_normalizedFloorNeverInsideTheBand` checks exactly, with 512-bit cross-multiplication
  against each source's rational bracket, over random answers, thresholds (≤ 5%), feed and token decimals (0–24),
  edges (≤ 1%) and one or two sources. Its non-vacuity companion counts 289 of 300 derived cases checked, 11 refused.
  - **Selling asset0:** always at or above the band's top.
  - **Selling asset1:** at or above the reciprocal of the band's bottom **whenever `e·(1e6 − u) ≥ u²`**. Outside that
    condition this is F-1.

What is not checked on-chain:
- **Leg order.** Which leg is currency0 and which is currency1 (CE-O2).
- **Asset identity.** That a feed prices the asset its slot claims.
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
| sequencer status not 0/1 | `FeedUnusable` | fill refused | `test_sequencerMalformedAnswers` |
| sequencer down, or within grace | `SequencerUnavailable` | fill refused | `test_sequencerDownOrInGrace` |
| reading with `priceX96 = 0`, past `validUntil`, or `u` above the bound (any adapter) | — | `InvalidReference` / `UncertaintyTooHigh` | `test_invalidReadings_refused` |
| arbitrary price from a malicious or wrong adapter | — | priced at that reference; stops at the inventory floor | `test_maliciousAdapter_stopsAtInventoryFloor`, `test_swappedLegs_passInstallation_boundedByInventoryFloor` |

The vault does not read `liveSources`. Requiring two sources is the adapter's job.

### 2.8 Fallbacks

There is **no fallback price** anywhere: no stored last-good price and no default. There are three fallback paths:
1. **Second source within the adapter.** With `minSources = 1`, one stale source is dropped and the other prices
   alone, which widens the band. This applies only to staleness; a broken source halts the read (CE-O1).
2. **Static mode.** The owner removes the adapter (DELAY).
   - Fills then use stored floors only; a direction without a stored floor closes.
   - Inventory floors with a target keep applying. An asset without a target loses all inventory protection (CE-O4).
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
  - Every adapter-mode fill re-reads the adapter in the same transaction and fails closed on any revert, zero
    price, expired reading or excessive `u`.
  - The fill price is at least the maximum of the stored, curator and dynamic floors.
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
  - The sequencer feed is initialized.
- **ASSUMED (operators).**
  - The adapter is built with the right feed in each slot.
  - The relayer, if any, only adds availability; it cannot set a price.
  - The guardian reacts within the flow-cap window.

## 3. Failure scenarios (Task 2)

All with the production `PriceRiskAdapter` over mock feeds, unless noted.

| # | Scenario | What happens | Test |
|---|---|---|---|
| 1 | stale primary | stale source dropped; two required → every fill refused. At the fresh-tier boundary + 1 s the narrow-band fill is refused (`PriceBelowFloor` against the wider push band) | `test_staleSource`; `test_freshTierBoundary_staleNarrowBandCannotAuthorize`; `test_relayerOutage_…` |
| 2 | unavailable fallback | `minSources` = 1: a stale fallback is dropped; a reverting or zero-answering fallback halts every read (CE-O1) | `test_unavailableFallback_haltsEvenWhenOneSourceSuffices` |
| 3 | conflicting sources | empty intersection → `ReferenceDivergence`. Within both error bounds (≤ about 1.84%) a disagreement only shifts the mid (CORRELATED_ORACLE_FAILURES.md, scenario 1) | `test_divergenceReverts` |
| 4 | valid but very uncertain | refused above `maxUncertaintyPips`; below it, quotes widen with `u`. **F-1: above 9,950 pips the asset1 floor is inside the band** | `test_F1_asset1FloorInsideBand_whenUncertaintyExceedsEdgeBound`, `test_invalidReadings_refused` |
| 5 | wrong direction or decimals | wrong token decimals or a swapped pair: refused at installation. **Swapped legs pass installation** and invert the price; the loss stops at the inventory floor (CE-O2) | `test_setRiskAdapter_validation`, `test_swappedLegs_passInstallation_boundedByInventoryFloor` |
| 6 | zero, negative, malformed | `FeedUnusable`; sequencer status ∉ {0, 1} likewise; sequencer `startedAt = 0` accepted (CE-O6) | `test_unusableLegReverts`, `test_sequencerMalformedAnswers` |
| 7 | replayed or expired signed updates | expired → dropped; future-dated → `FeedUnusable`; replay or rollback by the feed → accepted (provider assumption) | `test_freshnessIsTheFeedsClaim_replayAndRollback` |
| 8 | large move or depeg | feeds 8% behind the market inside their staleness limits: buyers take the inventory room at the stale band's top (about 1.0085 for an asset worth 1.08), and one more raw unit is refused. Loss 716.6 per 10,000 room, below `(δ − band)·room` | `test_jumpTheFeedsMissed_lossStopsAtInventoryRoom`; depeg: `test_Q4_depeg_markToMarketBeyondKappa_whileQ1Q2Hold` |
| 9 | price update between reservation and execution | the allocation fixes no price: after a move up the reservation-time price is refused; after a move down a lower price is accepted; only the curator floor is fixed | `test_priceMoveBetweenReservationAndExecution`, `test_replaceAdapter_duringActiveAllocation` |
| 10 | oracle failure during queued withdrawals | fills stop; `Q` stays reserved, so the LP's instant part is limited to `F` and the rest queues; queue, claims, deposits, cancellation and guardian tools work; a guardian release finalizes the queue; trading resumes when a source pushes | `test_outageWithReservation_exitsQueueBehindItUntilReleased`, `test_lpPaths_independentOfAdapter` |

## 4. Execution guarantees (Task 3)

| Property | Status | Evidence |
|---|---|---|
| **O-1** Unsafe swaps fail closed: any adapter revert, zero price, expired reading or `u` above the bound refuses the fill and changes nothing | ENFORCED, TESTED | §2.7 |
| **O-2** Stale data cannot authorize a fill the fresh data would refuse: the tier and `validUntil` are inclusive in both contracts; one second later the wider band applies | ENFORCED, TESTED | `test_freshTierBoundary_…`, `test_freshTier_boundaryIsInclusive` |
| **O-3** A fallback cannot loosen inventory protection: the inventory floor contains no price and applies in every mode once a target exists; adapter mode refuses an asset without a target | ENFORCED, TESTED, **except CE-O4** (static fall-back with an asset without a target) | `test_inventoryFloor_appliesInStaticMode`, `test_adapterRemoval_assetWithoutTarget_losesInventoryFloor` |
| **O-4** A fallback to fewer sources keeps each floor beyond the **remaining** sources' band. It can lower the asset0 floor relative to the two-source floor by `e·(mid₂ − mid₁)` plus rounding: 0.28 pip at `e` = 1 bp in the test | TESTED | `test_fallbackToOneSource_staysOutsideRemainingBand` |
| **O-5** Hook A and Hook B are held to identical vault rules: both call the same `exchange` → `_floorForFill` with the same adapter, edge and inventory floor; each hook's `minEdge ≥ e + 1` | ENFORCED, TESTED | `test_bothHooks_fillOutsideBand`, `test_adapterFailure_stopsBothHooks`, `test_inventoryCap_sharedAcrossHooks`, `test_hookEdge_isVaultEdgePlusOne`, `test_relayerOutage_…` |
| **O-6** Oracle failure never blocks claims or LP withdrawals that free inventory can pay | ENFORCED (no LP path reads the adapter), TESTED | `test_lpPaths_independentOfAdapter`, `invariant_lpPathsIndependentOfAdapter`, `test_outageWithReservation_…` |
| **O-7** Guardian restrictions survive oracle failure and adapter transitions: pause, halt, raising stored floors, raising `e`, lowering the bound, tightening inventory bounds and early release read no price | ENFORCED, TESTED | `test_haltAndPause_surviveTransitions`, `test_guardianRaisedFloor_survivesInstall`, `test_outageWithReservation_…` |
| **O-8** Normalization and rounding never put a fill inside the band: asset0 always; **asset1 only when `e·(1e6 − u) ≥ u²`** | TESTED (fuzz, exact), **F-1** | `testFuzz_normalizedFloorNeverInsideTheBand`, `test_normalizedFloor_checksAreExercised` |
| **O-9** Whatever any price input says, no fill takes `N_a` below `L_a` | ENFORCED, TESTED | `invariant_holdingsAtOrAboveInventoryFloor`, `test_maliciousAdapter_…`, `test_swappedLegs_…`, `test_jumpTheFeedsMissed_…` |

## 5. Findings

### F-1. The asset1 floor can sit inside the reference band (DEFECT, reproduced; fix not applied)

**What.**
- `u` is the band's half-width relative to the mid, so the band's bottom can be as low as `P(1 − u)`.
- Selling asset1, the vault must charge at least `1 / low` asset0 per asset1. That is at most
  `(1/P)(1 + u + u² + …)`.
- The floor is `F1 = (1/P)(1 + u + e)`.
- So `F1 ≥ 1/low` is guaranteed only when `e·(1e6 − u) ≥ u²` (pips), i.e. `u ≤ 9,950` for `e` = 100.
  `VaultRiskBoundary`'s claim "it never trades at a price any live source allows to be at or past the market, plus
  `e`" holds for asset0 and is false for asset1 above that `u`.
- The asset0 floor `P(1 + u + e) ≥ high + e·P` is exact.

**Reproduced.** `test_F1_asset1FloorInsideBand_whenUncertaintyExceedsEdgeBound`:
- **Setup.** `minSources` = 1, Chainlink stale, RedStone alone in its push tier: `u` = 10,200, accepted under the
  vault's 20,000 bound.
- **Result.** The vault sells 1,000 asset1 for 0.0048 asset0 less than the least price RedStone allows (4.8 pips; the
  formula gives 105 − 100 = 5).
- **At the vault's own bound.** At `u` = 20,000 the gap is about 308 pips beyond the edge.

**Also in the hooks (ARGUED).** `InventoryPricing.straddleCap` keeps the ask at the cap edge at `(1/P)(1 + hMin)`
with `hMin = minEdge + u`. That has the same second-order gap on the asset1-selling side.
- Inside the cap, hooks charge `baseSpread + u`, which covers `u²` at the configured spreads.
- Only quotes near the cap edge are affected.
- The bid side, where the vault sells asset0, is conservative.

**Not exposed in the rehearsal configuration.**
- With two sources required, `u` stays below about 8,250 pips. This is ARGUED: the intersection lies inside the
  Chainlink-like bracket, whose half-width at the configured thresholds is about 8,200 pips. Every two-source reading in
  `OracleFailureExecution.t.sol` is in that range.
- The inventory floor bounds the loss in every case (O-9).

**Options (owner decision R-18):**

| Option | Change | Cost | Effect |
|---|---|---|---|
| **A (recommended)** | Adapter only: measure the downside of `u` from the low end, `⌈(mid − low)·1e6 / low⌉`, so `[P/(1+u), P(1+u)]` covers the band | one line in `ReferenceBracket`; the `IMarketRiskAdapter.uncertaintyPips` definition; the Python model `mid_and_uncertainty` and `shared_core_brackets_v1` vectors; the measured 8,200 pips becomes about 8,268; a new adapter install (DELAY) | fixes the vault floor **and** the hooks; vault and hook bytecode unchanged; EIP-170 unaffected |
| B | Vault: widen asset1's floor by `u/(1 − u)` | vault bytecode, `vault_risk_v1` vectors, lens | fixes the vault floor only. The hooks' asset1 quote at the cap edge would then fall **below** the vault floor and be refused, so the hooks would also need changing. Not recommended |
| C | Configuration only: keep `e·(1e6 − u_max) ≥ u_max²`, i.e. `maxUncertaintyPips ≤ 9,950` at `e` = 100 | none in code; the guardian can apply it now (tightening only) | closes the gap for both vault and hooks while it holds; it is a constraint every future `e` / bound change must respect |

C should be applied before any configuration in which `u` can exceed 9,950 pips: `minSources = 1`, wider thresholds,
or another provider. A is the durable fix.

### Counterexamples to stronger readings (not defects)

| Id | Statement | Test | Assessment |
|---|---|---|---|
| CE-O1 | **A broken fallback halts.** With one source required, a reverting or zero-answering second source makes every read revert, although the first alone would suffice. Contradicts ORACLE_RISK_BOUNDARY_SPEC.md §5 ("a leg stale, missing or malformed → its source is dropped") | `test_unavailableFallback_…` | fail-closed, so safe; costs availability only with `minSources` = 1. The configured `minSources` = 2 halts anyway. R-21 |
| CE-O2 | **Swapped legs pass installation.** An adapter built with leg0 and leg1 exchanged reports `1/P`; `setRiskAdapter` checks only the pair, token decimals and that a reading exists. At a true price of 2 the vault sold its whole asset0 room (10,000) for 5,041.7 asset1 | `test_swappedLegs_…` | bounded by the inventory floor (O-9) and by any stored floor. A deployment check is needed: compare the reading with an independent price before queueing `setRiskAdapter` (§9) |
| CE-O3 | **No guardian price floor in adapter-only mode.** The rehearsal deploys with no stored floors. The guardian may only raise a stored floor that exists, so against a wrong but valid price its tools are halt and pause. An owner-set sanity floor restores the finer tool | `test_swappedLegs_…` (second half) | R-19 |
| CE-O4 | **Static fall-back drops protection for an asset without a target.** Adapter mode refuses an asset with `tau = 0`; after `setRiskAdapter(0)` (DELAY, not LONG_DELAY) and with a stored floor, that asset trades with no inventory floor (a 10% sale went through where 1% would be the room) | `test_adapterRemoval_assetWithoutTarget_losesInventoryFloor` | requires owner action and an unset target. The rehearsal sets both targets before any share exists (`DeploySystem`), and VerifyDeployment should check it. R-20 |
| CE-O5 | **Freshness is the feed's claim.** Replays and rollbacks by a feed are accepted (§2.3) | `test_freshnessIsTheFeedsClaim_…` | provider assumption; RedStone's `updatedAt` semantics must be measured before enabling the fresh tier |
| CE-O6 | **Sequencer `startedAt = 0` reads as "up since 1970".** The adapter does not treat a zero restart time as an invalid round | `test_sequencerMalformedAnswers` | Unichain's feed is initialized (`startedAt` 1,793,291,075, `ORACLE_VERIFICATION_UNICHAIN.md` §2). A deployment check, or a one-line adapter change if the owner prefers (R-22). I could not retrieve Chainlink's current guidance (the documentation URL returned 404), so I did not treat this as a defect |
| CE-O7 | **A fallback can lower one floor slightly.** O-4: under one pip at the configured edge | `test_fallbackToOneSource_…` | accepted; the floor stays beyond the remaining band |
| CE-O8 | **An unexecutable reservation still withholds inventory.** During an outage `Q` is not reduced, so LP instant exits are limited to `F = N − Q` until the allocation is released or expires (≤ 30 days) | `test_outageWithReservation_…` | by design (G03 G-11); matters for fees on reserved capacity (§8) |

### Correction to an earlier document

- **The spec says one thing, the code another.** `ORACLE_RISK_BOUNDARY_SPEC.md` §5 says a stale, missing or malformed
  leg drops its source. The code drops a **stale** source only; a missing or malformed leg reverts the whole read
  (CE-O1). The adapter's own NatSpec states the code's behaviour correctly.
- **The rehearsal's tolerances.** `maxUncertaintyPips` = 20,000 does not bind with the configured adapter (§2.5).

## 6. Safety invariants

The invariants that hold under every oracle input, with the evidence for each:
1. **`N_a ≥ min(N_a before the fill, L_a)` after every fill, in every mode with a target.** ENFORCED;
   `invariant_holdingsAtOrAboveInventoryFloor`, `invariant_Q1_perShareFloor`, `invariant_noFillUnderAdapterFault`.
2. **No fill without a valid reading in adapter mode.** ENFORCED; §2.7.
3. **Each fill pays at least `ceil(out × max(stored, curator, dynamic) / 2^96)`, on the exact claims moved.** ENFORCED;
   `test_dynamicFloor_bothDirections_exactBoundary`.
4. **No LP or claim path depends on the oracle.** ENFORCED; `invariant_lpPathsIndependentOfAdapter`.
5. **The adapter, hook and vault read one configuration in one transaction.** ENFORCED; `test_coreInputs_matchGetters`,
   `test_quotesFollowTheVaultsAdapter`.
6. **The asset0 floor is beyond every live source's top.** TESTED (exact fuzz).
7. **The asset1 floor is beyond the band's bottom when `e·(1e6 − u) ≥ u²`.** TESTED (exact fuzz); F-1 otherwise.

## 7. Exact LP protection limits

These are inventory-unit guarantees, not value guarantees (G03 G-9, G-10; `INVENTORY_FLOOR_GUARANTEE.md`).

**What the inventory floor promises.** Each share keeps at least `tau_a·(1 − kappa_a)` of each asset it had at least
that much of, whatever the oracle says.

What it does not promise:
- **Value loss is not bounded by `kappa`.** Loss as a fraction of value can exceed `kappa`
  (`test_Q1_holds_butLossFractionExceedsKappa_whenGainsLiftHoldings`).
- **Cumulative realized loss is unbounded** (`test_Q3_cumulativeRealizedLoss_exceedsKappaOfStartingValue`).
- **A depeg** marks the held units down with no limit (`test_Q4_…`).
- **The value at risk from a wrong price** is up to `Σ_a (N_a − L_a)·p_a` at the true prices, per re-centring. With
  `kappa` = 1% and the asset worth 1.08, the test lost 716.6 per 10,000 of room.

The price checks (dynamic floor, edge, uncertainty bound) bound the price of each fill only to the extent the
providers' assumptions hold (§2.10). The inventory floor is the only bound that does not depend on them.

## 8. Implications for future commitments (Task 4)

### 8.1 Four guarantees a reservation might mean

| Guarantee | Today | Why |
|---|---|---|
| **Exclusive accounting capacity** | **yes** | `Q_a ≤ N_a`; no two allocations count the same unit (G03 G-3); capacity stays reserved through oracle outages (CE-O8) |
| **Immediate physical availability** | **yes, as custody** | `Q_a + W_a ≤ B_a ≤` vault's ERC-6909 balance (G03 G-1, G-2): the claims exist in the PoolManager. Not the same as being payable |
| **Execution only while price conditions hold** | **yes, but no price is fixed** | every fill needs a valid reading and pays at least the dynamic floor at execution time; the reservation fixes only the curator floor (scenario 9) |
| **A bounded quantity of guaranteed executable output** | **no: 0 in the worst case** | executable output = `min(remaining, N_a − L_a, flow caps, exposure)` at execution time, and `N_a − L_a` is shared by every allocation and shrinks with other hooks' fills and with LP exits (G03 CE-1, CE-2); an outage makes it 0 for its duration |

These are not equivalent. Only the first two hold unconditionally, and neither is an execution guarantee.

### 8.2 What a commitment engine must enforce

**At admission:**
1. The existing rule `q ≤ N − Q − R − D` and the exposure caps.
2. **Room-aware admission (R-15).** `Q_a + q ≤ N_a − L_a`, if the engine sells executable output rather than capacity.
   On its own this is not enough, because LP exits shrink `N_a − L_a` (G03 CE-2). Either:
   - commitments reserve their own room that exits respect (a vault change); or
   - commitments are defined as capacity, with fees charged only on what was executable (design note §2.10, D-6).
3. **A valid reading at admission**, if the commitment is priced: refuse admission when `currentReference` reverts, so
   a hook does not pay for capacity it cannot use from the start.
4. **A curator floor stated explicitly.** It is the only price a reservation fixes.
5. **Bonded fees that do not accrue on capacity the vault itself refuses to execute.**
   - An outage is not recorded on-chain, so this needs either:
     - a permissionless "unavailable" checkpoint that calls the adapter and records failure intervals with their
       uncertainty; or
     - accepting that hooks pay for oracle downtime and pricing that into the rate.
   - Owner decision R-23.

**At execution (all already enforced by `exchange`):**
- a valid reading, the max of the three floors, the inventory floor, flow caps, expiry, quota, pause and halt;
- **plus** F-1 resolved, or the C constraint, before any commitment is priced off the reference band.

**What the engine must not promise:** a price, a quantity above `N_a − L_a`, or execution through an oracle outage.

## 9. Deployment risks

1. **F-1** until option A or C is in force (§5).
2. **Leg order and feed identity** cannot be checked on-chain (CE-O2). Before queueing `setRiskAdapter`, compare
   `currentReference()` with an independent price and record the result with `configVersion`.
3. **RedStone `updatedAt` semantics** must be measured before enabling the fresh tier (§2.3).
4. **Sequencer feed.** It must be configured on mainnet (the Sepolia rehearsal has none) and initialized (CE-O6).
5. **Stored sanity floors.** Without them, the guardian's only responses to a wrong-but-valid price are halt and pause
   (CE-O3).
6. **Both inventory targets set** before an adapter is removed or installed. Add this to VerifyDeployment (CE-O4).
7. **The two sources share upstream data.** A common-mode error inside both brackets is undetected and bounded only by
   the inventory floor (`CORRELATED_ORACLE_FAILURES.md`, scenario 3).
8. **Adapter replacement is DELAY, not LONG_DELAY**, and re-prices every live allocation at once
   (`test_replaceAdapter_duringActiveAllocation`).
9. **Fork evidence is from 2026-11-10.** No fork test was rerun in G04 (§10.3).

## 10. Validation

### 10.1 Commands and results

| Command | Result |
|---|---|
| `forge fmt --check` | clean |
| `git diff 4dbe6b9 -- src script` | empty |
| `forge test --match-contract "OracleFailureModesTest\|OracleFailureExecutionTest" -vv` | 6 + 7 passed |
| `forge test` (default profile) | see §10.4 |
| `FOUNDRY_PROFILE=ci forge test --match-contract "OracleFailure\|PriceRiskAdapter\|OracleRiskBoundary\|VaultRiskBoundary\|SharedCoreHooks\|RelayerOutage\|HookPriceBands\|InventoryProtectionBounds\|ReservationDeliverability"` | see §10.4 |
| `FOUNDRY_PROFILE=ci forge test --match-contract "OracleRiskInvariants\|InventoryProtectionInvariants\|VaultInvariants"` | see §10.4 |
| `python3 test/invariant/coverage.py` | see §10.4 |

### 10.2 Mutation checks of the new tests

| Mutant | Killed by |
|---|---|
| `VaultRiskBoundary.dynamicFloor` without `+ uncertainty` | fuzz test, non-vacuity test, fallback test, F-1 test (two-source half), jump test |
| `PriceRiskAdapter._tier` fresh boundary `<=` → `<` | `test_freshTierBoundary_staleNarrowBandCannotAuthorize` (and the existing `test_freshTier_boundaryIsInclusive`) |

Both mutants were applied to a working copy and restored; `git status` showed no change to `src/` afterwards.

### 10.3 Deliberately not run

| Check | Why |
|---|---|
| deep suite (`test/deep.sh`), full mutation campaign, Slither | no production contract changed |
| contract sizes, gas benchmarks | no production bytecode changed; EIP-170 headroom unchanged |
| fork tests (`test/fork/`) | the affected behaviour was reproduced with the production adapter over mock feeds; the real-feed facts used (decimals, thresholds, sequencer `startedAt`) are from the 2026-11-10 fork records. Measuring RedStone's `updatedAt` semantics needs a fork run and is listed as a deployment step (§9) |

### 10.4 Results

| Run | Result |
|---|---|
| `forge test` | 665 passed, 0 failed, 8 skipped (fork tests, no RPC); 65 suites, 22.0 s |
| CI profile, oracle and inventory suites (11 suites incl. the two new ones and G03's `ReservationDeliverability`) | 82 passed, 0 failed; the new fuzz test at 10,000 runs |
| CI profile, `OracleRiskInvariants` / `InventoryProtectionInvariants` / `VaultInvariants` | 3 + 6 + 35 passed; every invariant 128 runs × 16,384 calls, 0 reverts |
| `python3 test/invariant/coverage.py` (64 seeds, depth 128) | every gate passed (vault, oracle, inventory, liveness) |
| non-vacuity of the new fuzz test (`test_normalizedFloor_checksAreExercised`, 300 derived cases) | 11 refused; asset0 checked 148 (one source) / 141 (two); asset1 checked 217, outside F-1's condition 72 |

## 11. Owner decisions

Numbered after G03's R-17.
- **R-18.** F-1: option A (recommended), B or C; apply C now if any configuration can exceed 9,950 pips.
- **R-19.** Stored sanity floors at deployment (recommended), or accept halt and pause as the guardian's only response
  to a wrong-but-valid price.
- **R-20.** Static fall-back: require both inventory targets before `setRiskAdapter(0)` executes (a vault check), or
  rely on deployment verification (recommended for now).
- **R-21.** A broken source with `minSources = 1`: keep halting (current), or drop the source as the spec says.
- **R-22.** Sequencer `startedAt = 0`: a deployment check (current recommendation), or a one-line adapter refusal.
- **R-23.** Commitment fees during oracle outages (§8.2, item 5).

## 12. Result

**G04: PASS (local).**
- **Reconstructed and tested.** The oracle trust boundary, freshness rules, fallbacks and the ten failure scenarios
  are reconstructed from the code and covered by deterministic tests.
- **Fail-closed behaviour holds.** Oracle failure never blocks LP exits or claims, and guardian tools work throughout.
- **One defect, F-1.** It is reproduced, bounded, and not exposed in the rehearsal configuration. Its fix changes the
  pricing definition shared by the adapter, hooks and model, so it is left for the owner (R-18), with a guardian-level
  mitigation available now.
- **No production code changed.**

## 13. Commits

Listed in the completion report.
