# Porkfolio — Shared-core swap path: profile and optimizations (Phase 1B-4.4)

**Status: MEASURED.** All numbers come from production artifacts. Fork figures come from a read-only Unichain fork
pinned at block 63,689,000 (`UNICHAIN_FORK_BLOCK`, new in this phase), using `--isolate` (cold, one transaction per
call). Nothing was broadcast.

## 1. Where the gas went (before)

Trace of Hook B, 1,000 USDC → WETH: 417,221 gas in total, of which 322,467 in `beforeSwap`.
Command: `forge test --match-path test/fork/UnichainIntegratedSwap.t.sol --isolate -vvvvv`.

| Component | Gas | Notes |
|---|---|---|
| adapter read #1 (hook, cold) | 96,204 | 5 feeds incl. the sequencer: 74,965 in the feeds, ~13,000 cold-account surcharge, ~8,100 adapter compute |
| adapter read #2 (vault, warm) | 24,204 | 15,565 in the feeds, ~8,100 adapter compute |
| 7 vault getters from the hook | 19,160 | `riskAdapter`, `inventoryTolerancePips(1)`, `riskEdgePips`, `inventoryTargetPerShare(1)`, `backing`, `claimableAssets`, `totalShares`. About 1.1k each is call overhead; the cold slots would otherwise be paid inside `exchange` |
| `exchange`, own logic | ~79,000 | allocation, curator, 3 flow records, reserved totals, backing, floors. Static mode pays this too |
| ERC-6909 mint / transferFrom / transfer / burn | 72,383 | atomic settlement |
| hook logic | ~31,500 | ~10k of it is the core math (`test/pricing/SharedCoreGas.t.sol`) |
| outside `beforeSwap` | 94,754 | router, PoolManager, ERC-20 settle and take: the cost of any v4 swap |

**Where the +147k over static mode comes from:** about 120k is the two adapter reads, 19k the getters and 10k the core
math.

## 2. Candidates, measured one at a time

| # | Change | Security effect | Gas per shared-core swap | Bytes | Decision |
|---|---|---|---|---|---|
| P1 | Vault computes only the directional floor it uses (`VaultRiskBoundary.dynamicFloor`), not both | none: same steps and rounding; fuzz-tested equal to `dynamicFloors` (`testFuzz_dynamicFloorEqualsPair`) | −303 (selling asset1) / −563 (selling asset0) | vault −5 | **kept** |
| P2 | Adapter: feed calldata in scratch memory instead of `abi.encodeCall`; sources passed from immutables instead of rebuilt as memory structs | none: same reads and checks; oracle unit tests and fork tests pass | −1,632 per read (warm read 12,847 → 11,215 with mock feeds), two reads per swap | adapter +172 | **kept** |
| P3 | `vault.coreInputs()`: the six values the hook needs in one call; the hook makes 2 external calls instead of 8 | none: a view of the same storage, equal to the separate getters (`test_coreInputs_matchGetters`); the vault still re-reads the adapter and checks every limit itself | −7,167 | vault +196, hooks −720 each | **kept**; first to drop if a security fix needs vault bytes (§4) |
| P4 | Vault caches the reading in transient storage so `exchange` skips the second adapter read | arguably equivalent within one transaction, but it is a new stateful component, needs a non-view entry point the quote views cannot share, and must be keyed to the adapter and cleared on replacement | ≈ −23,800 (estimated from the trace: the warm read minus transient access) | ≈ +150 to +300 on the vault: headroom ≈ 1,840–1,990 B, **below the 2,048 B target** | **rejected**: size target, and the brief prefers no new caching or stateful components |
| P5 | Hook passes its reading to the vault | replaces the vault's independent price check | ≈ −24k | — | **rejected**: forbidden without an equivalent security property |
| P6 | Merge Hook B's `strategy` into its `CoreParams` slot | none | ≈ −2,100 (Hook B only) | — | not done: a new struct shape for one cold read (0.5%) |

**Not changed, and why:**
- **The first adapter read.** Its feed calls and cold accounts are the price of a fresh, sequencer-checked
  two-provider reading.
- **The vault's second read.** This is what keeps the vault's check independent of the hook.
- **Flow limits, exposure, curator and allocation checks.** Required.
- **ERC-6909 settlement.** Atomic by design.

**Off-chain lever (not a contract change):**
- An EIP-2930 access list naming the feeds and their slots saves about 200 gas per cold account and per cold slot,
  roughly 5k per swap. Routers may add it.

## 3. After (MEASURED)

### Fork, shared core, same pinned block

| Swap | Before | After | Change |
|---|---|---|---|
| Hook B, 1,000 USDC → WETH | 417,221 | **406,211** | −11,010 (−2.6%) |
| Hook B, 0.5 WETH → USDC | 412,492 | **401,222** | −11,270 (−2.7%) |
| Hook A, 1,000 USDC → WETH | 444,187 | **433,176** | −11,011 (−2.5%) |
| Hook A, 0.5 WETH → USDC | 439,539 | **428,268** | −11,271 (−2.6%) |
| Hook A, static mode | 296,761 | 296,898 | +137 (+0.05%) |

**The shared-core premium over static mode falls from about +147k to about +136k.**

**Later in this phase: the optional fresh tier** (`ORACLE_RELAYER.md`) **adds about 1,970 gas per swap even when
disabled** (the tier check runs on four legs in each of the two reads). Measured on the same block:

| Swap | Final |
|---|---|
| Hook B, 1,000 USDC → WETH | 408,181 |
| Hook B, 0.5 WETH → USDC | 403,192 |
| Hook A, 1,000 USDC → WETH | 435,146 |
| Hook A, 0.5 WETH → USDC | 430,238 |
| static mode | 296,898 |

- Net against the starting point: **−9,040 (Hook B, buy) to −9,301 (Hook A, sell)**, i.e. −2.1% to −2.2%.
- Adapter runtime 4,813 → 5,552 B.

### Local production benchmark (`test/bench/run.sh`, static mode)
- Swaps and splits: +137 gas each (+0.05%). That is the six-word `coreInputs` return where `riskAdapter` returned one
  word.
- LP paths and setters: +22 (dispatch).
- Vault deployment: +0.83%.
- Hook quotes: +135 to +156.
- Everything else: unchanged (26 rows).

### Bytecode (runtime / EIP-170 margin)

| Contract | Before | After |
|---|---|---|
| vault (200 runs) | 22,249 / 2,327 | **22,440 / 2,136** (target 2,048: met) |
| Hook A | 15,116 | 14,341 |
| Hook B | 15,338 | 14,601 |
| `PriceRiskAdapter` | 4,641 | 4,813 |
| `VaultGovernor` | 3,027 | 4,111 |

Vault storage layout: identical (30 entries, compared with `forge inspect` before and after).

## 4. Headroom policy
- The vault is 88 bytes above the 2,048 B target.
- P3 is a pure performance change, so it is the first thing to remove if an essential security change needs vault
  bytes. Removing it costs about 7k gas per shared-core swap and frees 196 B.
- No protection was removed or weakened to obtain any figure above.
