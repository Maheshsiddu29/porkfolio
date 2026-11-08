# Porkfolio — Cumulative Pricing Specification

**Status: SPECIFICATION FOR REVIEW (Phase 1B-2A). Not implemented. The current hooks are unchanged.** It answers the
problem measured in `TRADE_SPLITTING.md`, where both hooks price each swap independently. Labels: SOURCE, OBSERVED,
MODEL (exact rational model, script output quoted), PROPOSAL.

## 1. Scope and trust

- Hooks are **not trusted** to price fairly (`PHASE1B_CURATOR_AUTH.md` §12, assumption 4). The vault does not run the
  pricing functions. It enforces only the floor `max(f_v, f_c)` and the flow buckets (`MODULAR_RISK_ENGINE.md` §7).
- Cumulative pricing is therefore a property of **honest hooks**. It removes the split discount and bounds aggregate
  impact for the hooks we ship.
- The aggregate bounds that hold against a dishonest hook are the vault's flow limits and floors. This specification
  does not change them.

## 2. Model

### 2.1 Cumulative cost

For one pricing state `x` (defined per hook in §3) and output `q`:

```
Cost(x, q) = C(x + q) − C(x)            input owed for q of output, starting from state x
```

`C` is increasing. When `C` is a function of the state alone (path-independent), any sequence of trades that moves the
state from `x0` to `x1` costs `C(x1) − C(x0)` in total, however it is split.

### 2.2 Integer rule (mandatory)

Define one integer function `Ĉ(x) = ⌈C(x)⌉`, computed with `FullMath.mulDivRoundingUp` and never with a 256-bit
intermediate product. Then:

```
Cost(x, q) = Ĉ(x + q) − Ĉ(x)
```

- **Telescoping.** Over any split, `Σ [Ĉ(x_i+1) − Ĉ(x_i)] = Ĉ(x_n) − Ĉ(x_0)`: exactly the single-trade cost.
- **Exact input.** Given `in`, the output is the largest `q` with `Ĉ(x + q) − Ĉ(x) ≤ in`. Any unused part of `in` is
  kept by the vault.
  - Each piece of a split therefore reaches at most the state a single trade would reach. With integer `x`, the sum of
    outputs over pieces is **≤** the single-trade output.
  - Splitting can only lose to rounding, never gain.
- **What must not be done.** Rounding each piece's cost independently makes the result path-dependent. MODEL example,
  Hook B with `V = 10^6`, 1,000 out as pieces of 333, 333, 333 and 1:
  - telescoping total = single = 1,002;
  - rounding each piece up separately = 1,004.

  Rounding each piece *down* instead would let splitting win.

### 2.3 Why the state must be in storage

`x` must persist in contract storage across transactions. Transient storage resets at the end of each transaction,
so a trader could reset `x` by splitting across transactions. Several swaps in one transaction and the same swaps in
separate transactions at the same timestamp must reach the same state and pay the same total.

## 3. State variable per hook

| Hook | `x` | Keyed by | Why not the alternatives |
|---|---|---|---|
| Hook A (utilisation fee) | gross output this hook has sold on this pool in this direction, decayed linearly toward 0 | `(poolId, direction)` in hook storage | **Per allocation** (today's `consumed`) resets with every new allocation, so a trader shops for the freshest one. **Vault `consumed`** has the same problem. |
| Hook B (bounded impact) | **signed** net amount of currency1 the vault has sold through this pool (sold minus bought back), decayed toward 0 | `poolId` in hook storage | **Gross per direction** makes a round trip pay impact twice and never recover. **Vault inventory** `B_a` also moves with LP deposits and redemptions and with other hooks, which couples unrelated flows. |

- The hook updates `x` in `beforeSwap` **after** `vault.exchange` succeeds, in the same call, so a rejected swap leaves
  `x` unchanged (the whole transaction reverts).
- A hook sees every trade on its own pool, because every swap is intercepted (SOURCE, `BaseCompatibleHook`).
- **Optional variant for Hook A.** Read the vault's L2 bucket level `hookFlow[hook][out]` (`MODULAR_RISK_ENGINE.md`
  §7) as `x`. That state is authoritative, already decays, and costs no hook storage. It also ties the fee to the
  governance-set cap. Decide in the pricing milestone.

**Decay.**

- `x ← sign(x) · max(0, |x| − ρ · Δt)`, with `ρ = scale / WINDOW`.
- Rounding goes toward less decay: the trader sees the higher state.
- Gaps of any length are O(1).
- Decay is the only source of path dependence, and it is intentional: waiting is what lets the price recover.
- The amount of cheap flow per unit of time is `ρ`, so it is bounded by configuration, and also by the vault's L2–L4
  buckets.

## 4. Pricing functions

`P` converts output to input at the hook's reference price (Q64.96 raw currency1 per raw currency0, as in today's
`_grossOut`). Amounts are in raw units.

### 4.1 Hook A: linear markup

The marginal markup at state `s` (in pips) is `m(s) = base + (max − base) · min(1, s / K)`, where `K` is a per-pool
scale set by `hookOwner`. It is **not** the allocation's `maxOut`. For `x ≤ K`:

```
C_A(x) = P · [ x + (base · x + (max − base) · x² / (2K)) / 10^6 ]
```

Above `K`, the markup stays at `max`. The markup is charged on input, not as a haircut on output, so `C` is a
polynomial with no division by `(1 − fee)`.

- **Exact input** solves a quadratic: `q = ⌊(−b + √(b² + 4a·y)) / (2a)⌋ − x`, where `y = Ĉ(x) + in`. Use FullMath and
  OZ `Math.sqrt`, then correct by at most 2 steps so that `Ĉ(x + q) − Ĉ(x) ≤ in < Ĉ(x + q + 1) − Ĉ(x)`.
- **Overflow.** `x, q ≤ 2^127`; `x²/(2K)` is computed as `mulDiv(x, x, 2K)`; `P` is applied with
  `mulDivRoundingUp`.

### 4.2 Hook B: virtual constant product

One curve serves both directions. With depth `V` (output units):

```
C_B(x) = P · V · x / (V − x)          marginal price p(x) = P · V² / (V − x)²,   x < V
```

- **Vault sells currency1 (`x` rises by `q`).** The trader pays `Ĉ(x + q) − Ĉ(x)`. Exact input has a closed form with
  no square root: `x + q = V · y / (P·V + y)`, where `y = Ĉ(x) + in`.
- **Vault buys currency1 back (`x` falls by `q`).** The trader receives `Ĉ(x) − Ĉ(x − q)`, rounded down.
- **Impact cap as an aggregate bound.** The marginal impact `p(x)/P − 1 ≤ maxImpact` holds exactly while
  `x ≤ X_max = V · (1 − 1/√(1 + maxImpact))`. There is a symmetric bound for negative `x`. A swap that would move `x`
  past `X_max` reverts, **however the flow is split**.
- **Mapping today's parameters.** For small trades, today's impact is `k · G / R`. The CPMM's average markup is about
  `G / V`, so `V = R / k` reproduces today's single-trade price.

## 5. Examples (MODEL; quoted from an exact rational model)

1:1 reference price, 18-decimal tokens, nothing traded yet.

**Hook A**, base 500, max 5,000, `K` = 10,000:

| Trade | Today (OBSERVED, `TRADE_SPLITTING.md`) | Cumulative |
|---|---|---|
| 8,000 out, 1 swap | charge 32.8 | **18.4** |
| 8,000 out, 8 swaps | charge 20.18 | **18.4** |
| 8,000 out, 1,000 swaps | (model) 18.39 | **18.4** |

Every split pays exactly the integral. That equals today's n → ∞ limit, so a large single trade pays **less** than
today. To keep today's single-trade revenue, roughly double `max − base`. That is a pricing decision.

**Hook B**, `V` = 10^6 (matches today's `k` = 1%, `R` = 10,000):

| Trade | Today | Cumulative |
|---|---|---|
| 1,000 out, 1 swap / 10 swaps | 1.0 / 0.1054 | **1.0010 / 1.0010** |
| 5,000 out, any split | 25.0 single / 3.345 in 10 | **25.1256** |
| Aggregate cap, `maxImpact` 2% | per swap only | **|x| ≤ 9,852.5** |
| Cap-binding config: `V` = 2·10^5, `maxImpact` 1% | 5,000 executes as 5 swaps (OBSERVED) | **|x| ≤ 992.6**: 5,000 cannot execute in any split |

## 6. Cases that must be handled

| Case | Behaviour | Residual risk |
|---|---|---|
| Several swaps in one transaction | state persists in storage after each one; same as separate transactions | none beyond rounding (against the trader) |
| Swaps in separate transactions | same; decay applies between timestamps | intended recovery at rate `ρ` |
| Opposite direction | Hook A: separate `x` per direction with no netting, so a round trip pays the fee twice. Hook B: one signed `x`, so a round trip returns `x` to its start, pays zero net impact, and loses rounding. | Hook B round trips are free apart from rounding and fees. Vault floors (D14) still forbid profitable cycles at floor level. |
| Split across different hooks | **not prevented by pricing.** Each hook has its own `x`, so a trader takes the cheapest segment of each. | Bounded by the L3/L4 flow buckets and the floors, not by pricing. Do not claim otherwise. |
| Parameter change (`P`, `K`, `V`, fees, caps) | applies to the next swap; `x` is kept | A loosening change creates a one-time cheap segment. Proposal: loosening takes effect only after a delay, tightening immediately (as for the vault floor, D3). `P` updates are the main stale-price lever. |
| Integer rounding | §2.2: `Ĉ` telescoping; output rounded down; cost rounded up | at most 1 raw unit lost per piece by the trader |
| Hard epoch reset | **rejected.** At a boundary `x` jumps to 0, so a trader can buy the cheap segment just before the reset and again just after it: up to twice the capacity at the lowest price within seconds. | Use linear decay (§3) |
| Stale reference price `P` | Cumulative pricing **does not** fix it. An arbitrageur trades until the marginal price reaches the market. | Hook B, `V` = 10^6, market 1% above `P`: takes 4,962.8, LP loss 24.88. Market 5% above: the 2% cap stops it at 9,852.5 with loss 394.59 (uncapped it would take 24,099.9 and lose 609.85). Hook A's marginal price never exceeds `P · 1.005`, so any move above 0.5% lets the arbitrageur take everything up to the flow caps, losing at least `m − 1.005` per unit. Only floors, halts, caps and timely `P` updates bound this. |
| Unfavourable inventory change (one-sided flow) | Hook B's price rises as `x` grows; Hook A's fee rises with gross flow | The vault still loses the difference to the market during the move. The loss is bounded by the curve, the cap and the buckets. |
| Allocation shopping | removed: `x` is per pool and direction, not per allocation | — |

## 7. Required adversarial tests (for the pricing milestone)

- **Split invariance (fuzz).** For random `x0`, total `G` and partitions into 1–50 pieces, inside one transaction and
  across warped timestamps with decay disabled: `Σ out(pieces) ≤ out(single)` and `out(single) − Σ out(pieces) ≤ n`
  raw units.
- **Cross-transaction equivalence.** The same sequence of swaps inside one `BatchSwapRouter` unlock and as separate
  transactions at the same timestamp ends in an identical `x` and identical outputs.
- **Round trip.** Hook B: sell then buy back the same amount; the trader never ends with more of either asset.
  Hook A: a round trip pays both fees.
- **Aggregate cap.** Hook B with `k > maxImpact`: no partition of a flow beyond `X_max` executes. Invert the current
  `test_TS_hookB_capIsPerSwap_splitBypassesIt`.
- **Allocation shopping.** Two allocations for the same hook and pool: the price depends only on `x`, not on which
  allocation is used.
- **Decay.** Monotone in time; no reset when `Δt` exceeds the window by any amount; warp across `2^32`; no overflow at
  `|x| = 2^127 − 1`.
- **Parameter changes.** A loosening change before its delay has no effect; tightening applies at the next swap.
- **Stale price.** With the market moved by +1%, +5% and +50% relative to `P`, the arbitrage profit equals the model
  value to within rounding and never exceeds the bound from the caps and buckets.
- **Rounding.** Exact-input outputs satisfy `Ĉ(x+q) − Ĉ(x) ≤ in < Ĉ(x+q+1) − Ĉ(x)` for random inputs (differential
  test against a reference that solves by bisection).
- **Floor interplay.** With a vault floor above the curve, swaps revert with `PriceBelowFloor`. The curve never makes
  the vault accept a price below the floor.

## 8. Explicit non-guarantees

Cumulative pricing does not:

- prevent losses from a stale `P`;
- prevent splitting across different hooks;
- bound a dishonest hook;
- make the LP's share of fees match a market maker's.

It removes the split discount within one hook's pool and makes its impact cap an aggregate bound.
