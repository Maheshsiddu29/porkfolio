# Porkfolio — Authorization Security Release Notes

**Status: local only. Nothing is deployed, and no audit or formal verification is claimed.** These notes cover the
authorization path as of branch `phase-1b-2-4-auth-security-closure`: `SharedCommitmentVault.setAuthModule` and
`reserveFor`, and `CuratorAuthorization`. They are written for the people who will operate the vault (owner, guardian,
curators, relayers). The phase report (`PHASE1B2_4_REPORT.md`) has the evidence. Labels: SOURCE (read from the code),
OBSERVED (a test asserts it; the test is named), ESTIMATE.

## 1. What changed in this release

| Area | Before | Now | Evidence |
|---|---|---|---|
| Installing a module | the owner could install any address never installed before | the candidate must also answer `vault()` with this vault's address (one `staticcall`), or the call reverts `InvalidAuthModule` | `ModuleInstallation.t.sol`, `test_PA_auth_moduleInstallCheck` |
| Installing the installed module again | accepted; left it installed **and** marked retired | reverts `AuthModuleRetired`, nothing changes | `test_MI_repeatedInstallAndIdempotentDisable` |
| Calls from the vault to a module | none | exactly one, read-only, at installation | `test_ML_vaultCallsModuleOnlyAtInstall` |
| Signed instruction times | only `validAfter <= now <= deadline` | also `validAfter <= deadline`, `deadline - validAfter <= 1 day`, `deadline < expiry`, all checked before the clock and before any wallet code | `ActivationSafety.t.sol`, `test_PA_auth_signatureTimeRules` |
| Direct path times | vault checks `deadline >= now` and expiry | the module also requires `deadline < expiry` | `test_ST_inconsistentTimesRefusedAtAnyTime` |
| EIP-712 type, domain, digest | — | **unchanged** (`test_CA_digestFixedVector` still matches the value computed outside Solidity) | |

Instructions that were valid under the old rules and are refused now: a window longer than one day, and an expiry at
or before the deadline. Curators and relayers that produced such instructions must change their defaults. Nothing
on-chain needs migrating: no deployment exists.

## 2. The owner's trust boundary

The owner is trusted. The vault limits what the **guardian**, **curators**, the **module** and **hooks** can do; it does
not protect LPs from the owner. Before real value, the owner must be a multisig behind a timelock for loosening
actions (`MAINNET_READINESS.md` G-1, G-2).

| Role | Can | Cannot |
|---|---|---|
| Owner | everything the guardian can; and register hooks and curators, raise ceilings, raise or configure flow and exposure caps, lower the buffer, lower sell floors, lift halts, unpause, unfreeze curators, install a module, appoint the guardian, transfer ownership, seed the vault | move LP assets directly (no function does), un-revoke a curator, reinstall a retired module, reach W_a (assets finalized for queued redemptions) |
| Guardian | pause, halt a direction, deregister, freeze and revoke curators, lower ceilings and caps, raise floors and the buffer, disable the module, release any allocation | any loosening action, installing a module |
| Module | ask the vault to reserve for a registered, unrestricted curator at its current generation | anything else (`reserveFor` re-checks every financial and curator condition) |
| Curator | reserve within its ceiling and the vault's limits; cancel its own allocations; bump its generation; invalidate its nonces | consume, release others' allocations, change limits |

**Worst case, owner compromised (SOURCE, reasoned from the code; not demonstrated by a test).** With every owner power
combined, an attacker registers its own hook and curator, raises ceilings and caps, and lowers one direction's sell
floor. The directional consistency rule (the product of the two floors must stay at least 1) does not stop this: the
attacker raises the opposite floor (to at most 2^160 − 1, which allows a floor as low as 2^32 + 1 in Q64.96, about
2^-64) and sells one asset through its own hook at a price just above the lowered floor. Speed is bounded only by flow caps that the same key can
raise. Assets already finalized for queued redemptions (W_a) are never reachable: they are excluded
from N_a, so admission never lets an allocation take them. Queued shares that are not yet finalized still bear the
losses.

**What the installation check changes, and what it does not.** It catches mistakes: a module built for another vault,
a wrong address, an address without code, an unrelated contract, a contract that reverts. It cannot detect a
malicious or incorrect module, because the module itself answers the question. Any contract can return this vault's
address from `vault()`. The tests show that a malicious module, a contract that is not a module at all, and **both
consumer hooks** pass it (the hooks have a public `vault()` getter that names this vault; `test_MI_rightAnswerIsNotProofOfAModule`).
A hook installed by mistake creates nothing (it has no code that calls `reserveFor`) and keeps its consumer role when
replaced, but new allocations stop until a real module is installed. Before installing a module, the owner must still:

1. verify the deployed runtime code against a reviewed build (`MAINNET_READINESS.md` X-2);
2. confirm `vault()`, `eip712Domain()` and `MAX_VALIDITY_WINDOW()` read back as expected;
3. route the installation through the timelock (it is a loosening action).

A module that is installed is bounded by `reserveFor`: at worst it equals every registered, unrestricted curator
signing whatever the attacker wants, within their ceilings and every vault limit (`test_ML_compromisedModuleBoundedByVault`).

## 3. Permanent retirement of a module

Every module that leaves office, by replacement or by a guardian or owner disable, is retired for good. A retired
module can never be installed again, by anyone.

**Why.** The module's address is the EIP-712 verifying contract, and its nonce bitmap is its own. If a disabled module
could come back, every instruction signed for it and not yet used would become valid again, possibly long after the
curator stopped expecting it.

**Operational consequences.**

- **A disable is irreversible for that instance.** After `setAuthModule(address(0))`, resuming means deploying a new
  module, checking it (§2), and installing it through the owner.
- **Every outstanding signature dies.** Curators must sign again for the new module's domain. Relayers and
  front-ends must read `authModule()` (or follow `AuthModuleSet` events) and use the new domain; there is no
  on-chain list of retired modules to query (the mapping is internal), so off-chain systems should index the events.
- **Nonces do not carry over.** The new module has fresh bitmaps. A nonce used in the old module can be used again in
  the new one; that is safe because old signatures do not verify under the new domain (`test_MI_retiredModuleReplay`).
- **Allocations are unaffected.** Allocations created through a retired module stay consumable, cancellable and
  releasable. Swaps and every LP path never involve the module.
- **Disabling is idempotent.** Setting zero when no module is installed succeeds (it only emits `AuthModuleSet(0, 0)`),
  so two guardians acting at once cannot make the second disable fail.
- **For a temporary stop, do not disable.** Use a reversible control instead: lower the vault-scope exposure caps to
  zero (`setRiskLimit`; the guardian may lower, only the owner raises again), deregister specific curators, or pause.
  Disable the module when the module itself is suspect.
- **Each retirement leaves one storage slot set for ever.** This costs nothing at run time and is bounded by the number
  of installations.

**Module-compromise runbook.** (1) Guardian: `setAuthModule(address(0))`; new allocations stop in that transaction.
(2) Guardian: `release` the suspicious allocations, identified from the module's `Activated` and the vault's
`AllocationCreated` events. (3) Owner: deploy, verify and install a new module (§2). (4) Curators: re-sign.

## 4. Nonce and generation exhaustion

**Nonces cannot run out.** Each curator has a 2^256-entry bitmap per module, and nonces may be used in any order.
Only the curator can spend its nonces without a signature (`invalidateNonces`, up to 256 per call, own bitmap only).
Anyone holding a valid signed instruction can spend that one nonce, by activating it within its window; that is the
point of signing it.

**Generations can run out, in theory.** The generation is a `uint32` per curator and never wraps.

- What raises it: the curator's own `bumpGeneration`, deregistration (owner or guardian), and `unfreezeCurator` (owner).
- Reaching `type(uint32).max` takes 4,294,967,295 separate transactions. ESTIMATE: at roughly 30,000 gas each that is
  about 1.3 × 10^14 gas, far beyond any realistic budget; but a curator could in principle do it to itself.
- At the maximum (OBSERVED, `test_CA_generationExhausted`): every increment reverts `GenerationExhausted`. So
  `bumpGeneration`, **deregistration** and **unfreeze** of that curator revert for ever. Instructions signed at the
  final generation still activate, and the curator can still invalidate individual nonces.
- What still works: `freezeCurator` and `revokeCurator` never touch the generation, so the guardian can always stop
  such a curator. **Runbook:** if deregistration reverts with `GenerationExhausted`, freeze or revoke instead.
- No other curator is affected.

## 5. Signature validity policy

Rules enforced by `CuratorAuthorization.activate` (SOURCE), in this order, before the clock and before any wallet code:

```
validAfter <= deadline                       else InvalidValidityWindow
deadline - validAfter <= 1 day               else ValidityWindowTooLong
deadline < expiry                            else ExpiryNotAfterDeadline
validAfter <= now <= deadline                else AuthorizationNotYetValid / AuthorizationExpired
expiry <= now + MAX_HORIZON (30 days)        else HorizonExceeded (vault)
```

What this guarantees: an instruction is usable for at most one day once its window opens; every allocation an
instruction creates is still live when the window closes; inconsistent instructions fail with a precise error at any
time and never cost a relayer a wallet call. A curator who wants a minimum allocation lifetime L sets
`expiry >= deadline + L`.

**What it cannot guarantee without an issuance-time commitment.** The module cannot know when an instruction was
signed: `validAfter`, `deadline` and `expiry` are all the signer's choice. A curator can sign today for a window that
opens in a year, and it will be valid then, for up to a day (OBSERVED, `test_ST_futureDatedSignature`). The window
bound limits how long a leaked instruction stays usable after it becomes valid; it does not limit how long a signed
instruction can lie dormant. Closing that needs a signed `issuedAt` field and a maximum age, which is a new EIP-712
type (version `"2"`) and was not done here. Even then, a compromised key can sign any `issuedAt`; only the generation
and the curator's status stop a compromised key.

Tools against dormant instructions today: `invalidateNonces` (one or more specific nonces), `bumpGeneration` (every
outstanding instruction of that curator), deregistration or unfreeze (raise the generation), and module retirement
(every instruction for that module). Curators should sign windows that open now and keep them short.

The direct path (`activateDirect`) has no `validAfter` and no window bound: the request is the curator's own
transaction. It does require `deadline < expiry`, so the same request has the same outcome on both paths.

## 6. ERC-1271 wallets and relayer gas

A relayer that submits an instruction for a contract-wallet curator runs that wallet's `isValidSignature` and pays
for it.

- **Gas.** OpenZeppelin 5.0.2 `SignatureChecker` calls the wallet with `staticcall` and forwards all but 1/64 of the
  remaining gas. A wallet that loops burns it; the activation then runs out of gas and reverts, and the relayer pays
  (OBSERVED, `test_CA_1271_gasBurnerAndReturnBomb`).
- **Return data.** The library copies the wallet's entire return data into memory before decoding it, so a wallet
  that returns a large payload makes the relayer pay for memory expansion. A payload whose first word is the magic
  value is accepted if the relayer pays for all of it.
- **Writes under `staticcall`.** A wallet that tries to write (for example to re-enter the vault) halts and consumes
  all gas forwarded to it. A wallet that swallows that failure and approves leaves the module about 1/64 of the gas;
  with an ordinary limit the activation runs out of gas (OBSERVED, `test_CA_1271_reentrancyIsStatic`). Nothing changes
  on-chain in any case.
- **Simulation is not a guarantee.** A wallet can answer differently in simulation and on-chain (for example by
  reading the timestamp or `gasleft()`). The relayer then pays for a failed transaction.
- **No compensation.** The protocol does not pay relayers. A failed activation costs the submitter only; it spends no
  nonce and changes no state (OBSERVED, `test_W_failuresLeaveNoTrace`).
- **New in this release:** time and consistency checks run before the wallet is called, so an expired, early or
  inconsistent instruction never runs wallet code (OBSERVED, `test_ST_timeChecksRunBeforeWalletCode`).

**Relayer guidance.** Set an explicit gas limit (the measured cost of a signed ERC-1271 activation is about 319,000
gas on the production builds, `PHASE1B2_4_REPORT.md` §6); simulate first; consider allow-listing wallet code hashes;
treat repeated failures from one wallet as griefing. A curator can always bypass relayers with `activateDirect`.

## 7. Limits of the fixed one-day flow window

Flow caps (`RiskLimit.flowCap`) bound the gross output paid under a hook, a curator and the whole vault per window.
The window is a fixed epoch, `floor(block.timestamp / 86,400)`, aligned to 00:00 UTC (SOURCE, `FLOW_WINDOW`).

- **Boundary burst.** A scope can pay its full cap in the last second of one epoch and its full cap again in the first
  second of the next: up to 2 × cap within two seconds, and up to (ceil(T / 1 day) + 1) × cap in any T seconds. Size
  caps for twice the amount you can tolerate in a short period.
- **Predictable reset time.** Everyone knows when usage resets. Expect demand to bunch around 00:00 UTC.
- **Gross, not net.** Inflows are never netted against outflows, so trading back and forth uses the cap in both
  directions. This is deliberately conservative.
- **Amount, not price.** The cap says nothing about the price received; only the floors bound that.
- **Not configurable.** `FLOW_WINDOW` is a constant. A different window needs a new vault.
- **Timestamps.** On an L2 the sequencer sets `block.timestamp`; it can shift a trade across an epoch boundary by a
  few seconds within the chain's rules. Unichain's timestamp behaviour has not been checked (`MAINNET_READINESS.md`
  F-3).
- **Unrelated to `MAX_VALIDITY_WINDOW`.** Both happen to be one day; they bound different things (flow per epoch,
  and how long a signed instruction is usable).
- A rolling window or a decaying bucket would remove the boundary burst. Neither is implemented; a rolling window costs
  vault bytecode, and the vault has 2,052 bytes of EIP-170 margin left.

## 8. Checklist for operators

- [ ] Owner is a multisig; installing a module, registering hooks and curators, and every loosening action go through
      a timelock.
- [ ] Before installing a module: code verified against the reviewed build; `vault()`, `eip712Domain()` and
      `MAX_VALIDITY_WINDOW()` read back.
- [ ] Guardian runbooks for module compromise (§3) and for a curator whose generation is exhausted (§4).
- [ ] Curators sign windows that open now, one day at most, with `expiry` at least the minimum lifetime after the
      deadline.
- [ ] Relayers set gas limits for ERC-1271 curators and follow `AuthModuleSet` events.
- [ ] Flow caps sized for the 2 × cap boundary burst.
