# Porkfolio — Phase 1B-4.3 Report: Guarded Oracle Integration

**Status: PASS (local experimental integration); NOT approved for deployment or release.**
- Branch `phase-1b-4-3-oracle-integration` from `phase-1b-4-2-oracle-risk-boundary` at `5de09b1`.
- Verified at the start, at 2,000 runs, matching Phase 1B-4.2:
  - vault runtime 22,049 B, runtime keccak `0x5ab6d06f7b00…`, init keccak `0xcd95dfdd0930…`;
  - Hook A 8,576 B, Hook B 9,165 B, `CuratorAuthorization` 7,409 B, `VaultLens` 6,972 B.
- Labels: PROVEN, TESTED, MEASURED, ESTIMATE, SYNTHETIC.

## 1. Did the inventory-loss guarantee survive stateful adversarial testing?

**Yes, in its correct form; the stronger form is false** (`INVENTORY_FLOOR_GUARANTEE.md`).
- **T1 (PROVEN, TESTED).** Per share, a holding never falls below min(entry, `tau (1 − kappa)`).
- **T2 (PROVEN, TESTED).** An LP's shortfall against holding its entry basket, at any prices including depegs, is at
  most `s · sum_a (h_a − l_a)^+ p_a` plus rounding.
- **Evidence.**
  - Python model: exact integers, adversary sets every price; 300 × 400-call sequences plus a hill-climb; 40,526
    payouts × 6 price vectors. 0 violations, rounding ≤ 1.9 raw units per payout.
  - Solidity: stateful invariant, adversary owns the adapter (§8).
- **Covered:** repeated trades, both hooks, deposits (pro-rata, so they cannot refill per-share inventory), partial
  and full withdrawals, queued and finalized withdrawals, refill-then-drain, multiple epochs, flash deposits.
- **Not true: "loss ≤ `kappa` of vault value".** It is true only at the target composition. The random search reached
  13.3% at `kappa` 5% once fees or skew lifted holdings above target.
- **Mark-to-market loss (depegs) is not bounded and not claimed.**

## 2. Counterexamples and design corrections

| # | Finding | Correction |
|---|---|---|
| C1 | Immediate owner loosening of `tau`/`kappa` (1B-4.2 patch) opens the whole reserve | `VaultGovernor` as owner: 32-day delay for `setInventoryBounds`; guardian only tightens |
| C2 | 1B-4.2 patch dropped the inventory floor outside adapter mode | floor applies in every mode once `tau` is set |
| C3 | A short delay does not protect a queued LP: commitments can hold it up to 30 days, and its shares bear the new floor | floor delay 32 days > `MAX_HORIZON` + a flow window; tested end to end (`test_queuedLp_finalizedBeforeFloorLoosening`) |
| C4 | Room grows with fees and skew | bound stated as `sum (h − l)^+ p`; raising `tau` re-centres it (immediate for owner and guardian) |
| C5 | `tau = 0` means no floor | fills in adapter mode refuse a direction without a target |
| C6 | 1B-4.2 patch ignored stored floors in adapter mode, so a guardian-raised floor disappeared on install | fill floor = max(stored, curator, dynamic); clearing a stored floor is a loosening, allowed only in adapter mode |
| C7 | The delay enforced inside the vault costs 840 B and leaves 1,323 B headroom (target 2,048) | delay moved to an external timelock owner (0 B in the vault); in-vault variant kept as `docs/proposals/vault-inline-change-delay.patch` (decision R-1b) |

## 3. Guardian and governance transition rules

| Change | Owner (= `VaultGovernor`) | Guardian | Effect on live state |
|---|---|---|---|
| install, replace or remove the adapter | 3-day delay; pair, decimals and a live reading checked | — (it halts or pauses instead) | live allocations re-priced at once; stored and curator floors keep binding; removal closes directions with no stored floor |
| `setRiskBounds` (edge `e`, max uncertainty) | 3 days | raise `e`, lower the bound | next fill |
| `setInventoryBounds` (`tau`, `kappa`) | 32 days | raise `tau`, lower `kappa` | next fill |
| stored floor: raise / lower / clear | 3 days (clear only in adapter mode) | raise only | next fill |
| halt / pause | 3 days to lift | set immediately | survive every adapter transition (tested) |
| `transferOwnership` | 32 days | — | escaping the governor waits as long as a floor change |
| `setGuardian` | 3 days, **not** cancellable by the guardian | — | — |
| cancel a queued change | admin | any change except `setGuardian` | — |

Execution window: 7 days after `eta`. Each queued calldata runs at most once; re-queuing starts a new delay.
- **LP paths never read the adapter.** Deposits, redemptions, queue, claims and cancels all work with a reverting
  adapter (tested).
- **Deployment invariant:** `vault.owner() == governor`, checkable on-chain.

## 4. Implemented contracts and interfaces

**`SharedCommitmentVault`:**
- `riskAdapter`, `riskEdgePips`, `maxUncertaintyPips`, `inventoryTargetPerShare[2]`, `inventoryTolerancePips[2]`;
- `setRiskAdapter`, `setRiskBounds`, `setInventoryBounds`;
- `_floorForFill` (stored, curator and dynamic floors, inventory floor) and `_reading` (zero price, expiry and
  uncertainty checks);
- `setSellFloor` may clear a floor only in adapter mode.

**`VaultGovernor`** (new): `queue`, `cancel`, `execute`, `acceptVaultOwnership`, `delayFor`.

**Hooks:**
- `BaseCompatibleHook`: shared-core mode with `configureCore`, `_coreState` and `_quoteAny`. The adapter comes from the
  vault; the cap is clamped to the vault's `kappa_1` and the edge raised to at least the vault edge + 1 pip.
- `HookA_DynamicFee`: the activity fee on the core.
- `HookB_BoundedImpact`: `configureStrategy` for a markup and per-trade bound on the core.

**`VaultLens`:** `effectiveFloorX96` mirrors the new floor; new `inventoryRoom`.

**Interfaces:** `ISharedCommitmentVault` (events and errors), `IVaultState` (getters).

**Unchanged:** `CuratorAuthorization`, `PriceRiskAdapter`, `VaultRiskBoundary`, the pricing libraries.

## 5. Bytecode and storage (MEASURED)

| Contract | Before (5de09b1) | After | Headroom (EIP-170) |
|---|---|---|---|
| `SharedCommitmentVault` (200 runs) | 22,049 B at 2,000 runs | **22,249 B** (same source at 2,000 runs: 25,048 B, over the limit) | 2,327 B (target 2,048: met) |
| `HookA_DynamicFee` | 8,576 B | 15,116 B | 9,460 B |
| `HookB_BoundedImpact` | 9,165 B | 15,338 B | 9,238 B |
| `VaultLens` | 6,972 B | 8,902 B | 15,674 B |
| `VaultGovernor` | — | 3,027 B | 21,549 B |
| `CuratorAuthorization` | 7,409 B | unchanged | |

**Vault storage:** the 25 existing layout entries are unchanged; appended:
- slot 24: `riskAdapter`, `riskEdgePips` (offset 20), `maxUncertaintyPips` (offset 23);
- slots 25–26: `inventoryTargetPerShare`;
- slot 27: `inventoryTolerancePips`.

**Hook storage:** `coreParams` is slot 0 (base contract), and each hook's own state moves down one slot. Hooks are
redeployed anyway, so no migration is involved.

**Deployment:**
- **Vault (CREATE).** Its address does not depend on its code.
- **Hooks.** Their addresses must encode their permission bits, so they are mined from the init-code hash. Init code
  changed, so any previously mined CREATE2 salt is void. The repository has no deployment script or stored salt.
- **New steps:** deploy and configure, `initialDeposit`, `transferOwnership(governor)`,
  `governor.acceptVaultOwnership()`.

## 6. Gas (MEASURED)

**Integrated swaps on a read-only Unichain fork.**
- Setup: Unichain's PoolManager `0x1F98…0004`, production builds, `PriceRiskAdapter` over the live Chainlink and
  RedStone WETH/USDC feeds, `--isolate`.
- Results:
  - Hook B shared core: **417,181** (1,000 USDC → WETH) and **412,452** (0.5 WETH → USDC);
  - Hook A shared core: **444,147** and **439,499**;
  - Hook A static mode, same fork: **296,761**.
- Shared-core pricing therefore costs **about +147k per swap (+50%)**. The 1B-4.2 estimate of ≈ 353k for Hook B was 18%
  low.
- Where it goes:
  - two adapter reads (hook, then vault): ≈ 76k cold + 24.5k warm;
  - the hook's seven vault getters;
  - the core math (≈ 10k);
  - the vault's floor and inventory check.

**Production benchmark** (local `test/bench/run.sh`, `--isolate`, static mode). Baseline: `5de09b1`, vault at 2,000
runs. Now: vault at 200 runs, hooks with the mode check.

| Operation | Before | After | Change |
|---|---|---|---|
| swap Hook A / Hook B | 262,580 / 244,885 | 270,044 / 252,175 | +7,464 / +7,290 (+2.8% / +3.0%) |
| split 10 × 100, Hook A / Hook B | 2,408,725 / 2,387,594 | 2,483,365 / 2,461,024 | +3.1% |
| deposit / redeem instant / redeem queued / claim / processQueue | 149,223 / 160,392 / 147,673 / 135,857 / 121,985 | +719 / +441 / +552 / +97 / +330 | +0.07–0.48% |
| allocate (steady) / signed activation (EOA) | 293,921 / 314,088 | +655 / +543 | +0.2% |
| hook quote views | 18,942–21,751 | 25,956–28,865 | +7.0–7.1k |
| deploy vault | 4,919,363 | 4,986,481 | +1.36% |
| deploy lens | 1,581,329 | 1,994,735 | +26% |

In static mode a swap pays about +7.3k for two things:
- the hook's `vault.riskAdapter()` check;
- the vault's mode and inventory-target reads, at 200 runs.

In shared-core mode it pays about +147k (fork figures above).

## 7. Cross-hook tests (`test/integration/SharedCoreHooks.t.sol`, real PoolManager, production builds)

All 11 pass:
- fills outside the band in both directions on both hooks;
- quotes equal the libraries;
- quotes follow the vault's adapter, including a replacement;
- an adapter failure stops both hooks;
- ten alternating cross-hook round trips each lose;
- the inventory cap is shared across hooks;
- a split across hooks pays at least the core;
- guardian tightening (edge, `kappa`) reaches both hooks with no hook action;
- a 10%-wrong reference is refused by stored and curator floors, or bounded by the cap above the vault floor;
- removing the adapter restores static pricing.

## 8. Oracle and adversarial results

- **`OracleRiskBoundary.t.sol` (13):** the exact dynamic-floor boundary in both directions; malformed readings refused
  (zero, expired, uncertainty, reverting); a malicious adapter drains exactly `N − L` for dust and one more raw unit is
  refused; adapter validation; every transition in §3.
- **`OracleRiskInvariants.t.sol`.** The handler owns the adapter and mixes drains at chosen prices, honest refills,
  LP flows, guardian re-centring and time. Invariants:
  - T1 after every call;
  - accounting equations;
  - holdings vs floor.
  
  A liveness test guards against a vacuous campaign. This mattered: the first run filled nothing because of a handler
  bug, which was found and fixed.

  Deep campaign (256 runs × depth 128, `fail_on_revert`): all 3 invariants pass over 32,768 calls with 0 reverts;
  `drain` fills and refusals at the floor occur in every run. The existing `VaultInvariantsTest` (35) passes under the
  same settings with the new vault.
- **Mutation: 26 mutants of the new vault, governor, hook and lens code; 26/26 killed.**
  - On the first run, three survived:
    - V7: an unset stored floor counting as 0 in adapter mode;
    - V13: the adapter's asset1 not checked;
    - H5: Hook A's flow level not stored in core mode.
  - Two tests were added (`test_setRiskAdapter_rejectsOtherAsset1_andZeroCuratorFloor`,
    `test_hookA_activityLevelPersistsInCoreMode`), and they kill all three.

## 9. `kappa` sensitivity (`KAPPA_SENSITIVITY.md`, SYNTHETIC)

- **Availability barely moves with `kappa`.** Push-only fill is 4.1–4.8% and fresh-source fill 35–38% across 1–15%.
- **Compromise loss is close to linear in `kappa`.** Malicious adapter, worst seed: −39 / −89 / −233 / −386 / −514 bps
  (push-only) at 1 / 2 / 5 / 10 / 15%.
- **Repeated drain-and-refill extracts exactly `kappa` of value.**
- **LP exits are 100% instant at every `kappa`.**
- **Proposed ranges** (R-4): 1–2% for a first mainnet launch; 5–15% only for testnet experiments.

## 10. Fresh-price feasibility (`FRESH_PRICE_EVALUATION.md` §6)

- **RedStone.** The push adapter on Unichain accepts a signed package from **any** sender (MEASURED by replaying the
  latest relayer calldata from an unrelated address). A credentialed third-party relayer could therefore narrow the
  band while execution stays permissionless and traders supply nothing, so nobody can weaken validation by omission.
  Cost: about 65k gas per feed update, paid by the relayer.
- **Pyth.** Also permissionless to update, but nobody relays it on Unichain (132 days stale).
- **Data Streams.** Would need a store contract.
- **Recommendation.** Push-only remains the operating mode; a relayer is an option (R-5). A fresh source must never be
  mandatory.

## 11. Remaining risks and release blockers

**Release blockers** (all must clear before any deployment):
1. Owner decisions R-1 … R-6 (§12).
2. Independent review of the vault diff, the governor and the hook changes.
3. Testnet rehearsal (needs approval):
   - governance handover;
   - a queued change executed and one cancelled;
   - adapter install and removal with live allocations.
4. A deployment checklist that verifies `vault.owner() == governor` and the hook permission bits.
5. A monitoring plan:
   - feed ages and the sequencer;
   - queued governor changes;
   - inventory against floors;
   - re-centring `tau`.

**Residual risks:**
- Push-only fills are low (≈ 5% in the model).
- `kappa` is real capital at risk under total oracle compromise.
- Common-mode exchange errors reach both providers.
- Shared-core swaps cost about +147k gas.
- Hook parameters still have no timelock (P-6), though they cannot widen the vault's boundary.
- Unpausing or lifting a halt waits 3 days, a liveness cost of the safety rule.
- All economics are SYNTHETIC.

## 12. Decisions requiring approval

- **R-1:** the integrated boundary as implemented, with the vault at 200 runs.
- **R-1b:** where the delay lives:
  - `VaultGovernor` as owner (selected: 0 B in the vault, target met; enforced by deployment configuration);
  - or in the vault (`vault-inline-change-delay.patch`: unconditional, but 1,323 B headroom, missing the target by 725
    B).
- **R-3:** delays of 3 / 32 days and a 7-day window.
- **R-4:** `kappa` for launch (1–2% proposed).
- **R-5:** a credentialed relayer for RedStone, or not.
- **R-6:** hook strategies: Hook A activity fee; Hook B 10 bp markup with a 2% per-trade bound, as tested. Both
  parameter sets still need calibration.

## 13. Validation

Foundry 1.7.1, solc 0.8.26, Slither 0.11.6, Python 3.11.8. All local. Fork reads used the public Unichain RPC,
read-only; nothing was broadcast.

| Command | Result |
|---|---|
| `forge fmt --check` | clean |
| `forge test` | 539 passed, 0 failed, 8 skipped (all 8 are fork tests skipped without `UNICHAIN_RPC_URL`) |
| `bash test/bench/security.sh` (CI profile, 10,000 fuzz runs, forced rebuild, size gate including `VaultGovernor`) | exit 0; vault 22,249 B, margin 2,327 B ≥ 2,048 |
| `FOUNDRY_INVARIANT_FAIL_ON_REVERT=true FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-contract "VaultInvariantsTest\|OracleRiskInvariantsTest$"` | 35 + 3 passed; every invariant 32,768 calls, 0 reverts |
| `UNICHAIN_RPC_URL=https://mainnet.unichain.org forge test --match-path "test/fork/*"` | 8/8 pass, none skipped (oracle reads, TWAP, Pyth age, integrated swaps) |
| same with `--isolate` on `UnichainIntegratedSwap.t.sol` | the gas in §6 |
| `bash test/bench/run.sh` before (worktree at `5de09b1`) and after | §5, §6 |
| mutation (scratch copy; targeted suites) | 26/26 killed (§8) |
| `slither . --filter-paths "lib/\|test/" --exclude-dependencies` | 56 results (45 before). The 11 new ones were all reviewed and none is a defect: 2 are existing hook findings renamed from `beforeSwap` to `_fill`; 5 are governor low-level call, assembly (revert bubbling) and benign reentrancy-event (record deleted before the call; the vault only makes view or `staticcall` calls back out); 3 are intended timestamp comparisons (reading validity, delays); 1 is `version` deliberately zero when the adapter is removed. |
| `python3 -m unittest discover -s simulations/mm` / `simulations/pricing` | 46 / 22 passed |
| `python3 simulations/mm/floor_guarantee.py`, `simulate.py --phase143` | `results/floor_guarantee.md`, `results/phase143_kappa.md` |
| storage layout vs baseline (`forge inspect`) | 25 entries unchanged; slots 24–27 appended |

Not run:
- an Unichain Sepolia rehearsal (needs approval);
- formal verification;
- an independent audit;
- fuzzing of the hooks' shared-core quotes against the Python model across random states. Conformance is by unit
  equality on fixed states (`test_quotesEqualLibraries`), on top of the libraries' existing vectors.
