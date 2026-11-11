# Porkfolio — What the Inventory Floor Guarantees (Phase 1B-4.3, Task 1)

**Status: PROVEN (T1, T2, under the assumptions in §2) and TESTED (stateful adversarial model, exact integers).**
The Phase 1B-4.2 summary "LPs lose at most `kappa` of vault value" is **false** as stated (§4). The correct statement is
per share, against the LP's own entry basket, and holds only while the floor parameters do not loosen.
Model: `simulations/mm/floor_guarantee.py`; tests: `simulations/mm/test_floor_guarantee.py`; results:
`simulations/mm/results/floor_guarantee.md`. Solidity counterpart: `test/invariant/OracleRiskInvariants.t.sol`.

## 1. Definitions

For asset `a`:
- `N_a = B_a − W_a`: net assets owned by outstanding shares (finalized withdrawals `W_a` excluded).
- `S`: total shares, including queued shares.
- `h_a = N_a / S`: per-share holding.
- `l_a = tau_a (1 − kappa_a)`: per-share floor. Here `tau_a` is the target holding per share (`inventoryTargetPerShare`,
  WAD) and `kappa_a` the tolerance (`inventoryTolerancePips`).

The vault enforces `N_a − x ≥ L_a = ceil(S · tau_a · (1e6 − kappa_a) / (1e18 · 1e6))` on every fill paying `x` of
`a`.

## 2. What is guaranteed

**Assumptions** (each is a code property or a governance rule, listed so a reviewer can check it):
- A1. The only paths that change `N_a` or `S` are `initialDeposit`, `deposit`, instant `redeem`, queue finalization,
  `claim` and `exchange` (verified by listing every write to `backing`, `claimableAssets` and `totalShares`).
- A2. `deposit` pays `ceil(s N_a / S)`; `redeem` and finalization pay `floor(s N_a / S)`; `claim` lowers `B_a` and
  `W_a` equally. So none of them lowers `h_a`.
- A3. Every `exchange` that pays out `a` checks the inventory floor, in every pricing mode, once `tau_a` is configured.
- A4. `tau_a` does not fall and `kappa_a` does not rise during the period considered.
- A5. Claims donated to the vault are not counted (B_a is the vault's own accounting).

**T1 (per-share depletion; PROVEN).** For `t0 ≤ t1`: `h_a(t1) ≥ min(h_a(t0), l_a)`.
Proof: by A2, LP paths never lower `h_a`. By A3, a fill lowering `h_a` leaves `N_a ≥ L_a ≥ S·l_a`, so `h_a ≥ l_a`
afterwards. Induction over the sequence of calls.

**T2 (economic shortfall; PROVEN, from T1 and A2).** An LP holding `s` shares from `t0` to `t1` is paid a basket
worth, at **any** price vector `p` (including after a depeg), at least

    s · sum_a min(h_a(t0), l_a) · p_a  −  (one raw unit per asset per payout, rounding)

So its shortfall against simply holding its entry basket is at most `s · sum_a (h_a(t0) − l_a)^+ · p_a`.

This bounds what any adversary can take **in total, over any number of trades, epochs, hooks, refills and
deposits**. It is a bound on the state, not on a flow. Specifically:
- **Repeated trades against a corrupted oracle.** Covered: each fill is checked against the same per-share floor.
- **Two hooks on one reserve.** Covered: the check is vault-wide on `N_a`, independent of which hook trades.
- **LP deposits refilling inventory.** Deposits are pro-rata, so they do not raise `h_a`. A drained asset stays drained
  per share, and the new LP's own exposure starts at its entry `h_a`.
- **Partial and full withdrawals.** Do not lower `h_a`.
- **Queued and finalized withdrawals.** Queued shares bear the same per-share bound until finalized; finalized `W_a` is
  outside `N_a` and cannot be sold.
- **Refill by honest flow, then extraction again.** Covered by T1: the budget is the distance to the floor, which
  honest refills restore only by moving value into the vault.
- **Flash deposit, drain, redeem.** The existing LPs' bound is unchanged (tested).

**Not bounded by the floor: mark-to-market loss.** If asset1 depegs, LPs lose its value exactly as holders would. T2
compares against holding the entry basket at the *same* prices, so the depeg itself is not counted. What the floor
bounds is the extra loss from the vault trading at wrong prices.

**Search result (SYNTHETIC adversary, exact integers).**
- Run: 300 random sequences × 400 calls; 40,526 payouts, each checked at 6 price vectors (including a full depeg of
  either asset); a hill-climb over drain / refill / deposit / redeem / flash-deposit sequences.
- T1 violations: 0. T2 breaches: 0.
- Worst shortfall / bound: 1.0009, explained entirely by rounding of at most 1.9 raw units per payout.

## 3. Corrections the search forced

| # | Finding | Evidence | Correction (implemented in this phase) |
|---|---|---|---|
| C1 | The owner could lower `tau` or raise `kappa` at once (1B-4.2 patch), which opens the whole reserve | `ce_loosen_bounds_immediately`: 100% extractable | any loosening of `tau`/`kappa` is delayed (`FLOOR_CHANGE_DELAY`, §5); guardian may only tighten |
| C2 | The 1B-4.2 patch checked the inventory floor only while an adapter was installed; returning to static mode silently dropped it | `ce_static_mode_without_floor`: 50% | the inventory floor applies in **every** mode once `tau` is configured |
| C3 | A delay protects only LPs who can leave within it. Queued shares keep bearing losses, and finalization can wait up to `MAX_HORIZON` (30 days) for commitments to expire | `ce_queued_lp_cannot_escape`: a queued LP finalized with 0 asset0 after a loosening took effect | floor loosening waits `FLOOR_CHANGE_DELAY = 32 days` > `MAX_HORIZON` + one flow window. Every request queued when the change is announced is deliverable before it takes effect, because the admission rule keeps new allocations off the queue's claim `D_a` and anyone can release expired allocations |
| C4 | The room `(h_a − l_a)` grows when fees accrue or honest flow skews inventory, so the loss as a fraction of value can exceed `kappa` | random search: 13.3% at `kappa` 5%; fee accrual: 5.8%; skewed composition: 9.5% of the asset0 holding | stated honestly: the bound is `sum (h_a − l_a)^+ p_a`, not `kappa · value`. The guardian (or the owner, immediately) may **raise** `tau` to re-centre the floor on current holdings; lowering it needs the 32-day delay |
| C5 | `tau = 0` means "no floor" | design | with an adapter installed, a fill in a direction with `tau = 0` is refused (`InventoryBoundsNotConfigured`) |

## 4. What is NOT claimed

- Not "at most `kappa` of vault value" (C4).
- No time-windowed budget. All of the room can be consumed within one flow epoch, and flow caps (two caps across a
  boundary) only slow it.
- No protection while `tau` is unconfigured in static mode (the pre-existing behaviour).
- Nothing about a compromised owner **after** a loosening has waited out its delay: LPs who stay accept the new floor.

## 5. Loss budget as an explicit mechanism?

The brief asks whether a cumulative loss budget needs its own accounting. T2 already **is** a lifetime per-share
budget relative to a fixed `l_a`:
- it never refills by itself;
- it can grow only through value the vault gained (fees, favourable fills);
- it can be widened only by a delayed governance change.

A separate counter of "value lost" would need a price to value fills, which is exactly what a corrupted oracle
controls. So no price-based budget is proposed. What does need explicit accounting is the **re-centring of `tau`**
(C4):
- every change is an event with the old and new values;
- raising is immediate;
- lowering waits 32 days and is cancellable by the guardian.
