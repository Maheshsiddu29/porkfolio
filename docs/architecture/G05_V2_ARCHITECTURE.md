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
`test/model/ExpiryRing.sol` (library, 106 lines).

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
