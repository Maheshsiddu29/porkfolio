# Porkfolio — Phase 1B-0: Threat Model, Required Tests and Implementation Plan

**Status: SPECIFICATION FOR REVIEW. Nothing here is implemented.** The design under analysis is the one specified in:

- `PHASE1B_PRICE_POLICY.md` (cited below as **PP**);
- `PHASE1B_CURATOR_AUTH.md` (cited below as **CA**).

Notation follows `SHARE_ACCOUNTING.md`:

| Symbol | Meaning |
|---|---|
| `f_v[out]` | vault floor for the sold currency |
| `f_c` | curator floor |
| `F_eff` | `max(f_v, f_c)` |

---

## 1. New invariants for Phase 1B

All existing invariants (`PHASE1AH_REPORT.md` §4.1, ten of them) must continue to hold unchanged. Phase 1B adds:

| ID | Invariant | Checked by |
|---|---|---|
| **INV-P1** | Every successful exchange satisfies `ΔIn · 2^96 ≥ ΔOut · max(f_v[out] at that block, f_c)`, where `ΔIn` and `ΔOut` are measured on the vault's PoolManager ERC-6909 balances | ghost log in the handler + `invariant_everyExchangeMeetsEffectiveFloor` |
| **INV-P2** | No exchange succeeds while `f_v[out] = 0`, while `halted[out]`, or while paused | handler ghost + `invariant_noExchangeWhenClosed` |
| **INV-P3** | LP exit paths (`redeem`, `processQueue`, `cancelRequest`, `claim`, `release`) behave identically whatever the floor and halt state | differential test T-12 |
| **INV-A1** | Each `(curator, nonce)` is used at most once. The number of allocations activated by curator `c` is ≤ the number of `c`'s set nonce bits. | `invariant_noncesSingleUse` |
| **INV-A2** | For every allocation: `consumed ≤ maxOut`. `Q_a` and `curatorReserved[c][a]` equal the exact sums over unreleased allocations (`CA` §8). | existing `reservedIsExactAndBacked`, extended with `curatorReserved` |
| **INV-A3** | A closed allocation is terminal: its `consumed` never changes again, and it contributes 0 to `Q_a` | `invariant_closedIsTerminal` |
| **INV-A4** | Each allocation's activation time lies in `[validAfter, deadline]`. Each consumption happens at a time `< expiry`. | handler ghost + `invariant_windowsRespected` |
| **INV-R1** | No guardian call lowers any `f_v`, clears a halt, unpauses, registers a consumer, or raises a ceiling | `invariant_guardianOnlyReducesRisk` |

## 2. Threat analysis

Each row lists:

- the attacker's capability;
- the on-chain invariant that bounds it;
- the residual loss;
- the specific Foundry tests that must exist before Phase 1B is accepted.

Proposed test files:

| File | Purpose |
|---|---|
| `test/security/PricePolicy.t.sol` | price-policy tests (prefix `PP`) |
| `test/security/CuratorAuth.t.sol` | authorization tests (prefix `CA`) |
| `test/security/AuthLifecycle.t.sol` | lifecycle tests (prefix `LC`) |
| `test/security/Roles.t.sol` | role tests (prefix `RO`) |
| `test/integration/HookPriceBands.t.sol` | Hook A / Hook B band tests (prefix `HB`) |
| `test/utils/Mock1271Wallet.sol` | test-only ERC-1271 wallet with modes `Valid`, `Invalid`, `Revoked`, `Reentrant`, `GasBurner`, `ReturnBomb` |

### T-01 Compromised curator

- **Capability.** Activate allocations up to its ceiling, for registered hooks on this pair, at `f_c ≥ f_v`, for at
  most 30 days. It can also cancel its own allocations and invalidate its own nonces.
- **Bound.**
  - It cannot price trades. A curator alone causes no loss.
  - Combined with a malicious hook, the loss is at most `ceiling · max(0, M − f_v)` per direction (`PP` §8.1).
  - It can also freeze up to `ceiling` of capacity, which sends LP exits to the queue until release.
- **Invariants.** INV-A2, INV-P1; the ceiling check.
- **Response.** Guardian sets the curator's ceiling to 0 and emergency-releases its allocations.
- **Tests:**
  - `test_CA_compromisedCurator_boundedByCeilingAndVaultFloor`
  - `test_RO_guardianZeroCeiling_blocksNewActivations_existingNeedEmergencyRelease`
  - `test_LC_emergencyRelease_restoresFreeInventory_andLpExitBecomesInstant`

### T-02 Malicious registered hook

- **Capability.**
  - Choose `amountOut` up to the remaining quota at any price `≥ F_eff`.
  - Call `exchange` outside any swap. The vault cannot tell, and needs only input claims.
  - Charge swappers a spread (`PP` §3.3).
  - Ignore its own `priceX96`.
- **Bound.** Per allocation: `remaining · max(0, M − F_eff)`.
- **Invariants.** INV-P1, INV-A2, and the existing `custodyAndSolvency` (no operator rights over the vault).
- **Tests:**
  - `test_PP_maliciousHook_cannotBeatEffectiveFloor` (fuzz over `amountIn`, `amountOut`, `f_v` and `f_c`, using
    `MaliciousConsumerHook`)
  - `test_PP_directExchangeOutsideSwap_stillBoundByFloorAndQuota`
  - `test_PP_hookOwnerSetsAbsurdPrice_tradeReverts_notExecuted`

### T-03 Compromised allocator (the submitter or relayer of signed authorizations)

- **Capability.**
  - Submit, or withhold, any valid signed authorization at any time within `[validAfter, deadline]`.
  - Choose which `PoolKey` to supply.
  - Front-run the curator's own submission.
- **Bound.**
  - It cannot change any signed field, because the digest covers them.
  - A wrong `PoolKey` fails `key.toId() == poolId`.
  - It can only cause activation earlier or later inside the signed window. Withholding is countered by the curator
    submitting directly.
- **Invariants.** INV-A1, INV-A4.
- **Tests:**
  - `test_CA_anySubmitter_sameResult`
  - `test_CA_tamperedField_eachOfThirteen_rejected` (one case per struct field)
  - `test_CA_wrongPoolKeyForSignedPoolId_rejected`
  - `test_CA_frontRunActivation_curatorDirectThenReverts_nonceUsed`

### T-04 Zero-price and unfavourable-price execution

- **Attack.**
  - A floor of 0 or 1 wei.
  - Dust rounding.
  - Price checked on arguments, but different amounts moved.
- **Invariants.** INV-P1, INV-P2; activation rejects `f_c = 0` and `f_c < f_v`; `f_v = 0` closes the direction.
- **Tests:**
  - `test_PP_activation_rejectsZeroCuratorFloor`
  - `test_PP_activation_rejectsFloorBelowVault`
  - `test_PP_exchange_revertsWhenVaultFloorUnset`
  - `test_PP_oneWeiInput_largeOutput_reverts`
  - `testFuzz_PP_acceptanceIsExactRationalInequality`, which compares the result with a reference
    `amountIn·2^96 ≥ amountOut·F` in 512-bit arithmetic
  - `test_PP_priceMeasuredOnClaimDeltas_equalsArguments`
  - `test_PP_decimals6and18_workedExample` (the `PP` §2.3 numbers, both directions, including the
    `2850000001` boundary: one raw unit less reverts)

### T-05 Cross-chain and cross-vault signature replay

- **Attack.**
  - Reuse a signature on another chain.
  - Reuse it on another vault for the same pair.
  - Reuse it on a vault redeployed at the same address on another chain.
- **Invariants.** The digest binds `chainId` and `verifyingContract`, and the struct binds `vault`.
- **Tests:**
  - `test_CA_replayOtherChain_rejected` (`vm.chainId`)
  - `test_CA_replayOtherVaultSamePair_rejected`
  - `test_CA_chainIdChangeAfterDeploy_domainRecomputed`
  - `test_CA_structVaultFieldMismatch_rejected`

### T-06 Duplicate and out-of-order nonces

- **Attack.**
  - Activate the same authorization twice.
  - Activate two different messages with the same nonce.
  - Activate nonces out of order.
  - Malleable signature variants.
- **Invariant.** INV-A1.
- **Tests:**
  - `test_CA_sameAuthTwice_reverts`
  - `test_CA_twoMessagesSameNonce_onlyFirstActivates`
  - `test_CA_outOfOrderNonces_bothActivate`
  - `test_CA_highSVariant_rejected`
  - `test_CA_invalidateNonces_bulk256_andIdempotent`
  - `test_CA_directAndSignedPaths_shareNonceSpace`

### T-07 Expired authorizations and allocations

- **Attack.**
  - Activate before `validAfter` or after `deadline`.
  - Activate with `expiry` beyond the horizon.
  - Consume at or after `expiry`.
- **Invariant.** INV-A4.
- **Tests:**
  - `test_LC_activateBeforeValidAfter_reverts`
  - `test_LC_activateAtDeadline_ok_afterDeadline_reverts`
  - `test_LC_expiryBeyondHorizonAtActivation_reverts`
  - `test_LC_consumeAtExpiry_reverts_releasePermissionless`
  - `test_LC_lapsedNonceReusableByNewMessage`

### T-08 Curator cancellation after partial consumption

- **Attack.**
  - Cancel, then consume.
  - Cancel twice.
  - Re-activate the canceled authorization.
  - Someone other than the curator cancels.
- **Invariants.** INV-A2, INV-A3. Releasing returns exactly `maxOut − consumed`.
- **Tests:**
  - `test_LC_cancelAfterPartial_releasesExactRemainder`
  - `test_LC_cancelThenExchange_reverts`
  - `test_LC_cancelTwice_reverts`
  - `test_LC_cancelThenReactivateSameSig_reverts`
  - `test_LC_nonCuratorCannotCancel` (owner, guardian, hook, other curator)
  - `test_LC_cancelWhilePaused_allowed`
  - `test_LC_1271CuratorCancels`

### T-09 Revocation races

Each row of `CA` §7.5 is reproduced as a pair of orderings in one test:

- `test_LC_race_invalidateVsActivate_bothOrders`
- `test_LC_race_cancelVsSwap_bothOrders`
- `test_LC_race_emergencyVsSwap_bothOrders`
- `test_LC_race_tightenVsSwap_bothOrders`
- `test_LC_race_deregisterVsActivate_bothOrders`
- `test_LC_race_ceilingVsActivate_bothOrders`

Each asserts INV-A2 and INV-A3, and that capacity is never released twice.

### T-10 Signature-verifier reentrancy (ERC-1271)

- **Attack.** A curator wallet's `isValidSignature`:
  - re-enters `allocate`, `exchange`, `cancelAllocation`, `redeem` or `invalidateNonces`;
  - reads views mid-activation;
  - burns gas;
  - returns a huge payload;
  - is revoked after activation.
- **Bound.**
  - `staticcall` forbids state changes.
  - Verification precedes all effects (`CA` §5.3).
  - Gas griefing only hurts the submitter.
- **Tests:**
  - `test_CA_1271Reentrant_writeAttemptsFail_activationReverts`
  - `test_CA_1271ReadsViewsDuringVerify_seesPreActivationState`
  - `test_CA_1271GasBurner_revertsOnlySubmitterTx`
  - `test_CA_1271ReturnBomb_rejected`
  - `test_CA_1271RevokedAfterActivation_allocationStillValid_cancelWorks`
  - `test_CA_eoaCuratorBadSig_1271FallbackRejects`

### T-11 Changes to oracle configuration or risk bounds

There is no oracle in the recommended design. The analysis covers changes to `f_v`, the halt flags, ceilings, the
buffer floor and consumer registration.

- **Attack.**
  - The guardian loosens.
  - A change fails to reach live allocations.
  - Loosening goes below `f_c`.
- **Invariants.** INV-R1, INV-P1.
- **Tests:**
  - `test_RO_guardianCannotLoosen_canTighten`
  - `test_RO_onlyOwnerResumesAndUnpauses`
  - `test_PP_tightenAppliesToOutstandingAllocation`
  - `test_PP_loosenNeverBelowCuratorFloor`
  - `test_PP_cannotResetFloorToZero_useHalt`
  - `test_RO_accessMatrix` (table-driven over `CA` §9)
- **If Design B is approved later:** a separate test set for missing, stale, zero, negative and out-of-band answers,
  sequencer down and grace period, each of which must revert (`PP` §8.2).

### T-12 Unexpected accounting mutations during external calls

- **New external calls in Phase 1B:**
  - the ERC-1271 `staticcall`, which is read-only;
  - no oracle.
- **Unchanged external calls:** to the PoolManager only, with effects before interactions.
- **Attack.** State changes between check and effect; price policy blocking exits.
- **Invariants.** INV-P3, and the existing `actualBalanceMovementsMatchAccounting`.
- **Tests:**
  - `test_PP_exitsUnaffectedByHaltPauseAndUnsetFloor`: differential; the same redemption sequence gives the same result
    with all floors halted or unset as with them open.
  - `test_CA_activation_noStateChangeBeforeSignatureCheck`, using a 1271 wallet that snapshots views.
  - Extend `invariant_actualBalanceMovementsMatchAccounting` to the new actions.

### T-13 Compromised guardian

- **Capability.**
  - Halt trading.
  - Pause inflows.
  - Freeze activations.
  - Emergency-release allocations, which breaks hooks' expected capacity.
- **Bound.** Liveness only. It cannot increase risk or move value (INV-R1).
- **Test:** `invariant_guardianOnlyReducesRisk`, with random guardian calls in the handler.

### T-14 Compromised owner (documented, not bounded)

The owner can loosen floors, register a malicious hook and raise an attacker's ceiling. **No on-chain bound exists**
(`PP` §13). The mitigation is operational: a multisig or timelock (`PP` D3).

**Test:** none. It is an explicit trust assumption, recorded in the report.

## 3. Implementation plan (each commit is independently buildable and fully green)

**Ordering principle.** The price floor lands **before** signatures. It closes the reported vulnerability without
depending on the authorization work. Signing and replay protection land **in the same commit**, so that no intermediate
commit accepts signatures without replay protection.

Per `CLAUDE.md` (2–4 commits per milestone), the work is split into three sub-milestones. Each one stops for review.

### Phase 1B-1: roles and price safety

| # | Commit | Content | Tests |
|---|---|---|---|
| 1 | `feat(roles): guardian with risk-reducing-only powers; two-step ownership` | the `guardian` role; `setGuardian`; pause by guardian, unpause by owner only; deregister by guardian; lower ceiling by guardian; raise buffer by guardian; `transferOwnership` + `acceptOwnership` (if D10 is approved) | `Roles.t.sol` (`test_RO_*`) |
| 2 | `feat(price): vault per-direction sell floor and halt; effective floor at exchange` | `SellPolicy`; `setSellFloor` and `setSellHalted`; activation checks (`PP` §4.1); `F_eff` in `exchange`; views `effectiveFloorX96` and `requiredInput`; fixture configures floors; `ZeroAssetStates` rewritten with non-zero floors (D13) | `PricePolicy.t.sol` (T-02, T-04, T-11, T-12) |

### Phase 1B-2: authorization lifecycle

| # | Commit | Content | Tests |
|---|---|---|---|
| 3 | `feat(auth): EIP-712 curator authorization with unordered nonces` | `CuratorAuthorization` replaces `AllocationRequest`; shared `_activate`, which checks `isCurator` on both paths before signature verification (R1); the D15 epoch field if approved (R2); `allocate` (direct) and `allocateWithSig` (ECDSA + ERC-1271 via OZ 5.0.2); the OZ remapping; nonce bitmap; `invalidateNonces`, which does not require registration (R3); `validAfter`; `hashAuthorization` | `CuratorAuth.t.sol` (T-03, T-05, T-06, T-10); `Mock1271Wallet`; R1–R3 tests in `CURATOR_REVOCATION.md` §5 |
| 4 | `feat(auth): curator cancellation and emergency release` | `cancelAllocation`, which does not require registration (R3); `emergencyRelease` (owner or guardian); `release` limited to expired allocations; `_close(id, reason)` (R4); `ReleaseReason`; NatSpec on which actions stop consumption immediately (R5) | `AuthLifecycle.t.sol` (T-01, T-07, T-08, T-09, plus `test_LC_race_curatorDeregisterVsActivate_bothOrders`) |

### Phase 1B-3: integration and evidence

| # | Commit | Content | Tests |
|---|---|---|---|
| 5 | `test(hooks): Hook A and Hook B under vault floors` | Real-PoolManager swaps for both hooks across the executable band (`PP` §5): inside, at the boundary ±1, outside, halted, tightened after activation, 6/18 pair. Hook `quote()` view uses `requiredInput` only if D9 is approved; `beforeSwap` is unchanged. | `HookPriceBands.t.sol` (`test_HB_*`) |
| 6 | `test: Phase 1B invariants, fuzzing and gas` | Handler actions: `activateWithSig`, `activateDirect`, `cancel`, `invalidate`, `emergencyRelease`, `guardianTighten`, `guardianHalt`, `ownerLoosen`, `deregisterCurator`. Invariants: INV-P1 to INV-R1, plus `invariant_activationRequiresRegisteredCurator` (R6). A 10,000-run fuzz profile. `test/gas/AuthGas.t.sol` (`--isolate`). Size check. | all |
| 7 | `docs: Phase 1B report` | validation, gas before and after, size, mutation check, residual risks | — |

### Mutation checks to run (manual, not committed, as in Phase 1A-H)

| # | Mutation | Must be caught by |
|---|---|---|
| M1 | `exchange` uses `f_c` only | `test_PP_tightenAppliesToOutstandingAllocation`, INV-P1 |
| M2 | `exchange` uses `min` instead of `max` | `test_PP_loosenNeverBelowCuratorFloor` |
| M3 | Activation skips `f_c ≥ f_v` | `test_PP_activation_rejectsFloorBelowVault` |
| M4 | Guardian may loosen | `test_RO_guardianCannotLoosen_canTighten`, INV-R1 |
| M5 | Nonce not consumed on the signed path | `test_CA_sameAuthTwice_reverts`, INV-A1 |
| M6 | Domain without `chainId` | `test_CA_replayOtherChain_rejected` |
| M7 | Struct `vault` field not checked | `test_CA_structVaultFieldMismatch_rejected` |
| M8 | Cancel releases `maxOut` instead of the remainder | `test_LC_cancelAfterPartial_releasesExactRemainder`, INV-A2 |
| M9 | `_close` does not check `released` | `test_LC_cancelTwice_reverts`, INV-A3 |
| M10 | Signature verified after the nonce is consumed | `test_CA_activation_noStateChangeBeforeSignatureCheck` |
| M11 | Halt ignored in `exchange` | INV-P2 |

### Validation commands (run after every commit)

```
forge fmt --check
forge build --force --sizes          # vault runtime must stay < 24,576 B (EIP-170)
forge test -vvv
FOUNDRY_PROFILE=ci forge test --match-test testFuzz
FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-contract VaultInvariants
forge test --match-contract "AuthGas|LpGas|GasBaseline|AuthorizationComparison" --isolate -vvvv
slither . --filter-paths "lib/|test/" --exclude-dependencies
```

### What is explicitly not in Phase 1B

- An oracle (unless D1 changes).
- Splitting the commitment registry into another contract.
- Changes to share accounting, the FIFO queue or ERC-6909 settlement.
- Keeper incentives.
- Frontend, SDK, deployment.
