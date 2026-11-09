# Porkfolio — Curator Revocation (Specification)

**Status: SPECIFICATION, PARTLY SUPERSEDED.** `CURATOR_SECURITY_MODEL.md` replaces §3 and D16, and step 1B-2.1
(`PHASE1B2_1_REPORT.md`) implemented R2 (as a vault-side generation), R3 (cancel in any state), R4 (one `_close` with a
reason) and a freeze/revoke check in `exchange`. R1, R5's signature wording and R6 wait for the signed path (1B-2.3).
The SOURCE/OBSERVED labels below describe the code before 1B-2.1. It extends
`PHASE1B_CURATOR_AUTH.md` (§7 lifecycle, §7.5 races, §9 roles) and adds requirements to the Phase 1B-2 plan in
`PHASE1B_THREATS_AND_PLAN.md` §3. Labels: SOURCE (read from code), OBSERVED (asserted by a test), PROPOSAL, DECISION
(needs the owner's approval).

## 1. Four different actions

They act on different objects. Confusing them leaves a gap, so each is defined by **what it stops** and **what it
leaves alone**.

| Action | Acts on | Stops | Does not stop or change | Today |
|---|---|---|---|---|
| **Deregister a curator** (`setCurator(c, false)`) | the curator's authority to create *new* allocations | new activations by `c`. In 1B-2 this must include activation of `c`'s outstanding *signed* authorizations by a relayer (R1). | allocations `c` already created (they stay consumable); consumed amounts; LP exits | SOURCE: `allocate` checks `isCurator[msg.sender]`. OBSERVED: `test_RO_curatorRegistry` |
| **Invalidate unused signed authorizations** (`invalidateNonces`, 1B-2) | off-chain messages that have not been activated | activation of those specific `(curator, nonce)` pairs | anything already activated (no allocation exists for an unused nonce; an activated one must be canceled separately, `CA` §7.5 row 1) | not implemented. Today a nonce is spent only by a successful `allocate`. |
| **Cancel an active allocation** (curator X1, 1B-2; owner/guardian X2) | one live allocation | **all further consumption of that allocation, immediately**; its `remaining` returns to free inventory | `consumed` (already exchanged and owned by all shares); the nonce stays used | X2 exists today as `release(id)` before expiry by owner or guardian (SOURCE). OBSERVED: `test_ownerEmergencyRelease_blocksFurtherConsumption`. X1 (curator) is not implemented. |
| **Emergency-release unused commitment capacity** | the reservation `Q_a` held by allocations | the same as cancel: the allocation becomes `released`, `exchange` reverts `AllocationAlreadyReleased`, and `Q_a` and `curatorReserved` fall by `maxOut − consumed` | no assets move (OBSERVED: `test_RO_guardianEmergencyActions_moveNoAssets`); no shares, queue or `W_a` change | SOURCE: `release`. After expiry anyone may call it (lazy expiry, `test_lazyRelease`). |

"Cancel" and "emergency release" are the same state transition (`CA` §7.3 X1/X2). They differ only in who may call
them and in the reason recorded. "Releasing capacity" is how canceling shows up in accounting, not a separate
mechanism.

## 2. What must stop consumption immediately

An action **prevents further consumption immediately** if the next `exchange` against an affected allocation reverts in
the same block, whatever the swapper does.

| Action | Prevents further consumption immediately? | Required? | Reason |
|---|---|---|---|
| Cancel / emergency release of an allocation | **Yes** (SOURCE: `_getLiveAllocation` rejects `released`) | **Must** | It is the only way to remove a specific commitment before expiry. |
| Deregister the consumer hook (`setConsumer(h, false)`) | **Yes**, for every allocation bound to `h` (SOURCE: `exchange` checks `isConsumer[msg.sender]`) | **Must** | Hooks are what price trades. A suspect hook must be stoppable in one call. OBSERVED: `test_revokedHook_cannotConsume`. |
| Halt a direction / pause | **Yes**, for every allocation in that direction / all of them (SOURCE) | **Must** | Global emergency stop. |
| Deregister a curator | **No.** Its allocations remain consumable (SOURCE, documented on `setCurator`). | **Must stop new activations immediately, including outstanding signatures (R1).** Should **not** stop consumption by itself. | A curator cannot price trades. Its existing allocations are bounded by quota × `F_eff` and by the hook they name. Deregistration is also used for benign offboarding, where breaking live commitments to hooks would be wrong. A compromised curator is handled by §3. |
| Invalidate signed authorizations | Not applicable: they have no allocation to consume. | **Must stop activation of those nonces immediately** (planned bit set in the same transaction). | — |
| Lower the curator ceiling to 0 | No. It blocks new activations only. | — | `CA` §7.5 last row. |

Consequence: a compromised curator's *existing* allocations stay consumable until each one is canceled or released,
or its hook is deregistered, or the direction is halted. That is intentional, and the response in §3 is built around
it.

## 3. Response to a compromised curator (PROPOSAL, guardian runbook)

All of these steps are within the guardian's risk-reducing powers today, except step 3's batch form.

1. `setCurator(c, false)`. This immediately stops every new activation by `c`, direct or signed (R1).
2. `setCuratorCeiling(c, asset0 | asset1, 0)`. This is defence in depth and survives an accidental re-registration.
3. `release(id)` (1B-2: `emergencyRelease(id)`) for each live allocation of `c`, found from `AllocationCreated`
   events. Each call immediately stops consumption of that allocation and returns its remaining capacity. Total locked
   capacity is at most `c`'s ceiling, so the cost of this step grows with the number of allocations, not with the
   amount at risk.
4. If a hook named by those allocations is also suspect: `setConsumer(h, false)`, or halt the direction. This is the
   only way to stop all of `c`'s allocations in one call.

Loss bound while steps 3–4 are in progress: `PHASE1B_THREATS_AND_PLAN.md` T-01. The bound is quota × `(M − F_eff)⁺` and
needs a registered hook that prices badly. A curator alone causes no loss.

## 4. Gap found: deregistration and outstanding signatures

`PHASE1B_CURATOR_AUTH.md` §4 lists the checks for signed activation (A1). It does **not** list `isCurator[curator]`.
Without that check, after 1B-2:

- a deregistered curator's outstanding signed authorizations could still be activated by any relayer, until each one's
  `deadline` passes;
- the guardian could not stop them. Invalidating nonces is curator-only, so the only guardian lever left would be
  setting the ceiling to 0 (and the owner could later raise it).

**Resurrection.** Even with the check, re-registering the same address (owner only, OBSERVED in
`test_RO_curatorRegistry`) makes every outstanding signature of that curator valid again. That includes signatures that
may have leaked while the curator was considered compromised.

## 5. Required changes for Phase 1B-2 (PROPOSAL)

| ID | Change | Where | Test (to add in 1B-2) |
|---|---|---|---|
| **R1** | `_activate` checks `isCurator[auth.curator]` on **both** paths (direct and signed), before signature verification. Reverts `CuratorNotRegistered`. | commit 3 (`feat(auth)`) | `test_LC_deregisteredCurator_outstandingSignatureCannotActivate`; `test_LC_race_curatorDeregisterVsActivate_bothOrders` |
| **R2** | Stop resurrection (DECISION D15). Recommended: a per-curator `authEpoch` included in the signed struct, checked as equal at activation, and incremented by `setCurator(c, false)` and by a curator-only `bumpAuthEpoch()`. This invalidates **all** of a curator's outstanding signatures in O(1), and gives the curator a "revoke everything" call. Alternative without a schema change: store `revokedAt[c]` and reject `auth.validAfter < revokedAt[c]` (future-dated signatures survive). Alternative with no code: an operational rule never to re-register a deregistered address. | commit 3 (the struct must be final before signatures exist) | `test_LC_reregisteredCurator_oldSignatureRejected`; `test_LC_bumpEpoch_invalidatesAllOutstanding` |
| **R3** | `cancelAllocation` (X1) and `invalidateNonces` do **not** require `isCurator`. A deregistered or zero-ceiling curator must still be able to reduce its own exposure. | commits 3–4 | `test_LC_deregisteredCuratorCanStillCancelAndInvalidate` |
| **R4** | X1, X2 and X3 share `_close(id, reason)`. It reverts if already released, sets `released` before subtracting, and emits the reason. It moves no assets. (Already planned in `CA` §8; restated because §2 depends on it.) | commit 4 | existing T-08/T-09 list; `test_LC_emergencyReleaseMovesNoAssets` |
| **R5** | Document on `setCurator` that deregistration also blocks signed activation (R1), and on `setConsumer`/`emergencyRelease` that they are the immediate consumption stops (§2). NatSpec only. | commits 3–4 | — |
| **R6** | Invariant: no allocation is activated for a curator that was not registered at that block. Handler action: guardian deregisters a curator between a signature being produced and being submitted. | commit 6 (`test: Phase 1B invariants`) | `invariant_activationRequiresRegisteredCurator` |

**Not proposed for 1B-2 (DECISION D16).** A per-curator freeze checked inside `exchange` would let deregistration (or
a separate `freezeCurator`) stop all of a curator's allocations at once. Costs: one more storage read on every swap
(cold `SLOAD`, 2,100 gas, an EIP-2929 constant), new bytecode in a vault with 1,762 B of EIP-170 margin before the
1B-2 additions, and a new path that breaks commitments to hooks. Step 4 of §3 already provides an immediate stop at
the layer that prices trades. Recommendation: do not add it. Revisit only if the threat model changes so that a
curator alone can cause loss.

**Size note.** R1 reuses the existing `CuratorNotRegistered` check, moved into the shared `_activate`. R2 (epoch) adds
one storage mapping, one struct field and one small function. Both must be measured with `forge build --sizes`
after the commit, as `CA` §11 already requires.
