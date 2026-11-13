# Porkfolio — G02: Governance and Withdrawal Liveness

**Status: see §11; closeout review in §13.** This document states what `VaultGovernor` and the vault's withdrawal queue guarantee about
governance changes and LP exits, where the two interact, and what an adversary can do at that interaction. Everything
here is derived from the code at the commits listed in §12, not from earlier phase reports; where an earlier report
said something different, §10 says so.

- **Branch:** `phase-2-g02-governance-liveness`, from `main` at `52fefdc` (the reviewed G01 head).
- **Toolchain:** Foundry 1.7.1 (`4072e48`), solc 0.8.26 (via-IR, cancun, `bytecode_hash = none`), Slither 0.11.6,
  Python 3.11.8, macOS (Darwin 25.2.0).
- **Labels.** PROVEN: a written argument under stated assumptions, plus tests. TESTED: checked by tests that exercise
  the path, no proof. MEASURED: a number from a recorded command. LIMIT: a known limitation, documented, not fixed.
- The master roadmap and task tracker are not in the repository. Scope comes from the G02 brief.

Notation follows the vault's NatSpec: per asset a, `B_a` backing, `Q_a` unused committed capacity, `W_a` finalized
and unclaimed, `N_a = B_a − W_a`, `F_a = N_a − Q_a` free inventory, `S` total shares, `P` pending (queued) shares,
`D_a = ceil(P·N_a/S)`, `R_a` buffer floor, `b` the vault-scope exposure cap (bps / 10,000). "Commitment" means an
allocation. "Deliverable" is `d = min_a floor(F_a·S/N_a)` (`_deliverableShares`, `VaultLens.deliverableShares`).

## 1. Actual lifecycles

### 1.1 Withdrawal request

| State (`VaultLens.requestStatus`) | Stored condition | Enters by | Leaves by |
|---|---|---|---|
| None | `lp == 0` | — | `redeem` with a remainder |
| Pending | `sharesPending > 0` | `redeem(…, queueRemainder = true)` when `shares > d` (or when `P ≠ 0` after the inline step) | finalization slices; `cancelRequest` |
| Pending, partly finalized | `sharesPending > 0`, `claimable > 0` | a slice smaller than the request; only the queue head can be in this state | further slices; `cancelRequest` (claimable part stays) |
| Claimable | `sharesPending == 0`, `claimable > 0` | last slice, or cancel after a partial slice | `claim` |
| Completed / Canceled | both zero | `claim` / `cancelRequest` with nothing claimable | terminal |

Transitions, from `SharedCommitmentVault`:

- **Request (`redeem`).** If `P ≠ 0`, process up to `INLINE_QUEUE_STEPS = 4` entries first. Pay an instant portion
  only if `P == 0` afterwards (no overtaking). The remainder is escrowed: it leaves `sharesOf` but stays in `S` and is
  added to `P`, so it keeps sharing gains and losses. Ids increase; FIFO is by id. A remainder whose basket rounds to
  zero in both assets reverts (`DustRedemption`).
- **Queue insertion** happens only in `redeem`. Nothing else creates a request.
- **Finalization (`processQueue`, permissionless, or the inline step).** From `queueHead`, each visited entry gets
  `s = min(sharesPending, d)` shares converted at `floor(s·N_a/S)`; `P` and `S` fall by `s`, `W_a` rises. Stops at a
  head that cannot be completed. A partial slice that rounds to zero is not taken. After finalization the amounts are
  fixed: `W_a` is outside `N_a`, so no later trade or configuration reaches them.
- **Claim** (request's LP only, paid to its `receiver`): `W_a` and `B_a` fall by the same amounts.
- **Cancel** (request's LP only): pending shares return to `sharesOf`; claimable amounts stay claimable.
- **What can hold a request:** only `d`, i.e. `Q_a` relative to `N_a`. Pause, direction halts, curator freeze or
  revocation, flow caps, exposure caps, the buffer floor and the oracle are not read on any of these paths
  (`invariant_lpPathsIndependentOfAdapter`, G01; `test_oracleFailure_doesNotHoldTheQueueOrGovernance`).

### 1.2 Commitment (allocation)

| State | Condition | Enters by | Leaves by |
|---|---|---|---|
| Live | `!released`, `now < expiry` | `reserveFor` (module only; expiry ≤ now + `MAX_HORIZON` = 30 days) | expiry; `cancelAllocation`; `release` |
| Expired, unreleased | `!released`, `now ≥ expiry` | time | `release` (anyone) or `cancelAllocation` |
| Closed | `released` | `_close` | terminal |

- **Admission** (`reserveFor`): `Q_a + q + R_a + D_a ≤ N_a`, and each scope's `(held + q)·10⁴ ≤ bps·(N_a − D_a)`. The
  `D_a` term is what keeps a new commitment off the queue's pro-rata claim.
- **Expiry is lazy.** An expired commitment holds its `Q_a` until someone calls `release`. A queued request waiting
  behind it stays pending until then (`test_oneShare_holdsLongChange_whileFullyCommitted`).
- **Release** is permissionless after expiry or once the curator is revoked; before that only the owner or guardian
  (emergency). **Cancel** is the curator's, at any time, in any state, including while paused.
- **Consumption** lowers `Q_out` and `B_out` by the same amount, so `F_out` does not change.

### 1.3 Governance operation (`VaultGovernor`)

| State | Condition | Enters by | Leaves by |
|---|---|---|---|
| Unqueued | `eta[id] == 0` | — or after execute / cancel | `queue` (admin) |
| Waiting | `now < eta` | `queue`: `eta = now + delayFor(target, data)` | `cancel` |
| Executable | `eta ≤ now ≤ eta + GRACE` | time | `execute` (admin); `cancel` |
| Expired | `now > eta + GRACE`, record still set | time | `cancel` only (`queue` → `AlreadyQueued`, `execute` → `NotExecutable`) |

- `id = keccak256(abi.encode(target, data))` binds target, selector and every byte of calldata.
- `queue`: admin only; target is the vault or a hook whose `hookOwner()` is this governor and whose `vault()` is the
  vault (checked once, at queue time); refuses a duplicate id.
- `execute`: admin only, inside the window. For a LONG_DELAY call it reverts with `PendingWithdrawals(P)` while
  `vault.pendingShares() ≠ 0`. The record is deleted before the call; a reverting target reverts the whole
  transaction and leaves the change queued.
- `cancel`: admin, or the vault's live guardian for any call except the vault's `setGuardian`.
- Delay classes after this milestone (selector-based; `test_delayClass_everyVaultFunction` pins all 69 vault functions):

| Class | Calls | Extra execution rule |
|---|---|---|
| LONG_DELAY (32 d proposed) | vault `setInventoryBounds`; vault `transferOwnership(n)` with `n ≠ 0` (or calldata too short to hold `n`) | `pendingShares == 0` at execution |
| DELAY (3 d proposed) | every other vault call, including `transferOwnership(address(0))`; every hook call | none |
| GRACE (7 d proposed) | window after eta for both classes | — |

### 1.4 Guardian emergency actions (vault, immediate, cannot loosen)

Pause; revoke a consumer; deregister, freeze or revoke a curator; lower a curator ceiling; tighten a configured risk
limit (including a vault-scope exposure cap of 0); raise a buffer floor (up to `type(uint256).max`); raise a set sell
floor; halt a direction; retire the authorization module (permanent); raise the edge or lower the uncertainty bound;
raise a target or lower a tolerance (`setInventoryBounds`); emergency `release`. On the governor: cancel any queued
change except its own replacement. Every one of these is available while LPs are queued.

### 1.5 Ownership and guardian replacement

- **Vault owner.** Two-step: `transferOwnership(n)` sets `pendingOwner`; `n` calls `acceptOwnership`. Under the
  governor, a non-zero nomination is LONG_DELAY with the queue check; withdrawing a nomination
  (`transferOwnership(address(0))`) is DELAY (changed here, §6). The governor accepts a hand-over to itself with
  `acceptVaultOwnership` (admin, immediate: it only adds delays). The nominee's `acceptOwnership` is a vault call the
  governor never sees.
- **Guardian.** `setGuardian` is DELAY and cannot be canceled by the guardian it replaces. The right to cancel follows
  `vault.guardian()` live: it moves in the block the replacement executes; with no guardian only the admin cancels
  (`test_guardianReplacement_movesTheCancelRight`).
- **Governor admin** and **hook owners** are immutable. Rotating either means a new governor (LONG_DELAY hand-over)
  and, for hooks, new hook deployments.

### 1.6 Every point where a pending withdrawal or a commitment affects governance

1. `execute` of a LONG_DELAY call reverts while `P ≠ 0`, whatever its direction (tightening via the governor too).
2. Whether the admin's batch can make `P = 0` depends only on commitments: `processQueue` finalizes exactly the
   deliverable prefix of the queue.
3. Expired, unreleased commitments still hold inventory; the batch must release them first.
4. A change refused through its whole window expires and needs `cancel` + `queue`, i.e. a fresh LONG_DELAY.
5. A partly finalized head still counts: `P` includes its remainder (`test_partialFulfillment_blocksWithExactRemainder`).
6. The check binds at nomination execution, not at the nominee's acceptance (§3, C5).
7. Before this milestone, withdrawing a nomination was also held by queued LPs (C4, fixed).
8. In the other direction, queued shares lower admissible capacity for curators by `D_a`; this is what makes the
   per-request bound L-1 hold.
9. Nothing else: DELAY-class calls, hook calls, guardian actions and cancellation never read the queue.

## 2. Security properties

| # | Property | Status | Evidence |
|---|---|---|---|
| S-1 | **Existing LP withdrawal rights are not silently weakened.** (a) Finalized amounts never change. (b) The inventory floor of a queued request cannot be lowered while it is queued: `setInventoryBounds` is LONG_DELAY and refused while `P ≠ 0`. (c) New commitments cannot take a queued request's pro-rata inventory. (d) No pause, halt, freeze, flow limit, exposure cap or oracle state blocks exit paths | TESTED, (c) PROVEN (§4) | `invariant_S1_noLongChangeWithQueuedShares`; G01 `invariant_Q2_queuedRequestsKeepTheirProtection`, `invariant_lpPathsIndependentOfAdapter`; `test_delayClass_directionAtQueueTimeIsNotDirectionAtExecution`; L-1 invariant |
| S-2 | **No delay can be bypassed.** Every executed call was queued at least its class delay earlier, runs inside its window, at most once, only to its queued target with its queued calldata | TESTED | `invariant_S2_delaysAndWindowsHold` (checked against an independent class table); 1B-4.4 tests G4–G12; `test_targetCodeReplacedAfterQueue_gainsNothing` |
| S-3 | **Risk-increasing changes follow fixed rules.** Loosening the inventory floor and handing ownership elsewhere: LONG_DELAY + empty queue at execution. Every other loosening (adapter, edge, uncertainty bound, sell floors, ceilings, caps, buffer, unpause, resume, registrations, module, hook pricing): DELAY. The class depends only on the selector (and, for `transferOwnership`, on whether the argument is zero), never on the current state | TESTED | `test_delayClass_everyVaultFunction`, `test_nominationRetraction_onlyACleanZeroWord` |
| S-4 | **Emergency tightening stays available.** All guardian levers are immediate and unaffected by the queue. Through the governor, every tightening except `setInventoryBounds` is DELAY and not queue-gated; a nomination can be withdrawn after DELAY whatever the queue | TESTED | `test_guardianTightening_isImmediate`, `test_restrictingNewCommitments_endsBlockingWithinMaxHorizon`, `test_nominationRetraction_waitsDelay_notHeldByQueuedLps` |

Qualifications of S-1 (each a LIMIT, §7): DELAY-class changes do apply to queued LPs, bounded by the unchanged
inventory floor, which only exists once `tau_a` is configured; an LP who queues after a nomination executed is not
protected from a non-timelock nominee; an older queued absolute value can undo a guardian tightening.

## 3. Counterexamples (each reproduced by a deterministic test)

| # | What happens | Test |
|---|---|---|
| C1 | With the fixture's limits (`b = 100%`, `R_a = 0`) an honest curator commits all free asset0. One share, bought for 1 raw unit of each asset **before** the commitment, is queued behind it and holds a LONG_DELAY change at eta. The change executes once the commitment expires and the batch releases it; without the release, the expired commitment still blocks | `test_oneShare_holdsLongChange_whileFullyCommitted` |
| C2 | A registered curator that is also an LP blocks a LONG_DELAY change for as long as it keeps rotating: cancel, re-commit everything admissible, queue one share, in one transaction. Refused at eta, mid-GRACE and at the window's last second, through three windows and two re-queues (115 days, 10 rotations). An honest LP queued behind the first commitment is finalized at the first rotation, 9 days later | `test_curatorLpCoalition_blocksLongChangeWhileRotating` |
| C3 | With `b = 50%` and every allowed unit committed, `d = S/2` exactly. A holder of `d` shares redeems all instantly and nothing is queued; `d + 1` leaves exactly one share queued, which blocks | `test_exposureCap_setsCapitalNeededToHoldTheQueue` |
| C4 | (fixed) Withdrawing a nomination waited LONG_DELAY and was refused while an LP was queued; the nominee accepted meanwhile | commit `ec26e8b`, `test_nominationRetraction_isHeldLikeATransfer` (replaced in `f2419cc`) |
| C5 | A nomination executes with the queue empty; an LP queues 20 days later; the non-timelock nominee accepts and sets the floor to zero while that LP is queued | `test_nomineeAcceptingLate_isNotHeldByLaterQueuedLps` |
| C6 | An edge raise queued at 150 pips executes after the guardian raised the edge to 300, taking it back to 150. Canceling the queued call prevents it | `test_olderQueuedValue_undoesGuardianTightening_unlessCanceled` |
| C7 | A `setInventoryBounds` that tightens at queue time (5% → 4%) loosens at execution after the guardian tightened to 2%. Classified by direction it would have run after DELAY with an LP queued; by selector it is held | `test_delayClass_directionAtQueueTimeIsNotDirectionAtExecution` |
| C9 | Governance stops new commitments at eta, after a commitment made one second earlier. That commitment outlives `eta + GRACE`, so the original change is refused through its whole window and expires. Cancel + re-queue executes at the new eta; an emergency release executes the original in the same block. The lever deadline for the original is exactly `queuedAt + 9 days` | `test_leverAfterEta_originalExpires_recoveryPaths`, `test_leverDeadline_isQueueTimePlusNineDays` |
| C10 | After a nomination executes, the nominee accepts one second before the retraction's eta. The guardian can neither retract (no ownership power) nor cancel (the nomination already executed); the retraction then fails with `NotOwner` | `test_pendingNominee_canAcceptDuringRetractionDelay` |
| C11 | The guardian cancels the canonical copy of a conflicting edge raise; a copy with one trailing byte stays queued and undoes the tightening. `CheckQueuedConflicts` flags the copy | `test_guardianCancellation_missesAPaddedCopy_conflictCheckFindsIt` |
| C8 | The code at a queued hook-like target is replaced after queuing. Execution calls it; it cannot use the governor's identity (every vault and governor call it tries reverts). With no code left, `execute` "succeeds" and emits `Executed` | `test_targetCodeReplacedAfterQueue_gainsNothing` |

Orderings checked without a counterexample: deliverable requests (a stale one and five new redemptions from different
accounts) submitted just before the batch are all served by it; a partly finalized head blocks with its exact
remainder; an oracle outage stops fills but not finalization, claims or the LONG_DELAY change; 100 accounts queuing one
share each are all cleared by one batch.

## 4. Liveness properties

**L-1 (per request). PROVEN under the vault's own accounting; TESTED.** A pending request can be held only by
commitments that existed when it was queued. Once each of those is closed (all are expired at most `MAX_HORIZON`
after the request, and anyone may then release them), `processQueue` (permissionless) finalizes the queue up to and
including that request.

*Argument.* Let `X` be the pending shares of the requests queued before every live commitment was created (a prefix
of the queue). It is enough to show `F_a·S ≥ X·N_a` for each asset, since then `d ≥ X`.
- An asset with no live commitment has `F_a = N_a`, so `d_a = S ≥ X`.
- Otherwise take the most recent live commitment in that asset. At its creation, admission gave
  `F_a ≥ R_a + D_a ≥ P·N_a/S ≥ X·N_a/S`.
- Every later operation preserves `F_a·S ≥ X·N_a`:
  - fills: `F_out` unchanged, `N_out` falls; `F_in` and `N_in` rise by the same `x`, and `x·(S − X) ≥ 0`;
  - deposits of σ shares paying `δ = ceil(σ·N_a/S)`: the difference grows by `F_a·σ + δ·(S − X) + δ·σ ≥ 0`;
  - claims: `N_a` unchanged; cancellations and other closes: `X` falls or `F_a` rises; new requests: not in `X`;
    instant redemptions: only when `P = 0`, so `X = 0`; later commitments: not possible, the chosen one is the most
    recent;
  - finalizing `s` prefix shares with `e = floor(s·N_a/S) ≤ s·N_a/S`: the difference becomes
    `(N_a − e)(S − X) − Q_a(S − s)`, which is `≥ 0` because `N_a(S − X) ≥ Q_a·S` and `(N_a − e) ≥ N_a(S − s)/S`;
  - a newer request is finalized only after the prefix is empty (FIFO), when `X = 0`.

The campaign checks the statement after every call (`invariant_L1_requestsHeldOnlyByOlderCommitments`), with `w(a)`
recorded as the next request id at the start of the call that created commitment `a`.

**L-2 (LONG_DELAY change). PROVEN from L-1; TESTED.** If no commitment has been created since time `T` (any guardian
lever in §1.4 that blocks `reserveFor`: buffer floor at the maximum, vault-scope cap 0, pause, or deregistering the
curators), then at any time `≥ T + MAX_HORIZON` inside the change's window the batch *release expired → processQueue →
execute* succeeds. Every commitment created before `T` has expired and is released by the batch, none was created
after `T`, so `Q_a = 0`, `F_a = N_a` and the whole queue is deliverable; inside the one transaction nobody can add a
request. With an emergency release of every live
commitment plus a lever, the same holds in one block. Checked by `invariant_L2_longChangeExecutesOnceCommitmentsAreStopped`
and by `test_restrictingNewCommitments_endsBlockingWithinMaxHorizon` (all four levers) and
`test_emergencyRelease_endsBlockingInOneBlock_onlyWithARestriction`.

Because LONG_DELAY (32 d) exceeds `MAX_HORIZON` (30 d), applying a lever when the change is queued makes it executable
at eta.

**L-2 recovers governance, not necessarily the queued operation** (closeout, §13.1). The original operation is
guaranteed to execute only if the lever is applied no later than
`queuedAt + LONG_DELAY + GRACE − MAX_HORIZON` (9 days after queuing with 32 / 7 / 30 days): every commitment made
before the lever must expire inside `[eta, eta + GRACE]`. Applied later, a commitment made just before the lever can
outlive the window and the original expires (C9). Governance still recovers, by either of:
(a) cancel and re-queue as soon as the lever is on; the fresh LONG_DELAY exceeds `MAX_HORIZON`, so it executes at its
new eta, provided the lever stays on until then; (b) an emergency release of the live commitments while the lever is
on, which lets the original execute in the same block. Neither weakens any LP's protection: in both, every queued
request is finalized under the old values first.

**L-3. Not guaranteed: LONG_DELAY liveness while new commitments are allowed.** C2 holds a change indefinitely. §5
quantifies it.

**L-4. DELAY-class changes** never depend on the queue: executable anywhere in their window.

**L-5. No unconditional withdrawal availability.** A request is legitimately held by commitments that predate it, for
up to `MAX_HORIZON` plus the time until someone calls `release`, and by strict FIFO behind larger head requests. The
guarantee is L-1, not immediacy.

## 5. Can an attacker block a governance operation indefinitely?

**Yes, conditionally, and only LONG_DELAY changes.** Requirements, from §4 and the tests:

| | Single-shot (lasts ≤ `MAX_HORIZON`) | Sustained (indefinite) |
|---|---|---|
| Permission | none | a registered curator with a ceiling and configured limits (granted by governance), or an LP that back-runs every honest commitment (not demonstrated) |
| Capital (shares held **before** the commitment) | more than `max((1 − b)(S − P), R_a·S/N_a)` on the most committed asset: at `b = 100%`, `R_a = 0` one non-dust share (C1); at `b = 50%` more than half the non-queued supply (C3) | the same amount, re-queued after every rotation; finalized shares come back as assets that can be re-deposited in the same transaction |
| Transactions | one redemption: 102,639 gas (MEASURED, test build of the vault = production settings) | one rotation (cancel + re-commit + queue) before each commitment expires: 418,369 gas (MEASURED) |
| Condition | curators have committed close to the cap at the moment of queuing | as long as governance allows new commitments |

Why a fresh deposit does not work: depositing `x` shares adds `x·N_a/S` to both `N_a` and `F_a`, so `d` rises by
exactly `x` and those shares redeem instantly (`test_sharesBoughtAfterCommitment_redeemInstantly`).

Queue flooding: with 100 accounts, the attacker pays 79,014 gas per request and the admin 28,536 gas per finalized
entry (MEASURED); one `processQueue(100)` clears them. Flooding adds cost, not blocking.

**Impact.** A held change is a LONG_DELAY change: an inventory-floor change (usually a loosening) or a non-zero
nomination. No LP asset is at risk, no delay is shortened, and every tightening path (§1.4, S-4) stays open. A held
change is delayed, not lost: it may expire after GRACE (C9), and it can then be canceled and re-queued with a fresh
LONG_DELAY (§13.1).

**Response, in order of cost.** (1) Freeze, revoke or deregister an identified coalition curator (immediate). (2) Apply
a lever that stops new commitments when queuing the change; it then executes at eta (L-2); the cost is no new
commitments for up to 30 days. (3) Lever plus emergency release of the live commitments: executable in the same block;
the cost is breaking those commitments to their hooks. (4) Prevention: deploy with `b ≤ 50%` (the deployment script's
default is 5,000 bps) and a non-zero `R_a`, which raises the single-shot capital to half the vault.

## 6. Corrections

**Implemented: nomination withdrawal is DELAY and not queue-gated** (`f2419cc`). `_isLong` now treats
`transferOwnership` as LONG_DELAY unless its argument word is present and zero. A dirty address word or short
calldata stays LONG_DELAY and is rejected by the vault's ABI decoder; bytes after a zero word are ignored by the vault
(`test_nominationRetraction_onlyACleanZeroWord`). Justification: C4 — a right-removing call was held to the
strictest rule, and through C2's griefing could be held indefinitely while the nominee kept the right to accept. The
withdrawal cannot shorten a real transfer (`test_nominationRetraction_doesNotShortenATransfer`).

Effect, production artifacts (`test/bench/ProductionArtifactGas.t.sol`, `--isolate`):

| | Before | After |
|---|---|---|
| `VaultGovernor` runtime / init (bytes) | 4,111 / 4,567 | 4,152 / 4,608 |
| `SharedCommitmentVault` runtime | 22,440 | 22,440 (byte-identical; 2,136 B under EIP-170, 88 B above the 2,048 B target) |
| hooks, lens, module | — | byte-identical |
| `queue` setPaused / setInventoryBounds / transferOwnership(0) | 49,775 / 55,675 / 54,263 | 49,781 / 55,674 / 54,336 |
| `execute` setPaused / setInventoryBounds / transferOwnership(0) | 40,391 / 109,497 / 44,124 | 40,396 / 109,497 / 41,524 |

Governor ABI unchanged; storage unchanged (one mapping, §8.1).

**Documentation in `src/`.** The governor's NatSpec now states that the delay class follows the selector, that a
re-committing curator can hold LONG_DELAY changes until new commitments are stopped, and that the queue check binds at
nomination, not acceptance.

**Rejected or deferred alternatives.**

| Alternative | Why not now |
|---|---|
| Queue check only for requests older than the change (governor records `nextRequestId` at queue time; requires `queueHead` past it) | Unconditional LONG_DELAY liveness (old requests are free within `MAX_HORIZON < LONG_DELAY`), but LPs who queue more than `LONG_DELAY − MAX_HORIZON` = 2 days after the announcement lose their floor protection. A weakening of LP protection: owner decision (R-9) |
| Cap new commitments' expiry at an outstanding LONG_DELAY change's eta (vault admission) | Gives L-2 without stopping new commitments. Needs vault storage and an admission change: architectural review; natural fit for the time-bounded commitment work (R-10) |
| Per-request floor snapshot | Vault accounting change; rejected in 1B-4.4 for the same reason |
| Classify by direction of the change | Unsound: C7 |
| Queue check at the nominee's acceptance | Acceptance is a vault call; needs a vault change. Release rule instead: nominate only a reviewed governor and accept in the same transaction |
| Immediate (undelayed) nomination withdrawal | Breaks the rule that every owner call waits; DELAY suffices |
| Minimum request size or queue length cap | Would restrict LP exits; flooding already costs the attacker more than the admin |
| Make emergency release the standard procedure | Breaks commitments to hooks; kept as the emergency path |

## 7. Exact limitations

1. **LONG_DELAY liveness is conditional** (L-3, §5). Restoring it costs either a pause in new commitments of up to
   `MAX_HORIZON` or breaking live commitments.
2. **DELAY-class changes reach queued LPs.** Adapter, edge, uncertainty bound, sell floors, hook pricing and the rest
   apply to shares still queued. The bound is the inventory floor, which a DELAY change cannot lower. In static mode
   with `tau_a = 0` there is no inventory floor and the sell floor, a DELAY-class setting, is the only price bound.
   Recommended release rule (not in the checklist yet): configure `tau_a` before LPs are admitted.
3. **Nomination vs acceptance** (C5, C10). After a nomination executes, a non-timelock nominee can accept at any time,
   including during the DELAY of a retraction, and LPs who queue later have notice (`pendingOwner` is public) but no
   protection. A reviewed-governor nominee keeps both the timelock and the queue check after a late acceptance
   (`test_reviewedGovernorNominee_acceptingLate_keepsTheTimelock`). Release rule and gate 12: nominate only a reviewed
   governor; accept in the nominating transaction where both governors share the admin.
4. **Absolute values** (C6, C11). An older queued call can undo a guardian tightening after its own delay. The governor
   does not detect this; the design relies on explicit cancellation, checked by `CheckQueuedConflicts` after every
   guardian action and before every `execute` (§13.3).
5. **Target check at queue time only** (C8). Execution to an address whose code changed, or that has none, is not
   detected; it gains no authority, but `Executed` is emitted. Monitors decode target and calldata.
6. **Tightening the inventory floor through the governor** is LONG_DELAY and queue-gated (by selector, C7). The
   immediate path is the guardian; without a guardian, appointing one is DELAY and not cancellable by anyone but the
   admin.
7. **Trailing calldata** gives one effect several ids (1B-4.4 G15, unchanged); each waits its full delay.
8. **The admin's batch must be atomic** (release, process, execute). With an EOA admin, a deliverable queue can still be
   emptied, but an attacker meeting §5's capital condition can insert a request between transactions. With mainnet
   delays, `VerifyDeployment` gate 2 requires the admin to be a contract (closeout, §13.4); that it actually batches is
   procedural.
9. **Governor admin and hook owners cannot be rotated** (1B-4.4 G19, unchanged).
10. **Deployment values decide exploitability.** The test fixtures use `b = 100%`. The deployment script defaults to
    `b = 50%` and, since the closeout, a buffer floor of 10% of the seed; `VerifyDeployment` gate 9 requires both to
    equal the reviewed values and the floor to be non-zero. The vault itself enforces neither.
11. **A blocked LONG_DELAY change can expire** (C9) if the levers come more than `LONG_DELAY + GRACE − MAX_HORIZON`
    after queuing. Recovery is cancel + re-queue or an emergency release (§13.1).

## 8. Validation

### 8.1 Commands and results

| Command | Commit | Result |
|---|---|---|
| `forge test` (default profile), before any change | `52fefdc` | 584 passed, 0 failed, 8 skipped (fork tests, no RPC); matches G01 |
| `forge test` (default profile) | `8241124` | **619 passed, 0 failed, 8 skipped**, 20 s. +35: 11 liveness scenarios, 11 integrity tests, 1 governor bench, 5 + 6 tests of the new campaign and its scripted subclass, 1 inventory regression |
| `forge fmt --check` | `8241124` | clean |
| `bash test/bench/security.sh` (CI profile: fuzz 10,000, invariants 128 × 128) | `439af7e` | exit 0, 7 min. Size gate passed (vault margin 2,136 B, governor 4,152 B); production-build checks 3 + 25 passed; suite 618 passed, 0 failed, 8 skipped; the new campaign's invariants `runs: 128, calls: 16384, reverts: 0` |
| `bash test/deep.sh` (deep profile), first run | `439af7e` | **failed at step 2**: 617 passed, 1 failed. `invariant_Q2_queuedRequestsKeepTheirProtection` in the G01 inventory campaign. Diagnosed as a checker artifact (§8.2), fixed in `8241124` |
| `bash test/deep.sh` (deep profile), rerun | `8241124` | **exit 0, 27 min.** Suite 619 passed, 0 failed, 8 skipped; all **58 invariant campaigns `runs: 1000, calls: 256000, reverts: 0`** (48 from G01 plus the new 5 + 5); fuzz 10,000 runs; seeds `0x1`, `0x2`, `0x3` at 256 × 128: 49/49 each; coverage gate passed for all four campaigns; Python 46 + 22 OK; fork step skipped by the script (no RPC); Slither 59 results |
| `UNICHAIN_RPC_URL=https://mainnet.unichain.org UNICHAIN_FORK_BLOCK=63689000 forge test --match-path "test/fork/*" --isolate -vv` | `8241124` | 8/8 passed. Read-only public RPC, no key; responses may come from Foundry's RPC cache. The fork tests do not exercise the governor; run because the full suite skips them |
| `python3 test/invariant/coverage.py --campaign liveness --seed-base {13,101,4001,65537}` | `439af7e` | gates set from these four families (§8.3) |
| Mutation run (§8.4) | `439af7e` | 12/12 killed |
| `forge inspect …VaultGovernor storageLayout` after the forced rebuild | `439af7e` | one slot: `eta` mapping at slot 0, as before |
| Production artifact comparison against `52fefdc` | `f2419cc` | vault, both hooks, lens and module runtime and init code byte-identical; governor ABI identical, bytecode changed (§6) |

### 8.2 The deep-profile finding

The first deep run found a violation of `invariant_Q2_queuedRequestsKeepTheirProtection` (G01's inventory campaign),
shrunk to 19 calls. Replaying them deterministically:
- The violation is recorded during a `claim`, which cannot finalize anything.
- The 18th call (`governedLoosen` with a late LP) queues a request and finalizes part of it inside one call. The
  handler checked slices only for requests pending when a call started, so that slice was left for the next call.
- The 19th call claimed the request first, zeroing its claimable amount, and the late check then saw a slice that
  paid nothing.
- Replacing the claim with a step that does not claim, the same slice is checked and passes. The vault's payouts were
  correct.

This is the mechanism G01 §12.2 described for the second unit of tolerance, reached through a claim this time. The G02
code changes did not cause it. Changed bytecode changes the fuzzer's dictionary, so the deep run explored a different
path. Fix (`8241124`, test code only): `governedLoosen` checks every tracked slice right after its `processQueue`.
The 19 calls are kept as `test_handler_claimAfterSameCallSlice_isNotAViolation`, which fails without the fix. The
2-unit tolerance is unchanged; whether one unit now suffices was not re-measured.

### 8.3 Non-vacuity of the new campaign

`GovernanceLivenessInvariantsTest` is gated by `test/invariant/coverage.py` with the G01 method. Each gate is at least
four binomial standard deviations (64 seeds) above the worst zero-run fraction over seed bases 13, 101, 4001 and
65,537, except `longBlocked` (worst 0.80; four deviations would be 1.0, so the gate is 0.98, 3.6 deviations).
Measured in the deep run (base 13):

| Counter | Zero-runs | Gate | Counter | Zero-runs | Gate |
|---|---|---|---|---|---|
| commitsOk | 0.00 | 0.10 | longExecuted | 0.05 | 0.45 |
| depositsOk | 0.00 | 0.20 | longBlocked | 0.80 | 0.98 |
| swapsOk | 0.03 | 0.15 | restrictedExecutions (L2 cases) | 0.36 | 0.85 |
| queuedOk | 0.36 | 0.60 | rotationsOk | 0.00 | 0.10 |
| finalizedOk | 0.09 | 0.30 | preEtaRotations | 0.52 | 0.80 |
| prefixChecks (L1 with a non-empty prefix) | 0.05 | 0.20 | expiredOps | 0.53 | 0.80 |
| execAttempts | 0.03 | 0.35 | otherFailures | must be 0 in every run | — |

Thin spots, stated plainly: a blocked LONG_DELAY attempt occurs in only one run in five, and an L2 case in about two
in three. Both are reached deterministically by `test_handler_reachesEveryBranch` and by the scenario tests. Two
handler defects found while measuring were fixed before the gates were set: the LPs started without shares, and
the coalition helper tried to cancel commitments that were already released, which made every later rotation revert.

### 8.4 Mutation testing

Hand-picked, as in G01: no mutation tool is installed. Each mutant was applied to `src/`, the full fast suite was run,
and the file restored (`git diff --quiet -- src` checked after each). Persisted fuzz and invariant failures were
redirected outside the repository.

| # | Mutation | Result | Killed by (selection) |
|---|---|---|---|
| GM1 | nomination withdrawal LONG again (pre-fix) | killed, 3 tests | the three retraction tests |
| GM2 | non-zero nominee classified DELAY | killed, 6 | `test_delayClass_everyVaultFunction`, `test_ownershipEscape_waitsLongDelayAndQueue` |
| GM3 | short-calldata guard removed | killed, 1 | `test_nominationRetraction_onlyACleanZeroWord` |
| GM4 | queue check removed | killed, 17 | coalition, exposure-cap, expiry and migration scenarios; campaign scripted test |
| GM5 | GRACE expiry removed | killed, 2 | `test_expiry_afterGrace`, `test_expiredOperation_requeueStartsAFullDelay` |
| GM6 | guardian may cancel its own replacement | killed, 2 | `test_cancel_roles`, `test_guardianReplacement_movesTheCancelRight` |
| GM7 | record kept after execution (replay) | killed, 24 | `test_delay_window_replay_andEvents` and others |
| GM8 | inventory-floor setter classified DELAY | killed, 24 | delay-class and queue-check tests |
| VM1 | admission ignores `D_a` | killed, 19 | **`invariant_L1_requestsHeldOnlyByOlderCommitments` (shrunk to two rotations)**, coalition test, G01 queue tests |
| VM2 | release after expiry no longer permissionless | killed, 50 | the batch scenarios and G01 lifecycle tests |
| VM3 | new commitments allowed while paused | killed, 7 | `test_restrictingNewCommitments_endsBlockingWithinMaxHorizon`, pause tests |
| VM4 | admission ignores the buffer floor | killed, 17 | both lever scenarios, `invariant_equationsFromRawSources` |

GM5 is not caught by the campaign (its handler cancels expired changes before attempting them); deterministic tests
catch it.

### 8.5 Static analysis

Slither 0.11.6: 59 results, the same count as G01 and 1B-4.4. Not re-triaged as a whole. The governor's findings were
read: an event emitted after the external call in `execute` (the record is deleted before the call and every re-entry
path is admin-only), timestamp comparisons (the delay window), assembly (revert-data pass-through) and low-level calls
(the governed call and the target check). All by design; none is new in kind.

### 8.6 Not run, and limits of this validation

- **No independent review or formal verification.** The L-1 argument (§4) is a hand proof checked by a campaign, not
  a machine-checked proof.
- **Mutation testing is hand-picked** (12 mutants), not a mutation score.
- **The new campaign runs in static mode** (no adapter) with one coalition and two honest curators. Oracle faults are
  covered by the G01 inventory campaign and one deterministic test here.
- **Gas figures** for queuing, rotation and flooding come from test builds. The vault is compiled with its production
  settings there, but the PoolManager is not. Governor gas is from the production artifact.
- **Back-running every honest commitment** (the curator-free sustained attack) is argued, not demonstrated.
- **No testnet run.** Nothing was broadcast.
- **The CI-profile suite ran at `439af7e`.** The later commit changed only the inventory test handler, and the deep
  run covers it under a stronger profile.

## 9. Files changed

`src/governance/VaultGovernor.sol` (the correction and NatSpec); new tests
`test/governance/GovernanceLiveness.t.sol`, `test/governance/GovernorIntegrity.t.sol`,
`test/invariant/GovernanceLivenessInvariants.t.sol`, `test/utils/GovernanceActors.sol`; governor benchmark in
`test/bench/`; `test/invariant/coverage.py` (liveness campaign and gates); `test/deep.sh` (campaign added to the
extra-seed step); `test/invariant/InventoryProtectionInvariants.t.sol` (§8.2); this document;
`docs/architecture/GOVERNANCE_SECURITY.md` (§3.3 corrected, G20 added). Closeout (§13): tests in the two governance
files and `test/script/DeployScripts.t.sol`; `script/CheckQueuedConflicts.s.sol` (new); `script/DeploySystem.s.sol`,
`script/VerifyDeployment.s.sol`, `script/README.md`; `docs/architecture/MAINNET_READINESS.md` (G-6 … G-11, C-4);
`GOVERNANCE_SECURITY.md` (G21 … G23).

## 10. Corrections to earlier documents

- `GOVERNANCE_SECURITY.md` §3.3 said blocking needs "pending shares above `1 − b` of supply" and that the guardian can
  release the commitments. Both are right for a single shot at `b ≤ 50%`, but the text did not cover the curator-LP
  coalition, which sustains blocking indefinitely (C2), and at `b = 100%` the threshold is one share (C1). Corrected
  there with a pointer here.
- G01 §8 described queue-check griefing as delaying a loosening "up to `MAX_HORIZON` absent griefing". With a
  coalition curator there is no such bound until new commitments are stopped (L-2, L-3).

## 11. G02 result

**PASS, with one conditional liveness property stated rather than solved.**

- **Lifecycle** modelled from the code (§1). Every point where the queue or a commitment affects governance is listed
  (§1.6).
- **Griefing.** Investigated in nine orderings. Indefinite blocking of a LONG_DELAY change is possible for a curator-LP
  coalition while new commitments are allowed (C2). Single-shot blocking needs more than `(1 − b)` of the non-queued
  supply. Governance can always end it with existing guardian levers within `MAX_HORIZON`, or in one block with an
  emergency release (L-2). LP protection is not weakened.
- **Properties.** S-1 to S-4 and L-1, L-2 and L-4 are stated with evidence. L-3 is explicitly not guaranteed, and L-5
  rules out unconditional withdrawal availability.
- **Governor integrity.** All twelve items of the brief are tested. One defect (C4) is fixed with a focused governor
  change: vault untouched, governor +41 bytes.
- **Validation.** Full, CI and deep suites pass, the coverage gate passes, 12/12 mutants are killed and the fork tests
  pass. The deep profile's one failure was a checker artifact in G01's campaign; it was diagnosed, fixed and kept as a
  regression test.

**Decisions requiring the owner** (numbered after 1B-4.4's R-3 … R-8):
- **R-9:** accept conditional LONG_DELAY liveness (current rule), or adopt the snapshot rule that trades LP protection
  for unconditional liveness (§6).
- **R-10:** whether the time-bounded commitment work should cap new commitments' expiry at an outstanding
  LONG_DELAY change's eta (vault change, needs architectural review).
- **R-11:** add to the release checklist: `b ≤ 50%` and a non-zero `R_a` at launch; `tau_a` configured before LPs are
  admitted; nominate only a reviewed governor and accept in the same transaction; the guardian cancels queued calls
  that conflict with its tightening; the admin's LONG_DELAY batch is atomic. *Closeout: added as checklist rows
  G-6 … G-11 and, where a script can check it, as deployment gates (§13.4). The cap is checked against the reviewed
  value, not against 50%.*
- **R-12:** accept the G01 inventory-handler fix (`8241124`), a test-only change to a G01 campaign.

## 12. Commits

Branch `phase-2-g02-governance-liveness` from `52fefdc`:

| Commit | Subject |
|---|---|
| `d6a1926` | test: reproduce LONG_DELAY blocking by queue replenishment |
| `ec26e8b` | test: cover governor operation integrity edge cases |
| `f2419cc` | fix: let the governor retract an ownership nomination after DELAY |
| `439af7e` | test: add governance liveness invariant campaign |
| `8241124` | test: check same-call queue slices before a claim can hide them |
| `98b2434` | docs: define governance and withdrawal liveness guarantees |

Nothing was pushed, merged, deployed or broadcast. `AGENTS.md` (untracked, not created in this work) was not touched.

## 13. Closeout review

The G02 closeout brief asked for four focused reviews before owner integration. All four were answered with tests
against the real contracts. **No production contract changed:** `git diff 98b2434 -- src` is empty, and the vault
(22,440 B) and governor (4,152 B) were re-measured after the prototypes below were removed.

### 13.1 Execution window: does the grace-period claim hold?

The constraints are LONG_DELAY = 32 d, GRACE = 7 d, `MAX_HORIZON` = 30 d, and a LONG_DELAY change refused while
`pendingShares ≠ 0`. A commitment made at time `t` can hold inventory until `t + 30 d`. If governance stops new
commitments at `L`, the queue is guaranteed deliverable from `L + 30 d`. The original change can still execute only
if that time falls inside its window:

`L + MAX_HORIZON ≤ eta + GRACE`, that is `L ≤ queuedAt + LONG_DELAY + GRACE − MAX_HORIZON = queuedAt + 9 d`.

| Claim | Holds? | Evidence |
|---|---|---|
| Governance can always recover a blocked LONG_DELAY change once new commitments are stopped | **Yes** | L-2; recoveries (a), (b) below |
| The same queued operation will execute | **Only if the lever is applied by `queuedAt + 9 d`** | `test_leverDeadline_isQueueTimePlusNineDays`: lever at the deadline, and the original executes at `eta + GRACE` (its last executable second); one second later, it expires |
| Stopping commitments at eta saves the original | **No** (C9) | `test_leverAfterEta_originalExpires_recoveryPaths` (a): a commitment made at `eta − 1` lives until `eta + 30 d − 1`, after `eta + 7 d`; refused at `eta + GRACE`, `NotExecutable` one second later |

**Recovery sequence (intended behaviour, now documented).**
1. *Preferred:* when queuing a LONG_DELAY change while commitments are near capacity, or as soon as blocking is seen,
   apply a lever in the same block as the `queue` (buffer floor at the maximum, vault-scope cap 0, pause or curator
   deregistration). The change executes at eta (L-2). The latest lever time is `queuedAt + 9 d`.
2. *Lever applied later, change blocked:* do not wait for the window to pass. Either:
   - (a) cancel and re-queue at once. The fresh LONG_DELAY (32 d) outlasts every commitment made before the lever
     (30 d), so the change executes at its new eta. The lever must stay on until then. Cost: no new commitments for up
     to 32 days. Test: case (b) of the C9 test.
   - (b) release the live commitments in an emergency (guardian or owner) with the lever on. The original executes in
     the same block. Cost: commitments to hooks are broken. Test: case (c) of the C9 test.
3. An expired record must be canceled before the change can be queued again (`AlreadyQueued`,
   `test_expiredOperation_requeueStartsAFullDelay`).
4. Lifting the lever is an owner change through the governor (DELAY). Queue the lift at least DELAY before the planned
   execution and execute it in the same batch, after the LONG_DELAY change. Lifting it earlier lets new commitments
   and new requests block again.

In every path the batch finalizes each queued request under the old values before the change applies. **No LP
protection is weakened.** Guaranteeing the same operation would need one of:
- a GRACE longer than `MAX_HORIZON`, which leaves approved changes executable for weeks after their notice;
- the snapshot rule (R-9), which weakens LP protection;
- an expiry cap on new commitments (R-10), which is a vault change.

None is adopted here.

### 13.2 Ownership nomination and acceptance

| Question | Result | Evidence |
|---|---|---|
| Sequence: (1) nomination executed, (2) LP queues, (3) nominee accepts, (4) new owner bypasses the old timelock | **Possible only with a nominee that is not a timelock.** An EOA nominee sets the floor to zero at once while the LP is queued (C5). A reviewed `VaultGovernor` nominee accepting late changes nothing: its admin cannot call the vault (`NotOwner`), and a floor change waits LONG_DELAY and is refused while the LP is queued | `test_nomineeAcceptingLate_isNotHeldByLaterQueuedLps`, `test_reviewedGovernorNominee_acceptingLate_keepsTheTimelock` |
| Can a pending nominee accept during the retraction's DELAY? | **Yes** (C10). Nothing on-chain stops it: the guardian has no ownership power and cannot cancel an executed nomination. The nominee accepts at `eta2 − 1`, and the retraction then fails with `NotOwner` | `test_pendingNominee_canAcceptDuringRetractionDelay` |
| Can the window be avoided? | **Yes**, when both governors share the admin: the nomination and `acceptVaultOwnership` run in one transaction. If acceptance fails, the nomination reverts with it and no nominee remains | `test_atomicHandover_leavesNoAcceptanceWindow` |

**Does this violate a documented protection?** No. The governor's NatSpec and §1.5 and §7.3 state that the queue check
binds when the nomination executes, not when the nominee accepts.
- The nomination itself waited LONG_DELAY in public and could execute only with the queue empty, so every LP queued
  before it was finalized under the old values.
- LPs who queue after the nomination can read `pendingOwner`: they have notice but no protection from a non-timelock
  nominee.

So no contract change is made. The release rule is now an executable check:
- **Gate 12** (`VerifyDeployment.nominee()`) accepts only a production `VaultGovernor` for this vault, with the
  expected admin and the mainnet delay minimums (`test_gate12_nomineeMustBeAReviewedGovernor`);
- **gate 1** already refuses any pending nomination after a hand-over.

**Smallest on-chain options, measured, not applied (owner decision R-13).** Measurements are from production builds;
the prototypes were removed.

| Option | Size | Effect | Cost |
|---|---|---|---|
| V-A: the vault's `acceptOwnership` also requires `pendingShares == 0` | vault +19 B (22,459; margin 2,117) | Moves the queue check to acceptance, so C5 cannot hit a queued LP | Does not close C10. Acceptance becomes griefable like L-3. A vault change to the ownership rule |
| G-A: an immediate retraction through the governor, by the admin or guardian | not prototyped | Narrows C10 to a same-block front-run | Breaks "every owner call waits" (§6). Gives the guardian a power over ownership |

### 13.3 Guardian tightening and queued operations

**Reproduction.** C6 shows an edge raise queued at 150 undoing a later guardian raise to 300. C11 shows that cancelling
by id misses a copy of the call with one trailing byte, which then undoes the tightening as well.

**Can the governor reject stale, conflicting changes at execution?** Not from its own state:
- it sees only `(target, data)`;
- the guardian acts on the vault directly;
- as owner, every governor call passes the vault's `_authorize`, so the governor cannot tell a loosening from a
  tightening.

Rejection needs a signal from the vault. The smallest such design was prototyped and measured on production builds,
then removed:
- **Vault:** a counter incremented in `_authorize`'s guardian branch, with a public getter.
- **Governor:** stores the counter at `queue` for vault calls, and at `execute` refuses any vault call (except
  `setGuardian`) whose counter changed.

| | Current | Prototype | Change |
|---|---|---|---|
| Vault runtime (B) | 22,440 (margin 2,136) | 22,505 (margin 2,071) | +65 B; 23 B above the 2,048 B target |
| Governor runtime (B) | 4,152 | 4,710 | +558 B |
| `queue` setPaused / setInventoryBounds / transferOwnership(0) (gas) | 49,781 / 55,674 / 54,336 | 57,614 / 63,509 / 62,170 | about +7.8k with the counter at zero; storing a non-zero counter adds about 20k more (not measured) |
| `execute` setPaused / setInventoryBounds / transferOwnership(0) (gas) | 40,396 / 109,497 / 41,524 | 45,716 / 114,839 / 46,866 | about +5.3k |

The prototype was also incomplete: the guardian's emergency `release` uses its own authorization path and was not
counted; it had no NatSpec and no tests.

**Not selected.** It would protect against admin mistakes without depending on the guardian, but:
1. It uses almost all of the vault's remaining headroom, which C-1 (TVL cap) and R-10 need.
2. Every guardian action invalidates every queued vault change, including unrelated ones and the LONG_DELAY change a
   lever is meant to rescue. Recovery (a) of §13.1 then becomes the only path after a lever.
3. It changes the vault's governance interface: architectural review.

A compromised guardian would gain nothing from it: it can already cancel everything except its replacement. This is
owner decision R-14.

**Assumption the design relies on, and its failure modes.** *After any guardian tightening, every queued change that
would loosen the tightened state is canceled before its eta, by the guardian or the admin.*

Failure modes:
1. **A missed id.** Trailing-byte copies (C11, 1B-4.4 G15) or an equivalent call with other arguments.
2. **A slow or absent guardian.** The admin, who alone can execute, executes the stale change.
3. **A verdict on stale state.** The check is valid only at the block simulated.
4. **Owner-only calls** (unfreeze, guardian or ownership changes) can only be flagged for review, not classified by
   direction.
5. **Hook calls cannot be classified.** They cannot undo a vault tightening, because hooks are priced inside the
   vault's limits.

**Executable check: `script/CheckQueuedConflicts.s.sol`.**
- It reads every `Queued` event and simulates each still-queued vault call from the guardian's address on a discarded
  snapshot. The vault's own `_authorize` then says whether the call would loosen the *current* state.
- It needs no per-function table and finds padded copies, because it simulates the exact queued bytes.
- It reverts if any change loosens or is owner-only.
- Run it after every guardian action and before every `execute`.
- Tests: `test_guardianCancellation_missesAPaddedCopy_conflictCheckFindsIt` and
  `test_conflictCheck_verdictsAfterGuardianEmergency` (unpause and an older edge loosen; unfreeze is owner-only; a
  further tightening and a hook call are not flagged; no state is left behind).

### 13.4 Deployment policies

| Requirement (checklist) | How it is enforced | Evidence |
|---|---|---|
| Exposure cap and non-zero protected buffer (G-6) | `DeploySystem` sets `BUFFER_FLOOR` (default 10% of the seed) and refuses zero. Gate 9 requires the vault-scope cap and the buffer floor to equal the reviewed values, and the floor to be non-zero. It prints the two blocking thresholds `1 − b` and `R_a / B_a`. The cap is compared with the reviewed value, **not with 50%**: 50% is the rehearsal default, not a protocol invariant | `test_gates_deploymentPolicies` |
| Inventory targets before LP deposits (G-7) | `DeploySystem` sets the targets and the buffer floor before `initialDeposit`, then checks the target against the shares minted. LPs can deposit only after the seed, so no share ever exists without a floor. Gate 9 requires both targets to be non-zero | `test_gates_deploymentPolicies` (`inventoryTargetPerShare(0) == 1e18`) |
| Reviewed governor ownership and transfer acceptance (G-8) | Gate 1: owner is the governor and nothing is pending. Gate 12 for a hand-over. Atomic acceptance where the admins coincide | `test_gates_refuseUntilGovernorAccepts`, `test_gate12_nomineeMustBeAReviewedGovernor`, `test_atomicHandover_leavesNoAcceptanceWindow` |
| Atomic handling of related operations (G-9) | Gate 2 (mainnet): the admin must be a contract (a multisig can batch). The governor itself has no batching | `test_gates_deploymentPolicies` |
| Conflict checks after emergency guardian actions (G-10) | `CheckQueuedConflicts` | §13.3 tests |
| Lever timing for LONG_DELAY changes (G-11) | Gate 3 (mainnet): `LONG_DELAY > MAX_HORIZON`. The deadline itself (`queuedAt + 9 d`) is procedural | §13.1 tests |

**Not enforceable by a script:**
- that the multisig really submits one transaction;
- that the guardian runs the conflict check;
- when a lever is applied.

### 13.5 Validation

| Command | Commit | Result |
|---|---|---|
| `forge fmt --check` | `b257017` | clean |
| `forge test` (default profile) | `b257017` | **628 passed, 0 failed, 8 skipped** (fork tests, no RPC). +9 since G02: 3 liveness, 4 integrity, 2 deployment-gate tests |
| `forge test --match-path test/governance/*` | `b257017` | 14 + 15 + 22 passed |
| `forge test --match-path test/script/DeployScripts.t.sol` | `b257017` | 6 passed, including the full local rehearsal with the new gates |
| `forge test --match-path test/invariant/GovernanceLivenessInvariants.t.sol` (default; then `FOUNDRY_PROFILE=ci`) | `b257017` | 5 invariants, 64 × 64 and 128 × 128 (16,384 calls), 0 reverts; scripted branch test passes |
| `python3 test/invariant/coverage.py --campaign liveness` | `b257017` | every gate passed (64 seeds; `longBlocked` zero-runs 0.80 against a gate of 0.98, as at G02) |
| `forge test --match-test test_bench_governor --isolate` | restored tree | governor gas identical to §6 (49,781 / 55,674 / 54,336; 40,396 / 109,497 / 41,524) |
| sizes from `out/` after `forge build` | restored tree | vault 22,440 B, governor 4,152 B: unchanged |

**Deliberately deferred,** because no production contract changed and nothing failed:
- `test/deep.sh`, the mutation campaign, `test/bench/security.sh`, Slither, the fork tests and the historical
  benchmarks;
- `CheckQueuedConflicts.run()` and `VerifyDeployment.nominee()` have not run against a chain: `run` needs
  `eth_getLogs` from an RPC. The classification and gate logic they call is tested locally.

### 13.6 Owner decisions added

- **R-13:** ownership acceptance. Keep the current rule with gate 12 and atomic acceptance, or adopt V-A (+19 B vault)
  and/or G-A (§13.2).
- **R-14:** stale-change rejection. Keep explicit cancellation with `CheckQueuedConflicts`, or adopt the vault counter
  (+65 B vault, +558 B governor, §13.3), which needs architectural review.
- R-9 and R-10 also decide whether the queued operation itself, and not only governance, is guaranteed to execute
  (§13.1).

### 13.7 Closeout commits

| Commit | Subject |
|---|---|
| `ed47b2b` | test: check governance expiry after a late commitment stop |
| `d56d557` | test: cover ownership acceptance with queued exits |
| `752d891` | test: add a queued-change conflict check for guardian actions |
| `b257017` | test: gate deployments on buffer, cap, admin and nominee policy |
| (this commit) | docs: define governance recovery conditions |
