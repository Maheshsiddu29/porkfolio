# Porkfolio — Phase 1B-2.4 Report: Authorization Security Closure

**Status: DONE, waiting for review.** Branch `phase-1b-2-4-auth-security-closure`, created from
`phase-1b-2-3-curator-authorization` at `ebcc929` (clean worktree, remote `origin` unchanged, compiler settings as in
1B-2.3). Cumulative pricing and epoch commitments were not started. Labels: SOURCE (read from the code), OBSERVED
(measured or asserted by a test; the command is given), ESTIMATE.

| Commit | Content |
|---|---|
| `2b56927` | `feat(vault)`: `setAuthModule` reads `vault()` from the candidate (`InvalidAuthModule`); re-installing the installed module reverts; three lifecycle tests updated |
| `0b669bc` | `feat(auth)`: time rules for signed instructions (`MAX_VALIDITY_WINDOW` = 1 day, validAfter ≤ deadline < expiry), deadline < expiry on the direct path; four tests adjusted |
| `e251f80` | `test(auth)`: `ModuleInstallation.t.sol`, `ActivationSafety.t.sol`, invariant actions and INV-T1/INV-M9, two production-artifact tests, `ModuleCandidate` |
| `fd43e82` | `ci`: size gate in `security.sh` and `test_productionSizesWithinLimits`; the workflow runs the script |
| `a912c10` | `test(auth)`: two tests that kill the install-check mutants that survived (§7) |
| this commit | this report; `AUTH_SECURITY_RELEASE_NOTES.md`; `PHASE1B3_PLAN.md`; `CURATOR_SECURITY_MODEL.md`, `MAINNET_READINESS.md` |

## 1. Starting point (OBSERVED)

`git status` clean on `phase-1b-2-3-curator-authorization`; `HEAD` = `ebcc929`; `main` is an ancestor; `origin` =
`https://github.com/Maheshsiddu29/porkfolio.git` (fetch and push), not changed. `foundry.toml`: solc 0.8.26, cancun,
via-IR, `bytecode_hash = "none"`, default 44,444,444 runs, the vault restricted to 2,000 runs (the `ci` profile
inherits the restriction: `FOUNDRY_PROFILE=ci forge config --json`). Foundry 1.7.1 (`4072e48`), Slither 0.11.6. No
mutation tool is installed (gambit and vertigo absent); mutation checks are scripted as in 1B-2.3. The baseline
benchmark at `ebcc929` reproduced the 1B-2.3 report exactly (vault 22,433 B, all gas rows equal).

## 2. Contract-size gate (measured before accepting the vault change)

Each variant is an exact, asserted source replacement in `setAuthModule`, built at the vault's production setting
(`forge build src --sizes`; script outside the repository; source restored after each build).

| Variant | Runtime (B) | Margin (B) | Δ |
|---|---|---|---|
| `ebcc929` | 22,433 | 2,143 | — |
| retire the current module before the retired check (re-install refused) | 22,433 | 2,143 | 0 |
| install check, high-level `staticcall` + `abi.decode` | 22,685 | **1,891** ✗ | +252 |
| install check, short assembly `staticcall`, Solidity custom error | 22,524 | 2,052 | +91 |
| same, reusing `NotAuthModule` instead of a new error | 22,524 | 2,052 | +91 |
| same, `returndatasize() == 32` instead of `> 31` | 22,524 | 2,052 | +91 |
| same, revert also written in assembly | 22,516 | 2,060 | +83 |
| **built: reorder + assembly check + `InvalidAuthModule`** | **22,524** | **2,052** | **+91** |

- The built variant keeps the target (≥ 2,048) with 4 bytes to spare. A new error costs nothing over reusing one, so
  the precise error was kept. The all-assembly variant saves 8 more bytes at a readability cost; not taken.
- No vault check was removed; the optimizer setting is unchanged; comments do not change bytecode
  (`bytecode_hash = "none"`).
- **Consequence for the next phase:** the vault has 4 bytes above the project margin. Phase 1B-3 must not add vault
  code (`PHASE1B3_PLAN.md` §0).

## 3. Module installation safety

`setAuthModule(m)`, `m ≠ 0` (SOURCE): one `staticcall(gas(), m, "vault()")` writing at most 32 bytes; accepted only if
the call succeeded, returned at least 32 bytes, and the first word equals `address(this)` exactly. Otherwise
`InvalidAuthModule(m)`. Then the current module (if any) is retired, then the retired check runs, so `m == authModule`
reverts `AuthModuleRetired`.

| Case | Result | Evidence |
|---|---|---|
| address without code | refused (the call succeeds with no data) | `test_MI_refusesCandidatesThatDoNotReportThisVault` |
| contract without `vault()` (wallet, vault itself, PoolManager, lens) | refused | same |
| production module built for another vault | refused | same; `test_ML_moduleForAnotherVaultRefused`; `test_PA_auth_moduleInstallCheck` |
| getter reverts; returns nothing; 31 bytes; zero; this address with dirty upper bits | refused | same; fuzz `testFuzz_MI_onlyThisVaultsAddressIsAccepted` |
| reverts with exactly this address as revert data; 31-byte answer whose leftover 32nd byte completes the address | refused | `test_MI_failedOrShortAnswerCannotPassAsTheVault` (added after mutation, §7) |
| getter burns gas | owner's call fails with `InvalidAuthModule` (1/64 of the gas is left to revert) | `test_MI_gasBurningCandidateOnlyCostsTheOwner` |
| retired module (still reports this vault) | `AuthModuleRetired` | `test_MI_retiredModulePassesCheckButIsRefused` |
| the installed module again | `AuthModuleRetired`, no event, stays installed | `test_MI_repeatedInstallAndIdempotentDisable`, `test_ML_retiredModuleNeverReinstalled` |
| disable twice, disable with none installed, install while paused | succeed | `test_MI_repeatedInstallAndIdempotentDisable` |
| **accepted:** a malicious module, a contract that is not a module, an answer with extra data, **either hook** | installed | `test_MI_rightAnswerIsNotProofOfAModule`, `test_PA_auth_moduleInstallCheck` |

**Finding.** Both hooks expose `vault()` returning this vault (`BaseCompatibleHook.vault`, SOURCE), so a hook address
passes the check. Installed by mistake, a hook creates nothing; new allocations stop until a real module is installed,
and the hook's consumer role is unaffected when it is retired as a module (tested). A module-specific selector would
reject hooks at the same vault size (OBSERVED: with `authorizationVault()` = `0x137ab7bc` in place of `vault()` the
vault is still 22,524 B; source restored and checked against `HEAD`), but it adds a getter to the module's interface;
not done without approval (§10).

**Not a substitute for review.** The candidate answers its own question, so the check catches deployment mistakes,
not malice. What a malicious installed module can do is unchanged and bounded by `reserveFor`
(`test_ML_compromisedModuleBoundedByVault`).

**Call graph.** The vault now calls a module exactly once, read-only, at installation; never on swaps, LP paths,
cancellation, release or retirement (`test_ML_vaultCallsModuleOnlyAtInstall`, renamed from
`test_ML_vaultNeverCallsModule`).

## 4. Signature validity policy

Implemented in `CuratorAuthorization` without touching the EIP-712 type, domain or digest
(`test_CA_digestFixedVector` and the independent-encoder fuzz still pass unchanged).

| Rule | Where | Error |
|---|---|---|
| validAfter ≤ deadline | signed | `InvalidValidityWindow(validAfter, deadline)` |
| deadline − validAfter ≤ `MAX_VALIDITY_WINDOW` = 86,400 s | signed | `ValidityWindowTooLong(validAfter, deadline)` |
| deadline < expiry | signed and direct | `ExpiryNotAfterDeadline(expiry, deadline)` |
| validAfter ≤ now ≤ deadline | signed (unchanged) | `AuthorizationNotYetValid`, `AuthorizationExpired` |
| expiry ≤ now + 30 days | vault (unchanged) | `HorizonExceeded` |

- The first three run before the clock and before the signature, so a malformed instruction gets its own error at any
  time and never runs wallet code (`test_ST_inconsistentTimesRefusedAtAnyTime`, `test_ST_timeChecksRunBeforeWalletCode`).
- Boundaries (`test_ST_windowBoundaries`): a one-day window activates at both ends; one second longer is refused at any
  time; a zero-length window activates in its one second; `expiry = deadline + 1` activated at the deadline gives an
  allocation that is live for exactly one second, then the swap is refused (`AllocationExpired`).
- `testFuzz_ST_timeRulesMatchReference` checks module and vault together against the rule list above, over activation
  times up to 40 days below `type(uint64).max` (1,000 runs default, 10,000 in CI).
- The direct path applies `deadline < expiry` too, so `testFuzz_CA_directAndSignedEquivalent` still holds unchanged
  (its lifetimes include values below the one-hour deadline).
- A `deadline` of `type(uint64).max` can never activate (no expiry can be later).

**Behaviour changes for callers.** Instructions with windows longer than a day, or with `expiry ≤ deadline`, are now
refused. Four existing tests built such requests and were adjusted (commit `0b669bc`):
`test_CA_validityWindowAndExpiry` (three-day window → one day), `test_FL_closesNeverRefundFlow`,
`test_FL_nearUint64Timestamps_failClosed` (deadline moved below expiry), `test_horizonAndPastExpiry` (the past-expiry
case now gets the module's error). The vault's own `InvalidExpiry` check is now reachable only by a module that skips
the rule; it is covered through `MaliciousAuthModule` in `test_ML_compromisedModuleBoundedByVault`.

**What cannot be solved without an issuance-time commitment.** All three times are chosen by the signer, and the
module cannot know when a message was signed. A curator can sign today for a window that opens in a year; it activates
then (`test_ST_futureDatedSignature`, which also shows the three ways to cancel it first: nonce invalidation,
`bumpGeneration`, module retirement). Bounding signature age needs a signed `issuedAt` and a new type version; even
then, a compromised key can sign any `issuedAt`. Proposed, not implemented (§10).

## 5. Regression tests added

| File | Tests | What they establish |
|---|---|---|
| `test/security/ModuleInstallation.t.sol` | 8 | §3 table; replay of instructions signed for retired modules on every path (used nonce, unused nonce, ERC-1271, direct, new module, third module after a guardian disable); nonce spaces are per module |
| `test/security/ActivationSafety.t.sol` | 9 | §4; ERC-1271 failures (four modes, approval for another instruction, approval under another module's domain) leave no event and no state change; a refusal at the vault's **last** check (vault-scope exposure cap) rolls back everything on the EOA, ERC-1271 and direct paths, and the same instructions then take consecutive ids |
| `test/bench/ProductionArtifactSecurity.t.sol` | +2 (20) | install check and time rules against artifact-deployed contracts, ABI only |
| `test/invariant/VaultInvariants.t.sol` | +2 invariants | INV-T1: every successful signed activation met every time rule (one in four signed activations draws its time fields); INV-M9: the installed module reports this vault and no invalid candidate was ever accepted (new action offering another vault's module, no code, the vault, the PoolManager, the installed module) |
| `test/unit/ProductionBuilds.t.sol` | +1 | sizes of the deployed production code (§8) |

Direct and signed equivalence tests are preserved unchanged. Every new test except the `ModuleCandidate`,
`MaliciousAuthModule` and `Mock1271Wallet` helpers runs on the production artifacts (`VaultTestBase` deploys the
vault, hooks, lens, module and PoolManager from their artifact files; `ProductionBuilds.t.sol` checks them).

## 6. Gas and size (OBSERVED, `test/bench/run.sh`, production artifacts, `--isolate`)

| Path | `ebcc929` | Now | Δ |
|---|---|---|---|
| Signed activation, EOA | 315,662 | 316,226 | +564 |
| Signed activation, ERC-1271 | 319,074 | 319,638 | +564 |
| Direct activation, first in vault / steady state | 334,606 / 295,919 | 334,746 / 296,059 | +140 / +140 |
| `setAuthModule` replace (owner) | 59,521 | 62,594 | +3,073 (cold `staticcall` to the candidate) |
| `setAuthModule` disable (guardian) | 54,141 | 54,169 | +28 |
| Deploy vault / deploy module (CREATE) | 5,002,784 / 1,568,176 | 5,022,118 / 1,674,576 | +19,334 / +106,400 |
| Every swap, deposit, redeem, queue, claim, freeze, cancel, release, risk-limit row | — | — | **0** (identical) |

| Contract | Runtime (B) | Init (B) | EIP-170 margin (B) | Masked runtime keccak256 |
|---|---|---|---|---|
| `SharedCommitmentVault` (2,000 runs) | 22,524 (+91) | 23,133 | **2,052** | `0x21be50c0…f8878d98` (changed) |
| `CuratorAuthorization` | 7,310 (+498) | 8,488 | 17,266 | `0xa6e4e3ea…7769ba2a` (changed) |
| `HookA_DynamicFee` | 7,174 | 8,011 | 17,402 | `0xa917ca88…2eaf29a` (unchanged) |
| `HookB_BoundedImpact` | 6,884 | 7,721 | 17,692 | `0xeca951d1…8b8fc5` (unchanged) |
| `VaultLens` | 6,972 | 6,998 | 17,604 | unchanged |
| `PoolManager` (pinned) | 24,009 | 24,194 | — | `0xa1d857eb…bebb48` (unchanged) |

ESTIMATE of the +564 on signed activations: three comparisons and a subtraction on calldata fields, and the
`MAX_VALIDITY_WINDOW` constant; +140 on the direct path: one comparison and the internal call.

## 7. Validation

All commands at the final implementation commit unless stated; Foundry 1.7.1.

| Command | Result |
|---|---|
| `forge fmt --check` | clean |
| `test/bench/run.sh` | exit 0; settings ok; vault margin 2,052; §6 |
| `test/bench/security.sh` (`FOUNDRY_PROFILE=ci`, 10,000 fuzz runs; forced rebuild; size gate) | exit 0 at `a912c10`: size gate ok (vault margin 2,052); ProductionBuilds 3/3; ProductionArtifactSecurity 20/20; full suite **398/398** in 31 suites |
| `forge test` (default profile, 1,000 fuzz runs) | **398/398** at `a912c10` (376 at 1B-2.3: +8 `ModuleInstallation`, +9 `ActivationSafety`, +2 production-artifact, +2 invariants, +1 `ProductionBuilds`) |
| `FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-contract VaultInvariantsTest -vv` (at `fd43e82`; `a912c10` changes no invariant code) | 32/32 (28 invariants × 32,768 calls, 0 reverts; 4 progress tests) |
| `slither . --filter-paths "lib/\|test/" --exclude-dependencies` | 32 results (30 at 1B-2.3); triage below |
| Mutation script (§7.1) | 14/14 killed (two after adding tests; §7.1) |

Final-run counters of the deep campaign (only the last run is printed): 5 invalid module candidates refused, 3 retired
reinstalls refused; 2 signed activations with drawn times, both refused; 9 signed activations refused, none succeeded
in that run. Successful activations with drawn time fields are asserted by `test_handler_authProgress`, not by these
counters.

**Slither.** The two new results are intended: `assembly` in `setAuthModule` (the 91-byte `staticcall`, §2) and
`naming-convention` for `MAX_VALIDITY_WINDOW()` (a constant getter, like the existing `FLOW_WINDOW()`). The existing
`timestamp` entry for `activate` covers the same two clock comparisons as before; the new ordering checks compare
calldata fields only.

### 7.1 Mutation checks

Scratch copy of the tree at `fd43e82` (lib symlinked), one asserted replacement per mutant, `forge test --fail-fast`
on the six authorization-related security suites (120 tests, all passing unmutated). Script kept outside the
repository.

| ID | Mutation | Result (first failing test) |
|---|---|---|
| V10 | install check removed | killed: `test_ML_vaultCallsModuleOnlyAtInstall` |
| V11 | answer length not checked | **survived the committed suite**; killed by the test added in `a912c10`: `test_MI_failedOrShortAnswerCannotPassAsTheVault` |
| V12 | answer not compared with this vault | killed: `test_MI_refusesCandidatesThatDoNotReportThisVault` |
| V13 | call success ignored (revert data read as the answer) | **survived the committed suite**; killed by `test_MI_failedOrShortAnswerCannotPassAsTheVault` |
| V14 | old order: re-installing the installed module allowed | killed: `test_ML_retiredModuleNeverReinstalled` |
| A17 | validAfter > deadline not checked | killed only by the exact error: the subtraction then reverts with a Panic (0x11) instead, so the instruction is still refused; `test_ST_inconsistentTimesRefusedAtAnyTime` |
| A18 | window length not bounded | killed: `test_ST_timeChecksRunBeforeWalletCode` |
| A19 | window bound off by one (`>=`) | killed: `test_ST_windowBoundaries` |
| A20 | signed path: expiry rule removed | killed: `test_ST_inconsistentTimesRefusedAtAnyTime` |
| A21 | expiry equal to deadline allowed | killed: `test_ST_inconsistentTimesRefusedAtAnyTime` |
| A22 | direct path: expiry rule removed | killed: `test_horizonAndPastExpiry` |
| A23 | window bound doubled | killed: `test_ST_maxWindowIsOneDay` |
| A24 | wallet called before the time checks | killed: `test_CA_everySignedFieldIsBound` |

**14 of 14 killed**, two of them only after the tests in `a912c10` (re-run of V11 and V13 with those tests: both
killed). Why they survived first: a failed `staticcall` still copies its revert data into the output buffer, and a
short answer leaves the last byte of the selector in the word that is read; each is harmless only while the
corresponding condition is present. The 1B-2.3 mutants were not re-run; the code they target is unchanged except for
the lines above.

## 8. Independent reproducibility

- `.github/workflows/security.yml` (reviewed): triggers push, pull request, manual; `contents: read`;
  `persist-credentials: false`; no secrets, no RPC, no deployment. Actions pinned by commit SHA; re-checked with
  `git ls-remote`: `actions/checkout` v4.2.2 = `11bd7190…`, `foundry-rs/foundry-toolchain` v1.9.2 = `dba66c27…`;
  Foundry `v1.7.1` = `4072e487…`. The YAML parses (PyYAML).
- **Gap found and fixed.** The 2,048-byte vault gate lived only as inline shell in the workflow, so running the
  scripts locally did not reproduce it, and `run.sh` only prints `BELOW_TARGET`. It is now in `security.sh` (vault
  margin ≥ 2,048, EIP-170 for every production contract, EIP-3860 for init code; the gate was checked to fail with a
  2,100-byte requirement) and in `test_productionSizesWithinLimits`. The workflow runs `run.sh` and then `security.sh`,
  so the same two commands reproduce the job.
- `security.sh` runs: forced rebuild, size gate, `ProductionBuilds.t.sol`, `ProductionArtifactSecurity.t.sol`, the full
  suite, under the CI fuzz profile. Measured locally: 3 min 40 s.
- **The workflow has not run on GitHub.** Nothing has been pushed. Not verified until the owner pushes: that GitHub
  resolves the pinned actions, the recursive submodule checkout, `jq` on the runner image, and the duration under the
  90-minute timeout.

## 9. Residual risks and tests not run

- The install check is not a review (§3); a hook passes it.
- Signature age is unbounded (§4).
- The vault has 4 bytes above the 2,048-byte target; any further vault code needs a refactor first.
- Owner trust boundary, permanent retirement, nonce and generation exhaustion, ERC-1271 relayer gas and the fixed
  one-day flow window: `AUTH_SECURITY_RELEASE_NOTES.md` §2–§7.
- Not run: the workflow on GitHub; Unichain fork tests; testnet; an independent review. No audit or formal
  verification is claimed.

## 10. Next actions requiring approval

1. Accept the behaviour changes: install check, refused re-install, the one-day window and `deadline < expiry`
   (including on the direct path), and the value of `MAX_VALIDITY_WINDOW`.
2. Decide whether the install check should call a module-specific selector instead of `vault()`, so that hooks are
   refused (same vault size; adds one getter to the module).
3. Decide whether to add a signed `issuedAt` (EIP-712 version "2") to bound signature age.
4. Push the branch (owner) so the workflow runs once on GitHub.
5. Approve `PHASE1B3_PLAN.md` and its decisions D-P1 … D-P6 before cumulative pricing starts.
