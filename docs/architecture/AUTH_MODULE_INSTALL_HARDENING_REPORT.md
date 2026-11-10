# Porkfolio — Authorization Module Installation Hardening: Report

**Status: PASS (local).** Branch `fix/auth-module-install-hardening`, from `phase-1b-2-4-auth-security-closure` at
`5489b70`. Nothing is pushed, merged or deployed. No audit or formal verification is claimed. Labels: SOURCE (read
from the code), OBSERVED (measured or asserted by a named test), ESTIMATE.

## 1. What changed

| Commit | Content |
|---|---|
| `8eb72cc` | `refactor(vault)`: `reserveFor` reads each request field from calldata once. −550 bytes, same checks in the same order |
| `3021a36` | `feat(auth)`: `setAuthModule` asks `authModuleId()` before `vault()`; `CuratorAuthorization.authModuleId()`; tests |
| (docs commit) | this report, `MODULE_INSTALLATION_CHECKLIST.md`, release notes, security model, readiness, plan, READMEs |

**Installation check (SOURCE).** For a non-zero candidate `m`, `setAuthModule` now:

1. `staticcall(gas(), m, authModuleId())`, copying at most 32 bytes. Passes only if the call succeeded, returned at
   least 32 bytes, and the first word equals `AUTH_MODULE_ID` = `keccak256("porkfolio.vault.auth-module.v1")` =
   `0xbdeb213b…16000a`.
2. Only if step 1 passed: the same for `vault()`, which must equal this vault's address (clean upper bits).
3. Otherwise `InvalidAuthModule(m)`. Then, unchanged: the current module is retired, a retired candidate reverts
   `AuthModuleRetired`, the candidate is installed, `AuthModuleSet` is emitted.

`AUTH_MODULE_ID` is a file-level constant in `ISharedCommitmentVault.sol`, imported by the vault and the module, so
the two copies cannot drift. It names a role ("authorization module of a Porkfolio vault, calling `reserveFor` as
declared"), not a build: a replacement module for a deployed vault must return the same value. It is public and
proves nothing about the code.

**Module (SOURCE).** `function authModuleId() external pure returns (bytes32)` returning `AUTH_MODULE_ID`. No
storage, no owner, no new permission, no dependency.

**Unchanged (SOURCE, OBSERVED).** Disabling (`setAuthModule(0)`) makes no call to any module, so it cannot be blocked
by a misbehaving one. Retirement rules, `reserveFor`'s checks, the EIP-712 type, domain and digest, nonces,
generations, swaps, ERC-6909 settlement, flow and exposure limits and every LP path are unchanged. No call was added on
the swap or LP paths (`test_ML_vaultCallsModuleOnlyAtInstall` counts calls to the installed and retired modules across
swaps, deposits, redemptions, queue processing, claims, cancellation, release and configuration: zero).

## 2. Bytecode

Vault runtime size, production build (2,000 runs), measured by compiling each variant (OBSERVED):

| Variant | Runtime | EIP-170 margin | Δ vs `5489b70` |
|---|---|---|---|
| `5489b70` (`vault()` check only) | 22,524 | 2,052 | — |
| + identity check, `if ok { second call }` (chosen) | 22,599 | **1,977** ✗ | +75 |
| + identity check, both calls always made | 22,581 | 1,995 ✗ | +57 |
| + identity check through a Yul helper function | 22,599 / 22,581 | — | same as the two above |
| `reserveFor` read-once refactor alone (`8eb72cc`) | 21,974 | 2,602 | −550 |
| **refactor + identity check (`3021a36`, final)** | **22,049** | **2,527** | **−475** |

The identity check measured +75 bytes, not the +91 the task assumed (+91 was the original `vault()` check in 1B-2.4).
That left 1,977 bytes, so at least 29 had to be recovered.

**The optimization (`8eb72cc`).** `reserveFor` read `req.consumer` 9 times, `req.maxOut` 14 times,
`req.expiry` 5 times, `req.currencyOut` 3 times and `req.minInPerOutX96` 3 times directly from the calldata struct
(counting error arguments, which are code even when they only run on a revert). Under via-IR every
such read recomputes the field's calldata offset and re-validates that the value fits its type (an `address` or
`uint128` with dirty upper bits reverts). The refactor copies each of these fields into a local at the point where it
was first read before. Why this is behaviour-preserving:

- Every check is still there, with the same condition, error and arguments, in the same order.
- Each field's first read happens at the same point as before, so even a malformed call (dirty upper bits, which the
  module never sends) reverts at the same place.
- Locals hold exactly the validated calldata values; `uint128 maxOut` and `uint64 expiry` keep the field types, and
  the `Allocation` written to storage and the `AllocationCreated` event receive the same values.
- No arithmetic, custody, accounting or storage layout changed. ABI identical, storage layout identical (compared with
  AST ids removed).
- Evidence: the full suite passed at `8eb72cc` alone (398/398) and at the final commit (402/402, default and CI
  profiles); mutants R1–R5 on the rewritten function (§5); gas on every allocation path fell by 2,138.

No check was removed, no optimizer setting changed, no contract was split, and the only assembly is the documented
install check. The chosen form of the check (`if ok`) costs 18 bytes more than making both calls unconditionally; it
was kept because "ask `vault()` only of a contract that claims to be a module" is easier to read and review.

**All production contracts (OBSERVED, `test/bench/run.sh`):**

| Contract | Runtime before → after | Init before → after | Margin after | Init-code keccak256 (no args) after | Runtime keccak256 (artifact) after |
|---|---|---|---|---|---|
| `SharedCommitmentVault` | 22,524 → **22,049** | 23,133 → 22,658 | **2,527** | `0xcd95dfdd…e31787` (was `0x3e6c360c…98bcb3`) | `0x5ab6d06f…db2b1e` (was `0x21be50c0…f8878d98`) |
| `CuratorAuthorization` | 7,310 → **7,409** | 8,488 → 8,587 | 17,167 | `0xd63ccb2f…b885fee7` (was `0x269a6d63…7ca1af4`) | `0x66cba666…5a96d76c` (was `0xa6e4e3ea…7769ba2a`) |
| `HookA_DynamicFee` | 7,174 (same) | 8,011 | 17,402 | `0x47abaff3…6c2713e2` (unchanged) | unchanged |
| `HookB_BoundedImpact` | 6,884 (same) | 7,721 | 17,692 | `0xdcdfba66…ed974d87` (unchanged) | unchanged |
| `VaultLens` | 6,972 (same) | 6,998 | 17,604 | `0x518bba97…d1977918a` (unchanged) | unchanged |

**CREATE2 and deployment records.** The vault's and the module's init code changed, so any CREATE2 address computed
for them changes, and so does the module's constructor-arguments hash wherever the vault address changes. The hooks'
init code is unchanged, but their constructor takes the vault address, so mined hook salts depend on the vault's
deployed address as before. No hash is hard-coded in the tests: `ProductionBuilds.t.sol` and
`ProductionArtifactSecurity.t.sol` compare the deployed code with the artifact files at run time, so no expectation
needed updating. Deployment documentation records the procedure (`MODULE_INSTALLATION_CHECKLIST.md`), not hashes.

**ABI.** Vault: identical (the `InvalidAuthModule(address)` signature is unchanged; only its documentation changed).
Module: adds `authModuleId() → bytes32` (selector `0x31b014a1`). Hooks and lens: identical.

**Storage layout.** Identical for all five contracts.

## 3. Gas (OBSERVED, production builds, `forge test --isolate`)

| Path | `5489b70` | Final | Δ |
|---|---|---|---|
| `setAuthModule` (replace) | 62,594 | 62,993 | +399 (one more `staticcall` to the candidate) |
| `setAuthModule` (guardian disable) | 54,169 | 54,169 | 0 |
| signed activation, EOA | 316,226 | 314,088 | −2,138 |
| signed activation, ERC-1271 | 319,638 | 317,500 | −2,138 |
| direct activation (`allocate`, steady state) | 296,059 | 293,921 | −2,138 |
| first allocation in the vault | 334,746 | 332,608 | −2,138 |
| swap HookA / HookB | 239,693 / 239,597 | same | 0 |
| deposit, redeem instant / queued, processQueue, claim | 149,223; 160,392 / 147,673; 121,985; 135,857 | same | 0 |
| cancel, release, freeze, unfreeze, revoke, setRiskLimit, invalidateNonces | — | same | 0 |
| deploy vault (CREATE) | 5,022,118 | 4,919,363 | −102,755 |
| deploy module (CREATE) | 1,674,576 | 1,696,917 | +22,341 |

The −2,138 on every allocation path comes from the refactor (fewer calldata reads and checks); the identity check
costs nothing outside `setAuthModule`.

## 4. Adversarial installation tests (OBSERVED)

Production-artifact harness (`ProductionArtifactSecurity.t.sol`, ABI only, contracts deployed from artifact files):

| # | Candidate | Result | Test |
|---|---|---|---|
| 1 | production `CuratorAuthorization` for this vault | installed, works | `test_PA_auth_moduleInstallCheck` |
| 2, 3 | production HookA, HookB (their `vault()` names this vault) | `InvalidAuthModule` | same |
| 4 | PoolManager | `InvalidAuthModule` | same |
| 5 | the vault itself | `InvalidAuthModule` | same |
| 6 | EOA | `InvalidAuthModule` | same |
| 7 | empty contract (`STOP`: calls succeed with no data) | `InvalidAuthModule` | same |
| 8 | right `vault()`, no `authModuleId()` | `InvalidAuthModule` | same |
| 9 | production module for another vault; candidate with right identity and another vault | `InvalidAuthModule` | same |
| 10 | empty, 31-byte, echoed-call-data answers to either question; dirty upper bits in `vault()` | `InvalidAuthModule` | same |
| 11 | identity `…v2`, identity with one bit flipped, the vault address as identity | `InvalidAuthModule` | same |
| 12 | reverting getters, including revert data equal to the expected word | `InvalidAuthModule` | same |
| 13 | getter that burns all gas, on either question (3,000,000 gas forwarded) | `InvalidAuthModule` | same |
| 14 | fallback with one fixed answer for every selector (this vault's address, or `AUTH_MODULE_ID`) | `InvalidAuthModule` | same |
| 15 | the module installed now | `AuthModuleRetired` | `test_PA_auth_installLifecycleAndSpoofedModule` |
| 16 | a replaced (retired) module | `AuthModuleRetired` | same |
| 17 | after a guardian disable: the disabled module, earlier modules; a new module by the guardian | `AuthModuleRetired`; `GuardianCannotIncreaseRisk` | same |
| 18 | malicious module returning both right answers | **installed** — the check cannot tell it apart; still bounded by `reserveFor` (`CuratorNotRegistered`, `StaleGeneration`); removed by the guardian's disable | same |

Every refusal is asserted to revert with exactly `InvalidAuthModule(m)`, to emit nothing, and to leave `authModule()`
unchanged; after the refusals the module installed at setup still activates and its allocation still swaps. The
emergency disable succeeds after refused candidates were proposed and a malicious one was installed.

Functional suite (`ModuleInstallation.t.sol`, production builds through `VaultTestBase`), 11 tests (3 new):
`test_MI_refusesCandidatesThatAreNotModulesForThisVault` (also the lens and an ERC-1271 wallet),
`testFuzz_MI_onlyTheModuleIdentityIsAccepted` and `testFuzz_MI_onlyThisVaultsAddressIsAccepted` (1,000 runs default,
10,000 in CI), `test_MI_oneAnswerForEverySelectorIsRefused`, `test_MI_failedOrShortAnswerCannotPass`,
`test_MI_gasBurningCandidateOnlyCostsTheOwner`, `test_MI_identityAskedFirst` (a hook gets one call, `authModuleId()`;
a module gets exactly two), `test_MI_bothRightAnswersAreNotProofOfAModule`, and the unchanged retirement and replay
tests. Invariant handler: `moduleTryInstallInvalid` also offers both hooks; INV-M9 asserts the installed module's
identity and vault.

Regression intent preserved: signed (EOA and ERC-1271) and direct activation, nonce replay, generations and
revocation, real PoolManager swaps through both hooks, ERC-6909 settlement, exposure and flow limits, LP deposits,
withdrawals and claims, module replacement and permanent retirement are all covered by the unchanged tests, which pass.

## 5. Validation (Foundry 1.7.1)

| Command | Result |
|---|---|
| `forge fmt --check` | clean |
| `forge build --force` / `--sizes` | ok; sizes in §2 |
| `forge test` (default, 1,000 fuzz runs) | **402/402** (398 before: +3 `ModuleInstallation`, +1 production-artifact) |
| `forge test` at `8eb72cc` (refactor only) | 398/398 |
| `test/bench/security.sh` (`FOUNDRY_PROFILE=ci`, 10,000 fuzz runs, forced rebuild) | exit 0: size gate ok (vault margin 2,527 ≥ 2,048); ProductionBuilds 3/3; ProductionArtifactSecurity 21/21; full suite 402/402 in 31 suites |
| `test/bench/run.sh` | exit 0; settings ok; §2, §3 |
| `FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-contract VaultInvariantsTest -vv` | 32/32 (28 invariants × 32,768 calls, 0 reverts; 4 progress tests). Last run: 5 invalid candidates refused, 3 retired reinstalls refused |
| `slither . --filter-paths "lib/\|test/" --exclude-dependencies` (0.11.6) | 32 results, the same 32 as at `5489b70` (compared without line numbers); no new finding |
| Mutation script (§5.1), whole suite per mutant | 15 mutants: 14 killed; 1 survivor (I3), shown to be equivalent |

### 5.1 Mutation checks

Scratch copy of the tree (lib symlinked), one asserted replacement per mutant, `forge test --fail-fast` on the **whole
suite** (default profile). Script kept outside the repository.

Unmutated baseline in the copy: 402/402. Suites run in parallel, so "first failing test" is whichever failed first
in that run; R3 and R5 were re-run once to record the test names, which the first run's output had truncated.

| ID | Mutation | Result (first failing test) |
|---|---|---|
| I1 | identity value not compared | killed: `testFuzz_MI_onlyTheModuleIdentityIsAccepted` |
| I2 | identity call success ignored (revert data read as the answer) | killed: `test_MI_failedOrShortAnswerCannotPass` |
| I3 | identity answer length not checked | **survived: equivalent mutant** (below) |
| I4 | identity check removed (`ok := 1`) | killed: `testFuzz_MI_onlyTheModuleIdentityIsAccepted` |
| I5 | `if ok` → `if 1`: the `vault()` result overwrites the identity result | killed: `testFuzz_MI_onlyTheModuleIdentityIsAccepted` |
| I6 | `if ok` → `if 0`: `vault()` never asked | killed: `test_ML_moduleForAnotherVaultRefused` |
| I7 | identity asked with the `vault()` selector | killed: every fixture's `setUp` (the real module is refused) |
| V11 | `vault()` answer length not checked | killed: `test_MI_failedOrShortAnswerCannotPass` |
| V12 | `vault()` answer not compared | killed: `test_ML_moduleForAnotherVaultRefused` |
| V13 | `vault()` call success ignored | killed: `test_PA_auth_moduleInstallCheck` |
| R1 | `reserveFor` stores the vault floor instead of the curator floor | killed: `test_priceFloor_enforced` |
| R2 | hook exposure computed from the curator's reserve | killed: `test_EX_partialConsumptionAndCloses` |
| R3 | curator ceiling not checked | killed by the exact error: `test_CA_failedActivationDoesNotConsumeNonce` (admission then refuses with `InsufficientBacking` instead of `CuratorCeilingExceeded`) |
| R4 | horizon bound off by one | killed: `test_horizonAndPastExpiry` |
| R5 | allocation stores the deadline as its expiry | killed: `test_RE_hook_cancelDuringConsumption` (the swap meets an already-expired allocation) |

**Why I3 is equivalent (SOURCE).** Before the identity call the vault writes the selector `0x31b014a1` into the last
four bytes of the zeroed word at 0x00. An answer of L < 32 bytes overwrites only bytes 0..L−1, so byte 31 of the word
read back is always `0xa1`. The last byte of `AUTH_MODULE_ID` is `0x0a`, so no short answer can equal it, with or
without the length check. The check is kept: it costs a few bytes, states the rule directly, and stays correct if the
identity value or the selector ever changes. For `vault()` the same leftover-byte effect is reachable (a vault address
ending in `0xcf`), which is why V11 is killed by a dedicated test.

## 6. Remaining trust assumptions and limits

- **The check is an interface check.** It refuses contracts that are not meant to be modules for this vault. It cannot
  refuse a malicious or buggy contract that returns both answers (OBSERVED, #18). Code verification against an
  independently reproduced build, and governance review, are required before every installation
  (`MODULE_INSTALLATION_CHECKLIST.md`). No on-chain code-hash allowlist exists; adding one needs a separate design
  decision.
- **The owner is trusted** to install only reviewed modules (`AUTH_SECURITY_RELEASE_NOTES.md` §2). A malicious module,
  once installed, is bounded by `reserveFor`: at worst every registered, unrestricted curator signing whatever the
  attacker wants, within their ceilings and every vault limit.
- **The identity value is fixed in the vault's bytecode.** Every future module for a deployed vault must return
  `AUTH_MODULE_ID`; a module that returns another value can never be installed there.
- **Length check on the identity answer.** With this identity value no test can show it is necessary: mutant I3 is
  equivalent (§5.1). It is kept as a direct statement of the rule.
- **Remote CI has never executed.** The owner pushed `phase-1b-2-4-auth-security-closure`; GitHub created run
  42736981219 for `5489b70` but did not start the job: "The job was not started because your account is locked due to
  a billing issue." Everything in §5 was run locally only.
- Not run: Unichain fork tests, testnet deployment, an independent review.

## 7. Recommendation for Phase 1B-3

Proceed with the cumulative-pricing plan (`PHASE1B3_PLAN.md`) after review of this change, with two adjustments to its
gates: the vault margin is now 2,527 bytes, and the plan's "vault runtime hash unchanged" gate should use the new
vault hash recorded above. The plan still needs no vault code. Before mainnet, independent of 1B-3: resolve the GitHub
billing lock so the workflow runs once on the pushed commits, and write the X-2 verification script that automates
`MODULE_INSTALLATION_CHECKLIST.md` §2.
