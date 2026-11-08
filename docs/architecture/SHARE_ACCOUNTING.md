# Share and Redemption Accounting — Phase 1A

This document specifies the multi-LP ownership and two-tier redemption model in
`src/SharedCommitmentVault.sol`. Each claim is labelled:

- **VERIFIED**: an executable Foundry test or invariant on the real PoolManager checks it. The test is named.
- **ARGUED**: a derivation in this document. It is not machine-checked and has not been formally verified.
- **UNRESOLVED**: a known open case. Nothing in the code or tests settles it.

This is **not** an ERC-4626 vault. There is no single underlying asset and no on-chain valuation. A share is a
fraction of *both* asset balances, delivered in kind.

## 1. State

All quantities are per asset `a ∈ {asset0, asset1}`, except the share counts.

| Symbol | Meaning | Storage |
|---|---|---|
| `B_a` | Accounted backing: ERC-6909 claims the vault owns | `backing[a]` |
| `Q_a` | Committed capacity: Σ (maxOut − consumed) over unreleased allocations | `reserved[a]` |
| `W_a` | Claimable: assets finalized for queued requests, not yet claimed | `claimableAssets[a]` |
| `N_a` | Net assets owned by outstanding shares: `B_a − W_a` | derived: vault `_netAssets(a)`; read with `VaultLens.netAssets(vault, a)` |
| `F_a` | Immediately deliverable inventory: `N_a − Q_a` | derived; read with `VaultLens.freeInventory(vault, a)` |
| `R_a` | Admission floor for new allocations | `bufferFloor[a]` |
| `S` | Outstanding shares, **including** escrowed pending shares and the locked `M` | `totalShares` |
| `P` | Shares escrowed in the queue that are not yet finalized | `pendingShares` |
| `D_a` | Pending demand `⌈P · N_a / S⌉` (0 when `P = 0`) | derived: vault `_pendingDemand(a)`; read with `VaultLens.pendingDemand(vault, a)` |
| `M` | `MIN_SHARES = 1000`, held by `address(0)` forever | `sharesOf[address(0)]` |
| `s_i` | Free (un-escrowed) shares of account `i` | `sharesOf[i]` |

The real ERC-6909 balance `PM.balanceOf(vault, a)` is at least `B_a`. The two are equal unless someone transfers claims
to the vault without going through it (a "donation"). Donations are deliberately left out of `B_a` (§7).

Each queued request `r` stores `lp`, `receiver`, `sharesRequested`, `sharesPending`, `claimable0`, `claimable1`
and `canceled`.

## 2. Operations and equations

Rounding in each formula below always favours the vault, meaning the remaining holders.

| Operation | Effect |
|---|---|
| `initialDeposit(x0, x1, receiver)` (**owner only**; requires `S = 0`, `x0, x1 > 0`) | `S := ⌊√(x0·x1)⌋`; requires `S > M`; owner pays; `receiver` gets `S − M`; `M` locked; `B_a := x_a`. Runs at most once, since `S ≥ M` afterwards. |
| `deposit(s)` | pays `x_a = ⌈s · N_a / S⌉` of each asset, bounded by `maxAmount_a`; `S += s`; `B_a += x_a` |
| entitlement of `s` shares | `e_a(s) = ⌊s · N_a / S⌋` |
| deliverable shares | `s_max = min over a with N_a > 0 of ⌊F_a · S / N_a⌋` (∞ if both `N_a = 0`) |
| `redeem(s)`, inline queue step | if `P > 0`: first run up to `INLINE_QUEUE_STEPS = 4` steps of `processQueue` (Phase 1A-H) |
| `redeem(s)`, instant part | `s_inst = min(s, s_max)` **only if `P = 0` after the inline step**, otherwise 0; pays `e_a(s_inst)`; `S −= s_inst`; `B_a −= e_a` |
| `redeem(s)`, queued part | `s − s_inst` moves from `s_i` into a new request; `P += s − s_inst` (S unchanged) |
| `processQueue`, per head request `h` | `s = min(pending_h, s_max)`; `e = e_a(s)`; `pending_h −= s`; `claimable_h += e`; `W_a += e`; `P −= s`; `S −= s` |
| `cancelRequest(r)` (request LP only) | `s_i += pending_r`; `P −= pending_r`; `pending_r := 0` |
| `claim(r)` (request LP only) | pays `claimable_r`; `W_a −= claimable_r,a`; `B_a −= claimable_r,a` |
| `allocate(q)` | requires `Q_a + q + R_a + D_a ≤ N_a`; `Q_a += q` |
| `exchange(i, o)` (registered hook) | requires `o ≤ remaining`, `i ≥ ⌈o · floor / 2^96⌉`; `Q_out −= o`; `B_out −= o`; `B_in += i` |
| `release` | `Q_out −= maxOut − consumed` |

Further rules:

- **Queue order.** `processQueue` walks forward from `queueHead`, skipping canceled or finished requests. It stops at
  the first request it cannot finish. It never finalizes a later request while an earlier one still has pending
  shares.
- **Dust.** A partial slice is never finalized if both `e_a` are 0. A redemption whose own entitlement is 0 in both
  assets reverts with `DustRedemption`.

## 3. No dilution (ARGUED; VERIFIED by invariant and tests)

**Claim.** Deposits, instant redemptions, finalization, cancellation and claims never reduce `N_a / S` for any asset.
Only trades (`exchange`) change the per-share basket, and they always do so through both assets.

| Operation | Derivation |
|---|---|
| deposit | `N'_a = N_a + ⌈s N_a / S⌉ ≥ N_a (S + s) / S` ⇒ `N'_a / S' ≥ N_a / S` |
| instant redeem / finalize | `N'_a = N_a − ⌊s N_a / S⌋ ≥ N_a (S − s) / S` ⇒ `N'_a / S' ≥ N_a / S`. `S − s ≥ M > 0` because `M` is never redeemable. |
| cancel | `S`, `N_a` unchanged (shares move from `P` back to `s_i`) |
| claim | `B_a` and `W_a` fall by the same amount, so `N_a` and `S` are unchanged |
| queued request | `S`, `N_a` unchanged |

Evidence:

- `invariant_noDilutionByLpOperations`: a ghost cross-multiplication check `N'_a·S ≥ N_a·S'` after every successful
  LP action.
- `test_depositAfterTrades_doesNotDiluteExistingHolders`.
- `testFuzz_depositRedeemRoundTrip_neverProfitable`: the round trip loses at most 1 wei per asset and never gains.
- Mutation tests: rounding a deposit down (M3) or a redemption up (M4) makes these fail.

**Consequence.** Depositing and redeeming in a single block is never profitable. The maximum loss is 1 wei per asset per
operation.

## 4. Solvency (ARGUED per function; VERIFIED by invariants)

**Claim.** After every external call:

- (S1) `Q_a + W_a ≤ B_a ≤ PM.balanceOf(vault, a)`
- (S2) `W_a = Σ_r claimable_r,a`
- (S3) `P = Σ_r pending_r`
- (S4) `S = Σ_i s_i + P`

**Case analysis for (S1).** Write it as `F_a ≥ 0`.

- `allocate`: the admission check gives `Q'_a = Q_a + q ≤ N_a − R_a − D_a ≤ N_a`.
- `exchange`: `o ≤ remaining_j ≤ Q_a`. So `Q_a` and `B_a` both fall by `o`, and `B_in` rises.
- Instant redeem: `e_a(s_inst) ≤ F_a`, because `s_inst ≤ ⌊F_a S / N_a⌋` implies `⌊s_inst N_a / S⌋ ≤ F_a`. `B_a` falls
  by at most `F_a`.
- Finalize: the same bound applies. `W_a` rises by `e_a ≤ F_a`.
- `claim`: `B_a` and `W_a` fall by the same amount.
- `release`: `Q_a` falls.
- `deposit`: `B_a` rises.

The upper bound `B_a ≤ balanceOf` holds because every change to `B_a` is paired, in the same transaction, with an
equal ERC-6909 mint, burn or transfer on the real PoolManager.

**Evidence (VERIFIED):**

- `invariant_reservedIsExactAndBacked`, `invariant_backingEqualsRealClaims`, `invariant_ghostLedgerConservation`.
- `invariant_sharesAndQueueConserved`, which checks (S2), (S3), (S4), `S ≥ M`, and that no request behind
  `queueHead` still has pending shares.
- `_assertAccountingConsistent`, which runs after most tests.

**What this gives:**

- Outstanding commitments stay backed: `Q_a ≤ N_a ≤ B_a`.
- Claimable redemption assets stay funded: `W_a ≤ B_a`, and no path other than `claim` reduces `W_a`.
  `test_claimableAssetsAreRingFenced` lets a hook consume a new commitment fully. Another LP is refused, and the claim
  still pays exactly what was finalized.

## 5. No double redemption or claim (VERIFIED)

- Shares leave `s_i` before anything is paid. They are either burned (instant) or escrowed (queued). Escrowed shares
  can only be finalized once, because `pending_r` is decremented, or returned once by `cancelRequest`, which zeroes
  `pending_r`.
- `claim` zeroes `claimable_r` before the external unlock.
- Only `lp_r` can cancel or claim request `r`.

Evidence:

- `invariant_noDoubleClaim`: for every request, ghost claimed + claimable = ghost finalized.
- `test_sharesCannotBeRedeemedTwice`, `test_requestAuthority`, `test_cancel_returnsPendingShares_statusTransitions`.
- Mutations M5 (claim does not clear the request) and M8 (cancel does not release pending) are caught.

## 6. Two-tier redemption: fairness and liveness

### 6.1 Policy

1. **Instant tier.** An LP may take its full in-kind entitlement for as many shares as free inventory can deliver in
   *both* assets (`s_max`). It may do this **only while no shares are pending.** Any remainder is either queued or
   the call reverts (`InsufficientLiquidity`), at the caller's choice.

   **Phase 1A-H.** If shares are pending, `redeem` first runs up to `INLINE_QUEUE_STEPS = 4` FIFO steps of the queue,
   then applies the rule above. This stops a request that is already deliverable but unprocessed from blocking every
   instant exit. Earlier requests are still finalized first, in the same transaction, and the redeemer's extra gas is
   bounded.
2. **Queue.** Strict FIFO by request id. Partial fills happen only at the head. Escrowed shares keep their full economic
   exposure (fees, trades) until the moment they are finalized. At that point they are converted at
   `⌊s · N_a / S⌋`, which is the same rate every other share would get in that block.
3. **States** (`VaultLens.requestStatus(vault, id)`, derived from `getRequest`):

   | State | Condition |
   |---|---|
   | `Pending` | `pending > 0` (claimable may also be > 0 after a partial fill) |
   | `Claimable` | `pending = 0` and `claimable > 0` |
   | `Completed` | everything finalized and claimed, not canceled |
   | `Canceled` | canceled and nothing left to claim |

   Finalized amounts stay claimable after cancellation.

This refines the Phase-0 proposal in `ACCOUNTING_FLOW.md` §6.4. That proposal paid only a fraction of `F_a` per share,
which would have under-paid redeemers. Here, shares are always burned at the full per-share basket, and `F_a` only
limits *how many* shares can leave now.

### 6.2 Fairness (VERIFIED)

- **No stale-queue denial of service** (Phase 1A-H). A pending request that free inventory could already serve is served
  by the next redeemer's inline step, and that redeemer then exits instantly
  (`test_DOS_staleDeliverableEntry_doesNotBlockInstantExit`, `test_interleaved_depositSwapCancelEmergencyRelease`).
  Both failed before the fix; mutation H1 is caught.
- **No queue jumping.** While `P > 0` after the inline step, a new redeemer is queued in full. `test_fifoFairness_competingRequests` shows
  this, and mutation M1 is caught.
- **FIFO ordering.** `invariant_fifoOrdering` checks that no later request has any finalized shares while an earlier
  one is pending. Mutation M6 is caught.
- **Equal treatment.** Equal requests finalized in the same call receive identical baskets
  (`test_fifoFairness_competingRequests`). A queued LP ends with the same per-share basket as an identical LP who held
  (`test_pendingSharesKeepPnL_sameAsHolding`, within 1 wei of floor rounding).
- **Protected capacity.** Pending demand is protected from new commitments through `D_a` in the admission rule
  (`test_queuedRedemptionDuringActiveCommitments`; mutation M2 is caught).

**Accepted property (not a bug).** Requests finalized at *different* times receive different baskets, because the
basket composition changes with trades in between. Holding shares carries the same exposure. This is the in-kind
liability model the human owner approved. A pro-rata epoch model is an alternative that would finalize all pending
requests at one rate (§9).

### 6.3 Liveness (ARGUED + fuzz-tested; not proven)

**Claim.** Let request `r` be created at time `t_r`. Let `A_r` be the set of allocations live at `t_r`. Once every
allocation in `A_r` has been consumed or released, `processQueue` can fully finalize `r` and every request before it.
This holds whatever allocations were admitted after `t_r`, whatever trades occur, and whatever later requests or
cancellations happen. Each allocation in `A_r` expires within `MAX_HORIZON = 30 days` of `t_r`, and `release` is
permissionless after expiry.

**Argument.** Let `P'` be the pending shares of `r` and all earlier requests, and `D'_a = P' · N_a / S`.

1. An allocation admitted after `t_r` satisfied `Q + q + R + D ≤ N` at admission, with `D ≥ D'`. So right after it,
   `F_a ≥ D'_a`.
2. No later event lowers `F_a − D'_a`:
   - *Consumption*, out side: `F` unchanged, `D'` falls.
   - *Consumption*, in side: `F += i`, `D' += i · P'/S ≤ i`.
   - *Deposit*: `F += x`, `D' += x · P'/S ≤ x`.
   - *Release*: `F` rises.
   - *Claim*: `F` unchanged.
   - *Cancel of an earlier request*: `D'` falls.
   - *Finalization of an earlier request*: `F` and `D'` fall by `e` (up to rounding in the remaining holders'
     favour).
   - *Later requests*: do not change `F` or `D'`.
   - *Instant redemptions*: impossible while `P > 0`.
3. Once `A_r` is gone, every live commitment was admitted after `t_r`. So `F_a ≥ D'_a ≥ Σ e_a` for `r` and all earlier
   requests, and the FIFO walk finalizes all of them.

**Evidence.** `testFuzz_queueDrainsAfterHorizon` (1,000 runs; 10,000 under the `ci` profile, §8 of the report) uses
random pre-existing commitments in both assets, two requests, and a curator who then reserves as much as admission
allows for 20 days. It also adds trades on the old commitment, releases only the pre-request commitments, and
asserts `P = 0`.

**What is NOT promised:**

- **No nominal payout.** The amount is in kind at finalization.
- **No unconditional deadline.** The bound needs someone to call `release` (for expired allocations) and
  `processQueue`. Both are permissionless, but nothing calls them automatically.
- **Owner emergency release only accelerates.** The owner can release a commitment early (§8), but cannot delay one.

## 7. Donations, inflation attacks, decimals (VERIFIED)

- **Donations.** ERC-6909 claims sent directly to the vault (`test/utils/ClaimDonor.sol`) do not change `B_a`, share
  price, or deliverable capacity. They are stranded, not owned by anyone
  (`test_donation_toLiveVault_doesNotMoveSharePrice`).
- **First-depositor inflation attack.** The attack fails for three reasons:
  - donations are not counted;
  - deposits are denominated in shares, so a depositor never "rounds to zero shares";
  - `M = 1000` shares are locked.

  `test_inflationAttack_firstDepositorCannotStealFromVictim`: the attacker seeds 1001/1001 wei and donates 2,000e18.
  The victim's deposit is priced as if no donation happened, and the victim exits within 1 wei per asset. The
  attacker recovers 2 wei.
- **Initialization minimum.** `⌊√(x0·x1)⌋` must exceed `M` (`test_initialDeposit_minimumAndLockedShares`).
- **Decimals.** The deposit and redemption rules are unit-free ratios. Only the initial geometric mean depends on
  units, and it only sets the share scale. `test_decimals_6and18` covers a 6/18-decimal pair; the round trip is exact
  to 1 wei per asset.

## 8. Fees, gains, losses, owner powers

- **No protocol, curator or performance fee exists** (out of scope).
- **Trading results accrue pro rata.** HookA's utilisation fee and HookB's impact are retained in `amountIn`, so they
  accrue to `B_in` and therefore pro rata to all `S`, including pending shares.
- **"Realized" gains and losses** are changes in basket composition. Nothing is marked to a price.
- **The only on-chain economic bound** on a trade is the curator's floor: `i ≥ ⌈o · floor / 2^96⌉`. Valued at the
  floor price, the vault's holdings do not decrease on any trade. Valued at a market price, they can (adverse
  selection). That is LP risk bounded by quota × (fair price − floor), and it is **not** prevented.
- **The owner has no asset path.** The M0 `deposit(currency, amount)` and `withdraw` functions are removed.
  `test_ownerHasNoPathToShareholderAssets` probes the old selectors. The owner can:
  - pause inflows, commitments and consumption (never exits, per `test_pause_blocksInflowsAndCommitments_notExits`);
  - register consumers, set ceilings and floors;
  - emergency-release commitments.

  None of these moves assets.

## 9. Unresolved cases and limitations

1. **Liveness needs callers.** It depends on `release` and `processQueue` being called; there is no keeper incentive.
2. **Queue spam, and the cost of processing it.**
   - **Creating a request** costs about 145k gas for the vault frame.
   - **Finalizing a live request** costs about 120k isolated, or about 32k per request warm in a batch.
   - **Skipping a canceled request** is cheaper still: `processQueue` over 10 canceled + 1 live entry measured
     144,856 gas, against 120,726 for one live entry alone.
   - So a spammer pays more than processors do. Spam cannot reorder or block the queue.
   - **Phase 1A-H** adds that a redeemer may pay for up to 4 inline steps; the inline attempt when the head is blocked
     measured +10,737 gas.
   - No minimum size or bond was added (approved decision 3). A size floor in share units would have to be
     re-denominated whenever the per-share basket changes, and it would block legitimate small holders.
3. **Curator griefing.** A large LP can queue, which blocks new commitments through `D_a`, and then cancel. The effect
   is bounded by that LP's share. A cancel cooldown is a possible fix (decision).
4. **Race for free inventory.** While `P = 0`, instant redemptions are first-come-first-served by transaction order and
   are exposed to MEV ordering.
5. **Initialization (resolved in Phase 1A-H).** `initialDeposit` is owner-only, and the asset pair is fixed in the
   constructor. Before initialization, nothing an attacker can do changes the owner's outcome: deposit, redeem,
   processing and allocation all revert, and donations are ignored (`Initialization.t.sol`).
6. **Shares are not transferable** (no ERC-20 or ERC-6909 share token in Phase 1A).
7. **Zero-asset edge cases** (Phase 1A-H). See §10.
   - The both-assets-zero `DustRedemption` branch is now exercised.
   - The `NoAssets` state (`S > 0`, `N_0 = N_1 = 0`) is **unreachable** (§10.1). Its revert is defensive only and not
     exercised by tests.
   - **Head-of-line** under strict FIFO is a documented tradeoff, not eliminated: a large head request absorbs every
     unit of freed inventory before anyone behind it (`test_INTENDED_headOfLine_largePartialHead`).
8. **Caps.** `B_a` and `S` are capped at `int128.max`. Swaps that would push `B_in` beyond that revert.
9. **Unanalysed token behaviour.** Fee-on-transfer tokens fail closed at deposit (`SettlementMismatch`), but no test
   uses such a token. Rebasing and ERC-777 tokens are unanalysed.
10. **Formal methods.** Nothing in this document is formally verified. The invariant campaign is bounded (§8 of
    `PHASE1A_REPORT.md`).

## 10. Zero-asset, depleted and dust states (Phase 1A-H)

### 10.1 Reachability: `N_0 + N_1 > 0` while `S > 0` (ARGUED; checked by `invariant_equationsFromRawSources`)

After initialization both `N_a > 0`. Go through each operation:

- **Trade.** It lowers only `N_out`. It raises `N_in` by `amountIn ≥ 1`, because `exchange` rejects a zero input.
- **Redemption or finalization.** For any `N_a > 0`, `e_a = ⌊s N_a / S⌋ < N_a`, because `s ≤ S − M < S` (the locked
  `M` can never be redeemed). So no positive balance reaches zero this way.
- **Claim.** Leaves `N_a` unchanged.
- **Deposit.** Only raises `N_a`.

So at most one asset can be at zero at a time, and only because of a trade. Both at zero cannot happen.

### 10.2 Defined behaviour

| State | Behaviour | Evidence |
|---|---|---|
| `N_a = 0` for one asset | That asset is skipped in `s_max`. Its `D_a = 0` and admission `= 0` (no commitment of an absent asset). Deposits pay 0 of it and `⌈s N_b / S⌉ ≥ 1` of the other, so shares are always backed. Redemptions and claims pay a zero leg, and the zero transfer is skipped. A later trade brings the asset back. | `test_asset1AtZero_definedBehaviour`, `test_asset0AtZero_mirror` |
| Both `N_a = 0` | Unreachable (§10.1). Defensive behaviour if it were reached: `deposit` → `NoAssets`; `redeem` → `DustRedemption`; queued requests finalize at zero. | proof + invariant |
| Redemption rounds to 0 in both assets | Fully instant → `DustRedemption` (shares are not burned for nothing). Queued remainder → `DustRedemption`. A partial instant slice that is dust → the whole request is queued. | `test_bothAssetsZero_unreachable_nearTotalDepletionIsEconomic` |
| Head slice rounds to 0 but the request has more pending | Not finalized; the head waits for inventory, and no shares are burned. | `test_dustPartialSlice_isNotFinalized` (mutation H5) |
| A whole pending request rounds to 0 | Finalized at zero, status `Completed`. Not trapped, and it does not block the queue. | `test_dustPendingRequest_finalizesAtZero_notTrapped` |
| Near-total depletion (e.g. `N = (0, 1 wei)`) | Accounting identities still hold, and shares are worth under 1 wei. New deposits are fully backed, but the `int128` share cap limits new value to a tiny amount: the vault is terminal in practice. | same test |
| Emptied vault (only `M` remain) | Normal re-entry at a basket of about `N/M`; round trip is exact. | `test_emptiedVault_reentry` |
| Uninitialized vault | `previewDeposit` → `NotInitialized` (was `NoAssets`); `deliverableShares` = 0 (was `type(uint256).max`); `previewRedeem` = (0, 0); every other view = 0 (these previews are `VaultLens` functions since Phase 1B-2 step 1); `processQueue` is a no-op. | `test_uninitializedVault_viewsAndCallsNeverDivideByZero` |

### 10.3 Economic loss vs accounting error

The depletion tests use a **registered** hook and a curator floor of 0, so these are *authorised* trades. LPs lose value,
and pending requests share the loss pro rata: `D_a` protects their *capacity*, not their *value*
(`test_pendingRequest_capacityProtected_valueSharesLoss`).

After every step, `_assertEquations` re-derives `N`, `F`, `D` and admission from raw PoolManager balances and storage,
and they match. The losses are economic, not accounting errors. The control that bounds them is the curator floor; the
Phase 1B minimum execution-price policy (approved decision 7) is the planned independent bound.
