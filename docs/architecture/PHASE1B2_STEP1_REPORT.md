# Porkfolio — Phase 1B-2 Step 1 Report: Compiler Profile and Contract-Size Refactor

**Status: DONE, waiting for review.** Branch `phase-1b-2-step1`, created from `fix/pre-1b-2-security-cleanup` at
`4a2ee07`. This step changes no trust boundary. It adds no curator status, signatures, nonces or flow limits. Labels:
OBSERVED (measured here; the command is given), SOURCE (read from the code), ESTIMATE.

| Commit | Content |
|---|---|
| `2b82851` | `test/bench/`: production-artifact size and gas benchmark, committed before any change so both sides are measured the same way |
| `ea370dd` | `foundry.toml`: the vault is compiled with `optimizer_runs = 2,000` |
| `b62a28f` | `src/VaultLens.sol`, `src/interfaces/IVaultState.sol`: eight views move out of the vault |
| `a85ae4d` | lens deployment benchmark; lens names in `SHARE_ACCOUNTING.md` |
| this commit | this report; updates to `MODULAR_RISK_ENGINE.md`, `PHASE1B2_IMPLEMENTATION_PLAN.md`, `MAINNET_READINESS.md`, `README.md` |

## 1. Final optimizer configuration

```toml
[profile.default]
solc_version = "0.8.26"
evm_version = "cancun"
via_ir = true
optimizer = true
optimizer_runs = 44444444
bytecode_hash = "none"
additional_compiler_profiles = [{ name = "vault", optimizer_runs = 2000 }]
compilation_restrictions = [{ paths = "src/SharedCommitmentVault.sol", optimizer_runs = 2000 }]
```

The `vault` profile inherits every other setting from the default profile. The pinned compiler, the EVM version and
the Uniswap dependencies are unchanged. `FOUNDRY_PROFILE=ci` inherits the same restriction (checked with
`forge config --json`).

| Contract | Production setting | Why |
|---|---|---|
| `SharedCommitmentVault` | 2,000 runs | D19: size headroom for the 1B-2 risk features |
| `HookA_DynamicFee`, `HookB_BoundedImpact` | 44,444,444 runs (unchanged) | they are on every swap and are far from the size limit |
| `VaultLens` | 44,444,444 runs (default) | not on any transaction path. A lower setting would save deployment gas only; not worth a second restriction |
| `CuratorAuthorization` | not built yet | to be chosen and measured in step 1B-2.3 |

## 2. Evidence that each contract uses its intended profile

### 2.1 Artifact metadata (OBSERVED, `test/bench/run.sh` at `b62a28f`)

`run.sh` reads `metadata.settings` from every artifact. It fails if:

- the vault does not record the expected runs;
- more than one vault artifact exists;
- a hook or the lens lacks a default-profile build;
- anything exceeds EIP-170.

| Artifact | runs | viaIR | evm | bytecodeHash | Role |
|---|---|---|---|---|---|
| `SharedCommitmentVault.json` (the only vault artifact) | 2,000 | true | cancun | none | production |
| `HookA_DynamicFee.json` | 44,444,444 | true | cancun | none | production |
| `HookA_DynamicFee.vault.json` | 2,000 | true | cancun | none | test-only build |
| `HookB_BoundedImpact.json` | 44,444,444 | true | cancun | none | production |
| `HookB_BoundedImpact.vault.json` | 2,000 | true | cancun | none | test-only build |
| `VaultLens.json` | 44,444,444 | true | cancun | none | production |
| `VaultLens.vault.json` | 2,000 | true | cancun | none | test-only build |
| `PoolManager.default.json` | 44,444,444 | true | cancun | none | used by `test/bench` (v4-core's own settings) |
| `PoolManager.vault.json` | 2,000 | true | cancun | none | used by the functional suite |

### 2.2 What test files actually deploy

**Investigated, not assumed.** solc compiles a file together with everything it imports, so Foundry compiles every
test file that imports `src/SharedCommitmentVault.sol`, and its whole import graph, under the `vault` profile. A probe
test (deleted after use) showed what that means:

- **The vault.** There is exactly one vault artifact. `type(SharedCommitmentVault).creationCode` in a functional test
  equals `vm.getCode("SharedCommitmentVault.sol:SharedCommitmentVault")`. **The functional suite tests the production
  vault bytecode.**
- **The hooks.** `deployCodeTo("HookA_DynamicFee.sol:HookA_DynamicFee")` inside such a file resolves to the artifact
  of the caller's profile. The deployed hook had 5,601 B of code, against 7,174 B for the production build. Foundry has
  no identifier syntax that selects a profile: `…:default`, `…:vault` and `…:0.8.26:default` were tried. **The
  functional suite runs the hooks and the PoolManager as 2,000-run builds.** Behaviour is the same, because optimizer
  settings do not change semantics, but gas measured there is not production gas.
- **The mitigation.** `test/bench/ProductionArtifactGas.t.sol` imports only interfaces and v4-core, so it compiles
  under the default profile. It deploys the single vault artifact, the default-profile hooks and lens, and a
  `new PoolManager` built with v4-core's settings. `test_bench_sizes` asserts that each deployed code length equals
  its artifact's. Every swap and LP path in the benchmark runs on production bytecode, so it doubles as a smoke test
  of the production builds.
- **Still open.** The full functional suite does not run against production hook and PoolManager builds. This is
  tracked as `MAINNET_READINESS.md` D-6.

`test/gas/*` now states in its header that its numbers are under the vault profile and that production gas comes
from `test/bench/`.

## 3. Views moved and the remaining vault interface

### 3.1 Selection rule

A view moved to the lens only if all of these hold:

- the vault never needs it as an external function;
- its value can be rebuilt from public, stored state;
- it takes no caller-supplied balances;
- moving it puts no external call on a swap, deposit, allocation or withdrawal.

Every formula the vault enforces stays inside the vault as an internal function. The lens holds a second copy for
readers only.

| Removed vault function (selector) | `VaultLens` replacement (selector) | Computed from | Vault's own copy |
|---|---|---|---|
| `netAssets(address)` `91de1483` | `netAssets(address,address)` `cd5baf38` | `backing − claimableAssets` | `_netAssets` |
| `freeInventory(address)` `d07b2b2d` | `freeInventory(address,address)` `795dd390` | `backing − claimableAssets − reserved` | inside `_deliverableShares` |
| `pendingDemand(address)` `4dcbf094` | `pendingDemand(address,address)` `c1c3c998` | `⌈pendingShares · N / totalShares⌉` | `_pendingDemand` |
| `deliverableShares()` `5219fd00` | `deliverableShares(address)` `04a92835` | min over assets of `⌊F·S/N⌋` | `_deliverableShares` |
| `previewDeposit(uint256)` `ef8b30f7` | `previewDeposit(address,uint256)` `b8f82b26` | `⌈shares · N / S⌉` | `_depositAmounts` |
| `previewRedeem(uint256)` `4cdad506` | `previewRedeem(address,uint256)` `cbe52ae3` | `⌊shares · N / S⌋` | `_entitlement` |
| `effectiveFloorX96(uint256)` `4b929177` | `effectiveFloorX96(address,uint256)` `6e648c5d` | `max(sellPolicy floor, allocation floor)`, same reverts | `_effectiveFloor` |
| `requestStatus(uint256)` `1a313202` | `requestStatus(address,uint256)` `98e4136b` | `getRequest` fields | none needed |

**Kept on the vault, although they could have moved:**

- **`admissibleCapacity`.** It is the exact admission rule `allocate` enforces, including the overflow-safe
  subtraction. Keeping it external lets anyone read the vault's own result, not a copy. Cost: 67 B.
- **`getRequest`.** Request records are internal storage, and this is the only way to read them. It is in
  `IVaultState`.
- **`getAllocation`.** The hooks call it.

### 3.2 Lens trust model (SOURCE)

The lens has:

- no storage (its storage layout is empty);
- no constructor and no owner;
- no ERC-6909 claims and no approvals.

Each function takes the vault as an argument and calls only the getters in `IVaultState`, which return stored values.
The vault never calls the lens. `test_lens_readsOnlyAndHasNoStorage` checks that a call to every lens function
touches no lens storage and writes no vault storage.

A wrong lens result can mislead a caller, for example into a slippage bound that reverts their own transaction. It
cannot change what the vault accepts or pays.

`IVaultState` declares the getters the lens reads. The vault inherits it, so solc checks that each getter exists with
those exact types.

### 3.3 ABI and storage comparison (OBSERVED, `forge inspect`, `4a2ee07` vs `b62a28f`)

| Item | Result |
|---|---|
| Vault function selectors | 8 removed (table above), 0 added, 0 changed |
| Events and errors | identical |
| Storage layout | identical: 22 variables, same slots, offsets and types (`owner`/`paused` share slot 0) |
| Hook ABI and bytecode | identical (hooks use only `exchange` and `getAllocation`) |
| Affected clients | the vault's own tests (115 call sites, switched to the lens with the same assertions). `frontend/`, `sdk/`, `script/` and `simulations/` contain only placeholder READMEs, so there is no off-chain client to update |

## 4. Bytecode size and headroom (OBSERVED, production artifacts)

| Contract | Before (`4a2ee07`) runtime / init | After (`b62a28f`) runtime / init | EIP-170 margin after |
|---|---|---|---|
| `SharedCommitmentVault` | 22,814 / 23,444 | **17,035 / 17,644** | **7,541** |
| `HookA_DynamicFee` | 7,174 / 8,011 | 7,174 / 8,011 | 17,402 |
| `HookB_BoundedImpact` | 6,884 / 7,721 | 6,884 / 7,721 | 17,692 |
| `VaultLens` | — | 5,046 / 5,072 | 19,530 |

- **Where the vault's saving comes from.** 5,022 B come from the optimizer setting (17,792 B at 2,000 runs) and 757 B
  from the lens.
- **Margin target.** Every contract we deploy clears the 2,048 B target. The upstream PoolManager at its own settings
  is 24,009 B; it is Uniswap's deployment, not ours.
- **Per-view savings** at 2,000 runs, removing one view at a time:

  | View | Bytes saved |
  |---|---|
  | `requestStatus` | 195 |
  | `previewDeposit` | 154 |
  | `freeInventory` | 101 |
  | `previewRedeem` | 71 |
  | `effectiveFloorX96` | 69 |
  | `deliverableShares` | 63 |
  | `netAssets` | 46 |
  | `pendingDemand` | 46 |
  | `admissibleCapacity` (kept) | 59 |

## 5. Gas before and after (OBSERVED)

All three columns come from the same harness (`test/bench/run.sh`, `forge test --isolate`). The PoolManager, hooks
and router are production builds in every column; only the vault changes. Gas is the `gasleft()` difference around
one external call.

| Path | Before (`2b82851`) | Vault at 2,000 runs (`ea370dd`) | + lens (`b62a28f`) | Δ total |
|---|---|---|---|---|
| Swap via HookA (router + PM + hook + vault) | 214,382 | 214,831 | 214,456 | +74 |
| Swap via HookB | 214,286 | 214,735 | 214,360 | +74 |
| Native v4 swap (control, no project code) | 150,303 | 150,303 | 150,303 | 0 |
| `allocate`, first in vault | 284,894 | 285,799 | 285,667 | +773 |
| `allocate`, steady state, new curator | 263,307 | 264,212 | 264,080 | +773 |
| `release` by owner before expiry | 38,722 | 38,791 | 38,774 | +52 |
| `initialDeposit` | 236,843 | 237,039 | 236,819 | −24 |
| `deposit`, new LP | 148,577 | 148,830 | 148,520 | −57 |
| `redeem`, instant | 159,820 | 160,085 | 159,865 | +45 |
| `redeem`, fully queued | 145,160 | 145,388 | 145,278 | +118 |
| `processQueue(1)` | 121,394 | 121,612 | 121,458 | +64 |
| `claim` | 135,298 | 135,484 | 135,352 | +54 |
| Deploy vault (CREATE) | 5,080,926 | 4,001,060 | 3,838,048 | −1,242,878 |
| Vault init-code calldata (16/4 gas per byte) | 333,628 | 260,128 | 248,844 | −84,784 |
| Deploy `VaultLens` (CREATE) / calldata | — | — | 1,167,248 / 71,324 | new |

- **The control row is unchanged.** So every difference above comes from the vault.
- **2,000 runs cost +449 per swap and +905 per allocation.** Removing views recovered most of that. The likely cause is
  a shorter selector dispatch in the vault (8 fewer functions). This has not been verified by trace.
- **No regression above 1,000 gas.** The largest is `allocate` (+773, +0.3%).
- **Deployment is about 1.24M gas cheaper** for the vault, and the lens adds 1.17M once. The lens is optional for
  integrators, because every value it returns can be computed off-chain from the same getters.

## 6. CREATE2 and init-code hashes (OBSERVED; keccak256 of creation code without constructor arguments)

| Contract | Before | After | Changed? |
|---|---|---|---|
| `SharedCommitmentVault` | `0x8baaeb977f2d9897f2594fc79216417a6e85e3dfeb5569fc617e8dfb9610f7ba` | `0xa812e7a9ff69966e1e67ca5af00ca46b6256d113029a9fef31c13862b068f32c` | yes (expected) |
| `HookA_DynamicFee` | `0x47abaff39a7c606e10d5c44540262c5b33299781d2347d84928da4296c2713e2` | same | no |
| `HookB_BoundedImpact` | `0xdcdfba66878304afd70049c629cc5517691fd16a5ef3363ac27ed5b3ed974d87` | same | no |
| `VaultLens` | — | `0x1ab8483abfa26aa292ffc88bb4b414416c701fc060258b8a616b46b463e05296` | new |

(At `ea370dd`, the optimizer change alone, the vault's hash was
`0x2b9e69e90ff26ad930932803a211c5a4fe07a2f4a9992fc4af2bb20f110c6c33`.)

- **Hook creation code is unchanged.** A hook's CREATE2 address, however, also depends on its constructor arguments,
  which include the vault address.
- **If the vault is deployed with CREATE2,** its new init-code hash gives it a new address. Each hook then needs its
  permission-bit salt mined again.
- **No deployment script or mined salt exists yet** (`MAINNET_READINESS.md` X-1). Tests place hooks with
  `deployCodeTo`, so nothing in the repository depends on the old hashes.

## 7. Validation (OBSERVED, final commit of this step unless stated)

| Command | Result |
|---|---|
| `forge fmt --check` | clean |
| `forge build --force --sizes` | success; sizes in §4 |
| `forge test` | **210 passed, 0 failed** at the final commit (188 earlier tests + 15 benchmark + 6 lens unit tests + 1 invariant) |
| `FOUNDRY_PROFILE=ci forge test` (10,000 fuzz runs) | 210 passed, 0 failed |
| `FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-contract VaultInvariantsTest` | 15 passed (14 invariants + 1 progress test), 32,768 calls each, 0 reverts |
| `test/bench/run.sh` | exit 0; every production artifact has the expected settings |
| `slither . --filter-paths "lib/\|test/" --exclude-dependencies` | 22 results, against 21 at `4a2ee07`. The one new result is `unimplemented-functions`: Slither says the vault does not implement `IVaultState.backing`, `reserved`, `claimableAssets` and `sellPolicy`. **False positive.** These are public mappings keyed by the user-defined type `Currency`. solc accepts them as implementations (the contract compiles and deploys), and the lens tests call all four through `IVaultState`. The other 21 are unchanged. |

### 7.1 Lens equivalence

- **Against the vault's execution (committed).**
  - `invariant_lensPreviewsMatchExecution` runs on every state the stateful campaign reaches. On a snapshot that is
    rolled back afterwards, it checks that:
    - `deposit` charges exactly `previewDeposit`;
    - an instant `redeem` delivers `min(balance, deliverableShares)` shares worth `previewRedeem`, or reverts as dust
      exactly when the lens model predicts;
    - `processQueue(1)` finalizes `min(pending, deliverableShares)` worth `previewRedeem`.
  - `testFuzz_lensMatchesExecution` (1,000 runs; 10,000 in CI) adds `allocate` at exactly `admissibleCapacity` (which
    succeeds), one unit above it (which reverts with the vault's own `available` figure), and the `N` and `D` terms
    from the lens.
  - `invariant_equationsFromRawSources` compares lens `N`, `F` and `D` against raw ERC-6909 balances and request and
    allocation records.
- **Against the removed view code (one-off, not committed).**
  - In a scratch worktree at `ea370dd`, the vault still had its views. An invariant there compared every old view
    with the lens on the same state, including return data and revert data:
    - previews at 0, 1, 1e18, S/3 + 1, S and 2^128 − 1 shares;
    - `requestStatus` for every request id;
    - `effectiveFloorX96` for every allocation id plus one unknown id.
  - Result at 256 runs × 128 depth: **identical everywhere**. Injecting a rounding change into the lens's
    `previewRedeem` made it fail on the first run.

### 7.2 Mutation checks (manual, scratch worktree at `b62a28f`, full suite per mutant): 14 of 14 killed

| Mutant | Result |
|---|---|
| L1 lens `previewDeposit` rounds down | killed (10 tests) |
| L2 lens `previewRedeem` rounds up | killed (6) |
| L3 lens `deliverableShares` ignores `Q1` | killed (4) |
| L4 lens `pendingDemand` rounds down | killed (6) |
| L5 lens `effectiveFloorX96` takes the minimum | killed (4) |
| L6 lens `requestStatus` reports Claimable before Pending | killed (2) |
| L7 lens `netAssets` ignores `W` | killed (14) |
| L8 lens `freeInventory` ignores `Q` | killed (18) |
| V1 vault admission omits `D` | killed (13) |
| V2 vault `D` rounds down | killed (7) |
| V3 vault deposit price rounds down | killed (4) |
| V4 vault admission sums `Q + R + D` (the old overflow) | killed (7: `AdmissibleCapacity.t.sol` buffer-near-max tests) |
| V5 vault entitlement rounds up | killed (10) |
| V6 vault `_deliverableShares` ignores `Q1` | killed (35) |

The V mutants confirm that the vault's own copies of the moved formulas are still guarded by tests, now that the
external views that used to expose them are gone.

### 7.3 Behaviours re-checked

| Area | Evidence |
|---|---|
| ERC-6909 custody and settlement | `invariant_backingEqualsRealClaims`, `invariant_ghostLedgerConservation`, `invariant_actualBalanceMovementsMatchAccounting`; benchmark swaps on production builds |
| Exact-price enforcement | `PricePolicy.t.sol`, `invariant_everyExchangeMeetsEffectiveFloor` (the handler reads the floor through the lens, and the vault enforces its own copy) |
| Curator and guardian restrictions | `Roles.t.sol`, `invariant_guardianOnlyTightens`; unchanged code |
| LP share accounting | `ShareSecurity`, `MultiLpAccounting`, `invariant_noDilutionByLpOperations` |
| FIFO withdrawal | `QueueGriefing`, `invariant_fifoOrdering`, `invariant_sharesAndQueueConserved` |
| Claimable-asset protection | `invariant_custodyAndSolvency`; `claimableTouched` flag in the handler |
| Overflow-safe `admissibleCapacity` | `AdmissibleCapacity.t.sol`, the handler's `setBuffer` near `type(uint256).max`, mutant V4 |

## 8. Reproducing the measurements

```sh
git checkout <commit>
test/bench/run.sh                    # config, artifact settings, sizes, init-code hashes, gas
forge inspect SharedCommitmentVault methodIdentifiers   # selectors
forge inspect SharedCommitmentVault storageLayout       # storage layout
```

Requirements: Foundry 1.7.1 (the version used here), `jq`, `cast`. Run `run.sh` at `2b82851`, `ea370dd` and
`b62a28f` to reproduce the three gas columns. Scenarios and method are described in `test/bench/README.md`.

## 9. Residual risks and tests not run

- **Functional suite builds.** It runs 2,000-run builds of the hooks and PoolManager (§2.2). Production builds run
  only in the benchmark's paths. Tracked as D-6.
- **Lens drift.** Every formula now has two copies. If a later change edits the vault's formula and not the lens,
  `invariant_lensPreviewsMatchExecution` and `testFuzz_lensMatchesExecution` fail. The vault stays correct either way.
- **ABI break for external readers.** It is real but has no current consumer. Any future SDK or UI must call the lens.
- **Benchmark scope.** Numbers are relative and use v4-core's `PoolSwapTest` router; they are not mainnet fee
  predictions. Unichain L1 data cost is not included (F-2).
- **Foundry dependence.** `run.sh` depends on Foundry's artifact naming and its `forge config --json` output. A
  Foundry upgrade may need the script adjusted; the script fails rather than passing silently if artifacts are
  missing.
- **Not done in this step:** fork tests against the canonical Unichain PoolManager, a trace-level confirmation of the
  dispatch explanation in §5, and a lens-specific optimizer setting.

## 10. Next action requiring approval

Review this step. Step 1B-2.1 (curator status and generation, freeze, revoke, cancel, shared close path, transient
lock) needs explicit approval to start. It changes vault behaviour, but not the module trust boundary, which stays
in 1B-2.3.
