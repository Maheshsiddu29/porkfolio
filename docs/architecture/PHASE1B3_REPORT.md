# Porkfolio — Phase 1B-3 Report: Cumulative Pricing in Hook A and Hook B

**Status: PASS (local), with one owner decision outstanding (§8.1).** Branch `phase-1b-3-cumulative-pricing` from
`fix/auth-module-install-hardening` at `4dcf4bd`. Nothing is pushed, merged or deployed. No audit, formal proof or
historical-market result is claimed. Labels: SOURCE (read from code), OBSERVED (asserted by a named test or measured
by a named command), MODEL (Python reference model, `simulations/pricing/`), SYNTHETIC (generated trade paths).

The pricing passed every economic-consistency check set for it (§3) and the adversarial suite (§5). It also has a
structural consequence that the plan did not anticipate. With the vault's directional-consistency floors (D14), Hook B
cannot trade a position back toward zero at the curve's price. A reverse trade is refused until the position decays.
That is safe, but in the synthetic runs it lowers Hook B's fill rate to 59–67% (§8). Whether to accept this, shorten
the decay window or change the reverse-leg rule is an owner decision.

## 1. What changed

| Commit | Content |
|---|---|
| `f1c7594` | `sim(pricing)`: integer reference model (`cumulative.py`) and 22 economic-consistency checks |
| `c42667b` | `feat(pricing)`: `src/hooks/CumulativePricing.sol` and its model-differential unit tests; vector generator |
| `a823bb4` | `feat(hooks)`: cumulative pricing in Hook A and Hook B; `_quote` / `_commit` split; optional `hookData` minimum; existing tests updated for the new semantics |
| `1e48281` | `test(pricing)`: model scenarios end to end, Hook A / Hook B behaviour, trader protection (incl. V4Router) |
| `bef2234` | `test(pricing)`: adversarial suite; production-artifact pricing scenarios |
| `ddf208e` | `test(invariant)`: INV-P2 (state replay), INV-P4 (cap) in the stateful campaign |
| `eddbf5c` | `sim(pricing)`: synthetic economic comparison |
| `b4a82d3` | `test(bench)`: pricing gas on production artifacts |
| `0b14391` | `test(invariant)`: the `pricingSwap` allocation search cannot overflow its seed (§10) |
| (this commit) | `docs`: this report; `TRADE_SPLITTING.md` §8; status lines of the spec and plan; readiness P-2, P-5, P-6; ledger example |

`SharedCommitmentVault.sol` is unchanged: its runtime bytecode is identical to the hardening baseline (§9).

## 2. Pricing mathematics (SOURCE)

Units: raw token units; `P` = reference price, raw currency1 per raw currency0, Q64.96; fees and impact in pips
(10^6 = 100%); time in seconds. `Q = 2^96`.

### 2.1 Hook A: cumulative fee per pool and direction

State per (pool, direction): level `s` = gross **input** swapped in that direction, raw input units, `uint128`, with
`updatedAt`. Marginal fee rate `m(u) = base + (max − base)·min(1, u/K)`, `K` = the direction's scale.

```
F(s)     = (base·s + (max − base)·s²/(2K)) / 10^6                     s ≤ K
         = (K·(base + max)/2 + max·(s − K)) / 10^6                     s > K      (continuous at K)
F̂(s)     = ⌈F(s)⌉                                                    CumulativePricing.cumulativeFee
s₀       = max(0, s − ⌊K·Δt/W⌋)                                       decay, W = decayWindow (0: off)
fee      = F̂(s₀ + in) − F̂(s₀)                                         ≤ in, since max < 10^6
out      = _grossOut(P, dir, in − fee)                                rounded down
store    s₀ + in (reverts AmountTooLarge above 2^128 − 1), updatedAt = now
```

Example (1:1, base 500, max 5,000, K = 10,000): 8,000 in from level 0 pays F(8,000) = 4 + 14.4 = 18.4 and receives
7,981.6, as one swap or any split.

### 2.2 Hook B: signed position on a virtual constant-product curve

State per pool: position `x` = currency1 sold by the vault minus currency1 bought back, `int128`, with `updatedAt`.
Depth `V ≤ 2^95 − 1`, cap `X = maxPosition(V, maxImpact)`.

```
C(x)     = V·x·Q / (P·(V − x))           currency0 owed for position x (virtual reserves V and V·Q/P)
Ĉ(x)     = ⌈C(x)⌉ for every integer x    CumulativePricing.positionCost (negative x: −⌊|C(x)|⌋)
x₀       = sign(x)·max(0, |x| − ⌊X·Δt/W⌋)
sell currency0 (zeroForOne): t = Ĉ(x₀) + in; revert if t ≥ Ĉ(X + 1)
         x' = largest x with Ĉ(x) ≤ t = ⌊t·P·V / (V·Q + t·P)⌋ (toward −∞)   positionForCost, exact
         out = x' − x₀ currency1; the remainder t − Ĉ(x') stays with the vault
sell currency1 (oneForZero): x' = x₀ − in; revert if x' < −X; out = Ĉ(x₀) − Ĉ(x') currency0
X        = V − r,  r = smallest integer with r²·(10^6 + m) ≥ V²·10^6    (marginal ratio (V/(V−x))² ≤ 1 + m)
```

Example (V = 1,000,000, 2%, 1:1): Ĉ(1,000) = 1,001.001…, X = 9,852.457…; 1,000 currency1 out costs 1,001.001 as one
swap or ten.

### 2.3 Rules common to both

- **Write after settlement.** `_quote` is a view returning the new state; `_commit` stores it after `vault.exchange`
  returns. Any failure later in the unlock reverts it (`test_HBP_failedSwapsLeaveStateUnchanged`,
  `test_ADV_hookA_unpaidSettlementRollsBackLevel`). No swap can run between quote and commit: the only calls in
  between are `poolManager.mint`, `vault.exchange` (non-reentrant; calls only ERC-6909 functions, no callbacks) and
  `poolManager.burn`.
- **Storage, not transient storage**, so splitting across transactions at one timestamp equals one transaction
  (`test_ADV_split_2_5_10_100_sameAndCrossTx`).
- **Allocation-independent.** The allocation id and curator are not pricing inputs.
- **Parameter changes.** `configurePool` first applies the decay elapsed under the old parameters. Hook A keeps its
  levels. Hook B rescales `x` by `V_new / V_old` (toward zero) when the depth changes, keeps it otherwise; a tightened
  cap leaves an out-of-range `x`, from which only trades toward zero execute. New prices apply at once. `hookOwner` is
  trusted; there is no loosening delay (D-P3 deferred).

### 2.4 Departures from the plan and specification

| Plan / spec | Implemented | Why |
|---|---|---|
| Hook A state = gross **output**, quadratic inverse with `sqrt` and correction steps | State = gross **input**, fee on input, no inverse | Same economics at a fixed `P`; the fee is computed directly from the input, telescopes exactly, and needs no square root or correction. |
| Hook A one `K` per pool | `scale0`, `scale1` per direction | The two directions' inputs are different tokens; one number cannot mean the same size in both. |
| Hook B: `Ĉ` (ceil) to sell, `Č` (floor) to buy back | One `Ĉ` for both directions | MODEL: with `Ĉ`/`Č` a change of direction can **gain** the trader one raw unit (round trip from a state where `C` is not an integer to one where it is), repeatably. With one function every closed cycle exchanges exactly zero net currency0 plus remainders. |
| Hook B keeps raw `x` when `V` changes (D-P5 covers the cap only) | Rescale `x` by `V_new/V_old` | MODEL: keeping raw `x` after a 10× tighter depth paid a buy-back 1.543 currency0 per currency1, against 1.041 for the last unit sold; rescaling pays 1.031. Rescaling keeps the marginal price continuous, so a smaller depth is a tightening in both directions and a larger one a loosening in both. |
| Symmetric bound for negative `x` (formula unstated) | `|x| ≤ X` with the positive-side `X` | Conservative: at `−X` the premium on currency0 is `((V+X)/V)² − 1 < m`. |
| Decay `ρ = scale / W` | Hook A `K/W`; Hook B `X/W`; `W = 0` disables | "A state at the scale decays to zero in `W` seconds"; `W = 0` makes decay-free tests and configurations possible. |
| D-P4 64-byte `hookData` minimum on Hook B | On both hooks, in the shared base | Same trust model; one code path. |

## 3. Independent Python model (Stage 1, MODEL)

`simulations/pricing/cumulative.py` mirrors the Solidity integer arithmetic operation by operation and keeps the real
curves as exact `Fraction`s. `python3 -m unittest discover -s simulations/pricing -v`: **22/22 OK** (0.6 s). Checks:

| Check | Result |
|---|---|
| `cumulativeFee`, `positionCost` are exact ceilings of the real curves; both fee branches agree at `K` | 3,000 random cases each, pass |
| `positionForCost` equals an independent bisection | 1,500 cases, pass |
| `maxPosition` is the exact cap: ratio ≤ 1 + m at `X`, > 1 + m at `X + 1`; negative side ≤ 1 + m | 3,000 cases, pass |
| Split invariance, Hook A (random price, base, max, K, prior level, 1–50 pieces) | fees identical; output gap ≤ n − 1; 1,500 cases |
| Split invariance, Hook B selling currency0 | `x_split ≤ x_single`; value forgone = sum of exact-input remainders, each below one more unit's integer cost; 1,500 cases |
| Split invariance, Hook B selling currency1 | outputs identical (no remainder); 1,500 cases |
| Aggregate cap (`V` = 200,000, 1%): 5,000 in 1, 2, 5, 10, 100 pieces | every partition stops at the cap |
| Any interleaved sequence, Hook B, no elapsed time | trader pays exactly `Ĉ(x_end) − Ĉ(x_start)` + remainders, receives `x_end − x_start` currency1; 400 sequences |
| Closed cycles (`x` returns) | never pay the trader currency0; value gained at `P` < `(10^6 + m)/10^6` raw currency0 once per sequence (flat steps of `Ĉ` where currency1 is cheaper than one raw currency0) |
| Single actor, decay between trades, 4,000 random strategies | best result **0** raw currency0 at `P` (no profitable cycle) |
| Sandwich: profitable on the curve alone | 2,000/2,000 cases; **all 2,000 back-runs refused by D14-consistent floors** |
| Round trip with floors on a grid (`F1` 0.98–1.01, `F0 = ⌈2^192/F1⌉`) | no zero-cost round trip passes both floors |
| Decay monotone, never below exact linear decay, gaps to `2^64 − 1` | pass |
| Hook A decay farming | fee saved ≤ `K·Δt/W` of flow at `max` + 1 |
| Depth change, rescale vs keep raw | rescale: buy-back 1,030.72 for 1,000 (last unit sold at 1.0412); raw: 1,543.21 |
| Hook A round trip | pays both fees exactly |
| Allocation shopping | old rules: a fresh allocation prices better (A and B); new rules have no allocation input |
| Spec §5 numbers | Hook A 18.4 (1, 8, 1,000 pieces); Hook B `Ĉ(1,000)`, `X` = 9,852.457…, 25.1256 |

The model is also the source of the Solidity expectations: `vectors.py` writes `test/utils/PricingVectors.sol`
(232 library vectors and two 60-step swap scenarios), regenerated byte-identical.

BondMeBro's synthetic simulation work could not be reused. Neither local BondMeBro checkout contains its generator,
regime definitions or outputs, only summary statistics in its README. No data was invented in its place; §8 uses a
new, separately labelled generator.

## 4. Splitting resistance (OBSERVED)

| Property | Bound | Evidence |
|---|---|---|
| Hook A split vs single | fees identical; split receives ≤ single and at most `n − 1` raw units less (one rounding per conversion). **Reached**: at `P = 2^96 − 1` selling currency0 loses exactly one unit per extra piece | `testFuzz_HAP_splitVersusSingle` (1,000 / 10,000 runs) |
| Hook B selling currency1 | split output = single output exactly | model; `test_TS_hookB_splitPaysSameImpact`; scenarios |
| Hook B selling currency0 | split ≤ single; difference ≤ sum of the pieces' exact-input remainders, each < the integer price of one more unit | model `test_hook_b_split_zero_for_one` |
| 1 vs 2, 5, 10, 100 pieces, same transaction and separate transactions | identical output and state at 1:1 | `test_ADV_split_2_5_10_100_sameAndCrossTx`, `test_PA_pricing_splitInvariance` |
| Across allocations and curators | identical | `test_ADV_split_acrossAllocationsAndCurators` |
| Hook B aggregate cap | no partition passes it, positive and negative side | `test_TS_hookB_capIsAggregate_splitCannotBypassIt`, `test_HBP_negativeCapIsAggregate`, `test_PA_pricing_aggregateCap` |
| Crossing trade split below the floor | refused (each piece is floor-checked alone) | `test_HBP_crossingTrade_cannotBeSplitBelowTheFloor` |
| Across hooks | **not prevented by pricing**; bounded by the vault-scope flow limit | `test_ADV_crossHookSplit_boundedByVaultFlowLimit` |
| Across time | intended recovery; Hook A saving ≤ `K·Δt/W` of flow at `max` + 1; Hook B refill ≤ `X·Δt/W` | `testFuzz_ADV_hookA_decayGainBounded`, `test_ADV_hookB_decayRefillBounded` |

Rounding found by the tests: because the Hook A fee is a difference of two rounded-up values, **waiting can raise the
integer fee by one raw unit** when the exact fee falls by less than one unit (`testFuzz_ADV_hookA_decayGainBounded`
counterexample, now asserted as the bound).

## 5. Round trips, manipulation and the vault floors

- **Hook B is path-independent in integers.** Any trade sequence moving `x` from `a` to `b` exchanges exactly
  `Ĉ(b) − Ĉ(a)` currency0 plus remainders, in any order and split. A round trip therefore exchanges zero net
  currency0 except remainders; the hook would pay back exactly what it charged
  (`test_HBP_roundTrip_hookPaysBackExactly_vaultFloorRefusesIt`, `test_PA_pricing_roundTrips`).
- **The reverse leg is priced above the reference while `x > 0`** (below it while `x < 0`). The vault refuses it at
  1:1 floors with `PriceBelowFloor`. More generally, D14 requires `F0·F1 ≥ 1`. A trade and its reversal have the same
  average price `π`, so the two legs need `π ≥ F1` and `π ≤ 1/F0 ≤ F1`. Both hold only if `π = F1` exactly (model
  grid; SOURCE argument). In practice, with floors at the reference, `x` moves away from zero by trading and comes
  back by decay, or by a trade large enough to cross zero at an average price on the right side of the floor.
- **Sandwich.** On the curve alone a Hook B sandwich is profitable, as on any path-independent AMM (MODEL 2,000/2,000).
  The back-run is a reverse leg, so the D14 floors refuse every profitable back-run (MODEL; OBSERVED
  `test_TP_sandwich_minimumProtectsVictim_floorStopsBackRun`). The front-run still worsens the victim's price.
  Only a minimum output protects the victim (§6).
- **Hook A** has no reverse leg. Each direction has its own level, so pushing a level up costs the attacker the
  higher rate, and exiting pays the other direction's fee (`test_ADV_hookA_pushLevel_costsAttacker`,
  `test_ADV_hookA_sandwichUnprofitable`).
- **Stale reference price** (Hook B, 1:1 fixture, market above `P`): LP loss at market 24.88 at +1% (the arbitrageur
  stops at `x` = 4,962.8, where the marginal price meets the market), 394.59 at +5% and 4,828.19 at +50% (both stopped by
  the cap at 9,852.5). These match the model to the wei (`test_ADV_hookB_staleReference_lossBoundedByCap`). The cap
  bounds the loss **per decay window**, not in total. Hook A's fee never exceeds `max`, so only the vault's flow
  limits stop a stale-price arbitrage there (`test_ADV_hookA_staleReference_boundedOnlyByVaultLimits`).
- **Zero spread at the reference.** Hook B's first unit in either direction trades at exactly `P`. If the floors
  pivot exactly at `P` and `P` is a rounded value (6/18-decimal pairs), small trades can fall on the wrong side of the
  floor by rounding. The 6/18 fixture needed a depth in currency1 units (`HookPriceBands6x18Test.setUp`). Configure `P`
  strictly inside the floors, or accept that the curve's impact is what keeps trades inside them.

## 6. Trader protection (Stage 5)

- **Exact input only**; exact output is refused before pricing (`test_TP_exactOutputRefused`).
- **`sqrtPriceLimitX96` is ignored.** The hook takes the whole amount, so the PoolManager calls `Pool.swap` with
  `amountToSwap = 0`. That returns at `Pool.sol:320`, before the price-limit checks at lines 322 onward (pinned
  v4-core), and the pool price never moves. Confirmed in both directions with limits the native curve would reject
  (`test_TP_priceLimitIgnoredBothDirections`, `test_priceLimitIsNotEnforcedForFullyInterceptedSwaps`).
- **Optional minimum in `hookData`**: `abi.encode(allocationId, minAmountOut)` (64 bytes) reverts with
  `InsufficientOutput(amountOut, minAmountOut)` before any mint or vault call; 32 bytes sets no minimum; any other
  length reverts `InvalidHookData`. Exact boundary: a minimum equal to the quote passes, one more unit reverts
  (`test_TP_hookDataMinimum_exactBoundary`, `test_PA_pricing_hookDataMinimum`). **This protects only integrations that
  encode it; it is not universal slippage protection.**
- **A real router's own minimum works.** The v4 periphery `V4Router` logic, through its `MockV4Router` harness and the
  real PoolManager, enforces `amountOutMinimum` on the hook's output, because the output reaches the swapper as an
  ordinary delta. Boundary on both sides: `V4TooLittleReceived(q + 1, q)`, then exactly `q` received
  (`test_TP_v4RouterAmountOutMinimum`).

## 7. Tests, invariants and mutation (OBSERVED)

New and changed suites (all through the real pinned PoolManager and the production hook builds):

| Suite | Tests | What it covers |
|---|---|---|
| `test/unit/CumulativePricing.t.sol` | 13 | every Python vector; inverse exactness, cap exactness, monotonicity, decay fuzz; overflow reverts instead of wrapping |
| `test/integration/CumulativePricing.t.sol` | 20 | model scenarios A and B end to end (outputs, cap and floor refusals, state); Hook B (8); Hook A (5); trader protection (5) |
| `test/security/PricingAdversarial.t.sol` | 13 | §4–5 attacks, extremes (`2^127 − 1` input, depth 1,000 and `2^95 − 1`), level overflow, unpaid settlement, cross-hook limits |
| `test/integration/TradeSplitting.t.sol` | 4 | inverted characterisation (§8 of `TRADE_SPLITTING.md`) |
| `test/bench/ProductionArtifactSecurity.t.sol` | +4 (25) | split invariance, aggregate cap, round trips, `hookData` minimum on artifact-deployed hooks through the ABI |
| `test/invariant/VaultInvariants.t.sol` | +3 (35) | new actions `pricingSwap`, `hookReconfigure`; INV-P2, INV-P4, progress test |
| existing suites | updated | exact outputs; Hook B reversals warp past the decay window; deeper Hook B for LP-accounting suites; 6/18 depth |

**INV-P2**: Hook A's two levels and Hook B's position equal an independent replay of every successful swap and
reconfiguration (decay and rescaling rewritten in the handler), checked after every call and at every swap.
**INV-P4**: no successful swap leaves `|x|` beyond the cap unless it moved toward zero. Every previous invariant runs
unchanged. INV-P3 from the plan (input received ≥ telescoped cost, decay off) is not implemented as an invariant; the
same property is asserted exactly by the scenario tests and the model.

### 7.1 Mutation testing

Script: `mutate.py` (kept outside the repository), run in a scratch copy with `lib/` symlinked. Each mutant is one
asserted textual replacement; `forge test --fail-fast` runs the whole default-profile suite once per mutant. The
real tree was never modified, and each copy's `src/` matched HEAD again afterwards (`diff -rq`).

| id | file | mutation | result | first failing test |
|---|---|---|---|---|
| L1 | `CumulativePricing.sol` | decay rounds up (less state kept) | killed | `test_model_hookA_scenario` |
| L2 | `CumulativePricing.sol` | decay disabled | killed | `test_model_hookA_scenario` |
| L3 | `CumulativePricing.sol` | Hook A fee rounds down below K | killed | `test_model_hookA_scenario` |
| L4 | `CumulativePricing.sol` | Hook B cost rounds down for x >= 0 | killed | `test_model_hookB_scenario` |
| L5 | `CumulativePricing.sol` | Hook B cost of a negative position rounds toward zero | killed | `test_model_hookB_scenario` |
| L6 | `CumulativePricing.sol` | inverse rounds up for a positive cost | killed | `test_model_hookB_scenario` |
| L7 | `CumulativePricing.sol` | cap one unit too high | killed | `test_model_hookB_scenario` |
| L8 | `CumulativePricing.sol` | cap root not corrected upward | killed | `test_model_hookB_scenario` |
| A1 | `HookA_DynamicFee.sol` | level never stored | killed | `test_model_hookA_scenario` |
| A2 | `HookA_DynamicFee.sol` | fee from level 0 every trade (per-trade pricing) | killed | `test_model_hookA_scenario` |
| A3 | `HookA_DynamicFee.sol` | level not decayed | killed | `test_model_hookA_scenario` |
| A4 | `HookA_DynamicFee.sol` | configure does not settle decay | killed | `test_HAP_parameterTightening` |
| A5 | `HookA_DynamicFee.sol` | selling currency1 uses scale0 | killed | `test_model_hookA_scenario` |
| A6 | `HookA_DynamicFee.sol` | level overflow check off | killed | `test_ADV_hookA_levelOverflowRefused` |
| B1 | `HookB_BoundedImpact.sol` | position never stored | killed | `test_model_hookB_scenario` |
| B2 | `HookB_BoundedImpact.sol` | cap check one unit late | killed | `test_hookB_impactBound` |
| B3 | `HookB_BoundedImpact.sol` | negative cap not enforced | killed | `test_HBP_negativeCapIsAggregate` |
| B4 | `HookB_BoundedImpact.sol` | decay loses the sign of a negative position | killed | `test_model_hookB_scenario` |
| B5 | `HookB_BoundedImpact.sol` | depth change does not rescale | killed | `test_HBP_parameterChanges` |
| B6 | `HookB_BoundedImpact.sol` | one extra unit of input credit per trade (per-piece rounding) | killed | `test_model_hookB_scenario` |
| B7 | `HookB_BoundedImpact.sol` | configure resets the position | killed | `test_ADV_hookB_priceChangeKeepsPosition` |
| H1 | `BaseCompatibleHook.sol` | minimum output ignored | killed | `test_PA_pricing_hookDataMinimum` |
| H2 | `BaseCompatibleHook.sol` | state stored before the vault fills the trade (equivalent: the swap is atomic) | survived (equivalent) | — |
| H3 | `BaseCompatibleHook.sol` | 64-byte hookData reads the minimum as the allocation | killed | `test_PA_pricing_hookDataMinimum` |

**23 of 24 killed; H2 survives and is equivalent.** H2 writes the pricing state before
`vault.exchange` instead of after it. The swap is one atomic call, so any later revert also undoes the early
write, and nothing reads the state in between (the vault does not call back into the hook). Writing after the
exchange is kept because it does not rely on that reasoning.

The first campaign's result parser treated a fuzz failure (whose `[FAIL: ...]` bracket contains `args=[...]`)
as a pass and reported L3 as surviving. The parser was corrected before the re-runs. The correction cannot
turn a reported kill into a survival, because every other kill already had a named failing test.

The campaign's copy was taken at `ddf208e`: `src/` identical to HEAD, the test tree without the gas benchmarks of
`b4a82d3` and the handler fix of `0b14391` (455 tests). Later commits only add tests or change the invariant handler,
so a mutant killed there stays killed unless its only killer was the handler. A4 was killed by the handler's progress
test, so A4, L3 and H2 were re-run against a copy of HEAD (460 tests); the table shows those re-runs.

## 8. Economic analysis (Stage 7, SYNTHETIC)

`python3 simulations/pricing/economics.py`: 6 regimes × 3 seeds × 4,000 generated orders, **identical sequences for
every rule**, deterministic (same output on repeated runs). The fixture parameters are used (old: 10,000-token
allocations refreshed when exhausted, refused or 24 h old; new: Hook A 5→50 bps over K = 10,000, Hook B depth
1,000,000 with a 2% cap, both decaying over 1 h). Vault floors are 1:1 and the vault holds 1,000,000 of each token;
vault flow limits are not modelled. Fills are valued at the market price at that moment.

Columns: *LP rev/seed* is the value the vault received minus the value it paid, at market, in currency0 tokens,
averaged over seeds; *rev bps* is that per unit of filled notional; *arb P&L/seed* is the LP revenue from
arbitrage fills alone (negative = LP loss); *split disc bps* is what splitting saved splitters per unit of split
notional; *refusals* are summed over the three seeds.

| regime | rule | fill% | LP rev/seed | rev bps | arb P&L/seed | max|inv1| | split disc bps | worst seed rev | refusals (all seeds) |
|---|---|---|---|---|---|---|---|---|---|
| balanced | A old | 99.95 | 7,692.68 | 29.60 | 0.00 | 157,531.58 | n/a | 7,520.01 | {'QuotaExceeded': 6} |
| balanced | A new | 100.00 | 4,240.91 | 16.15 | 0.00 | 159,984.83 | n/a | 3,637.38 | {} |
| balanced | B old | 99.95 | 7,628.99 | 29.35 | 0.00 | 157,402.45 | n/a | 7,367.94 | {'QuotaExceeded': 6} |
| balanced | B new | 63.17 | 7,106.51 | 39.42 | 0.00 | 259,755.00 | n/a | 6,417.22 | {'PriceBelowFloor': 4389, 'ImpactBoundExceeded': 31} |
| one-sided (80% one way) | A old | 99.96 | 7,802.86 | 29.70 | 0.00 | 154,883.35 | n/a | 7,750.95 | {'QuotaExceeded': 5} |
| one-sided (80% one way) | A new | 100.00 | 5,161.50 | 19.49 | 0.00 | 169,238.09 | n/a | 4,887.12 | {} |
| one-sided (80% one way) | B old | 99.96 | 7,842.98 | 29.85 | 0.00 | 154,763.85 | n/a | 7,742.22 | {'QuotaExceeded': 5} |
| one-sided (80% one way) | B new | 67.31 | 9,545.11 | 51.68 | 0.00 | 318,624.37 | n/a | 9,439.01 | {'PriceBelowFloor': 3857, 'ImpactBoundExceeded': 66} |
| whales (5% x 8,000 median) | A old | 98.05 | 9,240.35 | 30.35 | 0.00 | 114,967.39 | n/a | 9,035.27 | {'QuotaExceeded': 234} |
| whales (5% x 8,000 median) | A new | 99.99 | 24,196.79 | 48.79 | 0.00 | 848,394.96 | n/a | 22,687.05 | {'InsufficientInventory': 1} |
| whales (5% x 8,000 median) | B old | 98.08 | 11,152.22 | 36.51 | 0.00 | 115,476.34 | n/a | 10,805.24 | {'ImpactBoundExceeded': 103, 'QuotaExceeded': 128} |
| whales (5% x 8,000 median) | B new | 58.67 | 10,526.27 | 54.42 | 0.00 | 241,303.10 | n/a | 10,179.94 | {'PriceBelowFloor': 4650, 'ImpactBoundExceeded': 310} |
| splitters (50% split 5-10) | A old | 99.97 | 7,581.25 | 28.70 | 0.00 | 108,274.16 | 0.50 | 7,410.64 | {'QuotaExceeded': 3} |
| splitters (50% split 5-10) | A new | 100.00 | 4,183.93 | 15.76 | 0.00 | 118,482.20 | 0.00 | 4,042.16 | {} |
| splitters (50% split 5-10) | B old | 99.97 | 4,985.49 | 18.87 | 0.00 | 107,014.42 | 10.14 | 4,734.77 | {'QuotaExceeded': 3} |
| splitters (50% split 5-10) | B new | 62.46 | 6,509.97 | 38.19 | 0.00 | 132,743.16 | 0.00 | 6,387.05 | {'PriceBelowFloor': 4479, 'ImpactBoundExceeded': 26} |
| stale drift + arbitrage | A old | 73.53 | -10,180.94 | -15.46 | -61,211.44 | 1,025,042.85 | n/a | -17,997.32 | {'InsufficientInventory': 14038, 'QuotaExceeded': 6} |
| stale drift + arbitrage | A new | 74.22 | 1,089.87 | 1.68 | -51,804.16 | 1,041,276.14 | n/a | -1,719.86 | {'InsufficientInventory': 13731} |
| stale drift + arbitrage | B old | 74.13 | -19,188.39 | -33.33 | -70,025.05 | 1,016,223.27 | n/a | -36,495.60 | {'InsufficientInventory': 13626, 'QuotaExceeded': 5, 'ImpactBoundExceeded': 1} |
| stale drift + arbitrage | B new | 35.73 | -36,459.20 | -190.19 | -37,730.03 | 999,999.96 | n/a | -61,802.30 | {'PriceBelowFloor': 5692, 'ImpactBoundExceeded': 1925, 'InsufficientInventory': 2652} |
| stale jump +2% + arbitrage | A old | 80.33 | -9,688.38 | -26.56 | -30,416.49 | 999,999.96 | n/a | -10,659.70 | {'InsufficientInventory': 10694, 'QuotaExceeded': 7} |
| stale jump +2% + arbitrage | A new | 80.39 | -7,874.93 | -21.37 | -26,948.68 | 999,999.92 | n/a | -8,881.21 | {'InsufficientInventory': 10693} |
| stale jump +2% + arbitrage | B old | 80.22 | -10,433.34 | -28.61 | -30,880.19 | 999,999.98 | n/a | -11,396.71 | {'InsufficientInventory': 10707, 'QuotaExceeded': 6, 'ImpactBoundExceeded': 1} |
| stale jump +2% + arbitrage | B new | 40.84 | 2,333.76 | 12.30 | -1,948.10 | 999,995.05 | n/a | 1,990.42 | {'PriceBelowFloor': 5098, 'ImpactBoundExceeded': 1705, 'InsufficientInventory': 2418} |

Parameter sensitivity (new rules only; same sequences):

| regime | setting | fill% | LP rev/seed | rev bps | arb P&L/seed | max|inv1| | split disc bps | worst seed rev |
|---|---|---|---|---|---|---|---|---|
| balanced | B depth 500,000 | 47.52 | 10,559.90 | 99.04 | 0.00 | 326,366.97 | n/a | 10,517.25 |
| balanced | B depth 1,000,000 | 63.17 | 7,106.51 | 39.42 | 0.00 | 259,755.00 | n/a | 6,417.22 |
| balanced | B depth 2,000,000 | 79.67 | 2,863.57 | 12.74 | 0.00 | 184,852.50 | n/a | 2,605.09 |
| balanced | B depth 1,000,000, decay 600 s | 92.88 | 4,355.21 | 17.62 | 0.00 | 164,616.42 | n/a | 4,238.57 |
| balanced | B depth 1,000,000, decay 14400 s | 35.73 | 9,039.66 | 175.82 | 0.00 | 518,717.28 | n/a | 8,893.12 |
| balanced | A max 5000 pips | 100.00 | 4,240.91 | 16.15 | 0.00 | 159,984.83 | n/a | 3,637.38 |
| balanced | A max 9500 pips | 100.00 | 7,169.24 | 27.31 | 0.00 | 161,084.47 | n/a | 5,976.87 |
| stale jump +2% + arbitrage | B depth 500,000 | 23.79 | 2,243.68 | 21.73 | -688.18 | 670,897.76 | n/a | 2,033.75 |
| stale jump +2% + arbitrage | B depth 1,000,000 | 40.84 | 2,333.76 | 12.30 | -1,948.10 | 999,995.05 | n/a | 1,990.42 |
| stale jump +2% + arbitrage | B depth 2,000,000 | 63.99 | 1,805.12 | 6.73 | -2,409.04 | 999,998.93 | n/a | 1,581.22 |
| stale jump +2% + arbitrage | B depth 1,000,000, decay 600 s | 84.28 | 346.58 | 1.05 | -7,262.18 | 999,998.67 | n/a | 255.29 |
| stale jump +2% + arbitrage | B depth 1,000,000, decay 14400 s | 15.59 | 2,237.67 | 42.26 | -419.88 | 217,506.67 | n/a | 2,207.52 |
| stale jump +2% + arbitrage | A max 5000 pips | 80.39 | -7,874.93 | -21.37 | -26,948.68 | 999,999.92 | n/a | -8,881.21 |
| stale jump +2% + arbitrage | A max 9500 pips | 80.30 | 2,876.94 | 7.79 | -18,761.79 | 999,999.94 | n/a | 1,900.30 |

Findings (synthetic, under these assumptions only):

- **Splitting discount removed.** Old Hook A 0.50 bps and old Hook B 10.14 bps of split notional; both new rules
  0.00 exactly.
- **Hook A revenue at the same fee parameters is about half the old** in static regimes (16–19 vs 29–30 bps). The
  integral charges less than "post-trade utilisation on the whole trade", as the spec predicted. With `max` 9,500
  pips it is 27 bps. With whales the new rule earns more (48.8 bps), because flow accumulates across allocations
  instead of resetting with them.
- **Hook B fill rate falls** to 59–67% in static regimes (old: 98–100%). The refusals are `PriceBelowFloor` on reverse
  legs (§5). Revenue per filled notional rises (38–54 vs 19–37 bps).
- **Stale price.** After a +2% jump, the new Hook B is the only rule with positive LP revenue (+2,334 per seed; old
  B −10,433), and its arbitrage loss is 1,948 vs 30,880. Under a sustained drift its total LP revenue is worse than
  the old rule's (−36,459 vs −19,188), although its arbitrage loss is lower (−37,730 vs −70,025). It refuses most
  ordinary two-way flow while the drift keeps its position away from zero. **Worst regime for the new Hook B: stale
  drift.** For Hook A, every rule loses to arbitrage in both stale regimes, because its fee cannot exceed `max`;
  total LP revenue is positive only for the new rule under drift (+1,090 per seed, −1,720 in its worst
  seed).
- **Decay window is the main lever.** Hook B at 600 s fills 92.9% in the balanced regime at 17.6 bps, but loses
  7,262 to the +2% arbitrage. At 4 h it fills 35.7% at 175.8 bps and loses 420. Larger depth fills more and earns
  less per unit. No setting is best on every axis. These numbers are not a recommendation, and no parameter was
  chosen on revenue.

### 8.1 Decision needed: Hook B reverse legs

The approved signed model and the vault's D14 rule together refuse Hook B's reverse legs until the position decays.
Options, none implemented:

1. **Accept**, and choose the decay window for the expected flow (shorter window: more two-way flow, more stale-price
   exposure per hour).
2. **Price the reverse leg at the floor when the curve is above it**: the hook pays `min(curve output, floor output)`
   and the vault keeps the difference. Splits still cannot gain (`Σ min ≤ min Σ`), but the state then no longer
   telescopes in that direction. That needs a new model check.
3. **Per-direction gross state for Hook B** (as Hook A). Round trips then pay impact twice, which the spec rejected.

## 9. Gas and bytecode (OBSERVED)

Production artifacts (`bash test/bench/run.sh`, via-IR, cancun, `bytecode_hash = "none"`). Sizes in bytes.

| Contract | Runtime before | Runtime after | Init after | EIP-170 margin |
|---|---|---|---|---|
| `SharedCommitmentVault` (2,000 runs) | 22,049 | **22,049** | 22,658 | 2,527 |
| `HookA_DynamicFee` | 7,174 | 8,576 | 9,406 | 16,000 |
| `HookB_BoundedImpact` | 6,884 | 9,165 | 9,995 | 15,411 |
| `CuratorAuthorization` | 7,409 | 7,409 | 8,587 | 17,167 |
| `VaultLens` | 6,972 | 6,972 | 6,998 | 17,604 |

The vault's runtime keccak (`0x5ab6d06f…db2b1e`) and init-code keccak (`0xcd95dfdd…e31787`) equal the hardening
baseline, and so do its ABI and storage layout. `CuratorAuthorization` and `VaultLens` are also byte-identical.

Gas, `forge test --isolate`, `gasleft()` around one external call through `PoolSwapTest`, PoolManager, hook and vault:

| Operation | Gas |
|---|---|
| native v4 swap (no hook), reference | 150,303 |
| Hook A swap, first in a direction (previously 239,693) | 262,580 |
| Hook A swap, other direction, first | 262,855 |
| Hook A swap, same direction after 60 s (steady state) | 239,071 |
| Hook B swap, asset1 in, first on the pool (previously 239,597) | 244,885 |
| Hook B swap, asset0 in, first on the pool | 253,582 |
| Hook B swap, second on the pool after 60 s | 253,611 |
| split, Hook A: 1 × 1,000 vs 10 × 100 | 262,045 vs 2,408,725 |
| split, Hook B: 1 × 1,000 vs 10 × 100 | 244,514 vs 2,387,594 |
| failed swap: Hook B cap / `hookData` minimum / vault floor | 82,691 / 92,339 / 142,519 |
| `quote`: Hook A / Hook B asset1 in / Hook B asset0 in (inverse) | 21,751 / 18,942 / 21,471 |

The first swap in a direction writes a zero storage slot (about 20,000 more than a later write); in steady state Hook A
costs about the same as before. A split pays the full per-swap cost for every piece, on top of paying the same pricing.
Failures revert before the vault moves anything. Every non-pricing operation measured in the hardening report has the
same gas (allocation, activation, deposit, redeem, claim, queue, governance).

Measurement caveat: the second Hook B swap measures 253,611 against 244,885 for the first, but their execution traces
are 236,162 and 235,968. The ~9,000 difference comes from how the isolated transaction's gas is accounted (the
benchmark's warm/cold set-up), not from extra execution in the hook, and was not investigated further.

## 10. Validation

Foundry 1.7.1, solc 0.8.26, Slither 0.11.6, Python 3.11 (standard library only). All local.

| Command | Result |
|---|---|
| `forge fmt --check` | clean |
| `forge build` | success |
| `forge test` (default profile, 1,000 fuzz runs, invariants 64 × 64) | 460 passed, 0 failed, 37 suites |
| `bash test/bench/security.sh` (`FOUNDRY_PROFILE=ci`, 10,000 fuzz runs, forced rebuild) | exit 0; size gate passed; `ProductionArtifactSecurity` 25/25; full suite 460/460 |
| `bash test/bench/run.sh` | exit 0; sizes and gas in §9 |
| `FOUNDRY_INVARIANT_FAIL_ON_REVERT=true FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-contract VaultInvariantsTest -vv` | 35/35: 30 invariants × 32,768 calls, 0 reverts; 5 handler progress tests, including `test_handler_pricingProgress` |
| `python3 simulations/pricing/test_cumulative.py` | 22/22 checks OK |
| `python3 simulations/pricing/vectors.py` | regenerates `test/utils/PricingVectors.sol` byte-identically |
| `python3 simulations/pricing/economics.py` | §8 tables; identical output on repeated runs |
| `slither . --filter-paths "lib/\|test/" --exclude-dependencies` | 39 results vs 32 at `4dcf4bd` (baseline rebuilt in a temporary worktree, since removed) |
| mutation script (§7.1) | 23 of 24 killed; H2 equivalent |
| vault bytecode, ABI, storage layout vs `4dcf4bd` | identical |

Slither (compared without line numbers): 7 new results and one reworded existing result, all in the hooks.

- Three `uninitialized-local`. `allocationId` and `minAmountOut` in `beforeSwap` are assigned from `hookData` for
  both accepted lengths (32 and 64 bytes); every other length reverts. A 32-byte `hookData` leaves `minAmountOut` at
  0, meaning no minimum, by design. `x` in Hook B's `configurePool` is 0 for a pool configured for the first time,
  which is the intended starting position.
- One `incorrect-equality`: `amountOut == 0` is the intended refusal of a zero-output swap.
- Three `timestamp`. Slither flags comparisons whose operands come from the decayed state: the level overflow check,
  the sign of `x`, and the cap check. Decay uses `block.timestamp` only as elapsed time. A validator can shift that by
  seconds, which changes the decay by `rate × seconds / window`, a bounded amount in either direction.
- `reentrancy-events` on `beforeSwap` now lists the `_commit` storage write before the event. The external calls go
  to the PoolManager and the vault, both trusted, and `beforeSwap` is `onlyPoolManager`.

No finding needed a code change.

The invariant handler originally could overflow its allocation-search seed (about 10 handler reverts per campaign with
`fail_on_revert` off); `0b14391` fixed it, and the campaign above runs with `fail_on_revert = true`.

## 11. Residual risks and tests not run

- **Hook B reverse legs** are refused under D14 floors until decay (§8.1). Safe; reduces fills.
- **Stale reference price** is not fixed by any pricing rule. The cap bounds Hook B's loss per decay window; Hook A is
  bounded only by the vault's limits. `P` updates are immediate and owner-trusted (P-4 not started).
- **`hookOwner` is trusted.** No loosening delay (D-P3 deferred). A larger depth, a lower fee or a longer window
  takes effect at once.
- **Cross-hook splitting** is bounded only by vault flow limits.
- **Hook B has no spread at `x = 0`**; with floors exactly at a rounded `P`, small trades depend on rounding (§5).
- **Rounding, all against the trader**: Hook A split ≤ n − 1 units; waiting can raise a Hook A fee by one unit; Hook B
  flat steps where currency1 is cheaper than one raw currency0 (value < (1 + m) raw currency0 per sequence); decay
  forgets less than one unit per update.
- **Gas measurement**: the steady-state Hook B swap measures 253,611 by the benchmark's `gasleft()` method against
  244,885 for the first swap, while their execution traces are 236,162 and 235,968. The difference comes from how
  the isolated transaction is accounted, not from extra execution; it was not investigated further (§9).
- Not run: Unichain fork tests, testnet deployment, an independent review, remote CI (the GitHub account billing lock
  reported in the hardening report is unrelated to this branch and was not re-checked), historical-data simulations.
- The economic analysis is synthetic, omits vault flow limits, gas and multiple pools, and uses one curator refresh
  rule for the old pricing. It compares rules; it does not estimate real revenue.

## 12. Next action requiring human approval

1. Review the pricing rules and the departures in §2.4.
2. Decide on Hook B reverse legs (§8.1) and on the decay windows and depths for any deployment.
3. Decide whether a loosening delay for hook parameters (D-P3) is required before testnet.
4. Approve (or not) merging this branch; nothing has been pushed.
