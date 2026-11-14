# Porkfolio — G05: V2 Financial Architecture

**Status: architecture decision record, awaiting owner review.** Nothing in this document is implemented in `src/`
unless a row says IMPLEMENTED. G05 changed no production contract (`git diff 5701e9c -- src` is empty). The V2 design
below is a proposal for milestones C01 and later (§11).

Labels:
- **IMPLEMENTED**: present in `src/` at `5701e9c`, with the evidence named.
- **PROPOSED**: V2 design; not in `src/`.
- **MEASURED**: a number observed by a command listed in §13 (prototype or model, as stated).
- **TESTED (model)**: checked by a test-only model in `test/model/`; says nothing about `src/`.
- **PROVEN**: an argument here that holds for every input in the stated domain. Hand proofs; nothing is
  machine-checked, and nothing here has been reviewed independently. No formal verification was performed.
- **DECISION**: an owner choice. G03's D-1 … D-12 and R-15 … R-17, G04's R-19 … R-23 keep their numbers; new items
  are V2-1, V2-2, … (§10).

## 0. Starting state and summary

| Check | Result |
|---|---|
| G03 in `main` | yes: `4dbe6b9` is an ancestor of `main` |
| G04 in `main` | yes: `main` = `origin/main` = `phase-2-g04-oracle-safety` = `5701e9c` |
| Branch | `phase-2-g05-v2-architecture` from `5701e9c`; no other branch created |
| Worktree | clean except the untracked `AGENTS.md` (not created here, not touched) |
| Vault runtime at `5701e9c` | 22,440 B, 2,136 B under EIP-170 (MEASURED, `forge build --sizes`) |
| Vault size policy | at least 2,048 B under EIP-170, enforced by `test/unit/ProductionBuilds.t.sol` and `test/bench/security.sh`: **88 B usable** |

Sources read in full or in the parts cited: `SharedCommitmentVault.sol`, `ISharedCommitmentVault.sol`,
`IVaultState.sol`, `VaultGovernor.sol`, `PriceRiskAdapter.sol`, `ReferenceBracket.sol`, `VaultRiskBoundary.sol`,
`CuratorAuthorization.sol`, `BaseCompatibleHook.sol` (Hook A and Hook B inherit it), `VaultLens.sol`;
`test/model/ReservationBondModel.sol`, `test/model/IdleYieldModel.sol`; the G01–G04 reports;
`FUTURE_CAPITAL_AND_YIELD_ACCOUNTING.md` (the "design note", source of D-1 … D-12); `MODULAR_RISK_ENGINE.md` §7.3
(earlier ring-buffer analysis); `ACCOUNTING_FLOW.md` §7 (blueprint corrections); `docs/reference/Master_Blueprint.pdf`.

**Decisions in one place** (each is argued below; owner decisions are §10):

1. A reservation guarantees **exclusive accounting capacity backed by physical claims**, and that the capacity was
   **sellable above the inventory floor when it was admitted**. It does not guarantee later execution. With a
   per-share inventory floor and pro-rata in-kind exits, no rule can keep LP exits, the floor and continued
   sellability all at once (§3.3, PROVEN and TESTED (model)).
2. **R-15 resolved:** admission also requires `Q_a + q ≤ N_a − L_a` (room-aware admission). CE-1 is removed; CE-2
   remains and is disclosed.
3. **Keeper-free expiry:** a bucketed ring of K = 720 one-hour slots per asset, swept at most 32 buckets per call,
   holds `Q_a`. Expired capacity leaves `Q_a` without a `release` transaction (§3.5). The ring is O(1) amortized per
   elapsed bucket, not O(1) per call, and someone must still call the vault. Flow caps are unchanged and separate.
4. **Bonds:** a separate `BondEscrow` holds prepaid fee collateral in the reserved asset, accrues on the unused
   remainder over time, realizes fees into the vault through one escrow-only entry, and refunds by pull. `deposit`
   realizes first; exits never call the escrow (§5).
5. **Yield:** model A. Porkfolio holds no external ERC-4626 shares in V2. Model B (custody module, in-kind) is the
   only acceptable future design, and it needs vault bytes V2 does not have (§6).
6. **Bytes:** every V2 vault change breaks today's 2,048 B policy. Moving the vault's derived and struct getters behind
   one `extsload` (the pattern of v4's PoolManager) frees 2,220 B; with it, the V2 set plus the C-1 TVL cap measures
   22,443 B, 2,133 B under EIP-170 (§8, MEASURED on a prototype).
7. **Implementation order:** C01 byte reclaim (no behaviour change) → C02 ledger (room-aware admission, ring) → C03
   bonds → C04 Hook C and interfaces → C05 full validation (§11).

## 1. Final architecture

```
                 curators (EIP-712 intent: hook, pool, asset, maxOut, floor, expiry, payer, maxRate)
                 payers   (submit the intent, post the bond)
                                     │ activate()
                     ┌───────────────▼────────────────┐   post(bond)   ┌───────────────────────────────┐
                     │ CommitmentAuthorizer           ├───────────────►│ BondEscrow                    │
                     │ (vault.authModule; replaceable)│                │ bonds as ERC-6909 claims,     │
                     │ signature, nonce, payer, rate  │                │ accrual, refunds, protocol fee│
                     └───────────────┬────────────────┘                └──────┬─────────────▲──────────┘
                          reserveFor │                           realizeFee   │             │ realize()
                                     ▼                       (claims pull)    ▼             │ (deposit)
 LPs ── deposit / redeem / ──► ┌──────────────────────────────────────────────────────────────┴─────────┐
        processQueue / claim   │ SharedCommitmentVault (V2)                                             │
                               │ custody of ERC-6909 claims · LP shares and FIFO queue · B, W, N        │
                               │ allocations · Q with expiry ring · admission (incl. room) · exchange   │
                               │ floors (stored, curator, dynamic) · inventory floor · flow & exposure  │
                               │ extsload (generic read) · coreInputs · getCurator                      │
                               └───▲──────────────────────▲───────────────────────────▲─────────────────┘
                     exchange()    │            exchange()│                exchange() │   currentReference()
                ┌──────────────────┴──┐  ┌────────────────┴──┐  ┌─────────────────────┴──┐   ┌──────────────────┐
                │ Hook A (dynamic fee)│  │ Hook B (bounded   │  │ Hook C (third party,   │   │ PriceRiskAdapter │
                │                     │  │ impact)           │  │ no shared base class)  │   │ (immutable)      │
                └─────────────────────┘  └───────────────────┘  └────────────────────────┘   └──────────────────┘
   VaultGovernor (owner of vault, escrow config and hooks; DELAY / LONG_DELAY)   Guardian (tighten only)
   VaultLens (stateless reads through extsload)          PoolManager (canonical v4; holds every claim)
```

No arrow leaves the vault towards the escrow except `deposit`'s `realize()` call; no LP exit, no `exchange` and no
`release` calls the escrow, the authorizer or the adapter-free paths' modules. The adapter is read only by `exchange`
and by core-mode hooks, as today.

## 2. Contract responsibilities and interfaces

### 2.1 Implemented baseline and what V2 changes

| Area | IMPLEMENTED at `5701e9c` | PROPOSED V2 |
|---|---|---|
| Custody | vault holds ERC-6909 claims; `B_a ≤ PM.balanceOf` (G03 G-1) | unchanged; one new inflow, `realizeFee` |
| LP shares, queue | proportional in-kind deposit/exit, FIFO queue, `W` ring-fenced (G03 G-4 … G-8) | unchanged; `deposit` first calls `escrow.realize()` |
| Admission | `Q + q + R + D ≤ N`, exposure caps on `E`, curator ceiling (G03 G-3) | adds `Q + q ≤ N − L`; expiry on an hour boundary |
| Expiry | lazy: `Q` keeps expired capacity until `release` (G02 §1.2) | bucketed ring removes it from `Q` without `release` |
| Execution | floors, inventory floor, flow caps, oracle checks (G04 §7) | unchanged |
| Fees | none | `BondEscrow` (new contract) |
| Authorization | `CuratorAuthorization` | `CommitmentAuthorizer`: same checks plus payer, `maxRate`, bond posting |
| Reads | ~25 public getters and 4 struct getters in the vault | `extsload`; `VaultLens` decodes the layout |
| Idle yield | none | none (model A, §6) |
| Governance | `VaultGovernor`, guardian levers (G02) | unchanged; escrow parameters are owner calls through the governor |
| Oracle | `PriceRiskAdapter` (G04) | unchanged |

Guarantees V2 must keep, with their sources: P-1 … P-8 of the design note §1 (G03 G-1 … G-12), G02 S-1 … S-4 and
L-1/L-2, G04 O-1 … O-8 and §7's six safety invariants. §12 restates the ones V2 touches as testable invariants.

### 2.2 Who does what

| Contract | Moves funds? | Responsibility | Trusts | Replaceable? |
|---|---|---|---|---|
| `SharedCommitmentVault` | yes: the only holder of LP claims; pays exits, claims and fills; pulls fee claims from the escrow | custody, shares, queue, commitment ledger, admission, execution checks | PoolManager; installed adapter for prices only; installed authorizer for "curator authorized this"; escrow only as a source of fee claims | no (new deployment; §7.5) |
| `BondEscrow` | yes: bonds, refunds, protocol fees; pushes LP fees into the vault | bond custody, accrual, realization, settlement | the vault's allocation records; `vault.authModule()` as the only poster of bonds | only with the migration procedure of §7.5 |
| `CommitmentAuthorizer` | moves the bond from payer to escrow, nothing else | EIP-712 verification, nonces, payer binding, rate cap | the vault's curator records | yes (`setAuthModule`; old module retired for good) |
| Hooks A, B, C | own claims only, inside one swap | pricing; settling the swap's deltas | the vault | per hook (registration) |
| `PriceRiskAdapter` | no | reference price and uncertainty | feeds (G04 §2.10) | yes, owner DELAY |
| `VaultGovernor` | no | delays owner calls | — | LONG_DELAY hand-over |
| `VaultLens` | no | decoded reads, previews | vault storage layout | yes (stateless) |

Validation only, never custody: the authorizer (signatures), the adapter (prices), the lens (reads), the governor
(timing). The escrow validates nothing about trades; the vault validates every trade.

### 2.3 Stable interfaces

**Hook side (`ICommitmentConsumer` requirements; unchanged from today).** A hook integrates by meeting these, not by
inheriting `BaseCompatibleHook`:
1. Permissions `beforeSwap` and `beforeSwapReturnDelta` (and anything else it needs), mined into its address.
2. Registered as a consumer by the vault owner (`setConsumer`, DELAY); the guardian may deregister.
3. Grants the vault ERC-6909 operator rights over the hook's own claims (`poolManager.setOperator(vault, true)`).
4. In `beforeSwap`: mint `amountIn` input claims, call `vault.exchange(key, zeroForOne, allocationId, amountIn,
   amountOut)`, burn `amountOut` output claims, return the matching `BeforeSwapDelta`. Exact-input only.
5. Reads prices from `vault.coreInputs()` if it wants the vault's adapter; the vault enforces its floors either way.

`exchange` is the only vault function a hook calls. Adding Hook C changes no vault code or storage layout: it is one
`setConsumer` call and allocations made out to it.

**Authorizer → vault:** `reserveFor(AllocationRequest, curator, generation)` (unchanged struct; V2 adds the hour
alignment check on `expiry`).

**Escrow ↔ vault (new):**

| Call | Caller | Effect |
|---|---|---|
| `vault.realizeFee(Currency a, uint256 x)` | only `vault.feeEscrow()` | `B_a += x`, pulls exactly `x` claims of `a` from the escrow; mints no shares; lock-free |
| `escrow.realize()` | anyone; `vault.deposit` before pricing | moves fees earned and not yet realized into the vault (§5.4) |
| `escrow.post(allocationId, payer, maxRate)` | only `vault.authModule()` | records the bond for an allocation created in the same transaction (§5.2) |
| `vault.getCurator`, `vault.extsload` | escrow, lens, anyone | reads |

**Reads:** `extsload(bytes32 slot)` plus `coreInputs()`, `getCurator()`, `owner()`, `guardian()`, `pendingShares()`,
`isConsumer()`, `authModule()`, `paused()`, `pendingOwner()`, `poolManager()`, `asset0()`, `asset1()` and the
constants stay as functions (hooks, governor, authorizer and scripts call them). Everything else is read through
`VaultLens`, which decodes the storage layout; a storage-layout test pins the slots (§12).

### 2.4 Hook C integration test (requirement for C04)

A test-only third-party hook, written against `ISharedCommitmentVault` and the PoolManager only (no import of
`BaseCompatibleHook`, `InventoryPricing` or any Porkfolio hook code), with its own pricing (for example constant-price
with a fixed fee), deployed at a mined address, registered by the governor, against the production vault build. It
must show, on the real PoolManager:
1. Hooks A, B and C trade the same reserve on three pools in one block, each against its own allocation; `Q`, `B` and
   the claim balance reconcile after each swap.
2. Hook C cannot consume A's or B's allocation, another pool's, the wrong direction, beyond its quota, after expiry
   (exact second), below any floor, or past the inventory floor or a flow cap; each attempt reverts and changes
   nothing.
3. A bonded reservation for Hook C accrues, is consumed, synced, settled and refunded like any other.
4. Hook C reverting, re-entering the vault, or lying about amounts is contained (the existing
   `MaliciousConsumerHook` cases, repeated through Hook C's path).
5. The vault's runtime bytecode hash is identical before and after Hook C is registered and used.
6. No call in Hook C's swap path iterates over a registry, allocations or buckets (gas of `exchange` is independent
   of the number of allocations and of elapsed buckets; asserted with 1 and 200 live allocations).

## 3. The reservation guarantee and the per-asset ledger

### 3.1 What a reservation is

| Field | V2 rule | Source |
|---|---|---|
| Asset committed | `currencyOut`, one of the pair; the vault sells it | IMPLEMENTED |
| Hook and pool | `consumer` (registered) and `poolId` (whose `hooks` is the consumer, whose currencies are the pair) | IMPLEMENTED |
| Direction | implied by `currencyOut` | IMPLEMENTED |
| Maximum output | `maxOut`, raw units of `currencyOut`, `0 < maxOut ≤ 2^127 − 1` | IMPLEMENTED |
| Consumed more than once? | partially, any number of fills, until `consumed = maxOut`; each unit at most once; input received never re-arms it | IMPLEMENTED |
| Start | at creation; no forward start | IMPLEMENTED (V2 keeps it) |
| Expiry | `now < expiry ≤ now + 30 d`, **on an hour boundary** (new); consumable while `now < expiry` | PROPOSED (alignment) |
| Pricing | each fill pays at least `max(stored floor, curator floor, dynamic floor)` at execution; only the curator floor is fixed by the reservation | IMPLEMENTED |
| Oracle | adapter mode: every fill needs a valid reading (G04 O-1); admission and bonds read no price | IMPLEMENTED / PROPOSED |
| Curator authorization | EIP-712 or direct; nonce; generation; deadline; registered and unrestricted at creation; unrestricted at each fill; ceiling | IMPLEMENTED; V2 adds payer and `maxRate` to the signed intent |
| Physical backing | `Q_a + q + R_a + D_a ≤ N_a`, exposure caps on `E_a`, **and `Q_a + q ≤ N_a − L_a`** (new) | IMPLEMENTED + PROPOSED |
| Pending withdrawals | admission excludes `D_a`; a request queued after admission waits at most until that reservation's expiry | IMPLEMENTED (G03 G-11) |
| Release | curator cancel (any time); owner or guardian (emergency); anyone after expiry or once the curator is revoked; **expiry removes it from `Q_a` without a call** (new) | IMPLEMENTED + PROPOSED |
| Bond | prepaid maximum fee in `currencyOut`, held by the escrow, refunded by pull (§5) | PROPOSED |

### 3.2 Four guarantees, and which V2 gives

| Guarantee | V2 | Why |
|---|---|---|
| **G-R1 Exclusive accounting capacity.** No other reservation, no LP exit and no claim can take the reserved units while the reservation is live | **yes**, until expiry or a close | admission bounds `Q`; exits pay at most `F = N − Q`; `W` is outside `N`; consumption is per allocation (G03 G-3, G-6) |
| **G-R2 Physical backing.** The units exist as claims the vault holds | **yes** | `Q_a + W_a ≤ B_a ≤ PM.balanceOf(vault, a)` (G03 G-2); bonds and external assets never count (§5.6, §6) |
| **G-R3 Sellable at admission.** When admitted, the whole remainder fits above the inventory floor | **yes (new)** | room-aware admission (§3.4) |
| **G-R4 Executable later.** The remainder can still be sold at any later time before expiry | **no** | §3.3: impossible together with G-R1 and the floor; also oracle outages, pause, halts, freezes and flow caps (G04 §8.2) |

The quantity a hook can actually sell at time `t` is

    sellable_j(t) = min(r_j, N_a − L_a, flow headroom of hook, curator and vault, …)   if no refusal applies, else 0

and `N_a − L_a` is shared first come, first served by every live reservation in that asset. V2 does not partition the
room: a pro-rata per-fill cap is not stable (§3.3).

### 3.3 The reservation–withdrawal conflict (PROVEN; TESTED (model))

**Claim.** Let `τ_a` be set, so `L_a = ⌈S·l⌉` with `l = τ_a(1 − κ_a) > 0`, and `h = N_a/S > l`. Then no admission and
exit rule can keep all three:
- (i) LP exits limited only by free inventory (`s ≤ ⌊F_a·S/N_a⌋`);
- (ii) the inventory floor on every fill;
- (iii) every admitted remainder stays sellable until expiry.

**Proof.** Admit `Q = N − L` (the whole room). Then `F = L` and (i) allows `s = ⌊L·S/N⌋ ≈ S·l/h > 0` shares to leave,
paying `⌊s·h⌋`. Afterwards the room is `N' − L' = N − ⌊s·h⌋ − ⌈(S − s)·l⌉`, so
`Q − (N' − L') = ⌊s·h⌋ + ⌈(S − s)l⌉ − ⌈S·l⌉ ≥ ⌊s·h⌋ − ⌈s·l⌉ − 1 > 0` once `s(h − l) ≥ 3` raw units. By (ii) no fill may
take `N` below `L'`, so part of `Q` cannot be sold, contradicting (iii). ∎ In general the room scales with the
shares: `room' = room·(S − s)/S`, while `Q` does not move.

Evidence: `testFuzz_freeInventoryExit_shrinksRoomBelowReserved` (1,000 runs over supply, holdings, `τ`, `κ` from
0.1% to 50%; room' < Q and room' = Q·(S − s)/S ± 3 units) and G03's CE-2 on the real vault.

**What keeping (iii) would cost.** Exits would have to keep `(S − s)(h − l) ≥ Q`, i.e. `s ≤ S − Q/(h − l)`, instead of
`s ≤ S − Q/h`. A reservation would hold back `h/(h − l)` times as many shares; at `h = τ` that is `1/κ`, twenty times at
`κ = 5%`. With half the room reserved, 50% of shares could exit instead of 97.5%; with all of it, none
(`test_hardExecutableRule_costsOneOverKappa`). Rejected (REJECTED-1, §10.4): it converts a commitment to hooks into a
twentyfold claim on LP liquidity.

**Why not share a shrunken room pro rata.** A cap of `r_j·room/Q` per fill falls for everyone else after any fill,
because `(room − x)/(Q − x) < room/Q` when `room < Q` (`test_proRataFillCap_isNotStable`: 25 → 16). Stable pro-rata
scaling needs a global index applied to every reservation on every exit and an accrual integral of it for fees: a
state write in every LP exit and every fill. Rejected for V2 (REJECTED-2).

**Consequence for fees (D-6, R-23).** The bond charges for capacity withheld from LPs (G-R1), which is what LPs give
up. It does not insure execution (G-R4). §5 states the terms; §10 records the decision.

### 3.4 Per-asset ledger (PROPOSED)

All quantities per asset `a`, raw units, unless noted.

| Symbol | Definition | Storage |
|---|---|---|
| `B_a` | accounted ERC-6909 backing | vault `backing` |
| `X_a` | uncounted claims: `PM.balanceOf(vault, a) − B_a ≥ 0` (donations) | derived |
| `Q_a` | stored reserved total: unused capacity of every unreleased allocation whose expiry bucket has not been swept or evicted (§3.5) | vault `reserved` + ring |
| `Q^live_a` | unused capacity of allocations that are unreleased and not expired | derived (`ExpiryRing.live`) |
| `Q^lazy_a` | unused capacity of every unreleased allocation (today's `Q`) | derived |
| `W_a` | finalized, unclaimed withdrawals | vault `claimableAssets` |
| `N_a` | `B_a − W_a` | derived |
| `F_a` | `N_a − Q_a` (exits read the stored, swept `Q`) | derived |
| `R_a` | buffer floor (admission only) | vault `bufferFloor` |
| `D_a` | `⌈P·N_a/S⌉` | derived |
| `E_a` | `N_a − D_a` | derived |
| `L_a` | `⌈S·τ_a(1e6 − κ_a)/(1e18·1e6)⌉` if `τ_a ≠ 0`, else 0 | derived |
| `room_a` | `max(0, N_a − L_a)` | derived |
| `Y_a` | bond collateral in `a` held by the escrow | escrow, never in `B_a` |
| `U_a` | fees earned and not yet realized | escrow |

**Relations (V2 invariants; IDs refer to §12).**

    PM.balanceOf(vault, a) = B_a + X_a,  X_a ≥ 0                         (V-1)
    Q_a + W_a ≤ B_a                                                       (V-2)
    Q^live_a ≤ Q_a ≤ Q^lazy_a                                             (V-3)
    after reserveFor(q):  Q_a ≤ N_a − R_a − D_a  and  Q_a ≤ room_a        (V-5)
    escrow claims of a ≥ open bonds in a − (realized − settled charges)   (V-11, per asset)

**Admission (PROPOSED)**, with `Q_a` swept first:

    q ≤ max(0, N_a − Q_a − R_a − D_a)                     today's rule
    q ≤ max(0, room_a − Q_a)                              new; only when τ_a ≠ 0
    (held_scope + q)·10⁴ ≤ bps_scope · E_a  for hook, curator, vault   unchanged
    q ≤ ceiling_curator − curatorReserved                  unchanged
    expiry ≡ 0 (mod 3600), now < expiry ≤ now + MAX_HORIZON

In adapter mode `τ_a` is always set for a tradable asset (fills of an asset without a target are refused, G04 §2.2),
so the room rule always applies there. In static mode with `τ_a = 0` there is no floor and no room rule; G02's R-11
release rule (configure `τ_a` before LPs are admitted) stays.

**No unit is promised twice (PROVEN).** (1) `Q^live ≤ Q` and admission bounds `Q` by `N − R − D`, so live
reservations never exceed physical net assets. (2) Each allocation's remainder `maxOut − consumed` falls only through
its own consumption or its own close, each applied once (`released` flag; ring tags, §3.5). (3) Exits pay at most
`F = N − Q ≤ N − Q^live`. (4) `W` is outside `N`. (5) Bonds and external assets are outside `B`. So every unit counted
in `Q^live` is counted for exactly one allocation and is not payable to anyone else.

### 3.5 Keeper-free expiry: the bucketed ring (PROPOSED; TESTED (model))

**Design.** Buckets of `δ = 1 hour`; bucket `b` ends at `b·δ`. An allocation's expiry is a bucket end, so it belongs
to bucket `b = expiry/δ` and is live while `now < b·δ`; with `c = ⌊now/δ⌋`, bucket `b` is expired iff `b ≤ c`. Per
asset the vault keeps `swept` (every bucket `≤ swept` is out of `Q`), `maxBucket` (largest bucket ever written) and
`K = MAX_HORIZON/δ = 720` slots; bucket `b` lives in slot `b mod K`, tagged with `b`. Reference implementation:
`test/model/ExpiryRing.sol` (a test-only library).

| Path | Ring operation | Notes |
|---|---|---|
| `reserveFor` | sweep (≤ 32 buckets), then `add(b, q)` | a slot holding another tag is an expired bucket (proof below): subtract it if not yet swept, then overwrite |
| `exchange` | `remove(b, x)` | a live allocation's bucket is always resident and unswept; no sweep in the swap path |
| `release`, `cancelAllocation` | `remove(b, r)` | no-op if `b ≤ swept` or the slot's tag ≠ `b` (already out of `Q`) |
| `redeem`, `processQueue` | sweep (≤ 32 buckets) per asset | then `F` and deliverable shares use the swept `Q` |
| view | `live(…)` | `Q^live` without writing (lens) |

**Sizing and slot reuse (PROVEN).** A new expiry satisfies `c < b ≤ c + K` (expiry `≤ now + 30 d`, aligned). Suppose
bucket `b` is written and its slot holds tag `b' ≠ b`. Then `b' ≡ b (mod K)` and `|b − b'| ≥ K`. `b'` was written
at an earlier bucket `c' ≤ c`, so `b' ≤ c' + K ≤ c + K < b + K`, hence `b' ≤ b − K ≤ c`: `b'` is expired. So a slot is
never overwritten while it holds live capacity, and `K = 720` slots suffice for a 30-day horizon.

**Sweep.** `sweep` walks `b = swept + 1 … min(c, swept + 32)` and subtracts every slot whose tag equals `b`. If
`c ≥ maxBucket`, every bucket ever written has expired: `Q_a := 0` and `swept := c` in O(1). The ring starts with
`swept = ⌊deployment time/δ⌋`; starting at 0 would make the first walk cover every hour since 1970.

**Conservative when behind.** A capped sweep leaves `Q_a` too high, never too low (V-3), so `F` and admission are
conservative, never unsafe. Every call that sweeps advances by up to 32 buckets; a quiet vault catches up on the
next calls or through the shortcut. A permissionless `sweep(maxSteps)` may be added if C02 measurements show a need;
it is not required for safety.

**What it does not do.** Contracts do not run when time passes. Expiry is *recognized* lazily, by the next vault call
that sweeps, at a bounded cost; no keeper and no knowledge of allocation ids is needed. Per-scope totals
(`hookReserved`, `curatorReserved`) stay lazy until `release`; they are only read for exposure caps and ceilings,
where a stale (high) value is conservative and costs only that curator's or hook's own admissions. `release` after
expiry remains permissionless for that cleanup, and the escrow's `settle` calls it (§5).

**Not an epoch flow limit.** Flow caps (`FLOW_WINDOW = 1 day` gross outflow per scope) are unchanged and remain a
speed limit. The ring changes when reserved capacity stops counting; it does not cap flow, and flow caps do not expire
reservations.

**Evidence (TESTED (model), `test/model/ExpiryRingModel.t.sol`, 8 tests).**
- Exact boundary: consumable at `expiry − 1`, refused at `expiry`; `Q^live` drops at `expiry` with no call.
- Slot reuse after wrap-around; eviction subtracts once; close before and after a sweep; long gap shortcut; capped
  sweeps between `Q^live` and `Q^lazy` and converging.
- `testFuzz_ringMatchesReference`: 1,000 random schedules of 80 steps (reserve, reserve without sweep, consume, close,
  sweep, warps up to twice the horizon) against a reference that scans every reservation: `live() = Q^live` exactly,
  and `Q^live ≤ Q ≤ Q^lazy` after every step.

Gas and storage are in §8.

**Alternatives.** One-day buckets (K = 30) are simpler but quantize expiry to UTC days; a 4-hour reservation would be
billed and withheld for up to a day (V2-2, §10). The degenerate ring K = 1 (zero `Q` only when every reservation of
the asset has expired) costs 337 B instead of 1,185 B but frees nothing while reservations overlap; it is the fallback
if C02's real measurement does not fit (§8). A separate ledger contract saves almost nothing (1,072 B of call
encoding in the vault instead of 1,185 B, MEASURED) and adds a call to every path: rejected (REJECTED-5).

### 3.6 Effect of each operation

Δ per asset; blank = unchanged. `b` = the allocation's expiry bucket; "ring" = the slot of `b`.

| Operation | `B` | `W` | `Q` | ring | `N` | `F` | `S` | escrow |
|---|---|---|---|---|---|---|---|---|
| create `q` (+ bond `Y`) | | | `+q` | `+q` | | `−q` | | `+Y` claims; record |
| consume `x` (`exchange`, sold asset) | `−x` | | `−x` | `−x` | `−x` | | | none (learns at the next sync) |
| receive input `i` (`exchange`, bought asset) | `+i` | | | | `+i` | `+i` | | |
| release remaining `r` before expiry | | | `−r` | `−r` | | `+r` | | accrual stops at the observed close |
| expire (time passes) | | | | | | | | accrual on `r` stops at `b·δ` |
| sweep after expiry | | | `−r` (if not yet out) | | | `+r` | | |
| release after expiry | | | 0 (already swept) or `−r` | same | | same | | `settle` (§5) |
| LP deposit `s` | `+⌈sN/S⌉` | | | | same | same | `+s` | `realize()` first |
| LP instant exit `s` | `−⌊sN/S⌋` | | | | same | same | `−s` | none |
| queue finalization `s` | | `+⌊sN/S⌋` | | | `−⌊sN/S⌋` | same | `−s` | none |
| claim | `−c` | `−c` | | | | | | none |
| fee realization `x` (reserved asset) | `+x` | | | | `+x` | `+x` | | `−x` claims |
| raise `τ_a` / lower `κ_a` (guardian or owner) | | | | | | | | room shrinks; existing `Q` unchanged |
| lower `τ_a` / raise `κ_a` (LONG_DELAY, empty queue) | | | | | | | | room grows |
| oracle outage, pause, halt, freeze | | | | | | | | fills refused; `Q` unchanged; accrual continues |

**Effects on accepted commitments.**
- **LP withdrawals** never reduce `r_j` or take reserved units (G-R1). They shrink the room by `room·s/S`, which can
  make part of `r_j` unsellable (§3.3). Queued requests wait behind reservations admitted before them, at most until
  those expire, and V2 removes expired capacity without a release call.
- **Changed inventory targets.** A guardian tightening takes effect at once and can make reservations unsellable
  (§3.3 in the other direction); a loosening needs LONG_DELAY with an empty queue (G02 S-1). Neither changes `Q` or
  any bond.
- **Oracle outages.** Fills stop (G04 O-1); `Q` stays; bond accrual continues (R-23, §10); the payer's remedy is an
  early close through the curator, the guardian's is emergency release (unearned bond refunded).
- **Adapter replacement** (DELAY) re-prices every live reservation at once (G04 §9 item 5); unchanged in V2.

## 4. Reservation state machine

States are per allocation `j`; the bond columns are in §5.5.

| State | Condition | Enters by | Leaves by |
|---|---|---|---|
| Intent | signed, not activated | curator signs (off-chain) | `activate` within `[validAfter, deadline]`; nonce invalidation; generation bump |
| Live | `!released`, `now < expiry` | `activate` → `reserveFor` + `post` (one transaction) | fills (stay Live while `r > 0`); close; expiry |
| Live, exhausted | `r = 0`, `now < expiry` | last fill | close; expiry (nothing left to remove) |
| Expired, counted | `now ≥ expiry`, bucket not yet swept | time | any sweep reaching `b`; release |
| Expired, swept | `now ≥ expiry`, `b ≤ swept` (or evicted) | sweep | release (scope cleanup only); `settle` |
| Closed | `released` | curator cancel; owner/guardian emergency release; anyone if expired or curator revoked | terminal (vault) |

Transitions that cannot happen: Closed → anything; Expired → Live; a fill at or after `expiry`; a fill by another hook
or on another pool; a second close. A curator freeze makes fills revert but leaves the state Live (accrual continues);
revocation lets anyone close it.

Who may move a reservation out of Live early: its curator (`cancelAllocation`, any time, any state, while paused);
the owner or guardian (`release`, emergency); anyone once the curator is revoked. A payer who is not the curator has
no direct close in V2 (D-4, §10).

## 5. Reservation bonds and fee accounting (PROPOSED)

### 5.1 What the bond pays for

A bond pays LPs for capacity withheld from them over time: G-R1 exclusive accounting capacity, which blocks LP exits
(`F = N − Q`) and other admissions. It is not insurance of execution (§3.2, G-R4). The terms a payer accepts, and
that interfaces and documentation must state, are:
- the fee accrues on the unused remainder until expiry or an observed close, whether or not fills are possible;
- pause, direction halts, curator freezes, oracle outages, flow caps and room lost to LP exits do not stop accrual;
- the payer's remedy is an early close (through the curator) or the guardian's emergency release, after which the
  unearned bond is refunded.

These resolve D-6 and R-23 (§10). The alternative of suspending accrual while fills are refused needs an on-chain
record of every refusal interval, including oracle outages a `view` call cannot prove, and invites timing games;
rejected (REJECTED-7).

### 5.2 Creation (one transaction)

1. The **payer** calls `CommitmentAuthorizer.activate(intent, key, signature)`. The curator's EIP-712 intent contains
   today's fields plus `payer` and `maxRate`; the authorizer requires `msg.sender == payer`, so nobody else can spend
   the payer's allowance or activate at a time the payer did not choose.
2. The authorizer calls `vault.reserveFor` (all V2 admission rules, §3.4) and receives `allocationId`.
3. The authorizer calls `escrow.post(allocationId, payer, maxRate)`. The escrow
   - accepts only `msg.sender == vault.authModule()`;
   - reads the allocation (asset `a`, `maxOut = A`, `expiry`), requires it unconsumed, unreleased and unbonded;
   - fixes `ρ_j = rate_a` (the escrow's governance-set rate for `a`) and requires `ρ_j ≤ maxRate`;
   - computes the bond `Y_j = ⌈A·(expiry − now)·ρ_j / 1e18⌉`, pulls `Y_j` of `a` (ERC-20) from the payer, settles it into
     the PoolManager and mints ERC-6909 claims **to the escrow**;
   - adds `A·ρ_j` to the asset's accrual rate and to the rate drop of bucket `expiry/δ` (§5.4).
4. Any failure reverts all of it: no reservation without its bond, no bond without its reservation.

Every reservation made through the V2 authorizer is bonded; with `rate_a = 0` the bond is 0 and nothing accrues
(today's behaviour, without anti-griefing). Recommended launch setting: `rate_a > 0`.

### 5.3 Accrual, charge and refund per reservation

Notation per reservation `j`: `A` reserved, `t_c` creation, `t_1` expiry, `ρ` rate (fee units of `a` per reserved unit
of `a` per second, scaled by `1e18`), `r(t)` the remainder **as the escrow knows it**.

    I_j(t)    = ∫ r(u)·ρ du   over [t_c, min(t, t_1, t_close)),  kept unscaled (exact integer "rho-seconds")
    Y_j       = ⌈A·(t_1 − t_c)·ρ / 1e18⌉                                         bond, prepaid
    I_min     = A·min(T_min, t_1 − t_c)·ρ                                          minimum charge, rho-seconds
    charge_j  = ⌈max(I_j, I_min) / 1e18⌉   at settlement
    refund_j  = Y_j − charge_j ≥ 0

`I_j ≤ A·(t_1 − t_c)·ρ` because `r ≤ A` and accrual stops at `t_1`, and `I_min ≤` the same bound, so
`charge_j ≤ Y_j` (PROVEN; TESTED (model) `charge never exceeds bond`).

**Lazy consumption (new in V2).** The escrow is not on the swap path, so it does not see fills when they happen.
`sync(j)` (anyone, any time) reads the vault's `consumed` and `released` for `j`, accrues to now, and then lowers `r`
by the consumption it had not seen. Consumption therefore stops accruing at the sync, not at the fill: the payer is
charged `x·ρ·(t_sync − t_fill)` extra for a fill of `x` synced late (`test_lazySync_overchargeIsExact`: 30,000 units
synced one day late cost exactly 2.592 more at `ρ = 1e-9`). The error is always against the payer and in favour of
LPs, and the payer removes it by syncing in the fill's transaction (a hook may call `sync` in `afterSwap`; that is the
hook's choice and puts the escrow on that hook's path only).

A close the escrow did not perform (curator cancel, emergency release, revoked-curator cleanup) is observed the same
way: accrual stops at the sync that sees `released`. A curator that cancels and syncs in one transaction stops
accrual exactly.

Why not exact accrual inside `exchange`: it needs a per-allocation consumption-time moment `Σ x·t` (up to 2^167, a
new storage slot written on every fill) or a call from `exchange` to the escrow. Both cost every swap; the first also
costs vault bytes. Rejected (REJECTED-8).

**Settlement.** `settle(j)` is open to anyone once `j` is closed (observed) or `now ≥ t_1`. It syncs, computes
`charge_j`, credits `refund_j` to the payer, moves `j` from the open aggregate to the settled total (§5.4), sets a
terminal flag, and calls `vault.release(allocationId)` if the allocation is still unreleased (permissionless after
expiry; it cleans the per-scope totals, §3.5). A second `settle` reverts.

**Refunds and protocol fees are pulled.** `claimRefund(to)`: the payer chooses the recipient, so a payer whose
address a token refuses can still be paid (unlike the vault's fixed request receiver, G03 CE-5). Unclaimed refunds
stay in the escrow forever (D-5). `claimProtocol()`: the protocol recipient (governance-set) only.

### 5.4 Aggregate realization and LP fee ownership

**Why aggregate.** LPs must receive fees before any change of `S` they did not pay for (G03 model: a just-in-time
depositor took 43.2 of 86.4). Realizing per reservation before each deposit would iterate over every open bond.
Instead the escrow keeps, per asset, the rate `Rate_a = Σ r_j·ρ_j` over open, unexpired reservations, and a ring of
rate drops per expiry bucket (the same `δ = 1 h`, K = 720 layout as §3.5). The aggregate accrual
`Agg_a(t) = Σ_open I_j(t)` advances bucket by bucket, applying each bucket's drop at its end. Because every expiry is
a bucket end, the aggregate and each reservation stop at the same second.

**Realization.** `realize()`:

    target_a   = settledCharges_a + ⌊Agg_a(now) / 1e18⌋
    Δ_a        = target_a − realized_a
    protocolΔ  = ⌊target_a·π / 10⁴⌋ − ⌊realized_a·π / 10⁴⌋          π = protocol share, bps
    lpΔ        = Δ_a − protocolΔ          → vault.realizeFee(a, lpΔ)  (the vault pulls exactly lpΔ claims)
    realized_a = target_a

`target_a` never falls: when `j` settles, `settledCharges` rises by `charge_j ≥ ⌈I_j/1e18⌉` while `Agg` falls by `I_j`,
and `⌊x⌋ ≤ ⌊x − y⌋ + ⌈y⌉`.

**Ownership rule.** A fee becomes LP property when it enters `N_a` through `realizeFee`; from then on it belongs to the
`S` outstanding shares pro rata, queued shares included, exactly like a hook's spread. Before that it is escrow-held,
belongs to no LP, is not in any share price, and is not claimable by anyone: "accrued but unpaid LP revenue" is
`U_a = target_a(now) − realized_a`.

- **Deposits realize first.** `vault.deposit` calls `escrow.realize()` before computing the price, inside its lock
  (`realizeFee` is lock-free and accepts only the escrow, so the call back works). If `realize` reverts, the deposit
  reverts: deposits fail closed (D-2). `test_jitDeposit_buysNoPastFees`: the depositor redeems for what it paid, less
  at most one raw unit.
- **Exits never call the escrow** (P-5 kept). An LP that exits, or a queued request finalized, between realizations
  forfeits its pro-rata part of `U_a` to the shares that stay (`test_exitBeforeRealization_forfeitsProRata`). It can
  call `realize()` itself first. The forfeit is at most `(s/S)·U_a` and favours the remaining LPs, never a newcomer.
- **Bounded walk.** `realize` walks at most a fixed number of buckets per call (proposal: 32). If it cannot reach `now`
  it realizes up to where it got; the deposit path then reverts with `EscrowBehind` instead of pricing on a stale
  realization, and anyone can catch up with `realize(maxSteps)`.

**Exactness (TESTED (model), `test/model/BondLedgerModel.t.sol`, 7 tests).**
- `testFuzz_aggregateIsExactAndEscrowSolvent` (1,000 schedules × 60 steps: create, vault fills, late syncs, early
  closes, settlements, realizations, claims, warps): after every step the aggregate equals the sum of per-reservation
  accruals exactly; nothing is realized before it is earned; and the escrow identity of §5.6 holds. At the end every
  bond splits exactly into LP fees, protocol fees and refunds.
- `testFuzz_realizationFrequencyIsIrrelevant`: realizing at random points or only at the end gives identical charges,
  LP and protocol totals and refunds.
- `test_aggregateRealization_matchesPerReservationCharge`: G03's example D through the aggregate (35.424 realized on day
  5 without touching the reservation; final charge 41.472; LPs 37.3248, protocol 4.1472).
- `test_schedulesExerciseEveryOperation`: over 16 seeds, before the final sweep, 133 reservations, 31 with fills, 463
  reservation-steps with unsynced fills, 55 early closes, 20 settlements, and a non-zero realization in all 16.

### 5.5 Fee state machine

Per bond `j`:

| State | Condition | Enters by | Leaves by | Accrues? |
|---|---|---|---|---|
| Open | posted, not closed, `now < t_1` | `post` | sync (stays Open, `r` lower); observed close; time | on synced `r` |
| Closed | close observed by a sync | `sync` sees `released` | `settle` | no |
| Expired | `now ≥ t_1`, not settled | time | `settle` | no (clipped at `t_1`) |
| Settled | terminal flag | `settle` | — | no |

Escrow-level balances per asset (raw units of `a`, as ERC-6909 claims held by the escrow):

| Bucket | Increases | Decreases |
|---|---|---|
| open bonds `Σ_open Y_j` | `post` | `settle` (moves `charge` to settled charges and `refund` to refunds owed) |
| earned, unrealized `U_a` | time (aggregate) | `realize` |
| refunds owed | `settle` | `claimRefund` |
| protocol owed | `realize` (`protocolΔ`) | `claimProtocol` |
| LP fees moved | `realize` (`lpΔ`) | — (now in the vault's `N_a`) |

### 5.6 Bond collateral stays separate from LP backing

Kept from the design note §2.6 (R-B1 … R-B3), with the V2 mechanics:
- **Custody.** Bonds are ERC-6909 claims owned by the escrow's address. The vault's `B_a` counts only what the vault
  has accounted for (V-1); the escrow's claims are not the vault's balance at all.
- **One inflow path.** The only escrow-to-vault movement is `realizeFee`, called by `realize` for fees already earned;
  it raises `B_a` by exactly the claims pulled and mints no shares.
- **Per-reservation limits.** `charge_j ≤ Y_j`; a bond pays only its own charge and its own refund; refunds go only to
  the payer's chosen recipient.
- **Admission reads only `N, Q, R, D, L`.** A bond can never back a reservation, an exit or a fill.
- **Escrow identity (PROVEN; TESTED (model)).** Per asset, at every step:

      escrow + realized = refunds owed + protocol owed + Σ_open Y_j + settled charges
      realized − settled charges ≤ ⌊Agg/1e18⌋ ≤ Σ_open Y_j

  so the escrow always holds every owed refund, every owed protocol fee and the unearned part of every open bond.

### 5.7 Pricing and rounding

**Deterministic pricing.** `rate_a` is a number stored in the escrow, set by the owner through the governor (DELAY),
fixed per reservation at creation and capped by the signed `maxRate`. No model, no learned or adaptive pricing, no
oracle. The blueprint's utilization-scaled premium `Q·k·(f_base + f_slope·U/(1 − U))` is deterministic but unbounded as
`U → 1` and is an upfront charge with no refund; not adopted for V2 (REJECTED-6). A bounded, kinked utilization
schedule evaluated at creation is a possible later addition (DEFERRED-3).

**Units.** The fee asset is the reserved asset (D-1), so `ρ` is dimensionless per second and independent of token
decimals: `1e18` scaling resolves rates down to `1e-18`/s (about `3.2e-11` per year), which removes the design note's
need for a `1e36` scale. Bounds: `A ≤ 2^127`, durations `≤ 2^22` s, so `A·T ≤ 2^149`; products with `ρ` use
`FullMath.mulDiv` (512-bit). `Rate_a = Σ A·ρ` fits 256 bits for `ρ < 2^100`; the escrow caps `rate_a` (proposal:
`≤ 1e18`, i.e. 100% of the amount per second) so no sum can overflow.

| Quantity | Rounding | Favours | Bound |
|---|---|---|---|
| bond `Y` | up | LPs (covers the largest charge) | < 1 unit |
| aggregate realization | down (`⌊Agg/1e18⌋`) | nobody: the remainder is realized later | < 1 unit outstanding |
| final charge | up | LPs and protocol, against the payer | < 1 unit per reservation |
| protocol share | down on cumulative totals | LPs | < 1 unit in total, not per step |
| refund | exact `Y − charge` | — | 0 |
| deposit / exit | up / down (unchanged) | remaining shares | < 1 unit per payout (G03 G-7) |

**Parameters** (owner through the governor, DELAY; the guardian has no power over them): `rate_a` per asset,
`T_min` (D-3; proposal 1 hour), `π` (proposal: immutable cap 2,000 bps), the protocol recipient. A rate change applies
only to reservations created afterwards.

### 5.8 Failure and recovery

| Failure | Effect | Recovery |
|---|---|---|
| `escrow.realize` reverts (bug, walk behind) | deposits revert; exits, claims, swaps, admissions unaffected | catch up with `realize(maxSteps)`; for a bug, the owner unsets `feeEscrow` (DELAY): deposits resume, fees still in the escrow stop reaching LPs |
| `vault.realizeFee` reverts (amount above `MAX_AMOUNT − B`) | as above | as above |
| a payer's token transfer refused at creation | activation reverts | none needed |
| refund recipient refuses the token | that claim reverts | claim to another address |
| nobody syncs after a fill or close | payer over-charged until a sync | anyone may sync; the payer can always |
| nobody settles after expiry | refund waits; `Q` is already free (ring); per-scope totals stale | anyone may settle |
| escrow replaced while bonds are open | the old escrow keeps settling and refunding but can no longer realize: the LP part of its remaining fees is stranded | replacement procedure, §7.5 |
| escrow has a bug that locks claims | locked | none: no admin can withdraw escrow funds (intended; §7.6) |

### 5.9 Adversarial cases

| Attack | Control | Status |
|---|---|---|
| Reserve all admissible capacity briefly, release | `T_min` minimum charge | design note §2.3; TESTED (model) |
| Self-trade to reduce the fee | fee on remainder; no volume term; consumption stops accrual only as release would | design note §2.2 |
| JIT deposit before realization | `deposit` realizes first | TESTED (model) |
| Exit just before realization | forfeits own share to remaining LPs | TESTED (model) |
| Delay someone else's sync to inflate their charge | anyone, including the payer, can sync at any time | ARGUED |
| Keep the escrow behind so a deposit prices stale | deposit reverts with `EscrowBehind` | PROPOSED |
| Rate raised between signing and activation | `maxRate` in the signed intent | PROPOSED |
| Another party activates the curator's intent | `payer` signed and must be `msg.sender` | PROPOSED |
| Replay of an intent | nonce bitmap, generation, deadline (unchanged); one `post` per allocation id | IMPLEMENTED + PROPOSED |
| Bond counted as backing | separate custody; admission reads `N` only | §5.6 |
| Realization timed to move core-mode quotes | realization raises `N_1` like a donation of earned fees; amount is not attacker-chosen; bounded by `U_a` | ARGUED; CE-G5-6 (§12.3) |

## 6. Idle-yield custody and loss model

### 6.1 The two models

**Model A — LP-held, not recallable.** The commitment reserve is 100% physical ERC-6909 claims. Porkfolio holds no
external ERC-4626 shares, calls no strategy and recalls nothing. An LP who wants yield on part of its capital holds
the external shares itself (outside Porkfolio, or later through an optional periphery wrapper that is not part of the
core and that the vault does not know about). Those shares are not available to Porkfolio and are never counted.

**Model B — custody module, recallable.** A `YieldCustody` module holds external shares `Z_a` for the vault's
shareholders and can attempt redemption ("recall") when the vault needs physical inventory. Share accounting is in
kind (design note §3.4, Y1): each vault share is a fraction of physical `N_a` and of `Z_a`; deposits buy both parts;
exits receive both parts, the external part as a claimable balance in the custody module. Book-value accounting
(Y2) is rejected (D-7): a stale value pays exiting LPs at the expense of remaining ones (400,000 paid against a fair
360,000 in `test_bookValue_staleExitTransfersLoss`) unless every exit re-reads the strategy, which breaks P-5.

### 6.2 Comparison

| Criterion | Model A | Model B (Y1, in kind) |
|---|---|---|
| Shared-liquidity goal (commitments on one reserve) | fully met | met only for physical capital; every unit deployed is not admissible and not instantly exitable until recalled |
| Idle-yield goal | not met inside the reserve | met for capital above every requirement (`I_a`, §6.3) |
| Counts external assets as backing? | no | no (required); admission, `W`, `D`, `R` and fills stay physical |
| Strategy code reachable from | nowhere | deploy, recall, deposit (buying the external part); never `exchange`, exits or claims |
| Deposits depend on the strategy? | no | yes: fail closed while the strategy refuses `mint` |
| Exits depend on the strategy? | no | no, if the external part is credited to a claimable ledger rather than transferred |
| Valuation of external shares | none | none (in kind) |
| Loss allocation | n/a | pro rata through each share's external part; realized recall losses pro rata through `N_a` |
| New attack surface | none | inflation/donation on first deploy, strategy pause, transfer hooks, withdrawal fees, illiquidity, allowlist governance |
| Vault changes | none | deposit, redeem, queue finalization and claim paths carry a third basket component; a no-share inflow entry for recalls; deploy entry; inventory-floor interaction (D-8). ESTIMATE ≥ 1 KB of vault runtime (not measured) |
| Fits the V2 byte budget (§8)? | yes | **no**: V2 already uses the reclaimed bytes |

### 6.3 Can either model meet both goals?

**Neither meets both in full (PROVEN for B's limit, from the admission rule).** Admission, fills, `W` and `D` must use
physical claims only, because `maxWithdraw` and `previewRedeem` describe the present and promise nothing about the
moment a reservation is consumed (G03 design note §3.2). Hence at any instant deployed capital and committable
capital are disjoint:

    deployable_a = I_a = max(0, min(N_a − Q_a − R_a − D_a − K_a,  room_a − Q_a))

with `K_a` a liquidity buffer for instant exits (D-10). Deploying `x` lowers future admissible capacity and `F_a` by
`x` until it is recalled, and recall is best effort. So B delivers yield only on capital that neither current
commitments, nor the queue, nor the buffers, nor the inventory room above `Q` need; and when demand for commitments
returns, that capital is not available for admission until a recall succeeds.

- **A** keeps the shared-liquidity guarantees exactly as they are and gives no yield inside the reserve.
- **B** gives yield on genuinely idle capital without weakening any commitment, at the cost of strategy-dependent
  deposits, a four-asset exit basket (two pair tokens, two strategy share tokens), new governance (allowlist, caps,
  deployer role) and at least a kilobyte of LP-path code in the vault.

### 6.4 Capital movements (specification for Model B; not in V2)

Per asset `a`; `N_a` physical, `Z_a` external shares by internal count (shares sent to the module directly are not
counted, as donated claims are not).

| Movement | Who | Condition | Effect |
|---|---|---|---|
| Deploy `x` | deployer role within limits (D-9) | `x ≤ I_a`; strategy allowlisted with `asset() = a`; `maxDeposit ≥ x`; caps; value check: shares received redeem now for ≥ `x(1 − ε)`; shares received = measured balance change; exact approval | vault burns `x` claims, custody deposits `x`, `B_a −= x`, `Z_a += shares` |
| Partial recall `z` shares | deployer; anyone when `F_a < K_a` or the queue head waits (D-11) | `z ≤ maxRedeem(custody)`; minimum assets bound | custody redeems, settles ERC-20 into claims, vault `B_a += assets` through a no-share inflow entry (custody only), `Z_a −= z` |
| LP deposit `s` | anyone | strategy accepts `mint` | physical `⌈s·N_a/S⌉` + external `⌈s·Z_a/S⌉` shares minted at the depositor's expense (`previewMint` rounds up) |
| LP exit `s` | LP | as today for the physical part | physical `⌊s·N_a/S⌋`; external `⌊s·Z_a/S⌋` credited to the LP's claimable balance in the custody module; no strategy call |
| Queue finalization | permissionless | as today | as an exit, at finalization |
| Realized loss | — | recall returns fewer assets than the pre-fee value | shortfall stays out of `N_a`: borne by every share pro rata |
| Unrealized loss / gain | — | share price moves | each share's external part moves pro rata; nothing is accounted |
| Strategy pause / illiquidity | — | — | deploys, recalls and deposits revert; exits continue; external parts stay claimable |
| Shutdown | owner (DELAY) stops deployment; recall what can be recalled | — | the rest stays in kind; LPs receive their external part on exit; nothing is written down or valued |
| Non-transferable shares | — | — | refused at allowlisting; the claimable ledger is the fallback if a strategy changes (D-12) |

Loss model: every loss of the external position is borne pro rata by the shares outstanding when it happens, in kind;
no LP can exit ahead of a loss at a stale price, because nothing is ever priced. Commitments, `W` and the queue's
physical claim are unaffected by any strategy event.

### 6.5 Recommendation (DECISION V2-3)

**Model A for V2.** Reasons, in order:
1. It keeps every commitment and exit guarantee exactly, with no new external code reachable from Porkfolio.
2. B's yield exists only on capital the commitment engine does not need, and taking it reduces what the engine can
   sell until a recall succeeds; the product's core is commitments, not yield.
3. B needs LP-path changes in the vault that do not fit next to the V2 ledger and bond changes (§8), so B implies a
   vault split or giving up keeper-free expiry.
4. No measured idle-capital data exists to justify B's complexity; the blueprint's APY figures are unverified
   hypotheses (`ACCOUNTING_FLOW.md` §7).

Tradeoff accepted: the idle-yield goal is not met inside Porkfolio in V2. **Model B (Y1, claimable external parts) is
the only design to consider later**, gated on: a vault split or measured bytes; an allowlisted strategy whose shares
are transferable without hooks; measured idle capital; and D-7 … D-12 as resolved in §10.
