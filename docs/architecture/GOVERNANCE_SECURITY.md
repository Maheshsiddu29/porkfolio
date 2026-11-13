# Porkfolio — Governance Security: the `VaultGovernor` audit and delay policy (Phase 1B-4.4)

**Status: TESTED locally (`test/governance/VaultGovernor.t.sol`, 22 tests, real PoolManager, production hook
builds). Not reviewed independently. Delay values are provisional policy (decision R-3).**

Labels: **FIXED** (changed in this phase, with a test), **HOLDS** (checked against the implementation, with a test),
**LIMIT** (a known limitation, documented, not fixed).

## 1. What was audited

The implementation, not the interface:
- `src/governance/VaultGovernor.sol`;
- every owner- and guardian-gated function of `SharedCommitmentVault` (`_authorize`, `onlyOwner`);
- every `onlyHookOwner` setter of `BaseCompatibleHook`, `HookA_DynamicFee` and `HookB_BoundedImpact`;
- the vault's LP exit path (`redeem`, `_processQueue`, `_deliverableShares`, `reserveFor` admission), because the
  delays are only meaningful relative to how fast an LP can leave.

Routing checks:
- Neither the vault nor the hooks has a `fallback`, `receive`, `delegatecall` or multicall (grep of `src/`).
- A selector therefore always reaches the function it names, so classifying a call by its selector cannot be routed
  around.

## 2. Findings

| # | Check from the brief | Result | Evidence |
|---|---|---|---|
| G1 | Every risk-increasing **vault** owner function goes through the delay | HOLDS while `vault.owner() == governor`. The governor has no immediate path except `acceptVaultOwnership`, which only adds delays. | `test_handover_governorOwnsVaultAndHooks` |
| G2 | **Hook** parameter setters (`configurePool`, `configureCore`, `configureStrategy`) were immediate | **FIXED.** The governor now governs targets: the vault, and any hook whose immutable `hookOwner()` is the governor and whose `vault()` is the governed vault. Production hooks are deployed with `hookOwner = governor`. All hook calls wait DELAY. | `test_hookParameters_waitDelay`, `test_targets_onlyVaultAndOwnHooks` |
| G3 | No immediate arbitrary-call bypass | HOLDS. Targets are limited to G2's set; nothing executes before `eta`. A target that passes the hook check gains nothing by re-entering: `queue`, `execute` and `acceptVaultOwnership` are admin-only. | `test_maliciousTarget_cannotReenterGovernor` |
| G4 | Queued operations bind target, selector and arguments | HOLDS. The id is `keccak256(abi.encode(target, data))`. | `test_operationId_bindsTargetAndCalldata`, `test_execute_cannotSubstituteCalldataOrTarget` |
| G5 | Executed operations cannot be replayed | HOLDS. The record is deleted before the call; re-queuing starts a fresh delay. | `test_delay_window_replay_andEvents` |
| G6 | Cancellation cannot be bypassed | HOLDS. A canceled id is `NotQueued`; the admin can only re-queue with a fresh delay. | `test_cancel_roles`, `test_compromisedScheduler_cannotShortenAnyDelay` |
| G7 | Only authorized accounts schedule or cancel | HOLDS. Admin queues and executes. Admin or the vault's live guardian cancels, except the guardian may not cancel the vault's `setGuardian`. | `test_onlyAdmin_queuesAndExecutes_noDuplicates`, `test_cancel_roles` |
| G8 | Guardian emergency restrictions stay immediate | HOLDS. They are vault calls, not governor calls. In shared-core mode the hooks clamp to the vault's `kappa_1` and edge, so a guardian tightening reaches both hooks in the same block. | `test_guardianTightening_isImmediate`; `SharedCoreHooks.t.sol` |
| G9 | A compromised scheduler cannot immediately loosen | HOLDS. Replacing the guardian (not cancellable by that guardian) still leaves every loosening its full delay, counted from its own queue time. | `test_compromisedScheduler_cannotShortenAnyDelay` |
| G10 | Ownership cannot escape without the delay | HOLDS, and now also needs an empty withdrawal queue (G13). The transfer is two-step and the nominee must accept. | `test_ownershipEscape_waitsLongDelayAndQueue` |
| G11 | A malicious executor cannot substitute calldata | HOLDS (G4). Only the admin executes. | `test_execute_cannotSubstituteCalldataOrTarget` |
| G12 | Auditable event trail | HOLDS. `Queued(id, target, eta, data)` carries the full calldata; `Canceled(id, by)`; `Executed(id, target)`. Acceptance of ownership emits the vault's `OwnershipTransferred`. | `test_delay_window_replay_andEvents` |
| G13 | Queued LPs exposed to a floor loosening | **FIXED.** See §3. A LONG_DELAY call (`setInventoryBounds`, `transferOwnership`) reverts with `PendingWithdrawals` while `vault.pendingShares() != 0`. | `test_queuedLp_lateInNotice_blocksLooseningUntilFinalized` |
| G14 | Fixed delay constants made a testnet rehearsal of a 32-day change impractical | **CHANGED.** The delays are constructor immutables: non-zero, LONG ≥ DELAY, each ≤ 365 days. The mainnet values are a release gate (`script/README.md`). | `test_constructor_rejectsBadDelays` |
| G15 | The same effect can be queued under two ids (the vault ignores trailing calldata) | LIMIT. Each copy still waits its full delay and can be canceled. Monitors must decode `data`, not compare ids. | `test_trailingBytes_areSeparateIds_eachDelayedAndCancellable` |
| G16 | A queued address argument binds an address, not code | LIMIT. An address with no code at queue time could receive any code later; a proxy can change its implementation. Checklist rule: the guardian cancels any queued adapter, module, consumer or new owner that has no code or is upgradeable, or that does not match a reviewed build. | `script/README.md` |
| G17 | A compromised guardian can delay governance and impose liveness costs | LIMIT. It can cancel everything except its replacement. It can pause, halt, revoke curators (permanent) and retire the authorization module (permanent). It cannot move assets, block LP exits or loosen anything. Recovery is `setGuardian` after DELAY. | `test_cancel_roles` |
| G18 | No immediate owner tightening without a guardian | LIMIT. Every governor call waits, including tightening. Release gate: a guardian is set and differs from the admin. | — |
| G19 | `admin` cannot be rotated | LIMIT (unchanged). Rotation means a new governor (LONG_DELAY ownership transfer) and new hooks. | — |
| G20 | Withdrawing a nomination (`transferOwnership(address(0))`) was LONG_DELAY and refused while LPs were queued, so a nominee could keep the right to accept | **FIXED in G02.** Now DELAY and not queue-gated; a non-zero nominee stays LONG_DELAY. See `docs/security/G02_GOVERNANCE_LIVENESS.md` §6. | `test_nominationRetraction_waitsDelay_notHeldByQueuedLps` |

**Privilege escalation paths examined:**
- **Ownership changes.** G10 and G13.
- **Module replacement.** `setAuthModule` waits DELAY. A module can at most reserve what curators' ceilings and the
  vault's limits allow (`MAINNET_READINESS.md` M-1).
- **Consumer replacement.** `setConsumer(x, true)` waits DELAY. A malicious consumer still fills only against
  allocations made out to it, at or above every floor, down to the inventory floor at worst.
- **Emergency operations.** Guardian-only and risk-reducing; the owner's emergency `release` waits DELAY like
  everything else.
- **Hook setters.** G2.

None of these paths reaches LP assets.

## 3. Delay policy and what each delay guarantees

### 3.1 How fast can an LP leave?
Exits are in kind and pro rata, and pauses, halts, freezes and flow limits never apply to them
(`test_queuedLp_pauseHaltFreezeDoNotBlockExit_guardianReleaseUnblocks`). Only reserved capacity `Q_a` can hold an exit
back.
- **New allocations cannot take a waiting LP's share.** Admission keeps `Q_a + q + R_a + D_a <= N_a`, so they stay off
  the queue's pro-rata claim `D_a`.
- **Older allocations can.** Commitments that already existed when the LP queued can hold its request until they expire
  and are released. That is at most `MAX_HORIZON` (30 days) after the LP queued. Release is permissionless after
  expiry, and the guardian can release earlier.

**So:** a redemption requested at time `t` is deliverable by `t + MAX_HORIZON`. Depleted inventory does not delay it
(the LP simply receives less of that asset), and neither do the requests ahead of it (their claims are inside `D_a` too).

### 3.2 Why the delay alone was not enough (G13)
Take a loosening announced at `T` with LONG_DELAY = 32 days.
- **Delay alone.** Only an LP who requests by `T + (32 − 30) = T + 2 days` is guaranteed to be finalized before
  execution.
- **Counterexample.** A curator commits inventory at `T + 4.9 d` for 30 days, and an LP requests at `T + 5 d`.
  - The LP is still queued at `T + 32 d`.
  - Its shares are still outstanding, so the looser floor would apply to them.
  - `test_queuedLp_lateInNotice_blocksLooseningUntilFinalized` reproduces this: the request is still pending at `eta`.

### 3.3 Snapshot or restriction?
Two options were considered:
- **Snapshot.** Each request records its floor. This needs per-request storage and a second floor rule inside the
  vault's fill path: new vault bytes and new accounting.
- **Restriction (selected).** The governor refuses a LONG_DELAY call while any shares are queued. The vault is
  unchanged (0 bytes).

How the restriction behaves:
- **What it guarantees.** Every LP who requests a withdrawal before the change executes is finalized under the old
  floor. Finalized amounts (`W_a`) are outside `N_a`, so no later floor change reaches them.
- **Effect on governance.** It can only delay a loosening, never hasten it. The admin calls the permissionless
  `processQueue` in the same transaction. Requests that are still undeliverable make the change wait; past GRACE it
  expires and must be re-queued.
- **Griefing.** Blocking needs requests that cannot be finalized. For a lone LP that means holding, before the
  commitments were made, more than `(1 − b)` of the non-queued shares, where `b` is the vault-scope exposure cap
  (one share at `b = 100%` with no buffer floor). **Corrected in G02:** a registered curator that is also an LP can
  sustain the blocking indefinitely by re-committing and re-queuing in one transaction; releasing its commitments
  alone does not stop it. Stopping new commitments does: `MAX_HORIZON` later, any LONG_DELAY change inside its window
  executes.
  See `docs/security/G02_GOVERNANCE_LIVENESS.md` §4–§5. Cost to the griefer: its capital stays at risk in the vault
  while it blocks.

### 3.4 The values

| Delay | Proposed (mainnet) | Applies to | Guarantees | Does not guarantee |
|---|---|---|---|---|
| DELAY | 3 days | every vault call except the two below; every hook call | public notice; time for monitors and the guardian to cancel; an instant exit where free inventory allows | that queued LPs leave first. They remain exposed to the change, but only down to the unchanged inventory floor (the price-free bound) |
| LONG_DELAY | 32 days | `setInventoryBounds`, `transferOwnership` | together with the queue restriction, every LP who requests before execution is finalized under the old floor or owner. Because 32 > `MAX_HORIZON`, even without the restriction an LP who requests in the first 2 days is out by time alone | anything for LPs who stay. After an ownership transfer, the new owner's own rules apply once it accepts |
| GRACE | 7 days | every queued change | stale approvals expire; time to clear the queue for a LONG change | — |

- **Why 3 days for DELAY.** These changes cannot lower the price-free floor. They change how fast the room above it can
  be used: the adapter, edge, stored floors, consumers, curators, the module and hook pricing.
- **Why 32 days for LONG_DELAY.** The 32 days stays as the notice period for passive LPs. The queue restriction, not
  the number, now protects LPs who act.
- **Immediate tightening** is the guardian's role. It is unchanged and needs no delay.

## 4. Testnet parameters

The Sepolia rehearsal may deploy the governor with short, clearly labelled delays (for example 10 minutes / 1 hour /
1 day). This is so that one queued change can be executed and one canceled within a session. The deployment script
prints them, and the checklist refuses mainnet values below 3 days / 32 days / 7 days.
