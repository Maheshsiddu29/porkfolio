# Production-artifact benchmark

Development-only measurements of contract size and gas. Nothing here is deployed. The numbers are for comparing
two builds of this repository under the same conditions, not for predicting mainnet fees.

## Run

```sh
test/bench/run.sh                 # full report: config, artifacts, sizes, init-code hashes, gas
test/bench/run.sh > bench.txt     # keep a copy (do not commit it)
```

Requirements: Foundry (the version in use is printed at the top of the report), `jq`, and `cast`. The script
rebuilds with `forge build --force` and then runs

```sh
forge test --match-path test/bench/ProductionArtifactGas.t.sol --isolate -vv
```

`--isolate` runs each external call as its own transaction, so storage starts cold, as it would on-chain. Without it the
numbers come out lower and cannot be compared with earlier runs.

## Why a separate harness

The vault can be compiled with its own optimizer setting through `compilation_restrictions` in `foundry.toml`. solc
compiles a file together with everything it imports, so every test file that imports `src/SharedCommitmentVault.sol`
is compiled under the vault's setting, including the PoolManager, the hooks and the routers it also imports. Inside
such a file, `deployCode("HookA_DynamicFee.sol:HookA_DynamicFee")` also returns the hook built with the vault's
setting. The functional tests still test the right behaviour, because optimizer settings do not change semantics. Their
gas numbers, however, include a PoolManager and hooks that are not the production builds.

`ProductionArtifactGas.t.sol` imports only interfaces and v4-core, so it compiles under the default profile:

| Contract | Where the bytecode comes from | Optimizer setting it should record |
|---|---|---|
| `SharedCommitmentVault` | `vm.getCode("SharedCommitmentVault.sol:SharedCommitmentVault")`, the only vault artifact | the vault's restriction, or the default if there is none |
| `HookA_DynamicFee`, `HookB_BoundedImpact` | `deployCodeTo` with the default-profile artifact | default (`optimizer_runs` in `foundry.toml`) |
| `VaultLens` | `deployCode("VaultLens.sol:VaultLens")`, default-profile artifact (size and deployment only) | default |
| `CuratorAuthorization` | `deployCode` with the default-profile artifact path (`ProductionArtifacts.authModule()`) | default |
| `PoolManager` | `new PoolManager`, compiled in this file | default, which matches pinned v4-core's own `foundry.toml` (via-IR, 44,444,444 runs) |
| `PoolSwapTest`, `PoolModifyLiquidityTest` | compiled in this file | default; test routers, included in every swap number |

`run.sh` reads `metadata.settings` from every artifact of these contracts and fails if:

- the vault's artifact does not record the expected runs;
- there is more than one vault artifact;
- a hook, `VaultLens` or `CuratorAuthorization` has no default-profile artifact;
- any of them exceeds the EIP-170 runtime limit of 24,576 bytes.

A margin below the project target of 2,048 bytes is flagged `BELOW_TARGET` but does not fail this run; it fails
`security.sh` and `test_productionSizesWithinLimits` (below).
`test_bench_sizes` also asserts that each deployed contract has the same code length as the artifact the report
describes.

## Scenarios

Each test starts from the same fixture as `test/utils/VaultTestBase.sol`:

- two 18-decimal mock tokens;
- 1,000,000 of each seeded into the vault;
- HookA on a 0.30% / 60-tick-spacing pool and HookB on a 0.05% / 10-tick-spacing pool, both priced 1:1;
- vault floors of 1:1 in both directions.

| Label | What is measured |
|---|---|
| `deploy vault (CREATE)` | CREATE of the vault init code with constructor arguments; the transaction would also pay 21,000 plus the logged calldata cost |
| `deploy lens (CREATE)` | CREATE of the `VaultLens` init code, plus the logged calldata cost |
| `initialDeposit` | first deposit into a freshly deployed vault, 1,000 + 1,000 tokens |
| `deposit (new LP)` | 1,000 shares bought by an account with no shares |
| `redeem instant` | 1,000 shares redeemed with enough free inventory |
| `redeem queued` | 1,000 shares fully queued (asset1 fully committed) |
| `processQueue(1)` | finalizing one queued request after the commitment is released |
| `claim` | paying out a finalized request |
| `allocate (first in vault)` | the vault's first allocation, made by the curator through the module's direct path (`activateDirect` -> `reserveFor`); every aggregate slot goes from zero to non-zero |
| `allocate (steady state, new curator)` | an allocation after another one exists, by a curator that has not allocated before, through the direct path |
| `activate signed (EOA, ...)` | the same steady-state allocation as an EIP-712 instruction signed by an EOA and submitted by a relayer |
| `activate signed (ERC-1271, ...)` | the same, with a contract-wallet curator that approves the digest from storage |
| `invalidateNonces (new word)` / `(same word)` | a curator invalidates one nonce in an untouched bitmap word, then a second bit in it |
| `setAuthModule (replace)` / `(guardian disable)` | owner installs a new module (the old one retires); guardian sets zero |
| `deploy auth module (CREATE)` | CREATE of the module init code with its vault argument, plus the logged calldata cost |
| `release (owner, before expiry)` | owner closes an unconsumed allocation early |
| `freezeCurator` / `unfreezeCurator` | owner freezes a curator holding one live allocation / lifts the freeze |
| `revokeCurator (10 live allocations)` | owner revokes a curator with ten live allocations; the cost does not depend on that number |
| `release (revoked curator, stranger, per allocation)` | permissionless cleanup of one partially consumed allocation of a revoked curator |
| `cancelAllocation (after partial consumption)` | the curator cancels its own partially consumed allocation |
| `swap hookA` / `swap hookB` | router + PoolManager + hook + vault `exchange`; 1,000 tokens exact input |
| `swap hookA, same flow window` | a second HookA swap in the same flow window: the three flow records are updated without a window change |
| `swap hookA, first in a new flow window` | the first HookA swap after the window rolled over: each record restarts from this swap's output |
| `setRiskLimit (configure new record)` / `(change configured record)` | owner configures a record for the first time (two zero-to-non-zero slots), then changes it |
| `swap native v4` | the same router and amount on a hookless concentrated-liquidity pool; a control that contains no project code |

Since the authorization module was added, the rows `freezeCurator`, `cancelAllocation`, `release (owner, ...)`,
`revokeCurator` and `redeem queued` read about 2,000 gas higher than in the 1B-2.2 run, although the vault calls
themselves did not change (their call frames in `-vvvv` traces differ by 0 to 22 gas). Their setup now allocates through the module, so the vault's
address is no longer warm in the test frame when the measured call starts; a real transaction to the vault always has
it warm. Compare those rows using the call frame in the trace.

Every fixture configures the flow and exposure records of the paths it uses (unconfigured paths fail closed). The
`swap hookA` and `swap hookB` rows are therefore also the first consumption in a window: the records exist but hold
no usage for the current window.

## Security tests on production builds

`ProductionArtifactSecurity.t.sol` runs security-relevant paths on production bytecode. Unlike the gas benchmark, it
deploys every project contract and the PoolManager from an explicit artifact file, for example
`out/HookA_DynamicFee.sol/HookA_DynamicFee.json`, so the build under test does not depend on the profile the test file
is compiled under. `test_PA_deployedCodeIsProductionArtifacts` checks, for each contract, the compiler settings recorded
in its artifact (optimizer runs, via-IR, cancun, no metadata hash) and that the deployed runtime code equals the
artifact's byte for byte once immutable ranges are masked (`test/utils/ProductionArtifacts.sol`); it logs the masked
runtime hashes. Reading `out/` needs the read-only `fs_permissions` entry in `foundry.toml`.

| Test | What runs on production builds |
|---|---|
| `test_PA_hookA_hookB_settlementConservation` | HookA and HookB swaps in both directions; trader, PoolManager and vault balances move by exactly the swap amounts; all PoolManager currency deltas are zero afterwards |
| `test_PA_frozenCurator_executionRejected` | a frozen curator's allocations are rejected on both hooks; unfreeze restores them |
| `test_PA_revokedCurator_executionRejected_thenCleanup` | a revoked curator's allocations are rejected; a stranger releases each one for exactly its remainder; re-registration fails |
| `test_PA_partialConsumptionThenCancellation` | cancel after a partial HookB fill; exact remainder; no asset moves; double cancel and later swaps fail |
| `test_PA_maliciousHookAndTokenReentrancy` | a registered hook cancels between two fills (swap reverts atomically) and redeems mid-swap (`AlreadyUnlocked`); a pair-token callback cannot re-enter the vault during a deposit (`ReentrantCall`) |
| `test_PA_lpWithdrawalDuringRestrictedTrading` | LP exits while paused, halted, frozen and then revoked: queueing, permissionless cleanup, finalization, claim, instant exit |
| `test_PA_flowLimits_allThreeLevels` | the hook, curator and vault flow limits each refuse a HookA/HookB swap, reached through the route that bypasses the level below; the refusal reports exactly cap - used; hooks and curators sum to the vault; a new window restores trading |
| `test_PA_flowLimits_splitTradesAndRollback` | a hook splitting one swap into two exchanges is charged for both; an over-limit split reverts and leaves every record unchanged; usage accumulates across transactions |
| `test_PA_exposureCaps` | at the cap and one unit above; after a deposit and after an instant redemption; an allocation above a tightened cap still executes |
| `test_PA_flowUsageSurvivesLifecycle_lpExitsUnaffected` | freeze, unfreeze, revocation, cleanup and pause leave usage unchanged; instant LP exit while paused with every cap at zero |
| `test_PA_failClosedAndTimestampBoundaries` | a production vault missing only its vault-wide record refuses to reserve; no window reset at 2^32; `FlowEpochOutOfRange` past the 40-bit epoch |
| `test_PA_auth_signedEoaAnd1271_activateAndSwap` | EOA-signed and ERC-1271 instructions submitted by a relayer become exactly the signed allocations and are swapped through HookA and HookB; a wallet that withdraws its approval blocks new instructions but not its existing allocation |
| `test_PA_auth_replayAndBindingMatrix` | wrong signer, 64-byte signature, another chain, another vault, an edited field, outside the time window, spent and invalidated nonces, stale generation, frozen and revoked curators; a reservation the vault rejects spends no nonce |
| `test_PA_auth_disableReplaceAndLpPaths` | guardian disables the module: both activation paths stop, swaps, cancel, release, deposit, redeem, queue and claim work; a new module is installed, the old one cannot return, old signatures fail on the new domain |
| `test_PA_auth_equivalenceCompetitionAndCaps` | signed and direct paths give the same allocation; two instructions competing for the last backing; exposure and flow caps bind signed allocations |
| `test_PA_auth_compromisedModuleBounded` | a malicious module forging `reserveFor` is stopped by the ceiling, registration and floor checks and cannot cancel, consume or configure |
| `test_PA_auth_reentrantWalletIsStatic` | a wallet that tries to cancel its own allocation from `isValidSignature` changes nothing |
| `test_PA_auth_moduleInstallCheck` | the install check, one candidate of each kind: refuses both hooks (their `vault()` names this vault but they have no module identity), the PoolManager, the vault, an EOA, an empty contract, another vault's module, a contract without `authModuleId()`, a wrong identity, malformed, reverting and gas-burning answers to either question, and a fallback with one answer for every selector; each refusal changes nothing; accepts the production module for this vault |
| `test_PA_auth_installLifecycleAndSpoofedModule` | the installed and retired modules cannot be (re)installed; a malicious module that returns both right answers is accepted (the limit of the check), stays bounded by `reserveFor`, and is removed by the guardian's emergency disable; the guardian cannot install; a new module resumes allocations; swaps and LP exits work throughout |
| `test_PA_auth_signatureTimeRules` | one-day window bound at its edge, validAfter after deadline and expiry not after deadline refused (signed and direct), a future-dated instruction activates only in its window, a replay is refused |

## The functional suite also runs on production builds

`test/utils/VaultTestBase.sol`, the fixture of nearly every functional, fuzz and invariant test, deploys the
PoolManager, both hooks, `VaultLens` and `CuratorAuthorization` from their production artifact files
(`ProductionArtifacts`), and the vault has a single (production) artifact. `test/unit/ProductionBuilds.t.sol` checks
all six against their artifacts in the same way as above, and shows the check tells the 2,000-run hook build apart.
The Reentrancy and 6/18-decimal fixtures are checked the same way; modules deployed inside tests (second vaults, the
invariant handler's replacements) also come from the production artifact. What is still compiled into test files:
routers and test-only contracts (`AuthModeHook`, `ScriptedHook`, `MaliciousConsumerHook`, `Mock1271Wallet`,
`MaliciousAuthModule`), which are never deployed by the project.

## Running the production-build security suite (CI)

```sh
test/bench/security.sh            # forge build --force; size gate; ProductionBuilds; ProductionArtifactSecurity; full suite
FOUNDRY_PROFILE=default test/bench/security.sh   # same with 1,000 fuzz runs instead of 10,000
```

The size gate fails the script if the vault's runtime margin under EIP-170 is below 2,048 bytes, if another production
contract exceeds EIP-170, or if any init code exceeds EIP-3860 (49,152 bytes). `test_productionSizesWithinLimits` in
`ProductionBuilds.t.sol` asserts the runtime limits again on the deployed fixture, so a plain `forge test` also fails.

`.github/workflows/security.yml` runs `run.sh` and then this script on pushes and pull requests (see that file for
what it does and does not do), so running both locally reproduces the CI job. `run.sh` alone runs the size report and
the gas benchmark.

Gas is the `gasleft()` difference around one external call made from the test contract, so it includes the call
overhead of that call but not the 21,000 base cost of a transaction. Compare numbers only between runs made with the
same Foundry version.
