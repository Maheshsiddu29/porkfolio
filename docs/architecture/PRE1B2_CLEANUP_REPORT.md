# Porkfolio — Pre-1B-2 Security Cleanup Report

| | |
|---|---|
| **Status** | **PASS** for the code fixes (Tasks 1–2) and the analyses (Tasks 3–4). Nothing from Phase 1B-2 is implemented. |
| **Base** | `48af4f9` (`docs/natspec-standard`). It contains every other local branch (`main`, `milestone-0`, `phase-1a`, `phase-1a-h`, `phase-1b-0`, `phase-1b-1`); verified with `git merge-base --is-ancestor`. |
| **Branch** | `fix/pre-1b-2-security-cleanup` (local only) |
| **Toolchain** | forge 1.7.1, solc 0.8.26 (via-IR, `optimizer_runs = 44,444,444`, `bytecode_hash = "none"`), Slither 0.11.6 |

## 1. Bugs fixed

### 1.1 `admissibleCapacity` overflow (vault)

- **Defect.** Capacity was computed as `_sub0(N, Q + R + D)`. `R = bufferFloor` has no upper bound, and the guardian
  is allowed to raise it to any value, including `type(uint256).max` as a "stop new allocations" action. Whenever
  `Q + D > 0`, the sum `Q + R + D` could overflow. `admissibleCapacity` then reverted with panic `0x11`, and so did
  `allocate`, which calls it, instead of returning 0 / reverting `InsufficientBacking`.
- **Reachability.** Owner or guardian calls `setBufferFloor(a, x)` with `x > 2^256 − 1 − (Q + D)` while an allocation
  or a queued redemption exists in that asset. No assets were at risk: every affected path reverted. The impact was a
  wrong error (panic instead of `InsufficientBacking`) and a view that off-chain tooling could not read.
- **Fix.** `_sub0(_sub0(_sub0(N, Q), R), D)`. For non-negative terms this equals `max(0, N − Q − R − D)` exactly. It
  differs from the old code only where the old code overflowed, and is 0 there. NatSpec on the function explains this.
- **Why existing tests missed it.** The invariant handler never changed `bufferFloor`. `test_RO_guardianEmergency...`
  sets `R = max` only after releasing every allocation, so `Q + D = 0` and the sum did not overflow.

### 1.2 Validation inconsistencies

| Item | Finding | Change |
|---|---|---|
| Zero-address constructor validation | Vault: already complete and tested (`test_constructor_rejectsZeroAddressesAndBadPairs`). **Hooks: none.** A zero `vault_` deployed a hook that could never fill a swap and gave operator rights over its claims to `address(0)`. A zero `hookOwner_` deployed a pool that could never be configured. A zero `poolManager_` failed later with an opaque revert. | `BaseCompatibleHook` constructor reverts `ZeroAddress()` first, before the address-permission check. |
| Error for zero-amount swaps | `beforeSwap` reported `amountSpecified == 0` as `ExactOutputNotSupported`. | New `ZeroInput()` error inside the existing `>= 0` branch, so the happy path gains no check. **Not reachable through the pinned PoolManager**, which reverts `SwapAmountCannotBeZero` before calling any hook (SOURCE `PoolManager.sol:193`, OBSERVED by `test_zeroAmountSwap_rejectedBeforeAndInsideHook`). Only the error a non-standard caller would see changes. |
| Loose 0.99 assertion | `_checkSwapAccounting` asserted `amountIn ≥ 0.99 · out` while the fixture floor is exactly 1:1. | Asserts `amountIn ≥ ceil(out · effectiveFloorX96 / 2^96)`, pins the fixture floor at exactly `2^96`, and asserts `out < amountIn` (both hooks charge a positive fee or impact). This is strictly stronger than before. |
| Outdated `unlockCallback` payloads | `VaultSecurity` sent `(uint8, Currency, uint256, address)`, an old encoding. `ShareSecurity` used a bare `uint8` for the action. | Both use the current `(CallbackAction, address, uint256, uint256)` encoding. The `VaultSecurity` test now sends a well-formed `Withdraw` of the whole backing to the attacker, decodes it to prove it is well-formed, and asserts nothing moved. |

**Externally observable changes:** two new errors on both hooks; hook constructors now revert on zero arguments; the
error for an unreachable zero-amount path is different. The vault ABI and the storage layouts of all three contracts
are unchanged (§3).

## 2. Regression tests added

| Test | What it proves |
|---|---|
| `test/security/AdmissibleCapacity.t.sol` (7 tests, 3 fuzz) | Guardian `R = max` with `Q > 0` gives capacity 0 and `InsufficientBacking(1, 0)`. Floors `max`, `max − 1`, `max − Q − D` (largest non-overflowing value), `max − Q − D + 1`, `max − Q`, `max − D` with real `Q, D > 0`. The exact boundary keeps its old behaviour: `cap` fits, `cap` reverts with `R + 1`, then 1 more unit is refused. Fuzz: independent `B, W, Q, R, S, P` storage values (`Q`, `R` anywhere in `uint256`) against a two-limb reference that shares no code path with the vault. Fuzz: equality with the old formula wherever it did not overflow. Fuzz: `allocate` end to end on real state. |
| Invariant handler `setBuffer` + `capacityReverted` flag | Guardian draws `R = max − offset`, offset ∈ [0, Q + D] (the overflow window); owner draws ordinary values. `admissibleCapacity` must never revert, and `invariant_equationsFromRawSources` checks its value against raw sources. |
| `VaultTestBase._assertEquationsWith` | No longer forms `Q + R + D` itself; it compares `R` against `N − (Q + D)`. |
| `test_zeroAmountSwap_rejectedBeforeAndInsideHook` | PoolManager rejects a zero swap first and never calls the hook; a direct call reports `ZeroInput`; positive amounts still report `ExactOutputNotSupported`. |
| `test_hookConstructor_rejectsZeroAddresses` | All six zero cases across both hooks; a non-zero control fails only on the unmined address. |
| `test/integration/TradeSplitting.t.sol` (4 tests) | Characterization of trade splitting (§5). |

**Regression evidence (OBSERVED).** Run against the unfixed vault, the new capacity tests fail with
`panic 0x11` (5 of 7; the exact-boundary test and the reference self-check pass, as they should). The extended
invariant campaign fails 2 invariants (`capacityReverted`, and a panic in `equationsFromRawSources`) at the default
64 × 64 configuration.

**Mutation testing.** No mutation tool is installed (`gambit` and `vertigo-rs` are absent). Twelve hand-written mutants
were applied one at a time to the changed lines. Each was run against the four affected test files, then reverted with
`git checkout`, and the tree was confirmed clean. **12/12 killed:**

| Mutant | Killed by |
|---|---|
| V1 old summed formula; V5 plain checked subtraction | panics in AC tests and both invariants |
| V2 drop `R`; V3 drop `D`; V4 drop `Q` | AC reference fuzz, `equationsFromRawSources`; V4 also `reserved > backing` |
| V6 result `+ 1`; V7 result `− 1` | AC reference fuzz, exact-boundary test, invariants |
| H1 drop `ZeroInput` branch; H5 zero reports `ExactOutputNotSupported` | `test_zeroAmountSwap_rejectedBeforeAndInsideHook` |
| H2 drop constructor zero check; H3 ignore `hookOwner_`; H4 ignore `vault_` | `test_hookConstructor_rejectsZeroAddresses` |

## 3. Gas and bytecode (OBSERVED)

The before figures come from a detached worktree at `48af4f9` (dependencies symlinked), run on the same test files as
after.

| Contract | Runtime | Init code | EIP-170 margin | ABI | Storage layout |
|---|---|---|---|---|---|
| `SharedCommitmentVault` | 22,772 → **22,814 (+42)** | 23,402 → 23,444 | 1,804 → **1,762** | unchanged | unchanged |
| `HookA_DynamicFee` | 7,129 → 7,174 (+45) | 7,910 → 8,011 | 17,402 | +`ZeroAddress()`, +`ZeroInput()` | unchanged |
| `HookB_BoundedImpact` | 6,839 → 6,884 (+45) | 7,620 → 7,721 | 17,692 | +`ZeroAddress()`, +`ZeroInput()` | unchanged |

| Path (`--isolate`, `GasBaseline` logs) | Before | After | Δ |
|---|---|---|---|
| `allocate` | 321,325 | 321,386 | +61 |
| Hook A exact-in swap (router + PM + hook + vault) | 214,443 | 214,443 | 0 |
| Hook B exact-in swap | 214,363 | 214,363 | 0 |
| `admissibleCapacity` (gas report, median over identical tests) | 12,400 | 12,461 | +61 |

Other `--isolate` gas tests move by +61 per `allocate` they contain (+122 for two). `test_gas_initialDeposit`
changes by +9,094, which is vault deployment of 42 more bytes. Swap, deposit and instant-redeem paths are unchanged.

## 4. Validation

| Command | Result |
|---|---|
| `forge fmt --check` | clean |
| `forge build --force --sizes` | compiles; sizes as in §3 |
| `forge test -vvv` | **188 passed, 0 failed, 0 skipped** (18 suites). Baseline at `48af4f9`: 175 (16 suites). |
| `FOUNDRY_PROFILE=ci forge test --match-test testFuzz` | 10 fuzz tests × 10,000 runs, all pass |
| `FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-contract VaultInvariants -vv` | 13 invariants × 32,768 calls, all pass, 0 reverts recorded |
| `slither . --filter-paths "lib/\|test/" --exclude-dependencies` | **21 results, same detectors and counts as the Phase 1B-1 triage** (`PHASE1B1_REPORT.md` §7). None is in the changed lines. |
| Mutation | 12/12 killed (§2) |

## 5. Trade splitting (Task 3)

Full analysis: `TRADE_SPLITTING.md`. In short:

- Both hooks price per swap, so splitting lowers the total cost.
- Hook A: up to half of the utilisation-dependent fee. 8,000 in: 32.8 → 20.18 with 8 swaps (OBSERVED).
- Hook B: almost all of the impact. 1,000 in: 1.0 → 0.1054 with 10 swaps (OBSERVED).
- Hook B's `maxImpactPips` is a **per-swap** bound: a 5,000 trade that reverts as one swap executes as five swaps in
  one transaction (OBSERVED).
- No split can trade below the vault floor, and accounting stays exact.

The consequences are lower LP revenue than quotes imply and, for Hook B, almost no protection beyond the vault floor
against split flow at a stale reference price. Pricing formulas are not changed here.

## 6. Curator revocation (Task 4)

Full specification: `CURATOR_REVOCATION.md`. In short:

- Deregistration must stop all new activation, **including relayed signatures** (R1). The current 1B-0 spec omitted
  this check.
- It should not stop consumption of existing allocations. Hook deregistration, emergency release, pause and halt are
  the immediate consumption stops.
- Re-registering a curator would revive its outstanding signatures; decision D15 recommends a per-curator signed
  epoch to prevent this.

`PHASE1B_CURATOR_AUTH.md` (§4, §7.5, §13) and the Phase 1B-2 plan in `PHASE1B_THREATS_AND_PLAN.md` §3 are updated with
R1–R6, D15 and D16.

## 7. Residual risks and tests not run

- The trade-splitting behaviour remains (documented, not fixed). Hook B's cap should not be relied on as an aggregate
  limit.
- The `ZeroInput` path is reachable only by a caller with PoolManager authority. It is tested by pranking the
  PoolManager, not through it.
- Splitting gas (~113k per extra piece) was measured in-test with `gasleft()`, not `--isolate`. It is indicative only.
- No external mutation tool was run; the mutants are hand-written and limited to the changed logic.
- `cache/invariant/` (gitignored failure-replay data) was deleted after the mutation runs so that recorded failures from
  mutants would not be replayed. Any earlier contents of that directory were also removed.
- Not run: formal verification, testnet or fork tests, any audit.

## 8. Next action requiring approval

1. Review and approve decisions **D15** (signed curator epoch versus the alternatives) and **D16** (no curator freeze
   in `exchange`) before the Phase 1B-2 struct is finalized.
2. Decide whether the trade-splitting behaviour (`TRADE_SPLITTING.md` §6) is acceptable for UHI11 or needs a pricing
   redesign, and when.
3. Approve starting Phase 1B-2 (EIP-712 authorization lifecycle).
