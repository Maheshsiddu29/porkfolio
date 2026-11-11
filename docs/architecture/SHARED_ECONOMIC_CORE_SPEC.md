# Porkfolio — Shared Economic Core and Hook Strategies (Phase 1B-4.1)

**Status: core and strategies IMPLEMENTED AS ISOLATED LIBRARIES; not integrated into the production hooks.**
`src/pricing/InventoryPricing.sol` (core), `src/pricing/StrategyPricing.sol` (Hook A and Hook B strategies),
`src/oracle/ReferenceBracket.sol` and `src/oracle/PriceRiskAdapter.sol` (reference). Python reference:
`simulations/mm/model.py`. Mathematical background: `INVENTORY_PRICING_SPEC.md` (unchanged, except the band-edge mode
of §4 below). Labels: PROVEN (holds for every input in the stated domain; argument here, checked by the named tests),
TESTED (checked on random and boundary cases, no general proof), SIMULATED (synthetic worlds only).

## 1. One source of truth

Both hooks price from the same physical reserve. Every quantity the economics needs is listed here with where it
lives. **No hook keeps a copy of any inventory quantity.**

| Quantity | Used for | Source of truth | Enforced by |
|---|---|---|---|
| Reserve balances `B_a` | inventory (`N_a = B_a - W_a`) | vault `backing` | vault |
| Protected withdrawal claims `W_a` | excluded from `N_a` | vault `claimableAssets` | vault |
| Shares `S` (incl. queued) | target `T_1 = S * tau`, depth `V = S * v` | vault `totalShares` | — |
| Queue liabilities `D_a` | not priced (queued shares keep their pro-rata claim; LP flows do not change the composition) | vault (`pendingShares`) | vault admission rule |
| Allocations and committed capacity `Q_a` | not priced (capacity, not exposure); predicted by the quoter | vault `reserved`, allocations | vault `exchange` (`QuotaExceeded`) |
| Target inventory `tau` | `I = T_1 - N_1` | core configuration | core (cap) |
| Validated reference `(P, u)` | mid and uncertainty | `PriceRiskAdapter` (immutable) | adapter refuses; vault re-checks (dynamic floor, if approved) |
| Allowed deviation `delta_max` | shared cap | core configuration | core, every strategy |
| Dynamic spread `h = h_base + u` | minimum half-spread of every quote | core | core |
| Cumulative trade costs | potential `C_hat(I)` telescoping on the vault's own `I`; Hook A's activity fee telescoping on its level | vault state; Hook A storage | core; Hook A |
| Vault-wide risk limits (flow caps, exposure caps, halts, floors) | not priced | vault | vault |

The only strategy state is Hook A's activity level (gross input per direction, decaying), the production Hook A's
existing state. It is a price surcharge, never an inventory ledger, and it never enters the core.

## 2. Deterministic quote, atomic settlement

Inside one `beforeSwap`, in this order:

1. The hook reads `n1 = backing(c1) - claimableAssets(c1)` and `S = totalShares()` from the vault, and `(P, u)` from the
   adapter.
2. It builds the core state and prices with its strategy. These are pure functions of those inputs plus the trade.
3. It calls `vault.exchange` with the exact amounts. The vault re-checks everything it owns: allocation, quota, flow
   caps, curator status, static floors and, if approved, the dynamic floor from the same adapter.
4. Hook A stores its new activity level. Hook B stores nothing.

Determinism: within one transaction the vault state changes only through `exchange`, and push feeds change only in
their transmitters' transactions. So the inputs of step 1 are exactly what an off-chain quoter reading the same block
would see, up to swaps placed earlier in the same block. Atomicity is unchanged from today: any failure reverts the
whole swap, including Hook A's level. Nothing in `hookData` carries state, so a trader cannot supply inputs to the
price.

## 3. Strategy interfaces

```solidity
// Core (InventoryPricing)
struct Config { uint256 targetPerShare; uint256 depthPerShare; uint256 depthMax; uint256 baseSpread;
                uint256 minEdge; uint256 maxSpread; uint256 maxDeviation; bool bandEdge; }
struct Core   { int256 inventory; uint256 depth; uint256 target; uint256 cap; uint256 halfSpread; uint256 priceX96; }
function coreState(Config memory, uint256 n1, uint256 shares, uint256 priceX96, uint256 uncertainty)
    returns (Core memory);
function ask(Core memory, uint256 netIn)                 returns (uint256 out, int256 inventoryAfter); // vault sells c1
function bid(Core memory, uint256 moved, uint256 priced) returns (uint256 out, int256 inventoryAfter); // vault buys c1

// Strategies (StrategyPricing)
struct ActivityFee { uint256 baseFeePips; uint256 maxFeePips; uint256 scale0; uint256 scale1; }
struct Quote { uint256 amountOut; int256 inventoryAfter; uint256 fee; uint256 newLevel; }
function hookA(Core memory, ActivityFee memory, uint256 levelNow, bool zeroForOne, uint256 amountIn)
    returns (Quote memory);
function hookB(Core memory, uint256 markupPips, uint256 maxTradeImpactPips, bool zeroForOne, uint256 amountIn)
    returns (Quote memory);
```

**The composition rule.** A strategy takes a fee from the input, rounded toward the vault, and hands the rest to `ask`
or `bid`. It may add to the core price, never subtract. The core's cap is computed for the core half-spread, so a
strategy's extra fee only moves its quotes further onto the vault's side of the reference.

- **Hook A** (inventory-aware cumulative dynamic fee): `fee = F_hat(level + in) - F_hat(level)`, the production
  `cumulativeFee` curve with configurable `[base, max]` bounds; activity-sensitive through the decaying level; the
  inventory cap is the core's, which it cannot change.
- **Hook B** (inventory-aware bounded impact): an optional flat markup; the core's shared cap as the aggregate impact
  bound; a per-trade bound `maxTradeImpactPips` on the distance between the trade's average price and the mid. It is
  two-sided, and inventory reduction is safe: reducing trades get the better side of the skew, and only the
  reference, the spread limit and the vault can refuse them.

**Shared configuration.** For the potential to be one function across hooks, every hook on the reserve must use the
same `Config` (apart from the strategy fields) and the same adapter. Today the libraries take `Config` as an argument.
The implementation gate (`PHASE1B4_1_REPORT.md` §9) requires the shared fields to be held once, immutably, where both
hooks read them, so that the hooks hold no independently mutable copies. Even with mismatched configurations the
straddle still holds per hook, so cycles still lose; what a mismatch breaks is cross-hook split pricing.

## 4. Band-edge mode (new)

`Config.bandEdge = true` computes the cap for an edge of `minEdge + u` instead of `minEdge`, so every quote stays
`minEdge` beyond the whole band `P * (1 +- u)`, not just beyond `P`. The skew room is unchanged, because both `h` and
the edge grow by `u`, and the cap no longer grows with uncertainty. This mode is required by the vault-side dynamic
floor, which refuses any price inside the band. `bandEdge = false` reproduces Phase 1B-4 exactly: its 212 vectors pass
unchanged against the Solidity.

**Constraint found while testing.** The vault's own floor edge must stay strictly inside the hook's. With equal edges
the only margin left is the vault floor's Q96 rounding, which can exceed it: a quote 2 wei short was found by fuzzing.
Rule: the vault refuses inside the band (edge `e`), and the hook keeps `minEdge > e`, with `minEdge >= 1` pip
(`testFuzz_bandModePassesDynamicFloor`).

## 5. Properties

| # | Property | Status | Evidence |
|---|---|---|---|
| S-1 | Every accepted quote of either strategy is beyond the reference by at least `minEdge` (beyond the band in band mode). | PROVEN (proof in `INVENTORY_PRICING_SPEC.md` §7; strategy fees only add) | `testFuzz_straddle_bothStrategies` (10,000 runs), `test_band_mode_straddles_the_whole_band`, `test_interleaved_hooks_alternating_directions` |
| S-2 | Closed cycles at a fixed reference lose, through any mix of strategies, under parameter changes and LP flows between legs. | PROVEN from S-1 | `test_fixed_reference_cycles_across_hooks_and_parameter_changes_lose`, `testFuzz_crossStrategyRoundTripLoses` |
| S-3 | No strategy moves the inventory further out than `max(cap, |I| before)`; inward trades are always priced. | PROVEN (cap check in `ask`/`bid`; linear extension) | `testFuzz_sharedCap`, `test_shared_cap_binds_every_strategy`, `test_flatSteps_askNeverPassesCap` |
| S-4 | Within one strategy at fixed state, splitting never gains. | PROVEN (sum of floors ≤ floor of sum; the potential telescopes; Hook A's fee telescopes) | `testFuzz_splitNeverGains`, `test_same_hook_split_never_gains` |
| S-5 | Across strategies, splitting cannot avoid the core charge: any split's output is at most the markup-free core's. | PROVEN (strategies only remove value; the core telescopes on the shared `I`) | `test_cross_hook_split_pays_the_core_charge_in_full` |
| S-6 | LP deposits and redemptions, allocation changes, curator changes and waiting do not change the core price. | PROVEN for the core (inputs are `n1`, `S` and the reference only; LP flows scale `n1`, `S` and `V` together, up to one unit) | `test_lp_flows_do_not_move_the_price`, `test_lp_flows_between_trades_keep_the_bound`, `test_waiting_lowers_only_the_activity_fee` |
| S-7 | Quotes pass D14 floors pivoted at the reference, and the proposed dynamic floor in band mode, with the vault's own rounding. | TESTED (needs `minEdge >= 1` pip beyond the vault edge) | `testFuzz_quotesPassFloorsPivotedAtReference`, `testFuzz_bandModePassesDynamicFloor` |
| S-8 | The bracket covers every market consistent with live sources. | PROVEN given each feed honours its own deviation trigger | `testFuzz_bracketCoversMarket`, `test_bracket_covers_every_consistent_market` |
| S-9 | Solidity equals Python on 513 vectors (212 + 240 + 61), refusals included. | TESTED | `test/pricing/SharedCoreVectors.t.sol` |

**Counterexamples (properties that do not hold universally).**

- **Routing across fee curves can beat either hook alone.** Hook A's fee starts below Hook B's markup and rises above
  it, so 6,000 through A and the rest through B beats either single hook
  (`test_counterexample_split_across_hooks_can_beat_the_best_single_hook`). The core charge is still paid in full
  (S-5). This is the ordinary routing advantage between two venues, not a bypass.
- **Not path-independent across reference updates.** A buy at `M_1` and a sell at `M_2` profit when the move exceeds
  `2 * minEdge` (band mode: the band). The profit is bounded by the move (`test_cycle_across_reference_update_is_bounded_by_the_move`).
  This is latency arbitrage against a lagging reference, a market cost.
- **On one shared core, Hook A is Hook B plus a fee.** With no markup on B, a best-price router never sends flow to A:
  the P4 configuration in `FILL_RATE_ANALYSIS.md` is identical to P2. Heterogeneous strategies attract different flow
  only through different pools, routers or markups. That is a product question, not a safety one.

## 6. FastPath quote contract, version 2

Extends `QUOTE_INTERFACE_SPEC.md` for the shared core and the adapter. An off-chain quoter (Python today, Rust or
TypeScript later, optionally cached in Redis) must reproduce these integers. Correctness never depends on it: a direct
swap computes the same on-chain.

- **Snapshot**: block number and timestamp; `n1`, `S`; for each adapter leg `(answer, updatedAt)` and the sequencer
  `(status, startedAt)`; the core `Config`; the strategy parameters; Hook A's level and `updatedAt` per direction;
  allocation, flow and floor state for refusal prediction.
- **`stateVersion`** = `keccak256(chainId, hook, poolId, n1, S, every leg's (answer, updatedAt), sequencer status,
  configHash, Hook A level and updatedAt)`. Any change invalidates cached quotes.
- **Maximum accepted price age**: the adapter's per-leg limits (heartbeat + 30 min). `validUntil` = the earliest leg
  expiry (`Reading.validUntil`), further bounded by the allocation's expiry and, for Hook A, by the next decay step.
- **Rounding**: as implemented. Credit and inverse round down, `C_hat` rounds up, outputs round down, one unit is
  reserved per trade, and the bracket rounds outward.
- **Refusal codes** (`shared_core_v1.json` `revertCodes` plus the adapter): 1 `ZeroInput`, 2 `AmountTooLarge`,
  5 `ReferenceDivergence`, 7 `SpreadTooWide`, 8 `NoDepth`, 9 `InventoryLimit`, 10 `ZeroOutput`,
  11 `TradeImpactExceeded`, 12 `DegenerateBracket`, 13 `InsufficientSources`, 14 `FeedUnusable`,
  15 `SequencerUnavailable`, 16 `DecimalShiftOutOfRange`; predicted vault refusals 20–26 as in v1.
- **Conformance**: `inventory_quote_v1.json` and `shared_core_v1.json`, with CSV views for Solidity.

## 7. Measured cost (production compiler settings)

| | Gas |
|---|---|
| Hook B strategy: core state + quote, vault sells / buys currency1 | 9,733 / 7,554 |
| Hook A strategy: same | 10,974 / 8,805 |
| Vault reads `n1`, `S` (five getters), cold / warm | 19,549 / 7,049 |
| Adapter `currentReference`, real Unichain feeds, cold / warm | 76,331 / 24,391 |
| Hook B swap today (for scale) | 244,885 |

**Estimated** integrated Hook B swap: 244,885 − about 3,000 (no position write) + 13,000 (vault reads, marginal) +
9,700 (quote) + 76,331 (adapter, cold) + 24,391 (vault re-read, warm) + 8,223 (vault floor work) ≈ **373,000 gas**.
That is ESTIMATE; it must be measured in the integration milestone.

| Bytecode | Runtime bytes |
|---|---|
| `PriceRiskAdapter` | 4,180 |
| Harness containing both strategies, the core and the bracket math (upper bound for the code a hook adds) | 7,118 |
| Production vault | 22,049 (unchanged) |
