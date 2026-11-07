# Porkfolio — Phase 1B-0: Minimum Execution-Price Policy (Specification)

**Status: SPECIFICATION FOR REVIEW. Nothing in this document is implemented.** It defines the price policy that Phase 1B
must enforce before EIP-712 curator authorization is built. Companion documents:

- `PHASE1B_CURATOR_AUTH.md`: signed curator authorizations and their lifecycle.
- `PHASE1B_THREATS_AND_PLAN.md`: threat model, invariants, required tests and the commit plan.

Labels used below:

| Label | Meaning |
|---|---|
| **SOURCE** | Read in the pinned code (`f104afb`, v4-periphery `c6e4754`, v4-core and OZ 5.0.2 as vendored under it) |
| **OBSERVED** | Shown by an existing test in this repository |
| **ASSUMPTION** | Taken as given and not verified here |
| **PROPOSAL** | Recommended design, pending approval |
| **DECISION** | Needs a human choice (collected in §15) |

---

## 1. Problem

Accounting solvency is not economic protection.

- **SOURCE.** `exchange` accepts a trade when `amountIn ≥ ⌈amountOut · minInPerOutX96 / 2^96⌉`. `minInPerOutX96` is chosen
  by the curator when the allocation is created. Nothing stops it being 0.
- **SOURCE.** Hook A and Hook B price trades from `priceX96`, which the **hook owner** sets through `configurePool`. The
  hook owner is a different party from the vault owner, and the vault never reads that value.
- **OBSERVED.** With a registered hook and a curator floor of 0, LPs can be drained to near zero while every accounting
  identity still holds (`test_bothAssetsZero_unreachable_nearTotalDepletionIsEconomic`,
  `test_pendingRequest_capacityProtected_valueSharesLoss`; `SHARE_ACCOUNTING.md` §10.3).

So today the only bound on what an authorised hook can give away is a number the curator alone picks. Phase 1B adds an
independent bound that the **vault** controls and that a curator signature cannot weaken.

## 2. Price representation and units

### 2.1 One unit everywhere: raw input per raw output, Q64.96

Every price in the policy is a **minimum input-per-output ratio in raw token base units**, encoded as an unsigned
Q64.96 fixed-point number in a `uint160`:

```
F  =  (min raw units of currencyIn received) / (1 raw unit of currencyOut paid)  ·  2^96
```

- This is the unit `minInPerOutX96` already uses (SOURCE: `ISharedCommitmentVault.AllocationRequest`).
- It reads as "the vault sells `currencyOut` and must receive at least `F / 2^96` of `currencyIn` per unit sold". A
  higher `F` is a **stricter** floor for the vault.
- The vault holds a single pair `(asset0, asset1)`. The direction is therefore identified by **the currency the vault
  sells**:

| Swap direction (`zeroForOne`) | Vault receives | Vault sells (`currencyOut`) | Floor unit |
|---|---|---|---|
| `true` | `asset0` | `asset1` | raw `asset0` per raw `asset1` |
| `false` | `asset1` | `asset0` | raw `asset1` per raw `asset0` |

Raw units make the on-chain check independent of `decimals()`. That matters because `decimals()` is optional in ERC-20,
and the vault never calls it (SOURCE). All decimal handling is an off-chain conversion with a fixed rounding rule
(§2.2).

### 2.2 Decimal normalization (off-chain, rounded towards the vault)

Given a human price `p` = the minimum number of whole `currencyIn` tokens per whole `currencyOut` token, with decimals
`d_in` and `d_out`:

```
F = ⌈ p · 10^d_in · 2^96 / 10^d_out ⌉
```

The conversion rounds **up**, so the encoded floor is never looser than the stated human price. Tooling must compute it
in exact integer or rational arithmetic, not floating point.

### 2.3 Worked example: USDC (6 decimals) / WETH (18 decimals)

Reference market price of 3,000 USDC per WETH (an illustrative number, not data). The policy sets a 5% band around it.
Values were computed exactly with integer arithmetic.

> **Erratum (Phase 1B-1, `PHASE1B_DECISIONS.md` D14).** These two floors **cross**: their product is about 0.905 ×
> `2^192`, which would allow a profitable round trip at the floors. The vault now rejects this configuration. A valid
> pair is to sell WETH at ≥ 2,850 USDC and sell USDC at ≥ 1/2,850 WETH
> (`F = 27799355268162925471418929942456140351`). The per-row arithmetic below is still correct for each direction
> taken alone.

| Vault sells | Human floor | `F` (X96) | Bits | Required input for … |
|---|---|---|---|---|
| WETH | ≥ 2,850 USDC per WETH | `225800263165653362142` | 68 | 1 WETH → 2,850.000001 USDC (`2850000001` raw); 1 wei → 1 raw USDC; 1 gwei → 3 raw USDC |
| USDC | ≥ 1/3,150 WETH per USDC (the vault will not buy WETH above 3,150 USDC) | `25151797623575980188426650900317460318` | 125 | 1 USDC → `317460317460318` wei; 1 raw USDC → `317460318` wei |

Observations:

- Rounding the floor up adds at most one raw unit of input per trade, in the vault's favour. In the first row it costs
  the swapper 1 raw unit (`0.000001` USDC).
- Dust trades pay far above the floor because of the `⌈·⌉` (1 gwei of WETH requires 3 raw USDC rather than 2.85). That
  is the intended direction of rounding.
- Both floors sit well inside the `uint160` range (68 and 125 bits).

### 2.4 Representable range and granularity

- Representable floors: `2^-96 ≤ F/2^96 < 2^64` raw-in per raw-out. Anything outside cannot be configured.
- The relative granularity of a floor is `1 / F`:
  - a raw ratio of `10^-9` (the WETH-sale row above) has granularity about `1.3·10^-20`;
  - a raw ratio of `10^-18` has granularity about `1.3·10^-11`;
  - a raw ratio of `10^-24` has granularity about `1.3·10^-5`.
- For 6/18 and 18/18 pairs this is far below any meaningful price step. Pairs whose raw ratio falls below about
  `10^-24` (for example, a token worth less than about `10^-12` USD in 18 decimals sold for a 6-decimal stablecoin)
  would get coarse floors. Such pairs are **out of scope** for UHI11.

## 3. Exact-input exchange price from actual claim movements

### 3.1 Definition

For one successful `exchange` call, let

- `ΔIn` = increase of `PoolManager.balanceOf(vault, currencyIn.toId())`;
- `ΔOut` = decrease of `PoolManager.balanceOf(vault, currencyOut.toId())`.

The **execution price** is `ΔIn / ΔOut` (raw input per raw output). The policy requirement is the exact rational
inequality

```
ΔIn · 2^96  ≥  ΔOut · F_eff                                        (P1)
```

where `F_eff` is the effective floor of §4.

### 3.2 Why the declared amounts are the actual movements

The vault checks P1 using the `amountIn` and `amountOut` arguments, then moves exactly those amounts:

```
poolManager.transferFrom(hook, vault, currencyIn.toId(), amountIn);   // ΔIn  = amountIn
poolManager.transfer(hook, currencyOut.toId(), amountOut);            // ΔOut = amountOut
```

**SOURCE** (`lib/v4-periphery/lib/v4-core/src/ERC6909.sol`, lines 25–47):

- `transfer` and `transferFrom` change balances by exactly `amount`.
- They charge no fee and invoke no receiver or sender hook.
- They call nothing outside the PoolManager.

So, provided the vault's `poolManager` immutable is the canonical v4 PoolManager (**ASSUMPTION**, fixed at
construction), `ΔIn = amountIn` and `ΔOut = amountOut`. No third party runs between the check and the movements.

The existing invariant `invariant_actualBalanceMovementsMatchAccounting` already compares real ERC-6909 movements with
the accounting (OBSERVED). Phase 1B adds a test that evaluates P1 on the **measured deltas**, not on the arguments
(`PHASE1B_THREATS_AND_PLAN.md` T-04).

**On-chain balance-delta re-measurement is not proposed.** It would cost two extra `balanceOf` calls per swap and adds
nothing while the PoolManager is canonical. If the vault were ever made generic over the PoolManager address, this
should be revisited.

### 3.3 Whose price this is

- P1 protects the **vault's LPs**. It does not protect the swapper.
- With `BaseCompatibleHook` the swapper's price equals the vault's price exactly (SOURCE: the hook returns
  `BeforeSwapDelta(+amountIn, −amountOut)`). The swapper's own protection is the router's minimum-output check (OBSERVED:
  `test_minOut_violation_rollsBack`).
- A malicious registered hook could charge the swapper more than it forwards to the vault and keep the spread. That is
  harm to swappers who choose that pool. It does not reduce what the vault receives, which P1 still bounds.

### 3.4 Exact input only

Hooks reject exact-output swaps (SOURCE: `ExactOutputNotSupported`). P1 is stated on vault-side movements, so it would
apply unchanged if exact output were added later.

## 4. Three price layers and the effective floor

| Layer | Set by | Scope | Changes after activation? | Trusted for LP value? |
|---|---|---|---|---|
| Hook reference price (`priceX96`, fee, impact) | **hook owner** | per pool | yes, at any time | **No.** Untrusted input. |
| Curator floor `f_c` (`minInPerOutX96` in the signed authorization) | curator, by signature | per allocation | **no** (fixed when activated) | Only as far as the curator is trusted |
| Vault floor `f_v[out]` | vault roles (§6) | per sold currency, i.e. per direction | yes, **live** (§7) | Yes. It is the independent bound. |

### 4.1 Rules (PROPOSAL)

**Activation** of an allocation selling `out` requires all of:

```
f_v[out] ≠ 0                    (direction configured; otherwise revert PriceFloorNotConfigured)
!halted[out]                    (direction not halted; otherwise revert DirectionHalted)
f_c ≠ 0                         (no zero curator floor; otherwise revert ZeroPriceFloor)
f_c ≥ f_v[out]                  (curator cannot sign below the vault minimum; otherwise revert FloorBelowVaultMinimum)
```

**Exchange** under allocation `j` requires:

```
f_v[out] ≠ 0  and  !halted[out]
F_eff = max(f_v[out] read NOW, f_c(j))
amountIn ≥ ⌈amountOut · F_eff / 2^96⌉                                           (≡ P1)
```

### 4.2 How the signed floor combines with the vault floor

The effective floor is the **maximum** of the two layers. This has three consequences:

- **Curator cannot weaken the vault.** A signature can only make the floor stricter.
- **Vault cannot weaken the curator.** Loosening `f_v` never lowers the floor below what the curator signed, so the
  curator's consent is never exceeded.
- **No arithmetic.** `max` of two `uint160` values involves no rounding.

Requiring `f_c ≥ f_v` at activation is redundant with `max` for safety. It is still proposed (DECISION D4) because it
makes the signer state an explicit price and rejects zero or forgotten floors at the cheapest point. If `f_v` later
rises above `f_c`, `max` enforces the new `f_v` anyway.

### 4.3 Granularity: per direction, not per pool or per hook

The floor is keyed by sold currency only. Every pool bound to this vault trades the same pair (SOURCE: `allocate`
requires `key.currency0/1 == asset0/1`), so per-pair and per-direction coincide. Per-hook vault floors are not
proposed. Hooks are already bounded per allocation by the curator floor, and a second vault-side dimension adds
configuration surface without a demonstrated need.

## 5. Direction-specific bounds for Hook A and Hook B

Both hooks take `P = priceX96` (raw `asset1` per raw `asset0`, Q64.96) and compute (SOURCE `BaseCompatibleHook._grossOut`,
`HookA_DynamicFee._quote`, `HookB_BoundedImpact._quote`):

```
zeroForOne :  gross = ⌊in · P / 2^96⌋      out = ⌊gross · (10^6 − x) / 10^6⌋
oneForZero :  gross = ⌊in · 2^96 / P⌋      out = ⌊gross · (10^6 − x) / 10^6⌋
```

The deduction `x` (in pips) is:

- **Hook A:** `x = fee ∈ [baseFeePips, maxFeePips]`, rising with utilisation.
- **Hook B:** `x = impact ∈ [0, maxImpactPips]`. It is `⌈impactAtFull · gross / remaining⌉`, which can be 0 only if
  `impactPipsAtFullQuota = 0`.

Every rounding step in the hooks lowers `out`, which favours the vault. Write `x_min` for the smallest deduction the
hook can apply: `baseFeePips` for Hook A, 0 for Hook B. Then a **sufficient** condition for every quote of the hook to
pass the vault floor is:

| Direction | Vault sells | Condition on hook reference `P` |
|---|---|---|
| `zeroForOne` | `asset1` | `P · F_eff(asset1) · (10^6 − x_min) ≤ 2^192 · 10^6` |
| `oneForZero` | `asset0` | `P · 10^6 ≥ F_eff(asset0) · (10^6 − x_min)` |

Together these give the **executable band** of hook reference prices:

```
F_eff(asset0)·(1 − x_min)  ≤  P  ≤  2^192 / (F_eff(asset1)·(1 − x_min))        (all in X96)
```

- Inside the band, every trade passes the floor. The vault's realised price is the hook's quote, which may still be
  below the market price; the floor bounds how far.
- Outside the band, trades that would breach `F_eff` **revert** in `exchange` (`PriceBelowFloor`). They never execute
  at a worse price. Mis-configuring a hook is a liveness failure, not a loss.
- **D14 (Phase 1B-1).** Because the vault requires `F_eff(asset0)·F_eff(asset1) ≥ 2^192`, this band is non-empty only
  if `F_eff(asset0)·F_eff(asset1)·(1 − x_min)^2 ≤ 2^192`: a hook trades both directions only when its spread straddles
  the vault's pivot interval (`PHASE1B_DECISIONS.md` D14).
- **Example** (§2.3 floors, which are crossed and now invalid; see the erratum there), 3,000 USDC per WETH with USDC as `asset0`): the band is the WETH price range in which both
  directions are executable, about 2,850 to 3,150 USDC per WETH, widened slightly by `x_min`. A hook owner who sets the
  reference to 1 USDC per WETH can no longer sell the vault's WETH. Before Phase 1B they could, down to the curator floor.

The hooks need **no change for safety**; the vault enforces the floor. For usability, Phase 1B adds vault views that
the hooks' off-chain `quote()` can use (§14, DECISION D9).

## 6. Who may tighten and loosen vault bounds (PROPOSAL)

Phase 1B introduces one additional role, the **guardian**. Its powers can only **reduce** risk (DECISION D2).

| Action | Owner | Guardian | Anyone else |
|---|---|---|---|
| Raise `f_v[out]` (tighten) | ✓ | ✓ | ✗ |
| Lower `f_v[out]` (loosen); first configuration from 0 | ✓ | ✗ | ✗ |
| Halt a direction (`halted[out] = true`) | ✓ | ✓ | ✗ |
| Resume a direction | ✓ | ✗ | ✗ |
| Set `f_v[out]` back to 0 | ✗. Use halt instead; 0 is reserved for "never configured". | ✗ | ✗ |
| Set or replace the guardian | ✓ | ✗ | ✗ |

Additional rules:

- **One setter.** `setSellFloor(out, F)` is a single function. The guardian's call reverts with `GuardianCannotLoosen`
  when `F < f_v[out]`. Each change emits `SellFloorSet(out, old, new, msg.sender)`.
- **No loosening delay in code (DECISION D3).** A timelock on loosening alone would be theatre: the same owner can
  register a hook and raise curator ceilings with no delay. A code-level delay only helps if every risk-increasing
  action is delayed. For UHI11 the recommendation is operational: the owner should be a multisig or timelock at
  deployment, and the owner is documented as fully trusted.
- **Directional consistency is enforced (superseded by `PHASE1B_DECISIONS.md` D14).** Whenever both floors are
  configured, `F(asset0) · F(asset1) ≥ 2^192` is required, so no round trip at the floors is profitable. Raising one
  side, the guardian's de-risking move, always preserves this.

## 7. New bounds apply immediately to outstanding commitments (PROPOSAL)

`f_v` and `halted` are read **at exchange time**. They are never snapshotted into an allocation.

**Why.** Allocations live for up to `MAX_HORIZON = 30 days` (SOURCE). An emergency tightening that left existing
commitments at the old floor would be ineffective for exactly the commitments that matter.

**Consequences.**

- **A commitment can become unexecutable.** Tightening above a hook's executable band (§5) makes an outstanding
  allocation unconsumable. Its capacity stays in `Q_a` until it is canceled by its curator, emergency-released, or
  released after expiry. That reduces free inventory `F_a`, so LP exits may queue instead of being instant. The
  emergency procedure (§12) therefore pairs tightening with release.
- **Reservation does not guarantee price.** This is consistent with `RISKS.md` R5: the vault never promised execution.
  Phase 1B documentation must keep the phrase "reserved capacity" and never say "guaranteed execution".
- **Loosening is bounded.** Loosening cannot take an existing allocation below its signed `f_c` (§4.2).
- **Curator floor is fixed.** The curator's `f_c` cannot be changed after activation. To change it, the curator cancels
  and activates a new authorization with a new nonce.

## 8. Design comparison

### 8.1 Design A — governance-configured per-direction minimum (static floor)

`f_v[out]` is set by the roles in §6 and changes only by transaction.

| Property | Assessment |
|---|---|
| External dependency | None |
| Failure modes | Only mis-configuration: unset → fail closed; too strict → halts trading; too loose → weak bound |
| Gas on the swap path | One extra storage read (cold `SLOAD`, 2,100 gas under EIP-2929) to load `f_v` and `halted` from one packed slot |
| Code size | Small (one mapping, one setter, two checks) |
| Market tracking | **None.** If the market moves away from `f_v`, the bound weakens until someone updates it. |
| What it guarantees | Valued at `F_eff`, the vault's holdings never decrease through a trade. Nothing more. |
| Loss bound vs market price `M` (in-per-out) | per unit sold: `max(0, M − F_eff)`. Per allocation: `remaining · max(0, M − F_eff)` |

### 8.2 Design B — oracle-referenced minimum with bounded deviation and freshness

```
r        = oracle reference price of asset0 in asset1, normalized to raw X96
f_o[a0]  = ⌈ r · (10^6 − δ) / 10^6 ⌉                 (vault sells asset0)
f_o[a1]  = ⌈ (2^192 / r) · (10^6 − δ) / 10^6 ⌉       (vault sells asset1)
F_eff    = max(f_v[out], f_o[out], f_c)
```

The oracle read must pass all of the following, or the exchange **reverts**, with no fallback:

- answer `> 0`, so zero and negative values are rejected (the answer type is `int256` for the common feed interface);
- `updatedAt ≠ 0`, `updatedAt ≤ block.timestamp`, and `block.timestamp − updatedAt ≤ maxAge`;
- answer within a configured sanity band `[minAnswer, maxAnswer]`, to catch aggregator clamping or circuit-breaker
  values;
- on an L2, a sequencer-uptime check: the sequencer is up and `block.timestamp − startedAt > gracePeriod`;
- normalization from feed decimals and token decimals that fits in `uint160`, with every rounding step towards the
  vault;
- for two-hop references (for example, two USD feeds), both legs must pass every check, and the combined rounding must
  be stated.

| Property | Assessment |
|---|---|
| External dependency | **Yes.** An oracle provider, its feed for this exact pair, and, on an L2, a sequencer-uptime feed |
| Availability on Unichain | **Not verified.** This phase checked no feed registry and no feed addresses. It must not be assumed that a feed exists for a given pair, or what its heartbeat, deviation threshold and decimals are. |
| Failure modes | Stale, zero, negative, out-of-band, sequencer down, provider deprecation: each halts trading (fail closed). It adds a liveness dependency. |
| Gas on the swap path | Two or more external `staticcall`s, plus the Design A read |
| Code size | Large relative to the 4,542-byte EIP-170 margin left in the vault (SOURCE: `forge build --sizes`, runtime 20,034 B) |
| Market tracking | Yes, within `δ`, freshness and the oracle's own accuracy |
| What it guarantees | Execution no worse than `(1 − δ)` × a reference **the oracle reports**. It is not a fair-price guarantee, because the oracle can be wrong, lagging or manipulated upstream. |

### 8.3 Rejected references

| Candidate | Why rejected |
|---|---|
| The hook's own `priceX96` | Set by the hook owner. It is the thing being bounded. |
| `sqrtPriceX96` of the vault's own pools | Never moves, because every swap is intercepted (OBSERVED: `test_nativeCurveNotExecuted_poolStateUnchanged`). It is set by whoever initializes the pool. |
| A TWAP from some other v4 pool | v4-core has no built-in oracle. A hook-based TWAP adds a dependency on that hook and on manipulation resistance that is not analysed. Out of scope. |

## 9. Recommendation

**Adopt Design A for UHI11:**

- static per-direction vault floor;
- effective floor = `max(f_v, f_c)`, read live;
- fail closed when unconfigured;
- guardian can tighten and halt; only the owner can loosen.

Reasons:

1. **Closes the reported vulnerability completely.** A zero or near-zero floor becomes impossible, and the loss from an
   authorised but adversarial hook is bounded by an independent, vault-controlled number.
2. **Adds no external dependency and no new failure mode** beyond configuration.
3. **Fits the size and gas budget.** One cold `SLOAD` per swap, and little code.
4. **Keeps an oracle as an explicit, separately approved extension.** Design B can be layered later as an additional
   `max` term without changing the units, the rule or the curator schema. No oracle code, interface or seam is added in
   Phase 1B.

**Non-guarantee, to be repeated in user-facing documentation.** A static minimum exchange rate is **not** a guarantee
of fair market pricing. It bounds worst-case execution relative to a number governance chose. When the market moves
away from that number, the protection weakens until governance updates it. Monitoring the market and updating floors is
an off-chain operational duty.

## 10. Behaviour when no external price reference exists (Design A)

- The vault has **no notion of market price**. It knows only `f_v`, `f_c` and the amounts in each trade.
- A direction with `f_v[out] = 0` (never configured) is **closed**: activation and exchange revert with
  `PriceFloorNotConfigured`.
- There is no fallback to the hook price, the pool price, or the curator floor alone.
- **LP exits do not depend on any price.** Redemption is in kind and pro rata (SOURCE: `_entitlement`). `redeem`,
  `processQueue`, `cancelRequest`, `claim` and `release` read no floor, no halt flag and no oracle. Neither a missing
  price nor an oracle failure (in Design B) can block an LP exit. Phase 1B must preserve this property and test it
  (T-12).

## 11. Rounding, overflow, precision

| Step | Rule | Bound |
|---|---|---|
| Human price → `F` | round **up** (§2.2), done off-chain | — |
| Combining layers | `max(f_v, f_c)`, with no arithmetic | exact |
| Required input | `FullMath.mulDivRoundingUp(amountOut, F_eff, 2^96)` (SOURCE: already used) | `amountOut < 2^127` and `F_eff < 2^160`, so the product is below `2^287` (a 512-bit intermediate in `FullMath`) and the result is below `2^191`. No overflow. |
| Acceptance | `amountIn ≥ requiredIn` | Exactly equivalent to the rational inequality P1, because `amountIn` is an integer: `⌈x/d⌉ ≤ a ⇔ x ≤ a·d`. No slack in either direction. |
| `requiredIn > MAX_AMOUNT` | the trade necessarily fails (`amountIn ≤ MAX_AMOUNT`) | fail closed |
| Hook-side rounding | every step rounds `out` down (SOURCE) | favours the vault |
| Design B normalization (not implemented) | every division rounds towards a stricter floor; results `≥ 2^160` revert | — |

**Precision of the floor value** is covered in §2.4.

## 12. Emergency de-risking and fail-closed behaviour

| Situation | Response (role) | Effect on LP exits |
|---|---|---|
| Market moved against a floor | guardian or owner raise `f_v` (applies to live allocations, §7) | none |
| Suspected bad hook | guardian halts the affected direction or both; guardian deregisters the consumer (risk-reducing; registering stays owner-only) | none |
| Suspected compromised curator | guardian reduces that curator's ceiling to 0 (blocks new activations); guardian or owner emergency-release its allocations (`PHASE1B_CURATOR_AUTH.md` §7) | **improves**: released capacity returns to `F_a` |
| Unknown failure | guardian sets `paused` (stops deposits, activations and exchanges); unpausing is owner-only | none (exits are not paused; SOURCE and OBSERVED: `test_pause_blocksInflowsAndCommitments_notExits`) |
| Capacity frozen by unexecutable allocations | emergency release (owner or guardian) | **improves** |

Every price-policy failure **reverts the trade**. No path executes a trade at a floor lower than `max(f_v, f_c)`, and no
path substitutes a default price.

## 13. Explicit non-guarantees

- No fair-market-price guarantee (§9).
- No guarantee that a reserved allocation will execute (§7; `RISKS.md` R5).
- No protection of swappers from a malicious hook's spread (§3.3).
- No protection against a malicious **owner**. The owner can loosen floors, register hooks and raise ceilings. The
  guardian cannot stop this.

## 14. Interface sketch (non-binding; to be finalized in implementation review)

```solidity
struct SellPolicy { uint160 minInPerOutX96; bool halted; }       // one storage slot
mapping(Currency currencyOut => SellPolicy) public sellPolicy;
address public guardian;

function setGuardian(address guardian_) external;                          // owner
function setSellFloor(Currency currencyOut, uint160 minInPerOutX96) external;  // owner: any non-zero; guardian: raise only
function setSellHalted(Currency currencyOut, bool halted) external;        // halt: owner|guardian; resume: owner

function effectiveFloorX96(uint256 allocationId) external view returns (uint160);
function requiredInput(uint256 allocationId, uint256 amountOut) external view returns (uint256);

error PriceFloorNotConfigured(Currency currencyOut);
error DirectionHalted(Currency currencyOut);
error ZeroPriceFloor();
error FloorBelowVaultMinimum(uint160 curatorFloor, uint160 vaultFloor);
error GuardianCannotLoosen(uint160 current, uint160 requested);
error NotGuardianOrOwner();

event GuardianSet(address indexed previous, address indexed current);
event SellFloorSet(Currency indexed currencyOut, uint160 previous, uint160 current, address indexed by);
event SellHaltedSet(Currency indexed currencyOut, bool halted, address indexed by);
```

`PriceBelowFloor(amountIn, requiredIn)` is kept. Phase 1B computes `requiredIn` from `F_eff`.

## 15. Open decisions (price policy)

| ID | Decision | Recommendation |
|---|---|---|
| D1 | Static per-direction floor (A) or oracle-referenced floor (B) | **A** for UHI11; B only as a separately approved extension after a feed and sequencer-uptime feed are verified on the target chain |
| D2 | Add a guardian role with risk-reducing-only powers | **Yes** |
| D3 | Code-level delay on loosening | **No** for UHI11. The owner is fully trusted and should be a multisig or timelock operationally. Revisit together with a delay on every risk-increasing action. |
| D4 | Reject activation when `f_c < f_v` (in addition to `max` at exchange) | **Yes** |
| D9 | Hooks pre-check the vault floor inside `beforeSwap` | **No.** The vault is authoritative. Expose `effectiveFloorX96` and `requiredInput` for off-chain `quote()` only, which avoids an extra external call per swap. |
| D14 | Directional consistency | **Superseded:** enforce `F(a0)·F(a1) ≥ 2^192` (`PHASE1B_DECISIONS.md`) |

The decisions on authorization (D5–D8, D10–D13) are in `PHASE1B_CURATOR_AUTH.md` §13.
