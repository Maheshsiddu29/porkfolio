# Porkfolio — Curator Security Model (Signed Permissions, Freeze, Revocation)

**Status: IMPLEMENTED (local).** Step 1B-2.1 implemented the curator record, freeze, revocation, generation,
cancellation and the shared close path in the vault (`PHASE1B2_1_REPORT.md`), with the differences listed in §1.1.
Step 1B-2.3 implemented signed authorizations, nonces, `reserveFor` and the authorization module
(`PHASE1B2_3_REPORT.md`), with the differences listed in §2.1. Step 1B-2.4 added the module installation check and
the signature time rules (§2.2; operator-facing summary in `AUTH_SECURITY_RELEASE_NOTES.md`). Where §2–§4 below still
describe the proposal, §2.1 and §2.2 say what was built. It assumes architecture B from
`MODULAR_RISK_ENGINE.md` (vault + `CuratorAuthorization` module). It refines `PHASE1B_CURATOR_AUTH.md` and
`CURATOR_REVOCATION.md`, and where they differ this document wins. Changes to earlier decisions are listed in §9.

## 1. Objects and where they live

| Object | Contract | Storage |
|---|---|---|
| Signed authorization | off-chain until submitted | none |
| Nonce bitmap | `CuratorAuthorization` | `mapping(curator => mapping(wordPos => uint256))` |
| Curator record: `status` and `generation` | vault | one slot per curator: `uint8 status`, `uint32 generation` (room left for a packed outflow bucket, `MODULAR_RISK_ENGINE.md` §8.2) |
| Allocation (commitment) | vault | as today, with the curator's address |

Status values (as proposed; see §1.1 for what was built):

| Status | Activate? | Consume existing allocations? | Re-enter `Active`? |
|---|---|---|---|
| `None` (never registered, or deregistered) | no | **yes** (benign offboarding; `CURATOR_REVOCATION.md` §2) | yes, by owner `setCurator(c, true)` |
| `Active` | yes | yes | — |
| `Frozen` | no | **no** | yes, by owner `unfreezeCurator`, which **bumps the generation** |
| `Revoked` | no | **no** | **never** (terminal) |

### 1.1 As built in 1B-2.1 (SOURCE)

One enum cannot hold both "may this curator create?" and "may its allocations execute?" without one action silently
changing the other. With a single `status`:

- deregistering a frozen curator would set `None`, which **re-enables consumption** of its allocations;
- `unfreezeCurator` would set `Active`, which **re-registers** a curator that was deregistered while frozen;
- re-registering a frozen curator (`setCurator(c, true)`) would have to either fail or lift the freeze.

The vault therefore stores two independent controls and the counter in one slot:

```
struct CuratorRecord { bool registered; CuratorRestriction restriction; uint32 generation; }   // 6 bytes, one slot
enum CuratorRestriction { None, Frozen, Revoked }
```

| State in the task's terms | `registered` | `restriction` | Create allocations | Consume its allocations | How it is left |
|---|---|---|---|---|---|
| Active | true | None | yes | yes | deregister, freeze, revoke |
| Deregistered | false | None | no | **yes** | owner re-registers; freeze; revoke |
| Frozen | true or false | Frozen | no | **no** | owner `unfreezeCurator` (registration unchanged); revoke |
| Revoked | false (forced) | Revoked | no | **no** | never |

Rules (all OBSERVED in `test/security/CuratorLifecycle.t.sol`):

- `setCurator(c, true)`: owner only; reverts `InvalidCuratorTransition` for a revoked curator; leaves a freeze in place.
- `setCurator(c, false)`: owner or guardian; `generation += 1` (also when already deregistered); restriction unchanged.
- `freezeCurator`: owner or guardian; only from `None`; registration and generation unchanged; no reservation moves.
- `unfreezeCurator`: owner only; only from `Frozen`; `generation += 1`; registration unchanged.
- `revokeCurator`: owner or guardian; from `None` or `Frozen`; sets `registered = false`; **does not** change the
  generation, so it can never fail on `GenerationExhausted`.
- `bumpGeneration()`: any caller, for its own record, in any state.
- `generation` is `uint32` and never wraps: every increment reverts with `GenerationExhausted` at `type(uint32).max`.
  At that point deregistration and unfreeze revert; freeze and revoke still work.

**One generation is enough; no second counter for execution rights.** The task asked whether one counter can both
invalidate unactivated instructions and permanently invalidate existing allocations. It cannot do both without
breaking an approved rule: if `exchange` compared an allocation's stored generation with the curator's current one,
then deregistration and unfreeze, which must raise the generation to kill outstanding instructions, would also kill
live allocations, contrary to "deregistration leaves allocations consumable" (`CURATOR_REVOCATION.md` §2) and
"unfreeze resumes consumption" (§4 below). The two jobs are therefore done by different mechanisms:

- **Unactivated instructions:** `generation`, which only rises. Example: a curator signs at generation 7; the guardian
  deregisters it (8); the owner re-registers it (still 8). An instruction tagged 7 can never match again. Since
  1B-2.3, `reserveFor` compares it on every activation (`StaleGeneration`).
- **Existing allocations:** the terminal `Revoked` restriction, checked by `exchange` on every call. Because `Revoked`
  never changes and `released` is never cleared, a revoked curator's allocations can never execute again, and no
  allocation id can be reopened (ids only increase). An execution generation stored per allocation would add a field
  and a comparison on every swap and would protect nothing that terminal revocation does not already protect.

## 2. EIP-712 authorization

### 2.1 As built in 1B-2.3 (SOURCE, `src/CuratorAuthorization.sol`, `SharedCommitmentVault.reserveFor`)

| Proposal below | As built | Why |
|---|---|---|
| Domain name "Porkfolio Curator Authorization" | **"Porkfolio Vault"**, version "1", chain id, verifying contract = module | the task fixed the established domain name; the verifying contract still makes it module-specific |
| Struct `CuratorAuthorization(...)` without `currencyIn`, `zeroForOne` | `AllocationAuthorization(address curator, uint32 generation, address vault, bytes32 poolId, address hook, address currencyIn, address currencyOut, bool zeroForOne, uint128 maxOut, uint160 minInPerOutX96, uint64 expiry, uint64 validAfter, uint64 deadline, uint256 nonce)` | the task asked for both assets and the direction to be signed; the module checks they agree with the submitted PoolKey |
| `reserveFor(req, curator, generation, signed)`; vault skips the generation for direct calls | `reserveFor(req, curator, generation)`; the vault always compares it; on the direct path the module passes the generation it reads from the vault in the same call | one rule in the vault; no flag a module could misuse |
| Direct path consumes a nonce | same: one bitmap per curator for both paths | an instruction a curator signed and then submits itself activates once, whichever path is first; retries are idempotent |
| `setAuthModule(0)` by the guardian, owner may set any value | owner may install any module that was never installed; guardian may only set zero; **the module being replaced or disabled is retired for good** | keeps a retired module's unused signatures from ever regaining authority; a reversible stop of new allocations exists already (vault-scope exposure cap, deregistration, pause) |
| — | 1B-2.3: the vault never calls the module (no `module.vault()` check at install). **Changed in 1B-2.4:** one read-only `vault()` call at installation (§2.2) | no call cycle either way; the install check costs 91 bytes and leaves 2,052 bytes of EIP-170 margin |

Order of an activation as built: signed-field checks (vault field, time-field consistency, clock, pool id, hook,
direction) → signature (`SignatureChecker`) → nonce bit → `vault.reserveFor` (last action). Any revert undoes the nonce
bit.

### 2.2 Added in 1B-2.4 (SOURCE, `PHASE1B2_4_REPORT.md`)

**Installation check.** `setAuthModule(m)` with `m != 0` makes one `staticcall` to `m.vault()` and reverts
`InvalidAuthModule(m)` unless the call succeeds, returns at least 32 bytes, and the first word is exactly this vault's
address. Installing the module that is already installed reverts `AuthModuleRetired` (installing retires the current
module first). The check catches deployment mistakes only: a malicious module, or any contract with a `vault()` getter
naming this vault (both hooks have one), passes it. Review and code verification stay mandatory.

**Time rules for signed instructions** (no change to the EIP-712 type, domain or digest):

| Rule | Error | Checked |
|---|---|---|
| validAfter <= deadline | `InvalidValidityWindow` | before the clock |
| deadline − validAfter <= `MAX_VALIDITY_WINDOW` (1 day) | `ValidityWindowTooLong` | before the clock |
| deadline < expiry (also on the direct path) | `ExpiryNotAfterDeadline` | before the clock |
| validAfter <= now <= deadline | `AuthorizationNotYetValid`, `AuthorizationExpired` | then |
| expiry <= now + `MAX_HORIZON` | `HorizonExceeded` (vault) | in the vault |

All of them run before the curator's ERC-1271 wallet is called. Not bounded: how long before its window an instruction
was signed. That needs a signed issuance time (a new type, version "2"); `AUTH_SECURITY_RELEASE_NOTES.md` §5.

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
| Too early or too late | `validAfter ≤ now ≤ deadline`; since 1B-2.4 also `validAfter ≤ deadline`, `deadline − validAfter ≤ 1 day`, `deadline < expiry` | module |
| Signed long before use (future-dated window) | **not bounded**: the module cannot know the signing time; cancel with `invalidateNonces`, `bumpGeneration` or module retirement | — |
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

As built (1B-2.1): both close entry points call one internal `_close`; `AllocationReleased` carries a `CloseReason`
(`Expired`, `Emergency`, `Canceled`, `CuratorRevoked`; `release` picks them in that order of precedence). A frozen or
deregistered curator's unexpired allocation is **not** releasable by a stranger, because a freeze may be lifted.
`revokeCurator` also deregisters. The `setAuthModule` and `invalidateNonces` rows are not implemented.
| `setAuthModule(0)` | owner or guardian | all activation stops; the module is retired and can never be installed again (as built, §2.1) | everything already reserved |

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
- The module → vault call is the module's last action. The vault calls a module only once, read-only, when the owner
  installs it (`vault()` through `staticcall`, 1B-2.4); never on any other path.

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

| ID | Invariant | Test | 1B-2.1 |
|---|---|---|---|
| INV-C1 | `generation[c]` never decreases | handler ghost; `invariant_generationMonotonic` | implemented |
| INV-C2 | `Revoked` never changes | `invariant_revokedIsTerminal` | implemented (also: stays unregistered) |
| INV-C3 | No allocation is created with a signed generation ≠ current | `invariant_signedActivationUsesCurrentGeneration` | implemented in 1B-2.3 |
| INV-C4 | No consumption while Frozen or Revoked | `invariant_noConsumptionWhenFrozenOrRevoked` | implemented (also: no creation unless registered and unrestricted) |
| INV-C5 | Freeze and unfreeze never change `Q_a`, `curatorReserved`, `B_a`, `W_a`, shares or the queue | differential | implemented as `invariant_curatorActionsMoveNothing`, for every curator action and owner/guardian rotation |
| INV-C6 | Each `(curator, nonce)` is used at most once, across both paths | `invariant_noncesSingleUse` | implemented in 1B-2.3 (per module; also: no bit is ever cleared) |

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
  timelock are required before real value (`MAINNET_READINESS.md` G-1, G-2).
- **Relayer liveness** (`RISKS.md` R7). A signature still needs someone to submit it.

## 9. Changes to earlier decisions (need confirmation)

| Earlier | Now | Reason |
|---|---|---|
| D11: domain `"Porkfolio Vault"` on the vault | `"Porkfolio Curator Authorization"` on the module | the verifying contract is the module |
| D15 (`CURATOR_REVOCATION.md`): epoch in the signed struct, stored with the signatures | `generation` stored **in the vault** next to `status`, signed, checked by the vault | one source of truth for curator state; the module stays stateless apart from nonces |
| D16: no freeze check in `exchange` | **freeze and revoke stop consumption** | the approved Option 3 requires temporary suspension; measured cost in §6 |
| D6: shared struct, direct path on the vault | direct path through the module, same nonce space | one nonce store; the vault has a single entry point for creating commitments |
| `CURATOR_REVOCATION.md` R1: `isCurator` check in `_activate` | `status == Active` check in `vault.reserveFor` | the same rule, enforced by the vault, which the module cannot bypass |
