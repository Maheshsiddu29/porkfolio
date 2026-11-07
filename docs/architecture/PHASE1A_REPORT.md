# Phase 1A — Multi-LP Accounting and Redemption: Validation Report

**Status: PASS (for the scoped Phase 1A).** Every Milestone-0 test is preserved; tests that used the removed owner
funding API were migrated without changing their intent (§3). Unresolved cases are listed in
`SHARE_ACCOUNTING.md` §9 and in §9 below.

- **Environment:** macOS (Darwin 25.2.0), forge 1.7.1, solc 0.8.26 (via-IR, 44,444,444 runs, cancun), Slither
  0.11.6. Dependency pins are unchanged from Milestone 0 (`ACCOUNTING_FLOW.md` §1).
- **Branch:** `phase-1a`, created from `milestone-0` at `7089293`. `milestone-0` is unchanged.

## 1. What changed

| Area | Change |
|---|---|
| Ownership | Owner-only single-asset `deposit` and `withdraw` are **removed**. LPs hold non-transferable, proportional, in-kind shares of a fixed two-asset reserve (`asset0 < asset1`, set in the constructor). |
| Deposits | `initialDeposit` mints `⌊√(x0·x1)⌋` shares, with 1000 locked forever. `deposit(shares, max0, max1)` pays `⌈s·N_a/S⌉` of each asset. |
| Redemption | `redeem` has an instant tier, limited to free inventory and disabled while anyone is queued. The remainder goes to a strict-FIFO queue with partial fills at the head. `processQueue` is permissionless and bounded by `maxSteps`. `cancelRequest` and `claim` complete the state machine. |
| Admission | `Q_a + q + R_a + D_a ≤ N_a`. Pending demand `D_a` and claimable assets `W_a` are protected from new commitments. `R_a` is now admission-only (approved decision 5). |
| Pairs | Allocations must be on pools of exactly the vault's pair (`UnsupportedPair`). |
| Caps | Per-asset backing and total shares are capped at `int128.max`. |
| Pause | Blocks deposits, allocations and consumption. Never blocks redemption, processing, cancellation or claims. |
| Settlement | **Unchanged.** Hook → vault operator plus atomic `exchange`. A comparison with exact allowances is in §6. No production hook changed. |

The full equations and derivations are in `docs/architecture/SHARE_ACCOUNTING.md`.

## 2. Files

| File | Status |
|---|---|
| `src/SharedCommitmentVault.sol` | modified (shares, queue, admission, pair restriction, caps) |
| `src/interfaces/ISharedCommitmentVault.sol` | modified (request struct and status enum, errors, events) |
| `test/utils/VaultTestBase.sol` | modified (vault seeded by LP `lp0`; LP helpers; adds the `Q+W ≤ B` check) |
| `test/unit/VaultFunding.t.sol` | migrated (§3) |
| `test/security/VaultSecurity.t.sol` | one assertion migrated (§3) |
| `test/invariant/VaultInvariants.t.sol` | handler rewritten for multi-LP; 4 M0 invariants kept, 4 added |
| `test/integration/MultiLpAccounting.t.sol` | new (12 tests) |
| `test/security/ShareSecurity.t.sol` | new (15 tests) |
| `test/gas/LpGas.t.sol`, `test/gas/AuthorizationComparison.t.sol` | new |
| `test/utils/ClaimDonor.sol`, `test/utils/AuthModeHook.sol` | new, **test-only** |
| `docs/architecture/SHARE_ACCOUNTING.md`, `PHASE1A_REPORT.md` | new |
| `ACCOUNTING_FLOW.md`, `MILESTONE0_REPORT.md`, `README.md` | pointers and one erratum (§5.1) |

Unchanged since Milestone 0: `src/hooks/*`, `test/integration/SharedLiquiditySwap.t.sol`,
`test/gas/GasBaseline.t.sol`, `test/utils/BatchSwapRouter.sol`, `test/utils/MaliciousConsumerHook.sol`.

## 3. Milestone-0 regression suite: what was migrated

The owner `deposit`/`withdraw` API no longer exists because the owner must not bypass shareholder accounting. So every
M0 test that called it was rewritten against the LP API with the same intent. No assertion was weakened.

| M0 test | Phase 1A form |
|---|---|
| fixture `_fundVault` (owner deposit of 1M + 1M) | `lp0.initialDeposit(1M, 1M)`. `backing` is identical, so all 38 security and 12 integration assertions on `VAULT_FUNDING` still hold unchanged. |
| `_assertAccountingConsistent` | **strengthened**: adds `reserved + claimable ≤ backing` |
| `test_pause_blocksAllocationAndConsumption_notWithdrawal` | last step: owner `withdraw` → LP `redeem` while paused |
| `test_deposit_mintsRealClaimsBackedByErc20` | `test_initialDeposit_mintsSharesBackedByRealClaims` (also checks share supply and the locked `M`) |
| `test_withdraw_burnsClaimsAndReturnsErc20` | `test_instantRedeem_burnsClaimsAndReturnsErc20` |
| `test_funding_accessControlAndValidation` | same name, rewritten for the new entry points (14 revert cases) |
| `test_constructor_rejectsZeroAddresses` | `…AndBadPairs` (adds native, unsorted and duplicate pairs) |
| `test_R1_reserveConditionDoesNotGrantFullExit` | same name. Now shows a 20% instant in-kind exit, the remainder queued, lazy expiry, then a full exit after `release`. |
| `test_consumptionChangesAssetComposition` | same name; asserts the redeemed basket |
| `test_withdraw_cannotNestInsideUnlock` | `test_redeem_cannotNestInsideUnlock` |
| invariant handler `deposit`/`withdraw` | replaced by multi-LP `deposit`, `redeem`, `process`, `cancel` and `claim` actions |
| `invariant_reservedIsExactAndBacked` | **strengthened**: adds `Q + W ≤ B` |

## 4. Validation commands and observed results

```
$ forge fmt --check                                  → exit 0
$ forge build                                        → Compiler run successful. 5 forge-lint notes, all
                                                       block-timestamp (intentional; same as M0)
$ forge build --sizes                                → SharedCommitmentVault runtime 19,368 B (margin 5,208 B)
$ forge test -vvv                                    → 9 suites, 111 passed, 0 failed, 0 skipped
    VaultFundingTest            8/8
    GasBaselineTest             4/4      (unchanged M0 file)
    SharedLiquiditySwapTest    12/12     (unchanged M0 file; 2 fuzz × 1000)
    VaultSecurityTest          38/38
    VaultInvariantsTest         9/9      (8 invariants × 64 runs × depth 64 = 4,096 calls each, + progress test)
    MultiLpAccountingTest      12/12     (2 fuzz × 1000)
    ShareSecurityTest          15/15     (1 fuzz × 1000)
    LpGasTest                   8/8
    AuthorizationComparisonTest 5/5
$ FOUNDRY_PROFILE=ci forge test --match-test testFuzz → 5/5 fuzz tests × 10,000 runs each, all pass
$ FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-contract VaultInvariants
                                                     → 8/8 invariants × 32,768 calls each, all pass
$ slither . --filter-paths "lib/|test/" --exclude-dependencies   → 21 results, triaged in §7
```

The invariant handler wraps every action in `try`/`catch`, so "reverts: 0" is by construction.
`test_handler_makesProgress` checks deterministically that every path runs: allocate, swap through both hooks,
deposit, instant, queued, cancel, finalize and claim. Per-run logs show the queue paths being reached during the
campaign. Example run:

| Counter | Value |
|---|---|
| deposits | 8 |
| instant | 8 |
| queued | 6 |
| finalize | 2 |
| cancel | 2 |

### 4.1 Mutation check (manual, not committed)

Each mutation was applied to the vault alone and the full suite was run. The source was then restored and verified
byte-identical with `cmp`.

| # | Mutation | Failing tests (of 97 at the time) | Examples |
|---|---|---|---|
| M1 | instant redemption ignores queue priority | 1 | `test_fifoFairness_competingRequests` |
| M2 | admission ignores pending demand `D_a` | 2 | liveness fuzz "queue did not drain"; `test_queuedRedemptionDuringActiveCommitments` |
| M3 | deposit rounds down | 4 | "lp0 token0 claim diluted"; invariant "per-share basket decreased" |
| M4 | redemption rounds up | 5 | demo exact amounts; invariant "per-share basket decreased" |
| M5 | `claim` does not clear the request | 7 | double-claim tests; arithmetic underflow on the second claim |
| M6 | queue skips a blocked head | 5 | invariant "later request finalized before earlier pending one"; R1 |
| M7 | `N_a` includes claimables | 8 | invariant "commitments + claimables > backing"; "equal requests, equal basket" |
| M8 | cancel does not release pending | 3 | invariant "S != held + pending"; status test |

### 4.2 Executable multi-LP demonstration

`forge test --match-test test_demo_threeLps -vv` runs the following sequence (1:1 hooks, 18 decimals):

1. `lp0` seeds 1M/1M; `lpA` deposits 500k shares at 500k/500k.
2. The curator commits 200k token1 to HookA and 200k token0 to HookB.
3. Traders sell 100k token0 through HookA and 50k token1 through HookB. Then S = 1.5M, N0 = 1,550,125, N1 = 1,450,275.
4. `lpB` deposits 250k shares at the post-trade basket, rounded up.
5. `lpA` instantly redeems 200k shares at the post-trade basket, rounded down.
6. Commitments expire and are released; everyone exits.

| Exit | token0 | token1 |
|---|---|---|
| lp0 (≈1M shares) | 1,033,416.67 | 966,850.00 |
| lpA (remaining 300k) | 310,025.00 | 290,055.00 |
| lpB (250k) | 258,354.17 | 241,712.50 |

- **Remaining:** S = 1000 (locked), N0 = 1034 wei, N1 = 967 wei.
- **Conservation:** remaining `backing` = total in − total out, exactly.
- **Value at the hooks' 1:1 reference price:** 2.000267 per share after the swaps, against 2.0 before. That is +0.0133%
  from HookA's fee and HookB's impact, observed in this scenario only. It is not a yield estimate.

## 5. Gas (measured, not optimised)

**Method.** `forge test --isolate -vvvv`: each top-level call is its own transaction (realistic cold/warm access).
Numbers are read from the trace. The before numbers were re-measured by running the M0 commit `7089293` from a clean
export in the scratchpad, with the same toolchain and settings.

### 5.1 Erratum to `MILESTONE0_REPORT.md` §4

While re-measuring, the trace showed that the **top-level frame** of an isolated transaction is reported **net of
SSTORE refunds**. Its child `PoolManager::unlock` frame shows *more* gas than the parent: 212,387 > 202,026 at M0.

- **Inner frames** (`PoolManager::swap`, `beforeSwap`, `exchange`) are gross.
- The M0 report labelled the router-frame figures "before SSTORE refunds". That is incorrect for the router frame and
  correct for the inner frames.
- The figures themselves are unchanged and remain comparable to each other.

### 5.2 Swap, before and after

| Path (exact-in 1000e18, `PoolSwapTest`) | M0 router (net) | 1A router (net) | Δ | M0 `PM.swap` (gross) | 1A `PM.swap` | M0 `exchange` | 1A `exchange` |
|---|---|---|---|---|---|---|---|
| HookA zeroForOne | 202,026 | 202,688 | +662 | 153,625 | 154,287 | 75,777 | 76,246 |
| HookB oneForZero | 201,935 | 202,597 | +662 | 153,373 | 154,035 | 75,790 | 76,259 |
| Native v4 CL reference | 139,471 | 139,471 | 0 | 51,516 | 51,516 | — | — |
| `allocate` (vault frame) | 269,586 | 274,622 | +5,036 | | | | |

The swap delta (+469 gas in `exchange`) is attributed to the new `backing[in] ≤ int128.max` cap check. It was not
profiled further. The `allocate` delta comes from reading `claimableAssets`, `pendingShares` and `totalShares` for the new
admission rule.

### 5.3 LP operations (vault call frame, gross, isolated)

| Operation | Gas |
|---|---|
| `initialDeposit` (both assets; fresh vault) | 243,507 |
| `deposit` (new LP, both assets) | 142,955 |
| `redeem`, fully instant (both assets) | 154,218 |
| `redeem`, fully queued (request only) | 144,723 |
| `redeem`, partial instant + queued remainder | 252,705 |
| `processQueue(1)`, finalize one request | 120,726 |
| `claim` (both assets) | 134,556 |
| `cancelRequest` | 38,681 |

Each deposit or payout opens one `PoolManager.unlock` and settles or takes both assets. That cost is most of the
deposit, instant and claim figures.

## 6. Settlement authorization: operator grant vs exact allowance (approved decision 1)

**Setup.** `test/utils/AuthModeHook.sol` (test-only) deploys two hooks with identical logic (1:1, no fee). They differ
only in authorization:

- **Operator mode:** `setOperator(vault, true)` once, in the constructor, as `BaseCompatibleHook` does.
- **Allowance mode:** `approve(vault, idIn, amountIn)` inside every `beforeSwap`.

Same pool shape, same amounts, same fixture, `--isolate`.

| | Operator (current) | Exact allowance |
|---|---|---|
| Router frame (net) | 192,672 | 208,586 (**+15,914**) |
| `PoolManager.swap` (gross) | 144,295 | 172,555 (+28,260: `approve` 24,950; `transferFrom` +702) |
| Residual authority after a swap | standing operator grant over a hook balance that is **0 at rest** | none (allowance consumed to 0) |
| Authority over the vault's claims | none | none |
| Accounting | identical (`test_bothModes_identicalAccounting`) | identical |
| Exactness | vault pulls exactly `amountIn` by code | enforced by the token as well: a 1-wei short approval reverts (`test_allowanceMode_isExact`) |

**Assessment.**

- The hook only holds claims inside `beforeSwap` (mint → exchange → burn) and has no other entry point that leaves
  claims behind. So the operator grant only matters during that window, while the vault is executing code it controls.
- An exact allowance adds defence-in-depth against a *vault* bug that pulls too much from the hook in that window. Its
  cost is about 16k gas per swap net, or about 28k gross before refunds.

**Recommendation:** keep the operator grant (no change made). Revisit if hooks are ever allowed to hold claims between
transactions, or if the vault becomes upgradeable. This is a decision for review.

## 7. Static analysis triage (Slither 0.11.6, `src/` only; 21 results)

| Detector | Count | Location | Disposition |
|---|---|---|---|
| arbitrary-send-erc20 (High) | 1 | `_settleIn` `safeTransferFrom(payer, PM, amount)` | **Accepted.** `payer` is always the `msg.sender` of `deposit`/`initialDeposit`. `unlockCallback` is only reachable through the vault's own `unlock`. Tests: `test_depositAlwaysPullsFromCaller` (an LP's max approval cannot be spent by anyone else), `test_unlockCallback_onlyPoolManager`. |
| unused-return | 4 | ERC-6909 `transfer`/`transferFrom`, `unlock`, hook `setOperator` | Accepted (upstream returns `true` or reverts). |
| reentrancy-events | 6 | events after PoolManager calls | Accepted. All state is written before the external call (CEI). No `reentrancy-no-eth` or `reentrancy-benign` results. |
| timestamp | 3 | expiry, deadline, horizon | Intentional. |
| costly-loop | 2 | `processQueue` | Accepted. Bounded by the caller's `maxSteps`, and needed to keep the queue FIFO. |
| cyclomatic-complexity | 3 | `redeem`, `allocate`, `exchange` | Accepted (linear guard sequences). |
| naming-convention | 2 | `HookA_DynamicFee`, `HookB_BoundedImpact` | Names required by the blueprint. |

## 8. Accounting and solvency invariants (all VERIFIED by the campaign above)

| Invariant | Statement |
|---|---|
| `backingEqualsRealClaims` | `B_a = PM.balanceOf(vault, a)` (no donations in the campaign) |
| `ghostLedgerConservation` | `B_a` = deposits − payouts + swap inputs − swap outputs |
| `reservedIsExactAndBacked` | `Q_a = Σ(maxOut − consumed)`; `Q_a + W_a ≤ B_a` |
| `custodyAndSolvency` | hooks hold no claims; no operator rights over the vault; PM holds the ERC-20 |
| `sharesAndQueueConserved` | `S = Σ s_i + P`; `P = Σ pending`; `W_a = Σ claimable`; `S ≥ M`; nothing pending behind the head |
| `noDoubleClaim` | per request: claimed + claimable = finalized |
| `fifoOrdering` | no later request has any finalized share while an earlier one is pending |
| `noDilutionByLpOperations` | `N_a/S` never decreases across LP operations |

## 9. Residual risks and tests not run

- **Not audited; no formal verification.** The liveness bound is argued and fuzz-tested, not proven
  (`SHARE_ACCOUNTING.md` §6.3).
- **No fixed payout or fixed deadline is promised.** Redemption is in kind at finalization. Draining the queue needs
  `release` and `processQueue` calls, and there is no keeper incentive.
- **Untested branches:** the both-assets-zero `DustRedemption` branch and the `NoAssets` state.
- **Griefing vectors:**
  - Queue spam costs processors gas: one `processQueue(10)` call over ten spam requests measured 324,794 gas in-test.
  - Queue-then-cancel blocks curator capacity for a while, bounded by that LP's share.
  - First-come race for free inventory while `P = 0`.
  - Permissionless initialization lets the first depositor choose the ratio.
- **Hook pricing is trusted** within quota × floor (unchanged from M0). A curator floor of 0 would let a registered hook
  take its quota for almost nothing. No minimum floor is enforced.
- **Not supported:** share transfers; fee-on-transfer, rebasing and ERC-777 tokens (FoT fails closed, but is not
  tested); native ETH; exact-output swaps.
- **Not run:**
  - Echidna/Medusa
  - `forge coverage`
  - fork or testnet runs
  - CREATE2 salt mining (tests use `deployCodeTo`)
  - invariant campaigns beyond 256 × 128
- **Gas** is measured with the v4 test router, so production routers will differ. LP-operation gas is unoptimised;
  for example, each payout opens its own `unlock`.

## 10. Decisions requiring human review

1. **Settlement authorization.** Keep the standing hook → vault operator grant (recommended, §6), or switch to exact
   per-swap allowances (+~16k gas net per swap).
2. **Queue policy.** Strict FIFO with partial head fills (implemented), or a pro-rata epoch model that finalizes all
   requests pending at an epoch boundary at one rate. Epochs give identical treatment within an epoch, at the cost of
   batching latency and extra state.
3. **Anti-spam.** A minimum request size, a per-request bond, or neither.
4. **Cancel cooldown.** Whether to add one, to limit queue-then-cancel blocking of curator capacity.
5. **Initialization.** Owner-only, or permissionless (current).
6. **Share transferability.** Plain non-transferable balances (current), an ERC-20 share token, or ERC-6909 share ids.
7. **Minimum curator floor.** Whether the vault should enforce a minimum `minInPerOutX96` relative to a reference, or
   keep it as curator responsibility.

## 11. Proposed Phase 1B scope (not started)

Per the approved decisions, plus open items from this phase:

1. **Curator cancellation of their own unused commitments.**
   - Only the allocation's curator may cancel (the owner's emergency release stays).
   - Releases `maxOut − consumed` immediately.
   - Single-use and replay-safe: a canceled allocation cannot be re-consumed or re-canceled, and its nonce stays
     burned.
   - Accounting tests: `Q`, `curatorReserved`, and the effect on queue liveness. Cancellation can only shorten the
     bound.
2. **EIP-712 signed allocation requests.** The `AllocationRequest` struct is already shaped for it: domain separator,
   curator signature, nonce and deadline, using the OZ remapping.
3. **Queue hardening, depending on decisions 2–4.** Optional minimum request size or cooldown; a batched
   `processQueue` + claim helper.
4. **Keeper-friendly views.** Next finalizable request, expired-unreleased allocation enumeration, and `canRelease`.
   Lazy expiry stays.
5. **Optional, if approved:** the exact-allowance mode as a configurable hook variant, behind the existing comparison
   tests.

**Out of scope until approved** (per CLAUDE.md): ring-buffer epoch expiry, oracle, performance fees, governance, SDK,
frontend, deployment.
