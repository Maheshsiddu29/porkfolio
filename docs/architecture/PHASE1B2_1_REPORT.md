# Porkfolio — Phase 1B-2.1 Report: Curator State, Revocation and Cancellation

**Status: DONE, waiting for review.** Branch `phase-1b-2-1-curator-lifecycle`, created from `phase-1b-2-step1` at
`c2d77cb`. This step changes vault behaviour (curator states, cancellation, a reentrancy lock). It does not change the
module trust boundary: there are no signatures, nonce bitmaps, `reserveFor`, flow limits, cumulative pricing or ring
buffers. Labels: SOURCE (read from the code), OBSERVED (measured or asserted by a test; the command is given), ESTIMATE.

| Commit | Content |
|---|---|
| `889d714` | `feat(vault)`: curator record (registration, restriction, generation), freeze, unfreeze, revoke, `bumpGeneration`; restriction check in `allocate` and `exchange`; permissionless release for revoked curators |
| `7777745` | `feat(vault)`: `cancelAllocation`; one internal `_close` for every close path; `CloseReason` |
| `989417e` | `feat(vault)`: transient (EIP-1153) reentrancy lock on the ten accounting entry points |
| `f7ca627` | `test(invariant)`: three curators and every lifecycle action in the stateful campaign; INV-C1, C2, C4, C5, A2, A3 |
| `f78d2c5` | `test(bench)`: security tests on production artifacts; lifecycle gas benchmarks |
| `f288326` | `test(bench)`: the production-build check reads artifact metadata (fix for a failure found under the CI profile, §6.1) |
| this commit | this report; `CURATOR_SECURITY_MODEL.md`, `CURATOR_REVOCATION.md`, `MAINNET_READINESS.md`, `PHASE1B2_IMPLEMENTATION_PLAN.md`, `README.md` |

## 1. Curator state model

**Decision: two independent controls plus a counter, not one status enum.** (SOURCE, `ISharedCommitmentVault.sol`)

```solidity
enum CuratorRestriction { None, Frozen, Revoked }
struct CuratorRecord { bool registered; CuratorRestriction restriction; uint32 generation; }   // one storage slot
```

| Task state | `registered` | `restriction` | Create allocations | Its allocations consumable | Reservations |
|---|---|---|---|---|---|
| Active | true | None | yes | yes | normal |
| Deregistered | false | None | no | **yes** (approved rule) | unchanged |
| Frozen | true or false | Frozen | no | **no** | **kept** in `Q_a` and `curatorReserved` |
| Permanently revoked | false (forced) | Revoked | no | **no, ever** | kept until each allocation is released; anyone may release |

**Why not the proposed `None/Active/Frozen/Revoked` enum.** With one field, three approved rules collide:

1. Deregistering a frozen curator would write `None`, which makes its allocations consumable again (an unfreeze by
   the guardian, which may never loosen).
2. `unfreezeCurator` would write `Active`, which re-registers a curator that was deregistered while frozen.
3. `setCurator(c, true)` on a frozen curator must either fail or lift the freeze; the task requires that ordinary
   re-registration never silently undoes a freeze.

With two fields, each action touches only its own field (OBSERVED: `test_CL_registrationAndFreezeAreIndependent`).
The mapping replaces `isCurator` at the same storage slot (4).

## 2. Registration, freeze and revocation

| Function | Caller | Allowed from | Effect | Generation |
|---|---|---|---|---|
| `setCurator(c, true)` | owner | `None`, `Frozen` (not `Revoked`) | `registered = true`; a freeze stays | unchanged |
| `setCurator(c, false)` | owner, guardian | any | `registered = false` | **+1** (always, also if already deregistered) |
| `freezeCurator(c)` | owner, guardian | `None` only | `restriction = Frozen` | unchanged |
| `unfreezeCurator(c)` | **owner only** | `Frozen` only | `restriction = None`; registration unchanged | **+1** |
| `revokeCurator(c)` | owner, guardian | `None`, `Frozen` | `restriction = Revoked`, `registered = false` | unchanged |
| `bumpGeneration()` | anyone, for itself | any | — | **+1** |

Invalid transitions revert with `InvalidCuratorTransition(curator, currentRestriction)`. Every change emits
`CuratorUpdated(curator, registered, restriction, generation, by)` with the full new record (`CuratorSet` is gone).

Properties (all OBSERVED in `test/security/CuratorLifecycle.t.sol`, 19 tests):

- **Immediate.** `exchange` reads the allocation's curator restriction on every call, so the next swap against any of
  the curator's allocations reverts `CuratorRestricted` in the same block. One storage write, whatever the number of
  allocations (`test_CL_revoke_stopsEveryAllocationInOneCall`, three allocations, two hooks, both directions).
- **No asset movement.** Freeze, unfreeze, revoke, (de)registration and bumps leave real claim and ERC-20 balances,
  `B_a`, `W_a`, `Q_a`, every `curatorReserved`, `S`, `P` and the queue unchanged (snapshot tests; INV-C5 in the
  campaign).
- **Before, during, after partial consumption.** `test_CL_freezeBeforeConsumption`,
  `test_CL_freezeDuringPartialConsumption` (exactly `maxOut − consumed` stays reserved; after unfreeze the rest is
  consumable), `test_CL_freezeAfterFullConsumption` (nothing reserved; freeze still blocks creation).
- **Guardian only restricts.** It can freeze, revoke and deregister. It cannot register (`GuardianCannotIncreaseRisk`)
  or unfreeze (`NotOwner`) (`test_CL_guardianCannotIncreaseAuthority`, `test_CL_guardianFreezes_onlyOwnerUnfreezes`).
- **Revocation is terminal across role changes.** After a two-step ownership transfer and a new guardian, the new owner
  cannot re-register or unfreeze the curator; raising its ceiling achieves nothing
  (`test_CL_revocationSurvivesOwnerAndGuardianChanges`).
- **Emergency actions work while paused and halted** (`test_CL_emergencyActionsWorkWhilePaused`).

## 3. Generation counter

**One counter is enough, because execution rights are removed by terminal revocation, not by a second counter.**

- **What it invalidates.** Curator instructions that have not become allocations. Rule: an instruction tagged with
  generation `g` is valid only while the curator's generation equals `g`. Example: a curator signs at 7; the guardian
  deregisters it (8); the owner re-registers it (still 8). The instruction tagged 7 can never match again.
- **Why it cannot also govern existing allocations.** If `exchange` compared a per-allocation generation with the
  current one, then deregistration and unfreeze, which must raise the generation, would also kill live allocations.
  That breaks two approved rules: deregistration leaves allocations consumable, and unfreeze resumes them.
- **What removes existing execution rights.** `Revoked`, checked in `exchange`. It never changes, `released` is never
  cleared and ids only increase, so a revoked curator's allocations can never execute again and no id can be reopened.
- **No wrap, no reuse.** `uint32`; `_nextGeneration` reverts `GenerationExhausted` at `type(uint32).max` instead of
  wrapping to 0. Reaching it takes 4,294,967,295 separate increments by the owner, guardian or curator. At the
  maximum, deregistration and unfreeze revert (the curator stays frozen: fail closed); freeze and revoke never touch the
  generation and still work (`test_CL_generationExhaustion`, which writes the slot with `vm.store` after checking the
  packing against `getCurator`).
- **Not read on-chain yet.** No signed path exists; the direct `allocate` path has the curator present, so it does not
  check the generation (as specified for the direct path). 1B-2.3's `reserveFor` will compare it. There is no
  placeholder signature check.
- **Monotonic** under random sequences of every action by every role (`testFuzz_CL_randomTransitions`, 24 steps per
  run) and in the campaign (INV-C1).

## 4. Cancellation and the shared close path

`cancelAllocation(id)`: only `a.curator`; works in every state (deregistered, frozen, revoked, paused, halted, hook
deregistered, expired), so a curator can always reduce its exposure. `release(id)`: anyone after expiry; anyone if the
curator is revoked; otherwise owner or guardian. A frozen or deregistered curator's unexpired allocation is **not**
releasable by a stranger, because a freeze may be lifted (`test_CL_frozenOrDeregisteredAllocationNotReleasableByStranger`).

Both call one internal function:

```
_close(id, a, reason):   unused = maxOut − consumed
                         a.released = true
                         Q_out                    −= unused
                         curatorReserved[c][out]  −= unused
                         emit AllocationReleased(id, msg.sender, unused, reason)
```

- **Exactly once.** Both callers load the allocation with `_getLiveAllocation`, which reverts `UnknownAllocation` or
  `AllocationAlreadyReleased`. `test_CC_doubleCloseFailsOnEveryPath` closes once and tries every other path, both
  orders.
- **Consumed output is never refunded.** Only `maxOut − consumed` leaves `Q_a`; `consumed` is untouched. Example:
  maxOut 10,000, consumed 3,500 → `Q_a` falls by 6,500 (`test_CC_cancelAfterPartial_releasesExactRemainder`;
  `testFuzz_CC_partialConsumptionThenClose` over every path and any consumption).
- **Independent allocations.** Closing one allocation leaves the curator's others and other curators' allocations
  unchanged (`test_CC_allocationsAreIndependent`).
- **No assets move; `W_a` untouched** (`test_CC_closeDoesNotTouchClaimableAssets`).
- **Reasons:** `Expired`, `Emergency`, `Canceled`, `CuratorRevoked` (`test_CC_closeReasons`).
- **Races** cancel vs swap and emergency release vs swap, both orders: consumed + released = maxOut.

**Reserved capacity between revocation and cleanup.** Revocation moves nothing. Until each allocation is released,
its `maxOut − consumed` stays in `Q_a` and `curatorReserved`. During that window:

- nobody can consume it (`exchange` rejects the curator);
- the admission rule still counts it, so it is never promised twice;
- `_deliverableShares` still excludes it, so LP exits may queue rather than be paid from it;
- `W_a` (assets already finalized for queued LPs) is never touched by revocation or cleanup.

Anyone may then release each allocation in O(1), in any order, exactly once. An LP blocked by it can do so itself
(`test_CL_lpExitsWhileFrozenThenRevoked`). The window is bounded by `MAX_HORIZON` (30 days) even if nobody cleans up,
because every allocation expires.

An O(1) aggregate sweep at revocation (subtracting `curatorReserved` from `Q_a`) was considered and not built: it would
redefine `Q_a` as a sum over non-revoked curators and make every later per-allocation close skip the subtraction, which
changes the invariant every LP path relies on.

## 5. Reentrancy

### 5.1 Call-path trace (SOURCE, pinned v4-core)

| Path | External calls | Foreign code can run? | Vault state during the call |
|---|---|---|---|
| `deposit`, `initialDeposit` | `PM.unlock` → `unlockCallback` → `_settleIn`: `PM.sync`, **ERC-20 `transferFrom`**, `PM.settle`, `PM.mint` | **yes**, in the pair token's `transferFrom` | shares and `B_a` already raised; claims not yet minted, so `B_a` > real claim balance |
| `redeem` (instant part), `claim` | `PM.unlock` → `_payOut`: `PM.burn`, `PM.take` → **ERC-20 `transfer`** to the receiver | **yes**, in the pair token's `transfer` | all effects done; between the two assets' legs, one asset's claims are burned and the other's not yet |
| `redeem` (queued part), `processQueue`, `cancelRequest` | none | no | — |
| `exchange` | `PM.transferFrom(hook→vault)`, `PM.transfer(vault→hook)` (ERC-6909) | **no**: v4 ERC-6909 transfers only update balances | effects done before the transfers |
| `allocate`, `release`, `cancelAllocation`, setters | none | no | — |
| `unlockCallback` | only called by the PoolManager, for the vault's own `unlock` | — | — |
| Hook `beforeSwap` → `exchange` | the vault is not executing before or after `exchange` | not reentrancy into the vault | consistent once `exchange` returns |
| Nested `PM.unlock` (any vault LP payout inside a swap) | reverts `AlreadyUnlocked` (PoolManager) | — | — |

### 5.2 What was implemented

An EIP-1153 transaction-scoped lock (inline `tload`/`tstore`; no dependency added or upgraded), taken by the ten entry
points that read or change share, queue or commitment accounting: `initialDeposit`, `deposit`, `redeem`,
`processQueue`, `cancelRequest`, `claim`, `allocate`, `release`, `cancelAllocation`, `exchange`. It is the first
modifier, so a reentrant call reverts `ReentrantCall` before any other check.

**Not locked, deliberately:**

- `unlockCallback`: it runs inside the vault's own `unlock`, while the lock is already held.
- Configuration setters: owner or guardian only, no external calls, no accounting reads.
- `bumpGeneration`: writes only the caller's own counter.
- Views.

Hooks are unaffected: the lock is only held while a vault entry point executes, and is released at its end, so two
`exchange` calls in one `beforeSwap` both work (`test_RE_lockReleasedBetweenCalls`).

Strictly, only the functions that open a token window (deposit, payout) and those whose outcome depends on `B_a`
(`exchange`, `allocate`, `processQueue`) need the lock. `release`, `cancelAllocation` and `cancelRequest` were included
because they change commitment or queue accounting that the others read, and including them removes the need to
re-check each one whenever a token window changes. Cost: 546 B and about 300 gas per call (ESTIMATE from
`TLOAD` + 2 `TSTORE`).

### 5.3 Tests (`test/security/Reentrancy.t.sol`, 10; plus production-artifact §7)

- **Token windows.** `ReentrantToken` is a pair token that calls out once from inside `transfer`/`transferFrom`. The
  callback enters through `ReentryAgent`, which is a registered curator, consumer and LP and holds every precondition
  (shares, a pending and a claimable request, an expired allocation, its own allocations, input claims and operator
  approval), so without the lock each call would pass its own checks.
  - Deposit window: all ten locked functions are rejected with `ReentrantCall`; the deposit completes exactly.
  - Payout window (instant redeem): same, and the redeemer receives exactly the accounted amount.
  - Double claim: a reentrant claim is rejected; a later claim reverts `NothingToClaim`.
  - Lock scope: `bumpGeneration` succeeds from a callback; `unlockCallback` still rejects non-PoolManager callers;
    setters still apply role checks.
- **Malicious registered hook** (`ScriptedHook`, runs scripted calls inside `beforeSwap`):
  - withdrawing or claiming while the swap is unsettled → `AlreadyUnlocked`, whole swap reverts, nothing changes;
  - the hook, as the allocation's curator, cancels between two fills → second fill reverts
    `AllocationAlreadyReleased`, whole swap reverts, allocation still open and unconsumed; cancelling after the last
    fill is valid and releases exactly the rest;
  - cancel then re-submit the same instruction → `NonceAlreadyUsed`; calling `unlockCallback` directly →
    `NotPoolManager`; opening its own `unlock` → `AlreadyUnlocked`;
  - two fills in one swap respect the quota.

## 6. Tests, fuzzing, invariants and mutations

### 6.1 Commands and results (OBSERVED; source at `f78d2c5`/`f288326`, which have identical `src/`)

| Command | Result |
|---|---|
| `forge fmt --check` | clean |
| `forge build --sizes` | success; §8 |
| `forge test` | **270 passed, 0 failed** (210 before this step + 60 new), at `f288326` after `forge build --force` |
| `FOUNDRY_PROFILE=ci forge test` (10,000 fuzz runs) | **270 passed, 0 failed** (after `f288326` and `forge build --force`; see the finding below) |
| `FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-contract VaultInvariantsTest` | **21 passed** (19 invariants + 2 progress tests), 32,768 calls per invariant, 0 handler reverts |
| `slither . --filter-paths "lib/\|test/" --exclude-dependencies` | 20 results (22 at `c2d77cb`); §6.4 |
| `test/bench/run.sh` | exit 0; every production artifact has the expected settings; §8 |

**Finding during validation.** The first CI-profile run (`f78d2c5`) failed one test:
`test_PA_deployedCodeIsProductionArtifacts` reported "no matching artifact found". That version compared the deployed
hooks with their 2,000-run test builds (`*.vault.json`), which exist in `out/` only while some test file has compiled
them; Slither's build (`forge build --skip test`, run just before) had removed them. The production artifacts were
correct (checked with `jq`: HookA 44,444,444 runs, 7,174 B; vault 2,000 runs, 19,520 B). Commit `f288326` makes the
test read the optimizer settings from each production artifact's metadata instead, so it no longer depends on which
other builds are present. The CI and default runs in the table are after that fix and a `forge build --force`.

All 210 earlier tests pass unchanged. No assertion was relaxed. The only edits to existing test files are the
invariant handler (new actions, per-curator sums) and `test/bench/ProductionArtifactGas.t.sol` (interfaces moved to
`IBench.sol`, five new benchmarks).

### 6.2 New tests

| File | Tests | Covers |
|---|---|---|
| `test/security/CuratorLifecycle.t.sol` | 19 (1 fuzz) | §1–§3 |
| `test/security/CuratorCancellation.t.sol` | 13 (1 fuzz) | §4, T-08, T-09 |
| `test/security/Reentrancy.t.sol` | 10 | §5 |
| `test/invariant/VaultInvariants.t.sol` | +5 invariants, +1 progress test | §6.3 |
| `test/bench/ProductionArtifactSecurity.t.sol` | 7 | §7 |
| `test/bench/ProductionArtifactGas.t.sol` | +5 benchmarks | §8 |

### 6.3 Stateful campaign

The handler now has three curators (one never revoked, so allocation stays possible) and these actions, each by the
owner or the guardian where relevant: register, deregister, freeze, unfreeze, revoke, bump generation, curator cancel
(own, and another curator's), release by owner or stranger, owner rotation (two-step) and guardian rotation, on top of
every earlier action. Guardian attempts to register or unfreeze are included and must fail.

| Invariant | Statement |
|---|---|
| INV-C1 `invariant_generationMonotonic` | no curator's generation ever decreases |
| INV-C2 `invariant_revokedIsTerminal` | once revoked: still revoked and unregistered, across rotations |
| INV-C4 `invariant_noConsumptionWhenFrozenOrRevoked` | no successful swap against a frozen or revoked curator; no allocation created by an unregistered, frozen or revoked curator; guardian never registers or unfreezes |
| INV-C5 `invariant_curatorActionsMoveNothing` | curator actions and rotations change no balance, `B`, `W`, `Q`, `curatorReserved`, `S`, `P` or queue |
| INV-A2 `invariant_reservedIsExactAndBacked` (extended) | `Q_a` and **each curator's** reserved total equal the sums over unreleased allocations; frozen and revoked allocations included |
| INV-A3 `invariant_closedIsTerminal` | every close released exactly `maxOut − consumed`, once, by an allowed caller; a closed allocation's `consumed` never changes; every `released` flag was set by an observed close |

The earlier invariants (backing equals real claims, ghost ledger, custody, shares and queue conservation, no double
claim, FIFO, no dilution, raw-source equations, lens previews, price floors, guardian tightening) run over the same
sequences, so they now also cover LP withdrawals while curators are frozen or revoked, and cleanup in arbitrary order.
"No ERC-6909 backing created or destroyed without a legitimate asset movement" is `invariant_backingEqualsRealClaims`
plus `invariant_ghostLedgerConservation` plus INV-C5. `test_handler_curatorLifecycleProgress` guards against a vacuous
campaign: it requires a rejected frozen swap, a rejected revoked swap, a stranger cleanup, a refused cross-curator
cancel, refused guardian unfreeze and registration, and a refused re-registration after an owner rotation.

Campaign depth caveat (OBSERVED): only the final run's counters are printed. Sampled single runs of 64 calls show each
lifecycle action succeeding 0–6 times per run and 1–3 successful allocations per run, because the action set grew from
18 to 28 selectors. The 256 × 128 campaign therefore exercises each action thousands of times in total, but individual
sequences are short in allocations. The deterministic tests in §2–§5 cover each transition explicitly.

### 6.4 Slither

20 results against 22 at `c2d77cb` (same command, same Slither 0.11.6):

- **Gone (2):** `reentrancy-events` for the vault's `deposit`, `initialDeposit`, `redeem`, `claim` (Slither recognises
  the lock). The hook's `beforeSwap` entry remains, unchanged.
- **New (2):**
  - `assembly-usage` in `_enterLock` and `_exitLock`: intended; Solidity 0.8.26 has no `transient` keyword.
  - `uninitialized-local` for `reason` in `release`: false positive; every branch assigns it or reverts.
- **Unchanged:** `unimplemented-functions` (the `Currency`-keyed getters, triaged in the step 1 report),
  `arbitrary-from-in-transferfrom` (`_settleIn` uses the depositor recorded by the vault's own `unlock`),
  `unused-return` (ERC-6909 `transfer`/`transferFrom` return `true` or revert; `unlock`'s return data is unused),
  `block-timestamp` (expiry and deadline), `missing-zero-address-validation` (`setGuardian(0)` removes the guardian),
  naming and complexity notes.

### 6.5 Mutation checks (manual, scratch worktree at `f78d2c5`, full `forge test` per mutant)

Each mutant is an exact, asserted one-line edit of `src/SharedCommitmentVault.sol` (script in the scratchpad, not
committed).

**18 of 18 killed.**

| Mutant | Change | Result | Killed by (examples) |
|---|---|---|---|
| C1 | `exchange` skips the restriction check | killed (9) | freeze/revoke tests, INV-C4, `test_PA_frozenCurator_executionRejected` |
| C2 | `unfreezeCurator` does not raise the generation | killed (5) | `test_CL_generationRules`, `test_CL_freezeDuringPartialConsumption` |
| C3 | a revoked curator can be re-registered | killed (6) | INV-C2, `testFuzz_CL_randomTransitions`, `test_CL_invalidTransitions` |
| C4 | freeze allowed from Revoked | killed (3) | `test_CL_invalidTransitions`, INV-C2 |
| C5 | deregistration does not raise the generation | killed (4) | `test_CL_deregister_bumpsGeneration_keepsAllocationsConsumable` |
| C6 | revocation keeps registration | killed (6) | INV-C2, record assertions |
| C7 | `allocate` ignores the restriction | killed (4) | `test_CL_freezeBeforeConsumption`, INV-C4 (creation) |
| C8 | generation wraps to 0 | killed (1) | `test_CL_generationExhaustion` |
| C9 | guardian can unfreeze | killed (5) | `test_CL_guardianFreezes_onlyOwnerUnfreezes`, `testFuzz_CL_randomTransitions` |
| C10 | strangers may release a frozen curator's allocation | killed (2) | `test_CL_frozenOrDeregisteredAllocationNotReleasableByStranger`, INV-A3 |
| C11 | `cancelAllocation` without the curator check | killed (3) | `test_CC_nonCuratorCannotCancel`, INV-A3 |
| C12 | `_close` releases `maxOut` (refunds consumed) | killed (31) | `test_CC_cancelAfterPartial_releasesExactRemainder`, raw-source equations |
| C13 | a closed allocation can be closed again | killed (15) | `test_CC_doubleCloseFailsOnEveryPath`, INV-A3 |
| C14 | `_close` does not lower `curatorReserved` | killed (10) | INV-A2 per curator, `test_CC_allocationsAreIndependent` |
| C15 | lock disabled | killed (4) | `test_RE_depositWindow_…`, `test_RE_payoutWindow_…`, `test_PA_maliciousHookAndTokenReentrancy` |
| C16 | lock never released | killed (160 of 237; some suites fail in setUp) | most of the suite |
| C17 | `exchange` checks registration instead of restriction | killed (10) | `test_CL_deregister_…keepsAllocationsConsumable`, `test_RO_curatorRegistry` |
| C18 | freeze releases the curator's reservation | killed (10) | INV-C5, INV-A2, `test_CL_freezeBeforeConsumption` |

C15 is the evidence that the lock, not some other check, rejects the reentrant calls: with it disabled, the agent's
reentrant calls pass their own checks and the four reentrancy tests fail.

## 7. Production-artifact tests

`test/bench/ProductionArtifactSecurity.t.sol` deploys the vault, HookA, HookB and the PoolManager **from their
production artifact files by path** (`out/HookA_DynamicFee.sol/HookA_DynamicFee.json`,
`out/PoolManager.sol/PoolManager.default.json`, …), so the build under test does not depend on the profile the test
file is compiled under. `test_PA_deployedCodeIsProductionArtifacts` checks each deployed code length against the
production artifact (vault 19,520; HookA 7,174; HookB 6,884; PoolManager 24,009) and that it differs from the 2,000-run
build of the same contract (HookA 5,601; HookB 5,386; PoolManager 19,959). `run.sh` checks the optimizer settings
recorded in those files. Reading `out/` needs the new read-only `fs_permissions` entry in `foundry.toml`.

| Test | Result |
|---|---|
| `test_PA_hookA_hookB_settlementConservation` | PASS: three swaps (HookA both directions, HookB); trader, PoolManager and vault balances move by exactly the swap amounts; `Q_out` and `consumed` move by the output; every PoolManager currency delta and the non-zero-delta count are 0 afterwards; the PoolManager is locked again |
| `test_PA_frozenCurator_executionRejected` | PASS on both hooks; unfreeze restores |
| `test_PA_revokedCurator_executionRejected_thenCleanup` | PASS; exact-remainder cleanup by a stranger; re-registration refused |
| `test_PA_partialConsumptionThenCancellation` | PASS |
| `test_PA_maliciousHookAndTokenReentrancy` | PASS (cancel between fills, redeem mid-swap, token callback during deposit) |
| `test_PA_lpWithdrawalDuringRestrictedTrading` | PASS (paused + halted + frozen, then revoked) |

**Which tests run production artifacts:** this file and `ProductionArtifactGas.t.sol` (all of `test/bench/`). The
**vault** is the production artifact in every test file (it has one artifact). Everywhere else in the functional
suite, HookA, HookB and the PoolManager are the 2,000-run builds (`MAINNET_READINESS.md` D-6, still Partial).

## 8. Sizes and gas (OBSERVED, `test/bench/run.sh`; production artifacts; Foundry 1.7.1)

### 8.1 Runtime size

| Contract | `c2d77cb` | `889d714` | `7777745` | `989417e` (final) | EIP-170 margin |
|---|---|---|---|---|---|
| `SharedCommitmentVault` (2,000 runs) | 17,035 | 18,609 | 18,974 | **19,520** | **5,056** (target ≥ 2,048) |
| `HookA_DynamicFee` | 7,174 | | | 7,174 | 17,402 |
| `HookB_BoundedImpact` | 6,884 | | | 6,884 | 17,692 |
| `VaultLens` | 5,046 | | | 5,046 | 19,530 |

Prototype prediction for 1B-2.1 + 1B-2.2 was about 19,400 B (`PHASE1B2_IMPLEMENTATION_PLAN.md`); 1B-2.1 alone is
19,520 B. The flow limits in 1B-2.2 must fit in the remaining 3,008 B above the 2,048 B margin. Hook and lens bytecode
and init-code hashes are unchanged.

### 8.2 Gas (`forge test --isolate`, `gasleft()` around one external call; same harness and Foundry version)

| Path | `c2d77cb` | final | Δ |
|---|---|---|---|
| Swap via HookA (router + PM + hook + vault) | 214,456 | 217,202 | **+2,746** |
| Swap via HookB | 214,360 | 217,106 | +2,746 |
| Native v4 swap (control, no project code) | 150,303 | 150,303 | 0 |
| `allocate`, first in vault | 285,667 | 286,392 | +725 |
| `allocate`, steady state | 264,080 | 264,805 | +725 |
| `release` by owner before expiry | 38,774 | 41,759 | +2,985 |
| `initialDeposit` | 236,819 | 237,348 | +529 |
| `deposit`, new LP | 148,520 | 149,069 | +549 |
| `redeem`, instant | 159,865 | 160,370 | +505 |
| `redeem`, fully queued | 145,278 | 145,695 | +417 |
| `processQueue(1)` | 121,458 | 121,919 | +461 |
| `claim` | 135,352 | 135,835 | +483 |
| `freezeCurator` | — | 33,139 | new |
| `unfreezeCurator` | — | 33,113 | new |
| `revokeCurator` (curator with 10 live allocations) | — | 33,571 | new |
| `release`, revoked curator, by a stranger (per allocation) | — | 39,597 | new |
| `cancelAllocation` after partial consumption | — | 37,771 | new |
| Deploy vault (CREATE) / init-code calldata | 3,838,048 / 248,844 | 4,374,257 / 287,104 | +536,209 / +38,260 |

- **Swap +2,746.** ESTIMATE of the parts: 2,100 for the cold read of the curator's slot (EIP-2929), about 300 for the
  lock, the rest dispatch and the check. Not verified by trace. The prototype's +19,163 included three flow buckets,
  which are not built.
- **`release` +2,985:** the same cold curator read (needed to know whether the curator is revoked) plus the lock.
- **LP paths +417 to +549:** the lock.
- **Revocation does not loop.** SOURCE: `revokeCurator` reads and writes one slot. The benchmark revokes a curator
  holding ten allocations at about the cost of a freeze with one.

## 9. Remaining security assumptions and residual risks

- **Reserved capacity after revocation** stays in `Q_a` until someone releases each allocation (§4). Liveness only;
  bounded by `MAX_HORIZON`. A keeper is expected; LPs can do it themselves.
- **A freeze can delay LP exits** for up to `MAX_HORIZON`, like any live commitment, because frozen capacity stays
  reserved. Intended: freezing must never leave an allocation without backing after unfreeze.
- **The generation is not consumed on-chain yet.** Its guarantees (monotonic, no wrap, not restored by
  re-registration) are tested; that it actually invalidates signatures depends on 1B-2.3 checking it.
- **Owner trust.** The owner can unfreeze, register curators and raise ceilings; it cannot un-revoke. Multisig and
  timelock are still required before real value (`MAINNET_READINESS.md` G-1, G-2).
- **Guardian can permanently ban any address** (revoke is allowed for unregistered addresses). This is a
  risk-reducing power; the owner can register a different address.
- **Generation exhaustion** blocks deregistration and unfreeze for that curator; reaching it needs 2^32 − 1 calls.
- **Reentrancy model assumes canonical v4 ERC-6909** (no transfer callbacks) and a PoolManager that rejects nested
  `unlock`. Both are pinned-source facts, not checked on Unichain (`MAINNET_READINESS.md` D-3, D-4).
- **Read-only reentrancy.** Views (`admissibleCapacity`, getters, the lens) can be read from inside a deposit's token
  callback while `B_a` is ahead of the real claims. No on-chain contract may rely on vault views mid-transaction.
- **Functional suite builds** (D-6): only `test/bench/` runs production hooks and PoolManager.
- **Not run:** fork tests, Unichain gas, a longer invariant campaign than 256 × 128, trace-level gas attribution.

## 10. Differences from the specifications

| Spec | As built | Why |
|---|---|---|
| One `status` enum (`CURATOR_SECURITY_MODEL.md` §1) | `registered` + `restriction` | §1 |
| `revokeCurator` bumps generation (implied) | does not; deregisters instead | revocation must never fail on `GenerationExhausted`; a revoked curator can activate nothing anyway |
| `emergencyRelease` separate from `release` (`PHASE1B_THREATS_AND_PLAN.md` commit 4) | one `release` with reason precedence; `cancelAllocation` for curators | fewer entry points and bytes; same authorization table |
| D16 "no freeze check in `exchange`" (`CURATOR_REVOCATION.md`) | check present | superseded by `CURATOR_SECURITY_MODEL.md` §9 and this task |
| Lock on "every state-changing entry point except `unlockCallback`" (`MODULAR_RISK_ENGINE.md` §4.5) | ten accounting entry points; setters and `bumpGeneration` unlocked | they make no external calls and read no accounting |
| — | `fs_permissions` read-only on `./out` | needed to deploy production artifacts by path |
| ABI | removed `isCurator(address)` `6c7b79d4`; event `CuratorSet` → `CuratorUpdated`; `AllocationReleased` gains `CloseReason`; added `freezeCurator`, `unfreezeCurator`, `revokeCurator`, `bumpGeneration`, `cancelAllocation`, `getCurator` | no off-chain consumer exists (`script/`, `sdk/`, `frontend/` are placeholders) |
| Storage | slot 4: `mapping(address => bool) isCurator` → `mapping(address => CuratorRecord) _curators`; all other slots unchanged | nothing deployed |

## 11. Next action requiring approval

Review this step. 1B-2.2 (flow limits, exposure cap) and 1B-2.3 (EIP-712 authorization module) have not started and
need explicit approval. Decisions D18 and D21 are still open for 1B-2.2.
