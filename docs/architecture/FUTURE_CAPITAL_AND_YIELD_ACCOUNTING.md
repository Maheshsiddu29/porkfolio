# Future Capital and Yield Accounting: Reservation Bonds and Idle ERC-4626 Yield

**Status: PROPOSAL. Nothing in this note is implemented.** `src/` has no reservation fee, no bond escrow, no protocol
fee and no yield adapter. The reference models in `test/model/` are test-only contracts that check the proposed
equations with exact integers; they hold no protocol state and are not designs for deployment.

Labels used here:
- **PROVEN (model)**: argued in this note and checked by a model test.
- **ARGUED**: argued in this note, not tested.
- **REQUIREMENT**: a condition a future implementation must meet.
- **DECISION**: an open choice for the owner; numbered D-1, D-2, … and listed in §5.

Notation follows `src/SharedCommitmentVault.sol` and `docs/security/G03_LP_ACCOUNTING.md` §2: per asset `a`,
`B_a` accounted ERC-6909 backing, `Q_a` unused reserved capacity, `W_a` finalized unclaimed withdrawals,
`N_a = B_a − W_a`, `F_a = N_a − Q_a`, `R_a` buffer floor, `D_a = ⌈P·N_a/S⌉`, `S` shares, `P` pending shares,
`L_a = ⌈S·τ_a·(1 − κ_a)⌉` the inventory floor.

## 1. What any extension must preserve

The current vault keeps the following, and G03 §4 records the evidence for each. A bond or yield extension that breaks
one of them changes what LPs were promised, and must be decided as such, not slipped in.

| # | Property | Where it comes from |
|---|---|---|
| P-1 | `PM.balanceOf(vault, a) = B_a + X_a`, where `X_a ≥ 0` is uncounted donated claims, and every change of `B_a` is paired with an equal claim movement in the same transaction | custody design; G03 G-1 |
| P-2 | `Q_a + W_a ≤ B_a` for both assets | G03 G-2 |
| P-3 | A new reservation is admitted only if `Q_a + q + R_a + D_a ≤ N_a` | `reserveFor`; G03 G-3, G-11 |
| P-4 | No LP-only operation lowers `N_a / S` for either asset | rounding directions; G03 G-8 |
| P-5 | LP exits (redeem, queue processing, cancel, claim) call no oracle, no strategy and no module, and are not stopped by pause, halts or caps | G01 / G02 S-1(d) |
| P-6 | Strict FIFO queue; `W_a` reachable only through `claim` | G03 G-5, G-6 |
| P-7 | Every fill pays at least the price floors and leaves `N_a ≥ L_a` | `_floorForFill`; G03 G-9 |
| P-8 | Donated claims are never counted | G03 G-1 |

**Byte budget.** The vault runtime is 22,440 bytes, 2,136 under EIP-170 (G02 §13). Neither extension below fits in
the vault. Both are specified as separate modules with the smallest vault interface that keeps P-1 … P-8.

## 2. Reservation bonds

A hook or curator that wants exclusive access to a fixed quantity of one asset for a fixed period escrows fee
collateral, and LPs are paid for the capital they keep reserved over time.

### 2.1 Objects and units

A reservation `j` has:

| Field | Meaning | Units |
|---|---|---|
| `a_j` | asset the vault sells under it | — |
| `A_j` | reserved amount | raw units of `a_j` |
| `t_c` | creation: the time `Q_a` rises | seconds |
| `t_s` | first time it may be consumed, `t_c ≤ t_s` | seconds |
| `t_1` | expiry, `t_1 ≤ t_c + MAX_HORIZON` | seconds |
| `ρ_j` | fee rate, fixed at creation | fee raw units per reserved raw unit per second, scaled by `RATE_SCALE` |
| `φ` | fee asset; **one of the pair's two assets** (§2.7, D-1) | — |
| `payer_j` | posted the bond; receives every refund | address |
| `r_j(t)` | unused remainder: `A_j` minus consumed minus released | raw units of `a_j` |
| `I_j(t)` | reserved unit-seconds, `∫ r_j(u) du` over `[t_c, min(t, t_1, t_close))` | raw unit-seconds |
| `Y_j` | bond | raw units of `φ` |
| `C_j` | fee realized so far (LP part + protocol part) | raw units of `φ` |

**`RATE_SCALE` (REQUIREMENT).** The model uses `1e18`. That is too coarse in general: with an 18-decimal sold asset
and a 6-decimal fee asset, a 1%-a-year fee on a $1 token is about `3.2e-22` fee units per reserved unit per second,
which a `1e18` scale rounds to zero. A scale of `1e36` keeps nine significant digits for rates down to
`1e-27`; `I_j·ρ_j` is then up to about `2^149 · 2^120`, so the product must be taken with a 512-bit `mulDiv` (as
`FullMath` does).

### 2.2 The fee base: reserved capital over time

The fee accrues on `r_j`, the capacity still withheld from LPs, and nothing else:

    fee earned by j up to t  =  floor(I_j(t) · ρ_j / RATE_SCALE)

Why each choice:
- **`r_j`, not `A_j`.** `r_j` is exactly this reservation's contribution to `Q_a`, which is what blocks LP exits
  (`F_a = N_a − Q_a`) and new admissions. Units already sold are no longer blocking anything; their input asset is in
  `N` and free.
- **From `t_c`, not `t_s`.** `Q_a` rises at creation. A forward-starting reservation blocks LP capital before it can be
  used, so it pays from creation. (The first implementation can simply require `t_s = t_c`.)
- **Stops at `t_1`.** Release is lazy (G03 §2.2): an expired reservation keeps its `Q_a` until someone calls
  `release`. The hook cannot use it after `t_1`, so it is not charged for the delay. Lazy expiry is a liveness cost to
  LPs, addressed by permissionless settlement, not by billing the hook.
- **No volume term (REQUIREMENT).** Consuming `x` units stops accrual on them exactly as releasing them would, and
  earns no rebate. A hook that trades against its own reservation to "use it up" pays at least the floor price for the
  output and gets nothing a release would not give it, so manufactured volume buys nothing. Fees for trading itself
  stay where they are today: in the hook's spread, retained in `amountIn`.

The fee is charged for `Q`, but `Q` is not always sellable: see §2.10.

### 2.3 Bond, charge and refund (PROVEN (model))

    Y_j       = ceil(A_j · (t_1 − t_c) · ρ_j / RATE_SCALE)            posted at creation, in full
    I_min,j   = A_j · min(T_min, t_1 − t_c)                           minimum charge in unit-seconds
    charge_j  = ceil(max(I_j, I_min,j) · ρ_j / RATE_SCALE)            at settlement
    refund_j  = Y_j − charge_j

`I_j ≤ A_j (t_1 − t_c)` because `r_j ≤ A_j` and accrual stops at `t_1`; `I_min,j ≤ A_j (t_1 − t_c)` by definition.
So `charge_j ≤ Y_j` and the refund is never negative: the bond always covers the largest possible fee, in units,
whatever happens to prices. Prepaying the maximum is what makes the reservation fail closed: there is no later debt to
collect.

`T_min` (D-3) makes reserving and immediately releasing cost something. Without it, a party could reserve all
admissible capacity for one block to push arriving LPs into the queue or to block other curators, for free
(`test_minimumCharge_onImmediateRelease`).

### 2.4 Lifecycle and who may call

| Action | Caller | Effect | Accrual |
|---|---|---|---|
| create | the authorization module (curator signature or direct call, as today) | `Q_a += A_j`; bond pulled into escrow **in the same transaction**; reverts if either fails | starts |
| consume `x` | the reservation's consumer hook, in `beforeSwap` (`exchange`) | `r_j −= x`, `Q_a −= x`, `N_a −= x` | accrued to now first |
| partial early release `x` | payer (or its curator, D-4) | `r_j −= x`, `Q_a −= x` | accrued to now first |
| full early release | payer / curator; owner or guardian in an emergency | `Q_a −= r_j`, `r_j = 0`, closed | accrued to now; stops |
| expiry | nobody (time) | nothing changes in storage | clipped at `t_1` |
| checkpoint | anyone, any time | moves `floor(I·ρ) − C_j` into the vault and the protocol bucket | accrued to now |
| settle | anyone, once closed or expired | releases any remainder, charges `charge_j`, credits `refund_j` to `payer_j` | final |
| claim refund / protocol fees | payer / protocol recipient | pull from escrow | — |

**Replay protection (REQUIREMENT).**
- Creation is bound to the authorization module's single-use curator nonce and EIP-712 domain, as allocations are
  today; each reservation gets a new id, so one instruction can never produce two reservations or two bonds.
- The bond moves in the transaction that raises `Q_a`, so neither can exist without the other.
- `settle` sets a terminal flag; a second call reverts (`test_exampleD_partialUseAndEarlyRelease`).
- `checkpoint` realizes up to a cumulative target, so repeating it moves nothing extra; accrual time only moves
  forward.
- Refunds are credited, not pushed.

**Permissionless where safe.** `checkpoint` only moves fees already earned, rounded down, so anyone may call it.
`settle` is open to anyone once the reservation is closed or past `t_1`, because nothing it does depends on the
caller and the refund always goes to `payer_j` (`test_permissionlessSettlementAfterExpiry_stopsAtExpiry`). Early
release before `t_1` stays with the payer or curator (it ends a commitment the hook paid for) and with the owner or
guardian as an emergency measure, as `release` is today.

### 2.5 Rounding, dust and partial settlements (PROVEN (model))

- A checkpoint realizes `floor(I·ρ / RATE_SCALE) − C_j`: rounded down, so nothing is realized that has not been earned.
- Settlement realizes `ceil(max(I, I_min)·ρ / RATE_SCALE) − C_j`: rounded up, against the payer, by less than one
  raw unit per reservation, and that unit goes to LPs and the protocol.
- The protocol's cumulative part is `floor(C_j · π / 10,000)` and the LP part is the rest. Both are computed on
  cumulative totals, so the per-step differences telescope.

Consequences, each checked over 1,000 random schedules with consumption, partial and full release, checkpoints and
settlement (`testFuzz_conservationAndExactCharge`, `testFuzz_checkpointsArePathIndependent`,
`test_schedulesExerciseEveryOperation`):
1. Every settled reservation is charged exactly `ceil(max(I, I_min)·ρ / RATE_SCALE)`, however many checkpoints ran.
2. LPs and the protocol receive the same totals, to the unit, with or without intermediate checkpoints.
3. `bonds posted = fees moved to LPs + escrow`, and the escrow equals unearned bond + unclaimed protocol fees +
   unclaimed refunds, after every step.
4. No reservation is ever charged more than its bond.

**Example D** (`test_exampleD_partialUseAndEarlyRelease`; `ρ = 1e-9` per second, about 3.15% a year when fee and sold
asset have equal value; protocol share 10%):

| Day | Event | `r` | `I` (token-days) | Realized | LP | Protocol |
|---|---|---|---|---|---|---|
| 0 | reserve 100,000; bond `100,000 · 864,000 s · 1e-9` | 100,000 | 0 | — | — | — |
| 2 | hook sells 30,000 | 70,000 | 200,000 | — | — | — |
| 5 | keeper checkpoints | 70,000 | 410,000 | 35.424 | 31.8816 | 3.5424 |
| 6 | hook releases the rest early | 0 | 480,000 | — | — | — |
| 6 | settle | — | 480,000 | 41.472 | 37.3248 | 4.1472 |

Bond 86.4, charge 41.472, refund 44.928. `T_min` = 1 day does not bind (`I` far exceeds 100,000 token-days).
A partial early release of 60,000 on day 1 of the same reservation, held to expiry, charges
`100,000·1 + 40,000·9 = 460,000` token-days, 39.744 tokens (`test_partialEarlyRelease`).

### 2.6 Bond collateral is neither LP backing nor another hook's liquidity

**Claim (ARGUED; PROVEN (model) for the ledger part).** Under the requirements below, no unit of refundable bond
collateral is ever counted in `B_a`, `N_a`, `F_a`, `E_a` or admissible capacity, and no bond can pay for another
reservation's capacity or fee.

Requirements:
- **R-B1 (custody).** Bonds are held by a separate escrow contract, not as vault ERC-6909 claims and not as vault
  ERC-20 balances.
- **R-B2 (one inflow path).** Escrow-to-vault transfers happen only as fee realization: the escrow moves `x ≤ earned_j
  − C_j` of `φ` to the vault through a dedicated vault entry point (only the escrow may call it) that raises `B_φ` by
  `x` with an equal claim inflow and mints no shares.
- **R-B3 (per-reservation buckets).** The escrow tracks `Y_j`, `C_j` and the refund per reservation; outflows are
  only (i) realization of `j`'s own earned fee, (ii) `j`'s refund to `payer_j`, (iii) the protocol bucket.

Argument:
1. By R-B1 and P-1, `B_a ≤ PM.balanceOf(vault, a)`, and the escrow's assets are not in that balance. So `B`, and
   therefore `N = B − W`, `F = N − Q`, `E = N − D` and the admission limit, exclude every bond.
2. Admission (P-3) reads only `N, Q, R, D`. So a reservation can never be admitted against bond collateral, and
   `Q_a ≤ N_a` holds whatever the escrow holds (`test_bondIsNeverBacking`: a bond larger than `N_a` adds no
   admissible capacity, and a second hook still gets exactly `N_a − Q_a`).
3. Fills pay only vault claims, at most `r_j ≤ Q_a ≤ N_a`; the escrow never pays a hook.
4. By R-B3, `C_j ≤ Y_j` (the bound of §2.3), and `j`'s bucket funds only `j`'s fee and `j`'s refund. So bond `j`
   never covers reservation `j′`.
5. The only escrow-to-vault flow is R-B2, and it raises `N_φ` by fees already earned. From that moment the units are
   LP property (§2.7) and no longer refundable.

**If custody cannot be separated** (for example to save a transfer), the vault would hold bond claims it does not
count, exactly like a donation. That is unsafe as it stands: donations and bonds would sit in the same uncounted
`X_a`, and the invariant `PM.balanceOf = B + X` would no longer say who owns `X`. It would need a counted
`Y_φ` with `PM.balanceOf(vault, φ) ≥ B_φ + Y_φ`, and `Y_φ` excluded from every formula above. Not recommended.

### 2.7 When LPs become entitled to fees

**Rule (REQUIREMENT).** A fee becomes LP property at the moment it is realized into `N_φ` (R-B2). From then on it
belongs to the `S` outstanding shares pro rata, through `N_φ / S`, exactly as a hook's spread does today:
- **Queued shares** are still in `S`, so they receive fees realized while they wait, as they bear gains and losses
  (consistent with G03 G-8).
- **Finalized withdrawals** (`W`) are outside `N` and receive nothing further.
- **Share transfers** (not implemented; shares are not transferable today) need no extra accounting under this rule:
  entitlement is a fraction of `N`, and a transfer changes neither `N` nor `S`.
- **Fee asset must be a pair asset (D-1).** Then a realized fee is just more of one basket asset and every existing
  formula applies unchanged. A third asset would need a per-share reward index with per-account checkpoints on every
  transfer, queue entry and finalization slice, which the vault has no bytes for.

**Timing problem (PROVEN (model)).** Fees accrue continuously but are realized at checkpoints. Between the two, they
are in escrow and belong to no LP. A depositor who enters in between buys at a price that excludes them and shares in
them when they are realized: in `test_feeAttribution_requiresCheckpointBeforeSupplyChange`, 1,000 shares have earned
86.4 units over 10 days; a new LP buys 1,000 shares just before settlement and walks away with 43.2 of them. With a
checkpoint before the deposit it gets nothing and the old LPs keep 86.4.

Exact attribution needs every accrued fee realized before every change of `S`: a deposit, an instant redemption, a
finalization slice. `cancelRequest`, queuing and `claim` do not change `S` or `N`, so they need nothing.

Two constraints decide how:
- **O(1) aggregate accrual needs bucketed expiries.** The accrual rate is `Σ_j r_j ρ_j`, and it falls at each `t_1`
  without any transaction (lazy expiry). Evaluating it at an arbitrary time in O(1) requires expiries rounded up to an
  epoch boundary and a per-epoch rate decrement, so a checkpoint walks at most `MAX_HORIZON / epoch` buckets. This is
  the "epoch-based expiry" the vault NatSpec lists as not implemented (D-2). Not measured.
- **Exits must not depend on the fee module (P-5).** A checkpoint call inside `redeem` or `processQueue` would make LP
  exits fail whenever the module reverts.

Recommended split (D-2):
- `deposit` checkpoints first and fails closed if the checkpoint fails. Deposits may stop; that closes the
  JIT-deposit path in the example above.
- Exits do not call the module. An exiting LP forfeits its pro-rata share of fees accrued since the last checkpoint
  (they go to the shares that stay), which is bounded by the checkpoint interval; checkpoints are permissionless and
  LPs can call one before exiting.

### 2.8 Unclaimed fees and refunds

- **LP fees:** never "unclaimed". Once realized they are part of `N_φ` and leave only in redemption baskets.
- **Protocol fees:** a pull bucket in the escrow, never in `B`, claimable only by the protocol recipient.
- **Refunds:** credited to `payer_j` and pulled. A payer that cannot receive (a blacklisted address, a reverting
  contract) cannot block settlement, so it cannot keep an expired reservation's `Q_a` alive. Unclaimed refunds stay in
  escrow; whether they are ever swept is D-5.

### 2.9 Prices, depegs and decimals

The bond accounting is in units and exact whatever the prices: the bond covers the largest charge in fee units, so a
fee-asset depeg cannot make a reservation insolvent. It changes **value**: `ρ_j` is fixed at creation, so if `φ`
loses value against `a_j` during the reservation, LPs are paid less real value for the capital they reserved; if `φ`
gains, the payer overpays. `MAX_HORIZON` (30 days) limits how long a rate can be stale. Choosing `φ = a_j` (fee in
the reserved asset) removes the cross-asset term for the reserved leg; it is D-1. How a rate is quoted (curator,
module, off-chain) is outside this accounting; the vault side only needs it fixed and deterministic.

### 2.10 Paying for capacity that cannot be sold

G03 shows that reserved capacity and sellable capacity differ:
- **CE-1:** admission ignores the inventory floor, so `Q_a` can exceed `N_a − L_a` from the start
  (`test_admissionIgnoresInventoryFloor`: 200,000 reserved, 50,000 sellable).
- **CE-2:** LP exits shrink the room above the floor by about `s·(h_a − l_a)` without touching `Q_a`
  (`test_lpExitShrinksInventoryRoomOfExistingReservation`: 40,000 reserved and sellable before a 50% exit, 25,000
  after).

Today this costs hooks nothing. Under a reservation fee they would pay for units the vault will refuse to sell. Vault-
side refusals add to it: pause, a direction halt, a curator freeze, flow caps, an invalid oracle reading.

Options (D-6):
- **B1. Admit against the floor:** require `Q_a + q ≤ N_a − L_a` (with `L_a` at the current `S`) in addition to P-3.
  Removes CE-1, not CE-2. Small vault change; the formula already exists in `VaultRiskBoundary`.
- **B2. Credit refused capacity:** stop accrual on units the vault refuses for vault-side reasons. Needs a measure of
  "refused" per reservation; not O(1) for CE-2.
- **B3. Exempt reserved capacity from per-share floor erosion.** Rejected: it weakens T1 for LPs (P-7).
- **B4. Price it:** disclose that `r_j` is an upper bound on what can be bought and let rates reflect it.

Recommendation: B1 + B4; never B3. Whether owner- or guardian-imposed refusals (pause, halt, freeze) pause accrual is
part of D-6.

### 2.11 Interaction with existing controls

- **Exposure caps, flow caps, `R_a`, `D_a`, `MAX_HORIZON`:** unchanged; a bonded reservation is admitted exactly as an
  allocation is today.
- **Emergency release** by owner or guardian: accrual stops at release; the unearned bond is refunded.
- **Revoked curator:** anyone may release (as today); accrual stops; refund to the payer.
- **Frozen curator:** the capacity stays reserved but cannot be consumed; whether it keeps accruing is D-6.
- **Governance:** bonds do not change `P`, so G02's queue check on LONG_DELAY changes is unaffected. The fee module and
  its parameters (`π`, `T_min`, `RATE_SCALE`) must be owner-only and delayed like other loosenings.

### 2.12 Adversarial cases

| Attack | Effect without a control | Control |
|---|---|---|
| Reserve everything for one block, release | LPs pushed into the queue, other curators blocked, for free | `T_min` minimum charge (§2.3) |
| Self-trade to reduce the fee | — | fee is on `r_j`; consuming stops accrual exactly as releasing does; no volume rebate (§2.2) |
| Under-funded bond | fee debt that cannot be collected | full prepayment of the maximum, atomic with `Q` (§2.3, §2.4) |
| Late settlement to inflate the charge | — | accrual clipped at `t_1` |
| Payer blocks settlement by reverting on refund | expired `Q` kept alive | refunds credited and pulled (§2.8) |
| JIT deposit before realization | takes earned fees | checkpoint before deposit (§2.7) |
| Exit just before realization | forfeits own accrued share | bounded by checkpoint interval; permissionless checkpoint |
| Replay of a creation instruction | double bond / double capacity | module nonce + unique id + atomic bond (§2.4) |
| Bond counted as backing | over-admission | separate custody and admission on `N` only (§2.6) |
| Rate rounding to zero | free reservations | `RATE_SCALE = 1e36` (§2.1) |

## 3. Idle capital in an external ERC-4626 strategy

Capital that no commitment, liability or buffer needs could earn yield in an external ERC-4626 vault (a "strategy").
This section starts from the generic ERC-4626 interface and assumes nothing about a particular strategy: its
`totalAssets`, `convertToAssets`, `previewRedeem`, `maxWithdraw` and `maxRedeem` describe the present, are set by its
own code, and promise nothing about the future. No strategy is selected here, and none should be selected on
advertised yield.

### 3.1 Seven quantities, per asset

`N_a` in this section is **physical**: `B_a − W_a`, exactly as today.

| # | Quantity | Symbol | Definition | Guaranteed? |
|---|---|---|---|---|
| 1 | Physical ERC-6909 backing | `B_a` | as today: claims on the PoolManager the vault has accounted for | yes (P-1) |
| 2 | External shares | `Z_a` | strategy shares owned for the LP shares, by internal count, held by a custody module | the count, yes; their value, no |
| 3 | Conservative economic value | `V_a` | at most `previewRedeem(Z_a)` (after the strategy's exit fee), less a haircut | an estimate; can fall to zero |
| 4 | Immediately redeemable | `M_a` | `min(previewRedeem(Z_a), previewRedeem(maxRedeem(custody)))` now | a snapshot; nothing about later |
| 5 | Needed for commitments | `Q_a` | as today | must be physical |
| 6 | Protected withdrawal liabilities | `W_a`, `D_a`, buffers `R_a`, `K_a` | finalized claims, the queue's pro-rata claim, the admission buffer, and a liquidity buffer for instant exits | must be physical |
| 7 | Available for new investment | `I_a` | `max(0, N_a − Q_a − R_a − D_a − K_a)`, and also at most `N_a − Q_a − L_a` (§3.7) | — |

### 3.2 No commitment relies on external assets

**Claim (ARGUED; PROVEN (model)).** If admission, fills, `W_a` and `D_a` are computed on physical assets only, and
deployment is limited to `I_a`, then every outstanding commitment and every protected liability stays covered by
physical claims whatever the strategy does.

- Admission (P-3) reads physical `N_a`, so a new reservation is admitted only within physical inventory.
- Deploying `x ≤ I_a` leaves `N_a − x ≥ Q_a + R_a + D_a + K_a`, so `Q_a ≤ N_a` and `F_a ≥ D_a + K_a` still hold.
- Fills pay from physical claims (as today), and `W_a` is physical.
- A later strategy loss, pause or shutdown changes `Z_a`'s value, never `B_a`.

`test_admission_physicalOnly`: with 500,000 of 1,000,000 deployed and 300,000 reserved, a new reservation is limited
to `N − Q − R = 150,000`, not to the 650,000 that total value would suggest; queuing 100,000 shares takes their
`D = 50,000` out of both limits.

This is the requirement the brief states: a valid future commitment must not rely on assets whose availability
cannot be enforced. `maxWithdraw` today says nothing about tomorrow, so it is never an input to admission.

### 3.3 Custody boundary (REQUIREMENTS)

- **Separate module.** A custody module holds the strategy shares; the vault keeps the ledger (`Z_a`) and its existing
  custody of ERC-6909 claims. No core accounting, no approval over vault claims and no operator right moves to the
  strategy.
- **Internal counts.** `Z_a` changes only through deploy, recall and LP operations; shares sent to the module
  directly are not counted, as donated claims are not (`test_donatedExternalShares_notCounted`). Every strategy call's
  return value is checked against the measured balance change.
- **Exact approvals.** Approve exactly the amount of each deposit and nothing standing. (The model approves the
  maximum for brevity; an implementation must not.)
- **Where strategy code runs.** Never inside `exchange` or `unlockCallback`. Only in deploy, recall and (design Y1)
  deposit, under the vault's transaction lock, after all state changes (checks-effects-interactions).
- **Allowlist.** A strategy is usable only if `asset()` is exactly the pair asset. Adding a strategy or raising a cap
  is an owner change through the governor's delay; the guardian may only stop deployment and request recalls.

### 3.4 What a share holds: two designs

**Y1, in kind (recommended).** Each share is a fraction of physical `N_a` and of `Z_a`, for both assets:
- deposit `s`: `ceil(s·N_a/S)` physical, plus `ceil(s·Z_a/S)` strategy shares minted at the depositor's expense
  (`previewMint` rounds up, against the depositor);
- exit `s`: `floor(s·N_a/S)` physical (limited by `F_a`, as today) plus `floor(s·Z_a/S)` strategy shares transferred.

No valuation is ever made, so nothing can be manipulated through one. P-4 extends to both parts:
`testFuzz_inKind_noDilutionAndNoRoundTripGain` checks that no deposit or exit lowers `N_a/S` or `Z_a/S` and that a
round trip never gains, at strategy share prices anywhere from a loss of all but one unit to a 5× gain. Costs: LPs receive strategy shares
on exit; deposits stop while the strategy refuses `mint`; and a strategy whose shares cannot be transferred needs a
fallback (the external part of an exit becomes a claimable balance, like `W_a`).

**Y2, book value.** The position is carried at a book value `C_a`; exits pay `floor(s·(N_a + C_a)/S)` in physical
assets. `C_a` must be lowered to `previewRedeem(Z_a)` before every exit, or a loss nobody has recorded is paid out to
whoever exits first: `test_bookValue_staleExitTransfersLoss` pays an LP holding 40% `400,000` at the stale book value
against a fair `360,000`, and the remaining LPs absorb the 40,000. A fresh check means calling the strategy in every
exit path, which breaks P-5; a strategy that reverts would then stop LP exits. Y2 also pays exits only from physical
assets, so exits drain `B_a` while `Z_a` stays, and deposits priced at book value let new LPs buy unrecognized gains.
Not recommended (D-7).

### 3.5 Admission conditions for moving assets out (REQUIREMENT)

Deploy `x` of asset `a` only if all hold:
1. `x ≤ N_a − Q_a − R_a − D_a − K_a` (quantity 7);
2. `x ≤ N_a − Q_a − L_a`, so outstanding reservations stay sellable above the inventory floor (§3.7);
3. the strategy is allowlisted for `a`, and `maxDeposit(custody) ≥ x`;
4. after deployment, the strategy's share of the asset stays within its cap (fraction of `N_a + V_a`) and the
   per-strategy cap;
5. **value check:** the shares received redeem now for at least `x·(1 − ε)`, with `ε` the accepted entry cost. This
   refuses a deposit into a strategy whose share price an attacker inflated by donation
   (`test_inflationAttack_onDeployment`: without it, 1,500,000 deposited buys one share redeemable for 1,250,000);
6. the shares received equal the measured balance change;
7. the deployment is made by an authorized role within these limits (D-9).

Recall (strategy shares back to physical) is best effort: at most `maxRedeem(custody)`, with a minimum-assets bound;
any shortfall against the pre-fee value is a realized loss borne by every share through `N_a`
(`test_recall_illiquidityAndFee`). Recalls should be permissionless when physical free inventory is below `K_a` or the
head of the queue is waiting (D-11).

### 3.6 What can happen to the position

| Event | Y1 (in kind) | Requirement or note |
|---|---|---|
| Yield accrues | strategy share price rises; every share's `Z_a/S` is worth more; new LPs pay for it at entry, exiting LPs take it (example E) | nothing to account |
| Exchange rate falls | each share's external part is worth less, pro rata | nothing to account; no exit is affected |
| Partial availability (`maxWithdraw` < position) | recalls are partial | exits do not depend on recalls (in kind) |
| Withdrawal fee | paid only on recall; a realized loss shared through `N_a` | bound with a minimum-assets argument |
| Realized loss | pro rata through `Z_a`'s value (example F) | no LP exits ahead of others at a stale price (contrast Y2) |
| Illiquidity / pause | recalls and deposits stop; exits continue in kind (example F) | P-5 holds |
| Strategy shutdown | as pause; shares may become non-transferable | fallback claimable balance for the external part |
| Donation to the strategy | raises the share price; benefits holders | the value check (§3.5.5) protects first deposits |
| Inflation attack on first deposit | the custody would receive too few shares | value check (§3.5.5) |
| Reentrancy | strategy code runs in deploy, recall, deposit | under the vault lock, after state changes, never in `exchange` |
| LP withdrawal ordering | the physical part follows the FIFO queue as today; the external part needs no inventory | queued shares keep their external part until finalized; finalization delivers it in kind |
| Two assets, depegs | each asset's ledger is separate; no cross-asset value is computed | a strategy that holds something other than its `asset()` shows up as share-price loss |

### 3.7 The inventory floor and deployment

Fills sell physical inventory, and the inventory floor compares physical `N_a` with `L_a = ⌈S·τ_a(1 − κ_a)⌉`.
Deploying `x` lowers physical `N_a / S` and with it the room above the floor. Two consequences:
- Condition 2 of §3.5 keeps every outstanding reservation sellable at the moment of deployment.
- If `τ_a` was set to the full per-share holding, any deployment puts the physical holding below `τ_a`, and fills of
  that asset stop once it reaches `L_a`. Lowering `τ_a` to match is a loosening: LONG_DELAY and an empty queue
  (G02). So either deployments are sized inside the room `N_a − L_a − Q_a`, or the floor is redefined on physical plus
  external holdings, which needs a value for `Z_a` inside a fill (an external call in `exchange`). D-8.

### 3.8 Examples E and F (model; `test/model/IdleYieldModel.t.sol`)

Setup for both: one asset, 1,000,000 units for 1,000,000 shares; `Q = 300,000` reserved; `R = 50,000`;
`K = 100,000`. Available for investment: `1,000,000 − 300,000 − 50,000 − 0 − 100,000 = 550,000`. 500,000 is
deployed into a fresh strategy at one share per unit. Physical `N = 500,000`, `Z = 500,000` shares.

**E. Positive yield** (`test_exampleE_positiveYield`). The strategy earns 10% (its assets go to 550,000).
- A new LP buys 100,000 shares: `ceil(100,000·500,000/1,000,000) = 50,000` physical, plus 50,000 strategy shares,
  which cost `previewMint(50,000) = ceil(50,000·550,000/500,000) = 55,000`. It pays 105,000 for 100,000 shares: the
  yield earned before it arrived is priced in.
- The seed LP redeems 100,000 shares: 50,000 physical and 50,000 strategy shares worth 55,000. It takes its yield
  with it.

**F. Loss, then pause** (`test_exampleF_lossAndPause`). The strategy loses 20% (assets 400,000) and pauses.
- Recall reverts; a deposit reverts (the strategy refuses `mint`).
- The seed LP redeems 200,000 shares: 100,000 physical (free inventory `500,000 − 300,000` covers it) and 100,000
  strategy shares worth 80,000. 0.9 per share: exactly the pro-rata loss.
- The remaining 800,000 shares hold 400,000 physical and 400,000 strategy shares: 0.5 + 0.5 per share, unchanged.
- Under Y2 without a fresh impairment check, the same exit would have been paid at the old book value (see §3.4).

**Illiquidity and fees** (`test_recall_illiquidityAndFee`). With the strategy able to return only 10,000 now and a
1% exit fee, recalling 10,001 shares reverts; recalling 10,000 returns 9,900, and a minimum of 10,000 refuses it.

## 4. Requirements for the implementing milestone

Before either extension is built:
1. Keep P-1 … P-8 (§1), and test each again with the extension in place.
2. Keep bonds and strategy shares out of `B_a`; keep admission on physical `N_a` (§2.6, §3.2).
3. No module or strategy call in any LP exit path (P-5). Deposits may fail closed; exits may not.
4. A dedicated, caller-restricted vault entry for realized fees that raises `B_φ` with an equal claim inflow and mints
   no shares; nothing else may raise `B` without minting shares.
5. Settle the decisions in §5 that the chosen scope touches; D-6 and D-8 change what LPs and hooks are promised.
6. Measure the vault's byte headroom and the checkpoint gas before choosing the epoch length (D-2).
7. Re-run G03's rounding, deliverability and accounting campaigns with bonds and deployments in the handlers.

## 5. Decisions for the owner

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D-1 | Fee asset | one pair asset per vault; the reserved asset `a_j`; a third asset | a pair asset (§2.7); `a_j` removes the cross-asset term |
| D-2 | Fee attribution | epoch-bucketed aggregate accrual with checkpoint in `deposit` (fail closed) and none in exits; or checkpoint-only with a deposit delay | the first; choose the epoch length; measure gas before committing |
| D-3 | Minimum charge `T_min` | none; a fixed duration; a fraction of `t_1 − t_c` | a fixed duration (§2.3) |
| D-4 | Who may release early | payer only; payer or curator | payer or curator, as `cancelAllocation` is the curator's today |
| D-5 | Unclaimed refunds | kept forever; swept to the protocol after a long period | kept forever (no new trust in a sweeper) |
| D-6 | Capacity the vault refuses to sell | B1 admission against `L_a`; B2 credits; B4 disclose | B1 + B4; decide whether pause, halt and freeze stop accrual |
| D-7 | What a share holds when capital is deployed | Y1 in kind; Y2 book value | Y1 (§3.4) |
| D-8 | Inventory floor and deployment | size deployments inside `N − L − Q`; redefine the floor on total holdings | size deployments; do not put a strategy call in `exchange` |
| D-9 | Who deploys | owner through the governor; a keeper role within limits; anyone within limits | a keeper role within the §3.5 limits |
| D-10 | Liquidity buffer `K_a` | absolute; fraction of `N_a` | a fraction of `N_a`, reviewed with the exposure caps |
| D-11 | When recalls are permissionless | never; when `F_a < K_a` or the queue head waits | the latter |
| D-12 | Strategy shares that cannot be transferred | refuse such strategies; fallback claimable balance | refuse at allowlisting, keep the fallback |

## 6. What this note does not claim

- Nothing here is implemented or audited. The model tests check the proposed equations, not any contract in `src/`.
- No gas, yield or utilization figure is given; none was measured.
- The bond fee is a payment for reserved capacity, not a guarantee that the capacity can be sold (§2.10).
- The in-kind design keeps exits independent of the strategy; it does not protect LPs from the strategy's losses,
  which they bear pro rata.

