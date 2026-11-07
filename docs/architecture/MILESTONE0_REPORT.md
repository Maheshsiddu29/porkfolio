# Milestone 0 — Validation Report

**Status: PASS (for the scoped vertical slice).** Out-of-scope items are listed explicitly in section 6.

Environment: macOS (Darwin 25.2.0), forge 1.7.1 (`4072e487`), solc 0.8.26, Slither 0.11.6. Dependency pins:
`ACCOUNTING_FLOW.md` §1.

## 1. What was built

| File | Purpose |
|---|---|
| `src/interfaces/ISharedCommitmentVault.sol` | Types (`AllocationRequest`, `Allocation`), custom errors, events, consumer entry point |
| `src/SharedCommitmentVault.sol` | ERC-6909 custody in the real PoolManager; owner funding/withdrawal; curator allocations with ceiling, nonce, deadline, horizon and `R + ΣQ ≤ C` admission; atomic `exchange`; lazy `release`; pause; consumer registry |
| `src/hooks/BaseCompatibleHook.sol` | `IHooks` implementation: exact-input `beforeSwap` → mint input → `vault.exchange` → burn output → `BeforeSwapDelta(+in, −out)`; rejects native liquidity |
| `src/hooks/HookA_DynamicFee.sol` | Fixed reference price minus a utilisation-linear fee (rounded in the vault's favour) |
| `src/hooks/HookB_BoundedImpact.sol` | Fixed reference price minus linear impact over remaining quota; reverts above `maxImpactPips` |
| `test/utils/VaultTestBase.sol` | Real `PoolManager`, two hooks at flag-encoded addresses, two pools, funded vault |
| `test/utils/BatchSwapRouter.sol` | **Test-only.** Several swaps in one `unlock`; asserts hook and vault deltas are 0 after each swap; can deliberately under-settle |
| `test/utils/MaliciousConsumerHook.sol` | **Test-only.** A compromised *registered* hook (5 attack modes) |
| `test/integration/SharedLiquiditySwap.t.sol` | Happy paths, both directions, both hooks, same-tx multi-hook, rollback, native-curve bypass, fuzzed accounting |
| `test/security/VaultSecurity.t.sol` | 38 negative and adversarial cases |
| `test/unit/VaultFunding.t.sol` | Deposit/withdraw through `unlock`, access control, R1 counterexample, asset-composition drift, nested-unlock guard |
| `test/invariant/VaultInvariants.t.sol` | Stateful invariants over random allocate/swap/warp/release/deposit/withdraw sequences |
| `test/gas/GasBaseline.t.sol` | Gas reference measurements |

## 2. Commands and observed results

```
$ forge fmt --check                      → exit 0
$ forge build --force                    → "Compiler run successful!" (87 files). 5 forge-lint notes remain:
                                           block-timestamp in src/SharedCommitmentVault.sol (intentional expiry/deadline logic)
$ forge test -vvv                        → 5 suites, 67 passed, 0 failed, 0 skipped
    VaultFundingTest          8/8
    GasBaselineTest           4/4
    SharedLiquiditySwapTest  12/12   (2 fuzz tests × 1000 runs, seed 0x5eed)
    VaultSecurityTest        38/38
    VaultInvariantsTest       5/5    (4 invariants × 64 runs × depth 64 = 4096 calls each, 0 handler reverts surfaced;
                                      plus a deterministic handler-progress test)
$ forge test --match-contract GasBaseline -vv --isolate   → see §4
$ slither . --filter-paths "lib/|test/" --exclude-dependencies   → 17 results, triaged in §5
```

**Mutation check (manual, not committed):** each of these vault changes was introduced temporarily, and in every case
the suite failed:

| Mutation | Tests that caught it |
|---|---|
| Remove the quota check | 5 failing tests, including invariant `consumed > maxOut` |
| Remove the price-floor check | 2 failing tests |
| Do not credit input backing | 6+ failing tests, including fuzz and conservation checks |

The source was then restored byte-for-byte (`cmp` verified).

## 3. Security cases covered (all through the real PoolManager unless noted)

| Required case | Test(s) |
|---|---|
| Successful authorised swap | `test_happyPath_hookA_zeroForOne`, `test_happyPath_hookB_oneForZero`, `test_bothDirections_bothHooks` |
| Unauthorised hook consumption | `test_unregisteredHook_cannotBeAllocatedTo`, `test_revokedHook_cannotConsume`, `test_hookB_cannotUseHookA_allocation`, `test_eoa_cannotCallExchange`, `test_registeredHook_cannotPassForeignKey` |
| Incorrect pool identity | `test_wrongPool_sameHook_reverts`, `test_allocate_consumerKeyMismatch_reverts` |
| Invalid currency / direction | `test_allocate_currencyNotInPool_reverts`, `test_wrongDirection_reverts` |
| Quota exhaustion | `test_quotaExhaustion`, `test_twoHooks_shareReserve_quotaIsolation`, `test_maliciousHook_cannotExceedQuota` |
| Curator bounds | `test_curatorCeiling_enforced`, `test_unauthorisedCurator_hasZeroCeiling` |
| Expired authorisation | `test_expiry_boundary` (expiry−1 ok, expiry reverts), `test_instructionDeadline`, `test_horizonAndPastExpiry` |
| Replay | `test_replay_sameNonce_reverts_evenAfterRelease`, `test_nonce_isCuratorScoped` |
| Insufficient ERC-6909 backing | `test_insufficientBacking_singleAndAggregate`, `test_R1_reserveConditionDoesNotGrantFullExit` |
| Invalid swap shape or amounts | `test_exactOutput_unsupported`, `test_invalidHookData`, `test_amountBounds_int128` (int256.min, −2^127), `test_dustInput_zeroOutput_reverts`, `test_maxOut_aboveInt128_reverts`, `test_hookB_impactBound` |
| Price bound | `test_priceFloor_enforced`, `test_maliciousHook_cannotBuyBelowFloor` |
| Incorrect settlement | `test_incorrectSettlement_rollsBackVault` (`CurrencyNotSettled`) |
| Atomic rollback | `test_sameTx_contention_atomicRollback`, `test_minOut_violation_rollsBack`, all `_maliciousHook_*` tests assert no state change |
| Custody / no blanket operator | `test_noOperatorOrAllowanceOverVaultClaims`, `test_maliciousHook_cannotBurnVaultClaims`, `test_maliciousHook_cannotTransferFromVault`, `test_maliciousHook_cannotTakeOutputWithoutFundingInput`, invariant `invariant_custodyAndSolvency` |
| Accounting conservation | `testFuzz_hookA_exactAccounting`, `testFuzz_hookB_exactAccounting`, invariants `backingEqualsRealClaims`, `ghostLedgerConservation`, `reservedIsExactAndBacked` |
| Access control | `test_admin_onlyOwner`, `test_funding_accessControlAndValidation`, `test_hookCallbacks_onlyPoolManager`, `test_unlockCallback_onlyPoolManager`, `test_constructor_rejectsZeroAddresses` |
| Pause / emergency | `test_pause_blocksAllocationAndConsumption_notWithdrawal`, `test_ownerEmergencyRelease_blocksFurtherConsumption` |
| Lazy expiry | `test_lazyRelease` (365 days past expiry: capacity still reserved until `release`) |

## 4. Gas baseline (measured, not optimised)

Settings: via-IR, 44,444,444 optimizer runs, `--isolate` (each top-level call is its own transaction, so cold/warm
access is realistic). The numbers below are **execution gas of the router call frame** from `-vvvv` traces. They
exclude the 21,000 intrinsic cost and **before** SSTORE refunds. *(Erratum, Phase 1A: under `--isolate` the top-level router
frame is reported **net** of SSTORE refunds; the inner `PoolManager.swap`, `beforeSwap` and `exchange` frames are
gross. The figures are unchanged. See `PHASE1A_REPORT.md` §5.1.)* They include the test router's own overhead. Use
them only to compare against each other.

| Path (exact-in 1000e18, test router `PoolSwapTest`) | Router frame | `PoolManager.swap` | `beforeSwap` | `vault.exchange` |
|---|---|---|---|---|
| HookA, zeroForOne | 202,026 | 153,625 | 135,696 | 75,777 |
| HookB, oneForZero | 201,935 | 153,373 | 135,410 | 75,790 |
| Native v4 CL pool, no hook (reference) | 139,471 | 51,516 | — | — |

Inside HookA `beforeSwap`: `getAllocation` 15,995, `PoolManager.mint` 26,035, `exchange` 75,777 (of which
`transferFrom` 11,365 and `transfer` 30,251), `PoolManager.burn` 4,732.

`allocate`: 235,205 to 269,586 (gas report, 523 calls).

Observed overhead versus native: about +62.5k on the router frame. The largest items are two zero→non-zero ERC-6909
balance writes on the hook (mint, then transfer-in), which are refunded when they return to zero, and the cross-contract
`getAllocation` read. Possible Phase-3 optimisations, not done here: keep a 1-wei standing claim balance on the hook,
pass allocation data back from `exchange` instead of a separate read, and pack `Allocation` more tightly.

## 5. Static analysis triage (Slither 0.11.6, src only)

| Detector | Location | Disposition |
|---|---|---|
| arbitrary-send-erc20 | `unlockCallback` `safeTransferFrom(owner, PM, amount)` | Accepted. The payer is hard-coded to `owner`. The callback is reachable only from the vault's own `unlock`. |
| unused-return | `unlock`, ERC-6909 `transfer`/`transferFrom`, `setOperator` | Accepted. PoolManager's ERC-6909 returns `true` or reverts. `unlock` returns `""` by design. |
| reentrancy-events | events after PoolManager calls | Accepted. PoolManager is the trusted singleton, and state is written before the calls (CEI). |
| timestamp | expiry, deadline and horizon comparisons | Intentional. Validator skew of a few seconds only moves expiry boundaries by seconds. |
| cyclomatic-complexity | `allocate`, `exchange` | Accepted. These are linear guard sequences. |
| naming-convention | `HookA_DynamicFee`, `HookB_BoundedImpact` | Names required by the blueprint. |

Fixed after the first Slither run: `deposit` now writes `backing` before the external call; the deposit payer is no
longer taken from callback data; the `currencyIn` derivation was restructured.

## 6. Residual risks, limitations and tests not run

- **Not audited.** No formal verification. The invariant campaign is 64 runs × depth 64 (default profile). The `ci`
  profile (10,000 fuzz runs) was **not** run.
- **Hook pricing is trusted** within quota × floor. A registered hook with a bad reference price can sell up to the
  remaining quota at the curator floor. There is no oracle. The hook owner sets the price.
- **Single LP (owner).** No share accounting, so no multi-LP fairness, queued withdrawals or valuation. The proposed
  model is in `ACCOUNTING_FLOW.md` §6.4 (needs a decision).
- `R_a` is enforced at admission only. The owner can withdraw into it.
- The curator cannot cancel its own unexpired allocation; only the owner can (emergency). This is a deliberate choice
  that needs review.
- `sqrtPriceLimitX96` is ignored for intercepted swaps. Integrators must enforce a minimum output.
  `PoolManager.Swap` events show zero amounts.
- Exact-output, partial interception, native ETH, fee-on-transfer/rebasing tokens: unsupported or unanalysed.
- No EIP-712, ring buffer, curator performance/HWM or ERC-4626 (scoped out of M0).
- Tests not run: CREATE2 salt mining (tests use `deployCodeTo`), any fork or testnet test, Echidna/Medusa,
  `forge coverage`.
- Gas numbers are from a test router. A production router will differ.

## 7. Architecture decisions requiring human review

1. **Settlement mechanism (hook → vault operator, atomic exchange).** `ACCOUNTING_FLOW.md` §3. This is the only path we
   found that both nets deltas on the hook address and avoids any grant over vault claims.
2. **Liability semantics:** in-kind share fraction plus bounded-horizon release, rather than a nominal amount
   (`ACCOUNTING_FLOW.md` §6.4). This is a material product change.
3. **Commitment irrevocability:** curator cannot cancel; the owner emergency-releases.
4. **Registry placement:** allocation logic currently lives inside the vault. Either split `CommitmentRegistry` out in
   Phase 1, or keep one trust boundary.
5. **`R_a` scope:** admission-only, or a hard floor on withdrawals too.
6. **Price floor per allocation** (`minInPerOutX96`): kept as the vault-side economic bound on hook behaviour.
