# C02: Time-bound commitment ledger (room-aware admission and the expiry ring)

**Status: implemented locally, awaiting owner review.** §1–§9 are the plan as committed before any production change
(`03aa331`) and stay as written. Results, measured numbers and every deviation from the plan are in §10.

Basis:
- `docs/architecture/G05_V2_ARCHITECTURE.md` (the ADR) is the specification, in particular §3.2–§3.6 (reservation
  guarantees, the conflict with LP exits, the per-asset ledger, the bucketed ring, the effect of each operation), §8
  (byte and gas budget), §10.3 V2-2 and V2-4, §10.5 B-G5-1, §11 (C02 row) and the invariants V-2 … V-10 of §12.1 with
  the boundary cases of §12.2.
- The owner's C02 instruction for this milestone.
- C01 (`docs/implementation/C01_VAULT_BYTECODE.md`), integrated into `main` at `5ab3051`: the vault's storage layout
  is part of its read interface, `VaultStateReader` decodes it and `test/unit/VaultStorageLayout.t.sol` pins it.
- Reference implementation: `test/model/ExpiryRing.sol` and `test/model/ExpiryRingModel.sol` (test-only, G05). They
  are the differential reference for the vault's ring; they are not copied into `src/`.

Labels as in the ADR: **MEASURED** (a command in §10 produced it), **ESTIMATE**, **TARGET** (acceptance threshold set
here), **PROVEN** (hand proof in this document; nothing is machine-checked), **ASSUMPTION**.

## 1. Objective

Exclusive, time-bound capital commitments whose expiry is recognized without a keeper releasing each allocation, while
keeping every existing financial guarantee of `SharedCommitmentVault`:

1. **Room-aware admission** (ADR §3.4, R-15): a new reservation must also fit above the inventory floor.
2. **Expiry ring** (ADR §3.5): expired capacity leaves the stored reserved total `Q_a` through bounded sweeps run by
   reservation and LP-exit paths, never by the swap path.
3. Correct updates on every path that touches `Q_a`, with no bucket ever subtracted twice.
4. Storage-reader compatibility: the new state is decoded by `VaultStateReader`, served by `VaultLens` and pinned by the
   layout test; no existing slot moves.

What C02 does **not** claim: that an admitted reservation can be executed later (G-R4 is refused by the ADR, §3.2 and
§3.3: LP exits, the oracle, pauses, halts, freezes and flow caps can all stop a fill), or that expiry is recognized
without any transaction (a contract runs only when called; ADR assumption A-8).

## 2. Scope

In scope:
1. `src/SharedCommitmentVault.sol`: room-aware admission; hour-aligned expiry; the ring (storage, sweep, add, remove);
   sweeps in `reserveFor`, `redeem` and `processQueue`; ring removal in `exchange` and `_close`; NatSpec in the same
   commit.
2. `src/interfaces/ISharedCommitmentVault.sol`: NatSpec of `AllocationRequest.expiry`, `Allocation.expiry`,
   `InvalidExpiry`, `InsufficientBacking` (documentation only; no new error, event or function, see §3.7).
3. `src/libraries/VaultStateReader.sol` and `src/VaultLens.sol`: ring slot constants and decoders; `liveReserved`,
   `sweptReserved`, `expiryRing`, `expiryBucket`; `admissibleCapacity`, `freeInventory` and `deliverableShares` restated
   on what the next sweeping call would compute (§3.6).
4. Tests: room-aware admission (§5.1), ring unit and boundary tests (§5.2), path tests (§5.3), storage layout and
   reader (§5.4), adversarial cases (§5.5), differential test against the G05 model (§5.6), invariant handler
   extension for V-2 … V-10 with non-vacuity counts (§5.7), liveness (§5.8), gas bench rows (§6).
5. Existing tests whose expectation the ADR changes (CE-1 now refused; "lazy expiry still blocks" now false; `Q_a` no
   longer equals the sum over unreleased allocations once time passes). Each change is listed in §10 with its reason.
6. Existing tests that create allocations with an expiry that is not on an hour boundary: the expiry they construct is
   aligned (rounded down to the hour) and nothing else changes. Listed in §10.
7. Documentation: this file, the vault and reader NatSpec, the C01 doc's "residual risks" pointer is left as history.

Out of scope (the brief's §7, or later milestones): `BondEscrow`, reservation fees, `realizeFee`, `deposit → realize`,
ERC-4626, a new permissioning model, Hook C, curator dashboards or SDKs, governance changes unrelated to the commitment
engine, RL pricing, the C-1 TVL cap, a permissionless `sweep(maxSteps)` entry (DEFERRED-9; `processQueue(0)` already
sweeps, §3.4), the empty-bucket bitmap (DEFERRED-8), flow-aware admission (DEFERRED-7), any change to the hooks, the
governor, the adapter or the authorizer source.

## 3. Design

### 3.1 Notation

Per asset `a`, raw units, as in the vault NatSpec and ADR §3.4: `B` backing, `W` finalized-unclaimed, `N = B − W`,
`Q` stored reserved total, `F = N − Q`, `S` total shares, `P` pending shares, `D = ⌈P·N/S⌉`, `E = N − D`, `R` buffer
floor, `τ`, `κ` inventory target and tolerance, `L = ⌈S·τ·(10⁶ − κ)/(10¹⁸·10⁶)⌉` when `τ ≠ 0`, `room = max(0, N − L)`.
`Q^live` = unused capacity of unreleased, unexpired allocations; `Q^lazy` = unused capacity of unreleased allocations
(the pre-C02 `Q`). Bucket width `δ = 3600 s`, ring size `K = 720`, sweep cap `32`, `c = ⌊now/δ⌋`.

### 3.2 Room-aware admission

`reserveFor` sweeps the asset first (§3.4), then admits `q = maxOut` only if

    q ≤ max(0, N − Q − R − D)                    (unchanged; computed by subtracting in turn with a floor at zero)
    q ≤ max(0, room − Q)                          (new; only when τ_a ≠ 0)

and reverts with the existing `InsufficientBacking(q, available)`, where `available` is the minimum of the two limits.
The curator ceiling and the three exposure caps are unchanged and still checked after it; the vault-scope cap reads the
swept `Q`. `L` uses the vault's own `VaultRiskBoundary.inventoryFloor(S, τ, κ)` (rounded up, against admission), with
`S` including pending shares, exactly as fills use it, so the bound "right after admission `Q ≤ N − L`" is the same
quantity the inventory check of a fill compares against.

Cases:
- `τ_a = 0`, static mode: no floor, no room rule (ADR §3.4).
- `τ_a = 0`, adapter mode: no room rule; the allocation is admitted but every fill of it is refused
  (`InventoryBoundsNotConfigured`, G04). The ADR relies on configuration (`τ` set for every tradable asset in adapter
  mode). Refusing such an admission would be a design change; it is listed for the owner (§9) and not implemented.
- `κ_a = 10⁶`: `L = 0`, room = `N`, so the room rule is implied by the first rule.

Guarantee (G-R3, PROVEN by construction): immediately after a successful `reserveFor`, `Q ≤ N − R − D` and, when
`τ ≠ 0`, `Q ≤ N − L`. Nothing later is guaranteed: an LP exit shrinks the room (CE-2, ADR §3.3), a guardian may
tighten `τ`/`κ`, and fills may be refused for unrelated reasons.

### 3.3 Hour-aligned expiry

`reserveFor` additionally requires `expiry % 3600 == 0` and reverts with the existing `InvalidExpiry()` otherwise
(§3.7). With the existing `now < expiry ≤ now + MAX_HORIZON`, the bucket `b = expiry / δ` satisfies `c < b ≤ c + K`
(PROVEN: `expiry > now ≥ c·δ` gives `b > c`; `b ≤ (now + 720·δ)/δ < c + 721`). An allocation is consumable while
`now < expiry`, i.e. while `b > c`; this is unchanged, since `exchange` still compares `block.timestamp` with the
stored `expiry`.

### 3.4 The ring

Storage (appended after slot 27, §4):

    struct ExpiryBucket { uint40 bucket; uint128 amount; }                    // one slot
    struct ExpiryRing   { uint40 swept; uint40 maxBucket; mapping(uint256 => ExpiryBucket) buckets; }
    mapping(Currency => ExpiryRing) internal _expiryRings;                   // slot 28

Bucket `b` lives in `buckets[b % 720]`, tagged with `b`. `swept`: every bucket `≤ swept` has been taken out of `Q`.
`maxBucket`: the largest bucket ever written. Representation invariant (RI):

    Q_a = Σ { amount_i : slot i with tag_i > swept }                         (exact, after every external call)

Operations (one implementation in the vault; the model in `test/model/ExpiryRing.sol` is the reference):

| Operation | Ring step | Called by |
|---|---|---|
| `_sweep(a)` | if `c ≤ swept`: nothing. Else if `c ≥ maxBucket`: `Q := 0`, `swept := c` (O(1)). Else walk `b = swept+1 … min(c, swept+32)`, subtract each slot whose tag is `b`, `swept := last b` | `reserveFor` (sold asset), `redeem` and `processQueue` (both assets) |
| add `(b, q)` | slot of `b`: same tag → `amount += q`; other tag → if that tag `> swept` subtract its amount from `Q` (eviction), then tag `:= b`, `amount := q`; `maxBucket := max(maxBucket, b)`; `Q += q` | `reserveFor` |
| remove `(b, x)`, live | slot of `b`: if tag is `b`, `amount −= x`, `Q −= x` (no header read) | `exchange` |
| remove `(b, x)`, any | if `b ≤ swept`: nothing; else as above (a mismatched tag means the bucket was evicted: nothing) | `_close` (`release`, `cancelAllocation`) |

The ring starts at `swept = maxBucket = 0` with no constructor write: the first sweep finds `c ≥ maxBucket = 0` and
takes the O(1) branch (`Q` is 0 then), so no walk ever starts at bucket 0. Deviation from the ADR's "start at the
deployment bucket", same effect, no init code (§10 records it).

**No live slot is overwritten (PROVEN; ADR §3.5).** Writing bucket `b` (`c < b ≤ c + K`) into a slot tagged `b' ≠ b`:
`b' ≡ b (mod K)` and `b'` was written at some `c' ≤ c` with `b' ≤ c' + K ≤ c + K`; `b' > b` would give `b' ≥ b + K >
c + K`, so `b' < b`, hence `b' ≤ b − K ≤ c`: `b'` is expired.

**A live allocation's bucket is resident and unswept (PROVEN).** For a live allocation `now < expiry`, so `b > c ≥
swept` (sweeps never pass the current bucket), and by the previous result its slot still has tag `b`. So `exchange`'s
removal always applies, and RI gives `remaining ≤ amount_slot ≤ Q`, so nothing underflows.

**No bucket is subtracted twice (PROVEN).** A slot's amount leaves `Q` in exactly one of: a sweep visiting its tag
(then `swept ≥ tag`, so eviction and `_close` skip it), an eviction (the tag is replaced, so the sweep and `_close`
no longer match it), or the O(1) branch (then `swept = c ≥ maxBucket ≥ tag`). Partial removals (`exchange`, `_close`)
only touch a slot whose tag is unswept and current, and lower `amount` and `Q` together, so RI holds.

**Conservative when behind (PROVEN).** Each step only removes expired buckets, so `Q^live ≤ Q`. Each removal in
`exchange`/`_close` is also a removal from `Q^lazy`, and sweeps/evictions only remove, so `Q ≤ Q^lazy` (V-3).

**Who sweeps.** `reserveFor` (the sold asset), `redeem` and `processQueue` (both assets), 32 buckets per asset per
call, at the start of the call. `processQueue(0)` is therefore a permissionless sweep of both assets that changes
nothing else; no new entry point is added (DEFERRED-9). `exchange`, `deposit`, `claim`, `cancelRequest`, `release`
and `cancelAllocation` do not sweep. `exchange` reads one ring slot and writes it; no loop, no header read.

**Long inactivity.** If every written bucket has expired (`c ≥ maxBucket`) one sweeping call sets `Q = 0`. Otherwise a
sweeping call walks 32 buckets; a gap of `g` buckets needs `⌈g/32⌉` calls to recognize everything (or the O(1) branch
as soon as `c ≥ maxBucket`). Until then `Q` is too high, never too low: admission and LP exits are conservative.

### 3.5 Effect on each path

| Path | Before C02 | After C02 |
|---|---|---|
| `reserveFor` | `Q += q` | sweep sold asset; room rule; aligned expiry; ring add (`Q += q`, eviction may subtract an expired bucket) |
| `exchange` | `Q −= x` | ring remove, live (`Q −= x`); no sweep |
| `release`, `cancelAllocation` | `Q −= r` | ring remove, any: `Q −= r` if the bucket is still counted, else `Q` unchanged; `curatorReserved` and `hookReserved` always `−= r` |
| `redeem` | `F = N − Q` | sweep both assets first, then unchanged |
| `processQueue` | `F = N − Q` | sweep both assets first, then unchanged (also when `maxSteps = 0`) |
| `deposit`, `claim`, `cancelRequest`, admin setters | — | unchanged; no sweep |

Flow limits (`FLOW_WINDOW`, `RiskLimit.flowUsed`) are untouched: the ring changes when reserved capacity stops
counting; flow caps still cap gross output per day (REJECTED-11).

**Per-scope totals stay lazy.** `curatorReserved` and `hookReserved` keep the sum of `maxOut − consumed` over
unreleased allocations (`Q^lazy` per scope). After expiry they are conservatively high until the allocation is closed.
Effects: the curator's ceiling and the hook-scope exposure cap count expired capacity, so that curator or hook can
reserve less (never more) until cleanup. Recovery: anyone may `release` an expired allocation (unchanged, permissionless,
one per call), and the curator may `cancelAllocation`; each lowers both totals by the exact remainder and leaves `Q`
alone if the sweep already removed it. The vault-scope cap and admission read the swept `Q`.

### 3.6 Read interface (VaultStateReader and VaultLens)

New decoded reads (slot constants pinned by the layout test):
- `expiryRing(vault, a) → (swept, maxBucket)`; `expiryBucket(vault, a, index) → (bucket, amount)`.
- `liveReserved(vault, a)` = `Q^live` exactly: `Q` minus every slot with `swept < tag ≤ c`. It reads
  `min(c − swept, 720)` slots (it scans the 720 slots instead of the gap when the gap is longer), or none when
  `c ≤ swept` or `c ≥ maxBucket`. A view; nothing on-chain calls it.
- `sweptReserved(vault, a)` = the `Q` the next sweeping call would leave (same 32-step cap and O(1) branch).

Restated on `sweptReserved` so that they keep predicting the next transaction:
- `admissibleCapacity` = `min(max(0, N − Q' − R − D), max(0, room − Q'))` (second term only when `τ ≠ 0`), `Q'` swept.
- `freeInventory` = `N − Q'`; `deliverableShares` uses `F' = N − Q'` (what `redeem` and `processQueue` use).
`reserved(vault, a)` keeps returning the stored `Q`.

### 3.7 ABI

No new external function, event or error on the vault: the vault ABI (functions, events, errors) is unchanged, so the
governor's ABI pin (`GovernorIntegrity.test_delayClass_everyVaultFunction`) and the authorizer's interface need no
change. Misaligned expiries revert with `InvalidExpiry()` (its NatSpec is extended); room refusals with
`InsufficientBacking(requested, available)`. Sweeps emit no event: per-allocation state is fully derivable from
`AllocationCreated`/`Consumed`/`Released` plus the clock, and `Q` is read through the lens. TARGET: if bytes allow a
dedicated error or event, it is an owner decision, not added silently.

## 4. Storage layout

Existing slots 0–27 (C01 doc §4) do not move: checked by diffing `forge inspect … storageLayout` (AST ids stripped)
before and after; only new entries may appear.

New:

| Slot | Variable | Type |
|---|---|---|
| 28 | `_expiryRings` | `mapping(Currency ⇒ ExpiryRing)` |

Entry of asset `a`: base `h = keccak256(abi.encode(a, 28))`. Word `h`: `swept` (uint40, bits 0–39), `maxBucket`
(uint40, bits 40–79). Ring slot `i ∈ [0, 720)`: word `keccak256(abi.encode(i, h + 1))`: `bucket` (uint40, bits 0–39),
`amount` (uint128, bits 40–167). Widths: bucket numbers are `timestamp/3600 < 2⁴⁰` until about year 125 million;
`amount ≤ Q ≤ MAX_AMOUNT < 2¹²⁷` (a bucket written by `add` is current, so its amount is part of `Q`).

Required (B-G5-2):
- `VaultStorageLayout.t.sol`: literal slot 28, header offsets and bucket offsets, checked after real transitions with
  populated slots, after wrap-around (a slot reused for `b + 720`), and by fuzzed words through the decoders.
- `VaultGetterHarness`: by-name getters of the ring (`oldExpiryRing`, `oldExpiryBucket`) for parity.
- `VaultStateReader` and `VaultLens`: decoders (§3.6).

## 5. Tests

Named files are new unless stated. Fuzz tests run at the default profile during development and at ci before
completion.

### 5.1 Room-aware admission (`test/security/RoomAwareAdmission.t.sol`)

- CE-1 (G03, `ReservationDeliverability.t.sol`): the same 200,000 request with 50,000 of room is now refused with
  `InsufficientBacking(200_000e18, 50_000e18)`; the existing test is flipped and renamed, its CE-2 sibling stays.
- Exact boundary `q = room − Q` admitted, `q + 1` refused, with `Q > 0` from an earlier reservation.
- Pending LP withdrawals: `P > 0` raises `D` (first rule) and stays inside `S` (so `L`); both rules at their exact
  boundary with a queue.
- Both asset directions (sell asset0, sell asset1), with different targets.
- `τ = 0` in static mode: no room rule (admits up to the old rule). Adapter mode with `τ = 0` for the sold asset:
  admitted, every fill refused. `κ = 10⁶`: room = `N`.
- Curator ceiling, hook/curator/vault exposure caps still refuse when they bind before the room.
- Lens `admissibleCapacity` equals the largest admitted `q` (admitted at the value, refused at `+1`), fuzzed.
- No admission-time execution claim: after admission an LP exit shrinks the room (CE-2) and a fill of the full
  remainder is refused; the test documents it as the disclosed limit.

### 5.2 Ring unit and boundary tests (`test/security/ExpiryRing.t.sol`)

- Expiry: misaligned refused; `≤ now` refused; `now + 30 d` on a boundary accepted (bucket `c + 720`) at an aligned
  `now`; at an unaligned `now` the last aligned expiry before `now + 30 d` accepted and the next refused
  (`HorizonExceeded`).
- Fill at `expiry − 1` accepted; at `expiry` refused; `liveReserved` drops at `expiry` with no call; stored `Q` drops
  at the next sweeping call.
- Sweep gaps of 0, 1, 32, 33, 719, 720, 721 hours, each with a long-lived reservation keeping `maxBucket` ahead (walk
  path) and without (O(1) path); `now = maxBucket·δ` exactly; the first sweep after deployment.
- Slot reuse across horizons: buckets `b`, `b + 720`, `b + 1440`; eviction of an unswept bucket subtracts once; close
  before a sweep, after a sweep, after an eviction.
- Partial consumption then expiry: the sweep removes only the remainder; `release` afterwards changes `Q` by zero and
  the scope totals by the remainder.

### 5.3 Paths

- `exchange`: ring slot and `Q` fall by `amountOut`; header untouched; gas of `exchange` does not depend on the
  number of elapsed buckets (same swap after 0 and 700 quiet hours with live allocations; equal gas).
- `release`/`cancelAllocation` before and after the sweep, after an eviction; per-scope totals always exact.
- `redeem` and `processQueue` sweep both assets, including `processQueue(0)`; FIFO order unchanged.
- Several hooks (Hook A, Hook B, a test hook) competing for one asset with different expiries; one hook's fills never
  change another's remainder or bucket.

### 5.4 Storage layout and reader

As §4. Plus lens parity for `liveReserved`, `sweptReserved`, `admissibleCapacity`, `freeInventory`,
`deliverableShares` against values the vault produces (a `processQueue(0)` then `reserved`), and against the model.

### 5.5 Adversarial

- Concurrent LP withdrawals queued behind reservations: after expiry `processQueue` alone finalizes them, no release.
- Oracle outage (adapter reverting) with live reservations: fills refused, `Q` unchanged, the sweep still recognizes
  expiry (no LP or sweep path reads the adapter), exits proceed.
- Long inactivity (100 days) followed by a single `redeem`: `Q = 0`, instant exit of the whole free basket.
- Long inactivity while `maxBucket` stays ahead (one reservation renewed each 40 hours): `Q` stays between
  `Q^live` and `Q^lazy`; `processQueue(0)` calls converge.
- Griefing: many tiny reservations in distinct buckets; cost of a 32-bucket sweep is bounded and paid by the caller.

### 5.6 Differential test against the G05 model (`test/security/ExpiryRingDifferential.t.sol`)

Random schedules on the real vault (real PoolManager, real hooks, through the authorization module): reserve, fill,
release, cancel, `processQueue(0)`, redeem, warps up to twice the horizon. A `ExpiryRingModel(3600, 720, 32)` per asset
replays the same operations (`reserve`, `consume`, `close`, `readerSweep`). After every step: vault `Q` = model
`total`; lens `liveReserved` = model `liveTotal` = model `refLive`; `Q^live ≤ Q ≤ Q^lazy`.

### 5.7 Invariant campaign (`test/invariant/VaultInvariants.t.sol`, extended)

The handler mirrors every successful ring operation into one `ExpiryRing` model per asset, aligns its expiries, gains
an owner action that sets `τ`/`κ` (so the room rule is live) and a rare long warp (up to 35 days). Invariants:

| Id | Check |
|---|---|
| V-2 | `Q + W ≤ B` with the stored, swept `Q` (existing check kept) |
| V-3 | `Q^live ≤ Q ≤ Q^lazy`; `lens.liveReserved = Q^live` (brute force over allocations); vault `Q` = model total |
| V-4 | every live allocation's bucket is resident (slot tag = its bucket) and unswept; `curatorReserved`, `hookReserved` equal the lazy sums; each allocation closes once (existing) |
| V-5 | at each successful `reserveFor`: `Q ≤ N − R − D`, and `Q ≤ N − L` when `τ ≠ 0` (sticky flag) |
| V-6 | per-allocation ghost `consumed` from measured outputs equals the stored `consumed`; no other allocation's changes |
| V-7 | no successful fill at `now ≥ expiry` (sticky flag); a close of a swept bucket leaves `Q` unchanged (model) |
| V-8 | covered by §5.8 (stateful liveness) |
| V-9 | at each successful `reserveFor`: `F ≥ R + D` (sticky flag); LP paths independent of adapter (existing) |
| V-10 | a successful fill never lowers `deliverableShares` (sticky flag) |

Restated existing checks: `invariant_reservedIsExactAndBacked` (`Q = Σ unreleased` becomes V-3/V-4) and
`invariant_exposureAndHookReserved` (`Σ hookReserved = Q` becomes `= Q^lazy ≥ Q`).

Non-vacuity: new `COV` counters `expirySweeps` (a sweep that lowered `Q`), `expiredReleases` (release after expiry),
`releasesAfterSweep` (release that left `Q` unchanged), `roomRefusals`; existing `swapsOk`, `queuedOk`, `finalizedOk`.
Gates in `coverage.py` set by the G01 method over the default seed family, recorded in §10.

### 5.8 Liveness (G02 L-2 re-proved, V-8)

- `GovernanceLiveness.t.sol`: the admin batch executes a LONG_DELAY change after the commitment expires **without**
  any `release` (the old "lazy expiry still blocks" assertion flips).
- New: once admissions stop, `Q = 0` after at most `MAX_HORIZON` and one sweeping call when `c ≥ maxBucket`, and the
  whole queue is then deliverable with `processQueue` only; fuzzed over the reservation schedule.
- `GovernanceLivenessInvariants`: the handler's prescribed batch keeps its releases (they remain valid), and a second
  execution attempt without releases is added and counted.

## 6. Bytecode and gas

| Item | Threshold | Basis |
|---|---|---|
| Vault runtime, production profile | **≤ 22,528 B** (policy: ≥ 2,048 B under EIP-170; B-G5-1, V2-10) | gate |
| Vault runtime, C02 budget | **≤ 21,750 B** (TARGET) | ADR §8.1 prototype A + C over C01: 20,220 + 217 + 1,185 = 21,622 B (ESTIMATE). Above 21,750, C03's fee entry (+602) and the TVL cap (+175) no longer fit the policy; that is reported as a C03 risk, not a C02 failure |
| Lens runtime | ≤ 24,576 B | EIP-170 |
| Hooks, authorizer, governor, adapter runtime | byte-identical to `5ab3051` | not in scope |
| Gas, measured with `test/bench/run.sh` (`--isolate`, production artifacts) | reported, compared with C01's bench and ADR §8.2 estimates | brief §6 |

Bench rows added: reservation creation (fresh slot, same bucket, reused slot, after a capped 32-bucket sweep);
swap (Hook A, Hook B) unchanged scenarios; early release and release after sweep; `processQueue(0)` sweep (nothing
expired, one bucket, 32 buckets, O(1) branch); redeem and `processQueue(1)` with and without a pending sweep.

If the measured vault exceeds 22,528 B: stop before committing the ring, keep the room-aware admission commit, and
present the K = 1 fallback (V2-4, ADR §8.1 variant G: +337 B) and the other options with their measured sizes for the
owner. No design is switched silently and the policy is not relaxed.

## 7. Validation criteria

C02 is PASS only if all hold, each with its command and observed result in §10:
1. `forge fmt --check` clean; `forge build` succeeds; `forge lint` adds no new warning class.
2. Vault runtime within §6; hooks, authorizer, governor and adapter bytecode identical to `5ab3051`.
3. Storage layout: slots 0–27 identical; slot 28 as §4.
4. Vault ABI identical to `5ab3051` (functions, events, errors).
5. `forge test` (default profile): all pass; skipped only the fork tests without an RPC.
6. `test/bench/security.sh` (ci profile: size gate, production builds, production-artifact security, the complete suite
   at 10,000 fuzz runs and 128 × 128 invariants) exits 0.
7. Invariant coverage gate `python3 test/invariant/coverage.py` passes with the new counters gated.
8. Differential test and V-3 hold at ci; the CE-1 test now refuses; the CE-2 test still demonstrates the limit; the
   L-2 liveness tests pass without releases.
9. `test/bench/run.sh` gas recorded; compared with C01 and ADR §8.2.

Deeper runs: the ring-specific suites (`ExpiryRing*`, the differential test, the vault invariant campaign) once at the
deep profile if the ci results leave doubt. The full historical deep suite (`test/deep.sh`) is not run (brief §8).

## 8. Steps and commits

Local commits only, each with the full default suite green.

| Step | Work | Commit |
|---|---|---|
| 0 | Baseline at `5ab3051`: sizes, default suite, layout, ABI, bytecode hashes (scratchpad, not committed) | none |
| 1 | This plan | `docs: plan C02 commitment ledger` |
| 2 | Room-aware admission in the vault and the reader/lens; CE-1 flipped; §5.1 tests | `feat: admit reservations only within inventory room` |
| 3 | Ring, hour alignment, path updates, reader/lens/layout; test migrations to aligned expiries; restated invariants; §5.2–§5.5 tests | `feat: recognize reservation expiry through a bucketed ring` |
| 4 | Differential test, invariant handler extension, liveness, coverage gates, bench rows | `test: differential, invariant and liveness coverage for the expiry ring` |
| 5 | Results in §10 | `docs: record C02 measurements` |

If a step cannot meet its criteria it stops there, uncommitted or committed with the failure stated, and is reported.

## 9. Open items for the owner (not decided here)

1. Adapter mode with `τ_a = 0`: admission succeeds and fills are refused (ADR behaviour). A one-line admission
   refusal would make such a reservation impossible to create. Not implemented.
2. A dedicated `ExpiryNotAligned` error and a sweep event: not added (§3.7); bytes and ABI cost reported in §10.
3. DEFERRED-9 (permissionless `sweep`): `processQueue(0)` serves; revisit only if §10 shows a need.

Git: work only on `phase-3-c02-commitment-ledger`. No push, merge, rebase, PR, tag, remote change, deployment or
broadcast. The untracked `AGENTS.md` is not touched. No co-authorship lines. C03 does not start.

## 10. Results

### 10.1 Commits

| Step | Commit | Content |
|---|---|---|
| 1 | `03aa331` | this plan (§1–§9) |
| 2 | `d24fa24` | room-aware admission; reader/lens admission limit; CE-1 flipped; test migrations; `RoomAwareAdmission.t.sol` |
| 3 | `6a3ccda` | expiry ring, hour-aligned expiries, every path, reader/lens/layout; test migrations; `ExpiryRing.t.sol` |
| 4 | `cdba22a` | differential test, invariant extension (V-2 … V-10), L-2 re-proved, coverage gates, bench rows |
| 5 | this commit | results; one bench row (`test_bench_ring_redeemInstant_steady`); the differential's deep run count |

Baseline for every comparison: `5ab3051` (C01, in `main`).

### 10.2 Admission as implemented (§3.2)

`reserveFor` sweeps the sold asset, then admits `q` only if `q ≤ min(max(0, N − Q − R − D), max(0, N − L − Q))`, the
second term only when the asset has a target (`_admissible`). The refusal is the existing
`InsufficientBacking(q, available)` with `available` the smaller term. `L` is `VaultRiskBoundary.inventoryFloor(S, τ,
κ)`, the function fills use; `test_admissionAndFillUseTheSameFloor` admits exactly the room and fills it to the last
unit at a rounded `L`. Curator ceiling and exposure caps unchanged and still checked after it.

| Case | Behaviour | Evidence |
|---|---|---|
| CE-1 (G03) | refused: `InsufficientBacking(200,000e18, 50,000e18)`; exactly the room admitted and filled in full | `test_admissionRefusesBeyondInventoryRoom_CE1` |
| boundary `room − Q` / `+1` | admitted / refused, both assets, different targets | `test_exactBoundary_bothAssets` |
| queued withdrawals | `D` binds when the target is low, the room binds when it is high; queued shares stay in `S` for `L` | `test_pendingWithdrawals_bothRulesAtTheirBoundary` |
| `τ = 0`, `κ = 10⁶` | no room rule / room = `N` | `test_zeroTargetOrFullTolerance_noRoomRule` |
| adapter mode, `τ = 0` | admitted, every fill refused (`InventoryBoundsNotConfigured`); ADR behaviour, owner item §9.1 | `test_adapterMode_zeroTarget_admittedButNeverFillable` |
| ceiling / exposure tighter than room | they refuse first, unchanged | `test_ceilingAndExposureCapsStillBind` |
| random state (target, tolerance, buffer, prior reservations, queue, asset) | reader = lens = independent formula; that amount admitted, `+1` refused; V-5 and V-9 right after | `testFuzz_limitIsExactAndBothRulesHoldAfterAdmission` (1,000 runs default; 10,000 ci) |
| CE-2 (G03) | still demonstrated: an LP exit after admission makes part of a reservation unsellable | `test_lpExitShrinksInventoryRoomOfExistingReservation` (unchanged) |

What admission does not promise is written into the vault NatSpec (`reserveFor`, `_admissible`, contract header "Not
implemented here") and the interface (`InsufficientBacking`): sellable when admitted, nothing about later fills.

### 10.3 Expiry as implemented (§3.3–§3.5)

As planned, with one change (DV-1: `uint64` fields). Storage: slot 28, `_expiryRings`. Expiries must be multiples
of 3,600 (`InvalidExpiry()`). `reserveFor` sweeps the sold asset, `redeem` and `processQueue` sweep both, 32 buckets
per asset or O(1) once `c ≥ maxBucket`; `exchange` reads one ring slot and writes it (no header read, no loop);
`_close` removes only while the bucket is counted. `processQueue(0)` is the permissionless sweep. The vault ABI
(functions, events, errors) is identical to `5ab3051`.

Per-scope totals: `curatorReserved` and `hookReserved` keep expired capacity until the close. Recovery is `release`
(anyone, after expiry) or `cancelAllocation` (curator). Observed effect in the suite: `Reentrancy.t.sol` commits "all
admissible asset1" after an expired, unreleased allocation; the hook's exposure cap (100%) refused the full amount by
exactly that allocation's 1,000, because the hook's total still counted it while `Q_1` no longer did. The test now caps
at the exposure headroom, and one test releases the expired allocation first (the documented recovery).

### 10.4 Storage-layout compatibility

| Check | Result |
|---|---|
| `storageLayout` of `5ab3051` vs ``cdba22a`` (labels, slots, offsets, types; AST ids ignored) | slots 0–27: identical (30 entries); added: `_expiryRings` at slot 28 |
| packing (compiler) | `ExpiryRing`: `swept` uint64 offset 0, `maxBucket` uint64 offset 8, `buckets` at struct slot 1; `ExpiryBucket`: `bucket` uint64 offset 0, `amount` uint128 offset 8 |
| `VaultStorageLayout.t.sol` | literal slot 28 and bit offsets checked on raw words after real transitions: populated slots, header with `maxBucket` at the horizon's far end, a slot reused 720 buckets later (`test_layout_expiryRing_populatedAndWrapped`); fuzzed words through lens vs by-name getters (`testFuzz_layout_ringWordsDecodeLikeGetters`); reader constants = vault (`test_layout_readerRingConstants`) |
| `VaultGetterHarness` | `oldExpiryRing`, `oldExpiryBucket`, `sweptAdmissibleCapacity`, `sweptReservedNow` (the last two sweep for real inside a snapshot) |
| `VaultLensParity` | lens `admissibleCapacity` and `sweptReserved` equal the vault's own sweep followed by its formula, on every generated state; ring header and a slot near the current bucket equal the by-name getters |

New reads (`VaultStateReader` and `VaultLens`): `expiryRing`, `expiryBucket`, `liveReserved` (exact; at most 720 slot
reads), `sweptReserved` (the Q the next sweeping call computes). `admissibleCapacity`, `freeInventory`,
`deliverableShares` and the vault-scope `exposureAvailable` now use `sweptReserved`; `reserved` stays the stored value.

### 10.5 Differential test against the G05 model

`test/security/ExpiryRingDifferential.t.sol`: 80-step random schedules on the real vault mirrored into two
`ExpiryRingModel(3600, 720, 32)` instances (the G05 library, unchanged). After every step: stored `Q` = model total,
lens `liveReserved` = model view = naive live sum, `Q^live ≤ Q ≤ Q^lazy`, ring header = model header.

| Run | Result |
|---|---|
| default profile, 256 runs (ordinary and eviction-heavy schedules) | pass |
| ci profile, 1,000 runs | pass (inside `security.sh`) |
| deep profile, 10,000 runs | pass |
| `test_schedulesReachEveryOperation` (24 fixed seeds, half eviction-heavy) | reserves 555, fills 174–190, cancellations 48–62, releases after expiry 64–78, `processQueue(0)` 103, instant redemptions 90, evictions 24 |

The first version of the generator reached only 1–2 evictions in 24 seeds (sweeps too frequent, and 60-day jumps end
every bucket so the next sweep takes the O(1) branch); the eviction-heavy mode (no permissionless sweeps, warps of up to
4 days, two reservations in three reuse an earlier slot) was added for that reason.

### 10.6 Financial invariants and non-vacuity

`VaultInvariants.t.sol` handler: a ghost ring (G05 library) fed every successful reservation, fill, close,
redemption and queue call; new actions `setInventoryTarget` (owner; targets ≤ 80% of holding, tolerance ≥ 10%, or
cleared) and `longWarp` (3–35 days); expiries aligned.

| Id | Check in the campaign | Where |
|---|---|---|
| V-2 | `Q + W ≤ B` (stored, swept `Q`) | `invariant_reservedIsExactAndBacked` |
| V-3 | `Q^live ≤ Q ≤ Q^lazy`; `liveReserved = Q^live`; stored `Q` and ring header = ghost ring | `invariant_reservedIsExactAndBacked`, `invariant_ringMatchesGhostModel` |
| V-4 | live buckets resident and unswept; per-curator and per-hook totals = lazy sums; Σ hookReserved ≥ `Q`; closes checked against "still counted" | `invariant_liveBucketsResident`, `invariant_exposureAndHookReserved`, `_recordClose` |
| V-5, V-9 | right after each successful admission: `Q ≤ N − R − D`, `Q ≤ N − L` with a target, `F ≥ R + D` | `_checkAdmissionBounds` → `invariant_commitmentLedgerRules` |
| V-6 | `consumed` rises by exactly the measured output of its own fills; ghost per allocation | `_afterFill`, `invariant_commitmentLedgerRules` |
| V-7 | no fill at `now ≥ expiry`; a close of a swept or evicted bucket leaves `Q` unchanged | `_afterFill`, `_recordClose` |
| V-8 | §10.7 | |
| V-10 | a fill never lowers `deliverableShares` | `_afterFill` |

Non-vacuity: `test_handler_commitmentLedgerProgress` reaches an expiry sweep, a release after expiry whose capacity a
sweep had removed, a target change, a room refusal, a 35-day quiet period. Coverage gate (`coverage.py`, 64 seeds,
depth 128):

| Campaign / counter | zero-run fraction, seed base 13 | range over bases 13, 101, 4001, 65537 | gate |
|---|---|---|---|
| vault `expirySweeps` | 0.14 | 0.14–0.25 | 0.50 (new) |
| vault `expiredReleases` | 0.23 | 0.23–0.31 | 0.55 (new) |
| vault `releasesAfterSweep` | 0.28 | 0.28–0.44 | 0.70 (new) |
| vault `targetChangesOk` | 0.11 | 0.05–0.12 | 0.30 (new) |
| vault `roomRefusals` | 0.86 | 0.83–0.88 | 0.98 (new; rare per run, gated like G02's `longBlocked`) |
| liveness `restrictedWithoutRelease` | 0.69 | 0.69–0.84 | 0.98 (new) |
| vault `queuedOk` (existing gate) | 0.33 | 0.31–0.42 | 0.50 (unchanged; G01 observed 0.17–0.25) |
| vault `finalizedOk`, `claimsOk` (existing) | 0.58, 0.55 | 0.58–0.69, 0.45–0.62 | 0.80, 0.85 (unchanged) |
| vault `swapsOk` (existing) | 0.16 | 0.09–0.22 | 0.40 (unchanged) |

`python3 test/invariant/coverage.py` (all four campaigns, 64 seeds, depth 128, base 13): every gate passed (2 min 9 s).
The bases 101, 4001 and 65537 were run for the vault and liveness campaigns with the final handler: every gate passed.

The vault campaign queues less than before C02: with targets set, a commitment cannot take free inventory below the
floor, so `queueBehindCommitment` often pays the LP instantly (finding F-1 in the campaign). The new
`setInventoryTarget` action therefore sets targets one call in three and clears them otherwise, which brought
`queuedOk` from 0.38–0.42 (targets set two calls in three) to 0.31–0.41. The existing gate (0.50) still passes on every
family and deterministically on the default seeds, but the margin is now about 1.5 standard deviations instead of the
four the G01 method asks for. Left unchanged; owner item (§10.13).

### 10.7 Expiry and withdrawal liveness

| Property | Evidence |
|---|---|
| G02 L-2 re-proved: commitments stopped by the guardian ⇒ a LONG_DELAY change queued then executes at eta through a batch with **no release** | `testFuzz_L2_executesWithoutReleaseOnceCommitmentsStop` (1,000 runs; up to six commitments of random size and horizon) |
| the same in the stateful campaign: half the batches and half the warps release nothing; `restrictedWithoutRelease` counts required executions done without a release | `GovernanceLivenessInvariants` (L2 never violated); counter in §10.6 |
| "one share holds the change": after expiry the batch executes without release (was: `PendingWithdrawals` until a release) | `test_oneShare_holdsLongChange_whileFullyCommitted` (flipped) |
| a griefer can no longer queue behind an expired commitment: its redemption sweeps and is paid at once | `test_restrictingNewCommitments_endsBlockingWithinMaxHorizon` (restated) |
| lever deadline: `queuedAt + 9 days` remains safe; the tight one is up to an hour later because expiries round down to the hour | `test_leverDeadline_isQueueTimePlusNineDays` (restated with the exact boundary) |
| queued LPs finalized by `processQueue` alone after expiry, FIFO; at `expiry − 1` nothing is finalized | `test_queuedWithdrawals_finalizeAfterExpiryWithoutRelease`, `test_R1_reserveConditionDoesNotGrantFullExit` |
| 100 idle days, one `redeem`: `Q = 0`, whole balance instant | `test_longInactivity_singleRedeemExitsEverything` |
| oracle outage: fills refused, `Q` kept while live, recognized at expiry, queue finalized, adapter still broken | `test_oracleOutage_expiryAndExitsUnaffected` |
| renewed reservations keep the ring behind: `Q` within bounds at every step, `⌈backlog/32⌉` calls catch up | `test_renewedReservations_sweepFallsBehind_butStaysBoundedAndConverges` |

Sweep-gap and boundary cases (`ExpiryRing.t.sol`): gaps of 0, 1, 32, 33, 719, 720, 721 hours with and without a
far bucket (stored `Q` after one call equals the exact expected value, then converges); `now = maxBucket·δ` and one
second before; the first sweep after deployment (no walk from bucket 0); fills at `expiry − 1` and at `expiry`;
`now + 30 days` at an aligned clock in bucket `c + 720`; three horizons of slot reuse with exact eviction amounts;
close before / after sweep / after eviction; partial consumption then expiry; three hooks on one asset.

### 10.8 Bytecode and gas

**Sizes** (MEASURED, `forge build --sizes`, production profile):

| Contract | `5ab3051` | C02 | Δ | Under EIP-170 |
|---|---|---|---|---|
| `SharedCommitmentVault` | 20,220 | **21,449** | +1,229 | **3,127** (policy ≥ 2,048: pass) |
| `VaultLens` | 12,530 | 14,344 | +1,814 | 10,232 |
| Hooks, authorizer, governor, adapter | — | identical bytecode | 0 | — |

Breakdown: room-aware admission +214 B (prototype A: +217); ring +990 B with `uint40` fields, +25 B for `uint64`
(prototype C: +1,185, which included an on-vault `liveReserved` view; here that view is in the lens). Total +1,229 B
against the ADR estimate of +1,402 B for A + C. Inside the C02 budget (≤ 21,750 B). Remaining before the size policy:
1,079 B. C03's fee entry (+602 B, prototype F) and the C-1 TVL cap (+175 B, prototype T) total 777 B in the prototype,
which leaves about 300 B; the real C03 code (events, errors) may differ.

**Gas** (MEASURED, `test/bench/run.sh`, production artifacts, `--isolate`; C01 baseline measured the same way on a
`git archive` of `5ab3051`):

Selected rows (the full table, 78 rows, is reproducible with `test/bench/run.sh` and the same command on a `git archive
5ab3051`). Every row not listed changed by 0 to +56 gas (failed swaps +44/+56; `initialDeposit` +2).

| Operation | C01 | C02 | Δ |
|---|---|---|---|
| swap Hook A (router + PM + hook + vault) | 269,697 | 275,410 | +5,713 (+2.1%) |
| swap Hook B | 251,829 | 257,542 | +5,713 (+2.3%) |
| ten split swaps, Hook A | 2,479,895 | 2,537,025 | +57,130 (+5,713 each) |
| allocate, first in vault (ring header and slot written for the first time) | 332,783 | 380,876 | +48,093 |
| allocate, steady state, new curator | 294,096 | 304,521 | +10,425 |
| activate signed (EOA), steady state | 314,349 | 324,762 | +10,413 |
| ring: reserve into a bucket already in use | — | 270,521 | (baseline of the ring rows) |
| ring: reserve into a slot never written | — | 287,563 | +17,042 vs same bucket |
| ring: reserve into a slot reused after wrap-around | — | 273,443 | +2,922 vs same bucket |
| ring: reserve after a quiet period (its sweep walks 32 populated buckets) | — | 352,390 | +81,869 vs same bucket |
| release (owner, before expiry) | 47,618 | 53,878 | +6,260 |
| release (revoked curator, stranger) | 43,888 | 50,148 | +6,260 |
| cancelAllocation (after partial consumption) | 44,121 | 50,381 | +6,260 |
| ring: release after its bucket was swept | — | 44,652 | (no ring write) |
| redeem instant, fresh vault (first write of both ring headers) | 160,601 | 206,160 | +45,559 |
| redeem instant, steady state (same scenario on both builds) | 156,113 | 160,728 | +4,615 |
| redeem queued, fresh vault | 147,624 | 173,269 | +25,645 |
| processQueue(1) (headers already written) | 121,919 | 126,515 | +4,596 |
| ring: processQueue(0), nothing ended | — | 32,429 | |
| ring: processQueue(0), one bucket ended | — | 48,669 | |
| ring: processQueue(0), 32 populated buckets ended (cap) | — | 124,434 | ≈ 2,875 per walked bucket |
| ring: processQueue(0), everything ended (O(1)) | — | 41,186 | |
| ring: redeem instant whose sweep recognizes every expiry (O(1)) | — | 184,561 | |
| deposit, claim, quotes, governor, setRiskLimit, lifecycle setters | | | 0 |
| deploy vault (CREATE) | 4,547,503 | 4,813,201 | +265,698 |

**Against the ADR §8.2 estimates.** Measured against ADR §8.2: `exchange` +5,713 (estimate +5,600; one cold ring-slot read and write, no header);
`reserveFor` +10,425 steady (estimate about +8,000), +17,042 more for a slot never used (estimate +28,000 including
the base slot write), up to +81,869 when its sweep walks the 32-bucket cap (estimate +80,000); `redeem` and
`processQueue` +4,596 to +4,615 when nothing has ended (estimate +4,200), a walked bucket about 2,875 gas (harness
estimate 2,415), a full 32-bucket walk about +92,000 per asset over the nothing-ended case (estimate up to +80,000).
New relative to the estimates: the first write of each asset's ring header (about 22,000 gas, once per asset, paid by
whichever sweeping call comes first) and +6,260 on every `release`/`cancelAllocation` (header read for `swept` plus
the slot). No swap path loops or reads a header: `test_exchangeGas_independentOfElapsedBuckets` shows the same fill
costs within 15 gas with the ring 0 or 700 buckets behind.

### 10.9 Deviations from the plan

| # | Plan | Done instead | Why |
|---|---|---|---|
| DV-1 | ring fields `uint40` (§4) | `uint64` for `bucket`, `swept`, `maxBucket` (offsets 0/64) | `FlowLimits.test_FL_nearUint64Timestamps_failClosed` runs near the end of 64-bit time, where the current bucket exceeds 2⁴⁰: a `uint40` cast would truncate. With `uint64` every expiry bucket fits by type; +25 B |
| DV-2 | authorizer source untouched | NatSpec only in `CuratorAuthorization.sol` and `ICuratorAuthorization.sol` (expiry on an hour boundary) | curators sign the expiry; the rule belongs where they read it. Runtime bytecode identical (checked) |
| DV-3 | — | `exposureAvailable` (vault scope) reads `sweptReserved` | `reserveFor` checks the vault-scope cap after its sweep |
| DV-4 | test migrations listed generally (§2.5–2.6) | G02 fixtures (`GovernanceLiveness`, its campaign) put no target on asset0; `VaultGovernor` and `GovernorIntegrity` redeem lp0's whole balance | with a 5% tolerance on the committed asset, room-aware admission caps a commitment at 5% of `N_0`, so "commit everything, one share queues" is impossible right after admission; asset0 unfloored keeps the worst case G02 measures (finding F-1) |
| DV-5 | — | fill-floor tests reach "reserved above the room" by lifting the targets for the admission (`_suspendInventoryFloor`; in governor-owned handlers by calling as the governor) | room-aware admission no longer creates that state directly; it remains reachable through a guardian tightening or LP exits (CE-2), and the fill-time check is what those tests exercise |
| DV-6 | — | `PricingAdversarial.t.sol`: allocations hoisted out of two loops | via-IR stack limit after `_request` gained the alignment |
| DV-7 | — | `AdmissibleCapacity._write` also marks the ring swept to the current bucket | a `Q` written with `vm.store` and an empty ring is not a reachable state (the next sweep would zero it) |
| DV-8 | — | `Rehearse.s.sol`: two allocations of 0.25% of backing (were 2%), hour-aligned | room at the default 1% tolerance |
| DV-9 | — | two new handler actions in `VaultInvariants` (`setInventoryTarget`, `longWarp`); the G02 campaign releases half the time | the room rule and long gaps must be live in the campaign; L-2 must hold without releases |

### 10.10 Findings

- **F-1 (G02 threat model).** With an inventory target on the committed asset, one admission can withhold at most the
  room `N − L`, so right after it `F ≥ L` and a single queued share is paid at once. The G02 "one share holds a
  LONG_DELAY change" case now needs that asset without a target, or LP exits that drain free inventory after the
  admission (CE-2). G02's measurements stay valid as the unfloored worst case.
- **F-2 (lever deadline).** `queuedAt + 9 days` remains a safe lever deadline. With hour-aligned expiries the tight
  deadline is the last second before a full-horizon commitment can reach the first hour boundary after
  `eta + GRACE` (at most an hour after `queuedAt + 9 days`).
- **F-3 (stale scope totals).** An expired, unreleased allocation keeps counting in its curator's ceiling and its
  hook's exposure cap; the lens's `admissibleCapacity` does not include those, so "reserve everything admissible" can
  be refused by the hook cap. Recovery: anyone `release`s the expired allocation. Documented in the vault NatSpec.
- **F-4 (catch-up rate).** A vault where reservations keep `maxBucket` ahead and nobody calls a sweeping function for
  more than 32 hours keeps expired capacity in `Q` until `⌈backlog/32⌉` sweeping calls; conservative, and anyone can
  call `processQueue(0)`. Measured: 32 populated buckets cost about 124k gas in one `processQueue(0)`.

### 10.11 Validation

| Criterion (§7) | Command | Result |
|---|---|---|
| 1 | `forge fmt --check`; `forge build`; `forge lint` | clean; builds; warning counts identical to C01 (17 block-timestamp, 2 incorrect-shift, 20 unsafe-typecast; the new casts carry justified `forge-lint: disable` lines) |
| 2 | `forge build --sizes`; `test/bench/run.sh` size rows | vault 21,449 B runtime, 22,093 B init, margin 3,127 B (policy ≥ 2,048: pass; C02 budget ≤ 21,750: pass). Hooks, authorizer, governor, adapter: deployed-bytecode sha256 identical to `5ab3051` |
| 3 | `storageLayout` diff (§10.4) | slots 0–27 identical; slot 28 added |
| 4 | ABI diff of the vault (`forge inspect … abi`) | identical to `5ab3051` (functions, events, errors) |
| 5 | `forge test` (default profile) at `cdba22a`, and with the results commit | **731 passed, 0 failed, 8 skipped** (fork tests without an RPC); C01 ended at 695 (+36 new tests). With this commit's bench row: **732 passed, 0 failed, 8 skipped** |
| 6 | `test/bench/security.sh` (`FOUNDRY_PROFILE=ci`) at `cdba22a` (only this document uncommitted) | exit 0: size gate ok; `ProductionBuilds.t.sol` 3/3; `ProductionArtifactSecurity.t.sol` 25/25; complete suite **731 passed, 0 failed, 8 skipped** at 10,000 fuzz runs (the differential test 1,000 runs) and 128 × 128 invariants (`invariant_ringMatchesGhostModel`, `invariant_liveBucketsResident`, `invariant_commitmentLedgerRules`: 128 runs, 16,384 calls, 0 reverts). Wall time 10 min 18 s |
| 7 | `python3 test/invariant/coverage.py` | every gate passed (§10.6) |
| 8 | §10.5, §10.2, §10.7 | differential pass (default 256, ci 1,000 runs); CE-1 refused; CE-2 still shown; L-2 without releases |
| 9 | `test/bench/run.sh` | exit 0; §10.8 |
| deep (ring only) | `FOUNDRY_PROFILE=deep forge test` on `ExpiryRingDifferential`, `ExpiryRing`, `RoomAwareAdmission` | all pass: `ExpiryRing` 15/15, `RoomAwareAdmission` 8/8 (fuzz 10,000 runs), `ExpiryRingDifferential` 2/2. The differential's inline config named only `default` and `ci`, so the deep profile ran it at 256 runs; a `deep.fuzz.runs = 10000` entry was added in the results commit and the test re-run: **10,000 runs × 80 steps pass** (2 min 55 s) | |

### 10.12 Residual risks and what was not run

- **Not an execution guarantee.** Admission proves sellability at admission only; CE-2, guardian tightening, oracle
  outages, pauses, halts, freezes and flow caps can all make reserved capacity unsellable later. C03's bond terms
  must charge for withheld capacity, not for execution (ADR §5.1).
- **Stale scope totals (F-3).** Curator ceilings and hook exposure caps count expired, unreleased capacity until a
  `release`; harmless for safety, but it can refuse a curator's or hook's new reservations. Anyone can clean up.
- **Catch-up rate (F-4).** With reservations renewed so that `maxBucket` stays ahead and no sweeping call for more than
  32 hours, `Q` overstates commitments until enough calls run; conservative for LPs, costly for admission.
- **Bytes for C03.** 1,079 B remain before the size policy; the C03 prototype items (fee entry + TVL cap) measured
  777 B in G05. A real escrow entry with events and errors may not fit; the K = 1 fallback is not needed for C02.
- **Coverage margin.** `queuedOk` is 1.5 σ from its gate (§10.6).
- **Layout as interface.** Third-party readers of `reserved` now read the stored, possibly unswept `Q`; `liveReserved`
  and `sweptReserved` are the meaningful reads. Documented in the lens NatSpec.
- Hand proofs only (§3.4); nothing formally verified; no independent review.

Not run: the full historical deep suite `test/deep.sh` (brief §8), mutation testing, Slither, fork tests (no RPC), any
broadcast. The deep profile was run only on the three ring/admission suites.

### 10.13 Next action requiring owner approval

Review of C02 (`03aa331` … this commit). Decisions for the owner: §9.1 (refuse admission in adapter mode when the sold
asset has no target), §9.2 (dedicated `ExpiryNotAligned` error and a sweep event, both cost bytes and an ABI change),
§9.3 (a separate `sweep` entry: not needed, `processQueue(0)` serves), whether to recalibrate the `queuedOk` gate, and
the C03 byte budget. C03 does not start before that review.
