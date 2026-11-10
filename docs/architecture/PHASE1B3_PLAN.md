# Porkfolio — Phase 1B-3 Plan: Cumulative Pricing in Hook A and Hook B

**Status: PLAN FOR REVIEW. Nothing here is implemented.** It turns `CUMULATIVE_PRICING_SPEC.md` (the model) into
an implementation sequence, and lists the decisions the owner must take first. It answers the splitting problem
measured in `TRADE_SPLITTING.md`. Labels: SOURCE, MODEL, PROPOSAL, DECISION (needs the owner).

## 0. Constraints that shape the plan

- **The vault does not change.** It has 2,527 bytes of EIP-170 margin (`AUTH_MODULE_INSTALL_HARDENING_REPORT.md`). Every change lives
  in the hooks (7,174 and 6,884 bytes, about 17 KB of margin each). The plan's first gate checks that the vault's
  runtime code hash is unchanged; if any step turns out to need vault code, stop and report.
- **Hooks stay untrusted by the vault.** The vault keeps enforcing `max(vault floor, curator floor)` on exact amounts
  and the flow and exposure caps. Cumulative pricing is a property of the hooks we ship, not a vault guarantee.
- **State in storage, not transient storage**, so splitting across transactions gains nothing (spec §2.3).
- **No epoch reset.** Linear decay only (spec §3, "Hard epoch reset: rejected").

## 1. Decisions needed before coding

| ID | Question | Recommendation |
|---|---|---|
| D-P1 | Hook A state: hook storage per (pool, direction), or the vault's flow record? | **Hook storage.** The vault's flow record is a fixed one-day epoch that resets to zero (`FLOW_WINDOW`), which is exactly the hard reset the spec rejects. |
| D-P2 | Parameters: decay window `W` per pool (seconds), Hook A scale `K`, Hook B depth `V` and `maxImpactPips` | Per pool, set by `hookOwner` in `configurePool`. Map today's values: `V = R / k` (spec §4.2). Decide whether to double Hook A's `max − base` to keep today's single-trade revenue (spec §5). |
| D-P3 | Loosening parameter changes (lower fee or impact, larger `V` or `K`, faster decay) delayed, tightening immediate? | **Defer.** Adds a pending-config state machine. Until then, document that `hookOwner` is trusted for pricing and must use a timelock. Reference-price `P` updates stay immediate. |
| D-P4 | Trader protection against sandwiching on Hook B (path-independent curves are AMM-like; see §5 E-7) | Accept a 64-byte `hookData` = `(allocationId, minAmountOut)` and revert below it; 32-byte `hookData` keeps working with no minimum. This changes the hook's calldata format. |
| D-P5 | Behaviour when a parameter change leaves Hook B's `|x|` beyond the new `X_max` | Trades that move `|x|` further out revert; trades that move it back toward 0 are allowed. No reset. |
| D-P6 | Reference model tooling | A Python `fractions` model (outside `src/`, under `simulations/`) that produces the expected integers for the differential tests. |

## 2. Shared library (commit 1)

`src/hooks/CumulativePricing.sol`, internal pure functions only:

- `decay(int256 x, uint256 rate, uint256 dt) → int256`: `sign(x) · max(0, |x| − rate · dt)`, with `rate · dt`
  saturating instead of overflowing; rounding toward less decay (the trader sees the higher state). O(1) for any gap.
- Hook A cost `Ĉ_A(x)` and its exact-input inverse (quadratic, OZ `Math.sqrt`, then at most two correction steps to
  satisfy `Ĉ(x+q) − Ĉ(x) ≤ in < Ĉ(x+q+1) − Ĉ(x)`). Piecewise: quadratic up to `K`, linear at the `max` fee above `K`,
  so no term squares a value larger than `K` (overflow argument next to the code).
- Hook B cost `Ĉ_B(x) = ⌈P·V·x/(V−x)⌉` for the vault selling currency1 and `Č_B(x) = ⌊P·V·x/(V−x)⌋` for the vault
  buying it back. Each telescopes on its own; a change of direction costs the trader at most 1 raw unit. (Refines
  spec §4.2, which rounds the buy-back "down" without naming a second function.) Closed-form inverse, no square root.
- `X_max = V·(1 − 1/√(1 + maxImpact))` precomputed at configuration, rounded down.
- Units: `x` in raw units of the asset the state tracks; costs in raw units of the input asset; `P` Q64.96 as today
  (`_grossOut`). Every `mulDiv` names its rounding direction and who it favours.

Tests: unit tests per function; differential fuzz against the Python model's vectors and against an on-chain
bisection reference (`Ĉ` monotone, inverse exact); overflow at `|x| = 2^127 − 1`, `V` near `2^127`, `P` at both
uint160 extremes; decay across `2^32` seconds.

## 3. Hook B: signed net state, aggregate impact cap (commit 2)

- State: `struct { int128 x; uint64 updatedAt; }` per pool, one slot. `x` = net currency1 the vault has sold through
  this pool (sold minus bought back).
- `zeroForOne` (vault sells currency1, `x` rises): decay, exact-input inverse with `Ĉ_B`, revert if the new `x`
  exceeds `X_max`.
- `!zeroForOne` (vault sells currency0, buys currency1, `x` falls by the input): output `Č_B(x) − Č_B(x − in)`, revert
  if the new `x` is below `−X_max`.
- Write the new state in `beforeSwap` **after** `vault.exchange` returns (the whole swap reverts otherwise). `_quote`
  becomes a view that returns `(amountOut, newState)`; a separate internal write commits it. `quote()` stays a view.
- Price no longer reads the allocation's `consumed`/`maxOut`: allocation shopping disappears. The allocation still
  bounds quantity in the vault.

## 4. Hook A: per-direction gross state, linear markup (commit 3)

- State: `struct { uint128 x; uint64 updatedAt; }` per (pool, direction). `x` = gross output sold in that direction,
  decayed. No netting between directions: a round trip pays both fees.
- Cost `Ĉ_A`, exact-input inverse; the fee is charged on input (spec §4.1).
- Same write-after-exchange structure as Hook B; the shared base hook gets a `_commit` hook point with a no-op default.

## 5. Tests (commits 2–4)

Every test runs on the production builds (`VaultTestBase`), through the real PoolManager.

**Split and path tests**

| ID | Test |
|---|---|
| T-1 | Split invariance (fuzz): random `x0`, total, 1–50 pieces, decay off: `Σ out(pieces) ≤ out(single)` and the gap ≤ n raw units. Both hooks, both directions. Inverts `TradeSplitting.t.sol`'s characterization (today splitting wins). |
| T-2 | Same swaps inside one `BatchSwapRouter` unlock and as separate transactions at one timestamp: identical state and outputs. |
| T-3 | Hook B round trip: sell then buy back the same amount; the trader never ends with more of either asset; `x` returns to its start. Hook A round trip pays both fees. |
| T-4 | Both directions interleaved (fuzz): Hook B's cost equals the telescoped `Ĉ`/`Č` sums within one unit per direction change. |
| T-5 | Aggregate cap: Hook B with `k > maxImpact`: no partition of a flow beyond `X_max` executes (inverts `test_TS_hookB_capIsPerSwap_splitBypassesIt`); symmetric for negative `x`. |
| T-6 | Allocation shopping: two allocations on one pool give the same price; the price depends only on the hook state. |

**State resets and time**

| ID | Test |
|---|---|
| R-1 | Decay is monotone in time and never resets: gaps of 0, 1, `W − 1`, `W`, `W + 1`, `2^32` seconds; a long gap brings `x` to 0, never past it. |
| R-2 | No reset from anything but decay: allocation creation, cancellation, release and expiry; module changes; LP deposits and redemptions; curator freeze and revocation; vault pause and halt leave hook state unchanged. |
| R-3 | A reverted swap (vault floor, flow cap, exposure, frozen curator, pause) leaves hook state unchanged. |
| R-4 | Parameter change keeps `x`; with D-P5, an out-of-range `x` only allows trades back toward 0. |
| R-5 | Several swaps in one block and in one transaction see the same state as the same swaps in separate transactions. |

**Economic attacks**

| ID | Attack | Expected |
|---|---|---|
| E-1 | Split one trade into many | no gain (T-1) |
| E-2 | Split across time to farm decay | gain bounded by `rate · Δt` units at the cheapest price; test the bound exactly |
| E-3 | Split across Hook A and Hook B pools | **not prevented by pricing**; total bounded by the vault-scope flow cap (assert) |
| E-4 | Stale `P` arbitrage at +1%, +5%, +50% | profit equals the model within rounding; bounded by `X_max`, floors and flow caps (spec §6) |
| E-5 | Round trip on Hook B to reset impact | net trader loss ≥ 0; LPs not worse off |
| E-6 | Push Hook A's `x` up to overcharge others | costs the attacker the markup; LPs gain; no attacker profit |
| E-7 | Sandwich on Hook B (buy, victim buys, sell back) | attacker profits at the victim's expense; the vault is not worse off (path independence: its net receipt is at least what the victim's trade alone would have paid, because `Ĉ ≥ Č` and rounding favours it); the victim is protected only by `minAmountOut` (D-P4). Test both with and without the bound |
| E-8 | Price below the vault floor | always refused by `exchange` (`PriceBelowFloor`), whatever the curve says |
| E-9 | Overflow and extreme inputs | `amountIn` up to `2^127 − 1`, `x` at its bound, `V` tiny and huge: revert or correct, never wrap |

**Invariants** (new handler actions: swaps on both hooks in both directions, warps, parameter changes):

- INV-P2: each hook's stored state equals a ghost replay of the successful swaps with decay.
- INV-P3 (decay off): input the vault received through a pool and direction ≥ telescoped `Ĉ` of the state change.
- INV-P4: Hook B `|x| ≤ X_max` after every successful swap.
- Every existing invariant keeps running.

**Production-artifact suite:** split invariance, aggregate cap and a round trip against artifact-deployed hooks.

## 6. Validation and evidence (commit 4–5)

- Gates before merging any step: vault runtime hash unchanged; hook sizes and margins recorded; `security.sh` passes.
- Gas: swap cost before and after for each hook and direction (one more storage slot read and written per swap;
  ESTIMATE +5,000 to +25,000 gas, to be measured, not assumed).
- Mutation checks on the library and both hooks (rounding direction, decay sign, missing state write, write before
  `exchange`, `X_max` off by one, per-piece rounding instead of telescoping).
- Docs: hook NatSpec with worked numerical examples; update `TRADE_SPLITTING.md` with before/after; report.

## 7. Not in Phase 1B-3

Epoch commitments, oracle-driven `P`, a loosening delay for hook parameters (D-P3), cross-hook pricing, and any vault
change. Cumulative pricing will not prevent losses from a stale `P`, splitting across hooks, or a dishonest hook
(spec §8).
