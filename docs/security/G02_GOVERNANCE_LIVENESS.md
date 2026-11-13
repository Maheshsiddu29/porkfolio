# Porkfolio — G02: Governance and Withdrawal Liveness

**Status: see §11.** This document states what `VaultGovernor` and the vault's withdrawal queue guarantee about
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
change is delayed, not lost: it expires after GRACE and can be re-queued.

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
3. **Nomination vs acceptance** (C5). After a nomination executes, a non-timelock nominee can accept at any time and
   LPs who queue later have notice (`pendingOwner` is public) but no protection.
4. **Absolute values** (C6). An older queued call can undo a guardian tightening after its own delay; the guardian must
   cancel conflicting queued calls when it tightens.
5. **Target check at queue time only** (C8). Execution to an address whose code changed, or that has none, is not
   detected; it gains no authority, but `Executed` is emitted. Monitors decode target and calldata.
6. **Tightening the inventory floor through the governor** is LONG_DELAY and queue-gated (by selector, C7). The
   immediate path is the guardian; without a guardian, appointing one is DELAY and not cancellable by anyone but the
   admin.
7. **Trailing calldata** gives one effect several ids (1B-4.4 G15, unchanged); each waits its full delay.
8. **The admin's batch must be atomic** (release, process, execute). With an EOA admin, a deliverable queue can still be
   emptied, but an attacker meeting §5's capital condition can insert a request between transactions.
9. **Governor admin and hook owners cannot be rotated** (1B-4.4 G19, unchanged).
10. **Deployment values decide exploitability.** The test fixtures use `b = 100%`; the deployment script defaults to
    `b = 50%` and `R_a` is not set by it. Neither is enforced on-chain.

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
`docs/architecture/GOVERNANCE_SECURITY.md` (§3.3 corrected, G20 added).

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
  that conflict with its tightening; the admin's LONG_DELAY batch is atomic.
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
| (this commit) | docs: define governance and withdrawal liveness guarantees |

Nothing was pushed, merged, deployed or broadcast. `AGENTS.md` (untracked, not created in this work) was not touched.
