# Porkfolio — G03: Exact LP Accounting Guarantees

**Status: see §11.** This document reconstructs the LP ledger of `SharedCommitmentVault` from the code, states what
it guarantees to LPs and with what evidence, and records the counterexamples found. The future reservation-bond and
idle-yield accounting is specified separately in `docs/architecture/FUTURE_CAPITAL_AND_YIELD_ACCOUNTING.md` and
summarized in §8. **No production contract changed in G03.**

- **Branch:** `phase-2-g03-lp-accounting`, from `main` at `f557664` (the G02 head).
- **Toolchain:** Foundry 1.7.1 (`4072e48`), solc 0.8.26 (via-IR, cancun, `bytecode_hash = none`), Python 3.11.8,
  macOS (Darwin 25.2.0).
- **Labels.** ARGUED: a written argument here, not machine-checked. TESTED: exercised by named tests, no proof.
  ARGUED + TESTED: both. ASSUMPTION: taken as given. COUNTEREXAMPLE: a reproduced case where a natural reading of a
  guarantee fails. OPEN: unresolved.
- Sources read: `src/SharedCommitmentVault.sol` (in full), `src/interfaces/IVaultState.sol`, `src/VaultLens.sol`,
  `src/risk/VaultRiskBoundary.sol`, `SHARE_ACCOUNTING.md`, `ACCOUNTING_FLOW.md`, `INVENTORY_PROTECTION.md`,
  `INVENTORY_FLOOR_GUARANTEE.md`, G01 and G02 reports, and the share, queue, zero-asset, multi-LP and invariant tests.
  Where the code and an older document differ, the code is used and §10 says so.

## 1. Starting state

| Check | Result |
|---|---|
| G02 integrated into `main` | yes: `main`, `origin/main` and `phase-2-g02-governance-liveness` all at `f557664` |
| `git status --short --branch` | `main`, only `?? AGENTS.md` (untracked, not created in this work, not touched) |
| Branch created | `phase-2-g03-lp-accounting` from `f557664`; no other branch |
| `forge test` (default profile) at `f557664` | **628 passed, 0 failed, 8 skipped** (fork tests, no RPC), 19.6 s; matches the G02 closeout |

## 2. The ledger, from the code

### 2.1 Quantities

All per asset `a ∈ {asset0, asset1}` except the share counts. Raw token units throughout.

| Symbol | Meaning | Source |
|---|---|---|
| `B_a` | accounted ERC-6909 backing | `backing[a]` |
| `X_a` | uncounted claims (donations): `PM.balanceOf(vault, a) − B_a` | derived |
| `Q_a` | unused capacity of all **unreleased** allocations selling `a`, including expired ones nobody has released | `reserved[a]` |
| `W_a` | finalized, unclaimed withdrawals | `claimableAssets[a]` |
| `N_a` | assets owned by outstanding shares: `B_a − W_a` (includes `Q_a`) | `_netAssets` |
| `F_a` | immediately deliverable inventory: `N_a − Q_a` | `VaultLens.freeInventory` |
| `R_a` | protected reserve floor; read only by admission | `bufferFloor[a]` |
| `D_a` | pending withdrawal demand `⌈P·N_a/S⌉` (0 if `P = 0`) | `_pendingDemand` |
| `E_a` | eligible backing `N_a − D_a`; base of the exposure caps | `_eligibleBacking` |
| `L_a` | inventory floor `⌈S·τ_a·(1e6 − κ_a)/(1e18·1e6)⌉`, when `τ_a ≠ 0` | `VaultRiskBoundary.inventoryFloor` |
| `S` | outstanding shares, including `P` and `M` | `totalShares` |
| `P` | escrowed, not yet finalized shares | `pendingShares` |
| `M` | `MIN_SHARES = 1000`, held by `address(0)`, never redeemable | `sharesOf[address(0)]` |
| `s_max` | deliverable shares `min over a with N_a > 0 of ⌊F_a·S/N_a⌋` | `_deliverableShares` |

### 2.2 Every balance change

Δ in each column; blank means unchanged. "claims" is `PM.balanceOf(vault, a)`.

| Operation | `B` | `W` | `Q` | `N` | `F` | `S` | `P` | claims | ERC-20 |
|---|---|---|---|---|---|---|---|---|---|
| `initialDeposit(x0, x1)` (owner, once) | `:= x_a` | | | `:= x_a` | `:= x_a` | `:= ⌊√(x0·x1)⌋` | | `+x_a` | owner → PM |
| `deposit(s)` | `+⌈sN/S⌉` | | | `+⌈sN/S⌉` | same | `+s` | | `+⌈sN/S⌉` | depositor → PM |
| `redeem`, instant part `s_i ≤ s_max`, only if `P = 0` | `−⌊s_iN/S⌋` | | | same | same | `−s_i` | | `−⌊s_iN/S⌋` | PM → receiver |
| `redeem`, queued part `r` | | | | | | | `+r` | | — (`sharesOf −= r`) |
| `processQueue`, one slice `s ≤ min(pending, s_max)` | | `+⌊sN/S⌋` | | `−⌊sN/S⌋` | same | `−s` | `−s` | | — |
| `cancelRequest` | | | | | | | `−pending` | | — (`sharesOf += pending`) |
| `claim` | `−c_a` | `−c_a` | | | | | | `−c_a` | PM → receiver |
| `reserveFor(q)` (module) | | | `+q` | | `−q` | | | | — |
| `exchange(i, o)`, sold asset | `−o` | | `−o` | `−o` | | | | `−o` (to hook) | — |
| `exchange(i, o)`, bought asset | `+i` | | | `+i` | `+i` | | | `+i` (from hook) | — |
| `release` / `cancelAllocation` | | | `−(maxOut − consumed)` | | `+same` | | | | — |
| direct ERC-6909 transfer to the vault | | | | | | | | `+d` (`X += d`) | — |
| configuration (`R`, `τ`, `κ`, floors, caps, curators) | | | | | | | | | — |

Rounding directions: deposits up, payouts down, `D_a` up, exposure caps down. Each favours the remaining shares or
the LPs over a hook.

### 2.3 Relations, verified against the code

| # | Relation | Status | Evidence |
|---|---|---|---|
| L1 | `PM.balanceOf(vault, a) = B_a + X_a`, `X_a ≥ 0`, and `X_a` changes only by donations | ARGUED + TESTED | every outflow of claims (`_payOut`, the `transfer` in `exchange`) is of an amount just subtracted from `B_a`; `invariant_backingEqualsRealClaims` (with a donation ghost), `invariant_ghostLedgerConservation` |
| L2 | `Q_a + W_a ≤ B_a`, i.e. `F_a ≥ 0` | ARGUED + TESTED | §2.2 row by row (`SHARE_ACCOUNTING.md` §4); `invariant_reservedIsExactAndBacked`, `_assertEquations` |
| L3 | `W_a = Σ_r claimable_r,a`; `P = Σ_r pending_r`; `S = Σ_i sharesOf_i + P`; `S ≥ M` | ARGUED + TESTED | `invariant_sharesAndQueueConserved` |
| L4 | `Q_a = Σ` over unreleased allocations of `maxOut − consumed` `= Σ_hooks hookReserved = Σ_curators curatorReserved` | ARGUED + TESTED | `_close` is reachable once per allocation (`_getLiveAllocation`); `invariant_reservedIsExactAndBacked`, `invariant_exposureAndHookReserved`, `invariant_closedIsTerminal` |
| L5 | `D_a ≤ N_a` (since `P ≤ S`), so `E_a` cannot underflow | ARGUED | `_pendingDemand` |
| L6 | `N_0 + N_1 > 0` while `S > 0` | ARGUED + TESTED | `SHARE_ACCOUNTING.md` §10.1; `invariant_equationsFromRawSources` |
| L7 | `Q_a ≤ N_a` | ARGUED | from L2; also every path that lowers `N_a` either lowers `Q_a` equally (`exchange`) or pays at most `F_a` (redemptions, slices) |

### 2.4 Admission and execution checks: what each reads

| Path | Reads | Does not read |
|---|---|---|
| `reserveFor` | curator record, generation, deadline, consumer, pool, pair, direction floor and halt, ceiling, `N, Q, R, D` (admission `q ≤ max(0, E − Q − R)`), exposure caps on `E` | prices, `L_a`, `W` (excluded via `N`) |
| `exchange` | consumer, allocation, curator restriction, pool, expiry, direction, quota, price floors (stored, curator, dynamic), **inventory floor `N_out − o ≥ L_out`**, flow caps | `F`, `D`, `W`, `R` |
| `redeem`, `processQueue` | `N, Q, S, P`, queue order | pause, halts, prices, adapter, flow and exposure caps, `R`, `L` |
| `claim`, `cancelRequest` | request record | everything else |

The table matters for §6: the admission rule and the inventory floor read different things, so reserved capacity and
sellable capacity can differ.

## 3. Assumptions

- **A-1.** The PoolManager is the pinned canonical v4 build and moves ERC-6909 claims exactly (G01 §7.2).
- **A-2.** The pair tokens are plain ERC-20: no fee on transfer (deposits fail closed on a mismatch), no rebasing, no
  balance changes outside transfers. A token may refuse a specific receiver (blacklist); §6 CE-5.
- **A-3.** Liveness needs callers: `release` after expiry and `processQueue`, both permissionless, are called.
- **A-4.** For the inventory-floor results: `τ_a` configured and no loosening of `τ_a` or `κ_a` in the interval.
- **A-5.** Amounts stay within `MAX_AMOUNT = 2^127 − 1` (enforced; an operation that would exceed it reverts).
- **A-6.** Governance follows the G02 rules (LONG_DELAY changes refused while `P ≠ 0`).

## 4. LP financial guarantees

### G-1. Conservation of physical claims (ARGUED + TESTED)
Every change of `B_a` is paired, in the same transaction, with an equal ERC-6909 mint, burn or transfer on the real
PoolManager, and no path spends claims it has not counted (L1). Donated claims are stranded: they belong to no share,
are never admissible and never paid out.

### G-2. Per-asset solvency (ARGUED + TESTED)
`Q_a + W_a ≤ B_a ≤ PM.balanceOf(vault, a)` after every external call (L1, L2). Outstanding commitments, finalized
withdrawals and free inventory are all covered by claims the vault holds, in each asset separately. No path nets one
asset against the other.

### G-3. No double allocation (ARGUED + TESTED)
`Q_a` is the exact sum of live remainders (L4). An allocation is closed at most once; consumption is bounded by its
own remainder; admission refuses anything beyond `N_a − Q_a − R_a − D_a`. A fill lowers `N_out` and `Q_out` by the
same amount, so it does not raise admissible capacity: inventory a hook bought is never promised again
(`test_twoHooksOneAsset_noDoubleCounting`, example B).

### G-4. Share minting and burning (ARGUED + TESTED)
Shares are minted only by `initialDeposit` (once) and `deposit`, burned only by instant redemption and finalization.
Escrowed shares leave `sharesOf` but stay in `S` until finalized or returned by `cancelRequest`. `M` is held by
`address(0)` and can never be redeemed, so `S ≥ M` (L3). Shares are not transferable.

### G-5. Withdrawal FIFO (TESTED)
Requests are finalized in id order; only the head can be partially finalized; a later request is never finalized while
an earlier one is pending; a new redeemer is paid instantly only if nothing is pending after up to four inline queue
steps. Evidence: `invariant_fifoOrdering`, `test_fifoFairness_competingRequests`, `test_INTENDED_fifoBypassAttemptsFail`,
`test_DOS_staleDeliverableEntry_doesNotBlockInstantExit`. Head-of-line blocking is the accepted cost
(`test_INTENDED_headOfLine_largePartialHead`).

### G-6. Claimable balance protection (ARGUED + TESTED)
`W_a` is outside `N_a`, so no fill, admission or later redemption can reach it (`exchange` pays at most `Q_out ≤ N_out
= B_out − W_out`). Only `claim` lowers it, only for the request's LP, zeroing the request before paying. Finalized
amounts never change afterwards and stay claimable after a cancel. Evidence: `invariant_noDoubleClaim`,
`test_claimableAssetsAreRingFenced`, `test_maliciousHook_cannotReachClaimable`. Limit: CE-5.

### G-7. Rounding across partial payouts (ARGUED + TESTED; new in G03)
1. Each payout (instant redemption or finalization slice) is `⌊s·N_a/S⌋`: short of the exact pro-rata amount by less
   than one raw unit per asset. A deposit is `⌈s·N_a/S⌉`: over by less than one unit.
2. **Splitting never pays more.** If an LP's `s` shares leave in `k` payouts with only that LP's payouts in between,
   the total paid `T` satisfies `⌊s·N_a/S⌋ − (k − 1) ≤ T ≤ ⌊s·N_a/S⌋` per asset, with `N_a, S` taken before the first
   payout. Upper bound: by G-8, `N_a − T ≥ (S − s)·N_a/S`, so `T ≤ s·N_a/S`, and `T` is an integer. Lower bound: each
   payout exceeds its exact share minus one unit, and the exact share at the then-current rate is at least the
   share at the starting rate (G-8 again); so `T > s·N_a/S − k`. Releases between slices change neither `N_a` nor `S`,
   so the same bound holds for a queued request finalized in `k` slices.
3. The units an LP loses to rounding stay in `N_a` for the remaining shares; nobody else loses.
4. A deposit followed by a redemption of the same shares loses at most one unit per asset and never gains, however
   often repeated.

Evidence: `testFuzz_splitInstantRedemption_neverPaysMoreThanOneShot` (1,000 runs; 10,000 in the CI profile),
`test_queueSlices_roundingBoundedBySliceCount`, `testFuzz_repeatedRoundTrips_neverGain`; all in
`test/security/LpRounding.t.sol`, at a basket of 1.707 asset0 and 0.697 asset1 per share so that every payout rounds.
Mutation (§9.2): redemptions rounded up are caught by all three.

### G-8. LP dilution protection during LP-only operations (ARGUED + TESTED)
Deposits, instant redemptions, finalization, cancellation, queuing and claims never lower `N_a / S` for either asset
(derivation `SHARE_ACCOUNTING.md` §3). Allocation, release and cancellation of allocations change neither `N_a` nor
`S`. Only `exchange` moves the per-share basket, through both assets, and donations do not move it at all. Evidence:
`invariant_noDilutionByLpOperations`, `test_depositAfterTrades_doesNotDiluteExistingHolders`, the per-step checks in
`LpRounding.t.sol`.

### G-9. Per-share inventory floors (ARGUED + TESTED; unchanged from 1B-4.3, G01)
Under A-4, `N_a/S ≥ min(previous N_a/S, τ_a(1 − κ_a))` whatever price, hook or curator acts (T1), and an LP's payout
is short of its own entry basket by at most `s·(h_entry − l)^+` plus one raw unit per asset per payout, at any price
vector (T2). **This is a floor in units per share. It is not a bound on economic loss**: the loss as a fraction of
value can exceed `κ` (8.65% at `κ = 5%`), cumulative realized loss is unbounded, and mark-to-market loss after a depeg
is unbounded (G01 §7.3; `InventoryProtectionBounds.t.sol`). It does not exist for an asset whose `τ_a` is unset in
static mode.

### G-10. What can be promised under adverse market conditions (ARGUED)
- **In units:** new commitments only within `N_a − Q_a − R_a − D_a`, and within each scope's exposure cap
  `bps·E_a/10,000`. Nothing in admission reacts to prices: during a depeg the vault can still admit commitments up to
  that limit in the asset that holds its value.
- **In value:** each fill pays at least the price floors; with an adapter, the dynamic floor widened by the reference
  uncertainty and the edge. Under A-4 the per-share inventory floor bounds what fills at any price can take (G-9).
- **In speed:** flow caps per hook, curator and vault per fixed window (up to twice the cap across a window
  boundary).
- **Not promised to hooks:** that reserved capacity can be sold. CE-1 and CE-2 below.
- Guardian levers (halt, pause, raise floors and `R_a`, tighten caps, freeze, emergency release) are immediate and do
  not touch LP exits (G02 §1.4).

### G-11. New commitments cannot reduce the queue's deliverability (ARGUED + TESTED)
Right after any admission in asset `a`, `F_a ≥ R_a + D_a ≥ D_a`, so `⌊F_a·S/N_a⌋ ≥ ⌊⌈P·N_a/S⌉·S/N_a⌋ ≥ P`: in that
asset, the whole current queue is deliverable. Only allocations that existed before a request was queued can hold it,
and they end within `MAX_HORIZON` once released (G02 L-1; `testFuzz_queueDrainsAfterHorizon`,
`test_queuedRedemptionDuringActiveCommitments`).

### G-12. Swap demand never reduces instant exits (ARGUED + TESTED; new in G03)
A fill never lowers `s_max`. For the sold asset `F` is unchanged and `N` falls, so `F/N` rises; for the bought asset
`(F + i)/(N + i) ≥ F/N` because `F ≤ N`; `S` is unchanged. Evidence: `testFuzz_exchangeNeverReducesDeliverableShares`
(both directions, premiums up to 200%, a reservation on the bought asset so its ratio is below one) and order 1 of
`test_lpExitShrinksInventoryRoomOfExistingReservation`. The reverse is not true: an exit can reduce what a hook can
sell (CE-2).

### 4.1 Classification

| Property | Argued | Tested | Rests on | Known counterexample to a stronger reading |
|---|---|---|---|---|
| G-1 conservation of claims | yes | invariant | A-1 | — |
| G-2 per-asset solvency | yes | invariant | A-1, A-5 | — |
| G-3 no double allocation | yes | invariant + B | — | CE-1 (reserved ≠ sellable) |
| G-4 share mint and burn | yes | invariant | — | — |
| G-5 FIFO | — | invariant + unit | A-3 for progress | head-of-line (accepted) |
| G-6 claimable protection | yes | invariant + unit | A-2 | CE-5 (blocked receiver) |
| G-7 rounding across partial payouts | yes | fuzz + unit | — | CE-3, CE-4 |
| G-8 no dilution by LP operations | yes | invariant + fuzz | — | — |
| G-9 per-share inventory floor | yes | stateful + Python model | A-4 | loss fraction > κ; Q3; Q4 (G01) |
| G-10 adverse-market limits | yes | partly (floors, caps) | A-4 for value | CE-1, CE-2 |
| G-11 queue vs new commitments | yes | fuzz + unit | A-3 | lazy expiry needs `release` |
| G-12 swaps never reduce exits | yes | fuzz + unit | — | — |

Open questions are in §7.

## 5. Worked examples

Examples B, C, G and H run on the real PoolManager with production builds; D, E and F are on the test-only models of
the proposed designs (§8). A is arithmetic only, using the same formulas.

**A. Two LPs, different times.** `S = 10,000` (LP0 9,000 and `M` 1,000), `N = (10,000, 10,000)`.
1. LP1 buys 1,000 shares for `(1,000, 1,000)`. `S = 11,000`, `N = (11,000, 11,000)`.
2. A hook sells 2,200 asset1 for 2,310 asset0. `N = (13,310, 8,800)`.
3. LP2 buys 500 shares for `(⌈605⌉, ⌈400⌉) = (605, 400)`. `S = 11,500`, `N = (13,915, 9,200)`.
4. LP1 redeems 1,000: `(⌊1,210⌋, ⌊800⌋) = (1,210, 800)` against `(1,000, 1,000)` paid. It held through the trade.
5. LP2 redeems 500: `(605, 400)`, exactly what it paid. It entered after the trade and bore none of it.
The mechanism is exercised with real swaps in `test_demo_threeLps_interleavedSwapsDepositsRedemptions`.

**B. Two hooks, one asset** (`test_twoHooksOneAsset_noDoubleCounting`; 1,000,000 of each asset). Hook A reserves
600,000 and hook M 400,000 of asset1: `Q_1 = N_1`, admissible 0, a third reservation of 1 raw unit is refused. Hook M
sells 100,000: `N_1 = Q_1 = 900,000`, admissible still 0, hook A's 600,000 untouched; hook M cannot take more than its
remaining 300,000. Releasing hook M's remainder makes 300,000 admissible again.

**C. Queued withdrawal while capital is reserved** (`test_queuedRedemptionDuringActiveCommitments`). `S = 2,000,000`,
`N = (2,000,000, 2,000,000)`, 1,800,000 asset1 reserved. An LP redeems 1,000,000 shares: `s_max = ⌊200,000·S/N_1⌋ =
200,000` are paid at once, 800,000 are queued. The queue's demand `D_0 = 800,000` caps new asset0 commitments at
`1,800,000 − 800,000 = 1,000,000`; 1,000,000 + 1 is refused. The commitment is partly consumed, expires and is
released; one `processQueue` call finalizes all 800,000 shares at `⌊800,000·N_a/S⌋` of the traded basket (more asset0,
less asset1), and the claim pays exactly that.

**D. Bond, partial use, early release.** §8; `FUTURE_CAPITAL_AND_YIELD_ACCOUNTING.md` §2.5: bond 86.4, charge 41.472
(LPs 37.3248, protocol 4.1472), refund 44.928.

**E. Positive external yield** and **F. external loss and pause.** §8; design note §3.8.

**G. Concurrent withdrawal and swap demand** (`test_lpExitShrinksInventoryRoomOfExistingReservation`; `τ` = one unit
per share, `κ = 5%`, so 50,000 of asset1 sits above the floor). Hook M holds a 40,000 reservation.
- Fill first: the 40,000 fill succeeds, instant exits do not fall (G-12), then an LP redeems 500,000 shares instantly.
- Exit first: the 500,000-share exit succeeds without touching `Q_1`, but the floor falls with `S` and the room falls
  with it, to `0.05 · 500,000 = 25,000`. The same 40,000 fill is refused (`InventoryFloorBreached(460,000, 475,000)`);
  25,000 can still be sold; 15,000 stays reserved and unsellable until released.

**H. Repeated partial redemptions with rounding** (`test_queueSlices_roundingBoundedBySliceCount`). `S = 11,000`,
`N = (18,777, 7,667)`. An LP buys 5,000 shares for `(8,535, 3,485)` and queues them while all of asset1 is reserved in
five allocations of 1, 1, 7, 1,000 and 10,143.
- Finalized in one slice (everything released first): `(8,535, 3,485)`.
- Finalized in five slices (one release at a time): `(8,533, 3,483)`, two units short per asset, within the bound of
  `k − 1 = 4`. The first slice is one share worth 1.707 asset0 and 0.697 asset1, and pays `(1, 0)`.
- The two units per asset stay in `N` for the other 11,000 shares.

## 6. Counterexamples and limitations

New in G03:

| # | Finding | Evidence | Assessment |
|---|---|---|---|
| CE-1 | **Admission ignores the inventory floor.** A reservation of 200,000 is admitted with 50,000 above `L_1`; after 50,000 is sold the next unit is refused, while the other 150,000 stays in `Q_1` and is withheld from LP exits until released | `test_admissionIgnoresInventoryFloor` | not a solvency defect (`Q ≤ N` holds; LPs are on the safe side). `Q_a` is an upper bound on what hooks can buy, not a promise. Matters for any fee on reserved capacity (design note §2.10, D-6) |
| CE-2 | **LP exits shrink the floor's room under existing reservations.** The room falls by about `s·(h_a − l_a)` when `s` shares leave; a reservation that fit before an exit can be partly unsellable after it, with no parameter change | `test_lpExitShrinksInventoryRoomOfExistingReservation` | by design of a per-share floor; same consequence as CE-1 |
| CE-3 | **The number of slices is not the LP's choice.** Anyone who frees inventory in small steps (a curator releasing small allocations, depositors, a keeper processing after each release) sets `k`, and the request loses up to `k − 1` raw units per asset | `test_queueSlices_roundingBoundedBySliceCount` | bounded: under one raw unit per asset per slice; the units go pro rata to all remaining shares, so the party choosing `k` gains only its own fraction of them. Accepted (R-16) |
| CE-4 | **A slice can pay zero of one asset.** One share worth `(1.707, 0.697)` is finalized as `(1, 0)` | same test | the rule only refuses slices that pay zero in **both** assets; within CE-3's bound |
| CE-5 | **A request's receiver is fixed.** If the pair token refuses that address (blacklist), `claim` reverts and that request's `W` stays locked; the LP cannot redirect it | ARGUED from `claim` (no test with a blacklisting token) | affects only that request: `W` is outside `N`, so other LPs are untouched. R-17 |

Known from earlier phases and re-checked in G03:
- Loss as a fraction of value can exceed `κ`; cumulative realized loss and mark-to-market loss are unbounded (G01
  §7.3).
- Exact T2 without the one-unit allowance fails by under one unit (`test_rounding_exactT2FailsBySubUnit`).
- Head-of-line blocking under strict FIFO (`test_INTENDED_headOfLine_largePartialHead`).
- Instant exits race for free inventory while `P = 0` (first come, first served; exposed to transaction ordering).
- Expiry is lazy: a queued request behind an expired, unreleased allocation waits until someone calls `release`.

**No production defect was found.** No counterexample above breaks a guarantee in §4 as stated; each breaks a stronger
reading of one, and is recorded so that later milestones do not rely on that reading.

## 7. Open questions and owner decisions

Numbered after G02's R-14.

- **R-15.** Admission against the inventory floor: keep the current rule (`Q_a` is an upper bound, CE-1), or add
  `Q_a + q ≤ N_a − L_a`. Recommended before any fee is charged for reserved capacity; it does not address CE-2.
- **R-16.** Slice rounding (CE-3): accept (recommended), or add a minimum slice size, which would need re-denominating
  whenever the basket changes and could hold small requests.
- **R-17.** Fixed receivers (CE-5): accept, or let a request's LP change its receiver for unclaimed amounts (a vault
  change; bytes).
- **Bond and yield decisions** are D-1 … D-12 in the design note (§5 there). The ones that change what LPs or hooks
  are promised are D-6 (paying for capacity that cannot be sold), D-7 (what a share holds when capital is deployed)
  and D-8 (inventory floor and deployment).
- **Open (not a decision):** the guarantees in §4 are hand arguments plus tests; none is machine-checked, and none
  has been reviewed independently.

## 8. Future accounting (specification only)

`docs/architecture/FUTURE_CAPITAL_AND_YIELD_ACCOUNTING.md`. Nothing in it is implemented.

**Reservation bonds (§2 there).** Fee accrues on the unused remainder `r_j` over time, from creation to the earliest of
now, expiry and close: `I_j = ∫ r_j dt`, charged `⌈max(I_j, I_min)·ρ_j⌉`. The bond is the largest possible charge,
prepaid, so refunds are never negative. Partial and full early release, permissionless checkpoints and settlement,
pull refunds. Rounding: down at checkpoints, up at settlement, protocol share on cumulative totals; the totals do not
depend on how often fees are checkpointed. Bonds are held outside the vault and admission reads only `N`, so no bond
is LP backing or another hook's liquidity. A fee becomes LP property when it is realized into `N_φ`, which requires
the fee asset to be a pair asset; queued shares earn until finalized, finalized amounts do not, and transfers (if
shares become transferable) need nothing extra. Fees must be realized before every deposit, or a depositor takes fees
earned before it arrived (43.2 of 86.4 in the model). Model: `test/model/ReservationBondModel.t.sol`, 9 tests.

**Idle ERC-4626 yield (§3 there).** Seven quantities kept apart; commitments, `W`, `D`, `R` and a liquidity buffer stay
physical, and only `max(0, N − Q − R − D − K)`, further capped by `N − Q − L`, may be deployed. Recommended share
semantics: strategy shares held in kind in every LP share's basket, so no valuation is ever made and exits never call
the strategy. The alternative (book value, physical exits) transfers unrecorded losses to remaining LPs unless every
exit re-reads the strategy (400,000 paid against a fair 360,000 in the model). Model:
`test/model/IdleYieldModel.t.sol`, 8 tests.

## 9. Validation

### 9.1 Commands and results

| Command | Commit | Result |
|---|---|---|
| `forge test` (default profile), before any change | `f557664` | 628 passed, 0 failed, 8 skipped |
| `forge test --match-path test/security/LpRounding.t.sol`, `…/ReservationDeliverability.t.sol`, `test/model/*` | each commit | pass (3, 4, 9 and 8 tests) |
| `FOUNDRY_PROFILE=ci forge test` on the four new files (fuzz 10,000 runs) | `ca530d2` | 23 passed, 0 failed |
| `FOUNDRY_PROFILE=ci forge test --match-path test/model/ReservationBondModel.t.sol` | `18cf748` | 9 passed (after the partial-release model change) |
| `FOUNDRY_PROFILE=ci forge test --match-contract "^VaultInvariantsTest$"` (LP accounting campaign, 128 × 128) | `ca530d2` | 35 passed; all 30 invariants `runs: 128, calls: 16384, reverts: 0` |
| `FOUNDRY_PROFILE=ci forge test` on `ShareSecurity`, `QueueGriefing`, `ZeroAssetStates`, `MultiLpAccounting`, `AdmissibleCapacity`, `InventoryProtectionBounds` | `ca530d2` | 54 passed, 0 failed |
| `python3 test/invariant/coverage.py` (non-vacuity gate, 64 single-run campaigns per campaign, depth 128) | `ca530d2` | every gate passed (vault, oracle, inventory, liveness); 7 min 18 s |
| `forge fmt --check` | `18cf748` | clean |
| `git diff f557664 -- src` | `18cf748` | empty: no production source changed, so ABI, storage layout, bytecode and sizes are unchanged |
| `forge test` (default profile) | `18cf748` | **652 passed, 0 failed, 8 skipped** (fork tests, no RPC), 20.6 s. +24: 3 rounding, 4 deliverability, 9 bond-model, 8 yield-model tests |

The model tests use their own non-vacuity check: `test_schedulesExerciseEveryOperation` shows the random bond
schedules execute every operation kind (35 to 106 times over 32 schedules), not only the final settlement sweep.

### 9.2 Mutation checks of the new tests

Each mutant was applied to `src/SharedCommitmentVault.sol`, the named tests run, and the file restored from a copy
(`git diff -- src` empty afterwards). Persisted invariant failures were redirected to a scratch directory.

| Mutant | Tests run | Result |
|---|---|---|
| A: `_entitlement` rounds up (redemptions and slices) | `LpRounding.t.sol` | killed by all three tests (`testFuzz_repeatedRoundTrips_neverGain` only after `ca530d2`, which checks each leg against the state just before it; before that it survived, because the deposit's round-up hides the redemption's) |
| B: inventory-floor check removed from `_floorForFill` | `ReservationDeliverability.t.sol` | killed by `test_admissionIgnoresInventoryFloor` and `test_lpExitShrinksInventoryRoomOfExistingReservation`; the two tests that do not involve the floor pass, as expected |

### 9.3 Deliberately not run

- `test/deep.sh`, the full mutation campaign, Slither, the fork tests and the historical benchmarks: no production
  contract changed, and the brief defers them.
- Production size and gas: `src/` is byte-identical to `f557664` (§9.1), so neither changed.
- No campaign exercises bonds or a strategy against the real vault; they do not exist. The models are unit and fuzz
  tests of the proposed equations only.

## 10. Corrections to earlier documents

- `ACCOUNTING_FLOW.md` §6 and §7 describe the Milestone-0 single-funder model and the blueprint's claims; they are
  marked superseded there and were not relied on. Nothing new to correct.
- `SHARE_ACCOUNTING.md` §3 says LP operations lose "at most 1 wei per asset per operation". Correct per payout; for a
  position leaving in `k` pieces the bound is `k − 1` against a single payout (G-7), which that document does not
  state. Not edited; G-7 here is the reference.

## 11. G03 result

**G03: PASS (local).**

- The ledger was rebuilt from the code (§2): every balance change of every path, including donations, and the
  checks each path reads. Every relation the existing documents state holds in the code.
- Twelve LP guarantees are stated with status and evidence (§4), separating argued, tested, assumed and refuted
  readings. The inventory floor is stated as a per-share unit floor, not an economic loss bound.
- Five new counterexamples to stronger readings (§6), each reproduced or argued; none is a production defect, so no
  production code changed.
- Rounding across partial payouts is now bounded and tested: splitting never pays more, and loses at most `k − 1` raw
  units per asset over `k` payouts.
- Bond and idle-yield accounting are specified as proposals with reference models (§8), not implemented.
- Validation (§9) passed at the CI profile for everything touched, with the coverage gate; deep, mutation-campaign,
  fork and benchmark runs were deferred because no production contract changed.

Decisions for the owner: R-15 … R-17 (§7) and D-1 … D-12 (design note §5). Nothing was pushed, merged, deployed or
published. `AGENTS.md` (untracked) was not touched.

## 12. Commits

Branch `phase-2-g03-lp-accounting` from `f557664`:

| Commit | Subject |
|---|---|
| `c9628a3` | test: cover repeated partial withdrawal rounding |
| `683f051` | test: show reserved capacity can exceed what the inventory floor lets hooks sell |
| `80f7ad3` | test: model reservation-bond fee accounting |
| `7607d5d` | test: model idle-vault custody with in-kind external shares |
| `ca530d2` | test: check each round-trip leg against the state before it |
| `811f0bc` | test: add partial early release to the bond model |
| `e0551ed` | docs: separate bond collateral from LP assets |
| `18cf748` | docs: specify idle-vault liquidity requirements |
| (this commit) | docs: define LP asset and withdrawal liabilities |
