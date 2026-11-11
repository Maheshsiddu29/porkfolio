# Porkfolio — Inventory Pricing Specification (candidate C)

**Status: PROPOSED, not implemented.** The integer reference implementation is `simulations/mm/model.py`
(`quote_inventory`, `resolve_reference`). Conformance vectors are in `simulations/mm/vectors/inventory_quote_v1.json`.
Every claim marked (T) is checked by `simulations/mm/test_mm.py`. Where this text and the model differ, the model is
the reference until the owner approves this document.

## 1. Purpose and scope

A pricing core that every hook drawing on one `SharedCommitmentVault` reserve uses to quote exact-input swaps:

- two-sided, with an explicit bid and ask around an external reference;
- skewed by the vault's **real** inventory, read from the vault;
- refusing, never substituting, when the reference is missing or inconsistent;
- leaving every vault rule (floors, quota, flow and exposure caps, halts) authoritative.

It holds no state of its own. It needs no change to the vault. It does not choose allocations, route orders or set
floors.

## 2. Inputs

| Symbol | Meaning | Units | Source |
|---|---|---|---|
| `N_0, N_1` | net assets `backing − claimableAssets` | raw | vault getters, read in the swap |
| `S` | `totalShares` | shares | vault getter |
| `M` | reference mid | raw currency1 per raw currency0, Q64.96 | reference resolution (§3) |
| `u` | reference uncertainty | pips | §3 |
| `τ` | target currency1 per share | WAD | configuration |
| `v` | depth per share | WAD | configuration, derived (§5) |
| `V_max` | absolute depth cap | raw currency1, `≤ 2^95 − 1` | configuration |
| `h_base`, `h_min`, `h_max` | base half-spread, minimum edge, largest accepted half-spread | pips | configuration; `h_min < h_base ≤ h_max < 10^6` |
| `δ_max` | inventory cap | pips of `T_1` | configuration |

Derived:

```
T_1 = floor(S · τ / 10^18)                  target currency1 holdings
I   = T_1 − N_1                             deviation; I > 0: the vault is short currency1
V   = min(V_max, floor(S · v / 10^18))      curve depth
h   = h_base + u                            half-spread on both sides (a hook may add its own policy term)
```

Why these coordinates. LP deposits and redemptions are proportional baskets, so they scale `N_1`, `T_1` and `V` by the
same factor (up to one unit of rounding each): they cannot move the price (T, `test_lp_flows_do_not_move_the_price`).
A trade moves `N_1`, and so `I`, by exactly the currency1 it moves. Nothing decays. Waiting changes nothing
(T, `test_time_does_not_change_the_price`).

## 3. Reference resolution

```
primary   (p, t_p)      must exist (p > 0), t_p ≤ now, now − t_p ≤ max_age          else refuse
secondary (q, t_q)      used if q > 0 and now − t_q ≤ secondary_max_age
divergence d = ceil(|p − q| · 10^6 / min(p, q))   refuse if d > max_divergence
u = ceil(age_widen · (now − t_p) / max_age) + (d, or missing_penalty, or refuse if require_secondary)
    + realized-volatility term (below)
M = p
```

Realized volatility, from the primary's last `k` rounds `(p_i, t_i)`, oldest first:

```
r_i   = ceil(|p_i − p_{i−1}| · 10^6 / min(p_i, p_{i−1}))          pips
var   = ceil( mean_i ceil(r_i² / max(1, t_i − t_{i−1})) )          pips² per second
term  = ceil( vol_mult / 100 · isqrt(var · horizon) )              pips
```

Example: rounds 0.2% apart every 60 s give `r` = 2,000, `var` = 66,667 and, over a 300 s horizon at `vol_mult` = 100,
`isqrt(2·10^7)` = 4,472, so the term is 4,473 pips. A push feed updates on deviation, so in a fast market its rounds
are close together and the term rises; in a calm one the rounds are spaced by the heartbeat and the term is small.
Calibrated: `vol_mult` = 50, horizon 300 s, four rounds (§9).

The conversion of a feed answer to `M` (decimals of the feed and of both tokens, and inversion when the feed quotes
currency0 in currency1) is part of the adapter specification in milestone M2. It rounds down, and it fails closed on
a non-positive answer.

## 4. The potential

Inside the cap `c` (§5) the potential is Hook B's curve, evaluated at the inventory instead of a decaying position:

```
C(I) = V · I · 2^96 / (M · (V − I))           currency0 owed for a net sale of I currency1, |I| ≤ c
```

The marginal mid is `(2^96/M) · (V / (V − I))²` currency0 per currency1: the reference at `I = 0`, higher when the vault
is short currency1, lower when it is long. Outside `[−c, c]` the potential continues linearly with the edge slope:

```
I >  c:   C(I) =  2^96 · V · (I·V − c²) / (M · (V − c)²)
I < −c:   C(I) = −2^96 · V · (|I|·V + c²) / (M · (V + c)²)
```

Both forms equal `C(±c)` at the edge. The integer potential is one function, `Ĉ(I) = ceil(C(I))`. Every trade is
priced as a difference of two of its values, so trades telescope (§6).

Why extend linearly instead of refusing outside the cap. Parameters can change (a smaller `δ_max`, a different `h`),
and shares can leave, so the vault can find itself beyond the cap without having traded there. Refusing to price
would block exactly the trades that reduce the imbalance (the root cause, again). The linear extension prices them at
the edge's marginal bid, which still respects the straddle (T,
`test_inward_trades_from_beyond_the_cap_are_priced_and_straddle`).

## 5. Spread, cap and depth

**Straddle cap.** `c(V, h, h_min)` is the largest `c` with both

```
(1 − h) · (V / (V − c))² ≤ 1 − h_min       (bid at +c is at most M(1 − h_min))
(1 + h) · (V / (V + c))² ≥ 1 + h_min       (ask at −c is at least M(1 + h_min))
```

computed exactly in integers (`straddle_cap`: an `isqrt` start and at most a few correction steps per side; the ask
side is always the tighter one). The applied cap is `c = min(c(V, h, h_min), floor(T_1 · δ_max / 10^6))`.

**Depth is derived, not tuned.** The skew can use at most the spread, so the depth must be large enough that the
straddle cap at `h_base` reaches the risk cap:
`v = depth_per_share_for(τ, δ_max, h_base, h_min)`, about `2·δ_max·τ / (h_base − h_min)`. Calibrated values
(`h_base` = 20 bps, `h_min` = 1 bp, `δ_max` = 15%) give `v` = 158.0012892772015 WAD. For a vault with 1,000,000 of
each token that is `V` ≈ 1.58·10^8 tokens, and the straddle cap at `u = 0` is 150,015 tokens (the risk cap, 150,000,
binds). Wider uncertainty enlarges the straddle cap (at `u` = 500 pips it is 189,469 tokens), so the risk cap stays
the binding one and the skew per token falls as uncertainty rises.

Bound: `V ≤ 2^95 − 1` caps `I_max ≈ V·(h − h_min)/2`. At a 10 bp gap that is about 1.98·10^25 raw, i.e. 19.8 million
18-decimal tokens of deviation. A larger reserve needs a larger spread gap or a separate depth bound review.

## 6. Quotes (exact input)

```
vault sells currency1 (zeroForOne):
    t  = Ĉ(I) + floor(amountIn · 10^6 / (10^6 + h)) − 1
    refuse (InventoryLimit) if I ≥ c or t ≥ Ĉ(c + 1)
    I' = max{ J : Ĉ(J) ≤ t }                 (exact inverse; closed form, §7)
    out = I' − I

vault buys currency1 (oneForZero):
    I' = I − amountIn;  refuse (InventoryLimit) if I' < −c
    out = floor( (Ĉ(I) − Ĉ(I')) · (10^6 − h) / 10^6 ) − 1

refuse ZeroInput (amountIn = 0), AmountTooLarge (> 2^127 − 1), SpreadTooWide (h > h_max), NoDepth (V = 0),
ZeroOutput (out ≤ 0).
```

The `− 1` on each side. `Ĉ` is a ceiling, so `Ĉ(b) − Ĉ(a)` can exceed `C(b) − C(a)` by one raw unit. Reserving one
unit per trade makes the straddle exact for every size. Without it, a dust trade can land one wei on the trader's side
of the reference: four such cases in 3,000 random dust trades before the reserve was added; zero after it
(T, `test_dust_trades_also_straddle`).

## 7. Properties

**P-3 straddle (exact).** For any accepted trade at reference `M` (so one currency1 is worth `2^96/M` currency0):

```
ask (trader pays amountIn currency0, receives out currency1):   amountIn > out · (2^96/M) · (1 + h_min)
bid (trader pays amountIn currency1, receives out currency0):   out      < amountIn · (2^96/M) · (1 − h_min)
```

*Proof sketch (ask).* `C(I') ≤ Ĉ(I') ≤ t < C(I) + 1 + credit − 1`, so `C(I') − C(I) < credit ≤ amountIn/(1+h)`. The
potential's marginal price on `[I, I']` is at least its value at `−c` (or the edge slope beyond), which by the cap is at
least `(2^96/M)(1 + h_min)/(1 + h)`. Hence `amountIn > out · (2^96/M)(1 + h_min)`. *(Bid)* `out ≤ (Ĉ(I) − Ĉ(I'))(1 − h) − 1
< (C(I) − C(I') + 1)(1 − h) − 1 ≤ (C(I) − C(I'))(1 − h)`, and the marginal price on `[I', I]` is at most the value at
`+c`, which by the cap is at most `(2^96/M)(1 − h_min)/(1 − h)`. ∎ (T, 4,000 random quotes; 4,000 dust trades.)

**Vault floors.** With floors pivoted at `M` (`F_sell0 = M`, `F_sell1 = ceil(2^192/M)`), every accepted quote passes
`exchange`'s integer check. On the bid side this is exact. On the ask side `F_sell1`'s own ceiling adds less than
`out/2^96` raw units, which `h_min ≥ 1` pip covers (T, 3,000 cases including 1-wei to 10^21 inputs, `h_min` ∈ {1, 100}).
With `h_min = 0` a dust ask can be refused by the vault, which fails closed.

**P-1 splitting.** At fixed `(N, S, M, u)`, pieces `a_1..a_n` of one direction reach a state no further than the single
trade: `Σ(floor(a_k·k) − 1) ≤ floor(Σa_k·k) − 1`, and `I_n` is the largest state under a smaller target. The bid side is
`Σ(floor(g_k(1−h)) − 1) ≤ floor(Σg_k(1−h)) − 1`. The loss is at most a few raw units per piece
(T, 600 random partitions into 2–50 pieces; at most 16 units per piece at prices in [0.2, 5]). Because the state is the
vault's inventory, this holds across every hook that uses the same core.

**P-2 cycles.** From P-3, a closed loop in currency1 at fixed `M` buys at `≥ M(1 + h_min)` and sells at
`≤ M(1 − h_min)`, so it loses at least `2·h_min` of its volume. This holds whatever the parameters do between legs
(spread, cap, target), and across hooks with different spreads (T, `test_cycles_at_fixed_reference_always_lose`,
`test_cross_hook_cycles_lose_with_different_spreads`).

**What is not path-independent.** A change of `M` (a new reference round) changes every price. A trade before and its
reverse after an update can profit if the move exceeds `2h`. That is latency arbitrage against a lagging reference, a
market cost that `h` and `u` price. P-3 makes no claim about it.

## 8. Worked examples (MODEL; calibrated configuration, 1,000,000 of each token, `M` = 1, `u` = 0)

`V` = 158,001,289.28 tokens, `c` = 150,000 tokens. Marginal quotes: at `I = 0` ask 1.0020, bid 0.9980; at `I = +c`
ask 1.003905, bid 0.999898; at `I = −c` ask 1.000100, bid 0.996108.

| vault | trade | in | out | average (currency0 per currency1) | `I` before → after |
|---|---|---|---|---|---|
| balanced | trader buys currency1 | 10,000 c0 | 9,979.409578 c1 | 1.002063 | 0 → 9,979.41 |
| balanced | trader sells currency1 | 10,000 c1 | 9,979.368400 c0 | 0.997937 | 0 → −10,000 |
| 10% short c1 | sells currency1 (reduces) | 10,000 c1 | 9,992.012010 c0 | 0.999201 | 100,000 → 90,000 |
| 10% short c1 | buys currency1 (increases) | 10,000 c0 | 9,966.781913 c1 | 1.003333 | 100,000 → 109,966.78 |
| 10% short c1 | buys 60,000 c0 worth | 60,000 c0 | refused `InventoryLimit` | — | would pass 150,000 |
| 20% short c1 (beyond cap) | sells currency1 (reduces) | 10,000 c1 | 9,998.976231 c0 | 0.999898 | 200,000 → 190,000 |
| 20% short c1 | buys currency1 | 1,000 c0 | refused `InventoryLimit` | — | — |
| balanced | 1 wei | 1 | refused `ZeroOutput` | — | — |

The 10%-short rows are the case Hook B refuses: the inventory-reducing sale gets the better price (0.999201, below the
reference by 8 bps), the inventory-increasing purchase the worse one (1.003333), and both pass floors pivoted at 1.

## 9. Parameters (SYNTHETIC calibration, not a deployment recommendation)

Chosen on calibration seeds by a rule fixed in code before running: maximise the worst regime's median LP-vs-HODL,
then the median regime's (`simulate.py calibrate`). Then evaluated once on held-out seeds.

| parameter | value | sensitivity (calibration seeds, worst-regime LP vs HODL) |
|---|---|---|
| `h_base` | 20 bps | range over the other two parameters: 5 bps −249 to +97; 10 bps −164 to +102; 20 bps −16 to +119; 30 bps +52 to +117; 50 bps +27 to +72 |
| `δ_max` | 15% | at 20 bps and 50%: 5% +110.8; 15% +118.7; 30% +119.2 (15% and 30% tie at the rule's 1 bp; the median regime, 154.3 vs 151.5, breaks it) |
| `vol_mult` | 50% | 0%: +17.8; 25%: +113.4; 100%: +68.0 |
| `h_min` | 1 bp | not varied |
| reference policy | primary max age 3,900 s; secondary max age 25 h; divergence limit 1%; missing penalty 10 bps | not varied |

The volatility term is the strongest lever on the worst regime. It costs fill rate in volatile markets (19.5% vs 30.3%
without it), because the spread widens exactly when informed flow is most expensive.

## 10. Solidity-facing notes (for milestone M1)

- **Overflow.** Inside the cap the existing `CumulativePricing.positionCost` / `positionForCost` preconditions hold
  (`V ≤ 2^95 − 1`, `|I| ≤ c < 0.3·V`). The linear extension's denominator `M·(V ∓ c)²` can reach 2^350, so it is
  computed in two exact steps using `ceil(ceil(x/d₁)/d₂) = ceil(x/(d₁d₂))` (and the same with floor):
  `y = mulDivRoundingUp(I·V − c², V·2^96, (V − c)²)` then `ceil(y / M)`. With `|I| < 2^127` every operand and `y` stay
  below 2^256 (T, `SolidityFormEquivalence`, 3,000 random cases incl. `|I|` up to 2^127, equal to the model exactly).
  The negative inverse is `|I| = ceil((ceil(|t|·M·(V + c)² / (2^96·V)) − c²) / V)`, by the same identity.
- **Square roots.** `straddle_cap` needs two `Math.sqrt` calls with bounded correction loops. That is the same pattern
  as `maxPosition`, measured at 1,464 gas.
- **Measured components** (`test_RC_gas_curveMath`, production compiler settings): `positionCost` 546 gas,
  `positionForCost` 640, `maxPosition` 1,464. Vault reads for `N_0, N_1, S`: 19,549 cold, 7,049 warm
  (`test_RC_gas_vaultInventoryReads`).
- **Rounding direction.** Every division rounds toward the vault: `Ĉ` up, inverse down, credit down, output down, plus
  the one-unit reserve.
- **Events.** A swap should emit the reference round ids, `u`, `h`, `I` before and after, so that an off-chain quoter
  and an auditor can replay it.
- **No hook storage writes** on the swap path, unless M2 chooses a stored volatility estimate.
