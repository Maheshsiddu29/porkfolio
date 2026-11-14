# C03: Bond escrow and reservation economics

**Status: plan, committed before any production change.** §1–§11 are the plan and stay as written. Results, measured
numbers and every deviation from the plan are added later in §12 and after.

Basis:
- `docs/architecture/G05_V2_ARCHITECTURE.md` (the ADR) is the specification: §2.3 (escrow ↔ vault interface), §3.6
  (effect of each operation), §5 (bonds and fee accounting), §7 (authority and governance), §8 (bytes), §10 (decisions
  D-1 … D-6, V2-5 … V2-10), §11 (the C03 row) and §12 (invariants V-1, V-9, V-11 … V-16, V-18 … V-20, boundary cases).
- `docs/implementation/C02_COMMITMENT_LEDGER.md`: the vault this milestone starts from (`3502d9b`, in `main`), its
  findings F-1 … F-8 and its residual risks (F-8 must be analysed here).
- The owner's C03 instruction for this milestone.
- Reference models: `test/model/BondLedgerModel.sol` (aggregate accrual, lazy sync, attribution) and
  `test/model/ReservationBondModel.sol` (per-reservation charge). They are test-only references for the differential
  tests; they are not copied into `src/`.

Labels as in the ADR: **MEASURED** (a command in this document produced it), **ESTIMATE**, **TARGET** (acceptance
threshold set here), **PROVEN** (hand proof; nothing is machine-checked), **ASSUMPTION**, **DECISION** (a choice made
here inside G05's design that the owner should confirm; listed in §11).

## 1. Objective

Charge for reserving shared capital and pay the charge to LPs, while every C02 guarantee holds:

1. A separate `BondEscrow` holds prepaid bonds as PoolManager ERC-6909 claims, accrues a charge on the unused remainder
   of each reservation over time, settles, refunds the unearned part by pull, credits a protocol share, and realizes the
   LP part into the vault through one escrow-only entry.
2. A bonded authorization path: the curator's signed intent also binds the payer and a maximum rate; activation creates
   the vault commitment and the funded bond in one transaction, or nothing.
3. The vault gains exactly two things: `realizeFee` (escrow only) and a realization checkpoint at the start of
   `deposit`. Swaps, exits, queue processing, claims, release and cancellation do not call the escrow.
4. Governance of the escrow's parameters through the existing `VaultGovernor` delays.

What C03 does **not** claim: that a bond insures execution (ADR §3.2 G-R4 is still refused; the bond pays for capacity
withheld, ADR §5.1), exact attribution of fees to historical LP holders (ADR §5.4: exits forfeit unrealized fees), or
that bonds solve F-8 (§8 measures it; the answer is stated only if the experiments support it).

## 2. Scope

In scope:
1. `src/SharedCommitmentVault.sol`: `feeEscrow` storage, `setFeeEscrow` (owner; install check), `realizeFee`
   (escrow only), `deposit` realizes first. NatSpec in the same commit.
2. `src/interfaces/ISharedCommitmentVault.sol`: `realizeFee`, the new error and events.
3. New `src/BondEscrow.sol` and `src/interfaces/IBondEscrow.sol`.
4. New `src/CommitmentAuthorizer.sol`: the bonded authorization module. `src/CuratorAuthorization.sol` is refactored
   so that the bonded module reuses its checks unchanged (the checks move into internal functions; the unbonded
   module's external behaviour, ABI and EIP-712 type stay the same).
5. `src/governance/VaultGovernor.sol`: target check extended to the escrow (ADR §7.2).
6. `src/libraries/VaultStateReader.sol`, `src/VaultLens.sol`: the `feeEscrow` slot.
7. Tests (§7), analyses (§8), gas rows (§9), this document.

Out of scope (ADR §11 assigns them elsewhere, or the brief excludes them): Hook C and its integration test (C04), the
C-1 TVL cap as production code (ADR §11: C04 "if approved"; C03 only measures and evaluates it, §8.5), interface
documentation for hooks and payers beyond NatSpec (C04), deployment scripts and gates (C05), the deep campaign and
mutation of all new code (C05), payer-initiated or partial early release (DEFERRED-2), utilization-based pricing
(REJECTED-6, DEFERRED-3), retired escrows realizing (DEFERRED-6), idle yield (V2-3).

## 3. Bytecode preflight (MEASURED, before any production change)

Method: scratch copy of `src/` at `3502d9b` in the session scratchpad (not the repository), production profile (vault at
200 runs, via-IR, `bytecode_hash = none`), `forge build --sizes src/SharedCommitmentVault.sol`. The prototype is the
complete vault-facing change of §4.2, with its custom error and events (NatSpec does not change bytecode):

| Variant | Runtime B | Under EIP-170 | Δ vs C02 | Before the 2,048 B policy (≤ 22,528) |
|---|---|---|---|---|
| C02 (`3502d9b`) | 21,477 | 3,099 | 0 | 1,051 |
| F: `feeEscrow` slot, `setFeeEscrow` (owner), `realizeFee`, `deposit` → `realize()`, `NotFeeEscrow`, `FeeEscrowSet`, `FeeRealized` | 22,034 | 2,542 | +557 | 494 |
| F + install check in `setFeeEscrow` (`vault()` must answer this vault; `InvalidFeeEscrow`) | **22,103** | **2,473** | **+626** | **425** |
| F + C-1 TVL cap (G05 prototype T: per-asset backing cap in `deposit`) | 22,209 | 2,367 | +732 | 319 |
| F + install check + T (not built; sum of the measured deltas) | ≈ 22,278 | ≈ 2,298 | ≈ +801 | ≈ 250 (ESTIMATE) |

Conclusion: the complete C03 vault change fits the policy with the install check (TARGET: final vault ≤ 22,528 B,
expected about 22,103 B). The TVL cap, if the owner later approves it for C04, still fits (≈ 250 B left). No fallback
(V2-4) is needed. If the final build differs from the prototype by more than the remaining margin, work stops before the
vault commit and the alternatives are reported (§10).

## 4. Design

### 4.1 Contracts and money flow

```
payer ──activateBonded(intent, key, sig)──► CommitmentAuthorizer (vault.authModule)
                                              1. CuratorAuthorization checks (EIP-712 / EIP-1271, nonce, generation, window)
                                              2. vault.reserveFor(req, curator, generation) ──► allocation j
                                              3. escrow.post(j, payer, maxRate)
                                                     │ ERC-20 pulled from payer → PoolManager → claims minted to escrow
                                                     ▼
                                           BondEscrow  (claims of asset a: open bonds + earned + refunds owed + protocol owed)
   anyone: sync(j)  ── reads vault allocation j (consumed, released) through extsload
   anyone: settle(j) ── final charge, refund credited, vault.release(j) if expired and unreleased
   payer:  claimRefund(to)  ── claims burned, ERC-20 to `to`
   protocol recipient: claimProtocol(to)
   anyone / vault.deposit: realize() ── escrow approves exactly lpΔ claims ──► vault.realizeFee(a, lpΔ): B_a += lpΔ, pulls lpΔ
```

Only one value path enters the vault from the escrow (`realizeFee`), and only `deposit` calls the escrow. The escrow
never holds or moves LP claims; the vault never holds bonds.

### 4.2 Vault changes

Storage: `address internal _feeEscrow` appended at slot 29 (slots 0–28 unchanged; pinned by the layout test).

| Function | Caller | Effect | Failure |
|---|---|---|---|
| `setFeeEscrow(address escrow)` | owner (`_authorize(false)`: guardian refused) | installs, replaces or unsets (zero) the escrow; a non-zero address must answer `vault()` with this vault (one `staticcall`, same pattern as `setAuthModule`) | `NotOwner`, `GuardianCannotIncreaseRisk`, `InvalidFeeEscrow` |
| `realizeFee(Currency a, uint256 x)` | only `_feeEscrow` (zero matches nobody) | `B_a += x`; pulls exactly `x` claims of `a` from the escrow (`poolManager.transferFrom`, needs the escrow's allowance of `x`); mints no shares; no lock (it runs inside `deposit`'s lock); works while paused | `NotFeeEscrow`, `InvalidCurrency`, `AmountTooLarge` (`x > MAX_AMOUNT − B_a`), PoolManager allowance/balance revert |
| `deposit` | unchanged | if `_feeEscrow != 0`, calls `IBondEscrow(_feeEscrow).realize()` before pricing; a revert reverts the deposit (fail closed, D-2) | as before, plus any escrow revert |

`initialDeposit` does not realize: before initialization no allocation, hence no bond, can exist. `redeem`,
`processQueue`, `claim`, `cancelRequest`, `exchange`, `release`, `cancelAllocation` and every setter are unchanged and
make no escrow call (V-9).

Why lock-free `realizeFee` is safe (PROVEN by case): it only adds `x` to `B_a` and moves exactly `x` claims in the same
call, so `PM.balanceOf(vault) − B_a` is unchanged whatever the interleaving. The only foreign code that can run inside a
vault entry point is an ERC-20 transfer (contract NatSpec "Reentrancy"); every such window has already written its own
`B_a` change, and `realizeFee` reads `B_a` fresh. `deposit` calls `realize()` before it reads `N_a`. A token calling
`realize()` from inside a payout window only moves earned fees into `N_a` early, to the shares that remain (§4.3.5).

### 4.3 `BondEscrow`

#### 4.3.1 Roles

| Role | Can | Cannot |
|---|---|---|
| `vault.authModule()` | `post` (one bond per allocation, in the allocation's creation transaction) | anything else |
| `vault.owner()` (the governor, DELAY) | `setRate`, `setMinChargeDuration`, `setProtocolFee` (≤ immutable `MAX_PROTOCOL_BPS` = 2,000), `setProtocolRecipient` | move bonds, refunds, LP fees or protocol fees; change a posted bond's terms |
| payer | `claimRefund(to)` of its own refunds | claim anyone else's |
| protocol recipient | `claimProtocol(to)` | claim more than credited |
| anyone | `sync(j)`, `settle(j)` (when closed or expired), `realize()`, `realize(maxSteps)` | change charges or ownership of funds |
| guardian | nothing on the escrow (ADR §7.2); its vault levers are unchanged | — |

No rescue, sweep, arbitrary transfer, operator grant (except an exact-amount ERC-6909 allowance to the vault for one
`realizeFee`, consumed in the same call) or upgrade. The escrow's `owner()` view returns `vault.owner()` (live).

#### 4.3.2 Storage

Per bond, keyed by the vault's allocation id: payer, asset index, created, expiry, `last` (accrual time), the
minimum-charge duration in force at creation, `closed`, `settled`, `A` (amount), `synced` (consumption seen), `r`
(remainder accrued on), `ρ` (rate, fixed), `Y` (bond), `accrued` (Σ r·ρ·dt, unscaled rho-seconds), `charge`.

Per asset (`Ledger`): `rate` (Σ r_j·ρ_j over open bonds before expiry), `accrued` (Σ accrued_j over unsettled bonds at
`last`), `last`, `maxBucket`, `settledCharges`, `realized`, `protocolOwed`, `refundsOwed`, `openBonds`, and a ring of
720 rate-drop slots (`bucket` tag, `amount`), bucket width 1 hour, as ADR §5.4. Per payer and asset: refund owed.
Parameters: `rate[2]` (ρ for new bonds), `minChargeDuration`, `protocolFeeBps`, `protocolRecipient`.

#### 4.3.3 Entry points

| Function | Checks | Effects |
|---|---|---|
| `post(id, payer, maxRate)` | caller is `vault.authModule()`; the vault's `feeEscrow` is this escrow; `id` is the vault's latest allocation, unconsumed, unreleased, unexpired; not yet bonded; `ρ = rate[a] ≤ maxRate` | aggregate advanced to now; bond stored with `ρ`, `T_min` and `Y = ⌈A·(t₁ − now)·ρ / 1e18⌉ ≤ MAX_AMOUNT`; `rate += A·ρ` and drop of bucket `t₁/1h` `+= A·ρ`; `openBonds += Y`; `Y` pulled from the payer (ERC-20 → PoolManager → claims minted to the escrow; arrival checked exactly); nothing pulled when `Y = 0` |
| `sync(id)` | bond exists, not settled | aggregate advanced; bond accrued to `min(now, t₁)`; new consumption `x` read from the vault: `r −= x`; if the vault has released the allocation: `closed`, `r = 0`; while `now < t₁` the rate and the bucket drop fall by the removed remainder × `ρ` |
| `settle(id)` | not settled; after an internal sync, `closed` or `now ≥ t₁` | `charge = ⌈max(accrued, A·min(T_min, t₁ − t_c)·ρ) / 1e18⌉`; `refund = Y − charge` credited to the payer; `accrued` leaves the aggregate, `charge` enters `settledCharges`, `Y` leaves `openBonds`; terminal; then `vault.release(id)` if the allocation is still unreleased (only possible after expiry; permissionless there) |
| `realize()` | — | advances both assets at most 32 buckets each; reverts `EscrowBehind` if either is not at now; realizes both |
| `realize(maxSteps)` | — | advances at most `maxSteps` buckets per asset and realizes what is earned up to where it got; returns whether both reached now |
| `claimRefund(to)` | `to ≠ 0`; something owed | zeroes the caller's refunds of both assets, pays ERC-20 to `to` |
| `claimProtocol(to)` | caller is the protocol recipient; `to ≠ 0`; something owed | pays both assets' `protocolOwed` to `to` |
| setters | caller is `vault.owner()`; bounds | `setProtocolFee` realizes first, so the old share applies to everything earned before the change |

Every state-changing entry point takes a transient-storage reentrancy lock. `post`, `claimRefund`, `claimProtocol`
use the PoolManager's `unlock` (an `unlockCallback` that only the PoolManager may call, with the same exact-arrival check
as the vault).

#### 4.3.4 Accrual (ADR §5.3–§5.4)

Notation per bond `j`: `A`, `t_c`, `t₁`, `ρ` (fee units per reserved unit per second × 1e18), `r(t)` the remainder as
the escrow knows it.

    I_j       = Σ r·ρ·dt over [t_c, min(t, t₁, observed close))        exact integer rho-seconds
    Y_j       = ⌈A·(t₁ − t_c)·ρ / 1e18⌉                                 prepaid
    I_min     = A·min(T_min_j, t₁ − t_c)·ρ                              T_min_j fixed at creation
    charge_j  = ⌈max(I_j, I_min) / 1e18⌉ ≤ Y_j                          PROVEN: r ≤ A and accrual stops at t₁
    refund_j  = Y_j − charge_j

Aggregate per asset: `Agg(t) = Σ_unsettled I_j(t)`, advanced from `last` to `t` bucket end by bucket end, applying each
bucket's rate drop at its end; every expiry is a bucket end, so the aggregate and each bond stop accruing at the same
second (V-15). Walk bound (PROVEN): `post` leaves the aggregate at `now`, every written bucket is at most 720 buckets
after the post, and once the walk passes `maxBucket` (or `rate` reaches 0) every remaining drop is zero and the walk jumps
to `t` in O(1). So a walk visits at most 720 buckets; `realize()` (the deposit path) caps it at 32 (`EscrowBehind`);
`sync`, `settle` and `post` walk to now. Ring slot reuse is safe by the vault ring's proof (C02 §3.4): a slot is rewritten
only by `post` with the aggregate at now, so its old tag is a bucket whose drop was already applied, or a zero drop the
walk skipped.

Realization per asset:

    target    = settledCharges + ⌊accrued / 1e18⌋                       never decreases (ADR §5.4)
    protocolΔ = ⌊target·π / 10⁴⌋ − ⌊realized·π / 10⁴⌋
    lpΔ       = target − realized − protocolΔ                            → vault.realizeFee(a, lpΔ) when > 0
    realized  = target;  protocolOwed += protocolΔ

Rounding (ADR §5.7): bond up, charge up (against the payer), aggregate down (remainder realized later), protocol down on
cumulative totals, refund exact.

#### 4.3.5 Escrow identity (V-11, V-19)

Per asset, after every call:

    claimsHeld = openBonds + settledCharges − realized + refundsOwed + protocolOwed ≤ PM.balanceOf(escrow, a)
    realized − settledCharges ≤ ⌊accrued / 1e18⌋ ≤ openBonds
    after every bond settles and everything is realized and claimed:  Σ Y = LP fees + protocol fees + refunds

Claims sent to the escrow directly are never counted (the inequality, not an equality).

#### 4.3.6 Bounds

`A ≤ MAX_AMOUNT = 2¹²⁷ − 1` (vault), `t₁ − t_c ≤ 30 days < 2²²`, `ρ ≤ MAX_RATE = 1e18` (ADR §5.7's proposal), so `A·ρ <
2¹⁸⁷`, `A·T·ρ < 2²⁰⁹`. A bucket drop is stored in 192 bits with a checked cast: `post` reverts once the summed rate of
one bucket would exceed 2¹⁹² (at least 32 maximum-size, maximum-rate bonds in the same hour). `Y ≤ MAX_AMOUNT` is
checked (the PoolManager's int128 limit). Every product is checked arithmetic or `FullMath.mulDiv`; overflow reverts.
`T_min ≤ 30 days`; `π ≤ 2,000` bps.

### 4.4 `CommitmentAuthorizer`

Inherits `CuratorAuthorization` (same vault, EIP-712 domain name "Porkfolio Vault" version "1" with its own address,
same nonce bitmaps, generation binding, validity window, pool/hook/direction checks, EOA and EIP-1271 signatures).
Adds an immutable `escrow` (its `vault()` must be the module's vault), and:

    struct BondedAuthorization { AllocationAuthorization allocation; address payer; uint256 maxRate; }
    activateBonded(BondedAuthorization auth, PoolKey key, bytes signature)   // msg.sender == auth.payer
    activateDirectBonded(AllocationRequest req, uint256 maxRate)             // curator is caller and payer

The curator signs the nested EIP-712 struct `BondedAuthorization(AllocationAuthorization allocation,address payer,
uint256 maxRate)` (the existing `AllocationAuthorization` type is referenced, not changed). The unbonded entry points
`activate` and `activateDirect` revert with `BondRequired` in this module, so every reservation it creates is bonded
(V2-5). Each bonded activation calls `vault.reserveFor` then `escrow.post`; any revert undoes the reservation, the bond,
the nonce bit and every intermediate state (one transaction).

`CuratorAuthorization` itself keeps its ABI, events, errors and EIP-712 type; only its two external functions become
`virtual` and their bodies move into internal functions the subclass calls. Its runtime bytecode changes (stated in
§12); its behaviour does not (its test suite runs unchanged).

### 4.5 Governance

- Vault `setFeeEscrow`: owner only, DELAY through the governor (the governor's default class). Guardian: refused
  (ADR §7.2). Unsetting is also owner, DELAY (the ADR's recovery for a broken escrow).
- Escrow setters: only `vault.owner()`. The governor's target check accepts, besides the vault and its hooks, a target
  whose `owner()` is the governor and whose `vault()` is the vault (the escrow); DELAY class. The guardian can cancel
  queued escrow changes (unchanged governor rule) but has no escrow power.
- `MAX_PROTOCOL_BPS = 2,000` is a constant; `MAX_RATE` and the `T_min` bound are constants.
- Escrow replacement follows ADR §7.5 / V2-7: an escrow replaced while bonds are open keeps syncing, settling and
  refunding, but its `realizeFee` calls revert, so the LP part of its remaining fees is stranded (CE-G5-7). Tested, not
  changed.

### 4.6 Read interface

`VaultStateReader.FEE_ESCROW_SLOT = 29` and `feeEscrow(vault)`; `VaultLens.feeEscrow`. The escrow reads the vault's
allocation records (slot 12), `nextAllocationId` (slot 13) and `feeEscrow` (slot 29) through `extsload` with the same
library, plus the `authModule()` and `owner()` getters. The layout test pins slot 29.

## 5. Decisions made inside the ADR (owner to confirm, §11)

| # | Point the ADR leaves open | Chosen | Why |
|---|---|---|---|
| DC-1 | Authorizer: new contract or edit in place | new `CommitmentAuthorizer` inheriting `CuratorAuthorization` | ADR §2.1 names `CommitmentAuthorizer`; reuses the reviewed checks instead of duplicating them; the unbonded module stays available to existing tests and is not the production module |
| DC-2 | `T_min` changes and existing bonds | fixed per bond at creation | a governance change must not alter an accepted charge (as for `ρ`, V-16) |
| DC-3 | Walk cap outside the deposit path | `sync`, `settle`, `post` walk to now (≤ 720 buckets, PROVEN); `realize()` caps at 32 | refunds and settlement never wait for someone else's catch-up |
| DC-4 | Escrow governance target | governor accepts `owner() == governor && vault() == vault` | works before installation and for a retired escrow; no vault getter needed |
| DC-5 | `setFeeEscrow` validation | `vault()` must answer this vault | fail closed on wrong address, EOA, wrong vault (+69 B, §3) |
| DC-6 | `post` freshness | allocation must be the vault's latest id, unconsumed, unreleased, unexpired, unbonded | only the creation transaction can bond it |
| DC-7 | `settle` and the vault | calls `vault.release` for an expired, unreleased allocation (ADR §5.3) | cleans per-scope totals (C02 F-3) |
| DC-8 | Refund and protocol claims | both assets in one call, to a caller-chosen non-zero recipient | ADR §5.3 / R-17 |
| DC-9 | Bonds when the escrow is not the vault's `feeEscrow` | `post` refuses | a bond in an escrow that cannot realize would strand LP fees from the start |
| DC-10 | C-1 TVL cap | measured and evaluated only (§8.5) | ADR §11 places it in C04, conditional on owner approval |

## 6. Invariant mapping (ADR §12.1)

| Id | Statement | Evidence planned |
|---|---|---|
| V-1 | `PM.balanceOf(vault, a) = B_a + X_a`, `X_a ≥ 0`, including `realizeFee` | bond campaign: invariant on the real vault with the escrow realizing |
| V-9 | exits, queue, cancel, claim call no escrow or authorizer and work with a reverting escrow | unit tests with a reverting/broken escrow installed; existing independence invariant kept |
| V-11 | escrow identity §4.3.5, per asset | campaign invariant (real escrow + vault + hooks); differential |
| V-12 | `charge ≤ Y`, `refund = Y − charge`, settle once, charge formula on the synced remainder | differential vs `BondLedgerModel`; unit tests (duplicate settle, `T_min` > duration, rate 0, `A = MAX_AMOUNT` region) |
| V-13 | no escrow claim in `B_a`; admission reads no escrow state; a bond larger than `N_a` adds no capacity | unit test on the real contracts |
| V-14 | fees enter `N_a` only through `realizeFee`, no shares minted; JIT deposit gains ≤ 1 raw unit; an exit before realization forfeits its pro-rata part of `U_a` | unit tests with exact amounts; campaign ghost check that every `B_a` increase not from deposit/fill input equals a `FeeRealized` |
| V-15 | `Agg = Σ_unsettled I_j` exactly; realization frequency changes no total; `target` never decreases | differential (two escrows on the same schedule, different realization frequency); campaign invariant |
| V-16 | a bond's `ρ` and `T_min` never change; `ρ ≤ maxRate` | unit tests (rate change after post; `maxRate` below rate refused) |
| V-18 | no V2 contract holds or calls an ERC-4626 | by construction; noted |
| V-19 | rounding directions; `Σ Y = LP + protocol + refunds` after settlement | differential end-of-schedule identity; campaign end check |
| V-20 | role matrix: `realizeFee` only from `feeEscrow`; `post` only from `authModule()`; escrow setters only from the vault owner; guardian has no escrow power and cannot `setFeeEscrow`; no role moves bonds or LP funds | `Roles`-style matrix test on escrow and vault; governor tests |

## 7. Test plan

New files (names indicative):
1. `test/unit/BondEscrow.t.sol`: posting (rate 0, positive, `maxRate` bound, bond rounding, `Y` bound), freshness
   (stale id, consumed, released, already bonded, wrong caller, escrow not installed), sync (partial fills, late sync,
   cancel observed, after expiry), settle (expiry boundary `t₁ − 1` / `t₁`, `T_min` longer than the duration, one-bucket
   bond, duplicate settle, settle calls `release`), refunds (recipient zero refused, recipient refusing the token, claim
   twice), protocol fee bounds (0 and 2,000), setters (only vault owner, bounds), extreme values (`A` near 2¹²⁷ with the
   rate cap, mixed decimals 6/18), reentrancy (token re-entering `post`, `claimRefund`, `deposit` from inside an escrow
   payout).
2. `test/security/BondedActivation.t.sol`: EOA and EIP-1271 bonded activation; malicious wallet (revert, wrong magic,
   gas burn); payer binding (relayer refused); `maxRate` below the rate; nonce replay; generation bump; unbonded entry
   points refused; atomic rollback on every failure (allowance short, escrow not installed, admission refused, rate
   above max): no allocation, no bond, no nonce bit, no token movement.
3. `test/security/FeeRealization.t.sol`: `realizeFee` callers (owner, guardian, old escrow, anyone) refused; deposit
   realizes first (JIT ≤ 1 unit); exit before realization forfeits exactly; failed realization (escrow behind, escrow
   reverting) reverts deposits while exits, queue, claims, swaps and admissions work; `realizeFee` at `MAX_AMOUNT − B`;
   escrow replacement with open bonds; install check; multiple hooks and curators sharing an asset; same-block
   activation and cancellation.
4. `test/security/BondEscrowDifferential.t.sol`: random schedules on the real vault, hooks, authorizer and escrow
   (activate, fill through Hook A/B, sync now or late, cancel, emergency release, settle, realize, deposit, redeem,
   claim, warps) mirrored into `BondLedgerModel`; after every step: per-bond accrued, charge, refund, aggregate,
   realized, LP and protocol totals equal the model's; end-of-schedule conservation.
5. `test/invariant/BondEscrowInvariants.t.sol`: a handler over the real contracts; invariants V-1, V-11, V-12, V-13,
   V-14, V-15, V-19 with non-vacuity counters gated in `coverage.py` (bonds posted, fills synced late, settlements,
   realizations, refunds claimed, deposits that realized).
6. Governance: governor accepts the escrow and refuses look-alikes; escrow changes wait DELAY; guardian cancel; ABI pin
   test updated for `setFeeEscrow` and `realizeFee` (DELAY class).
7. `test/unit/VaultStorageLayout.t.sol`: slot 29.
8. Production builds: `ProductionArtifacts` gains the escrow and authorizer artifacts; `ProductionBuilds.t.sol` and
   `security.sh` size-gate them.

## 8. Economic and adversarial analysis plan

All on the real contracts (production builds, real PoolManager), with the numbers produced by tests that log them.

1. **F-8 (fresh-capital queue blocking).** C02's construction (`GovernanceLivenessConfigured`) repeated with bonded
   reservations at ρ = 0, a low rate (1e9: about 3.15%/year), a high rate (1e12: about 3,150%/year); reservation
   horizons of 1 hour, 1 day and 9 days; repeated rotations; partial fills; early cancellation; guardian intervention.
   Measured per rotation: transient capital, bond posted, charge, the share of the charge that returns to the
   coalition through its own LP shares, protocol share, refund, gas, and the queue delay imposed on honest LPs.
   Reported: capital locked versus economic loss. A bound is claimed only if the measurements give one under stated
   assumptions.
2. **Fee attribution.** Fees forfeited by LPs who exit before realization, as a function of `U_a`, exit size and time
   since the last realization (exact amounts).
3. **Late synchronization.** Payer over-charge `x·ρ·Δt` for fills synced late, measured against the immediately synced
   charge.
4. **Unexecutable commitments.** Reservations made unfillable by LP exits (CE-2), an oracle outage, a guardian
   tightening, a direction halt, a curator freeze: who pays (the payer, until an observed close or expiry), who receives
   (LPs, protocol), and that sync, settlement and refunds stay available in each case.
5. **C-1 TVL cap.** Size (§3), what it bounds (deposited capital, hence the fresh capital an F-8 rotation can bring
   through `deposit`), what it does not (commitments, fills, fee inflows; capital already inside; a coalition below the
   cap), deployment implications (cap per asset, DELAY to raise, guardian lowers). Not implemented in C03.

## 9. Gas plan

`test/bench/run.sh` rows (production artifacts, `--isolate`), compared with the same command on a `git archive` of
`3502d9b`: bonded activation (direct, signed EOA, signed EIP-1271), first and repeated bond posting (new and used ring
slot), sync (fill seen, close seen), settle (expiry, early close), refund claim, protocol claim, realize (nothing earned,
earned, 32-bucket walk), deposit with an escrow installed (nothing earned, fees earned), redeem, swap Hook A and Hook B
(expected unchanged: `exchange` gains no call). Sizes of the vault, escrow and authorizer.

## 10. Validation criteria and commits

C03 is PASS only if all hold, each with its command and observed result in §12:
1. `forge fmt --check` clean; `forge build`; `forge lint src` adds no new warning class without a justified disable.
2. Vault runtime ≤ 22,528 B (production profile); escrow and authorizer within EIP-170.
3. Storage layout: vault slots 0–28 identical, slot 29 added.
4. `forge test` (default profile): all pass; skipped only the fork tests without an RPC.
5. `test/bench/security.sh` exits 0 with the escrow and authorizer in the size gate.
6. `python3 test/invariant/coverage.py` passes with the new counters gated.
7. Differential and campaign invariants hold at the ci profile.
8. Gas table recorded against `3502d9b`; `exchange` gas unchanged.

Commits (local only, each with the default suite green):

| Step | Content | Commit |
|---|---|---|
| 1 | this plan | `docs: plan C03 bond escrow` |
| 2 | vault fee entry, reader/lens/layout, governor target, their tests | `feat: escrow-only fee realization in the vault` |
| 3 | `BondEscrow`, `CommitmentAuthorizer`, `CuratorAuthorization` refactor, unit and security tests | `feat: bond escrow and bonded authorization` |
| 4 | differential, invariant campaign, economics, gas rows, coverage gates | `test: bond conservation, differential and economics` |
| 5 | results | `docs: record C03 measurements` |

If a step cannot meet its criteria it stops there and is reported; nothing is relaxed silently.

## 11. Open items for the owner

1. DC-1 … DC-10 (§5).
2. Production must install `CommitmentAuthorizer`, not the unbonded `CuratorAuthorization`; the vault cannot enforce
   which module is bonded (it would need vault bytes). Recorded for the C05 deployment checklist.
3. C-1 TVL cap for C04: approve or reject after §8.5.

Git: work only on `phase-3-c03-bond-escrow`. No push, merge, rebase, PR, tag, remote change, deployment or broadcast.
The untracked `AGENTS.md` is not touched. No co-authorship lines. C04 does not start.
