# Porkfolio — Market-Making Candidates (Phase 1B-4)

**Status: ANALYSIS, recommendation for review.** Compares four complete pricing architectures against the root cause
(`PHASE1B4_ROOT_CAUSE.md`) and the invariants (`PRICING_INVARIANTS.md`). Integer model: `simulations/mm/model.py`.
Numbers labelled SYNTHETIC come from `simulations/mm/simulate.py` on held-out seeds (`PHASE1B4_REPORT.md` §5 has the
full tables and assumptions). Nothing here is historical data.

Notation: `P` or `M` is a reference price (raw currency1 per raw currency0, Q96 in code); prices "of currency1" below
are in currency0, i.e. `1/M`. `h` is a half-spread, `h_min` a minimum edge, both in pips. `I` is the vault's real
inventory deviation in raw currency1 (target minus held; `I > 0` = the vault is short currency1). `x` is Hook B's
decaying position.

## A. Existing cumulative virtual constant-product curve (Hook B, Phase 1B-3)

**Definition.** State `x` per pool, decaying toward 0 at `X_max / window` per second. Cost function
`C(x) = V·x / (P·(V − x))`; a trade from `x` to `x'` exchanges `Ĉ(x') − Ĉ(x)` currency0. Cap `|x| ≤ X_max`.

**Transitions.** Vault sells currency1: `x' = max{x : Ĉ(x) ≤ Ĉ(x) + in}`. Vault buys currency1: `x' = x − in`,
`out = Ĉ(x) − Ĉ(x')`. Decay between swaps. `configurePool` rescales `x` on a depth change.

**Strengths.** Exact telescoping in integers (split-proof within one pool); aggregate cap independent of splitting;
closed-form inversion; small, audited-in-house code; no external dependency.

**Failure conditions.**
1. Bid = ask = `p(x)`: every `|x|`-reducing trade is quoted on the wrong side of the reference and refused by D14 floors
   pivoted there (root cause).
2. `x` is not inventory: decay restores the price without restoring holdings; one buyer per window can drain the
   vault at reference prices while `x` never exceeds `X_max` (236,435 currency1 in 24 h in the fixture).
3. Static `P`: with a moving market every regime loses to arbitrage (SYNTHETIC A0: worst regime −886 bps vs HODL).
4. Per-pool state: a second hook on the same reserve doubles the exposure the cap was meant to bound.

**Attack surface.** Waiting for decay is free; splitting across hooks; stale `P`; `hookOwner` parameter changes apply
at once.

## B. Two-sided constant-product model (Hook B plus a spread)

**Definition.** As A, but the vault sells currency1 at `(1 + h)` times the curve and buys it at `(1 − h)`:

```
ask:  x' = max{x : Ĉ(x) ≤ Ĉ(x) + floor(in·PIPS / (PIPS + h))}
bid:  out = floor((Ĉ(x) − Ĉ(x − in)) · (PIPS − h) / PIPS)
```

**Round trips.** A closed loop now costs `2h` of the curve segment (plus rounding), so zero-cost reversal is gone.

**Reverse trades.** A reverse leg passes a pivot at `P` only while `(1 − h)·(V/(V − x))² ≤ 1`, i.e. while the curve
premium accumulated since `x = 0` is below `h`. Two consistent settings exist, and neither is good:

- `X_max` set by impact (2%), `h` ≪ 2%: reverse trades still fail beyond a premium of `h` (B1).
- `X_max` shrunk so the premium never exceeds `h` ("straddle cap"): every reverse passes, but the cap is tiny
  (0.2% impact → about 1,000 tokens of position at `V` = 1M), so inventory-*increasing* flow is refused instead
  (B2: protocol acceptance 42–49%).

**Unfixed.** Failure conditions 2–4 of A remain: B still prices decaying pressure, not inventory, and per-pool.

SYNTHETIC (calibrated `h` = 20 bps, 2% cap, keeper-updated `P`): median fill 30.2%, worst-regime LP vs HODL +48.6 bps,
worst world −74.9 bps.

## C. Inventory potential around an external reference (recommended)

**Definition.** Full specification in `INVENTORY_PRICING_SPEC.md`. In short:

```
state      I = T_1 − N_1,  T_1 = S·τ          (vault's real currency1 deviation; S = total shares; no hook state)
depth      V = min(V_max, S·v)                  (v derived from the risk cap and the spread, not tuned freely)
reference  M, u = resolve(primary, secondary, history)    (fails closed; u = divergence + age + realized vol)
spread     h = h_base + u,  refuse if h > h_max
cap        c = min(straddle_cap(V, h, h_min), I_max = S·τ·δ_max)
potential  Ĉ(I) = Hook B's integer curve inside [−c, c], continued linearly beyond (one integer function)
ask        I' = max{I : Ĉ(I) ≤ Ĉ(I) + floor(in·PIPS/(PIPS+h)) − 1},   refuse if I' > c
bid        out = floor((Ĉ(I) − Ĉ(I − in))·(PIPS − h)/PIPS) − 1,         refuse if I − in < −c
```

**Key property (P-3, straddle).** `c` is the largest deviation at which the curve's skew still fits inside the spread:
the bid at `+c` is `M(1 − h_min)` and the ask at `−c` is `M(1 + h_min)`. So every accepted trade is on the vault's side
of `M` by at least `h_min`, for any state and parameters. Consequences, all checked in `test_mm.py`:

- floors pivoted at `M` accept every quote (the root cause cannot occur);
- closed cycles at fixed `M` lose, also across hooks with different spreads and across parameter changes;
- inventory-reducing trades are priced at up to `M(1 − h_min)` and are never refused for pricing-state reasons;
  inventory-increasing trades pay up to about `M(1 + 2h)` and stop at the cap.

**Why real inventory.** It is the authoritative state the vault already maintains; it changes only by trades
(LP flows scale it and `V` together); it does not decay; every hook reading it sees the same value, so cross-hook
splitting cannot reach a fresh curve (P-1 across hooks, P-5).

**Why the cap is tied to the spread.** Without it the skew could cross the reference, and then either the vault pays
through the market to rebalance (a cost LPs did not agree to) or the floors refuse it, which brings back the root
cause. The cost of the tie is that skew is limited to about one spread. The simulation shows this is enough: the
deviation stays within the 15% cap in every held-out world.

**Rejected variant: value target.** Measuring `I` against `θ·(N_1 + N_0/M)` makes the target move with the spread each
trade earns, so `I` does not move by exactly the traded amount. Counterexample (`ValueTargetCounterexample`): 100
pieces of a 100,000-token bid are paid 0.18 tokens more than one trade. A per-share unit target `τ` has no such leak;
governance can retarget `τ` (a parameter change, see the spec).

**Attack surface.** The reference (manipulation, staleness, outage, divergence; see `ORACLE_REFERENCE_FEASIBILITY.md`);
latency arbitrage around reference updates (market arbitrage, priced by `h` and `u`); just-in-time LP deposits that
deepen `V` (bounded by `V_max`, and the depositor bears its share of any loss); parameter changes (straddle still holds;
loosening still needs D-P3 delays); informed flow (a market cost, priced by `u`).

SYNTHETIC (calibrated `h_base` = 20 bps, `δ_max` = 15%, volatility multiplier 50%): median fill 34.3%, protocol
acceptance 97–100%, median reverse fill 37.9%, worst-regime LP vs HODL **+90.9 bps**, worst single world **+8.6 bps**,
arbitrage revenue against the vault 0.0/day in every regime except the jump (−169/day: the primary feed is one slot
behind a 6% jump, which is market arbitrage, not mechanical).

## D. Hybrid: deterministic quote plus an authorised RFQ path

**Definition.** C, plus a route by which an authorised maker signs a quote (pool, direction, amounts, expiry, nonce)
that the hook verifies and passes to `exchange`. The vault still enforces floors, quota, flow caps and every other rule;
the RFQ cannot bypass vault authorization. A router takes whichever quote pays more.

**What it improves.** Fills (median 40.0% vs 34.3%), because the maker prices from the live market with a fixed
15 bps spread instead of a reference plus an uncertainty spread.

**What it costs.**
- LP outcome: worst-regime LP vs HODL falls from +90.9 to **−16.4 bps** (worst world −207). The RFQ captures the
  uninformed flow at a lower spread and fills the daily flow caps, after which the on-chain quotes are refused
  (`FlowLimitExceeded` is D's top refusal in every regime).
- If the RFQ path does not enforce the hook's inventory cap, inventory runs to 100% and the worst world loses
  −794 bps (D'). The vault does not enforce inventory policy, so the hook must check every RFQ fill against the same
  cap.
- New trust: a signing key that can sell the reserve at any price above the floors until the caps stop it, equal to
  `hookOwner` setting `P` today. New availability dependency: the maker's server. Gas: one `ecrecover` (~3k) plus
  calldata.
- It cannot fix the root cause: reverse trades refused by the vault's floors are refused for RFQ fills too.

**Verdict.** Not part of the core. If it is ever added, it should be an optional, inventory-checked route, and it
must not share the flow caps of the deterministic path. That needs its own decision.

## Cross-hook and shared-inventory economics

Both hooks draw on one reserve. The vault already enforces aggregate *quantity* limits (allocations, flow caps,
exposure caps) across hooks. It does not see *price*. So the reserve's effective price for an inventory-increasing
trade is the cheapest quote among all hooks that have capacity.

SYNTHETIC, two hooks on one reserve, router takes the better quote (held-out seeds):

| configuration | median fill | worst-regime LP vs HODL | worst world | max inventory deviation |
|---|---|---|---|---|
| Hook A + Hook B (today, keeper-updated `P`) | 38.7% | −105.1 bps | −776.5 bps | 99.99% |
| Hook A + C | 43.5% | −90.3 bps | −666.8 bps | 99.98% |
| C + C-core at 10 bps (shared inventory) | 39.4% | +72.7 bps | −47.4 bps | 15.0% |

Hook A ignores inventory. Paired with any inventory-aware hook, it becomes the drain: arbitrage and one-sided flow
route through it until the vault holds one asset. **An inventory-aware hook protects the reserve only if every hook on
that reserve shares the inventory signal.**

Ways to share it, compared:

| design | correctness | gas | new trust or state | verdict |
|---|---|---|---|---|
| 1. Each hook reads authoritative vault state during execution (`backing`, `claimableAssets`, `totalShares`) | exact; same value for every hook; no divergence possible | 19,549 cold / 7,049 warm measured for the five getters; about 13k marginal once the vault account and slots are warmed by `exchange` (estimate) | none: existing public getters | **recommended** |
| 2. Derive inventory from existing interfaces off-chain and pass it in `hookData` | wrong under concurrency, and trader-controlled | low | trusts the swapper | rejected |
| 3. Restricted auxiliary risk or pricing contract | exact if it reads the vault; otherwise a second source of truth | an extra external call | new stateful module | rejected unless (1) proves too costly |
| 4. Hook-local transient state with reconciliation | diverges between reconciliations; transient storage resets per transaction | low | reconciliation authority | rejected |

With design 1, the shared-core requirement becomes a **configuration requirement**: every hook on the reserve uses
the same reference policy, target `τ`, depth `v` and cap `δ_max`, and sets only its own spread policy `h ≥ h_base`.
A hook whose curve differs still straddles `M`, so cycles across hooks still lose; what differs is only which hook a
router prefers. Hook A should therefore either adopt the core (its cumulative flow fee becomes its spread policy) or
leave the shared reserve. Running it unchanged next to C is the configuration the simulation shows draining the vault.

## Complexity and performance

Gas is measured where marked; everything else is an estimate, to be measured at the milestone gates in
`PHASE1B4_REPORT.md` §8.

| criterion | A (today) | B | C | D |
|---|---|---|---|---|
| Mathematical correctness | P-1 within pool; fails P-3, P-4, P-5, P-8 | adds round-trip cost; still fails P-4, P-5, P-8 | P-1 to P-9 (model-checked) | as C, plus whatever the RFQ check enforces |
| Economic outcome: worst-regime LP vs HODL (SYNTHETIC) | −37 bps (keeper `P`), −886 (static) | +48.6 bps | **+90.9 bps** | −16.4 bps |
| Swap gas | 244,885–253,611 measured (Phase 1B-3) | ≈ A + 0.5k (est.) | ≈ A + 13k vault reads + 2–3k math + 20–28k for two feeds, + 20–32k if volatility is read from four past rounds (est.): **≈ 280k–320k** | C + ~3k signature check + calldata |
| Storage writes per swap | 1 (position) | 1 | **0** in the hook | 0 (+1 nonce for RFQ fills) |
| External calls | vault `exchange` | same | + 1 vault call (5 reads) + 2 feed reads (+ up to 4 round reads) | + `ecrecover` |
| Runtime bytecode | 9,165 B measured | ≈ 9.4k (est.) | ≈ 11–14k (est.), under EIP-170 | ≈ +2k |
| Quote computation off-chain | trivial | trivial | needs vault snapshot + feed values; deterministic | needs maker service |
| Cross-hook synchronisation | none (the problem) | none | implicit, through vault inventory | as C for on-chain fills |
| Failure recovery | waits for decay | waits for decay | none needed; refusals clear when reference recovers | as C; RFQ outage = C |
| New trust | `hookOwner` sets `P` | same | reference feeds + floor keeper (decisions D-1, D-2) | + maker key |
| Operations | `P` updates | `P` updates | feed selection, floor re-centring | + maker uptime |

## Recommendation

**C**, implemented as one pricing core that every hook on the reserve uses, with:

- the vault's own inventory read through its existing getters (no new state, no change to the vault);
- a fail-closed two-feed reference (`ORACLE_REFERENCE_FEASIBILITY.md`);
- vault floors kept pivoted near the reference by an owner-authorised keeper process (decision D-2), because static
  D14 floors make any two-sided quote one-sided once the market moves (C1, static floors: median fill 4.7%).

Rejected: A (root cause), B (moves the boundary, keeps the wrong state), D in the core (better fills, worse LP outcome
and new trust; its inventory check is mandatory if it is ever added).
