# Porkfolio — Inventory Protection: four quantities, kept apart (Phase 1B-4.4)

**Status: TESTED (Solidity, stateful and deterministic, real PoolManager, production builds).** This extends
`INVENTORY_FLOOR_GUARANTEE.md` (Phase 1B-4.3), which stated and proved T1/T2. The starting hypothesis is the per-asset,
per-share protection. The rejected "LPs lose at most `kappa` of vault value" is not restored here; §4 shows again why
it is false.

## 1. The four quantities

Notation:
- `h_a = N_a / S` is the per-share holding of asset `a`.
- `l_a = tau_a (1 − kappa_a)` is the per-share floor.
- Prices `p` are true market prices.

| # | Quantity | Bound | Status |
|---|---|---|---|
| Q1 | Minimum units of each asset that stay protected per share | `h_a(t) >= min(h_a(t0), l_a)` for every `t >= t0` with no loosening in between | **holds** (proof T1; tested) |
| Q2 | Shortfall of one LP's payout against its own entry basket | per asset: `≤ s · (h_entry − l)^+ + 1 raw unit`. This implies every price vector, depegs included. A loosening executed while the LP stays adds `s · (l − l')` | **holds** (T2; tested, including queued LPs) |
| Q3 | Cumulative realized trading loss (sum over fills of value out − value in, at the true price of each fill) | **none** | measured; counterexample §4.2 |
| Q4 | Mark-to-market loss (value now vs. value at entry prices) | **none** | measured; counterexample §4.3 |

**None of these implies another.**
- Q1 is a state bound in units.
- Q2 compares a payout with the payee's own basket at one and the same price vector.
- Q3 is a flow that new capital and gains can refill.
- Q4 is market risk that holding the basket would carry anyway.

## 2. Stateful campaign

`test/invariant/InventoryProtectionInvariants.t.sol`, real PoolManager, production hooks.

**Handler actions:**
- honest and adversarial trades through **Hook A, Hook B** and a malicious consumer;
- **two curators**;
- **deposits** by three LPs;
- **instant and queued withdrawals**, `processQueue`, **claims**, request cancellations;
- **guardian tightening**: re-centre `tau`, lower `kappa`, raise the edge;
- **governed loosening** through `VaultGovernor`, raising `kappa` up to 20% or lowering `tau` up to 10%, with
  LONG_DELAY and the queue check;
- **adapter replacement** through the governor;
- **price jumps** (−20% … +25%) and **depegs** (one asset keeps 1/2 … 1/100);
- **corrupted references**, including drains at the price that makes a direction worthless;
- **time** in steps up to 2 days, so trading spans many flow windows and many allocation expiries.

**Fee collection:** the protocol has no fee withdrawal. Hook A's fee and both hooks' spreads stay in `N_a`, so "fee
collection" is the gain side of the trades.

**Checks after every call:**
- **Q1, cumulatively.** `N_a · 1e18 >= G_a · S`, where `G_a` is the largest `min(h_a, l_a)` seen since the last
  executed loosening. This is stronger than the per-step form of T1.
- **Q2, every instant payout.** Compared per asset with the paying LP's basket and room (lots are pro-rated).
- **Q2, every finalization slice of a queued request.** Compared with the basket and room the request carried *when it
  was queued*; it gains no room from a later loosening. A loosening that executed with shares still queued is also
  counted as a violation.
- **Accounting equations.**

**Non-vacuity:**
- `afterInvariant` fails any run with 8 or more honest trade attempts and no fill. (An earlier rule, "48 calls
  and no fill", was too blunt: it failed on a legitimate dead state, an asset at its floor and the other at the
  shared cap after a guardian tightening.)
- `InventoryProtectionLivenessTest` scripts a sequence that must reach every branch: fills on both hooks and the
  malicious consumer, a refusal at the floor, a realized loss at a corrupted price, an instant payout, a finalization
  slice, a loosening refused while a late LP is queued and then executed, an adapter swap and a depeg.

**Result (MEASURED):**
- Command:
  `FOUNDRY_INVARIANT_FAIL_ON_REVERT=true FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-contract "InventoryProtectionInvariantsTest$"`.
- All 4 invariants pass over 32,768 calls with 0 reverts.
- The sampled final runs (one per invariant function) had 3 / 4 / 2 fills (A / B / malicious), 2–3 loosenings
  executed and 6–7 refused by the queue check, 6–7 payouts and 5–7 slices checked.
- Forge prints `afterInvariant` logs for the final run only, so these counts are a sample. The per-run assertion is
  what covers every run.

**Correction (G01, `docs/security/G01_BASELINE.md` F5).** This section used to say that the largest shortfall seen was
253–582 bps of the LP's room (2,361 bps in an earlier campaign) and that all were below 10,000 bps. That came from one
sampled run per invariant and is wrong as a general statement. Over 100 single-run campaigns at depth 128 the logged
ratio `maxShortfallToRoomBps` exceeded 10,000 bps in 36 runs (median 6,760 bps, largest 1,523,526 bps). **Q2 held in
every one of them.** The ratio is not the bound:
- Q2 allows the shortfall to exceed the room by one raw unit per asset per payout, because the vault rounds each payout
  down. When an LP's room is a fraction of a raw unit (it entered with the holding at or near the floor), a shortfall
  of under one raw unit is a very large multiple of that room.
- The campaign checks `shortfall <= room + 2 raw units`, not `+ 1`. One checked slice can span two vault payouts: a
  request queued and first finalized inside the same handler call (the late-LP branch of `governedLoosen`) is not yet
  tracked at the start of that call, so its next slice is checked together with the first. Measured at one unit
  (256 runs × depth 256, seeds `0x5eed`, `0x1`, `0x2`, `0x3`): the instant-payout invariant passes, the queued-request
  invariant fails on every seed; at zero units both fail. So each vault payout stays within the one-unit allowance,
  and the second unit is how the test aggregates, not extra loss.

The smallest counterexample, §4.4, is this same allowance in its exact form.

## 3. What the governance change adds to Q2

Before this phase, a loosening could execute while an LP was queued. That LP's shares then bore the looser floor even
though it had asked to leave.
- **Now.** `VaultGovernor` refuses LONG_DELAY changes while `pendingShares != 0`
  (`GOVERNANCE_SECURITY.md` §3). The campaign checks this: queued requests carry their entry room unchanged across
  loosenings, and `requestViolations` stays 0.
- **What it costs.** In the campaign, 6–7 of 9–10 attempted loosenings in the sampled run were refused because an LP
  was queued behind a commitment.

## 4. Counterexamples (deterministic, `test/security/InventoryProtectionBounds.t.sol`)

**Setup** for all four: 1:1 assets, `N0 = N1 = 1e24`, `S = 1e24`, `kappa = 5%`.

### 4.1 Q1 does not bound loss as a fraction of value (C4, reproduced on the vault)
1. One overpaying trade lifts holdings to `(1.12, 0.96)` per share.
2. A corrupted oracle drains both assets to the floor. It takes **8.65%** of value (`0.18 / 2.08`) at `kappa = 5%`.

Throughout:
- Q1 holds.
- An LP who entered before the gain loses exactly its room (0.10 / share).
- An LP who entered after it loses its room of 0.18 / share, **8.65% of its entry value**. That is still within Q2.

**Remedy.** The guardian raises `tau` to the holding (immediate; tightening only). The room returns to `kappa` of the
holding (`test_recentring_restoresKappaOfHolding`). Lowering `tau` below the holding is refused to the guardian.

### 4.2 Q3 is not bounded by `kappa` of the starting value
1. Drain asset0.
2. New LPs double the supply. They buy in at the drained basket, so their entry is already depleted.
3. Honest flow refills asset0 from asset1's room.
4. Drain asset0 again.

Result:
- Cumulative realized loss **0.15e24 > `kappa · V0` = 0.10e24**.
- The seed LP's shortfall is still exactly its room, and Q1 holds.

The absolute flow can exceed any fraction of the starting value because the vault's size and composition change.

### 4.3 Q4 is unbounded
1. Asset1 keeps 1% of its value.
2. Honest arbitrage at the true price sells asset1 to the vault until asset0 reaches its floor.

Result:
- Q1 holds, and Q2 at post-depeg prices is about 0: the vault traded fairly.
- Against its value before the depeg, the seed LP's basket is down **49.5%**: what holding the basket would have lost,
  plus the 5% of asset0 the vault sold at a fair price.

### 4.4 The smallest counterexample: rounding
The exact statement "payout ≥ `s · min(h, l)`" is false by less than one raw unit.
- With asset0 at exactly `L = 0.95 S`, redeeming 3 shares pays `floor(2.85) = 2` raw units.
- This is the documented one-raw-unit-per-asset-per-payout allowance. It does not accumulate: each payout rounds
  against the redeemer, so `N/S` never falls for anyone else (`test_rounding_exactT2FailsBySubUnit`).

**No other counterexample was found:** none in the stateful campaign, and none in the Phase 1B-4.3 Python search
(40,526 payouts × 6 price vectors).

## 5. What is not claimed

- No bound on Q3 or Q4.
- No bound for LPs who stay through an executed loosening, beyond the added room `s · (l − l')`.
- No protection for an asset whose `tau` is unset in static mode (adapter mode refuses such fills).
- The campaign's adversary owns the adapter and a registered consumer. It does not own the vault owner or the governor
  admin beyond the governed actions listed.
