# Porkfolio — Curator Security Model (Signed Permissions, Freeze, Revocation)

**Status: SPECIFICATION FOR REVIEW (Phase 1B-2A). Nothing here is implemented.** It assumes architecture B from
`MODULAR_RISK_ENGINE.md` (vault + `CuratorAuthorization` module). It refines `PHASE1B_CURATOR_AUTH.md` and
`CURATOR_REVOCATION.md`, and where they differ this document wins. Changes to earlier decisions are listed in §9.

## 1. Objects and where they live

| Object | Contract | Storage |
|---|---|---|
| Signed authorization | off-chain until submitted | none |
| Nonce bitmap | `CuratorAuthorization` | `mapping(curator => mapping(wordPos => uint256))` |
| Curator record: `status` and `generation` | vault | one slot per curator: `uint8 status`, `uint32 generation` (room left for a packed outflow bucket, `MODULAR_RISK_ENGINE.md` §8.2) |
| Allocation (commitment) | vault | as today, with the curator's address |

Status values:

| Status | Activate? | Consume existing allocations? | Re-enter `Active`? |
|---|---|---|---|
| `None` (never registered, or deregistered) | no | **yes** (benign offboarding; `CURATOR_REVOCATION.md` §2) | yes, by owner `setCurator(c, true)` |
| `Active` | yes | yes | — |
| `Frozen` | no | **no** | yes, by owner `unfreezeCurator`, which **bumps the generation** |
| `Revoked` | no | **no** | **never** (terminal) |

## 2. EIP-712 authorization

**Libraries.** OpenZeppelin 5.0.2 `EIP712`, `ECDSA` (through `SignatureChecker`) and `SignatureChecker`, the version
already vendored under `lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts` (SOURCE, `package.json` 5.0.2).
There is no hand-written cryptography (D12).

**Domain.** `name = "Porkfolio Curator Authorization"`, `version = "1"`, `chainId`, `verifyingContract = module`.

- OZ caches the separator and rebuilds it if `block.chainid` changes (fork safety, SOURCE).
- It also exposes ERC-5267 `eip712Domain()`.
- The name changes from D11's `"Porkfolio Vault"` because the verifying contract is now the module (§9).

**Message.**

```
CuratorAuthorization(
  address curator, address vault, address consumer, bytes32 poolId, address currencyOut,
  uint128 maxOut, uint160 minInPerOutX96, uint64 validAfter, uint64 deadline, uint64 expiry,
  uint256 nonce, uint32 generation)
```

- `currencyIn` and `zeroForOne` are derived from `poolId` and `currencyOut` and do not need to be signed. The vault
  rejects any `currencyOut` outside the pair, and `poolId` commits to the full key.
- The prototype measured exactly this struct (`MODULAR_RISK_ENGINE.md` §8.2).

**Signature types.** `SignatureChecker.isValidSignatureNow(curator, digest, sig)`:

- First it tries ECDSA: 65-byte signatures only, low-`s` only, never reverts. It succeeds when the recovered address
  equals `curator`.
- Otherwise it calls `curator.isValidSignature(digest, sig)` with `staticcall` and requires the 4-byte magic value.
- An EOA with a bad signature fails, because a code-less address returns no data.
- **EIP-7702 note.** A delegated EOA has code, but ECDSA is tried first, so its own key still signs for it. Revoking a
  key is therefore only possible through `generation` or `status`, never by changing the account's code.

**Activation is atomic.** `module.activate` makes these calls, in this order, in one transaction:

1. window and deadline checks;
2. build the digest;
3. verify the signature (the only external call to untrusted code, read-only);
4. consume the nonce bit, reverting if it is already used;
5. `vault.reserveFor(req, curator, generation, signed = true)`.

Any revert in step 5 (status, generation, ceiling, admission, floor) reverts the nonce consumption. There is no
"authorized but not reserved" state on-chain.

**Direct path (D6).** `module.activateDirect(req)` with `curator = msg.sender`. There is no signature. It consumes a
nonce from the same bitmap and calls `reserveFor(req, msg.sender, 0, signed = false)`; the vault skips the generation
check for unsigned requests, because the curator is present.

## 3. Replay and revival protection

| Threat | Protection | Where |
|---|---|---|
| Same message twice | the nonce bit is set once, keyed by `(curator, nonce)` and not by digest | module |
| Two different messages with one nonce | same key, so at most one activates | module |
| Another chain | `chainId` in the domain; separator rebuilt on fork | module (OZ) |
| Another vault | `vault` field in the struct; the module's `vault` is immutable; the vault accepts only its configured module | module + vault |
| Another module (old or new) | `verifyingContract` in the domain | module (OZ) |
| Too early or too late | `validAfter ≤ now ≤ deadline` | module |
| Signature from before a key compromise | the curator or the owner bumps `generation`; the vault rejects `generation ≠ current` | vault |
| **Revival after unfreeze** | `unfreezeCurator` always increments `generation`, so every signature made before the freeze is dead | vault |
| **Revival after deregister and re-register** | `setCurator(c, false)` increments `generation` | vault |
| **Revival after revocation** | `Revoked` is terminal: `setCurator(c, true)`, `unfreezeCurator` and `reserveFor` all revert for it | vault |
| Old allocation reactivated | an allocation is closed exactly once (`_close` reverts on `released`); a nonce is never unset | vault + module |
| Generation overflow | `uint32`: 4.3·10^9 bumps. `bumpGeneration` reverts at `type(uint32).max` rather than wrapping to 0 | vault |

"Old signatures and permanently revoked commitments cannot be revived accidentally" therefore rests on three facts:
`generation` only increases, `Revoked` never changes, and `released` is never cleared. Each has an invariant (§7).

## 4. Actions

| Action | Caller | Effect, immediately in the same transaction | What stays backed |
|---|---|---|---|
| `bumpGeneration()` | the curator | `generation++`: every outstanding signature dies | all allocations (unchanged) |
| `invalidateNonces(word, mask)` | the curator (on the module) | sets bits; idempotent | all allocations |
| `setCurator(c, false)` (deregister) | owner or guardian | `status = None`, `generation++`; new activation stops | allocations stay **consumable** and reserved |
| `freezeCurator(c)` | owner or guardian | `status = Frozen`; activation **and** consumption stop | allocations stay **reserved** in `Q_a` and `curatorReserved`; they are not released |
| `unfreezeCurator(c)` | owner only | `status = Active`, `generation++` | consumption resumes on existing allocations |
| `revokeCurator(c)` | owner or guardian | `status = Revoked` (terminal); activation and consumption stop | allocations stay reserved **until released**; anyone may release them at once (`MODULAR_RISK_ENGINE.md` §4.1) |
| `cancelAllocation(id)` | the allocation's curator, in **any** status | closes it; `Q_a −= remaining` | the nonce stays used |
| `release(id)` | anyone after expiry or if the curator is Revoked; owner or guardian at any time | closes it; `Q_a −= remaining` | — |
| `setAuthModule(0)` | owner or guardian | all activation stops | everything already reserved |

**How frozen allocations stay backed.**

- Freezing changes only `status`. `Q_a`, `curatorReserved` and the allocation records are untouched.
- So the admission rule, `_deliverableShares` and the queue keep treating that capacity as committed, and LP exits
  cannot pay it out to a redeemer while a later unfreeze could still let a hook consume it.
- The capacity returns to free inventory only through one of the close paths:
  - curator cancel;
  - emergency release by the owner or guardian;
  - release by anyone after expiry, at most `MAX_HORIZON` = 30 days after creation;
  - release by anyone once the curator is revoked.
- A freeze can therefore delay LP exits for up to 30 days, the same bound as any live commitment
  (`MAX_HORIZON` NatSpec).

**Why freeze is not release.**

- A freeze is a pause while someone investigates. If it released capacity, unfreezing would need to re-reserve it, and
  that could fail admission. The allocation would then exist without backing, which is exactly what must never happen.
- Keeping the capacity reserved costs liveness (LP exits may queue) and never solvency.

**Revocation sequence (guardian runbook, replaces `CURATOR_REVOCATION.md` §3):**

1. `revokeCurator(c)`. Activation and consumption stop at once.
2. Anyone calls `release(id)` for each of `c`'s allocations, found from `AllocationCreated` events. A keeper or the
   guardian can do it; it is permissionless because nobody can consume them any more.
3. If a hook is also suspect: `setConsumer(h, false)`.

## 5. Untrusted calls and reentrancy

- The only call to curator-controlled code is the ERC-1271 `staticcall`, in the module, before any state change.
  - It cannot write state, so it cannot re-enter anything with an effect.
  - A wallet that burns gas or returns a large payload makes the **relayer's** transaction fail or cost more. Nothing
    else is affected.
  - OZ 5.0.2 `SignatureChecker` copies the return data, so the submitter pays for memory expansion (SOURCE). Relayers
    should set a gas limit.
- The module → vault call is the module's last action. The vault never calls the module.

## 6. Gas (OBSERVED, prototype, `optimizer_runs` 200; `MODULAR_RISK_ENGINE.md` §8.2)

| Path | Gas |
|---|---|
| Direct activation through the module | 270,158 |
| Signed activation, EOA | 283,071 |
| Signed activation, ERC-1271 | 290,560 |
| `freezeCurator` | 35,973 |
| `cancelAllocation` | 44,326 |
| Freeze check on every swap | part of the measured +19,163 (ESTIMATE about 2,100 for the cold status read) |

## 7. Invariants and required tests

| ID | Invariant | Test |
|---|---|---|
| INV-C1 | `generation[c]` never decreases | handler ghost; `invariant_generationMonotonic` |
| INV-C2 | `Revoked` never changes | `invariant_revokedIsTerminal` |
| INV-C3 | No allocation is created with a signed generation ≠ current | `invariant_activationRequiresRegisteredCurator` (extends R6) |
| INV-C4 | No consumption while Frozen or Revoked | `invariant_noConsumptionWhenFrozenOrRevoked` |
| INV-C5 | Freeze and unfreeze never change `Q_a`, `curatorReserved`, `B_a`, `W_a`, shares or the queue | differential |
| INV-C6 | Each `(curator, nonce)` is used at most once, across both paths | `invariant_noncesSingleUse` |

Negative and adversarial tests (`test/security/CuratorAuth.t.sol`, `AuthLifecycle.t.sol`):

- Replay: same signature twice; same nonce with two messages; another chain (`vm.chainId`); another vault; another
  module; before `validAfter`; after `deadline`.
- Generation: stale generation after `bumpGeneration`, after deregistration, after unfreeze; `bumpGeneration` at
  `uint32.max` reverts.
- Freeze: a swap reverts; activation reverts; cancel works; emergency release works; release after expiry works; LP
  redeem queues against frozen capacity and does not pay it out; unfreeze resumes consumption and kills old signatures.
- Revoke: terminal (`setCurator(true)` and `unfreeze` revert); anyone may release; a revoked curator can still cancel.
- ERC-1271: valid, invalid, reentrant (attempts a write: rejected by `staticcall`), gas burner, return bomb, wallet
  changes its signer after activation (the allocation stays valid; cancel works).
- Module: the vault rejects `reserveFor` from anything except `authModule`; the guardian can set it to zero and not to
  any other value; module replacement leaves allocations untouched and invalidates old-domain signatures.
- Races (each in both orders): freeze vs swap; revoke vs activation; bump vs activation; module disable vs activation.

## 8. Not covered

- **Key management.** A compromised curator key can sign until the curator or a guardian acts. Detection is
  off-chain.
- **Owner compromise.** The owner can unfreeze (not un-revoke), register hooks and raise ceilings. A multisig and
  timelock are required before real value (`MAINNET_READINESS.md` G-3).
- **Relayer liveness** (`RISKS.md` R7). A signature still needs someone to submit it.

## 9. Changes to earlier decisions (need confirmation)

| Earlier | Now | Reason |
|---|---|---|
| D11: domain `"Porkfolio Vault"` on the vault | `"Porkfolio Curator Authorization"` on the module | the verifying contract is the module |
| D15 (`CURATOR_REVOCATION.md`): epoch in the signed struct, stored with the signatures | `generation` stored **in the vault** next to `status`, signed, checked by the vault | one source of truth for curator state; the module stays stateless apart from nonces |
| D16: no freeze check in `exchange` | **freeze and revoke stop consumption** | the approved Option 3 requires temporary suspension; measured cost in §6 |
| D6: shared struct, direct path on the vault | direct path through the module, same nonce space | one nonce store; the vault has a single entry point for creating commitments |
| `CURATOR_REVOCATION.md` R1: `isCurator` check in `_activate` | `status == Active` check in `vault.reserveFor` | the same rule, enforced by the vault, which the module cannot bypass |
