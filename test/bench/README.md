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
| `PoolManager` | `new PoolManager`, compiled in this file | default, which matches pinned v4-core's own `foundry.toml` (via-IR, 44,444,444 runs) |
| `PoolSwapTest`, `PoolModifyLiquidityTest` | compiled in this file | default; test routers, included in every swap number |

`run.sh` reads `metadata.settings` from every artifact of these contracts and fails if:

- the vault's artifact does not record the expected runs;
- there is more than one vault artifact;
- a hook or `VaultLens` has no default-profile artifact;
- any of them exceeds the EIP-170 runtime limit of 24,576 bytes.

A margin below the project target of 2,048 bytes is flagged `BELOW_TARGET` but does not fail the run.
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
| `allocate (first in vault)` | the vault's first allocation; every aggregate slot goes from zero to non-zero |
| `allocate (steady state, new curator)` | an allocation after another one exists, by a curator that has not allocated before |
| `release (owner, before expiry)` | owner closes an unconsumed allocation early |
| `freezeCurator` / `unfreezeCurator` | owner freezes a curator holding one live allocation / lifts the freeze |
| `revokeCurator (10 live allocations)` | owner revokes a curator with ten live allocations; the cost does not depend on that number |
| `release (revoked curator, stranger, per allocation)` | permissionless cleanup of one partially consumed allocation of a revoked curator |
| `cancelAllocation (after partial consumption)` | the curator cancels its own partially consumed allocation |
| `swap hookA` / `swap hookB` | router + PoolManager + hook + vault `exchange`; 1,000 tokens exact input |
| `swap native v4` | the same router and amount on a hookless concentrated-liquidity pool; a control that contains no project code |

## Security tests on production builds

`ProductionArtifactSecurity.t.sol` runs security-relevant paths on production bytecode. Unlike the gas benchmark, it
deploys every project contract and the PoolManager from an explicit artifact file, for example
`out/HookA_DynamicFee.sol/HookA_DynamicFee.json`, so the build under test does not depend on the profile the test file
is compiled under. `test_PA_deployedCodeIsProductionArtifacts` checks each deployed code length against its production
artifact and against the 2,000-run build of the same contract. Reading `out/` needs the read-only `fs_permissions`
entry in `foundry.toml`.

| Test | What runs on production builds |
|---|---|
| `test_PA_hookA_hookB_settlementConservation` | HookA and HookB swaps in both directions; trader, PoolManager and vault balances move by exactly the swap amounts; all PoolManager currency deltas are zero afterwards |
| `test_PA_frozenCurator_executionRejected` | a frozen curator's allocations are rejected on both hooks; unfreeze restores them |
| `test_PA_revokedCurator_executionRejected_thenCleanup` | a revoked curator's allocations are rejected; a stranger releases each one for exactly its remainder; re-registration fails |
| `test_PA_partialConsumptionThenCancellation` | cancel after a partial HookB fill; exact remainder; no asset moves; double cancel and later swaps fail |
| `test_PA_maliciousHookAndTokenReentrancy` | a registered hook cancels between two fills (swap reverts atomically) and redeems mid-swap (`AlreadyUnlocked`); a pair-token callback cannot re-enter the vault during a deposit (`ReentrantCall`) |
| `test_PA_lpWithdrawalDuringRestrictedTrading` | LP exits while paused, halted, frozen and then revoked: queueing, permissionless cleanup, finalization, claim, instant exit |

These tests run in the ordinary `forge test` suite; `run.sh` runs only the gas benchmark.

Gas is the `gasleft()` difference around one external call made from the test contract, so it includes the call
overhead of that call but not the 21,000 base cost of a transaction. Compare numbers only between runs made with the
same Foundry version.
