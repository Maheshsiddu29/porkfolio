# Porkfolio — G01 Verified Financial Baseline

**Status: see §11.** This document records what is known about the financial correctness of the system at the end of
G01, before time-bounded commitments are added to the vault. G01 adds no protocol feature: no file in `src/` changed.

- **Branch:** `phase-2-g01-financial-baseline`, from `phase-1b-4-4-integration-hardening` at `540e99d`.
- **Toolchain:** Foundry 1.7.1 (`4072e48`), solc 0.8.26 (via-IR, cancun, `bytecode_hash = none`), Slither 0.11.6,
  Python 3.11.8, macOS (Darwin 25.2.0).
- **Labels.** PROVEN: a written proof under stated assumptions, plus tests. TESTED: checked by tests that exercise the
  path, with no proof. MEASURED: a number from a recorded command. SYNTHETIC: from generated data, not market data.
- `Porkfolio_Master_Roadmap.md` and `Porkfolio_Task_Tracker.csv` are not in the repository. This baseline is built
  from the Phase 1B-4.4 report and the architecture documents.

## 1. Starting state (verified)

| Check | Result |
|---|---|
| `git status --short --branch` | `phase-1b-4-4-integration-hardening`, clean |
| `git log -1` | `540e99d docs(report): Phase 1B-4.4 report; close two surviving mutants`, matching the report |
| Existing G01 / 1B-4.5 work | none (no branch, commit or document) |
| `forge build --force` | success, 5 min 22 s |
| `forge test` (default profile) | **579 passed, 0 failed, 8 skipped** (the 8 fork tests, no `UNICHAIN_RPC_URL`), 15 s; matches the 1B-4.4 report |
| Deep campaign as in the 1B-4.4 report: `FOUNDRY_INVARIANT_FAIL_ON_REVERT=true FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-contract "^(VaultInvariantsTest\|OracleRiskInvariantsTest\|InventoryProtectionInvariantsTest)$"` | **42 passed**: 37 invariants (30 + 3 + 4), each `runs: 256, calls: 32768, reverts: 0`, and the vault campaign's 5 scripted progress tests; 90 s |
| Python: `python3 -m unittest discover -s simulations/mm` / `-s simulations/pricing` | 46 / 22 passed |

## 2. Invariant depth, reconciled

The brief quotes "1B-4.3: 256 × 32,768 stateful calls" and "1B-4.4: 256 × 128". Neither is what was run, and there
was **no regression**.

- Both reports ran the same configuration: **256 runs × depth 128 = 32,768 handler calls per invariant function**,
  with `fail_on_revert = true` (1B-4.3 report line 248; 1B-4.4 report §10). 256 × 128 has been the deep configuration
  in every report since Phase 1A; `fail_on_revert = true` since 1B-3.
- "32,768" is the product, the `calls` figure forge prints. "256 × 32,768" multiplies it again; "256 × 128" is the
  same campaign written as runs × depth.
- Which suites: 1B-4.3 ran `VaultInvariantsTest` (30 invariants and 5 scripted progress tests, 35 in all) and
  `OracleRiskInvariantsTest` (3). 1B-4.4 ran the same two and `InventoryProtectionInvariantsTest` (4 invariants) for
  the first time. Each invariant function is a separate campaign, so each received 32,768 calls.
- Re-run at `540e99d` (§1): identical figures.
- `OracleRiskHandlerLivenessTest` and `InventoryProtectionLivenessTest` inherit their campaign's invariants, so a
  plain `forge test` runs those two campaigns twice. The `$`-anchored commands above run each once. Left as it is;
  it costs time only.

**What the depth did not show.** The `calls` figure counts handler calls, including calls that returned early or were
refused. §4 measures how many of them did something.

## 3. Test profiles

One compiler configuration for all three (the vault at 200 optimizer runs through `compilation_restrictions`, everything
else at 44,444,444); only the fuzzing effort differs. Seeds are fixed (`0x5eed`), so a result can be reproduced.
`fail_on_revert = true` in every profile (F4, §4.2).

| Suite | Command | Fuzz | Invariants | Also | Wall time (this machine) |
|---|---|---|---|---|---|
| Fast (development) | `forge test` | 1,000 runs | 64 runs × 64 = 4,096 calls each | — | 17.6 s after a build |
| CI | `test/bench/security.sh` (`FOUNDRY_PROFILE=ci`), then `python3 test/invariant/coverage.py`: what `.github/workflows/security.yml` runs | 10,000 | 128 × 128 = 16,384 | forced rebuild, size gate, production-build checks, coverage gate (§4.4) | 6 min 49 s + 1 min 29 s |
| Deep (adversarial / release) | `test/deep.sh` (`FOUNDRY_PROFILE=deep`) | 10,000 | 1,000 × 256 = 256,000 | seeds `0x1 0x2 0x3` at 256 × 128, coverage gate (§4.4), Python, fork tests if `UNICHAIN_RPC_URL` is set, Slither if installed | §5 |

The deep profile meets the length release checklist item I-5 asks for before Gate 2 (≥ 1,000 runs × 256), which no
earlier profile did. CI still has not run on GitHub (checklist D-7: the account was billing-locked); every step was
run locally.

## 4. Campaign audit: did the handlers do anything?

### 4.1 Method

Forge prints `afterInvariant` counters for the **last run only** (verified: with 4 runs, one block of logs). A
32,768-call campaign therefore gave one sample of its activity. To see the distribution, single-run campaigns were run
one per seed (`FOUNDRY_INVARIANT_RUNS=1`, seeds `i·7919 + 13`), and each run's counters were read. A run is a sample
of what one run in a 256-run campaign does, since each run starts again from `setUp`.

To find why operations failed, each refusal's selector was recorded through a throw-away sink contract (scratch copy,
not committed; `VaultHandler` is at the via-IR stack limit, and any new state inside it that handles `bytes` stops it
compiling).

### 4.2 Findings

**F1. The main vault campaign was mostly refusals.** `VaultInvariantsTest`, 100 runs at depth 128, at `540e99d`:

| Operation | Runs where it never succeeded | Median successes per run |
|---|---|---|
| swap (any hook) | **32 / 100** | 1 |
| Hook A / B pricing swap | 51 / 100 | 0 |
| withdrawal queued | **75 / 100** | 0 |
| queued request finalized | **91 / 100** | 0 |
| claim | **91 / 100** | 0 |
| signed activation | 70 / 100 | 0 |
| signed activation with drawn time fields | 99 / 100 | 0 |
| zero-asset state reached | 91 / 100 | 0 |
| deposit / instant redemption | 7 / 0 | 3 / 5 |

At depth 64 (the default profile) it was thinner: no swap in 34, no queued withdrawal in 85, no claim in 98.

Causes, from the 345 swap refusals over the same 100 runs:
- `ImpactBoundExceeded` (Hook B's position cap): 104. `swap` drew up to 150,000, which Hook B refuses.
- `AllocationAlreadyReleased`: 98, and `AllocationExpired`: 14. `swap` picked uniformly among every allocation ever
  made, most of them closed.
- `CuratorRestricted` 43, `PriceBelowFloor` 40, `QuotaExceeded` 33, `DirectionHalted` 12: intended refusals.
- 42 selectors with equal weight left about three swap calls in a 128-call run; withdrawals queue only when an
  allocation reserves most of an asset, which random allocations rarely did.

Consequence: invariants about swaps, queued withdrawals and claims (INV-P1, the ghost ledger, FIFO, no double claim,
the flow and exposure ghosts) were checked after every call, but over states where those operations had rarely or
never happened. The scripted progress tests (`test_handler_*`) prove the paths are **reachable**; they did not show
the random campaign **reached** them.

**F2. The inventory campaign's non-vacuity rule was seed-dependent.** `afterInvariant` failed a run with ≥ 8 trade
attempts and no fill. `INVENTORY_PROTECTION.md` describes it as "8 or more *honest* trade attempts", but the code
counted every attempt. Adding one selector changed the random sequence, and the fuzzer at once found a run that fails
it legitimately: `corruptReference` to a near-zero price (107,250 / 2^96), then eight hook trades, all refused because
the hooks quote at the corrupted price. A legitimate sequence violates the old rule; it passed in 1B-4.4 because seed
`0x5eed` with that selector set did not produce one. (The 1B-4.4 fix `2a94975` had replaced an even blunter rule.)

**F3. No stateful campaign made the price adapter fail.** Both oracle campaigns corrupt the price, but none reverted,
returned malformed data, returned a zero or expired reading or an uncertainty above the bound. Those were covered only
by unit tests (`test_invalidReadings_refused`, `test_lpPaths_independentOfAdapter`).

**F4. `fail_on_revert = false` in the default profile.** A handler call that reverts is dropped silently, which hides
a broken handler. The deep runs in every report used `true`; the default did not.

**F5. Reporting, not a defect.** `INVENTORY_PROTECTION.md` §2 said every observed "shortfall / room" ratio was below
10,000 bps. Over 100 runs it exceeded 10,000 bps in **36** (median 6,760; maximum 1,523,526). Q2 held in all of them:
the check allows the shortfall to exceed the room by up to two raw units, and when an LP's room is a fraction of a raw
unit the ratio is meaningless. The earlier statement was based on one sampled run per invariant. Why two units, and
not one, is measured in §12.2; the corrected text is in `INVENTORY_PROTECTION.md` (`3a2bdb1`).

**Covered as asked, found adequate:**
- both production hooks and multiple curators: `VaultInvariantsTest` (Hook A, Hook B, a 1:1 test hook; three
  curators), `InventoryProtectionInvariantsTest` (both hooks, a malicious consumer, two curators);
- governance and pending withdrawals: `InventoryProtectionInvariantsTest` loosens through `VaultGovernor` with
  LONG_DELAY, including the late-LP ordering, and replaces the adapter through it;
- the malicious consumer hook: both oracle campaigns;
- **malicious reader.** The repository defines no "reader". It was taken to mean a hostile price source (the adapter
  the vault and hooks read), together with the malicious consumer hook already covered: F3 and its correction.

### 4.3 Corrections (test code only)

| Commit | Change | Effect (same seeds) |
|---|---|---|
| `60a309f` | Inventory campaign: `adapterFault` (5 modes: revert, one-word return data, zero price, expired reading, uncertainty one pip over the bound); `invariant_noFillUnderAdapterFault`; `invariant_lpPathsIndependentOfAdapter` (the same LP sequence on two rolled-back copies, adapter healthy and reverting, must give identical results); non-vacuity counts only attempts under an honest reference; regression test for the F2 sequence | a fill was refused under an adapter fault in 89% of runs, and no fill succeeded under one; the LP-path differential runs after every call |
| `ff8046b` | Vault campaign: `swap` uses a live allocation three times in four and sizes three Hook B calls in four to the room under its cap; `queueBehindCommitment`; weights (value-moving actions about a third of calls); `COV` counters; `test/invariant/coverage.py` | below |
| `aa7340a` | Profiles (§3); `fail_on_revert = true` everywhere | — |
| `0d76434` | Under an adapter fault the malicious `drain` attempts the fill anyway (paying twice the true price), so the vault's own reading check is the only barrier | mutants M8b and M16 now also killed by `invariant_noFillUnderAdapterFault` (§5.3); before, only by a unit test |

`VaultInvariantsTest`, 100 runs at depth 128, before → after:

| Runs where it never succeeded | Before | After |
|---|---|---|
| swap | 32 | 17 |
| allocation (direct or signed) | 12 | 0 |
| withdrawal queued | 75 | 21 |
| queued request finalized | 91 | 39 |
| claim | 91 | 50 |
| request cancellation | 86 | 40 |

**Still weak, not fixed:**
- 17% of runs still have no successful swap. The remaining refusals are the campaign's own adversarial states
  (restricted curators, guardian-tightened floors, halts, a saturated Hook B), so this was left; the inventory
  campaign, which fills in 92–100% of runs, carries the trading load.
- Signed activations succeed in about a quarter of runs, and **INV-T1** (signed time rules) is checked on a
  successful timed activation only in the scripted `test_handler_authProgress` (0 of 100 random runs). The property is
  also covered by `ActivationSafety.t.sol` and `test_PA_auth_signatureTimeRules`.
- Zero-asset states: 2–3% of runs.
- `VaultInvariantsTest` runs in static-floor mode with an EOA owner. The adapter, the governor and the shared-core
  hook configuration are exercised by the inventory campaign, not by it.

### 4.4 The coverage gate

`python3 test/invariant/coverage.py` (64 seeds, depth 128, about 90 s) runs a single-run campaign per seed for each of
the three suites, reads the `COV` lines, and fails if an operation never succeeded in more runs than its gate allows,
or if a counter that must stay zero (`looseningsFailedOther`) is not. Since the closeout (§12) it runs in CI after
`security.sh`, and in `test/deep.sh`.

**Reproducibility.** The first version was not: two complete runs differed slightly (190 vs 188 vault swaps). §12.4
traces this to Foundry's storage-derived fuzz dictionary. The script now pins `FOUNDRY_PROFILE=default` and
`include_storage = false` for its own runs, and three complete runs at the final commit gave identical measurements.
Each gate is at least four binomial standard deviations above the worst fraction observed over seed bases 13, 101, 4001
and 65537.

**What it counts.** Every gated counter is a success (a fill, a swap, a deposit, a queued, finalized or claimed
withdrawal, an executed loosening, a checked payout or slice), or a refusal with its expected revert reason
(`refusedAtFloor`: `InventoryFloorBreached`; `looseningsBlocked`: `PendingWithdrawals`). The exception is
`refusedUnderFault`, which counts any refusal while the adapter is faulted: there the property is
`invariant_noFillUnderAdapterFault`, and the counter only shows the fault path is reached. No gate counts attempts.

Result at `9149abc`, default seeds (fraction of runs with zero / gate):

| vault | | oracle | | inventory | |
|---|---|---|---|---|---|
| swapsOk | 0.19 / 0.40 | fills | 0.03 / 0.20 | fillsA | 0.09 / 0.30 |
| pricingSwapsOk | 0.33 / 0.65 | refusedAtFloor | 0.00 / 0.10 | fillsB | 0.03 / 0.30 |
| allocationsOk | 0.02 / 0.20 | | | fillsMal | 0.00 / 0.20 |
| depositsOk | 0.02 / 0.15 | | | refusedAtFloor | 0.05 / 0.25 |
| instantOk | 0.06 / 0.25 | | | loosenings | 0.00 / 0.10 |
| queuedOk | 0.19 / 0.50 | | | looseningsBlocked | 0.05 / 0.35 |
| finalizedOk | 0.42 / 0.80 | | | payoutsChecked | 0.02 / 0.20 |
| claimsOk | 0.45 / 0.85 | | | slicesChecked | 0.17 / 0.40 |
| releasesOk | 0.08 / 0.35 | | | refusedUnderFault | 0.11 / 0.40 |

`looseningsFailedOther`: 0 in every run (must be 0). Totals over the 64 runs (vault): 177 successful swaps, 83 pricing
swaps, 202 allocations, 177 queued withdrawals, 74 finalizations, 45 claims; signed activations 13 (reported, not gated).

**Would it have caught F1?** Against the 100-run measurement of the pre-G01 vault campaign (§4.2), yes, on three gates:
`queuedOk` 0.75 > 0.50, `finalizedOk` 0.91 > 0.80, `claimsOk` 0.91 > 0.85. Not on swaps alone (0.32 < 0.40).

Per-run assertions were considered and rejected for the vault campaign: a legitimate adversarial run can block every
swap, which is how F2 arose.

## 5. Validation at the end of the main G01 work (`0d76434`)

All at `0d76434` unless stated. `src/` is byte-for-byte unchanged since `540e99d` (`git diff 540e99d HEAD -- src
script lib foundry.lock remappings.txt` is empty), so ABI, storage layout and bytecode are unchanged by construction;
the artifact hashes in §6 are the production baseline.

### 5.1 Commands and results

| Command | Result |
|---|---|
| `forge fmt --check` | clean |
| `forge test` (fast) | **584 passed, 0 failed, 8 skipped** (fork tests without an RPC); 19 s. +5 against §1: `invariant_noFillUnderAdapterFault` and `invariant_lpPathsIndependentOfAdapter` in both inventory contracts, and `test_handler_corruptReferenceCanBlockEveryTrade` |
| `bash test/bench/security.sh` (ci; at `ff8046b` with the profile change uncommitted) | exit 0; size gate passed (vault margin 2,136 ≥ 2,048); `ProductionBuilds` 3/3, `ProductionArtifactSecurity` 25/25; complete suite 584 passed, 0 failed, 8 skipped, invariants 128 × 128 = 16,384 calls each; 6 min 39 s |
| `bash test/deep.sh` | **exit 0, 27 min.** Step 2: size gate passed; complete suite 584 passed, 0 failed, 8 skipped; all **48 invariant campaigns `runs: 1000, calls: 256000, reverts: 0`** (30 vault, 3 + 3 oracle, 6 + 6 inventory: the liveness subclasses repeat their campaign); fuzz 10,000 runs. Step 3: seeds `0x1`, `0x2`, `0x3` at 256 × 128: 44/44 each. Step 4: every coverage gate passed (§4.4). Step 5: Python 46 + 22 OK. Step 6: skipped (no `UNICHAIN_RPC_URL` in the script's environment; run separately below). Step 7: Slither, 59 results |
| `UNICHAIN_RPC_URL=https://mainnet.unichain.org UNICHAIN_FORK_BLOCK=63689000 forge test --match-path "test/fork/*" --isolate -vv` | **8/8 passed**, read-only, public RPC, no key. Responses for that block may have come from Foundry's local RPC cache. Swap gas identical to 1B-4.4 (§6) |
| `bash test/bench/run.sh` | exit 0; every production artifact at its expected optimizer setting; §6 |
| `slither . --filter-paths "lib/\|test/\|script/" --exclude-dependencies` | 59 results, the same count as 1B-4.4 with no `src/` change since; not re-triaged |
| `python3 -m unittest discover -s simulations/mm` / `-s simulations/pricing` | 46 / 22 OK |
| Vector generators (`simulations/pricing/vectors.py`, `simulations/mm/vectors.py`, `vectors_core.py`, `vectors_csv.py`, `vectors_risk.py`) | regenerated; `git status` shows no change to any committed vector |
| `python3 simulations/mm/floor_guarantee.py` | identical to `results/floor_guarantee.md` except its elapsed-time line (3.2 s vs 3.3 s) |

**Seeds.** Fuzz and invariants: `0x5eed` in every profile; deep extra seeds `0x1 0x2 0x3`; coverage gate seeds
`i·7919 + 13` for `i = 1 … 64` (`0x1efc … 0x7bbcd`). Skipped tests: only the 8 fork tests, when no RPC is set.

### 5.2 Test counts by directory

`test/security` 278 test functions, `integration` 75, `bench` 58, `invariant` 47 (39 invariant functions with the
liveness duplicates counted once each, plus scripted tests), `unit` 30, `governance` 22, `gas` 20, `pricing` 15,
`oracle` 13, `fork` 8, `research` 7, `risk` 6, `script` 4 (function declarations, `grep`; forge's count of 592 includes
inherited invariants run twice).

### 5.3 Mutation testing

Targeted, in place with restore (scratch script, not committed). M1–M15 ran with the test code of `aa7340a`, M8b and
M16 with that of `0d76434` (and once before it, see the table). Each mutant was applied to `src/`, the full fast suite
run with fuzz and invariant failure persistence redirected to a scratch directory (so a mutant's counterexample is not
replayed later), the original restored; `git diff src` empty afterwards. About 5.6 min per mutant, mostly
recompilation.

**Result: 17 mutants, all killed; 16 by a semantic failure, M8 only by an overflow artifact (replaced by M8b).**

| # | Guarantee | Mutation | Killed by (selection) |
|---|---|---|---|
| M1 | LP shares | deposit price rounds down | `invariant_noDilutionByLpOperations`, `_lensPreviewsMatchExecution`, T1/Q1 invariants, `test_depositAfterTrades_doesNotDiluteExistingHolders` |
| M2 | LP shares | redemption rounds up | dilution and lens invariants, queue tests, `test_rounding_exactT2FailsBySubUnit` |
| M3 | withdrawals | claim leaves `claimable0` set (double claim) | `invariant_noDoubleClaim`, `_sharesAndQueueConserved`, 17 unit tests |
| M4 | withdrawals | pending demand rounds down | `invariant_equationsFromRawSources`, queue tests |
| M5 | price floor | one unit of input short accepted | 8 exact-boundary unit tests (no random swap lands exactly on the floor) |
| M6 | shared ERC-6909 backing | input credited one unit short | backing, ghost-ledger, custody and balance-movement invariants; 73 tests |
| M7 | inventory floor | one unit below the floor accepted | T1 and Q1 invariants, liveness and unit tests |
| M8 | oracle validation | `validUntil + 1 < now` | **weak kill**: the `+ 1` overflows at `validUntil = type(uint256).max`, so only `setUp` panics; replaced by M8b |
| M8b | oracle validation | a reading one second past `validUntil` accepted | `test_invalidReadings_refused`; after `0d76434` also `invariant_noFillUnderAdapterFault` (before it, the unit test alone) |
| M16 | oracle validation | zero price accepted | `test_invalidReadings_refused`, `test_setRiskAdapter_validation`; after `0d76434` also `invariant_noFillUnderAdapterFault` |
| M9 | curator authorization | a frozen curator's allocation can be consumed | `invariant_noConsumptionWhenFrozenOrRevoked`, lifecycle tests |
| M10 | aggregate exposure | new amount ignored in the cap check | `invariant_exposureAndHookReserved`, `ExposureCaps` |
| M11 | per-hook exposure | hook-scope check removed | `ExposureCaps`, `FlowLimits`, module tests |
| M12 | per-hook flow | hook-scope flow not consumed | `invariant_flowUsageMatchesGhost`, `_flowHierarchyConsistent`, 15 `FlowLimits` tests |
| M13 | guardian | every setter allowed to the guardian | `invariant_guardianOnlyTightens`, `_noConsumptionWhenFrozenOrRevoked`, `_exposureAndHookReserved`, 16 role tests |
| M14 | governor | LONG_DELAY executes with withdrawals pending | `invariant_Q2_queuedRequestsKeepTheirProtection`, `test_queuedLp_lateInNotice_blocksLooseningUntilFinalized`, `test_ownershipEscape_waitsLongDelayAndQueue`, inventory liveness |
| M15 | oracle independence of LP exits | `processQueue` reads the adapter | `invariant_lpPathsIndependentOfAdapter` (new), `test_lpPaths_independentOfAdapter`, inventory liveness |

Not mutated in G01: hook pricing, the authorization module's signature path, `VaultLens`, the adapter. Earlier phases'
mutation runs covered parts of them (1B-4.4: 21 mutants on the governor, the adapter's fresh tier, the vault's shared-core
view and the hook edge, all killed; 1B-2.x: module and lifecycle mutants, see those reports). No mutation tool (Gambit, Vertigo) is installed; the set is hand-picked, so it
measures the tests against chosen faults, not a mutation score.

## 6. Gas and runtime-bytecode baseline

`bash test/bench/run.sh` at `0d76434` (local, production artifacts, `--isolate`); identical source to `540e99d`.
Development measurements for comparing builds, not mainnet fee predictions.

**Runtime and init code (bytes), EIP-170 margin:**

| Contract | Optimizer runs | Runtime | Init | Margin | Init-code keccak256 (no constructor args) |
|---|---|---|---|---|---|
| `SharedCommitmentVault` | 200 | 22,440 | 23,077 | **2,136** (target 2,048: 88 B spare) | `0x66f57553…dc6920aa` |
| `HookA_DynamicFee` | 44,444,444 | 14,341 | 15,213 | 10,235 | `0x3e1bae76…a9245d0689` |
| `HookB_BoundedImpact` | 44,444,444 | 14,601 | 15,480 | 9,975 | `0x9b7802f3…645814045` |
| `VaultLens` | 44,444,444 | 8,902 | 8,928 | 15,674 | `0xccc51bcc…c31cec1c6` |
| `CuratorAuthorization` | 44,444,444 | 7,409 | 8,587 | 17,167 | `0xd63ccb2f…1b885fee7` |
| `VaultGovernor` | 44,444,444 | 4,111 | 4,567 | 20,465 | (size gate only) |

Full hashes are in the `run.sh` output; re-running it reproduces them.

**Gas, local (`gasleft()` around one external call, cold storage):**

| Operation | Gas |
|---|---|
| swap Hook A (router + PoolManager + hook + vault), static mode | 270,181 |
| swap Hook B, static mode | 252,313 |
| swap without a hook (router + PoolManager), for reference | 150,303 |
| deposit (new LP) / initial deposit | 149,964 / 238,085 |
| redeem instant / queued | 160,833 / 148,225 |
| `processQueue(1)` / `claim` | 122,337 / 135,954 |
| allocate (steady state, new curator, direct) / signed EOA / signed ERC-1271 | 294,576 / 314,631 / 318,043 |
| `cancelAllocation` / `release` (owner) | 44,209 / 47,618 |
| deploy vault (CREATE) | 5,027,680 |

**Gas, Unichain fork at block 63,689,000 (production builds, shared core with the adapter reading live feeds):**

| Swap | Gas |
|---|---|
| Hook B, 1,000 USDC → WETH / 0.5 WETH → USDC | 408,181 / 403,192 |
| Hook A, 1,000 USDC → WETH / 0.5 WETH → USDC | 435,146 / 430,238 |
| Hook A, static mode | 296,898 |
| `adapter.currentReference` (feeds cold / warm) | 95,819 / 98,379 |

All equal the 1B-4.4 figures.

## 7. Financial guarantees

Each row names the property, its status, the assumptions, and the evidence. "Stateful" means the property is an
invariant or a handler check in a campaign of §4; "unit" means deterministic or fuzz tests.

### 7.1 Proven under stated assumptions

| Property | Assumptions | Evidence |
|---|---|---|
| **T1 / Q1, per-share inventory floor.** For each asset, `N_a/S` never falls below `min(previous, tau_a(1 − kappa_a))` between loosenings, whatever the reference price, hook or curator does | `tau_a` configured; no governed loosening in the interval; the PoolManager settles ERC-6909 transfers exactly | Proof `INVENTORY_FLOOR_GUARANTEE.md` §2; stateful in both oracle campaigns; Python model (40,526 payouts); mutant M7 |
| **T2 / Q2, LP shortfall against its own entry basket.** Per asset, a payout is short of the LP's entry basket by at most its room `s(h_entry − l)^+` plus one raw unit; queued requests keep the room they had when queued | T1's assumptions; for queued LPs, the governor's queue check (`VaultGovernor` reverts LONG_DELAY calls while `pendingShares != 0`) | Proof as above; stateful (instant payouts and finalization slices); `InventoryProtectionBounds.t.sol` |
| **Directional floors never cross:** `F0 · F1 ≥ 2^192` at every reference, so no round trip at the floors is profitable | — | `VaultRiskBoundary.dynamicFloor` derivation (`ORACLE_RISK_BOUNDARY_SPEC.md`); `invariant_directionalFloorsConsistent`; unit |

These are proofs written by the developers and checked by tests. None is a formal (machine-checked) proof, and none has
been reviewed independently.

### 7.2 Tested, not proven

| Property | How it is tested |
|---|---|
| **Shared ERC-6909 backing.** The vault's real claim balance equals `B_a` plus donations; donations are never counted; hooks retain no claims; no operator rights over the vault | `invariant_backingEqualsRealClaims`, `invariant_custodyAndSolvency`, ghost ledger built from measured deltas (`invariant_ghostLedgerConservation`), every successful action checked against real ERC-20 and ERC-6909 movements; inventory and oracle campaigns check the same equations; mutant M6 |
| **LP share and withdrawal accounting.** `S = Σ shares + P`; `P = Σ pending`; `W = Σ claimable`; deposits round up, redemptions down, so no LP operation lowers `N_a/S` for remaining shares; strict FIFO; no double claim; lens previews equal execution | `invariant_sharesAndQueueConserved`, `_noDilutionByLpOperations`, `_fifoOrdering`, `_noDoubleClaim`, `_lensPreviewsMatchExecution`, `_equationsFromRawSources`; `ShareSecurity`, `QueueGriefing`, `ZeroAssetStates`; mutants M1–M4 |
| **Price floor per fill.** Every successful swap paid at least `max(vault floor, curator floor, dynamic floor)` on measured claim deltas | `invariant_everyExchangeMeetsEffectiveFloor` (512-bit, independent of FullMath); `PricePolicy`, `OracleRiskBoundary`; mutant M5 |
| **Oracle risk validation.** A zero price, an expired reading, an uncertainty above `maxUncertaintyPips`, a reverting adapter or malformed return data refuses every fill; LP paths never read the adapter | unit `test_invalidReadings_refused`, `test_lpPaths_independentOfAdapter`; stateful `invariant_noFillUnderAdapterFault`, `invariant_lpPathsIndependentOfAdapter` (new in G01); mutants M8b, M15, M16 |
| **Curator authorization.** Only registered, unrestricted curators allocate; frozen or revoked curators' allocations cannot be consumed; revocation is terminal; generations never decrease; nonces are single-use across direct and signed paths; signed instructions obey the time rules; only the installed module creates allocations | INV-C1…C6, INV-T1, INV-M2, M8, M9 (stateful), `CuratorAuthorization`, `CuratorLifecycle`, `ActivationSafety`, `ModuleInstallation`, `AuthModuleLifecycle`; mutant M9 |
| **Aggregate and per-hook exposure limits.** Each allocation keeps hook, curator and vault reserved amounts within `bps · E_a`; `hookReserved` sums to `Q_a`; flow usage per window per hook, curator and vault never exceeds its cap and sums consistently | INV-E1, INV-F1, INV-F2; `ExposureCaps`, `FlowLimits`; mutants M10–M12 |
| **Governor and guardian restrictions.** Every owner call to the vault and its hooks waits DELAY or LONG_DELAY and is cancellable; LONG_DELAY calls revert while withdrawals are pending; the guardian can only tighten, never registers, unfreezes, loosens or installs a module | `VaultGovernor.t.sol` (G1–G19), `invariant_guardianOnlyTightens`, `_noConsumptionWhenFrozenOrRevoked`, `_moduleLifecycle`, inventory campaign's governed loosening; mutants M13, M14 |
| **Real PoolManager settlement.** Every swap test settles through the pinned v4 `PoolManager` (production build, artifact-checked), with the vault paying and receiving ERC-6909 claims | all integration, security and invariant suites; `ProductionBuilds.t.sol`; Unichain fork swaps at block 63,689,000, 8/8, re-run in G01 (§5.1). Not mutated: the PoolManager is upstream code |

### 7.3 Known counterexamples (each reproduced by a deterministic test)

From `INVENTORY_PROTECTION.md` §4 and `test/security/InventoryProtectionBounds.t.sol`, all passing at the final commit:

| What is **not** bounded | Counterexample | Test |
|---|---|---|
| Loss as a fraction of value is not bounded by `kappa` | 8.65% of value lost at `kappa = 5%` once gains lift holdings above `tau` (Q1 and Q2 hold) | `test_Q1_holds_butLossFractionExceedsKappa_whenGainsLiftHoldings` |
| Cumulative realized loss (Q3) | 1.5 × `kappa · V0` with refills and new capital | `test_Q3_cumulativeRealizedLoss_exceedsKappaOfStartingValue` |
| Mark-to-market loss (Q4) | −49.5% after a depeg while Q1 and Q2 hold | `test_Q4_depeg_markToMarketBeyondKappa_whileQ1Q2Hold` |
| Exact T2 without the allowance | fails by under one raw unit (`floor(2.85) = 2`) | `test_rounding_exactT2FailsBySubUnit` |
| A corrupted reference can block every honest trade | eight trades refused after one `corruptReference` (liveness, not loss) | `test_handler_corruptReferenceCanBlockEveryTrade` (G01) |

No violation of a property in §7.1 or §7.2 was found in G01.

## 8. Outstanding financial risks

- **A compromised or wrong adapter costs up to the room above the floor**, about 2–3 κ per LP in the exact-integer
  worst case (`CALIBRATION_1B44.md`); κ is not chosen (R-4).
- **Q3 and Q4 are unbounded by design** (§7.3). LPs carry market risk and realized trading loss.
- **Re-centring is manual.** Without the guardian raising `tau`, gains above `tau` are unprotected room (8.65% case).
- **`freshDeviation`** in the adapter's fresh tier assumes how far the market moves within `freshMaxAge`; it is an
  assumption, not a check (`ORACLE_RELAYER.md`).
- **Governor limits G15–G19** (`GOVERNANCE_SECURITY.md`): duplicate ids through trailing calldata, a queued address
  binds no code, a compromised guardian imposes liveness costs, no immediate tightening without a guardian, no admin
  rotation.
- **Queue-check griefing**: a loosening can be delayed while shares are pending, up to `MAX_HORIZON` absent griefing.
- **Flow windows** allow up to 2 × cap across a window boundary (checklist H-3).
- **All calibration is synthetic**; push-only fill is about 4–5% (`CALIBRATION_1B44.md`).
- **Campaign blind spots** (§4.3): random signed activations rarely succeed; the vault campaign does not combine the
  adapter or the governor with its curator and module actions.
- **Vault bytecode headroom**: 2,136 B under EIP-170, 88 B above the 2,048 B target. Time-bounded commitments must fit
  in it or move code out of the vault.
- **No independent review, no formal verification.**

## 9. Deployment blockers

Nothing in this document authorizes any deployment.

| Blocker | Source |
|---|---|
| Owner decisions R-1 … R-8 (delays, κ, relayer, hook fees, `coreInputs`, Sepolia broadcast) | `PHASE1B4_4_REPORT.md` §13 |
| Independent security review; findings fixed or accepted in writing | `MAINNET_READINESS.md` Gate 3 |
| An observed Unichain Sepolia period; the rehearsal is unbroadcast and needs written approval | `script/README.md`; R-8 |
| CI has never executed on GitHub (D-7) | `MAINNET_READINESS.md` |
| PoolManager address and bytecode confirmed against Uniswap's published deployment (D-4); opcode support on Unichain (D-3) | `MAINNET_READINESS.md` |
| Deployed bytecode compared with an independently reproduced build (X-2) | `MAINNET_READINESS.md` |
| Issuance-time bound for signed instructions (S-6) | `MAINNET_READINESS.md` |

## 10. Not run, and limits of this baseline

- **No formal verification, no independent audit, no Certora or Halmos run.** §7.1's proofs are hand proofs.
- **Mutation testing is hand-picked** (17 mutants) and covers the vault, the risk library and the governor, not the
  hooks, module, lens or adapter in this phase.
- **The coverage gate measures with `include_storage = false`** (§4.4). The CI and deep campaigns fuzz with Foundry's
  default, which also samples storage values; the gate measures a close variant of them, not the exact runs.
- **Vault campaign blind spots** (§4.3): random signed activations rarely succeed; INV-T1 rests on scripted and unit
  tests; zero-asset states in 2% of runs; static mode only.
- **The LP-path differential** compares a healthy adapter with a *reverting* one. Gas-burning adapters were not run in
  a campaign: the invariant harness gives calls an effectively unlimited gas limit, so a burning adapter would hang the
  run. A view call cannot change state, and LP paths make no adapter call (the differential and M15 show that), but
  this was not measured under a gas limit.
- **Fork tests** ran once, against one historical block, possibly from Foundry's RPC cache. No Unichain Sepolia
  rehearsal (needs approval, R-8).
- **Slither** findings were counted, not re-triaged (same count as 1B-4.4, no `src/` change).
- **CI has still never run on GitHub** (D-7). Every CI step was run locally.
- Mutant runs persisted their failing sequences in scratch directories. Forge's own `cache/invariant` is deleted by
  every `forge build --force` (`security.sh`, `run.sh`, so also `deep.sh`), and with it any persisted counterexample.
  None exists at the final commit. A counterexample worth keeping must be turned into a test, as F2's was.

## 11. G01 result

**G01: PASS (local).**

- The starting state matched the 1B-4.4 report (§1). The invariant-depth discrepancy was a misreading of the same
  256 × 128 configuration; no regression (§2).
- The campaigns were audited. Three weaknesses were found and corrected in test code (F1, F2, F3), one in
  configuration (F4). One statement in `INVENTORY_PROTECTION.md` was contradicted by the measurements (F5); it was
  corrected at closeout (§12). Residual blind spots are listed (§4.3, §10).
- Every documented financial guarantee is preserved: `src/` is unchanged, every test passes in the fast, CI and deep
  suites, and every guarantee in §7.2 except PoolManager settlement (upstream code, not mutated) is backed by at least one
  killed mutant.
- Three test profiles exist and were run (§3, §5).
- This is a local baseline. It authorizes no deployment (§9).

**Closeout (§12): ready for owner integration.** Next per the roadmap: G02. The master roadmap and tracker are not in the repository, so G02's scope could not be
read from them; it is understood from the brief to be the start of time-bounded commitments in the vault. Not started.

## 12. Closeout (owner checklist before integration)

Five commits after `c132643`: `3a2bdb1`, `ffc814c`, `3e32c21`, `9149abc` and this document's update. No
`src/` change: `git diff 540e99d HEAD -- src` is still empty and the init-code hashes in §6 were reproduced exactly.

### 12.1 `AGENTS.md` (untracked, not touched)

- Created 2026-11-12 01:22 local time, during the `test/deep.sh` run of §5; 6,073 bytes. No command run in this work
  writes a file of that name; they write only `out/`, `cache/`, a scratch directory outside the repository and the
  committed files.
- Content: the project's `CLAUDE.md` with two words changed: the title reads "Project-wide instructions for Codex",
  and one rule says "Mention Codex" instead of "Mention Claude". Everything else is identical (`diff` against
  `CLAUDE.md`).
- Likely origin: a copy of `CLAUDE.md` made for OpenAI Codex, which reads `AGENTS.md`, by the owner or by a Codex tool
  outside this session. It carries a macOS `com.apple.provenance` attribute, which macOS adds to files written by
  certain applications; `CLAUDE.md` does not have it. Left untracked, unmodified and uncommitted; the owner decides.

### 12.2 `INVENTORY_PROTECTION.md` ratio claim (`3a2bdb1`)

The incorrect "all below 10,000 bps" statement is replaced with the 100-run measurement (§4.2 F5) and an explanation of
the tolerance. Measurement with the campaign's tolerance changed in a scratch copy (256 runs × depth 256, seeds `0x5eed`,
`0x1`, `0x2`, `0x3`, inventory campaign):

| Tolerance per asset | `invariant_Q2_entryBasketShortfall` (instant payouts) | `invariant_Q2_queuedRequestsKeepTheirProtection` |
|---|---|---|
| 2 raw units (committed) | pass | pass |
| 1 raw unit | pass on all 4 seeds | **fail on all 4 seeds** |
| 0 | fail | fail |

Each vault payout rounds down by less than one raw unit per asset: that is Q2's allowance, and the §4.4 counterexample
of `INVENTORY_PROTECTION.md` (`floor(2.85) = 2`, `test_rounding_exactT2FailsBySubUnit`) is unchanged. The second unit
comes from how the campaign checks queued requests: `_checkSlices` tracks the requests pending when a handler call
starts. In the late-LP branch of `governedLoosen` a request is queued and first finalized inside one call, before it is
tracked, so its next finalization is checked together with the first: two vault payouts in one comparison. The
shrunk counterexample at one unit (seed `0x1`) ends with two `governedLoosen(…, true)` calls and a `processQueue`. The
test comment that attributed the unit to "the floor in b's pro-rata split" (that floor rounds in the LP's favour) was
corrected in the same commit.

### 12.3 200-run vault build (`ffc814c`)

`MAINNET_READINESS.md` D-2 now states 200 runs, why (2,000 is over EIP-170 with the risk boundary, since 1B-4.3), and
the two places that enforce it: `ProductionArtifacts.VAULT_RUNS = 200` (artifact checks in tests and
`VerifyDeployment`) and `script/README.md`'s pre-broadcast check. `README.md` (Phase 1B-2 step 1 section) and
`MODULAR_RISK_ENGINE.md` D19 now say when the setting changed. `foundry.toml`, `test/bench/run.sh`, `security.sh` and
the deploy scripts already used 200 (`run.sh` at `9149abc`: vault artifact `runs=200 … ok`). Phase reports were left
as history.

### 12.4 Coverage gate in CI (`3e32c21`, `9149abc`)

- **Non-determinism found and removed.** Two complete runs of the earlier gate differed by a few counts. Repeating a
  differing seed with the call sequence dumped (a scratch edit forcing `afterInvariant` to fail, failure persistence
  redirected so no run replayed another) showed the same selectors with a few different argument values, for example
  `36893488147419103233` (2^65 + 1) in one run and another value in the next: values Foundry 1.7.1 collects from
  contract storage are sampled in an order that varies between identical runs. Our handlers and the vault have no
  randomness of their own. With `include_storage = false` four previously unstable seeds were identical over five
  repeats each; `dictionary_weight = 0` also fixes it but removes the whole dictionary, so it was not chosen.
- **Reproducibility at the final commit:** three complete runs (one with `FOUNDRY_PROFILE=ci` in the caller's
  environment) gave identical measurements.
- **False failures:** seed bases 13, 101, 4001, 65537 (256 single-run campaigns per suite): every gate passed on
  every base. Gates were then set to at least four standard deviations above the worst base (seven widened).
- **Meaningful operations:** §4.4. The two refusal counters now require their revert reason (`3e32c21`); over 64 runs
  the oracle `refusedAtFloor` fell from 505 to 502, i.e. three refusals had another reason and are no longer counted.
  `looseningsFailedOther` is 0 in every run and is enforced.
- **CI:** `.github/workflows/security.yml` runs `python3 test/invariant/coverage.py` after `security.sh`, reusing its
  build (a profile switch does not recompile: `No files changed, compilation skipped`). The fast profile is unchanged.
  CI has still never executed on GitHub (D-7); the steps were run locally, below.

### 12.5 Final validation at `9149abc`

Run in sequence from a clean tree (only `AGENTS.md` untracked):

| Command | Result |
|---|---|
| `forge fmt --check` | clean |
| `bash test/bench/run.sh` (forced rebuild) | exit 0, 5 min 29 s; every production artifact at its expected runs; init-code hashes identical to §6 |
| `bash test/bench/security.sh` (ci; forced rebuild = final clean compilation) | exit 0, 6 min 49 s; size gate passed (vault 22,440 B, margin 2,136); complete suite **584 passed, 0 failed, 8 skipped** (fork, no RPC) |
| `python3 test/invariant/coverage.py` | exit 0, 1 min 29 s; every gate passed; measurements identical to two earlier runs |
| `bash test/deep.sh` | exit 0, 28 min. Complete suite 584 passed, 0 failed, 8 skipped; all **48 campaigns `runs: 1000, calls: 256000, reverts: 0`**; seeds `0x1`, `0x2`, `0x3`: 44/44 each; coverage gate passed; Python 46 + 22 OK; Slither 59 results (unchanged); fork step skipped (no RPC in its environment) |
| `UNICHAIN_RPC_URL=https://mainnet.unichain.org UNICHAIN_FORK_BLOCK=63689000 forge test --match-path "test/fork/*" --isolate -vv` | 8/8 passed; swap gas identical to §6 |
| Targeted, during the closeout | `forge test --match-contract "InventoryProtection\|OracleRisk"`: 40 passed |

Scratch artifacts of the experiments (three persisted failure files in `cache/invariant/failures`) were deleted before
this validation; the forced rebuilds also clear `cache/`.

### 12.6 Readiness

**G01 is ready for owner integration**, subject to the owner's review of the ten local G01 commits
(`60a309f` … this one) and a decision on `AGENTS.md`. Nothing was pushed, merged or deployed. G02 has not started.

