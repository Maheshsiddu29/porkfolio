# Porkfolio — Phase 1B-1: Risk Roles and Vault-Enforced Price Floors — Report

**Status: PASS.**

- The vault now enforces its own minimum execution price in each direction. Curator signatures and hooks cannot weaken
  it.
- Risk administration is split into an owner and a tighten-only guardian.
- Ownership transfer is two-step.
- Curators must be registered.
- No EIP-712 code was written; that is Phase 1B-2.
- No accounting equation, settlement step or redemption rule changed.

| | |
|---|---|
| **Branch** | `phase-1b-1`, created from `phase-1b-0` at `328b851`. Earlier branches are unchanged. |
| **Toolchain** | forge 1.7.1, solc 0.8.26 (via-IR, `optimizer_runs = 44,444,444`), Slither 0.11.6 |
| **Decisions** | `PHASE1B_DECISIONS.md` (D1–D14, with the D3, D12 and D14 amendments) |

## 1. Contract and risk-architecture changes

### 1.1 Roles (`c4018c6`, `be8457e`)

| Capability | Owner | Guardian | Others |
|---|---|---|---|
| `transferOwnership` (nominate; zero cancels) / `acceptOwnership` (nominee only) | nominate | — | nominee accepts |
| `setGuardian` (zero removes) | ✓ | — | — |
| `setPaused(true)` / `setPaused(false)` | ✓ / ✓ | ✓ / — | — |
| `setConsumer(x, true)` / `(x, false)` | ✓ / ✓ | — / ✓ | — |
| `setCurator(x, true)` / `(x, false)` (**new registry**) | ✓ / ✓ | — / ✓ | — |
| `setCuratorCeiling`: raise / lower | ✓ / ✓ | — / ✓ | — |
| `setBufferFloor`: lower / raise | ✓ / ✓ | — / ✓ | — |
| `setSellFloor`: open (from unset) or lower / raise | ✓ / ✓ | — / ✓ | — |
| `setSellHalted(true)` / `(false)` | ✓ / ✓ | ✓ / — | — |
| `release` before expiry (emergency) | ✓ | ✓ | after expiry only |

**How this is enforced.** A single internal `_authorize(bool riskReducing)` implements the matrix:

- The owner is always allowed.
- The guardian is allowed only when `riskReducing`; otherwise it gets `GuardianCannotIncreaseRisk`.
- Anyone else gets `NotOwner`.

**What the guardian cannot reach.**

- It cannot touch `transferOwnership`, `acceptOwnership` (unless the owner nominated it) or `setGuardian`. So guardian
  powers cannot be escalated into owner powers (`test_RO_guardianCannotEscalateOrIncreaseRisk`).
- None of these functions moves assets. `test_RO_guardianEmergencyActions_moveNoAssets` applies every guardian power
  at once and checks that PM claims, ERC-20 custody, backing and shares are all unchanged.

**Storage.** `paused` was repacked with `owner` (`be8457e`), after the new fields had pushed it into its own slot.

### 1.2 Price policy (`d2fd4f3`)

```
sellPolicy[currencyOut] = { uint160 minInPerOutX96 /* f_v, Q64.96 raw-in per raw-out; 0 = closed */, bool halted }
allocate:  f_v != 0, !halted, curator floor f_c >= f_v              (zero f_c therefore impossible)
exchange:  amountIn >= ceil(amountOut * max(f_v read now, f_c) / 2^96)      on the exact ERC-6909 amounts moved
setSellFloor(out, F):  F != 0;  owner: any;  guardian: only F >= current != 0;
                       D14: if f_opp != 0 then F >= FullMath.mulDivRoundingUp(2^96, 2^96, f_opp)
setSellHalted(out, h): halt owner|guardian; resume owner
view effectiveFloorX96(allocationId)
```

**What is preserved.**

- The hooks are **unchanged**; the vault never relies on them.
- ERC-6909 settlement is unchanged: mint → `exchange` (pull input, then push output) → burn.
- Multi-LP share accounting and the withdrawal lifecycle are untouched.
- The direct allocation path is kept and passes every new check (decision D6).

## 2. Bytecode size (runtime, `forge build --sizes`)

| Commit | Vault runtime | Δ | EIP-170 margin |
|---|---|---|---|
| Phase 1A-H `f104afb` | 20,034 B | — | 4,542 B |
| `c4018c6` roles | 21,241 B | +1,207 | 3,335 B |
| `d2fd4f3` price policy | 22,780 B | +1,539 | 1,796 B |
| `be8457e` storage repack (HEAD source) | **22,772 B** | −8 | **1,804 B** |

**Where the growth comes from:**

- **Roles (+1.2 KB):** two-step ownership, guardian, curator registry, and `_authorize` at seven call sites.
- **Price policy (+1.5 KB):**
  - `setSellFloor`, which includes `FullMath.mulDivRoundingUp` for D14;
  - `setSellHalted`;
  - `_vaultFloor` and `_effectiveFloor`;
  - five new custom errors with arguments;
  - the `effectiveFloorX96` view.

The vault fits. **The remaining 1,804 B are very unlikely to absorb Phase 1B-2** (EIP-712, ECDSA and ERC-1271, nonce
bitmap, cancellation). See §9 for the D12-compliant plan.

## 3. Tests

### 3.1 Results

| Command | Result |
|---|---|
| `forge fmt --check` | exit 0 |
| `forge build --force` | success; 5 `block-timestamp` lint notes (unchanged, intentional) |
| `forge test -vvv` | **16 suites, 175 passed, 0 failed** (Phase 1A-H: 12 suites, 137) |
| `FOUNDRY_PROFILE=ci forge test --match-test testFuzz` | 7 fuzz tests × 10,000 runs, all pass (2 new) |
| `FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-contract VaultInvariants --fuzz-seed {0x1,0x2,0x3,0x5eed}` | 13 invariants (+ progress test) × 32,768 calls, all pass on all 4 seeds |

### 3.2 New tests (38)

| File | Tests | What they cover |
|---|---|---|
| `test/security/Roles.t.sol` | 9 | two-step ownership (accept, replace, cancel, replay); guardian escalation attempts; strangers; a removed guardian; guardian actions move no assets; curator registry; full emergency posture vs all LP exit paths |
| `test/security/PricePolicy.t.sol` | 17 (2 fuzz) | see the list below |
| `test/integration/HookPriceBands.t.sol` | 9 | Hook A and Hook B, both directions, on an 18/18 pair and a 6/18 USDC/WETH pair (see below) |
| `VaultInvariants.t.sol` (extended) | +3 invariants | INV-P1 `everyExchangeMeetsEffectiveFloor`, which checks **measured** ERC-6909 deltas in 512-bit arithmetic for every successful swap; D14 `directionalFloorsConsistent`; INV-R1 `guardianOnlyTightens`. Five new handler actions: guardian tighten, guardian loosen/resume attempts, guardian halt, owner resume, owner loosen to the D14 boundary. |

`PricePolicy.t.sol` covers:

- zero, invalid and unset floors;
- the fail-closed unset floor at exchange (via `vm.store`);
- exact floor vs one raw unit below, on measured claim deltas;
- an exact-rational-inequality fuzz against an independent 512-bit reference;
- tightening applied to live allocations, and loosening never below the curator floor;
- guardian tighten-only, and direction-specific halts;
- the D14 exact boundary with non-divisible rounding;
- D14 extremes (`2^32+1` vs `2^160−1`, and a `2^320` product);
- a crossed pair shown to be a money pump and rejected;
- a round-trip-at-the-floors fuzz;
- a malicious hook, both inside a swap and calling `exchange` directly outside one;
- atomic rollback;
- the `uint160` overflow boundary;
- a differential LP lifecycle with trading halted.

`HookPriceBands.t.sol` covers:

- the real hook quote passes at the floor and fails one unit above;
- hook-owner mispricing is refused only in the harmful direction;
- cyclic trades through both hooks are never profitable;
- the 6/18 spec values;
- 6/18 both directions with the pivot at the reference;
- 6/18 with the pivot below market, where only the favourable direction executes;
- the crossed Phase 1B-0 example is rejected;
- the mixed-decimal exact boundary (2,850.000001 USDC for 1 WETH).

### 3.3 Existing tests changed (security intent kept)

| File | Change | Why |
|---|---|---|
| `test/utils/VaultTestBase.sol` | registers the curator; sets 1:1 vault floors in both directions; default curator floor 0.99 → 1.0 | Curators must be registered. A curator floor below the vault floor is now rejected. 1:1 in both directions is the tightest non-crossing pair (product = `2^192`), and both hooks quote strictly inside it. |
| `test/unit/VaultFunding.t.sol` | `test_admin_onlyOwner` performs the accept step | two-step ownership |
| `test/security/Initialization.t.sol` | ownership test accepts; second vault registers the curator and a floor | same behaviour, under the new prerequisites |
| `test/security/VaultSecurity.t.sol` | `test_unauthorisedCurator_hasZeroCeiling` now checks **both** the registry rejection and, once registered, the zero-ceiling rejection; `test_nonce_isCuratorScoped` registers its second curator | stronger than before |
| `test/security/ZeroAssetStates.t.sol` | four floor-0 drains replaced by trades **exactly at the most permissive legal floor** (`2^32+1` vs `2^160−1`, decision D13); assertions re-derived (for example, the remaining token1 equals the exact floor payment, and max post-depletion deposit < 0.01% of the pool) | Floor-0 trades no longer exist. All zero-asset and dust states are still reached and checked by `_assertEquations`: one asset at zero, near-total depletion, the dust redemption revert, dust request finalized at zero, dust partial slice not finalized. |
| `test/utils/MaliciousConsumerHook.sol` | new `ExactAmounts` mode (enum appended) | lets tests choose exact in/out amounts |
| `test/invariant/VaultInvariants.t.sol` | handler curator floor 0.98 → `max(1.0, live vault floor)`; policy actions; three invariants | as above |

No existing invariant was weakened or removed.

### 3.4 Mutation check (manual, not committed; source restored byte-identical)

| # | Mutation | Result | Caught by (examples) |
|---|---|---|---|
| M1 | `exchange` uses the curator floor only (ignores the live vault floor) | caught (5) | `test_PP_tighteningAppliesToOutstandingAllocations_immediately`, `test_HB_realHookQuote_atFloorPasses_oneUnitAboveReverts` |
| M2 | effective floor = `min` instead of `max` | caught (7) | `test_PP_loosening_neverGoesBelowCuratorFloor`, `test_PP_exactlyAtFloor_passes_oneUnitBelow_reverts` |
| M3 | `allocate` skips curator floor ≥ vault floor | caught (1) | `test_PP_zeroAndInvalidFloorsRejected` |
| M4 | guardian may lower floors | caught (4) | `test_PP_guardianIsTightenOnly` path, `test_handler_makesProgress` |
| M5 | guardian may open an unset direction | caught (1) | `test_PP_unconfiguredDirection_isClosed` |
| M6 | D14 check removed | caught (4) | `test_PP_D14_crossedPair_wouldBeProfitable_andIsRejected`, `test_HB_6x18_crossedPhase1B0Example_rejected` |
| M7 | D14 bound rounded down (`mulDiv`) | caught (4) | `test_PP_D14_inconsistentFloorsRejected_exactBoundary`, `test_PP_D14_extremeFloors_noOverflow` |
| M8 | halt ignored | caught (1) | `test_PP_halt_blocksOneDirection_only` |
| M9 | guardian may resume a direction | caught (3) | `test_PP_guardianIsTightenOnly`, `test_handler_makesProgress` |
| M10 | required input rounded down | caught (9) | `test_HB_6x18_exactBoundary_mixedDecimals`, `test_HB_realHookQuote_atFloorPasses_oneUnitAboveReverts` |
| M11 | unset vault floor not rejected | caught (2) | `test_PP_unconfiguredDirection_isClosed`, `test_PP_unsetFloorAtExchange_failsClosed` |
| M12 | `acceptOwnership` callable by anyone | caught (3) | `test_RO_twoStepOwnership` |
| M13 | one-step ownership transfer | caught (4) | `test_RO_twoStepOwnership`, `test_admin_onlyOwner` |
| M14 | curator registry not enforced | caught (2) | `test_RO_curatorRegistry`, `test_unauthorisedCurator_hasZeroCeiling` |
| M15 | guardian may unpause | caught (1) | `test_RO_guardianCannotEscalateOrIncreaseRisk` |
| M16 | guardian may register consumers | caught (1) | `test_RO_guardianCannotEscalateOrIncreaseRisk` |
| M17 | guardian may raise ceilings | caught (1) | `test_RO_guardianCannotEscalateOrIncreaseRisk` |
| M18 | setter accepts a zero vault floor | first run: caught (1), **weakly**; after strengthening: caught (2) | `test_PP_zeroAndInvalidFloorsRejected` caught it only by a *different* error, because D14 also rejects zero when the opposite floor is set. `test_PP_unconfiguredDirection_isClosed` now asserts `ZeroPriceFloor` on a vault with **no** opposite floor, where D14 cannot help. Re-running M18 then fails both tests. |

All 18 mutations were caught. Each mutation was applied alone, the full suite was run (`forge test`), and the source was
restored and checked byte-identical (`cmp`).

## 4. Execution-price enforcement: argument

**Claim.** Every successful `exchange` against allocation `j` selling `out` satisfies

```
ΔIn · 2^96 ≥ ΔOut · max(f_v[out] at that block, f_c(j))           (P1)
```

where `ΔIn` and `ΔOut` are the changes in the vault's PoolManager ERC-6909 balances.

1. **`exchange` computes the floor at execution.** It computes `F = max(f_v, f_c)` by calling `_vaultFloor`, which
   reverts if `f_v = 0` or the direction is halted. It then computes `r = ⌈amountOut · F / 2^96⌉` with
   `FullMath.mulDivRoundingUp`.
   - `amountOut < 2^127` and `F < 2^160`, so the 512-bit product cannot overflow and `r < 2^191`.
   - `exchange` reverts unless `amountIn ≥ r`. For an integer `amountIn`, `amountIn ≥ ⌈x / 2^96⌉ ⇔ amountIn · 2^96 ≥ x`,
     so the check is exactly P1 on the arguments.
2. **The vault moves exactly the arguments.** The same call then executes `transferFrom(hook → vault, in, amountIn)`
   and `transfer(vault → hook, out, amountOut)`. Pinned v4-core `ERC6909.transfer` and `transferFrom` move exactly
   `amount`, charge nothing and call no one. So `ΔIn = amountIn` and `ΔOut = amountOut`. Any failure in between reverts
   the whole swap.
3. **The floor cannot be bypassed.**
   - `f_v` is read from storage in the same call, so changes apply to outstanding allocations immediately.
   - `f_c ≥ f_v_at_allocation` is enforced at `allocate`, and `max` keeps `f_c` binding after a loosening.
   - `f_v` can never become 0 again (`ZeroPriceFloor`).
   - No other function moves vault claims to a hook.

**Evidence.**

- `test_PP_exactlyAtFloor_passes_oneUnitBelow_reverts` checks measured deltas.
- `testFuzz_PP_acceptanceIsExactRationalInequality` (10,000 runs) compares against an independent 512-bit reference.
- `invariant_everyExchangeMeetsEffectiveFloor` checks measured deltas on every successful handler swap, while floors
  are tightened, loosened and halted.
- Mutations M1, M2, M10 and M11 are caught.

This is an argument plus tests, **not a formal proof**.

## 5. Both-direction round-trip safety (D14)

**Condition.** With `F_AB` = raw A per raw B (vault sells B) and `F_BA` = raw B per raw A (vault sells A), the vault
requires `F_AB · F_BA ≥ 2^192` whenever both are set.

**Proof sketch** (`PHASE1B_DECISIONS.md` D14).

- Choose any `k ∈ [2^96/F_BA, F_AB/2^96]`; the interval is non-empty exactly under the condition.
- Every floor-respecting trade leaves `V_k = A + k·B` non-decreasing.
- So no sequence of trades of any length, through any hooks or allocations, can leave the vault holding less of both
  assets.
- Curator floors only raise `F_eff`.

**Exact check.**

- `F ≥ ⌈2^192 / f_opp⌉` is computed as `FullMath.mulDivRoundingUp(2^96, 2^96, f_opp)`, which is ≤ `2^192`, so there is
  no overflow and no 256-bit product.
- It is exact for integer `F`.
- Tested at the non-divisible boundary (`⌈2^96/3⌉`) and at the extremes (`2^160−1 × 2^160−1` ≈ `2^320`; minimum legal
  floor `2^32+1`).
- Mutations M6 and M7 are caught.

**Measured behaviour.**

- `testFuzz_PP_D14_roundTripAtFloors_neverProfitable`: 10,000 runs, both legs executed exactly at their floors over
  `f1 ∈ [2^32+1, 2^160−1]`.
- `test_HB_cyclicTradesThroughBothHooks_neverProfitable`: five cycles through the real hooks.
- `invariant_directionalFloorsConsistent`.

**Practical consequence.**

- The two floors define a pivot interval. A hook trades both directions only when its spread straddles the interval.
- With the USDC/WETH floors at 2,850, the vault keeps selling WETH but stops buying it at about 2,985
  (`test_HB_6x18_pivotBelowMarket_onlyFavourableDirectionExecutes`).
- This is a liveness cost in one direction, never an LP-value cost.
- The Phase 1B-0 worked example (2,850 / 3,150) was a crossed pair. It is corrected in the decision record and rejected
  by `test_HB_6x18_crossedPhase1B0Example_rejected`.
- This check was judged **acceptable**, so no alternative was substituted.

## 6. Gas: Phase 1A-H vs Phase 1B-1

**Method.** The same gas test files (`LpGas`, `GasBaseline`, `AuthorizationComparison`) were run with `--isolate -vv` on
a clean `git archive` of `f104afb` and on HEAD. The figures are the in-test `gasleft()` deltas the tests log. They are
not comparable with the trace-frame figures in `PHASE1AH_REPORT.md` §5, which used a different method; both columns
here use the same method.

| Path | Phase 1A-H | Phase 1B-1 | Δ |
|---|---|---|---|
| Hook A exact-in swap (router+PM+hook+vault) | 211,669 | 214,443 | **+2,774** |
| Hook B exact-in swap | 211,589 | 214,363 | **+2,774** |
| operator-mode test-hook swap | 212,202 | 214,918 | +2,716 |
| allowance-mode test-hook swap | 228,116 | 230,289 | +2,173 |
| `allocate` | 316,536 | 321,325 | **+4,789** |
| `initialDeposit` | 236,439 | 236,819 | +380 |
| `deposit` (new LP) | 148,175 | 148,577 | +402 |
| `redeem`, instant | 159,585 | 159,821 | +236 |
| `redeem`, fully queued | 145,595 | 145,161 | −434 |
| `redeem`, partial + queued | 253,577 | 253,333 | −244 |
| `redeem` while head deliverable | 234,803 | 235,039 | +236 |
| `redeem` while head blocked | 133,266 | 132,832 | −434 |
| `processQueue(1)` | 121,204 | 121,394 | +190 |
| `processQueue`, 10 canceled + 1 live | 145,334 | 145,524 | +190 |
| `claim` | 135,094 | 135,298 | +204 |
| `cancelRequest` | 39,159 | 39,173 | +14 |
| native v4 swap (reference) | 150,274 | 150,274 | 0 |

**Attribution.**

- **Swap:** one extra cold `SLOAD` of `sellPolicy[out]` (2,100 under EIP-2929), plus the comparison logic.
- **`allocate`:** two extra cold `SLOAD`s (`isCurator`, `sellPolicy`) plus checks.
- **LP paths:** changes of a few hundred gas or less. The logic of these paths is unchanged, so this is consistent with
  dispatcher and bytecode-layout effects of the larger contract. It was not traced instruction by instruction.

## 7. Slither (`slither . --filter-paths "lib/|test/" --exclude-dependencies`)

There are **21 results** (Phase 1A-H: 19). No new detector category above Low.

| Detector | Count | Change | Disposition |
|---|---|---|---|
| arbitrary-send-erc20 (High) | 1 | unchanged | accepted in Phase 1A §7 (payer is always `msg.sender`) |
| unused-return (Medium) | 4 | unchanged | upstream returns `true` or reverts |
| reentrancy-events | 6 | unchanged | CEI; events after PoolManager calls |
| timestamp | 3 | unchanged | intentional |
| cyclomatic-complexity | 3 | `allocate` 16 (gained the curator and price checks) | linear guard sequences |
| naming-convention | 2 | unchanged | names required by the blueprint |
| **missing-zero-check** | **2 (new)** | `setGuardian`, `transferOwnership` | **Intentional.** Zero removes the guardian or cancels a nomination. A zero `pendingOwner` can never accept (`msg.sender ≠ 0`). Tested in `test_RO_nominationCanBeReplacedOrCanceled` and `test_RO_removedGuardianLosesEveryPower`. |

## 8. Residual risks and tests not run

**Trust and economic limits.**

- **A static floor is not fair pricing** (`PHASE1B_PRICE_POLICY.md` §9). LP loss against the market is bounded by
  `remaining × (M − F_eff)⁺` per allocation, and it grows as the market drifts from the floors until governance updates
  them.
- **The owner is fully trusted** (D3). It can loosen floors, register hooks and raise ceilings with no delay.
  Multisig/timelock governance and emergency authority need a separate review **before any real-value deployment**.
- **The guardian can grief liveness:** halt, pause, deregister, release. It cannot move value or increase risk.
- **Tightening can make outstanding allocations unexecutable.** Their capacity stays reserved until release, which can
  delay instant LP exits. Emergency release is the mitigation (`PHASE1B_PRICE_POLICY.md` §7).
- **A deregistered curator's existing allocations stay consumable** until released (`CA` §7.5). This is by design, and
  `test_RO_curatorRegistry` covers it.

**Testing limits.**

- **Invariant handler activity is moderate.** The per-run logs (last run only) show only a few swaps and allocations
  per 128-call run, because policy actions and halts dilute trading. INV-P1 is also covered by direct fuzz tests.
- **Not run:**
  - Echidna/Medusa
  - `forge coverage`
  - fork or testnet runs
  - CREATE2 salt mining
  - invariant campaigns beyond 256 × 128 on four seeds

**Unchanged from earlier phases.**

- Not audited; no formal verification.
- Fee-on-transfer, rebasing and ERC-777 tokens are unanalysed.
- Native ETH is unsupported.
- Exact-output swaps are unsupported.

## 9. Proposed Phase 1B-2 plan (EIP-712 curator authorization). Not started.

**Scope, from `PHASE1B_CURATOR_AUTH.md` with the approved decisions:**

- the `CuratorAuthorization` struct, shared by `allocate` (direct) and `allocateWithSig`;
- OZ 5.0.2 `EIP712("Porkfolio Vault", "1")` and `SignatureChecker` (ECDSA, then ERC-1271 `staticcall`);
- an unordered nonce bitmap with `invalidateNonces`;
- `validAfter`;
- `cancelAllocation` (curator, immediate);
- `emergencyRelease` split from `release`, plus `ReleaseReason`.

**Step 0: size (D12, before any 1B-2 code).** At 1,804 B of margin, 1B-2 will very likely exceed EIP-170 at the
current `optimizer_runs = 44,444,444`. Proposed order:

1. Measure the vault at lower optimizer settings (for example 10,000, 1,000 and 200 runs), with sizes **and** the §6
   gas table, and propose one vault-specific setting for approval. Phase 1B-2 does not lower it without approval.
2. If that is not enough, move non-security-critical **views** (previews, `deliverableShares`, `effectiveFloorX96`)
   into a stateless lens contract, keeping the state-changing logic and every check in the vault.
3. A contract split of authorization or the registry happens only after architectural review (D12).

**Commits (each green; sizes measured after each):**

1. `build: vault optimizer profile` (only if approved after Step 0).
2. `feat(auth): EIP-712 curator authorization with unordered nonces`. Signing and replay protection land together.
   Tests T-03, T-05, T-06 and T-10 use `Mock1271Wallet` (valid, invalid, revoked, reentrant, gas-burner, return-bomb).
3. `feat(auth): curator cancellation and emergency release`. Tests T-01, T-07, T-08 and T-09, with races in both orders.
4. `test: authorization invariants, fuzzing, gas; report`. Covers INV-A1 to INV-A4, a handler that activates signed
   and direct authorizations, cancels and invalidates, gas for `allocateWithSig` (EOA and ERC-1271), and mutations
   M5–M10 from `PHASE1B_THREATS_AND_PLAN.md`.

**Needs approval before starting:** this plan, and the Step 0 outcome.
