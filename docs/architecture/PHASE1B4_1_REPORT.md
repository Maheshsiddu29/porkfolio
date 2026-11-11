# Porkfolio — Phase 1B-4.1 Report: Shared Economic Core and Dynamic Risk Boundary

**Status: PARTIAL, by design. Architecture selected; isolated libraries and a read-only adapter implemented and
tested; the vault change is proposed and stopped before implementation, because it changes the vault's trust
boundary, storage and one financial invariant.** Branch `phase-1b-4-1-shared-economic-core` from
`research/adaptive-market-making` at `8e198b5`. Production contracts (`SharedCommitmentVault`, Hook A, Hook B,
`CuratorAuthorization`, `VaultLens`) are byte-identical to the baseline. Nothing pushed, merged, deployed or published.

## 1. Results

1. **Dynamic floor: architecture B selected.** One immutable, read-only `PriceRiskAdapter` serves both the hooks and
   the vault. The vault independently refuses any fill inside the adapter's band, in the same transaction, from the
   same data, with no operator action during trading. A (oracle logic inside the vault) does not fit and would
   duplicate logic; C (keeper-pushed floors) is stale by construction and adds a new price authority
   (`DYNAMIC_FLOOR_ARCHITECTURE.md`).
2. **The vault change is specified, measured and not applied** (`docs/proposals/vault-dynamic-floor.patch`): +1,947 B
   at 2,000 runs (misses the size target) or +1,581 B at 200 runs (meets it, +0.13–0.36% gas on every vault
   operation). With no adapter installed the patched vault passes the whole suite apart from the size gate.
3. **Oracles verified on Unichain mainnet**, read-only (`ORACLE_VERIFICATION_UNICHAIN.md`). Chainlink and RedStone push
   feeds work for WETH/USDC, but both trigger only on a 0.5% move (Chainlink heartbeat 24 h). The resulting WETH/USDC
   band is ±82 bps (fork-measured). Pyth's on-chain price is 132 days stale without an in-transaction update, and its
   update endpoint now needs an API key: not verified usable.
4. **Shared economic core** (`SHARED_ECONOMIC_CORE_SPEC.md`). Every economic quantity has one source of truth, the
   vault or the immutable adapter. The only strategy state is Hook A's activity level.
5. **Hook A and Hook B strategies** coexist by one rule: a strategy may add to the core price, never subtract. Proven
   from it: straddle, cycle losses, shared cap, split resistance within a strategy, and the core charge paid in full
   across strategies. Three counterexamples are documented.
6. **Execution availability** (`FILL_RATE_ANALYSIS.md`). The 34.3% of Phase 1B-4 is a demand-model effect: under 2% of
   orders are refused by the protocol in normal markets. With the verified feeds, fail-safe pricing fills about 5%. A
   fresh independent source would bring it to about 39% with zero arbitrage and the best LP outcome of every
   candidate, but no such source is verified usable today.

## 2. Files and commits

| Commit | Content |
|---|---|
| `17c94e4` | `sim(mm)`: shared core, strategies and bracket reference in the Python model; `test_core.py` |
| `a5dfc05` | `feat(pricing)`: `src/pricing/InventoryPricing.sol`, `StrategyPricing.sol`; `test/pricing/` (vectors, properties, harness); conformance vectors (JSON + CSV); read-only `fs_permissions` entry |
| `0d68a74` | `feat(oracle)`: `src/oracle/ReferenceBracket.sol`, `PriceRiskAdapter.sol`, `src/interfaces/IAggregatorV3.sol`; `test/oracle/`; `test/fork/UnichainOracles.t.sol`; `test/utils/MockAggregator.sol` |
| `28b9b7e` | `fix(pricing,oracle)`: explicit decimal-shift bound, documented casts, band-mode NatSpec; strategy gas test |
| `2744473` | `sim(mm)`: verified-feed reference modes, vault dynamic floor, rejection attribution; `results/phase141*` |
| (this commit) | `docs`: this report, `DYNAMIC_FLOOR_ARCHITECTURE.md`, `ORACLE_VERIFICATION_UNICHAIN.md`, `SHARED_ECONOMIC_CORE_SPEC.md`, `FILL_RATE_ANALYSIS.md`, `docs/proposals/vault-dynamic-floor.patch`; exact cap-boundary test |

## 3. Gas and bytecode (measured unless marked)

| Item | Value |
|---|---|
| Production vault runtime | 22,049 B, unchanged (EIP-170 margin 2,527) |
| `PriceRiskAdapter` runtime | 4,180 B |
| Harness with both strategies, core and bracket math | 7,118 B (upper bound for the code a hook adds) |
| Patched vault (proposal) | 23,996 B at 2,000 runs; 21,199 B at 200 runs |
| Vault at 200 vs 2,000 runs | +0.13% to +0.36% gas per operation; +526 per swap |
| Hook B / Hook A strategy quote (core state + quote) | 9,733 / 10,974 gas (vault sells currency1) |
| Adapter read on real Unichain feeds | 76,331 cold / 24,391 warm |
| Vault-side dynamic floor work (cheap adapter) | +8,223 per swap |
| Vault reads of `n1`, `S` | 19,549 cold / 7,049 warm |
| Integrated Hook B swap with the core, adapter and vault floor | **≈ 373,000 (ESTIMATE)**, against 244,885 today |

## 4. Mathematical results

**Proven** (argument in the specs; checked by Python and by Solidity-only fuzz at 10,000 runs): S-1 to S-6 and S-8 of
`SHARED_ECONOMIC_CORE_SPEC.md` §5.

**Tested, not proven**: S-7 (floor compatibility with the vault's rounding needs `minEdge >= 1` pip beyond the vault's
edge) and S-9 (Solidity = Python on 513 vectors).

**Simulation only**: every LP outcome and fill rate.

**Counterexamples**: cross-strategy routing can beat either hook alone; latency arbitrage across reference updates;
equal vault and hook edges let rounding refuse a quote (2 wei); a Hook A on the same core receives no flow; and, from
Phase 1B-4, the value-target split leak.

Bugs found and fixed in this phase's own new code:
- An unchecked decimal shift in `ReferenceBracket`, previously safe only through its caller (now `DecimalShiftOutOfRange`).
- An undocumented precondition of the inverse at flat-step prices. `ask` was already safe; the precondition is now
  documented, and a regression test pins `ask`'s behaviour.

## 5. Validation

See §10.

## 6. Open architectural risks

1. **Economics on push feeds only.** About 5% fills at ±82 bps quotes. Fixing it needs a fresh independent source,
   which brings credentials, fees and router integration for pull updates, and the trader's free option on which
   update to submit.
2. **The vault change** relaxes D14 to an outer band while an adapter is installed. If every source is corrupted at
   once, the static band (≤ ±25%), flow caps and exposure caps are the bound.
3. **Size.** The proposal meets the 2,048 B target only at 200 runs.
4. **Divergence detection is coarse**: two honest-looking sources can differ by up to about 1.84% on WETH/USDC before a
   refusal.
5. **Shared configuration** is not yet held in one immutable place (§3 of the core spec); until it is, a mismatched
   configuration weakens cross-hook split pricing (not cycle safety).
6. **Integration gas** (about 373k, estimated) has not been measured.
7. **Synthetic demand.** Fill rates move one-for-one with the assumed trader tolerance; no historical calibration.

## 7. Tests not run

No integration of the core into the production hooks (forbidden before the gates below). No Unichain Sepolia reads.
No pull-oracle update measured (no credentials). No Data Streams check. No historical replay. No remote CI. No
independent review.

## 8. Decisions requiring owner approval

- **D-2a**: architecture B and `docs/proposals/vault-dynamic-floor.patch` (vault trust boundary, storage, D14 → outer
  band while an adapter is installed).
- **D-2b**: vault at 200 optimizer runs, or remove code elsewhere in the vault.
- **D-1**: Chainlink and RedStone as the initial sources; whether to obtain a pull source (and accept its key, fees
  and trader option) before launch economics are acceptable.
- **D-3**: where the shared core configuration lives (recommended: in the immutable adapter, read by both hooks).
- **D-4**: the bracket configurations were evaluated only without the volatility term (their band already widens
  with the feeds' thresholds). Whether to add it, which needs Chainlink round history or a stored estimate because
  RedStone exposes no history, is open.

## 9. Gates for the next milestone (integration into the hooks)

Each is pass/fail and must pass before any production hook uses the core:

1. **Dynamic-floor decision.** D-2a and D-2b approved in writing; the vault change implemented in its own reviewed
   milestone. Full vault security suite, invariants with `fail_on_revert`, storage-layout diff showing only appended
   slots, bytecode within the approved target, guardian rules unchanged.
2. **Independent inventory-risk enforcement.** The vault-side check refuses every in-band fill, whatever the hook
   quotes. Test: a malicious hook that quotes inside the band is refused (scripted-hook test on the patched vault).
3. **Both hooks on the shared core.** Hook A and Hook B rewritten on `StrategyPricing`, sharing one immutable
   configuration. Tests: cross-hook cycles lose, the cap binds across hooks, and splits across hooks pay the full core
   charge, through the real PoolManager.
4. **Measured gas and size.** Production-artifact benchmark of the integrated swaps. Bytecode under EIP-170 with the
   project margin. Report against the 373k estimate.
5. **Supported reference behaviour.** Adapter configuration for the launch pair read on-chain. Fork test passing.
   Sepolia reads of the same providers. A written decision on the pull source.
6. **Conformance.** Solidity equals Python on all vectors, plus vectors for the integrated hooks' quote views.

## 10. Validation record

Foundry 1.7.1, solc 0.8.26, Slither 0.11.6, Python 3.11.8 (standard library). All local; the fork experiment used the
public Unichain RPC read-only.

| Command | Result |
|---|---|
| `forge fmt --check` | clean |
| `forge build` | exit 0; new `src/` files have no `unsafe-typecast` notes; `block-timestamp` notes in the adapter are intentional (staleness) |
| `forge test` (default profile) | 490 passed, 0 failed, 4 skipped (the fork tests, without an RPC), 43 suites |
| `bash test/bench/security.sh` (`FOUNDRY_PROFILE=ci`, 10,000 fuzz runs, forced rebuild, size gate) | exit 0; size gate passed, vault 22,049 B (margin 2,527); 489 passed, 0 failed, 4 skipped (fork tests without RPC) |
| `FOUNDRY_INVARIANT_FAIL_ON_REVERT=true FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-contract VaultInvariantsTest` | 35/35: 30 invariants × 32,768 calls, 0 reverts |
| `FOUNDRY_FUZZ_RUNS=10000 forge test --match-path "test/pricing/*"` | all pricing tests pass at 10,000 runs |
| `UNICHAIN_RPC_URL=https://mainnet.unichain.org forge test --match-contract UnichainOraclesForkTest -vv` | 4/4; numbers in `ORACLE_VERIFICATION_UNICHAIN.md` §5 |
| mutation run (19 mutants of the four new `src/` files; script kept outside the repository, run in a scratch copy) | **19 of 19 killed** (table below). In the first run M2 and M4 survived; `test_capBoundaryIsExact` was added and kills both |
| `slither . --filter-paths "lib/\|test/" --exclude-dependencies` | 45 results vs 39 at Phase 1B-3; the 6 new are in new files and intentional: `divide-before-multiply` in `coreState` (the risk cap is defined on the same floored `T_1` as `I`; under one unit, matches Python), `uninitialized-local` (`low` starts at 0 as the running maximum), 3 × `timestamp` (staleness and sequencer grace), `assembly` (bounded return-data copy) |
| `python3 -m unittest discover -s simulations/mm` | 37 passed |
| `python3 -m unittest discover -s simulations/pricing` | 22 passed |
| vector regeneration (`vectors.py`, `vectors_core.py`, `vectors_csv.py`, twice) | byte-identical; `inventory_quote_v1.json` sha1 `ecd0c700…` unchanged since Phase 1B-4 |
| `python3 simulations/mm/simulate.py --phase141` | `results/phase141.md` (74 s) |
| production contracts vs baseline | `src/SharedCommitmentVault.sol`, hooks, `CuratorAuthorization.sol`, `VaultLens.sol` unchanged (`git diff 8e198b5 -- <files>` empty); vault runtime 22,049 B |

Mutation run (one asserted textual change per mutant; `forge test --match-path 'test/{pricing,oracle}/*' --fail-fast`):

| id | file | mutation | result | first failing test |
|---|---|---|---|---|
| M1 | InventoryPricing.sol | ask: drop the one-unit reserve | killed | test_vectors_inventoryQuoteV1() (gas: 343997) |
| M2 | InventoryPricing.sol | ask: allow outward trade from exactly the cap | killed | test_capBoundaryIsExact() (gas: 18610) |
| M3 | InventoryPricing.sol | bid: drop the one-unit reserve | killed | test_vectors_inventoryQuoteV1() (gas: 387981) |
| M4 | InventoryPricing.sol | bid: cap off by one | killed | test_capBoundaryIsExact() (gas: 30409) |
| M5 | InventoryPricing.sol | straddle cap: max of sides | killed | test_vectors_inventoryQuoteV1() (gas: 9739421) |
| M6 | InventoryPricing.sol | band mode ignored | killed | test_vectors_strategies() (gas: 440905) |
| M7 | InventoryPricing.sol | extCost positive branch rounds down | killed | test_vectors_inventoryQuoteV1() (gas: 572223) |
| M8 | InventoryPricing.sol | inverse negative branch rounds down | killed | test_vectors_inventoryQuoteV1() (gas: 995288) |
| M9 | InventoryPricing.sol | risk cap not applied | killed | test_vectors_inventoryQuoteV1() (gas: 348871) |
| M10 | StrategyPricing.sol | Hook A bid moves state by net only | killed | test_vectors_strategies() (gas: 1030342) |
| M11 | StrategyPricing.sol | Hook B per-trade bound removed | killed | test_vectors_strategies() (gas: 488159) |
| M12 | StrategyPricing.sol | Hook B markup rounds for the trader | killed | test_vectors_strategies() (gas: 680749) |
| M13 | ReferenceBracket.sol | bracket low rounds up | killed | test_vectors_brackets() (gas: 71425) |
| M14 | ReferenceBracket.sol | uncertainty takes the smaller side | killed | test_vectors_brackets() (gas: 616454) |
| M15 | ReferenceBracket.sol | degenerate bracket accepted | killed | test_vectors_brackets() (gas: 140879) |
| M16 | PriceRiskAdapter.sol | sequencer grace ignored | killed | test_sequencerDownOrInGrace() (gas: 108451) |
| M17 | PriceRiskAdapter.sol | staleness one hour late | killed | test_staleSource() (gas: 83086) |
| M18 | PriceRiskAdapter.sol | future timestamps accepted | killed | an assertion in the adapter suite (`test/oracle/`) |
| M19 | PriceRiskAdapter.sol | minimum sources not enforced | killed | test_staleSource() (gas: 81726) |
