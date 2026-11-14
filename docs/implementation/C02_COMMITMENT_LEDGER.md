# C02: Time-bound commitment ledger (room-aware admission and the expiry ring)

**Status: plan, committed before any production change.** §1–§9 are the plan and stay as written. Results, measured
numbers and every deviation from the plan go in §10.

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

(Filled in at step 5.)
