# Porkfolio — Modular Risk Engine: Architecture, Trust Boundaries and Measurements

**Status: ARCHITECTURE (Phase 1B-2A). The owner approved option B (D17) and `optimizer_runs = 2,000` for the vault
(D19). Implemented so far: step 1B-2.0 only, the vault's optimizer profile and `VaultLens` (§8.3,
`PHASE1B2_STEP1_REPORT.md`). Everything else here is still a proposal.** Labels: SOURCE (read from the code at
`4b5e514`), OBSERVED (measured in this milestone; method in §9), ESTIMATE (derived, not measured; how to measure it is
stated), PROPOSAL, DECISION (needs the owner's approval).

Companion documents:

- `CURATOR_SECURITY_MODEL.md`: signatures, nonces, generations, freeze and revocation;
- `CUMULATIVE_PRICING_SPEC.md`: path-independent hook pricing;
- `MAINNET_READINESS.md`: release checklist;
- `PHASE1B2_IMPLEMENTATION_PLAN.md`: commit sequence.

## 1. Recommendation

**Two deployed contracts plus libraries and an off-path lens.**

| Component | Deployed? | Owns state | On the swap path? | On the LP exit path? |
|---|---|---|---|---|
| `SharedCommitmentVault` | yes | custody, shares, queue, floors, **all commitment accounting**, curator status and generation, flow limits | yes | yes |
| `CuratorAuthorization` | yes | EIP-712 domain, nonce bitmaps | **no** | **no** |
| Pricing libraries | no (internal libraries compiled into hooks) | none (hooks hold their own pricing state) | yes, inside hooks | no |
| `VaultLens` | yes (optional) | none | no | no |
| `CommitmentEngine` as a separate contract | **not recommended** (§6) | — | — | — |

The "commitment engine" is a set of responsibilities, not a contract. It stays inside the vault because its state
(`Q_a`, allocations, flow counters) is read on both the swap path and the LP exit path. Splitting it out would put an
external call on both paths or duplicate the accounting (§6). The measurements in §8 show that the vault fits under
EIP-170 without that split, once the optimizer setting is lowered and views move to a lens. Those are the first two
size levers in D12.

The authorization module is the one split that pays for itself:

- it keeps signature parsing and every call to curator-controlled code (ERC-1271 wallets) out of the vault;
- it can be replaced, which kills all of its outstanding signatures, without migrating LP funds;
- it keeps about 2.1 kB of bytecode out of the vault.

Its costs are measured: about +8,100 gas per activation and about +0.9–1.2M gas to deploy. It never touches swaps or
withdrawals.

## 2. Implementation this design started from (SOURCE, `4b5e514`)

After step 1B-2.0 the vault is 17,035 B at `optimizer_runs = 2,000` and eight views live in `VaultLens` (§8.3).
The list below is the starting point.

- One contract, 22,814 B runtime (EIP-170 margin 1,762 B), `optimizer_runs = 44,444,444`.
- It holds custody (ERC-6909 claims on the PoolManager), shares, the FIFO queue, the floors, allocations, `Q_a`,
  curator ceilings, `nonceUsed`, and the owner and guardian roles.
- External calls go only to the PoolManager and the two pair ERC-20s (via PoolManager `settle`).
- Hooks call `exchange`. The vault grants no operator rights over its claims.
- Not present: signatures, curator freeze or revocation, curator cancel, flow limits, and cumulative pricing.

## 3. State ownership (PROPOSAL)

| State | Owner | Written by | Read by |
|---|---|---|---|
| ERC-6909 claims (custody) | PoolManager, on behalf of the vault | vault only (`exchange`, `_settleIn`, `_payOut`) | vault |
| `B_a`, `W_a`, shares, `P`, queue | vault | vault LP paths, `exchange` | vault, lens |
| Allocations, `Q_a`, `curatorReserved`, ceilings, `R_a` | vault | `reserveFor` (from the module), `exchange`, `cancelAllocation`, `release`, owner/guardian setters | vault, hooks (`getAllocation`), lens |
| Curator record: `status` (None / Active / Frozen / Revoked) and `generation` | vault, one storage slot per curator | owner/guardian setters, curator `bumpGeneration` | vault (`reserveFor`, `exchange`), module (none needed), lens |
| Flow buckets (vault, per curator, per hook) | vault | `exchange`; caps by owner (raise) or guardian (lower) | vault, hooks (optional pricing input), lens |
| Floors, halts, pause | vault | owner/guardian | vault |
| `authModule` address | vault | owner (set); guardian (set to zero only) | vault |
| EIP-712 domain, nonce bitmaps | `CuratorAuthorization` | module, during activation and `invalidateNonces` | module, lens |
| Hook pricing state `x` | each hook | the hook, in `beforeSwap` | the hook |

**Rule:** every quantity an invariant depends on lives in the contract that enforces that invariant. The only
cross-contract dependency is the module asserting authority, and the vault re-checks everything else (§4.4).

## 4. Trust boundaries

### 4.1 Who may do what to a commitment

| Action | Entry point | Caller | Vault checks |
|---|---|---|---|
| Create (activate) | `vault.reserveFor(req, curator, generation, signed)` | **only** `authModule` (after it verified a signature, or `msg.sender == curator` on the direct path) | curator `status == Active`; `generation` matches if signed; consumer registered and equal to `key.hooks`; pair; direction open and not halted; `f_c ≥ f_v`; `0 < maxOut ≤ MAX_AMOUNT`; expiry window; curator ceiling; admission `Q + q + R + D ≤ N`; exposure cap (§7, L5) |
| Consume | `vault.exchange` | the allocation's registered consumer (hook) | as today, plus curator `status ∉ {Frozen, Revoked}`, plus the three flow buckets |
| Cancel | `vault.cancelAllocation(id)` | the allocation's curator, **in any status** | not already closed |
| Release | `vault.release(id)` | anyone after expiry; anyone if the curator is Revoked; owner/guardian at any time (emergency) | not already closed |

All four close paths share one internal `_close(id, reason)`. It reverts if the allocation is already closed and sets
`released` before subtracting `remaining` (`PHASE1B_CURATOR_AUTH.md` §8).

### 4.2 Who can authorize a reserve transfer

Only `vault.exchange` moves vault claims out. It does so only to the hook that calls it, only after pulling the input
claims, only against a live allocation of a non-frozen, non-revoked curator, within quota, within all flow buckets and
at or above `max(f_v, f_c)`. **No module is ever involved in a transfer.**

- The vault never calls `setOperator` or `approve` on the PoolManager (SOURCE; it stays a test assertion).
- The authorization module holds no claims and has no operator rights.
- The lens has no write functions.

### 4.3 Which functions call untrusted code

| Caller | Callee | Trust | Notes |
|---|---|---|---|
| vault | PoolManager | canonical v4 (assumption 1 in `CA` §12) | `unlock`, `sync`, `settle`, `mint`, `burn`, `take`, `transfer`, `transferFrom` |
| vault | pair ERC-20s | chosen at deployment; standard tokens only | `transferFrom` in `_settleIn`; fee-on-transfer fails closed (SOURCE) |
| module | curator wallet (ERC-1271) | **untrusted** | `staticcall` inside OZ `SignatureChecker`; cannot change state; gas and return-data costs fall on the submitter |
| module | vault | trusted (fixed at module construction, immutable) | `reserveFor` is the module's last action |
| hook | vault | registered hooks only (vault checks) | `exchange`, `getAllocation` |
| vault | module | **never** | the vault has no reason to call the module |

### 4.4 How the vault verifies the module's decision

The module asserts exactly one fact: **"`curator` authorized `req` under `generation`."** The vault does not trust the
module for anything else. Every risk check in §4.1 runs inside the vault on the vault's own state. A compromised or
buggy module is therefore equivalent to **every registered, active curator being compromised at once**:

- It can create allocations up to each active curator's ceiling, for registered hooks only, at floors no lower than
  `f_v`, within admission.
- It cannot consume, move assets, change floors, unfreeze, un-revoke, or touch LP state.
- Loss requires a registered hook that prices badly and is bounded by `PHASE1B_THREATS_AND_PLAN.md` T-01 summed over
  curators, and further by the vault-wide flow bucket (§7).

**Response:**

1. The guardian calls `setAuthModule(address(0))`. All activation stops in the same block.
2. The guardian emergency-releases allocations created after the suspected compromise, identified from events.
3. The owner deploys a new module. The old module's signatures can never be used with the new one, because the
   EIP-712 domain's `verifyingContract` is different.

### 4.5 Reentrancy across modules

There are no call cycles:

- module → vault (`reserveFor`), and never vault → module;
- the module's only other external call is the ERC-1271 `staticcall`, which cannot write state;
- the module consumes the nonce **before** calling the vault, and the vault call is its last action, so a revert in the
  vault reverts the nonce too.

Inside the vault (PROPOSAL): add a transient-storage lock (EIP-1153, available because `evm_version = cancun`) to every
external state-changing function except `unlockCallback`, which only runs inside the vault's own `unlock`. This is
defence in depth:

- Nested `deposit`/`redeem` inside a swap already fail with `AlreadyUnlocked` (SOURCE, `test_withdraw_cannotNestInsideUnlock`).
- The lock also covers paths that do not unlock: `reserveFor`, `cancelAllocation`, `release`, `processQueue` and the
  setters, in case a non-standard pair token calls back during `transferFrom`.

Cost (ESTIMATE): two `TSTORE` and one `TLOAD` at 100 gas each, plus dispatch, under 500 gas per call. Measure in
1B-2.1 with `--isolate`.

### 4.6 What a module failure does

| Failure | Swaps | LP exits | Activation |
|---|---|---|---|
| Auth module reverts, is disabled, or is buggy | unaffected (not on the path) | unaffected | stops (fails closed) |
| Lens reverts or is wrong | unaffected | unaffected | unaffected (the UI may show wrong data; no on-chain contract may depend on the lens) |
| A hook's pricing library is wrong | only that hook's swaps; bounded by floor, quota and buckets | unaffected | unaffected |

### 4.7 Configuring and changing module addresses

- `setAuthModule(address m)`: the owner may set any value; the guardian may set only `address(0)` (risk-reducing,
  via `_authorize(m == address(0))`).
- The module's `vault` is immutable. One module serves one vault.
- **Active commitments when the module changes:** unaffected. They are vault state, validated by the vault at creation,
  and remain consumable, cancellable and releasable exactly as before.
- **Outstanding signatures:** they die with the old module (the domain binds `verifyingContract`). Nonce bitmaps do not
  migrate. They do not need to: no message signed for the old domain verifies under the new one.
- Before real value, module changes go through the multisig and timelock path (`MAINNET_READINESS.md` G-1, G-2).

## 5. Call sequences

```mermaid
sequenceDiagram
    participant R as Relayer (anyone)
    participant A as CuratorAuthorization
    participant W as Curator wallet (EOA or ERC-1271)
    participant V as Vault
    R->>A: activate(req, curator, generation, validAfter, sig)
    A->>A: window checks; digest = EIP-712(req, vault, generation)
    A-->>W: staticcall isValidSignature (only if ECDSA fails)
    A->>A: consume nonce bit (reverts if used)
    A->>V: reserveFor(req, curator, generation, signed = true)
    V->>V: status Active; generation equal; all risk checks; Q += maxOut
    V-->>A: allocationId
```

```mermaid
sequenceDiagram
    participant T as Trader router
    participant PM as PoolManager
    participant H as Hook
    participant V as Vault
    T->>PM: swap (inside unlock)
    PM->>H: beforeSwap
    H->>H: quote from its own cumulative state x
    H->>PM: mint input claims to hook
    H->>V: exchange(key, dir, id, in, out)
    V->>V: allocation live; curator not Frozen/Revoked; quota; floor; 3 buckets
    V->>PM: transferFrom(hook→vault, in); transfer(vault→hook, out)
    H->>PM: burn output claims; return delta
```

The freeze, revoke, cancel and LP-redeem sequences are single-contract calls into the vault. They are specified in
`CURATOR_SECURITY_MODEL.md` §4.

## 6. Option comparison

| Criterion | A: single vault (inline EIP-712) | **B: vault + authorization module (recommended)** | C: vault + authorization + commitment engine |
|---|---|---|---|
| Vault runtime at runs 44.4M / 20,000 / 2,000 / 200 (OBSERVED, prototype) | 28,797 / 24,401 / 22,847 / 20,427 | 26,293 / 21,965 / 20,481 / 18,293 | vault ≤ 18,262 at 44.4M, ≤ 12,732 at 200 (OBSERVED upper bound; engine not prototyped) |
| … with views moved to a lens | 27,318 / 23,300 / 21,764 / 19,248 | 24,807 / 20,857 / 19,391 / 17,110 | — |
| Extra deployed contract | none | module 3,776–5,008 B | module + engine (ESTIMATE: engine ≈ 8–10 kB, from the size removed from the vault) |
| Deployment gas, runs 200 (OBSERVED) | 4,641,466 | 4,160,637 + 920,184 = 5,080,821 | ESTIMATE ≥ B + 2M |
| Signed activation, EOA / ERC-1271 (OBSERVED, runs 200) | 274,951 / 282,449 | 283,071 / 290,560 | ≥ B (ESTIMATE: one more hop) |
| Direct activation (OBSERVED, runs 200) | 262,867 | 270,158 | ≥ B |
| Swap, HookA end to end (OBSERVED, runs 200) | 240,515 | 240,371 | ESTIMATE B + 4,000 to 7,000 (one cold external call with a 6-word payload; the measured struct-sized hop in B is ≈ 7,300) |
| Extra external calls on the swap path | 0 | 0 | 1 (vault → engine) |
| Extra external calls on the LP exit path | 0 | 0 | 0 only if the vault mirrors `Q_a`; otherwise 1 per redemption. Either way two contracts must agree on `Q_a`. |
| Reentrancy exposure | 1271 `staticcall` inside the vault | 1271 `staticcall` isolated in the module; no cycles | engine ↔ vault calls on the swap path; cycles possible unless strictly one-way |
| Storage ownership | single owner | single owner per invariant (§3) | `Q_a` split or mirrored across contracts |
| Audit scope | one large contract, including signature code | vault (no signature code) + a small module | three contracts and a cross-contract accounting protocol |
| Emergency | pause, halt, freeze in one place | same, plus disabling the module stops all activation | same, plus engine failure **halts all swaps** |
| Replaceable signature logic | no (LP migration needed) | yes | yes |

**Why not C.**

- The commitment state is read on every swap (`Q_a`, allocation, buckets) and every redemption (`Q_a` through
  `_deliverableShares`).
- Moving it out either adds an external call to both paths, or keeps a mirror of `Q_a` in the vault, which means two
  sources of truth for the most important invariant (`Q_a + W_a ≤ B_a`).
- B already fits under EIP-170 without it: the B vault with views moved to the lens leaves 3,719 B (runs 20,000) to
  7,466 B (runs 200) of margin. Size does not force the split.
- D12 says a split needs a security reason, and C has none.

**Why B over A.**

- A is simpler and about 8,100 gas cheaper per activation, and either is acceptable on gas.
- B was chosen because:
  1. curator-controlled code (ERC-1271) is never called from the custody contract;
  2. the signature scheme can be replaced without migrating LPs (relevant as EIP-7702 delegated EOAs and new signature
     standards appear), and replacing it revokes every outstanding signature at once;
  3. the vault keeps about 2.1 kB more headroom for the 1B-2 risk features.
- **DECISION D17:** confirm B. If the owner prefers minimum moving parts, A at `optimizer_runs ≤ 2,000` with a lens is
  a measured, viable fallback, with a 2.8–5.3 kB margin.

## 7. Hierarchical risk limits (PROPOSAL)

### 7.1 Levels

Every limit is **gross** (sum of `amountOut`, never netted against inflows). Netting would let wash trades refill
headroom.

| Level | Limit | Bounds | Where enforced | State |
|---|---|---|---|---|
| L1 Commitment | `maxOut`, `expiry ≤ now + MAX_HORIZON`, `f_c ≥ f_v` | one allocation's lifetime outflow and price | `reserveFor`, `exchange` (SOURCE today) | allocation |
| L2 Hook (strategy) | gross outflow per asset per window: `hookFlow[hook][a]` | a hook across **all** its allocations, curators and pools | `exchange` | leaky bucket |
| L3 Curator outflow | gross outflow per asset per window: `curatorFlow[c][a]` | a curator across all its allocations and hooks | `exchange` | leaky bucket |
| L3' Curator reservation | `curatorCeiling[c][a]` on outstanding `curatorReserved` (SOURCE) | the curator's open commitments, not its volume | `reserveFor` | existing |
| L4 Vault-wide outflow | gross outflow per asset per window: `vaultFlow[a]` | everything, across all curators and hooks | `exchange` | leaky bucket |
| L5 Exposure | `Q_a ≤ maxReservedBps · N_a / 10,000` and `expiry ≤ now + MAX_HORIZON` | how much of the LP basket can be promised, and for how long | `reserveFor` | one parameter per asset |
| L6 LP obligations | admission keeps `R_a` and `D_a` out of new commitments; `W_a` is excluded through `N_a`; flow limits **never** apply to `redeem`, `processQueue`, `claim` or `cancelRequest` | LP exits | `reserveFor`; LP paths untouched | existing |

**Gap closed by L3.** Today a curator's ceiling bounds only *outstanding* reservations. Consumption lowers
`curatorReserved`, so a curator can re-allocate after every fill: its *volume* per unit of time is unbounded (SOURCE:
`exchange` decrements `curatorReserved`). L3 bounds that volume.

**Bypass analysis.** One `exchange` updates L2, L3 and L4 atomically and reverts if any would exceed its cap.

| Bypass attempt | Caught by |
|---|---|
| Split one order into many swaps (same or separate transactions) | L2–L4 sum gross outflow; split pieces add up |
| Many allocations for the same hook | L2 (keyed by hook, not allocation), L3 |
| Route through another compatible hook | L3 (same curator), L4 (any curator) |
| Use another curator | L4 |
| Wash trade in the opposite direction to refill | not possible: buckets count gross outflow per asset; inflows never reduce them |
| Wait for the window to pass | intended: each bucket refills at `cap / window` per second |

**Default for an unconfigured bucket (DECISION D18).**

- Fail closed: a cap of 0 means no outflow (the prototype behaves this way).
- The owner must configure L4 for both assets and L2/L3 for each hook and curator before it can trade.
- Alternative: treat unconfigured L2/L3 as "no level-specific limit" and keep L4 mandatory. Recommendation: fail
  closed. The configuration cost is one transaction per hook or curator.

### 7.2 Window mechanics: leaky bucket, not fixed epochs

Each bucket is `{cap, level, last}`. On each use:

```
decay = elapsed ≥ WINDOW ? cap : floor(cap · elapsed / WINDOW)      (rounds down: less decay, conservative)
level = max(0, level − decay) + amountOut;  require(level ≤ cap)
```

- **Strict bound.** Over **any** interval of length T, gross outflow ≤ `cap + cap · T / WINDOW`. A fixed epoch counter
  allows up to `2 · cap` within a few seconds around a boundary (end of epoch e, then start of e+1). The bucket does
  not.
- **Skipped time.** Any gap is handled in O(1): `elapsed ≥ WINDOW` resets the level to 0. No per-epoch iteration and no
  keeper.
- **Wraparound.** The prototype packs `last` as `uint32`. That is **unsafe after 2106-02-07**: `block.timestamp −
  last` would mix a full timestamp with a truncated one, give a huge `elapsed`, and silently reset every bucket. The
  implementation must either store `uint40` (good until year 36,812) or compute
  `elapsed = uint32(block.timestamp) − last` inside `unchecked` (correct modulo 2^32 for gaps under 136 years).
  Required test: warp across `2^32` and assert that the bucket does not reset early.
- **Packing.** `uint112 cap, uint112 level, uint32 last` fits one slot. Amounts are limited to `2^112 − 1`, about
  `5.2·10^15` tokens at 18 decimals. Caps above that must revert on configuration.
- **Changing a cap.** Raising takes effect at once (owner only). Lowering below the current `level` blocks outflow
  until decay brings `level` under the new cap (guardian or owner). Neither changes `level`.

### 7.3 Expiry of commitments (ring buffer question)

`RISKS.md` R4 and the blueprint's "O(1) ring-buffer expiry" ask whether reserved capacity should expire in aggregate
buckets.

- **Recommendation for 1B-2: keep per-allocation lazy expiry.** An expired allocation cannot be consumed
  (SOURCE), and anyone may release it. Each release is O(1).
- An aggregate ring buffer (index = `expiryBucket mod N`, tagged with the bucket number) could subtract a whole bucket
  from `Q_a` at once. It needs all of the following:
  1. a tag per slot, so that a slot reused after wraparound is never confused with an old bucket;
  2. `N > MAX_HORIZON / BUCKET + 1`;
  3. a swept flag per bucket, so that a later per-allocation `release` does not subtract the same capacity again;
  4. the same structure for `curatorReserved`.

  It also changes `Q_a` at read time, which every LP path would have to apply. It does not remove the need for a
  transaction: someone must touch the vault. Cost and complexity are high and the benefit is liveness only.
- Deferred. If adopted later, it needs its own specification and the R4 tests (long gaps, slot reuse, wrap, double
  release).

## 8. Size and gas measurements (OBSERVED unless marked)

### 8.1 Optimizer setting, current vault, no code change

| `optimizer_runs` (whole project) | Vault runtime | Vault init | EIP-170 margin | HookA swap (router + PM + hook + vault) | Native v4 swap (router + PM) |
|---|---|---|---|---|---|
| 44,444,444 (current) | 22,814 | 23,444 | 1,762 | 214,443 | 150,274 |
| 200,000 | 22,814 | 23,444 | 1,762 | — | — |
| 20,000 | 19,098 | 19,728 | 5,478 | 215,486 | 151,206 |
| 2,000 | 17,792 | 18,422 | 6,784 | 217,048 | 152,463 |
| 200 | 15,937 | 16,567 | 8,639 | 219,302 | 153,861 |

- **How to read the gas columns.** Foundry compiles a test file's whole import graph with the restricted profile, so
  the PoolManager, router and hooks were also built at the lower setting in these runs. The deployed PoolManager is
  Uniswap's, not ours.
- **Vault and hook share at runs 200** (ESTIMATE): subtract the native-swap delta from the hook-swap delta,
  `(219,302 − 214,443) − (153,861 − 150,274) = 1,272` gas per swap, about 0.6%. To confirm, compile only the vault at
  low runs in a separate artifact and call it from a default-runs harness.
- **LP paths at runs 200** (same caveat): `deposit_newLp` 157,267 → 159,612 (+1.5%); `redeem_instant_full`
  168,404 → 170,095 (+1.0%). Vault deployment in `test_gas_initialDeposit`: 5,537,527 → 4,078,792.

### 8.2 Architecture prototypes

**Method.**

- These prototypes exist only to measure size and gas. They are not implementations, were not reviewed, and are not
  committed.
- A script generated vault variants from the current source in a scratch worktree, using exact, asserted text patches:
  - **Lens:** remove 7 view functions, make `netAssets`, `pendingDemand` and `admissibleCapacity` internal.
  - **Risk:** curator status (None/Active/Frozen/Revoked) replacing `isCurator`; the freeze check in `exchange`;
    `freezeCurator`, `unfreezeCurator`, `revokeCurator`, `cancelAllocation`, `setFlowCap`; three leaky buckets updated
    in `exchange`.
  - **A:** Risk + OZ 5.0.2 `EIP712` and `SignatureChecker` inline, a nonce bitmap, `invalidateNonces`, per-curator
    generation, `allocateWithSig`.
  - **B:** Risk + `reserveFor` restricted to `authModule`; nonces and deadline moved to a separate `AuthModuleProto`
    (OZ `EIP712` and `SignatureChecker`, bitmap, generation, `activate`, `activateDirect`).
  - **C upper bound:** Risk + Lens, minus `allocate`, `release`, `cancelAllocation`, the curator and flow setters and
    `admissibleCapacity`; `exchange` kept whole, so the figure overstates the C vault.
- Gas comes from `forge test --isolate` on the real PoolManager with HookA. Every activation is measured by a curator
  with no earlier allocation, after a warm-up allocation by another curator, so storage cold/warm states match. Swap:
  1,000 in, `zeroForOne`.

**Runtime size (bytes)**

| Variant | 44.4M | 20,000 | 2,000 | 200 |
|---|---|---|---|---|
| Current vault | 22,814 | 19,098 | 17,792 | 15,937 |
| Current − views (lens) | 21,283 | 17,945 | 16,682 | 14,734 |
| + Risk features | **26,258** ✗ | 22,012 | 20,522 | 18,305 |
| A (Risk + inline auth) | **28,797** ✗ | 24,401 | 22,847 | 20,427 |
| A − views | **27,318** ✗ | 23,300 | 21,764 | 19,248 |
| B vault | **26,293** ✗ | 21,965 | 20,481 | 18,293 |
| B vault − views | **24,807** ✗ | 20,857 | 19,391 | 17,110 |
| B auth module | 5,008 | 5,008 | 4,206 | 3,776 |
| C vault (upper bound) | 18,262 | — | — | 12,732 |

✗ = over the 24,576 B EIP-170 limit. **At the current optimizer setting, no option that includes the risk features
fits in one contract, and neither does B's vault.** Lowering `optimizer_runs` is required for every option except C.

**Gas (runs 200; runs 20,000 in brackets)**

| Operation | Current | Risk only | A | B |
|---|---|---|---|---|
| Deploy vault | 3,648,158 [4,307,373] | 4,163,258 [4,936,548] | 4,641,466 [5,470,260] | 4,160,637 [4,926,425] |
| Deploy module | — | — | — | 920,184 [1,182,022] |
| Direct activation (fresh curator) | 264,419 [263,730] | 264,602 [263,910] | 262,867 [262,384] | 270,158 [269,258] |
| Signed activation, EOA | — | — | 274,951 [274,326] | 283,071 [281,900] |
| Signed activation, ERC-1271 | — | — | 282,449 [281,425] | 290,560 [289,011] |
| HookA swap end to end | 221,043 [217,224] | 240,206 [236,452] | 240,515 [236,596] | 240,371 [236,452] |
| `cancelAllocation` | — | 44,326 | — | — |
| `freezeCurator` | — | 35,973 | — | — |

**Readings.**

- **Swap cost of the risk features: +19,163 gas (+8.7%).** That is one cold curator-status read plus three leaky
  buckets, each a cold read and a non-zero-to-non-zero write. Breakdown (ESTIMATE, from EIP-2929/2200 constants): about
  2,100 for the status read and about 5,500 per bucket. Two measurable reductions:
  - pack the curator's status, generation and outflow bucket into one slot, using `uint96` amounts and saving about
    2,100 gas;
  - make L2 optional per hook.

  Measure both in 1B-2.2.
- **Signature verification inline (A): +12,084 over a direct activation.** That covers `ecrecover` (3,000), EIP-712
  hashing and signature calldata. ERC-1271 adds +7,498.
- **Module hop (B vs A): +8,120 per activation.** That is a cold account access (2,600), re-encoding the request struct,
  and the vault's ABI decoding.
- **A and B do not differ on the swap path** (within 150 gas, which is dispatch-table noise).
- **Deployment.** B costs about 440k more than A at runs 200 for both contracts together. The extra lens is extra, not
  measured (ESTIMATE ≈ 1M, view-only).

**Not measured (ESTIMATE, with how to measure).**

- The full C design: build the engine only if D17 rejects B.
- The transient reentrancy lock: §4.5.
- Packed curator slot: 1B-2.2.
- Lens deployment: measured in 1B-2.0, §8.3.
- Vault-only optimizer effect: measured in 1B-2.0, §8.3.

### 8.3 Step 1B-2.0 as built (OBSERVED)

Production builds only, measured by `test/bench/run.sh`. That harness compiles under the default profile and deploys
the vault's own artifact, the hooks' default-profile artifacts and a PoolManager built with v4-core's settings. This
removes the confound in §8.1. Full tables are in `PHASE1B2_STEP1_REPORT.md`.

| | Before (`2b82851`) | Vault at 2,000 runs (`ea370dd`) | + `VaultLens` (`b62a28f`) |
|---|---|---|---|
| Vault runtime / init (B) | 22,814 / 23,444 | 17,792 / 18,422 | 17,035 / 17,644 |
| Vault EIP-170 margin (B) | 1,762 | 6,784 | 7,541 |
| HookA swap, end to end | 214,382 | 214,831 (+449) | 214,456 (+74) |
| Native v4 swap (control) | 150,303 | 150,303 | 150,303 |
| Allocate, steady state | 263,307 | 264,212 | 264,080 |
| Deploy vault (CREATE) | 5,080,926 | 4,001,060 | 3,838,048 |
| `VaultLens` runtime / deploy (CREATE) | — | — | 5,046 B / 1,167,248 |

- **Vault-only cost of 2,000 runs.** It is +449 gas per swap, not the +1,272 estimated in §8.1. That estimate was for
  200 runs and subtracted a PoolManager that had also been recompiled.
- **The lens recovered most of that cost.** Most likely this is because the vault's selector dispatch has 8 fewer
  entries. This explanation is not verified by trace.
- **Prototype comparison.** The lens prototype predicted 16,682 B at 2,000 runs. The built vault is 353 B larger,
  because `getRequest` and `admissibleCapacity` stay external (the step 1 report explains why).

## 9. Invariants the architecture must keep (existing + new)

Existing invariants (`PHASE1AH_REPORT.md` §4.1; `PHASE1B_THREATS_AND_PLAN.md` §1) all hold unchanged. New ones:

| ID | Invariant |
|---|---|
| INV-M1 | Only `vault.exchange` decreases the vault's ERC-6909 balance outside LP payouts. No module holds claims or operator rights. |
| INV-M2 | Every allocation was created by `reserveFor` called by the `authModule` in effect at that block, for a curator that was Active at that block, with the vault's own risk checks passing. |
| INV-M3 | No `exchange` succeeds for an allocation whose curator is Frozen or Revoked at that block. |
| INV-M4 | A Revoked curator is terminal: its status never changes again, and no allocation is ever created for it again. |
| INV-M5 | For each bucket and any interval of length T, gross outflow ≤ `cap + cap · T / WINDOW` (checked against a ghost log of `exchange` outflows). |
| INV-M6 | The flow limits never change the outcome of `redeem`, `processQueue`, `cancelRequest` or `claim` (differential test). |
| INV-M7 | `Q_a ≤ maxReservedBps · N_a / 10,000` immediately after every successful `reserveFor`. |
| INV-M8 | Disabling or replacing `authModule` does not change any allocation, `Q_a`, `B_a`, share, or queue entry. |

## 10. Open decisions

| ID | Decision | Recommendation |
|---|---|---|
| D17 | Architecture A, B or C | **B** (§6) |
| D18 | Unconfigured flow bucket: closed or unlimited | **Closed** (§7.1) |
| D19 | Vault optimizer setting | Start 1B-2 at **2,000** for the vault. Re-measure after every commit. Keep at least 2,048 B of margin; drop to 200 if the margin falls below that. |
| D20 | Aggregate ring-buffer expiry | **Defer** (§7.3) |
| D21 | Exposure cap L5 (`maxReservedBps`) | Adopt, owner-set, guardian may lower |
