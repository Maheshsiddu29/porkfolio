# Porkfolio — Phase 1B-4: Why Hook B Refuses Inventory-Reducing Trades

**Status: ANALYSIS (no production code changed).** Branch `research/adaptive-market-making` from
`phase-1b-3-cumulative-pricing` at `eaf3eff`. Labels follow the earlier reports: SOURCE (read from the code at
`eaf3eff`), OBSERVED (asserted by a named test on the production artifacts), MODEL (exact integer Python model),
SYNTHETIC (generated order sequences; not market data).

Reproduce:

```
python3 simulations/mm/rootcause.py                                  # parts 1 and 2 below
forge test --match-contract HookBRootCauseTest -vv                  # the same mechanisms on the real PoolManager
```

## 1. The system as it is (SOURCE)

| Component | What it does today | Where it matters for pricing |
|---|---|---|
| `SharedCommitmentVault` | Two-asset reserve held as ERC-6909 claims. `B_a` backing, `W_a` claimable, `N_a = B_a − W_a`, `Q_a` reserved, `F_a = N_a − Q_a` free. | Real inventory is `N_0`, `N_1`. Trades move `B_a` by the exact claim amounts. |
| ERC-6909 settlement | Hook mints input claims, `exchange` pulls them and pushes output claims, hook burns output; the PoolManager requires zero deltas. | Atomic: any failure reverts the whole swap, including the hook's pricing state. |
| Allocations | Curator reserves `maxOut` of one asset for one hook, pool and direction, with a curator floor, until an expiry. | A reverse trade needs a live allocation **in the reverse direction**. |
| Floors | Per direction, `F_sell0` (raw currency1 in per raw currency0 out) and `F_sell1`, with `F_sell0 · F_sell1 ≥ 2^192` (D14). Effective floor = max(vault, curator). | A D14 pair is a single pivot `K` or a no-trade gap: the vault never sells currency1 below `K` and never buys it above `K`. |
| Flow caps | Gross output per scope (hook, curator, vault) per fixed one-day epoch; inflows never net. | Bounds how fast either direction can drain an asset. |
| Exposure caps | Unused reserved capacity per scope, in bps of eligible backing. | Bounds how much can be committed, not the price. |
| LP exits | In-kind, pro rata; instant if free inventory suffices, else queued; `D_a` protects queued demand from new allocations. | LP flows change `N_0` and `N_1` in proportion, so they leave the composition unchanged. |
| Hook A | Fixed reference `P`; cumulative fee on gross input per direction, decaying linearly. | No inventory state; the price never moves with what the vault holds. |
| Hook B | One signed position `x` per pool (currency1 sold minus bought back) on a constant-product curve of depth `V` around a fixed `P`; aggregate cap `|x| ≤ X_max`; `|x|` decays to zero over `decayWindow`. Zero spread: one curve prices both directions. | The subject of this document. |
| Parameters | `hookOwner` sets `P`, `V`, caps and windows, applied at once. The vault owner sets floors (guardian may only raise them). | `P` and the floors are both static between governance actions. |

## 2. The mechanism

Hook B quotes every trade from one integer function `Ĉ(x)` of its position. The marginal price of currency1 at `x` is

```
p(x) = (1/P) · (V / (V − x))²        currency0 per currency1
```

It equals the reference at `x = 0` and rises as the vault sells currency1 (`x > 0`). Because one curve prices both
directions, the price at which the vault would **buy currency1 back** at `x > 0` is the same `p(x) > 1/P`.

The vault's floors in the fixture pivot at `K = P`. A D14 pair can never be looser than a single pivot: if the vault
could sell currency1 below `K` and also buy it above `K`, two trades at the floors would leave it with less of both
assets, which is exactly what D14 forbids (`test_d14_floors_cannot_bracket_the_market`). So with the pivot at `P`, a
vault bid above `1/P` is always refused.

Combining the two: **whenever `x > 0`, every trade that reduces `x` is quoted above the pivot and refused**, and
symmetrically for `x < 0`. The refusal ends only when decay brings `x` close enough to zero (or a single trade crosses
zero with an average price on the right side of the pivot).

### Worked example (MODEL, OBSERVED to the wei in `test_RC_reverseIsQuotedAboveReferenceAndRefused`)

Fixture: `V` = 1,000,000 tokens, 2% cap, decay 1 h, `P` = 1, floors 1:1.

1. A trader pays 5,000 currency0 and receives 4,975.1244 currency1. `x` = 4,975.1244; marginal price 1.010025.
2. The reverse, 1,000 currency1 in, is quoted at 1,009.0109 currency0 out (average 1.009011). The vault's floor for
   selling currency0 needs `in ≥ out`: refused with `PriceBelowFloor(1000e18, 1009010944001278714891)`.
3. The same reverse passes after **1,636 s** of decay, when `x` = 497.73 (`test_RC_reversePassesOnlyAfterDecay`).
   Nothing about the vault's holdings changed during those 1,636 s.

If the floors were removed and `P` were the market price, the reverse seller would earn 9.0109 currency0 against the
market on step 2. **The curve's buy-back is itself an arbitrage, and the floor is refusing a loss, not a profitable
trade.** The floor is doing its job; the quote is wrong.

## 3. Separating the candidate causes

| # | Suspected cause | Verdict | Evidence |
|---|---|---|---|
| 1 | Pricing-curve geometry | **Primary.** One curve for both directions makes bid = ask = `p(x)`, and `p(x)` moves away from `P` with `x`. Every refusal reduces `|x|`; every refused trade would pass from `x = 0`. | Part 2: 17,186 / 17,186 refusals reduce `|x|`; 17,178 / 17,186 pass from `x = 0`. |
| 2 | Incompatible directional floors | **Primary, jointly with 1.** D14 floors are a single pivot, so any quote whose mid moves away from the pivot can trade on one side only. Moving the pivot moves the refusal to the other side. | `test_RC_movingThePivotMovesTheRefusal` (pivot 0.99: the reverse passes, an ordinary forward sale near `P` is refused). |
| 3 | Missing bid-ask spread | **Contributing.** A spread `h` lets reverse trades through only while the accumulated premium `p(x)/p(0) − 1` is below `h`. To pass every reverse inside a 2% cap needs `h ≈ 2%`. | Part 1: 10 and 30 bps still refused, 100 bps passes this example; Part 2: 30 bps lifts fills 63→83%, 200 bps to 99.9% (at a 2% spread). |
| 4 | Virtual position vs real inventory | **Independent defect, not the refusal's trigger.** `x` decays; inventory does not. 45% of refused "reverse" trades did not reduce the vault's real imbalance, and after decay inventory-increasing trades are priced as if the vault were flat. | Part 2 (45.0%); `test_RC_decayRestoresPriceNotInventory`; Part 1: 236,435 currency1 sold in 24 h with `x` never above the 9,852 cap. |
| 5 | Insufficient available backing | Not a cause of `PriceBelowFloor`. It produces `QuotaExceeded` / `InsufficientBacking` separately. | — |
| 6 | Position limits | Minor: `ImpactBoundExceeded` only when a reverse would cross past `−X_max`. | 26–310 per regime in Phase 1B-3 §8, vs 3,857–4,650 floor refusals. |
| 7 | Stale market reference | **Amplifier.** A stale `P` lets arbitrage push `x` to the cap, after which ordinary flow in the reverse direction is refused until decay. | Phase 1B-3 §8 stale regimes; `simulate.py` A0 vs A rows. |
| 8 | Constraints interacting | Yes: 1 and 2 together produce every refusal; 3 can only shift the boundary; 7 makes it bind more often. A separate, look-alike refusal comes from allocations being directional. | `test_RC_reverseNeedsAnAllocationInItsDirection` (`DirectionMismatch`). |

### Part 2: attribution over the Phase 1B-3 sequences (SYNTHETIC)

Same generator, regimes and seeds as `simulations/pricing/economics.py` (static regimes; split orders replayed as one
trade, which is why the splitter regime reads 64.00% instead of the 62.46% reported in Phase 1B-3). Each column
removes one suspected cause:

| regime | Hook B | no floors | no decay | + 30 bps spread | + 200 bps spread |
|---|---|---|---|---|---|
| balanced | 63.17 | 99.87 | 0.48 | 82.71 | 99.88 |
| one-sided (80% one way) | 67.31 | 99.62 | 0.47 | 80.41 | 99.66 |
| whales (5% × 8,000 median) | 58.67 | 97.78 | 0.47 | 73.37 | 97.88 |
| splitters (50% split 5–10) | 64.00 | 99.83 | 0.47 | 83.76 | 99.85 |

- Removing the floors restores fills, but it would do so by paying the curve premium back to whoever trades in the
  reverse direction, which is an arbitrage against any correct reference.
- Removing decay locks the pool after the first trade in each direction (0.5% fills): decay is the only thing that
  re-opens the reverse direction in the current design.
- A spread is not a fix unless it is as large as the cap.

## 4. Conclusion

The refusal is a structural consequence of **pricing both directions from one inventory-moving mid with no spread,
against floors that are a fixed pivot**. It is not a parameter problem: any decay window, depth or cap only moves
where the boundary falls. The vault's floor is correct to refuse these quotes.

A second, independent defect matters as much for the long-term design. Hook B's state is decaying trading pressure,
not exposure, so the price returns to the reference while the vault's inventory stays skewed.

A design that fixes both has to:

1. quote bid and ask separately, with the bid never above, and the ask never below, a reference mid (then any floor
   pivoted at that mid accepts both sides);
2. measure the vault's **real** inventory, not a decaying proxy, if it is to price inventory risk at all;
3. keep the reference, and the floor pivot, close to the market, because a static pivot reintroduces the one-sided
   refusal as soon as the market moves.

`MARKET_MAKING_CANDIDATES.md` compares designs against these requirements; `INVENTORY_PRICING_SPEC.md` specifies the
recommended one.
