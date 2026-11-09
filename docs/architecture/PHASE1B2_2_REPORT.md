# Porkfolio — Phase 1B-2.2 Report: Hierarchical Flow Limits and Exposure Caps

**Status: DONE, waiting for review.** Branch `phase-1b-2-2-flow-limits`, created from `phase-1b-2-1-curator-lifecycle`
at `8ec08ca`. This step adds risk limits to the vault: gross-outflow caps per hook, per curator and vault-wide, and
exposure caps against eligible backing. It does not change the trust boundary: no signatures, nonce bitmaps,
`reserveFor`, authorization module, cumulative pricing or ring buffers. Decisions D18 (fail closed) and D21 (exposure
cap) were approved before the step. Labels: SOURCE (read from the code), OBSERVED (measured or asserted by a test; the
command is given), ESTIMATE.

| Commit | Content |
|---|---|
| `eaf44d8` | `test`: the functional fixture deploys the production PoolManager, hooks and lens; masked runtime-hash check |
| `7e96529` | `feat(vault)`: `RiskLimit` records, three flow checks in `exchange`, three exposure checks in `allocate`, `hookReserved`, `setRiskLimit`; lens helpers; `FlowLimits.t.sol`, `ExposureCaps.t.sol` |
| `5a8c688` | `test(invariant)`: risk actions, ghost flow model, INV-F1, F2, E1 |
| `ef29ff9` | `test(bench)`: flow and exposure scenarios on production artifacts; window gas; `security.sh` |
| `c299e5c` | `test`: queued demand binds the vault's own exposure check (closes mutant F15, §5.3) |
| this commit | this report; `MODULAR_RISK_ENGINE.md`, `MAINNET_READINESS.md`, `PHASE1B2_IMPLEMENTATION_PLAN.md`, `README.md` |

## 1. Final hierarchical risk-limit model

One record per **(scope, account, asset sold)** (SOURCE, `ISharedCommitmentVault.sol`):

```solidity
enum RiskScope { Hook, Curator, Vault }        // account = hook, curator, or address(0)
struct RiskLimit {
    bool    configured;      // slot 0
    uint40  epoch;           // slot 0: window the usage belongs to
    uint104 flowCap;         // slot 0: max gross output per window
    uint104 flowUsed;        // slot 0: gross output paid in window `epoch`
    uint16  maxReservedBps;  // slot 1: exposure cap, bps of eligible backing
}
mapping(bytes32 => RiskLimit) _riskLimits;     // key = keccak256(abi.encode(scope, account, currency))
```

| Level | Limit | Where enforced | Keyed by |
|---|---|---|---|
| L1 allocation | `maxOut`, expiry, floor (unchanged) | `allocate`, `exchange` | allocation |
| L2 hook flow | gross output per window, across all the hook's pools, allocations and curators | `exchange` | hook address |
| L3 curator flow | gross output per window, across all the curator's allocations and hooks | `exchange` | curator address |
| L3' curator ceiling | outstanding `curatorReserved` (unchanged, absolute) | `allocate` | curator address |
| L4 vault flow | gross output per window, across everything | `exchange` | `address(0)` |
| L5 exposure | unused reserved capacity of the hook, the curator and the vault, as bps of `E_a` | `allocate` | each scope |
| L6 LP obligations | admission keeps `R_a` and `D_a` out; flow and exposure limits never read on LP paths | `allocate`; LP paths untouched | — |

**Fail closed (D18).** `configured` is explicit. An unconfigured record reverts `RiskLimitNotConfigured` in
`allocate` (exposure check, all three scopes) and in `exchange` (flow check, all three scopes). A configured cap of 0
allows nothing. Configuration is one-way: a record can be closed (zeros) but not unconfigured.

**Roles.** `setRiskLimit(scope, account, currency, flowCap, maxReservedBps)`:

- Owner: any values within range (`flowCap ≤ 2^104 − 1`, `bps ≤ 10,000`, account matches scope, currency in the
  pair); marks the record configured.
- Guardian: only on a configured record, and only if **neither** value rises. Configuring a new record is refused
  (`GuardianCannotIncreaseRisk`).
- Nobody else, including hooks and curators (`NotOwner`).

**What administrative changes do to recorded usage** (SOURCE, tested in `FlowLimits.t.sol`):

| Change | `flowUsed` / `epoch` | Effect |
|---|---|---|
| Owner raises a cap | unchanged | the difference is available in this window |
| Owner or guardian lowers a cap below current usage | unchanged | no more output this window; next window starts at 0 under the new cap |
| Exposure bps lowered below what is held | n/a | existing allocations stay reserved and consumable; new ones refused |
| Freeze, unfreeze, deregister, re-register, `bumpGeneration`, revoke | unchanged (records keyed by address, not generation) | freeze and revoke stop execution; unfreeze resumes with the window's remainder only |
| `setConsumer(h, false)` then `true` | unchanged | — |
| Owner or guardian replaced | unchanged | the new guardian is bound by the same tighten-only rule |
| Pause | unchanged | `exchange` reverts before any record is read |
| Cancellation, emergency release, expiry release, revoked cleanup | unchanged | unused capacity returns to `Q_a`, `curatorReserved`, `hookReserved`; paid output stays counted |
| Deposit, redeem, processQueue, cancelRequest, claim | unchanged | limits are never read |

## 2. Accounting equations and window semantics

**Window.** `FLOW_WINDOW = 86,400 s`. `epoch(t) = floor(t / FLOW_WINDOW)` on the full 256-bit timestamp. Window `e`
covers `[e·W, (e+1)·W − 1]`, both ends inclusive; a trade at exactly `(e+1)·W` is in window `e+1`. The epoch is
stored in 40 bits; when `epoch(t) > 2^40 − 1` (about year 3 billion) every flow-limited `exchange` reverts
`FlowEpochOutOfRange` rather than wrapping.

**Per `exchange` of `amountOut`** (the exact claim amount transferred), for each of the three records `r` of
`currencyOut` (the calling hook, the allocation's curator, the vault), before any other effect:

```
require r.configured                                    else RiskLimitNotConfigured
used  = (r.epoch == epoch(now)) ? r.flowUsed : 0         // any earlier window, however old, counts as 0: O(1)
require used + amountOut <= r.flowCap                   else FlowLimitExceeded(scope, account, currency,
                                                                                  amountOut, max(0, cap − used))
r.epoch = epoch(now);  r.flowUsed = used + amountOut     // ≤ cap < 2^104, exact narrowing
```

`used + amountOut` is computed in 256 bits (`used < 2^104`, `amountOut < 2^127`): no overflow. Nothing else writes
`flowUsed`. Inflows are never subtracted, so a trade in the opposite direction cannot free capacity.

**Hierarchy identity** (OBSERVED, `invariant_flowHierarchyConsistent`): every successful `exchange` adds the same
amount to one hook record, one curator record and the vault record, so in the current window, per asset,

```
Σ_hooks used_h  =  Σ_curators used_c  =  used_vault
```

**Bounds a fixed epoch gives** (no rolling-window guarantee is claimed):

- within one window, per scope: total output ≤ the cap in force at each trade (≤ max cap during the window);
- around a boundary: up to `2 × cap` within two seconds (last second of `e`, first second of `e+1`), demonstrated by
  `test_FL_windowBoundary_bothSides`;
- over any interval of `T` seconds: ≤ `(ceil(T / W) + 1) × cap`.

**Reserved capacity.** `hookReserved[h][a]` is maintained exactly like `curatorReserved`: `+maxOut` in `allocate`,
`−amountOut` in `exchange`, `−(maxOut − consumed)` in `_close`. Per asset, `Σ_h hookReserved = Σ_c curatorReserved =
Q_a` (OBSERVED, `invariant_exposureAndHookReserved`, `invariant_reservedIsExactAndBacked`).

**The four quantities the task asked to keep apart**, per asset:

| Quantity | Symbol / storage | Raised by | Lowered by |
|---|---|---|---|
| Outstanding reservation | `Q_a`, `curatorReserved`, `hookReserved` | `allocate` | `exchange` (by output), `_close` (by remainder) |
| Gross executed outflow | `RiskLimit.flowUsed` (current window) | `exchange` only | only the start of a new window |
| Available inventory | `F_a = N_a − Q_a`; admission capacity `N_a − Q_a − R_a − D_a` | deposits, inputs received, closes | payouts, outputs, new allocations |
| LP withdrawal liabilities | `W_a` (finalized), `D_a = ceil(P·N_a/S)` (queued) | queue finalization, new queue entries | claims, finalization, cancellation |

## 3. Exposure cap: definition and rounding

**Definition.** A percentage of eligible backing, per hook, per curator and vault-wide, per asset. The absolute
per-curator ceiling (`curatorCeiling`) stays as it was, so a curator is bounded by both.

```
E_a = N_a − D_a = B_a − W_a − ceil(P · N_a / S)        // LP liabilities W_a and D_a are never counted as backing
accept allocate(maxOut)  iff  for each scope s ∈ {hook, curator, vault}:
        (held_s + maxOut) · 10,000  ≤  bps_s · E_a       // held_s = hookReserved, curatorReserved, Q_a
```

- **Exact integer check, no division.** Both sides are below `2^142`. It equals `held + maxOut ≤ floor(bps · E / 10,000)`:
  the cap rounds **down**, against the curator and in favour of LPs. `D_a` is rounded up, which lowers `E_a` further.
  Example (`test_EX_roundsDown`): `E = 1,000,000 ether + 7`, 25% → limit `250,000 ether + 1` (exact value
  `… + 1.75`).
- **Checked only at creation.** Backing that later falls (redemptions, queued exits, trading) can leave existing
  allocations above the cap; they are not cancelled and stay consumable, bounded by their own `maxOut`, the floors and
  the flow caps. Tightening a cap does the same. The guardian's freeze, revoke, pause, halt and emergency release remain
  the tools for stopping existing execution authority.
- **No valuation.** Every quantity is in raw units of one asset; nothing adds the two assets together.
- **Not a value guarantee.** Exposure caps and flow caps bound *how much* and *how fast* the reserve can be sold. They
  say nothing about the price received: a registered hook can still sell its whole allowance at exactly the floor.

## 4. Adversarial bypass attempts and results

All on the real pinned PoolManager. `FL` = `test/security/FlowLimits.t.sol`, `EX` = `ExposureCaps.t.sol`, `PA` =
`test/bench/ProductionArtifactSecurity.t.sol` (production builds by artifact path).

| Attempt | Result | Test |
|---|---|---|
| Normal authorized swap (HookA) | output recorded in hook, curator and vault records of the output asset only | FL `normalSwap_recordsAllThreeScopes` |
| Exhaust the hook limit | refused at `cap − used`; exactly-at-cap accepted | FL `hookLimit_exhaustion`, PA `flowLimits_allThreeLevels` |
| Exhaust the curator limit via a second hook | refused | FL `curatorLimit_acrossHooks`, PA |
| Exhaust the vault limit via a second curator | refused | FL `vaultLimit_acrossCurators`, PA |
| Re-allocate after every fill (ceiling resets, flow does not) | refused at curator cap | FL `repeatedAllocations_cannotBypassCuratorLimit` |
| Same hook on a second pool | one hook record across pools | FL `multiplePoolsSameHook_shareHookLimit` |
| Split trades in one transaction (two swaps in one unlock) | sum counted; over-limit second swap reverts the whole transaction including the first swap's usage | FL `splitTradesInOneTransaction` |
| Hook splits one swap into two `exchange` calls | both charged; over-limit split rolls back | FL `splitInsideOneSwap_byHook`, PA `splitTradesAndRollback` |
| Split trades across transactions | accumulate | FL `hookLimit_exhaustion`, PA |
| Trade on both sides of a window boundary | full cap at `e·W − 1` and again at `e·W` (documented burst) | FL `windowBoundary_bothSides`, PA |
| Skip many windows | usage restarts at 0 in one step | FL `skippedWindows` |
| Timestamps across 2^32 (2106-02-07) and in year 10000 | same window either side of 2^32; no reset | FL `year2106_noResetAtUint32Wrap`, PA |
| Last 40-bit epoch; past it; near 2^64 | works; then `FlowEpochOutOfRange` (fail closed); closes and LP exits still work | FL `epochAtUint40Limit_failsClosed`, `nearUint64Timestamps_failClosed`, PA |
| Guardian tightens below usage mid-window; owner raises | usage kept both ways | FL `tighteningAndRaisingDuringWindow` |
| Freeze, unfreeze, deregister, re-register, bump, consumer re-registration, revoke | no record changes; revoked allocations refused | FL `lifecycleNeverResetsUsage`, PA |
| Cancel, emergency release, expiry release | no flow refunded | FL `closesNeverRefundFlow`, EX `partialConsumptionAndCloses` |
| LP deposits and exits at high utilization, every cap exhausted or zero, while paused | all work; no record changes | FL `lpPathsIgnoreFlowLimits_atHighUtilization`, `pauseStopsTrading_preservesUsage`, PA |
| Unconfigured hook, curator or vault record | `allocate` refused; `exchange` refused even with the flag cleared by `vm.store` | FL `unconfigured_failsClosed`, `exchangeFailsClosedOnUnconfiguredRecord`, PA |
| Zero cap | nothing passes | FL `zeroCap_allowsNothing` |
| Out-of-range configuration, strangers, hooks, guardian loosening or configuring, replaced guardian | refused | FL `setterValidationAndRoles` |
| Usage at `2^104 − 6`, then 5, then 1 | accepted, then refused; no overflow | FL `largestCap_noOverflow` |
| Single output above the largest cap | refused before any claim moves | `PricePolicy` `testFuzz_PP_D14_roundTripAtFloors_neverProfitable` |
| Hook raises its own limit mid-swap | `NotOwner`, swap reverts | FL `splitInsideOneSwap_byHook` |
| Hook takes the flow check then fails to fund input | whole swap reverts, records unchanged | FL `laterFailureRollsBackUsage` |
| Token-callback reentrancy | unchanged from 1B-2.1 (`ReentrantCall`), now on the production PoolManager | `Reentrancy.t.sol`, PA |
| Cross-asset | each asset's records independent | FL `crossAssetIsolation` |
| Exposure at the cap, one above, rounding, three scopes, deposits, redemptions, queued exits, partial fills, closes, re-registration, guardian tightening, zero bps, zero backing | as specified in §3 | EX (10 tests), PA `exposureCaps` |
| Random sequences vs a reference model | identical acceptance and usage | FL `testFuzz_FL_matchesReferenceModel`, EX `testFuzz_EX_boundaryMatchesFormula` |

No bypass was found.

## 5. Fuzzing, invariants, mutations and static analysis

### 5.1 Commands and results

All on `ef29ff9` (Foundry 1.7.1, Slither 0.11.6). Outputs kept in the scratchpad, not committed.

| Command | Result |
|---|---|
| `forge fmt --check` | clean |
| `forge build --force --sizes` | vault 22,361 B runtime (§8) |
| `forge test` (default profile, 1,000 fuzz runs) | **322 passed**, 0 failed (270 at `8ec08ca`; +52 new); unchanged count at `c299e5c` |
| `test/bench/security.sh` (`FOUNDRY_PROFILE=ci`, 10,000 fuzz runs; forced rebuild, `ProductionBuilds`, `ProductionArtifactSecurity`, full suite) | 2 + 12 + **322 passed**, 0 failed |
| `FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-contract VaultInvariantsTest` | **25 passed** (22 invariants + 3 progress tests), 32,768 calls per invariant, 0 handler reverts |
| `slither . --filter-paths "lib/\|test/" --exclude-dependencies` | 27 results (20 at `8ec08ca`); §5.4 |
| `test/bench/run.sh` | all production artifacts `ok`; gas in §7 |
| mutation script (§5.3) | 22 mutants: 21 killed, 1 survived (F15) and killed after `c299e5c` |

New tests: `FlowLimits.t.sol` 26 (one reference-model fuzz), `ExposureCaps.t.sol` 10 (one formula fuzz),
`ProductionBuilds.t.sol` 2, `ProductionArtifactSecurity.t.sol` +5, gas bench +3, invariant suite +3 invariants and
+1 progress test, `Reentrancy.t.sol` and `HookPriceBands.t.sol` +1 build check each.

### 5.2 Stateful campaign

New handler actions: `riskOwnerSet` (one call in four sets binding values), `riskGuardianTighten`,
`riskGuardianTryLoosen` (raise a value, or configure a fresh record; must always fail). 31 selectors.

- **Ghost flow model.** Every successful swap adds the vault's *measured* ERC-6909 output to a ghost per record, reset
  when the window changes. Built only from what the handler saw succeed, never from vault storage.
- **INV-F1 `invariant_flowUsageMatchesGhost`**: all 14 records the campaign uses equal the ghost, so no path except a
  successful swap (no LP operation, close, curator action, configuration change or reverted swap) changes usage; and
  usage ≤ cap after every swap.
- **INV-F2 `invariant_flowHierarchyConsistent`**: per asset, Σ hooks = Σ curators = vault.
- **INV-E1 `invariant_exposureAndHookReserved`**: `hookReserved` exact per hook and summing to `Q_a`; every
  successful allocation satisfied all three exposure caps; the guardian never loosened a record.
- `test_handler_riskLimitsProgress` drives a refusal, a new window and both guardian paths deterministically.

### 5.3 Mutation checks (manual, scratch worktree at `ef29ff9`, `forge test --fail-fast` per mutant)

Each mutant is an exact, asserted one-line edit of `src/SharedCommitmentVault.sol` (script in the scratchpad, not
committed). "Killed" names the first failing test.

| # | Mutation | Result | Killed by |
|---|---|---|---|
| F1 | hook-scope flow check removed from `exchange` | killed | `test_PA_flowLimits_allThreeLevels` |
| F2 | curator-scope flow check removed | killed | `test_PA_failClosedAndTimestampBoundaries` |
| F3 | vault-scope flow check removed | killed | `test_PA_flowLimits_allThreeLevels` |
| F4 | unconfigured flow record accepted | killed | `test_FL_exchangeFailsClosedOnUnconfiguredRecord` |
| F5 | `used + amount > cap` → `>=` (exactly-at-cap refused) | killed | `testFuzz_FL_matchesReferenceModel`, `test_FL_splitTradesInOneTransaction` |
| F6 | window never resets | killed | `test_PA_flowLimits_allThreeLevels` |
| F7 | usage never accumulates | killed | `test_FL_repeatedAllocations_cannotBypassCuratorLimit` |
| F8 | epoch computed from a 32-bit timestamp | killed | `test_PA_failClosedAndTimestampBoundaries` |
| F9 | `setRiskLimit` erases usage | killed | `test_FL_tighteningAndRaisingDuringWindow` |
| F10 | guardian may raise the exposure bps | killed | `test_FL_setterValidationAndRoles` |
| F11 | guardian may configure a new record | killed | `test_FL_setterValidationAndRoles` |
| F12 | hook exposure check removed | killed | `testFuzz_EX_boundaryMatchesFormula`, `test_EX_partialConsumptionAndCloses` |
| F13 | curator exposure check removed | killed | `test_EX_reRegistrationAndGenerations` |
| F14 | vault exposure check removed | killed | `test_EX_roundsDown` |
| F15 | eligible backing ignores queue demand (`E = N`) | **survived** the first run; killed after `c299e5c` | `test_EX_pendingDemandReducesEligibleBacking` |
| F16 | exposure cap rounds up | killed | `test_EX_roundsDown`, `testFuzz_EX_boundaryMatchesFormula` |
| F17 | unconfigured exposure record accepted | killed | `test_FL_unconfigured_failsClosed`, `test_PA_failClosedAndTimestampBoundaries` |
| F18 | `_close` does not lower `hookReserved` | killed | `test_EX_partialConsumptionAndCloses` |
| F19 | `exchange` does not lower `hookReserved` | killed | `test_PA_exposureCaps` |
| F20 | a close refunds vault flow | killed | `test_PA_flowUsageSurvivesLifecycle_lpExitsUnaffected` |
| F21 | flow limit applied to `redeem` | killed | `test_FL_epochAtUint40Limit_failsClosed` (first failure in the full run: `test_ownerPaysReceiverOwns_lockedSharesPermanent`) |
| F22 | window index not written | killed | `test_FL_normalSwap_recordsAllThreeScopes` |

F15 is the one finding of this check: the original test compared lens values only, and the lens recomputes `E_a`
itself. The strengthened test (`c299e5c`) makes queued demand bind inside `allocate`. F5, F12, F15, F16, F17, F18 and
F21 were re-run against only `FlowLimitsTest|ExposureCapsTest|VaultInvariantsTest` to confirm a targeted test kills
each; the "killed by" column names the first failure reported with `--fail-fast` (other tests usually fail too).

### 5.4 Slither

27 results against 20 at `8ec08ca` (same command). None removed. The 7 new ones are all on the new code:

- `uninitialized-state` for `_riskLimits`: false positive. It is written through the storage pointer returned by
  `_riskLimit` (`setRiskLimit`, `_consumeFlow`), which Slither does not follow.
- `incorrect-equality` (2): `l.epoch == epoch` in `_consumeFlow` and the same test in `VaultLens.flowUsed`. Intended:
  the comparison asks "is the stored usage from this exact window"; any other value is an earlier window.
- `timestamp` (3): `_flowEpoch`, `_consumeFlow`, `VaultLens.flowUsed`. Intended; windows are defined on
  `block.timestamp`. A block producer can move a timestamp by seconds, which at most moves a trade across a window
  boundary: the documented boundary burst, not a new one.
- `naming-convention` for `IVaultState.FLOW_WINDOW()`: the getter of a public constant, named like the constant.

## 6. Production-artifact validation

**The functional suite now runs on production builds** (`eaf44d8`). `VaultTestBase`, the fixture of every unit,
integration, security, fuzz and invariant test except the bench files, deploys the PoolManager, HookA, HookB and
`VaultLens` from their production artifact files; the vault has a single artifact (2,000 runs). The Reentrancy and
6/18-decimal fixtures do the same. Until this step those tests ran on 2,000-run hooks and PoolManager.

**How it is verified** (`test/utils/ProductionArtifacts.sol`): for each deployed contract, the artifact's recorded
`optimizer.runs` (2,000 vault; 44,444,444 others), `optimizer.enabled`, `viaIR`, `evmVersion = cancun` and
`bytecodeHash = none`, and `keccak256(deployed runtime code with immutable ranges zeroed) ==
keccak256(artifact deployedBytecode)`. `test_maskedHashDistinguishesBuilds` shows the check tells the 2,000-run hook
build apart from the production one.

| Where | Contracts on production builds | Tests |
|---|---|---|
| `test/unit/ProductionBuilds.t.sol` | vault, HookA, HookB, lens, PoolManager of the shared fixture | 2 |
| All `VaultTestBase` tests (unit, integration, security, fuzz, 24 invariants) | same | 287 (all tests outside `test/bench/`) |
| `test/bench/ProductionArtifactSecurity.t.sol` (ABI only, no source imported) | vault, HookA, HookB, PoolManager by artifact path | 12 (5 new) |
| `Reentrancy.t.sol`, `HookPriceBands6x18` | vault, PoolManager / hooks | checked by `requireProduction` |

Masked runtime hashes (logged by `test_PA_deployedCodeIsProductionArtifacts`):

| Artifact | keccak256 of runtime code, immutables zeroed |
|---|---|
| `SharedCommitmentVault.json` (2,000 runs) | `0x24bf6b7cf3976178513ec623be1111e6e38ea7fab1dac084375314be8fc40d95` |
| `HookA_DynamicFee.json` (44,444,444) | `0xa917ca8825bc6007b238203471b944433065195e36642745ef24cb16e2eaf29a` |
| `HookB_BoundedImpact.json` (44,444,444) | `0xeca951d1da23b8634a6eb9d1b1b26c67863df69aabc2660bb74dbb7c0d8b8fc5` |
| `PoolManager.default.json` (44,444,444) | `0xa1d857ebc4a1ec6c1d33662732f3a056378b71c5a82a84cb42c692323bbebb48` |

**Coverage of the required list:** both hooks executing real swaps; ERC-6909 settlement and currency-delta
conservation; freeze, revocation and cancellation; all three flow limits; exposure limits; LP deposits, redemptions,
queue processing and claims; malicious-hook and reentrancy tests; boundary values, revert paths and rollback. All run
on production builds in both the functional suite and the ABI-only file.

**Not on production builds:** test-only contracts compiled into test files (routers, `AuthModeHook`, `ScriptedHook`,
`MaliciousConsumerHook`, `ReentrantToken`), which the project never deploys. **Remaining gap:** the production-artifact
checks compare against the artifacts of the same local build; they do not yet compare against an independently
reproduced build or a deployed chain (that is `MAINNET_READINESS.md` X-2, D-4).

**CI command:** `test/bench/security.sh` (forced rebuild, `ProductionBuilds`, `ProductionArtifactSecurity` with hashes
logged, then the full suite; CI fuzz profile by default). The repository has no CI workflow file; this script is the
command a CI job should run. `fs_permissions` is unchanged: read-only, `./out` only.

## 7. Gas (OBSERVED, `test/bench/run.sh`; production artifacts; `--isolate`; Foundry 1.7.1)

Before: `8ec08ca` (clean tree). After: `ef29ff9`. Same harness, same Foundry version. Every fixture configures the
records of the paths it uses (the bench at the widest values; values do not change gas).

| Path | Before | After | Δ |
|---|---|---|---|
| swap HookA (router + PM + hook + vault), first consumption in the window | 217,202 | 239,693 | **+22,491** |
| swap HookB, first consumption in the window | 217,106 | 239,597 | +22,491 |
| swap HookA, second in the same window | — | 233,238 | see note below |
| swap HookA, first in a new window | — | 233,253 | +15 over same-window: the window change costs no extra storage |
| swap native v4 (control, no project code) | 150,303 | 150,303 | 0 |
| `allocate` (first in vault) | 286,392 | 325,311 | +38,919 |
| `allocate` (steady state, new curator) | 264,805 | 286,624 | +21,819 |
| `setRiskLimit` (configure new record) | — | 80,776 | |
| `setRiskLimit` (change configured record) | — | 46,747 | |
| `release` (owner, before expiry) | 41,759 | 45,460 | +3,701 (`hookReserved`) |
| `release` (revoked curator, stranger) | 39,597 | 43,731 | +4,134 |
| `cancelAllocation` (after partial consumption) | 37,771 | 42,011 | +4,240 |
| `freezeCurator` / `unfreezeCurator` / `revokeCurator` (10) | 33,139 / 33,113 / 33,571 | 33,297 / 33,272 / 33,751 | +158 / +159 / +180 (dispatch) |
| `deposit` (new LP) | 149,069 | 149,179 | +110 |
| `initialDeposit` | 237,348 | 237,469 | +121 |
| `redeem` instant / queued | 160,370 / 145,695 | 160,392 / 145,695 | +22 / 0 |
| `processQueue(1)` / `claim` | 121,919 / 135,835 | 121,985 / 135,857 | +66 / +22 |
| deploy vault (CREATE) | 4,374,257 | 4,987,290 | +613,033 |
| deploy lens (CREATE) | 1,167,248 | 1,581,329 | +414,081 |

**Swap breakdown (ESTIMATE from EIP-2929/2200 constants, not measured separately):** three flow records, each one cold
slot read (2,100) and one non-zero to non-zero write (2,900), about 15,000; `hookReserved` decrement about 5,000; the
three `keccak256` keys, the epoch division and the checks make up the rest. The "same window" and "new window" rows
are equal because a record update costs the same whether or not the window changed. They are lower than the first
swap because the first swap also pays zero-to-non-zero writes outside the risk records (for example the allocation's
`consumed`); the first-swap rows are the comparison with the 1B-2.1 baseline. LP paths changed only by
dispatch-table noise (≤ 121 gas): no LP path reads a risk record.

Possible reductions, not implemented (each needs review): drop the hook-scope exposure cap (saves the `hookReserved`
write on every swap, about 5,000); key records by a cheaper hash; make the hook-level flow record optional.

## 8. Contract sizes and remaining headroom

| Contract (production build) | Runtime | Init | EIP-170 margin | Before (`8ec08ca`) |
|---|---|---|---|---|
| `SharedCommitmentVault` (2,000 runs) | 22,361 | 22,970 | **2,215** | 19,520 (5,056) |
| `HookA_DynamicFee` | 7,174 | 8,011 | 17,402 | unchanged |
| `HookB_BoundedImpact` | 6,884 | 7,721 | 17,692 | unchanged |
| `VaultLens` | 6,972 | 6,998 | 17,604 | 5,046 |

The vault grew by 2,841 B and keeps **2,215 B** of headroom, above the 2,048 B floor by 167 B. No risk check was
removed and no contract was split. Anything further in the vault needs bytes found first; candidate savings for
review: shorter error payloads (dropping `account`/`currency` from the two 5-argument errors), or moving `getRiskLimit`
to raw storage reads in the lens.

## 9. Remaining risks

- **Epoch-boundary burst.** A scope can pay `2 × cap` across two seconds at a window boundary, and
  `(ceil(T/W) + 1) × cap` over any `T` seconds. Operators must size caps with this in mind (half the tolerable
  two-window loss, if a burst at the boundary matters). The planned ring buffer (K sub-windows summed over the last K)
  would bound any window of length W by `cap × (1 + 1/K)`; it can replace the single (epoch, used) pair without
  changing any invariant above, because a rolling sum ≤ cap implies every fixed-window total ≤ cap.
- **Price is not bounded by these limits.** Flow and exposure caps limit amount and rate only. A hook can sell its
  allowance at the floor; the floor is static and set by governance.
- **One window length for all records** (`FLOW_WINDOW` is a constant). A per-record window would have to keep the
  epoch consistent when changed; not implemented.
- **Largest cap `2^104 − 1` raw units per window** (about `2 × 10^13` whole tokens at 18 decimals). A single output
  above it cannot execute at all. Tokens with very large raw supplies would need a scaled representation.
- **Exposure checked only at creation.** After backing falls, existing allocations can exceed the configured share;
  the guardian's freeze, revoke and emergency release are the tools to reduce them.
- **Configuration burden.** Every path needs three records per asset before anything trades (fail closed). A missed
  record blocks a path, which is safe but can surprise operators; deployment scripts must configure and read back
  every record (`MAINNET_READINESS.md` X-2).
- **Tightening, not loosening, is immediate for the guardian; loosening is immediate for the owner.** No timelock yet
  (`MAINNET_READINESS.md` G-2).
- **Bytecode headroom is now 2,215 B**, 167 B above the floor. The authorization module step (1B-2.3) removes `allocate` and
  `nonceUsed` from the vault but adds `reserveFor`; measure before adding anything else.
- **Not tested:** Unichain `block.timestamp` behaviour (flashblocks) against the window (F-3); fork tests.

## 10. Differences from the specifications

- **Fixed epochs instead of the leaky bucket** proposed in `MODULAR_RISK_ENGINE.md` §7.2 (reasons in its §7 note). The
  task allowed this explicitly; no rolling-window guarantee is claimed.
- **Exposure caps at three scopes** (hook, curator, vault), measured against `E_a = N_a − D_a` rather than `N_a`.
- **One configuration call for both limits** of a record; unconfigured fails closed for both.
- **Plan row 8 (packed curator bucket) not attempted** (§7 note in `MODULAR_RISK_ENGINE.md`).
- **Functional fixture moved to production builds** (not in the plan; requested by the task's production-artifact
  section).
- One existing fuzz test changed behaviour, not its assertion: `testFuzz_PP_D14_roundTripAtFloors_neverProfitable` now
  expects `FlowLimitExceeded` when the return leg's single output exceeds `2^104 − 1`; the floor inequality it checks is
  unchanged and still asserted on every run.

## 11. Recommended scope for EIP-712 authorization (1B-2.3, not started)

- Keep the module out of the swap and LP paths (architecture B, D17): it may only call `reserveFor`.
- `reserveFor(req, curator, generation, signed)` must run **every** check `allocate` runs today, including the three
  exposure checks and the D18 configuration checks; the module must not be able to skip them. Add a test module that
  calls `reserveFor` with arbitrary inputs (M-1).
- Bind the signed struct to: chain id, vault, module, curator, generation, consumer, pool key, `currencyOut`, `maxOut`,
  floor, expiry, deadline, nonce. Do **not** let a signature carry or raise risk limits; limits stay vault
  configuration.
- Unordered nonce bitmap per curator; single use across direct and signed paths (S-3); generation check on the signed
  path (S-2 revival tests already have the generation rules underneath).
- ERC-1271 with the `Mock1271Wallet` modes (M-3); domain separator rebuilt on chain-id change (S-4).
- Size: measure the vault after removing `allocate`/`nonceUsed` and adding `reserveFor` before writing the module.

## 12. Next action requiring approval

1. The fixed-epoch window (one day) instead of the leaky bucket, and the boundary-burst bound in §2.
2. The exposure-cap definition (§3): three scopes, `E_a = N_a − D_a`, checked at creation only.
3. The largest configurable cap, `2^104 − 1` per window, and the behaviour above it.
4. The functional fixture on production builds (§6) and `test/bench/security.sh` as the CI command.
5. Starting 1B-2.3 (authorization module, trust-boundary change), with the scope in §11.
