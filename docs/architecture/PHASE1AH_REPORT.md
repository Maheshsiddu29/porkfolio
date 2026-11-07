# Phase 1A-H — Redemption Security Hardening: Report

**Status: PASS.** No fundamental redemption or solvency flaw was found. Two avoidable denial-of-service behaviours and
one access-control gap were reproduced with failing tests and then fixed. Two misleading views on an uninitialized
vault were also corrected. The FIFO head-of-line tradeoff remains and is documented, not eliminated.

- **Branch:** `phase-1a-h`, created from `phase-1a` at `cc4375a`. `phase-1a` is unchanged.
- **Environment:** same toolchain as Phase 1A: forge 1.7.1, solc 0.8.26 (via-IR), Slither 0.11.6.

## 1. Problems reproduced (each failed before its fix)

| # | Problem | Test (failure before fix) | Classification |
|---|---|---|---|
| A1 | A queue entry that free inventory can already serve, but that nobody has processed, blocks **every** instant exit until someone calls `processQueue` separately | `test_DOS_staleDeliverableEntry_doesNotBlockInstantExit` → `InsufficientLiquidity(1e22, 0)` | avoidable DoS |
| A2 | Inventory added by a deposit while the queue is pending is usable by nobody: the head is not served and the newcomer is fully queued | `test_interleaved_depositSwapCancelEmergencyRelease` → `head served first: 1 != 2` | avoidable DoS |
| C1 | `initialDeposit` was permissionless: any address could seed the vault and choose its basket ratio before the owner | `test_unauthorizedCallersCannotInitialize`, `test_ownershipTransfer_movesInitializationRight` → "next call did not revert" | access control |
| B1 | Uninitialized vault: `previewDeposit` reverted with the misleading `NoAssets`; `deliverableShares()` returned `type(uint256).max` | `test_uninitializedVault_viewsAndCallsNeverDivideByZero` → `NoAssets() != NotInitialized()` | incorrect view (no fund impact) |

Scenarios audited that behave as **intended** (they passed before and after the fixes):

- A small LP cannot create a queue entry while inventory exists (`test_INTENDED_smallLpCannotForceQueueWhileInventoryExists`).
- Queue-and-cancel cycles (20 cycles) keep the honest request's position. Each cycle raises pending demand, and so
  reduces curator capacity, by no more than the attacker's own pro-rata claim (`test_queueAndCancelCycles_boundedImpact`).
- FIFO bypass attempts fail: instant-only exit while the head is undeliverable; splitting into many requests;
  re-redeeming escrowed shares; claiming before finalization; a new allocation trying to take pending demand
  (`test_INTENDED_fifoBypassAttemptsFail`).
- A long queue is processed across multiple transactions in order (`test_processingAcrossTransactions_longQueue`).
- **Head-of-line (documented tradeoff).** A large partially-filled head absorbs all freed inventory. Requests and
  instant exits behind it wait, even when token0 is plentiful, because an in-kind exit needs both assets
  (`test_INTENDED_headOfLine_largePartialHead`). Under strict FIFO this is unavoidable and is **not** claimed to be
  eliminated. Avoiding it would need a different policy, such as pro-rata epochs (approved decision 2: keep FIFO).

## 2. Changes and rationale

| Change | Why it is the smallest defensible fix |
|---|---|
| `redeem`: if `P > 0`, first run up to `INLINE_QUEUE_STEPS = 4` steps of the FIFO queue, then apply the unchanged instant rule (instant only if `P = 0` afterwards) | Fixes A1 and A2 without changing ordering: earlier requests are finalized first, in the same transaction, at the same rate `processQueue` would use. It adds no state, parameter or bond, and the redeemer's extra gas is bounded by a constant. Alternative considered: allow instant exits from inventory in excess of `D_a`. Rejected because rounding makes it subtle (`D` can rise after an exit), and it adds nothing once deliverable entries are processed. |
| `initialDeposit` is `onlyOwner` | Fixes C1. The pair is already fixed in the constructor. The owner pays and assigns the initial shares to any receiver. `deposit` stays permissionless. Initialization can still run only once (`S ≥ M` afterwards). No governance or upgradeability added. |
| `previewDeposit` reverts `NotInitialized` when `S = 0`; `deliverableShares` returns 0 when `S = 0` | Fixes B1. Views only; no state change. |
| **Not changed:** no withdrawal bond, no minimum request size, no cancel cooldown | Per approved decisions 3 and 4. See §6 for the cost asymmetry that makes spam self-limiting, and why a share-denominated minimum would block small holders. |

## 3. Mathematical and accounting review (Tasks B and D)

**No equation changed.** Every relation was re-derived from raw sources and checked through arbitrary deposits,
swaps, queue operations, cancellations, claims, releases and donations:

- PoolManager ERC-6909 balances;
- request storage;
- allocation storage.

The relations checked:

```
B_a = PM.balanceOf(vault, a) − donated_a
W_a = Σ claimable_r,a
P   = Σ pending_r
Q_a = Σ_unreleased (maxOut − consumed)
N_a = B_a − W_a
F_a = N_a − Q_a
D_a = ⌈P · N_a / S⌉
admissible_a = max(0, N_a − Q_a − R_a − D_a)
N_0 + N_1 > 0 while S > 0
```

**Checked by:**

- `_assertEquations` after each step of the new adversarial tests.
- `invariant_equationsFromRawSources`.
- `invariant_actualBalanceMovementsMatchAccounting`, which checks every successful action:
  - real ERC-20 and ERC-6909 movements equal the accounting change;
  - `W_a` changes only through finalization and claims, so finalized claimable assets cannot be consumed by hooks or
    later allocations;
  - no allocation succeeds above the admissible capacity.

**New derivation: `N_0 + N_1 > 0` (`SHARE_ACCOUNTING.md` §10.1).**

- A trade adds at least 1 wei of input.
- A redemption cannot zero a positive balance, because `s < S` (the locked `MIN_SHARES` are never redeemable).
- So "both assets zero" is unreachable, and the `NoAssets` revert is defensive only.

**Zero-asset and dust behaviour.** Defined in `SHARE_ACCOUNTING.md` §10.2 and tested through the real PoolManager:

- one asset at zero (both directions);
- near-total depletion;
- requests rounding to zero, which are finalized at zero and not trapped;
- dust partial slices, which are not finalized;
- an emptied vault re-entering;
- an uninitialized vault.

**Economic loss vs accounting error.** In the depletion tests, a registered hook trades at a curator floor of 0. LPs lose
value, and pending shares share that loss. The pending demand `D_a` protects their *capacity*, not their *value*
(`test_pendingRequest_capacityProtected_valueSharesLoss`). The accounting identities hold throughout. The planned
independent bound on such losses is the Phase 1B minimum execution-price policy (approved decision 7).

## 4. Validation

```
$ forge fmt --check                                   → exit 0
$ forge build --force                                 → Compiler run successful; 5 forge-lint notes, all
                                                        block-timestamp (unchanged)
$ forge build --sizes                                 → SharedCommitmentVault runtime 20,034 B (was 19,368; margin 4,542)
$ forge test -vvv                                     → 12 suites, 137 passed, 0 failed (was 111)
    new: QueueGriefingTest 7, ZeroAssetStatesTest 8, InitializationTest 6, LpGasTest +3, invariants +2
$ FOUNDRY_PROFILE=ci forge test --match-test testFuzz → 5 fuzz tests × 10,000 runs, all pass
$ FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-contract VaultInvariants
                                                      → 10 invariants × 32,768 calls each, all pass
$ slither . --filter-paths "lib/|test/" --exclude-dependencies   → 19 results (was 21)
```

### 4.1 Invariant handler

The handler now has 12 actions: allocate, swap (three hooks), drain to zero through a 1:1 test hook, ERC-6909
donation, warp, release, deposit, redeem (weighted ×2), process, cancel and claim.

| Invariant | Status |
|---|---|
| `backingEqualsRealClaims` | donation-aware |
| `ghostLedgerConservation` | |
| `reservedIsExactAndBacked` | |
| `custodyAndSolvency` | donation-aware |
| `sharesAndQueueConserved` | |
| `noDoubleClaim` | now also records finalizations done inline by `redeem` |
| `fifoOrdering` | |
| `noDilutionByLpOperations` | |
| `equationsFromRawSources` | **new** |
| `actualBalanceMovementsMatchAccounting` | **new** |

Per-run logs across seeds `0x1`, `0x2`, `0x3` and `0x5eed` show queued, finalized, donated, drained and zero-asset
states being reached. `test_handler_makesProgress` reaches each of these deterministically.

### 4.2 Mutation check (manual, not committed)

Each mutation was applied alone and the full suite was run. The source was then restored byte-identical (`cmp`).

| # | Mutation | Result |
|---|---|---|
| H1 | remove inline queue processing from `redeem` | caught (2 tests: the reproduced DoS cases) |
| H2 | `initialDeposit` not owner-only | caught (3) |
| H3 | instant tier allowed while the queue is still pending after the inline step | caught (1) |
| H4 | queue skips a blocked head | caught (13) |
| H5 | finalize a partial head slice worth zero | **survived at first.** Added `test_dustPartialSlice_isNotFinalized`; now caught (1) |
| H6 | admission ignores pending demand | caught (7) |

### 4.3 Slither delta

- No new detector categories.
- `redeem` cyclomatic complexity rose from 15 to 16.
- The two `costly-loop` informational results disappeared only because the loop moved into the internal
  `_processQueue`. The loop is unchanged and still bounded by `maxSteps`, or by `INLINE_QUEUE_STEPS`.
- `arbitrary-send-erc20` (accepted in Phase 1A §7) is unchanged. The payer is always `msg.sender`, and
  `initialDeposit` is now also owner-only.

## 5. Gas, before (`cc4375a`) and after (HEAD)

**Method.** The same test file (`test/gas/LpGas.t.sol`, `GasBaseline.t.sol`) was run on a clean export of `cc4375a`
and on HEAD with `--isolate -vvvv`. Figures are the vault (or router) call frame, gross.

| Path | Before | After | Δ |
|---|---|---|---|
| `initialDeposit` | 233,907 | 233,934 | +27 |
| `deposit` (new LP) | 142,955 | 142,977 | +22 |
| `redeem`, fully instant | 154,218 | 154,335 | +117 |
| `redeem`, fully queued | 144,723 | 144,840 | +117 |
| `redeem`, partial instant + queued | 252,705 | 252,822 | +117 |
| `redeem` while the head is **blocked** (inline attempt, then queued) | 121,774 | 132,511 | **+10,737** |
| `redeem` while a **deliverable** request is pending | 121,774 (caller only queued; no payout) | 234,048 (finalizes the head **and** pays the caller instantly) | different outcome |
| `processQueue(1)` | 120,726 | 120,726 | 0 |
| `processQueue` over 10 canceled + 1 live | 144,856 | 144,856 | 0 |
| `claim` | 134,556 | 134,556 | 0 |
| `cancelRequest` | 38,681 | 38,681 | 0 |
| `allocate` | 274,622 | 274,622 | 0 |
| HookA swap (router frame, net) | 202,688 | 202,688 | 0 |
| HookB swap (router frame, net) | 202,597 | 202,597 | 0 |

Notes:

- In the deliverable case, the "before" path still needed a separate `processQueue` and `claim` before the caller
  received anything.
- The Phase 1A report's `initialDeposit` figure (243,507) came from a different fixture, where an LP paid instead of the
  owner. Both columns here use the same fixture.

## 6. Remaining known limitations

- **Head-of-line (FIFO).** A large head request absorbs freed inventory before anyone behind it. This is documented, not
  eliminated.
- **Inline processing is bounded at 4 steps.** With more than 4 deliverable entries ahead, a redeemer is still queued
  and must (or someone must) call `processQueue`. This is bounded, not eliminated.
- **Queue spam.**
  - Creating a request costs the spammer about 145k gas.
  - Finalizing one costs about 120k isolated (about 32k warm in a batch).
  - Skipping a canceled entry costs a few thousand gas (10 canceled + 1 live = 144,856, against 120,726 for one live
    alone).
  - Spam therefore costs the spammer more than it costs processors, and it cannot reorder the queue. No bond or
    minimum was added, per decision 3. A share-denominated minimum would need re-denominating as the basket changes and
    would block small holders.
- **Queue-then-cancel curator griefing.** Bounded by the griefer's pro-rata claim. No cooldown, per decision 4.
- **Near-total depletion is terminal in practice.** It can only happen through authorised trades at an extreme floor.
  The `int128` share cap then limits new value. The Phase 1B price policy is the intended control.
- **Unchanged from Phase 1A:**
  - Liveness needs `release` and `processQueue` callers.
  - Not audited, and nothing is formally verified.
  - Fee-on-transfer, rebasing and ERC-777 tokens are unanalysed.
  - No coverage, Echidna/Medusa or fork runs.

## 7. Can Phase 1B begin?

**Yes, from a redemption and solvency standpoint.** No unresolved accounting defect is known. Every Phase 1A-H problem
that was reproduced has a regression test, and the mutation check is fully caught.

**Prerequisite before any Phase 1B code (approved decision 7):** a written specification of the minimum execution-price
policy, covering:

- its units and decimal normalization;
- who can set or update it, and how updates affect live allocations;
- failure conditions, including stale or absent reference data.

It should be reviewed before implementation, because it is the only planned bound on the authorised-loss scenarios
in §3.
