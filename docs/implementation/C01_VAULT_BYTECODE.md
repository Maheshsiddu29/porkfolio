# C01: Vault read-surface reclaim (getters behind `extsload`)

**Status: implementation plan.** Written before any production change. Results, measured numbers and deviations go
into §10 as the steps complete; nothing below is a result until §10 says so.

Basis:
- `docs/architecture/G05_V2_ARCHITECTURE.md` (the ADR), accepted by the owner as the basis for C01. The parts used
  here: §2.3 (the read surface that stays), §8.1 (flag X: −2,220 B, measured on a prototype), §9 limitation 10,
  §10.3 V2-1 and V2-10, §10.5 B-G5-1 and B-G5-2, §11 (C01 row).
- The owner's C01 instruction for this milestone: implement C01 only, on the existing branch, one step at a time,
  plan committed first.
- Size-probe references: `docs/proposals/g05-vault-size-probe.py` (flag X, lines 269–292) and
  `docs/proposals/g05-v2-vault-size-probe.patch` (X combined with A, C, F; only the X part applies to C01). The probe
  is the smallest code that exercises the change; it was measured, never tested for behaviour.

Labels as in the ADR: **MEASURED** (a command in §10 produced it), **ESTIMATE**, **TARGET** (acceptance threshold set
here), **ASSUMPTION**.

## 1. Objective

Reclaim vault runtime bytes for the V2 ledger (C02) and bond entry (C03) **without changing any state transition**.

The vault exposes about 25 public state getters and 4 struct/derived getters (`getAllocation`, `getRequest`,
`getRiskLimit`, `admissibleCapacity`). Each costs dispatch and ABI-encoding bytes. C01 makes those storage variables
`internal`, removes the four view functions, and adds one generic read, `extsload(bytes32 slot)`, the pattern v4's
`PoolManager` uses (`lib/v4-periphery/lib/v4-core/src/Extsload.sol`, imported as `@uniswap/v4-core/src/Extsload.sol`). `VaultLens`, already the stateless read helper, decodes the
storage layout through `extsload` and serves every removed read under the same name and return type, taking the
vault as its first argument.

Starting point (MEASURED in G05 at `5701e9c`; re-measured at the branch tip in step 0): vault runtime 22,440 B,
2,136 B under EIP-170, 88 B above the 2,048 B size policy. Prototype after X: 20,220 B (4,356 B under EIP-170).

## 2. Scope

In scope:
1. `SharedCommitmentVault`: visibility of storage variables from `public` to `internal` except the kept set (§3.2);
   remove `getAllocation`, `getRequest`, `getRiskLimit`, `admissibleCapacity`; add `extsload(bytes32)`; drop
   `IVaultState` from the inheritance list if it no longer matches; NatSpec updated in the same commit.
2. `IVaultState`: reduced to the reads that remain on the vault, plus `extsload`. `ISharedCommitmentVault`: remove
   the `getAllocation` declaration.
3. `VaultLens`: every removed read re-implemented on `extsload` with pinned slot constants; existing derived reads
   (`netAssets`, `pendingDemand`, `deliverableShares`, previews, `effectiveFloorX96`, `inventoryRoom`,
   `requestStatus`, `eligibleBacking`, `flowUsed`, `flowAvailable`, `exposureAvailable`) rewritten on the decoded
   reads with identical formulas and rounding; `admissibleCapacity` moved here with the vault's exact formula.
4. Tests: a storage-layout test (B-G5-2) pinning every slot and packed offset the lens reads; lens parity tests
   against the old getters; every existing test that read a removed getter moved to the lens with its assertions
   unchanged.
5. Scripts (`VerifyDeployment.s.sol`, `Rehearse.s.sol`, `DeploySystem.s.sol`): reads of removed getters moved to the
   lens. No broadcast is run.
6. Documentation: this file (§10 results), `docs/proposals/README.md` row for the probe (status), and the
   statements in existing docs that name a removed vault getter as the way to read state, where a reader would be
   misled.

Out of scope (C02 and later, or never in C01): room-aware admission (A), the expiry ring (C/G), fee entry (F/B),
the TVL cap (T), `BondEscrow`, `CommitmentAuthorizer`, Hook C, any change to a state-changing function, event, error,
modifier, check order, rounding, storage order or storage type, any change to the hooks, the governor, the adapter or
the authorizer source beyond an import of the reduced `IVaultState`, frontend and SDK.

## 3. Contracts involved

### 3.1 Changed

| Contract | Change | Bytecode expected to change |
|---|---|---|
| `src/SharedCommitmentVault.sol` | visibility, removed views, `extsload` | yes (the point of C01) |
| `src/VaultLens.sol` | reads through `extsload`; new decoded getters | yes |
| `src/interfaces/IVaultState.sol` | reduced read interface plus `extsload` | n/a (interface) |
| `src/interfaces/ISharedCommitmentVault.sol` | `getAllocation` removed | n/a (interface) |

### 3.2 Reads that stay on the vault

From ADR §2.3 and a call-site search of `src/` and `script/` at the branch tip:

| Read | Caller that needs it on-chain |
|---|---|
| `coreInputs()` | hooks in shared-core mode (`BaseCompatibleHook`) |
| `getCurator(address)` | `CuratorAuthorization`; future escrow |
| `owner()`, `guardian()`, `pendingShares()` | `VaultGovernor` |
| `pendingOwner()`, `paused()`, `isConsumer(address)`, `authModule()` | governor checks, scripts, module installation |
| `poolManager()`, `asset0()`, `asset1()` (immutables) | hooks, lens, authorizer |
| `MAX_AMOUNT`, `MAX_HORIZON`, `MIN_SHARES`, `INLINE_QUEUE_STEPS`, `FLOW_WINDOW` (constants) | lens, scripts, tests |
| `extsload(bytes32)` (new) | lens; any third-party reader |

### 3.3 Reads that move to the lens

Storage variables: `curatorCeiling`, `curatorReserved`, `backing`, `reserved`, `bufferFloor`, `sellPolicy`,
`claimableAssets`, `nextAllocationId`, `totalShares`, `sharesOf`, `nextRequestId`, `queueHead`, `hookReserved`,
`riskAdapter`, `riskEdgePips`, `maxUncertaintyPips`, `inventoryTargetPerShare`, `inventoryTolerancePips`.
View functions: `getAllocation`, `getRequest`, `getRiskLimit`, `admissibleCapacity`.

The lens keeps each name and return type and takes the vault as the first argument, so a call site changes from
`vault.backing(a)` to `lens.backing(vault, a)` and nothing else.

### 3.4 Not changed (bytecode must be identical before and after)

`HookA_DynamicFee`, `HookB_BoundedImpact`, `CuratorAuthorization`, `VaultGovernor`, `PriceRiskAdapter`. They call
only reads that stay (§3.2); if any of their runtime bytecode changes, stop and explain before committing.

## 4. Storage-layout requirements

The layout becomes part of the read interface (ADR §9 limitation 10). C01 must not move any slot.

Current layout (`forge inspect src/SharedCommitmentVault.sol:SharedCommitmentVault storageLayout` at the branch tip):

| Slot | Offset | Variable | Type |
|---|---|---|---|
| 0 | 0 / 20 | `owner` / `paused` | address / bool |
| 1 | 0 | `pendingOwner` | address |
| 2 | 0 | `guardian` | address |
| 3 | 0 | `isConsumer` | mapping(address ⇒ bool) |
| 4 | 0 | `_curators` | mapping(address ⇒ CuratorRecord) |
| 5 | 0 | `curatorCeiling` | mapping(address ⇒ mapping(Currency ⇒ uint256)) |
| 6 | 0 | `curatorReserved` | mapping(address ⇒ mapping(Currency ⇒ uint256)) |
| 7 | 0 | `backing` | mapping(Currency ⇒ uint256) |
| 8 | 0 | `reserved` | mapping(Currency ⇒ uint256) |
| 9 | 0 | `bufferFloor` | mapping(Currency ⇒ uint256) |
| 10 | 0 | `sellPolicy` | mapping(Currency ⇒ SellPolicy) |
| 11 | 0 | `claimableAssets` | mapping(Currency ⇒ uint256) |
| 12 | 0 | `_allocations` | mapping(uint256 ⇒ Allocation) |
| 13 | 0 | `nextAllocationId` | uint256 |
| 14 | 0 | `totalShares` | uint256 |
| 15 | 0 | `pendingShares` | uint256 |
| 16 | 0 | `sharesOf` | mapping(address ⇒ uint256) |
| 17 | 0 | `_requests` | mapping(uint256 ⇒ WithdrawalRequest) |
| 18 | 0 | `nextRequestId` | uint256 |
| 19 | 0 | `queueHead` | uint256 |
| 20 | 0 | `hookReserved` | mapping(address ⇒ mapping(Currency ⇒ uint256)) |
| 21 | 0 | `_riskLimits` | mapping(bytes32 ⇒ RiskLimit), key `keccak256(abi.encode(scope, account, currency))` |
| 22 | 0 | `authModule` | address |
| 23 | 0 | `_retiredAuthModule` | mapping(address ⇒ bool) |
| 24 | 0 / 20 / 23 | `riskAdapter` / `riskEdgePips` / `maxUncertaintyPips` | address / uint24 / uint24 |
| 25–26 | 0 | `inventoryTargetPerShare` | uint256[2] |
| 27 | 0 / 3 | `inventoryTolerancePips` | uint24[2] (packed) |

Struct packing (slot within the struct / byte offset):
- `Allocation`: 0 `curator`; 1 `consumer` (0), `expiry` uint64 (20), `released` (28); 2 `poolId`; 3 `currencyIn`;
  4 `currencyOut`; 5 `maxOut` uint128 (0), `consumed` uint128 (16); 6 `minInPerOutX96` uint160.
- `WithdrawalRequest`: 0 `lp` (0), `canceled` (20); 1 `receiver`; 2 `sharesRequested` (0), `sharesPending` (16);
  3 `claimable0` (0), `claimable1` (16).
- `RiskLimit`: 0 `configured` (0), `epoch` uint40 (1), `flowCap` uint104 (6), `flowUsed` uint104 (19);
  1 `maxReservedBps` uint16 (0).
- `SellPolicy`: 0 `minInPerOutX96` uint160 (0), `halted` (20).
- `CuratorRecord`: 0 `registered` (0), `restriction` uint8 enum (1), `generation` uint32 (2).

The reentrancy lock lives in transient storage (`_REENTRANCY_LOCK_SLOT`), not in this layout; `extsload` reads
persistent storage only, so it cannot observe the lock.

Requirements:
- **L-1.** `forge inspect … storageLayout` output (slots, offsets, types, order) is identical before and after C01;
  only the visibility of entries changes, and visibility is not part of the layout. Checked by diffing the JSON with
  the AST ids stripped.
- **L-2.** A storage-layout test pins every slot and packed offset in the table above with literal numbers written
  independently of the lens: it drives the vault through real state transitions, reads the raw word with `vm.load`
  at the literal slot (mapping slots derived with `keccak256(abi.encode(key, slot))`), and checks it against the
  value the old getter returned (step 2) or the value the transition must have produced (after step 3).
- **L-3.** The lens reads each value through `vault.extsload`, never through `vm.load` or a getter, so the parity
  tests compare two independent paths.
- **L-4.** `extsload` is `view`, reads any slot, takes no access control, and returns the raw 32-byte word. It
  exposes nothing that is not already public on-chain (any node serves `eth_getStorageAt`); it adds no write path.

## 5. Financial-equivalence tests

C01 claims "no state transition changes". The evidence must show that for every state-changing function the
behaviour is identical, and that every read a caller relied on returns the same value through the lens.

| Id | Test | What it proves |
|---|---|---|
| E-1 | **Full existing suite, assertions unchanged.** Every test that read a removed getter is changed only in the read expression (`vault.x(args)` → `lens.x(vault, args)`); no expected value, revert selector, bound or handler action changes. Checked by a diff filter that shows every changed test line is a read substitution. | Behaviour of all tested paths (deposit, redeem, queue, claim, cancel, reserve, exchange, release, cancel, governance, oracle, invariants) is unchanged |
| E-2 | **Lens parity against the old getters** (step 2, while the getters still exist): fuzzed sequences of deposits, redemptions, queue steps, claims, reservations, swaps through real hooks on the real `PoolManager`, releases and risk-limit configuration; after each step every lens read equals the corresponding vault getter, for both assets, every scope and every allocation and request id touched, plus unused ids (all-zero). | The lens decoding is exact on reachable states, including packed fields at their maximum widths |
| E-3 | **Parity on extreme values**: `vm.store` of all-ones and boundary patterns into each packed slot of a vault, compared lens vs old getter (step 2). | Masks and shifts are correct for every packed field at full width; no field bleeds into its neighbour |
| E-4 | **Persistent differential harness** (kept after step 3): a test-only `SharedCommitmentVault` subclass adding no storage, exposing the internal variables under `old*` names. Parity tests from E-2/E-3 re-run against it after the getters are removed. | Parity stays checked after removal, and any future layout change breaks a test |
| E-5 | **Storage-layout test** (L-2). | B-G5-2 |
| E-6 | **Invariant campaigns** (`test/invariant/*`) at the default profile, unchanged handlers, with their non-vacuity counts compared before and after. | Stateful behaviour and ghost accounting unchanged |
| E-7 | **ABI diff**: the set of state-changing selectors, events and errors is identical; the removed set is exactly §3.3 plus the inherited `IVaultState` entries; the added set is `extsload`. | No hidden interface change |
| E-8 | **`admissibleCapacity` in the lens**: equal to the vault's old value on the E-2 sequences, including `R_a` set to `type(uint256).max` and `D_a > 0`. | The moved derived formula is exact, including the overflow-safe chain |
| E-9 | **`coreInputs` unchanged**: hooks' quotes in shared-core mode are identical; existing `SharedCoreHooks` and `OracleBandHooks` tests pass unchanged. | The on-chain read used for pricing is untouched |

What these tests do not prove: equivalence on states no test or campaign reaches. The argument for those is
structural: C01's `src/` diff for the vault touches no function body that writes storage (checked in review by the
diff in §8 step 3), and solc's visibility change does not alter storage access.

## 6. Bytecode and gas targets

| Item | Target | Basis |
|---|---|---|
| Vault runtime, production profile (200 runs, via-IR, `bytecode_hash = none`) | **≤ 20,400 B** (TARGET); expected about 20,220 B (prototype, MEASURED in G05) | ADR §8.1; the prototype omits NatSpec only, which does not affect bytecode, but it removed `IVaultState` entirely and the final code keeps `extsload` declared in an interface, so a small difference is possible |
| Vault margin under EIP-170 | ≥ 4,176 B (TARGET) | 24,576 − 20,400 |
| Size policy (`ProductionBuilds.t.sol`, `security.sh`) | unchanged at ≥ 2,048 B; passes | V2-10 |
| Vault init code | under EIP-3860 (49,152 B) | existing gate |
| `VaultLens` runtime | ≤ 24,576 B (EIP-170) | existing gate; the lens grows (ESTIMATE: a few kB) |
| Hooks, authorizer, governor, adapter runtime | byte-identical to step 0 | §3.4 |
| Gas of state-changing vault calls (`test/bench/run.sh`, `--isolate`) | no operation more than 0.5% above step 0; every change reported | dispatch tables change; storage access does not |
| Hook A / Hook B swap gas (same bench) | no increase beyond 0.5% | `exchange` and `coreInputs` bodies unchanged |

If the vault exceeds 20,400 B, stop and report the measured size and its cause before committing step 3. Gas figures
are recorded only from the bench script; none is estimated here.

## 7. Validation criteria

C01 is PASS only if all of the following hold, each with the command and observed result in §10:
1. `forge fmt --check` clean.
2. `forge build` and `forge build --sizes` succeed; §6 size targets met.
3. `forge test` (default profile): all tests pass; the count equals step 0's count plus the new tests; skipped tests
   are only the fork tests without an RPC, as at step 0.
4. Invariant suites pass at the default profile with non-vacuity counts not lower than step 0.
5. `FOUNDRY_PROFILE=ci` run of the new parity, layout and lens tests passes.
6. `test/bench/security.sh` size gate passes; `test/bench/run.sh` gas compared with step 0 (§6).
7. Storage layout diff (L-1) empty.
8. ABI diff (E-7) matches §3.3 exactly.
9. Runtime bytecode of the contracts in §3.4 identical to step 0.
10. Scripts compile (`forge build` covers `script/`); `test/script/DeployScripts.t.sol` passes.
11. `git diff <step-0 tip> -- src` contains only the changes listed in §2.

Not run in C01 (stated in the report): deep profile, coverage gate, mutation testing, Slither, fork tests (no RPC),
any broadcast.

## 8. Steps and commits

Each step ends with the full suite green before its commit. Commits are local only.

| Step | Work | Commit |
|---|---|---|
| 0 | Baseline at the branch tip: `forge build --sizes`, full `forge test`, storage layout JSON, ABI JSON, runtime bytecode hashes of every production contract, `test/bench/run.sh` gas. Kept in the scratchpad, not committed. | none |
| 1 | This plan. | `docs: plan C01 vault read-surface reclaim` |
| 2 | Additive: `extsload` on the vault; `IVaultState` gains `extsload`; lens rewritten on `extsload` with the new decoded getters; storage-layout test; parity tests E-2, E-3, E-8 against the still-present getters. Vault still has every getter, so nothing else changes. | `feat: read vault state through extsload in VaultLens` |
| 3 | Subtractive: getters made internal, four views removed, `IVaultState` and `ISharedCommitmentVault` reduced; test-only differential harness (E-4); every test and script read migrated to the lens; size, ABI, layout and bytecode checks. | `refactor: move vault getters behind extsload` |
| 4 | Results in §10, proposals README status, doc statements that name removed getters. | `docs: record C01 measurements and read-interface change` |

If a step cannot meet its criteria, stop at that step, keep the work uncommitted or committed with the failure
stated in the message (never hidden), and report.

## 9. Git restrictions and completion requirements

Git:
- Work only on `phase-3-c01-vault-bytecode`. Do not create another branch, push, force-push, merge, rebase, tag, open
  a PR, change remotes or deploy. No testnet or mainnet broadcast.
- The untracked `AGENTS.md` is not ours: do not stage, modify or delete it.
- No `git reset --hard`, `git clean`, or other destructive command.
- Commits contain no build output, caches, bench output or secrets; no co-authorship or attribution lines.

Completion:
- §7 criteria met, or the report says PARTIAL / BLOCKED with the failing criterion and its evidence.
- §10 filled with exact commands and observed results (sizes, counts, gas deltas, diffs).
- The milestone report required by `CLAUDE.md`: status, architecture changes, files changed, commits with SHAs,
  validation, residual risks and tests not run, next action requiring approval, and the closing line stating that no
  push, merge, PR, deployment or publication was performed.
- C02 does not start without the owner's review of C01.

## 10. Results

Filled in step 4.
