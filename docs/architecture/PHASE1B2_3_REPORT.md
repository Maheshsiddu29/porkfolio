# Porkfolio — Phase 1B-2.3 Report: EIP-712 Curator Authorization

**Status: DONE, waiting for review.** Branch `phase-1b-2-3-curator-authorization`, created from
`phase-1b-2-2-flow-limits` at `29297a3`. This step changes the trust boundary as approved (architecture B): a separate
`CuratorAuthorization` contract verifies who is asking for a reservation, and the vault's new `reserveFor` decides
whether capital may be reserved. The vault's `allocate` and `nonceUsed` are removed. Cumulative pricing, rolling
windows and epoch expiry are not part of this step and were not started. Labels: SOURCE (read from the code), OBSERVED
(measured or asserted by a test; the command is given), ESTIMATE.

| Commit | Content |
|---|---|
| `1106025` | `feat(auth)`: `CuratorAuthorization`, `ICuratorAuthorization`; vault `reserveFor`, `setAuthModule`, retired-module list; `allocate`/`nonceUsed` removed; admission from E_a; the whole suite migrated to the module's direct path (no test removed) |
| `aa45c42` | `test(auth)`: `CuratorAuthorization.t.sol` (30 tests), `AuthModuleLifecycle.t.sol` (8), `Mock1271Wallet`, `MaliciousAuthModule`, `AuthTestBase` |
| `890b84c` | `test(invariant)`: signed activations, nonces and module lifecycle in the handler; INV-C3, C6, M2, M8 |
| `c9db475` | `test(bench)`: six module scenarios on production artifacts; activation, nonce and module gas; `.github/workflows/security.yml` |
| this commit | this report; `MODULAR_RISK_ENGINE.md`, `CURATOR_SECURITY_MODEL.md`, `MAINNET_READINESS.md`, `PHASE1B2_IMPLEMENTATION_PLAN.md`, `README.md` |

## 1. Contract-size feasibility gate (before implementation)

The vault had 2,215 B of margin under EIP-170 and must keep at least 2,048 B. Before writing the real code, a script in a
scratch worktree built exact, asserted source variants of the vault at its production setting (2,000 runs) and recorded
the runtime size of each (OBSERVED, `forge build src --sizes`, Foundry 1.7.1).

| Variant | Runtime (B) | Margin (B) | Δ |
|---|---|---|---|
| 1B-2.2 vault (`29297a3`) | 22,361 | 2,215 | — |
| A: `allocate` and `nonceUsed` removed | 18,725 | 5,851 | −3,636 (the cost of the old entry point) |
| B: A + `reserveFor(req, curator, generation, signed)` + a one-line `setAuthModule` | 22,532 | **2,044** ✗ | +3,807 over A |
| C: B + a separate enable/disable flag, a retired list, and a `module.vault()` call at install | 23,073 | **1,503** ✗ | +541 over B |
| D: `reserveFor(req, curator, generation)` (generation always checked), one-way retirement on replace or disable, no call to the module | 22,600 | **1,976** ✗ | |
| D-min: D with argument-free new errors | 22,578 | **1,998** ✗ | −22 |
| D-ref: D + `currencyIn` from the existing `_otherAsset` | 22,460 | 2,116 | −140 |
| D-adm: D + admission computed from E_a once | 22,573 | 2,003 ✗ | −27 |
| **D-ref-adm (built)** | **22,433** | **2,143** | −167 |

Readings:

- Replacing `allocate` with a module-restricted `reserveFor` costs slightly more than it saves (the vault must decode two
  more arguments and check the caller and the generation), so the swap was not enough on its own.
- A separate enable flag plus a vault→module call at install cost 541 B and also add the only vault→module call. Both
  were dropped: disabling retires the module (§4.4), and the module is bound to its vault by its own immutable and by
  the signed `vault` field.
- The final design fits through two refactors that change no result: the input currency comes from `_otherAsset`
  (the key's currencies are checked to be the pair just before), and the admission limit and the exposure caps share one
  E_a = N_a − D_a (previously D_a was computed twice). `admissibleCapacity` returns exactly what it did:
  max(0, max(0, E_a − Q_a) − R_a) equals max(0, N_a − Q_a − R_a − D_a) because every term is non-negative and
  D_a ≤ N_a. The existing admission, lens and invariant tests pass unchanged.
- No risk check was removed, no error lost its arguments, the optimizer setting is unchanged and there is no further
  contract split.
- No new external call runs during a swap: `exchange` is byte-for-byte the same code path, and the measured swap gas is
  unchanged (§9).

## 2. Final authorization architecture

```
Curator (EOA or ERC-1271 wallet)
   │ signs AllocationAuthorization (EIP-712)          │ or calls activateDirect(req) itself
   ▼                                                  ▼
Relayer (anyone) ──activate(auth, key, sig)──► CuratorAuthorization ──reserveFor(req, curator, generation)──► Vault
                                                 │ checks signed fields                   │ only from authModule
                                                 │ verifies signature (staticcall 1271)   │ every financial and
                                                 │ sets the nonce bit                      │ curator-state check
                                                 └ vault call is the last action           └ Q, curatorReserved, hookReserved += maxOut
```

| Contract | Holds | On the swap path | On LP paths | Upgradeable |
|---|---|---|---|---|
| `SharedCommitmentVault` | custody, shares, queue, commitments, curator records (registration, restriction, generation), risk limits, `authModule`, retired list | yes | yes | no |
| `CuratorAuthorization` | EIP-712 domain, one nonce bitmap per curator, immutable `vault` | **no** | **no** | no (no owner, no admin function) |

`CuratorAuthorization` (SOURCE):

- `activate(auth, key, signature)`: anyone submits a signed instruction.
- `activateDirect(req)`: the curator is `msg.sender`.
- `invalidateNonces(wordPos, mask)`: the caller sets bits in its own bitmap.
- views: `vault()`, `hashAuthorization(auth)`, `domainSeparator()`, `nonceBitmap(curator, word)`,
  `isNonceUsed(curator, nonce)`, `ALLOCATION_AUTHORIZATION_TYPEHASH`, ERC-5267 `eip712Domain()`.
- It cannot transfer claims, change any limit, register anyone, touch LP balances or reservation counters directly,
  swap, cancel, release or change custody: it has no function that calls the vault except `reserveFor`, and the vault
  gives it no other right (`test_ML_compromisedModuleBoundedByVault`).

OpenZeppelin 5.0.2 is used as vendored in v4-core, now through an explicit `@openzeppelin/contracts/` remapping (the
bytecode is identical with and without it, checked by hash): `EIP712` (domain, cached separator rebuilt on a chain-id
change, ERC-5267) and `SignatureChecker` (ECDSA through `ECDSA.tryRecover`, then ERC-1271). No cryptography is written by
hand.

## 3. EIP-712 schema and domain

**Domain:** `EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)` with name
`"Porkfolio Vault"`, version `"1"`, the live chain id and the module's address. No salt.

**Type:**

```
AllocationAuthorization(address curator,uint32 generation,address vault,bytes32 poolId,address hook,
  address currencyIn,address currencyOut,bool zeroForOne,uint128 maxOut,uint160 minInPerOutX96,uint64 expiry,
  uint64 validAfter,uint64 deadline,uint256 nonce)
```

| Field | Why it is signed | How it is checked |
|---|---|---|
| `curator` | the authorizer | signature must be valid for it |
| `generation` | kills instructions after a deregistration, unfreeze or bump | vault: equal to the current generation |
| `vault` | binds the instruction to one vault | module: equal to its immutable vault |
| `poolId` | one pool (commits to both currencies, fee, tick spacing and hook) | module: `keccak256(key)` of the submitted key |
| `hook` | the consumer | module: equal to `key.hooks`; vault: registered and equal to `key.hooks` |
| `currencyIn`, `currencyOut`, `zeroForOne` | the assets and direction, readable in the wallet | module: one direction of the key (zeroForOne ⇔ currency0 in, currency1 out); vault: pair and direction configured |
| `maxOut` | capacity | vault: non-zero, ≤ MAX_AMOUNT, ceiling, admission, exposure caps |
| `minInPerOutX96` | curator floor, Q64.96 | vault: ≥ live vault floor |
| `expiry` | **added field**: the allocation's lifetime, which the vault's model requires | vault: in the future and ≤ now + MAX_HORIZON at activation |
| `validAfter`, `deadline` | activation window, both inclusive | module; the vault checks `deadline` again |
| `nonce` | single use | module bitmap |

`currencyIn` and `zeroForOne` are redundant with `poolId` and `currencyOut`. They are signed because the task asked for
both assets and the direction, and the module rejects an instruction whose fields disagree with each other
(`DirectionMismatch`), so a wallet that displays them shows what will happen.

**Digest:** `hashAuthorization(auth) = keccak256("\x19\x01" ‖ domainSeparator ‖ keccak256(abi.encode(TYPEHASH, auth)))`.
Every field is a static type, so `abi.encode(TYPEHASH, auth)` is EIP-712's `encodeData` (one 32-byte word per field).

**Independent checks (OBSERVED):**

- `test_CA_digestFixedVector`: the digest of a fixed message under a fixed module address (`0x…A11CE`), vault
  (`0x…5AFE`) and chain id 130 equals a value computed outside Solidity with `cast abi-encode` and `cast keccak`:
  typehash `0xcb4cfc77…04761c5`, domain separator `0x7eadba32…eb966b98`, digest
  `0x36606823eec29c7e90a97c3aae053e20ecf83a162fa41db44e9a6f66c4c029e7`.
- `testFuzz_CA_digestMatchesIndependentEncoders` (1,000 runs default, 10,000 in CI): for arbitrary messages the digest
  equals a field-by-field Solidity encoding and Foundry's typed-data encoder (`eip712HashTypedData`, Rust/alloy) given
  the message as JSON.
- `test_CA_typehashAndDomain`: ERC-5267 fields, and the separator equals a manual encoding.

## 4. Vault / module trust boundary

### 4.1 What each side decides

| Question | Decided by | Where |
|---|---|---|
| Did this curator authorize exactly this request, once? | module | signature or `msg.sender`; nonce bitmap; signed-field checks |
| Is the caller of `reserveFor` the installed module? | vault | `msg.sender == authModule` |
| Is the curator registered, unrestricted and at this generation? | vault | `_curators[curator]` |
| Hook registered and equal to `key.hooks`; pool currencies equal the pair; direction configured and not halted; floor ≥ vault floor | vault | `reserveFor` |
| `0 < maxOut ≤ MAX_AMOUNT`; expiry in (now, now + MAX_HORIZON]; deadline not passed | vault | `reserveFor` |
| Curator ceiling; admission Q_a + q + R_a + D_a ≤ N_a (protects queued LP withdrawals and claimables) | vault | `reserveFor` |
| Hook, curator and vault exposure caps, and that their records are configured | vault | `reserveFor` |
| Unique allocation id | vault | `nextAllocationId++` |

The vault does not take a boolean from the module: the module's only statement is the call itself, with `curator` and
`generation` as arguments, and everything else is recomputed by the vault from its own state.

### 4.2 Compromise assumptions (OBSERVED, `test_ML_compromisedModuleBoundedByVault`, `test_PA_auth_compromisedModuleBounded`)

A module that forges `reserveFor` calls without any signature is still refused for: an unregistered curator; a frozen or
revoked curator; a stale or future generation; a request above the curator's ceiling; a floor below the vault floor; an
unregistered hook or a hook that is not the key's; zero capacity; an expired deadline; an expiry beyond the horizon;
the hook's exposure cap; insufficient backing; and a paused vault (`test_CA_failedActivationDoesNotConsumeNonce`). It
cannot call `exchange` (not a consumer), cancel (not the curator), release before expiry, set limits or unfreeze. It
holds no claims.

**Impact of a compromised or buggy module:** equivalent to every registered, unrestricted curator signing whatever the
attacker wants: reservations up to each curator's ceiling, for registered hooks, at floors no lower than the vault's,
within admission and the exposure caps. Assets leave only through `exchange`, so loss additionally requires a hook that
prices badly and stays within the flow caps (`PHASE1B_THREATS_AND_PLAN.md` T-01).

**Response:** the guardian calls `setAuthModule(address(0))` (one transaction; new allocations stop at once), then
releases suspicious allocations with `release` (identified from `Activated` and `AllocationCreated` events); the owner
deploys and installs a new module.

### 4.3 No call cycle, not on the hot paths

- The vault has no reference to the module's interface and never calls it (SOURCE). `test_ML_vaultNeverCallsModule`
  asserts zero calls to two modules across a swap, a deposit, a queued redemption, queue processing, a claim, a
  cancellation, a risk-limit change and two module changes (`vm.expectCall` with count 0; checked to fail when a call
  is made).
- Swap and LP gas are unchanged (§9). Disabling the module leaves swaps, cancellation, release, deposits, redemptions,
  queue processing and claims working (`test_ML_disableStopsOnlyNewActivations`,
  `test_PA_auth_disableReplaceAndLpPaths`).

### 4.4 Installation, disable, retirement and replacement

`setAuthModule(address module)` (SOURCE):

| Caller | May set | Effect |
|---|---|---|
| owner | any address never installed before, or zero | the current module (if any) is retired; `authModule = module` |
| guardian | zero only | the current module is retired; no module is installed |
| anyone else | nothing (`NotOwner`) | — |

- A retired module can never be installed again (`AuthModuleRetired`), by anyone. This covers both a replaced module and
  a disabled one, so its unused signatures and its nonce state can never regain authority.
- A guardian disable is therefore permanent for that module instance. To resume, the owner deploys and installs a new
  module, and curators sign again for its domain. A reversible stop of new allocations already exists: the guardian
  lowers the vault-scope exposure caps to zero (`setRiskLimit`), and the owner raises them again; or deregistration, or
  pause.
- Installing a new module invalidates every signature made for the old one, because the domain's verifying contract is
  different (`test_ML_replacementInvalidatesOldSignatures`).
- A module records its vault at deployment and only ever calls that vault. A module built for another vault and
  installed here by mistake can create nothing here (`test_ML_moduleForAnotherVaultCannotReserveHere`).
- A vault with no module creates no allocation (`test_ML_noModuleFailsClosed`).
- Nothing else changes on a module change: flow usage, exposure records, curator records, allocations, Q_a, B_a, W_a,
  shares and the queue are untouched (`invariant_moduleLifecycle`, `_riskRecords` checks).
- The module is not upgradeable and has no owner.

## 5. Nonces, generations and module retirement

### 5.1 Nonce bitmap

Nonce n of a curator is bit `n % 256` of word `n / 256` of that curator's bitmap in that module. Example: nonce 515 is
bit 3 of word 2 (`test_CA_invalidateNoncesAndBitmapLayout`).

| Rule | Evidence |
|---|---|
| A nonce activates at most once, through either path | `test_CA_duplicateNonce_sameAndDifferentMessage`, `test_CA_signedAndDirectShareNonces`, `invariant_noncesSingleUse` |
| A reverted activation does not spend the nonce (the bit is set in the same transaction as the vault call) | `test_CA_failedActivationDoesNotConsumeNonce`; every failure test asserts the bit is clear |
| An invalidated nonce cannot activate; invalidation is idempotent and only touches the caller's bitmap | `test_CA_invalidateNoncesAndBitmapLayout` |
| Curators have independent bitmaps | `test_CA_curatorsHaveIndependentNonces` |
| Bits are never cleared (no function clears one; the invariant re-reads every recorded bit) | `invariant_noncesSingleUse` |
| Nonce state is never reset by retirement or reinstatement: a retired module keeps its bitmap and can never be reinstalled; a new module has a new domain | `test_ML_retiredModuleNeverReinstalled` |

### 5.2 Generations

The generation is the vault's per-curator `uint32` counter from 1B-2.1. `reserveFor` rejects any request whose
generation is not the current one (`StaleGeneration(curator, authorized, current)`), also a future one.

| Event | Generation | Outstanding signatures | Evidence |
|---|---|---|---|
| curator calls `bumpGeneration` | +1 | dead | `test_CA_generationBumpInvalidatesOutstanding` |
| deregistration (owner or guardian) | +1 | dead; re-registration does not lower the counter, so they stay dead | `test_CA_deregisterReregisterCannotRevive` |
| freeze | unchanged | refused while frozen (`CuratorRestricted`) | `test_CA_freezeUnfreezeAndRevoke` |
| unfreeze (owner) | +1 | dead | same |
| revoke | unchanged | refused for ever (`Revoked` is terminal) | same |

**Overflow (permanent failure behaviour).** The counter never wraps. At `type(uint32).max` every increment reverts with
`GenerationExhausted`, so `bumpGeneration`, deregistration and `unfreezeCurator` revert for that curator for ever. What
still works (`test_CA_generationExhausted`): signatures made at that generation activate; the curator can invalidate
individual nonces; freeze and revoke (which never touch the generation) still stop it. Reaching the maximum takes
2^32 − 1 increments, each a separate transaction by the curator, the owner or the guardian. A curator that exhausts its
own counter can then only be stopped by freeze or revoke, which the guardian can always do.

### 5.3 Direct path

`activateDirect(req)` takes the curator from `msg.sender` only; no curator address is accepted from input
(`test_CA_directPath_curatorIsCaller`). It consumes `req.nonce` from the same bitmap. That is deliberate: a curator who
signed an instruction for a relayer and then submits the same instruction itself cannot end up with two allocations,
whichever arrives first; and a retried submission is idempotent. The module passes the vault's current generation (read
in the same call), so the vault's generation check always passes here; every other vault check applies exactly as for
a signed instruction. `testFuzz_CA_directAndSignedEquivalent` fuzzes size, floor, lifetime, pool and direction and
asserts that the two paths return the same allocation id or the same revert data, and leave the same allocation record
and reservation counters.

No entry point other than `reserveFor` creates an allocation (`allocate` is gone), and `invariant_onlyInstalledModule
CreatesAllocations` checks that every id assigned during the campaign belongs to an activation through the installed
module. Allocation identity and closure are unchanged: ids only increase, and `_close` still closes an allocation
exactly once.

## 6. Signature validation, ERC-1271 and reentrancy

| Case | Result | Test |
|---|---|---|
| valid EOA signature, any submitter | activates the exact signed allocation; consumable by the hook | `test_CA_signedEOA_relayerActivates_thenSwap`, `test_PA_auth_signedEoaAnd1271_activateAndSwap` |
| wrong signer; the relayer's own valid signature | `InvalidSignature`; `CuratorNotRegistered` (a valid signature does not make the relayer a registered curator) | `test_CA_wrongSigner` |
| empty, 64-byte (EIP-2098), 66-byte, high-s twin, v = 0/1, all zeros, garbage for curator 0 | `InvalidSignature` | `test_CA_malformedSignatures` |
| any one signed field edited by the relayer (17 variants) | rejected (field check or signature) | `test_CA_everySignedFieldIsBound` |
| valid ERC-1271 wallet | activates; the signature bytes are the wallet's business | `test_CA_1271_validWallet` |
| wallet not approving, wrong magic, revert, 1-byte return; ECDSA signature for a wallet curator | `InvalidSignature`, nonce unused | `test_CA_1271_failuresFailClosed` |
| gas-burning wallet; 1 MB return | the submitter's call runs out of gas (bounded budgets: reverts, nonce unused); a bomb whose first word is the magic value is accepted if the submitter pays for it | `test_CA_1271_gasBurnerAndReturnBomb` |
| wallet withdraws approval after activation | future instructions fail; the existing allocation is unchanged, consumable and cancellable | `test_CA_1271_revokedApprovalLeavesExistingAllocation` |
| wallet re-enters (cancel its live allocation, invalidate the nonce being used, activate again) from `isValidSignature` | runs under `staticcall`: the write fails inside the wallet; nothing changes | `test_CA_1271_reentrancyIsStatic`, `test_PA_auth_reentrantWalletIsStatic` |

**Observed behaviour worth knowing.** A write attempted under `staticcall` is an exceptional halt that consumes all the
gas forwarded to that call (63/64 of the wallet's gas, itself 63/64 of the module's). A wallet that swallows the failure
and approves leaves the module about 1/64 of the submitted gas, so with an ordinary budget the activation runs out of
gas and reverts; only a submitter who pays roughly 64 times the normal cost gets it through, once. Either way no state
changes and the cost falls on the submitter. Relayers should set a gas limit.

**EIP-7702 note.** `SignatureChecker` tries ECDSA first, so an EOA that delegates its code still signs with its own key;
changing its code cannot revoke a key. Generation and status remain the revocation tools.

The module has no reentrancy guard: the only foreign code it runs is the wallet inside `staticcall`, and the vault call
is its last action. The vault's `reserveFor` keeps the transaction lock (`Reentrancy.t.sol`: a token callback reaching
`reserveFor` through the module fails with `ReentrantCall`).

## 7. Invariants, fuzzing, mutations and static analysis

### 7.1 Commands and results

All at `c9db475` (implementation complete), Foundry 1.7.1, in the order of the validation script.

| Command | Result |
|---|---|
| `forge fmt --check` | clean |
| `test/bench/run.sh` | exit 0; every production artifact records its expected settings; vault margin 2,143 B (≥ 2,048) |
| `forge build --force --sizes` | exit 0 |
| `test/bench/security.sh` (`FOUNDRY_PROFILE=ci`, 10,000 fuzz runs) | ProductionBuilds 2/2; ProductionArtifactSecurity 18/18; full suite **376/376** in 29 suites |
| `FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-contract VaultInvariantsTest` | 30/30 (26 invariants, 32,768 calls each, 0 reverts; 4 progress tests) |
| `forge test` (default profile, 1,000 fuzz runs) | **376/376** |
| `slither . --filter-paths "lib/\|test/" --exclude-dependencies` | 30 results (27 at 1B-2.2); triage in §7.4 |
| `forge test --match-path test/bench/ProductionArtifactGas.t.sol --isolate -vv` | 28/28; numbers in §9 |

Test count: 322 at 1B-2.2, 376 now (+30 `CuratorAuthorization`, +8 `AuthModuleLifecycle`, +6 production-artifact
security, +5 gas benchmarks, +4 invariants and 1 progress test). No test was removed: the 84 direct
`allocate` call sites and the three vault-nonce tests were migrated to the module's direct path with the same
assertions (the nonce error now comes from the module).

### 7.2 Stateful campaign

New handler actions: `activateSigned` (EOA signatures by three curators, submitted by a relayer; one in four with a
stale or future generation; half with nonces from a small range shared with direct allocations and invalidations; one in
four sent to a random module including retired ones), `invalidateNonce`, `moduleReplace` (a fresh production-build
module), `moduleDisable` (guardian or owner), `moduleTryReinstall` (a retired module by the owner, any module by the
guardian). 38 selectors.

| ID | Invariant | Function |
|---|---|---|
| INV-C3 | every signed activation named the curator's generation at that moment | `invariant_signedActivationUsesCurrentGeneration` |
| INV-C6 | a (module, curator, nonce) activates at most once across both paths and invalidation; a reverted activation spends nothing; no recorded bit is ever cleared | `invariant_noncesSingleUse` |
| INV-M2 | every allocation id assigned since setUp comes from an activation the handler saw succeed through the installed module | `invariant_onlyInstalledModuleCreatesAllocations` |
| INV-M8 | a module change moves no asset, share, queue entry, reservation, risk record or curator record; retired modules never return; the guardian never installs one | `invariant_moduleLifecycle` |

All earlier invariants (backing, conservation, queue, floors, curator lifecycle, flow and exposure) keep running with the
new actions. `test_handler_authProgress` drives a fixed sequence through every new action and asserts the counters and
flags move.

### 7.3 Mutation checks

Scratch worktree at `c9db475`, one asserted text replacement per mutant, `forge test --fail-fast` on the default
profile, source restored after each (script kept outside the repository). The test named is the first failure.

| ID | Mutation | Result |
|---|---|---|
| A1 | nonce bit never set | killed: `test_ML_retiredModuleNeverReinstalled` |
| A2 | used nonce accepted | killed: `test_PA_auth_replayAndBindingMatrix` |
| A3 | direct path spends no nonce | killed: `test_CA_signedAndDirectShareNonces` |
| A4 | direct path uses another bitmap | killed: `test_RE_hook_unexpectedNestedCalls_revertAtomically` |
| A5 | signature not checked | killed: `test_PA_auth_disableReplaceAndLpPaths` |
| A6 | ERC-1271 only (ECDSA dropped) | killed: `test_ML_disableStopsOnlyNewActivations` |
| A7 | direct path trusts tx.origin | killed: `test_gas_allocate` |
| A8 | signed path passes the current generation | killed: `test_PA_auth_replayAndBindingMatrix` |
| A9 | vault field not checked | killed: `test_ML_moduleForAnotherVaultCannotReserveHere` |
| A10 | validAfter not checked | killed: `test_CA_validityWindowAndExpiry` |
| A11 | deadline not checked by the module | killed: `test_CA_validityWindowAndExpiry` |
| A12 | pool key not bound to poolId | killed: `test_CA_everySignedFieldIsBound` |
| A13 | hook not bound | killed: `test_CA_everySignedFieldIsBound` |
| A14 | direction not checked | killed: `test_CA_everySignedFieldIsBound` |
| A15 | type string field order changed | killed: `test_CA_typehashAndDomain` |
| A16 | a signed field left out of the struct hash | killed: `testFuzz_CA_digestMatchesIndependentEncoders` |
| V1 | reserveFor accepts any caller | killed: `test_ML_compromisedModuleBoundedByVault` |
| V2 | generation not checked | killed: `test_ML_compromisedModuleBoundedByVault` |
| V3 | registration not checked | killed: `test_ML_compromisedModuleBoundedByVault` |
| V4 | restriction not checked at creation | killed: `test_ML_compromisedModuleBoundedByVault` |
| V5 | backing not checked | killed: `test_ML_compromisedModuleBoundedByVault` |
| V6 | eligible backing ignores queue demand | killed: `testFuzz_AC_allocateAgreesWithReference` |
| V7 | curator ceiling not checked | killed: `test_ML_compromisedModuleBoundedByVault` |
| V8 | reserveFor not paused | killed: `test_CA_failedActivationDoesNotConsumeNonce` |
| V9 | reserveFor not locked | killed: `test_RE_depositWindow_everyLockedEntryPointRejectsReentry` |
| L1 | retired module can be reinstalled | killed: `test_ML_retiredModuleNeverReinstalled` |
| L2 | replaced module not retired | killed: `test_ML_retiredModuleNeverReinstalled` |
| L3 | guardian may install a module | killed: `test_ML_onlyOwnerInstalls_guardianOnlyDisables` |
| L4 | unfreeze does not raise the generation | killed: `test_CA_freezeUnfreezeAndRevoke` |
| L5 | deregistration does not raise the generation | killed: `test_CA_deregisterReregisterCannotRevive` |

**30 of 30 killed.** Two are killed only by the exact error, because a second layer still blocks the attack: A11 (the
vault re-checks `deadline` and reverts `InstructionExpired`) and A13 (the vault requires `consumer == key.hooks`, and
the pool id already commits to the hook). Both checks stay in the module so a relayer gets the precise reason.

### 7.4 Slither

30 results against 27 at 1B-2.2 (same command). Two former `allocate` findings (cyclomatic complexity, timestamp) now
name `reserveFor`. Three are new, all in the module and all intended:

| Detector | Location | Triage |
|---|---|---|
| `reentrancy-events` (×2) | `activate`, `activateDirect`: `Activated` is emitted after `vault.reserveFor` | the event carries the id the vault returns, so it must follow the call; the callee is the module's immutable vault, which never calls back; state (the nonce bit) is written before the call |
| `timestamp` | `activate`: `validAfter` and `deadline` comparisons | intended: the activation window is time-based; a block producer can shift it by seconds only |

## 8. Production-artifact coverage

- **Functional, fuzz and invariant suite:** `VaultTestBase` now also deploys `CuratorAuthorization` from its production
  artifact (`ProductionArtifacts.authModule()`, default profile, 44,444,444 runs). `ProductionBuilds.t.sol`,
  `Reentrancy.t.sol` and `ProductionArtifactSecurity.t.sol` check it against its artifact's recorded settings and masked
  runtime hash. Modules created inside tests (second vaults, invariant replacements, the fixed-vector test) also come
  from that artifact. So every test in §6 and §7 ran against the production builds of the vault, both hooks, the lens,
  the module and the pinned PoolManager.
- **ABI-level suite** (`ProductionArtifactSecurity.t.sol`, compiled without project sources): 6 new module scenarios
  (table in `test/bench/README.md`), 18 tests in total.
- **Masked runtime hashes** (logged by `test_PA_deployedCodeIsProductionArtifacts`):

| Contract (artifact) | Masked runtime keccak256 |
|---|---|
| `SharedCommitmentVault` | `0x1070b16ccc77158785837366c071e4cede2d4bb4e5fd255bbdde3a5adc099287` (changed: new code) |
| `HookA_DynamicFee` | `0xa917ca8825bc6007b238203471b944433065195e36642745ef24cb16e2eaf29a` (unchanged from 1B-2.2) |
| `HookB_BoundedImpact` | `0xeca951d1da23b8634a6eb9d1b1b26c67863df69aabc2660bb74dbb7c0d8b8fc5` (unchanged) |
| `PoolManager` (pinned v4-core) | `0xa1d857ebc4a1ec6c1d33662732f3a056378b71c5a82a84cb42c692323bbebb48` (unchanged) |
| `CuratorAuthorization` | `0x5204ec25b76935ebf4eddecd58a4e6e9d09952e81ec0ecdd421a7b4b0a667740` (new) |

- **Not covered:** test-only contracts (`Mock1271Wallet`, `MaliciousAuthModule`, routers, scripted hooks) are compiled in
  the test files and are never deployed by the project. No comparison yet with an independent rebuild or with deployed
  code (`MAINNET_READINESS.md` X-2).

## 9. Bytecode size and gas

**Sizes (OBSERVED, `test/bench/run.sh`):**

| Contract | Runtime (B) | Init (B) | EIP-170 margin (B) | Change |
|---|---|---|---|---|
| `SharedCommitmentVault` (2,000 runs) | 22,433 | 23,042 | **2,143** | +72 |
| `CuratorAuthorization` (44,444,444 runs) | 6,812 | 7,990 | 17,764 | new |
| `HookA_DynamicFee` | 7,174 | 8,011 | 17,402 | unchanged |
| `HookB_BoundedImpact` | 6,884 | 7,721 | 17,692 | unchanged |
| `VaultLens` | 6,972 | 6,998 | 17,604 | unchanged |

**Gas (OBSERVED, `forge test --match-path test/bench/ProductionArtifactGas.t.sol --isolate`, production artifacts,
Foundry 1.7.1; "before" is the same benchmark at `29297a3` in a scratch worktree):**

| Path | Before | After | Δ |
|---|---|---|---|
| Direct allocation, first in vault (`activateDirect` → `reserveFor`) | 325,311 | 334,606 | +9,295 |
| Direct allocation, steady state, new curator | 286,624 | 295,919 | +9,295 |
| Signed activation, EOA (same state as the steady direct case) | — | 315,662 | +19,743 over direct |
| Signed activation, ERC-1271 | — | 319,074 | +3,412 over EOA |
| `invalidateNonces`, new word / same word | — | 50,586 / 33,484 | — |
| `setAuthModule` replace (owner) / disable (guardian) | — | 59,521 / 54,141 | — |
| Deploy module (CREATE) + init-code calldata | — | 1,568,176 + 116,784 | — |
| Deploy vault (CREATE) | 4,987,290 | 5,002,784 | +15,494 |
| HookA swap / HookB swap | 239,693 / 239,597 | 239,693 / 239,597 | 0 / 0 |
| HookA swap, same window / new window | 233,238 / 233,253 | 233,238 / 233,253 | 0 / 0 |
| Deposit (new LP) / initialDeposit | 149,179 / 237,469 | 149,223 / 237,513 | +44 / +44 |
| Redeem instant / processQueue(1) / claim | 160,392 / 121,985 / 135,857 | unchanged | 0 |
| Redeem queued, freeze, cancel, release, revoke (call frame in `-vvvv`) | 144,941 / 32,628 / 41,448 / 44,897 / 33,082 | 144,919 / 32,606 / 41,448 / 44,880 / 33,082 | −22 / −22 / 0 / −17 / 0 |

- Swap and LP paths do not involve the module; their differences are dispatch-order noise (±44 gas).
- The `gasleft()` rows of the last line read about 2,000 higher than before because their setup now allocates through
  the module, so the vault address is cold in the test frame when the measured call starts. Their call frames (shown)
  are unchanged. `test/bench/README.md` explains this.
- ESTIMATE of the +9,295 on the direct path: the module call (cold account and re-encoding the request), the
  `getCurator` read (about 3,700 gas, in the trace), and the module's `Activated` event. The nonce write costs the same
  as the old `nonceUsed` write.
- ESTIMATE of the +19,743 for a signed EOA activation over a direct one: calldata for the 14-field message, the key and
  the signature, two EIP-712 hashes and `keccak256` of the key, `ecrecover` (3,000), the field checks, minus the
  `getCurator` read that the signed path does not need.
- The prototype in `MODULAR_RISK_ENGINE.md` §8.2 (runs 200, different code) measured 270,158 / 283,071 / 290,560; those
  numbers are not comparable with these and are not used.

## 10. CI workflow and differences from the specifications

**CI.** The repository had no workflow (checked at `29297a3`: no `.github/`). Added `.github/workflows/security.yml`:

- triggers: push, pull request, manual; `permissions: contents: read`; `persist-credentials: false`; no secrets; no
  deployment, broadcast, publication or push; no RPC (ffi off, no forks);
- `actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683` (v4.2.2) with recursive submodules and
  `foundry-rs/foundry-toolchain@dba66c27052e63476d886f22216e119ba7e615bf` (v1.9.2), both pinned by commit SHA (looked up
  with `git ls-remote`; both are lightweight tags), Foundry `v1.7.1` (tag commit `4072e48`, the version used locally);
- steps: `forge fmt --check`; `test/bench/run.sh` (artifact settings, sizes, gas); a vault-margin check that fails
  below 2,048 B; `test/bench/security.sh` (forced rebuild, production-build checks, ABI-level security suite, complete
  suite under the CI fuzz profile).

Validated locally: each step's command ran with exit status 0 (§7.1); the YAML parses. **Not verifiable until the
branch is pushed by the owner:** that GitHub resolves the pinned actions, that the runner image provides `jq` (the
standard Ubuntu image does), the recursive submodule checkout, and the job's duration under the 90-minute timeout.

**Differences from the plan and the security model:**

| Planned | Built | Reason |
|---|---|---|
| Domain name "Porkfolio Curator Authorization" (`CURATOR_SECURITY_MODEL.md` §2) | "Porkfolio Vault" | the task specified it; the verifying contract keeps it module-specific |
| `reserveFor(req, curator, generation, signed)` | no `signed` flag; generation always compared | one rule; the direct path passes the current value |
| Guardian `setAuthModule(0)`, owner re-enables | disable retires the module; resume = new module | no way back for a module's old signatures; size (§1) |
| (C) `module.vault()` check at install | none | no vault→module call; size; a foreign module gains nothing (§4.4) |
| Struct without `currencyIn`, `zeroForOne`; field `consumer` | both added; `hook` | task field list |
| `admissibleCapacity` as before | same results, E_a computed once | size; equivalence argued in §1 and tested by the existing suite |

## 11. Outstanding security issues and residual risks

- **Module compromise** has the impact in §4.2. Runbook: guardian `setAuthModule(0)`; release suspicious allocations
  (events give the ids); owner installs a new module; curators re-sign. Before real value, module changes go through
  the multisig and timelock (`MAINNET_READINESS.md` G-1, G-2).
- **The owner can install any module.** The vault does not inspect it. A module for another vault is harmless here; a
  malicious module is the compromise case above.
- **Disable is one-way per module.** Operationally, resuming needs a new deployment and fresh signatures. Use the
  vault-scope exposure caps for a reversible stop.
- **Generation exhaustion** blocks deregistration and unfreeze of that curator for ever (§5.2); freeze and revoke still
  work.
- **Signature lifetime** is whatever the curator signs: the module does not bound `deadline`. Curators should keep the
  activation window short; `bumpGeneration` and `invalidateNonces` cancel outstanding instructions.
- **Relayer costs.** A hostile ERC-1271 wallet can make a relayer's transaction fail or cost up to ~64 times more
  (§6). Relayers should set gas limits.
- **Relayer liveness** (`RISKS.md` R7): a signature still needs a submitter; the curator can always use the direct path.
- **Unchanged from 1B-2.2:** the fixed-window boundary burst (up to 2 × cap across a window boundary) remains; this step
  does not change it. Limits bound amount and speed, not price.
- **Not run:** Unichain fork tests, testnet, the CI workflow on GitHub, an independent review. No audit or formal
  verification is claimed.

## 12. Next action requiring approval

1. Accept the deviations in §10, in particular the one-way module retirement and the domain name.
2. Push the branch (owner) so the CI workflow runs once on GitHub; report its result.
3. Decide whether 1B-2.4 (evidence: longer campaigns, consolidated gas and mutation report) or 1B-3 (cumulative pricing)
   comes next. Neither was started.
