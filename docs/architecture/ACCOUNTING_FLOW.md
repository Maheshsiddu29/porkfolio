# Accounting Flow — Milestone 0 (verified against pinned Uniswap v4)

Status labels used in this document:

- **VERIFIED**: read in pinned upstream source *and* exercised by a passing test in this repo.
- **SOURCE**: read in pinned upstream source; not separately tested here.
- **DESIGN**: a choice made in this repo, enforced in code and tested.
- **PROPOSAL**: not implemented; requires human review before Phase 1.

---

## 1. Pinned dependencies and compiler settings

| Component | Pin | How |
|---|---|---|
| v4-periphery | `c6e4754dab11bd38c6f08ac51c3c868569e93d64` | `lib/v4-periphery` git submodule |
| v4-core | `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc` (v4.0.0 + 12, 2025-05-13) | transitive submodule `lib/v4-periphery/lib/v4-core`, the exact commit periphery is built against. A single copy, so no version skew. |
| solmate (MockERC20, SafeTransferLib) | `4b47a19038b798b4a33d9749d25e570443520647` | transitive via v4-core |
| forge-std | `v1.9.7` / `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | `lib/forge-std` |
| OpenZeppelin | not used in M0 | available transitively (v4-core `lib/openzeppelin-contracts` @ `dbb6104c`, v5.0.0+12). Add a remapping when EIP-712 lands (Phase 1). |

Compiler: solc `0.8.26`, `evm_version = cancun` (PoolManager needs EIP-1153 transient storage), `via_ir = true`,
`optimizer_runs = 44444444`, `bytecode_hash = none`. These match v4-core's own `foundry.toml`, so the PoolManager under
test is built the way upstream builds it. Fuzz seed is fixed (`0x5eed`), so runs are deterministic.

Remappings: `@uniswap/v4-core/ → lib/v4-periphery/lib/v4-core/`, `@uniswap/v4-periphery/ → lib/v4-periphery/`.

Periphery note: at this commit `BaseHook` is no longer in `v4-periphery/src` (it moved to a separate hooks library).
We implement `IHooks` directly in `BaseCompatibleHook`. Periphery is pinned for Phase 1+ (`V4Router`, `HookMiner` in
`test/shared/`).

Paths below are relative to `lib/v4-periphery/lib/v4-core/src/`.

---

## 2. Upstream behaviour this design depends on

| # | Behaviour | Source | Status |
|---|---|---|---|
| U1 | `unlock()` sets the lock, calls `IUnlockCallback(msg.sender).unlockCallback(data)`, then reverts `CurrencyNotSettled` unless `NonzeroDeltaCount == 0`. Nested `unlock` reverts `AlreadyUnlocked`. | `PoolManager.sol:104-114` | VERIFIED (`test_incorrectSettlement_rollsBackVault`, `test_withdraw_cannotNestInsideUnlock`) |
| U2 | `mint(to, id, amount)` debits **msg.sender's** delta by `amount` and mints claims to `to`. Requires unlocked. | `PoolManager.sol:322-329` | VERIFIED |
| U3 | `burn(from, id, amount)` credits **msg.sender's** delta by `amount` and burns from `from`. `_burnFrom` requires `from == msg.sender`, operator, or allowance. | `PoolManager.sol:332-336`, `ERC6909Claims.sol:13-22` | VERIFIED (`test_maliciousHook_cannotBurnVaultClaims`) |
| U4 | ERC-6909 `transfer`/`transferFrom` are inherited unmodified. They are **not** lock-gated and do not touch deltas. `transferFrom` skips the allowance check for `isOperator[sender][msg.sender]`. | `ERC6909.sol:25-48`; no override in `PoolManager.sol` | VERIFIED (`test_maliciousHook_cannotTransferFromVault`) |
| U5 | `take` debits msg.sender and transfers ERC-20 out. `sync`+transfer+`settle` credits msg.sender by the observed balance increase. | `PoolManager.sol:279-302, 349-365` | VERIFIED (deposit/withdraw tests) |
| U6 | Deltas are per `(address, currency)`, held in transient storage. `NonzeroDeltaCount` tracks how many are non-zero. Deltas **cannot** be moved between addresses except by real settle/take/mint/burn. | `PoolManager.sol:368-378`, `CurrencyDelta.sol`, `NonzeroDeltaCount.sol` | SOURCE |
| U7 | `beforeSwap`: if the hook has `BEFORE_SWAP_RETURNS_DELTA_FLAG`, `amountToSwap = amountSpecified + deltaSpecified`. It reverts `HookDeltaExceedsSwapAmount` if exact-in/out flips. | `Hooks.sol:248-282` | VERIFIED |
| U8 | `afterSwap`: hookDelta = `(spec, unspec)` mapped to `(amount0, amount1)` when `(amountSpecified < 0) == zeroForOne`, else swapped. Caller's delta = `swapDelta − hookDelta`. | `Hooks.sol:285-315` | VERIFIED (both directions) |
| U9 | PoolManager credits hookDelta to the **hook address** and swapDelta to the **caller**. | `PoolManager.sol:220-226` | VERIFIED (`BatchSwapRouter` asserts hook delta = 0) |
| U10 | `Pool.swap` returns a zero delta when `amountSpecified == 0`, **before** the `sqrtPriceLimitX96` checks. | `libraries/Pool.sol:320` | VERIFIED (`test_priceLimitIsNotEnforcedForFullyInterceptedSwaps`) |
| U11 | `BeforeSwapDelta` packs specified in the upper 128 bits and unspecified in the lower 128 bits. Hook return data must be exactly 96 bytes. | `types/BeforeSwapDelta.sol:9-37`, `Hooks.sol:259` | SOURCE |
| U12 | Hook permissions = the low 14 bits of the hook address. `*_RETURNS_DELTA` requires the matching base flag. `validateHookPermissions` requires an exact match. | `Hooks.sol:27-47, 83-127` | VERIFIED (constructor validation and flag-encoded deploys) |
| U13 | Hook reverts are wrapped as `WrappedError(hook, selector, reason, HookCallFailed)`. | `Hooks.sol:131-137`, `CustomRevert.sol` | VERIFIED (every negative swap test matches the exact wrapped error) |
| U14 | A dynamic-fee override from `beforeSwap` is honoured only if `key.fee.isDynamicFee()`. | `Hooks.sol:263` | SOURCE |
| U15 | Hooks are not called back for actions the hook itself initiates (`msg.sender == hook`). | `Hooks.sol:171-175, 253, 293` | SOURCE |

**CREATE2 / address mining:** the hook address must carry exactly the permission bits. Tests place hooks at
flag-encoded addresses with `deployCodeTo`. A real deployment must mine a CREATE2 salt (periphery
`test/shared/HookMiner.sol`). That is not exercised in M0.

---

## 3. The settlement mechanism, and why it is this one

### 3.1 What does *not* work

1. **Vault burns its own claims for the hook.** `burn` credits `msg.sender` (U3), so the +Y lands on the **vault's**
   delta. The return delta charges −Y to the **hook** (U9). Deltas do not net across addresses (U6), so `unlock`
   reverts `CurrencyNotSettled`.
2. **Hook burns vault claims directly.** This needs operator status or an allowance from the vault (U3). That is exactly
   the blanket grant the constraints forbid. It is shown to revert in `test_maliciousHook_cannotBurnVaultClaims`.
3. **Hook mints input to the vault and the vault "checks its balance went up".** Anyone can donate claims to the vault
   (U4), so a balance check cannot attribute the input to the current swap.

### 3.2 What we do: atomic claim-for-claim exchange (DESIGN)

The hook's constructor calls `poolManager.setOperator(vault, true)`. The **vault becomes operator over the hook's**
claims. The vault never grants anything to anyone. The hook holds claims only transiently, inside one `beforeSwap`.

Exact input, `zeroForOne`, X = amount in, Y = quoted amount out:

```
Router ──unlock──▶ PoolManager ──unlockCallback──▶ Router
Router ──swap(key, amountSpecified = −X, hookData = allocationId)──▶ PoolManager
  PoolManager ──beforeSwap──▶ Hook
    Hook: Y = _quote(...)                          (strategy-specific; reads allocation state from the vault)
    Hook ──mint(hook, c0, X)──▶ PM                 δ[hook,c0] = −X     claims[hook,c0] = X
    Hook ──exchange(key, zfo, id, X, Y)──▶ Vault
      Vault: checks (consumer, pool, direction, expiry, quota, price floor, pause), updates accounting
      Vault ──transferFrom(hook→vault, c0, X)──▶ PM   claims[hook,c0] = 0, claims[vault,c0] += X
      Vault ──transfer(vault→hook, c1, Y)──▶ PM       claims[vault,c1] −= Y, claims[hook,c1] = Y
    Hook ──burn(hook, c1, Y)──▶ PM                 δ[hook,c1] = +Y     claims[hook,c1] = 0
    Hook returns BeforeSwapDelta(+X, −Y)
  PoolManager: amountToSwap = −X + X = 0 → Pool.swap returns ZERO_DELTA   (U10)
  PoolManager: hookDelta = (+X, −Y) → δ[hook] = (0, 0)                    (U8, U9)
               callerDelta = (0,0) − (+X, −Y) = (−X, +Y) → δ[router] = (−X, +Y)
Router: sync(c0); ERC-20 transfer X → PM; settle()   δ[router,c0] = 0
Router: take(c1, trader, Y)                          δ[router,c1] = 0
PoolManager: NonzeroDeltaCount == 0 → lock            (U1)
```

The vault **pulls input before it pushes output, in the same call**. A hook that did not fund X makes `transferFrom`
underflow, and the whole transaction reverts (`test_maliciousHook_cannotTakeOutputWithoutFundingInput`). So even a
compromised whitelisted hook cannot take output without paying input.

### 3.3 Delta and balance ledger (numbers from `test_happyPath_hookA_zeroForOne`)

X = 1000e18, Y = 999.275e18 (Hook A fee 0.725e18: the pool's flow level moves from 0 to 1,000 with K = 10,000,
so the fee is 1,000 × 0.05% + 0.45% × 1,000² / (2 × 10,000) = 0.5 + 0.225; Phase 1B-3 cumulative pricing).

| Step | δ hook c0 | δ hook c1 | δ router c0 | δ router c1 | vault claims c0 | vault claims c1 |
|---|---|---|---|---|---|---|
| start | 0 | 0 | 0 | 0 | 1,000,000 | 1,000,000 |
| hook `mint` | −X | 0 | 0 | 0 | 1,000,000 | 1,000,000 |
| vault `exchange` | −X | 0 | 0 | 0 | 1,001,000 | 999,000.725 |
| hook `burn` | −X | +Y | 0 | 0 | 1,001,000 | 999,000.725 |
| PM applies hookDelta (+X, −Y) | 0 | 0 | 0 | 0 | — | — |
| PM applies callerDelta (−X, +Y) | 0 | 0 | −X | +Y | — | — |
| router settle c0 / take c1 | 0 | 0 | 0 | 0 | 1,001,000 | 999,000.725 |

End state per currency: PoolManager ERC-20 balance change = vault ERC-6909 claim change (c0: +X / +X, c1: −Y / −Y).
The swapper's PoolManager delta is exactly (−X, +Y). This is asserted in the happy-path and fuzz tests.

`BatchSwapRouter` (test-only) asserts `currencyDelta(hook) == 0` and `currencyDelta(vault) == 0` after **every** swap.
It records `NonzeroDeltaCount == 0` after settlement (`test_sameTx_twoHooks_deltasReconcile`).

### 3.4 Funding and withdrawal paths (DESIGN, VERIFIED)

- `deposit`: vault `unlock` → `sync(c)` → ERC-20 `transferFrom(owner → PM)` → `settle()` (+amount to the vault, and
  `paid == amount` is required, so fee-on-transfer tokens fail closed) → `mint(vault, c, amount)` (−amount). Net zero.
  The claims are backed by ERC-20 actually held by the PoolManager (`test_deposit_mintsRealClaimsBackedByErc20`).
- `withdraw`: vault `unlock` → `burn(vault, c, amount)` (+amount) → `take(c, to, amount)` (−amount). Net zero.

---

## 4. Custody and authorisation model

| Actor | Can move vault claims? | How bounded |
|---|---|---|
| Vault owner | Withdraw **free** backing only (`backing − reserved`); can pause; can emergency-release allocations | `onlyOwner` |
| Curator | No direct movement. Can reserve capacity for a registered consumer on one pool/currency | per-curator per-currency ceiling, `R + ΣQ + newQ ≤ C`, nonce, deadline, 30-day horizon |
| Registered hook | Only through `vault.exchange`, for an allocation bound to **its own address, this pool id, this direction**, before expiry | quota (`maxOut − consumed`), price floor `minInPerOutX96`, pause, revocation |
| Anyone else / any EOA | None | `ConsumerNotRegistered` |
| Anyone (lazy expiry) | `release` an expired allocation, which returns capacity to free backing | only after `expiry` |

The vault never calls `setOperator` or `approve` (`test_noOperatorOrAllowanceOverVaultClaims`, plus an invariant
checked after every fuzzed step).

**Trust assumption (explicit):** a registered hook prices trades. A malicious or buggy registered hook can sell up to an
allocation's remaining quota at the curator's floor price `minInPerOutX96`, and no worse. That is the bounded loss per
allocation. Hook registration is an owner decision and is not proof that the hook is benign.

---

## 5. What happens to native concentrated-liquidity execution

When the hook consumes the full specified amount (`amountToSwap == 0`):

1. The CL curve is **not executed**. Pool `sqrtPriceX96`, tick and liquidity do not change (VERIFIED,
   `test_nativeCurveNotExecuted_poolStateUnchanged`).
2. **`sqrtPriceLimitX96` is ignored** (U10). Slippage protection must come from the router's minimum-output check
   (VERIFIED, `test_minOut_violation_rollsBack`).
3. The **pool LP fee and the protocol fee are not charged**: `amountToProtocol = 0` when amount is 0 (SOURCE). A
   dynamic-fee override (`OVERRIDE_FEE_FLAG`) therefore has **no effect** on intercepted volume. HookA's "dynamic fee"
   is implemented inside its custom curve.
4. PoolManager still emits `Swap(id, sender, 0, 0, ...)` (`PoolManager.sol:241`). Indexers that read `Swap` amounts will
   see zero volume. The hook emits `SharedLiquiditySwap` with the real amounts.
5. Native liquidity added to these pools could never trade, so `beforeAddLiquidity` reverts
   (`test_nativeLiquidityAdd_isRejected`).
6. Exact-output swaps are rejected in M0 (`ExactOutputNotSupported`).

---

## 6. Solvency and liability model

> **Phase 1A update.** This section describes the Milestone-0 single-funder model.
>
> - **Superseded:** the multi-LP share model, two-tier redemption, and the protection of pending and claimable
>   redemptions from new allocations. These are specified in `SHARE_ACCOUNTING.md`.
> - **What changed:**
>   - `F_a` is now `B_a − W_a − Q_a`.
>   - The owner withdrawal path no longer exists.
>   - `R_a` is an admission floor only (approved decision 5).
>   - The open question at the end of §6.4 is resolved: queued liabilities are protected by `D_a` in the admission
>     rule.

### 6.1 Terms (per currency `a`)

| Symbol | Meaning | On-chain |
|---|---|---|
| `P_a` | Physical claims: `PoolManager.balanceOf(vault, a)` | upstream |
| `C_a` | Accounted backing | `backing[a]` |
| `Q_j,a` | Remaining capacity of unreleased allocation j: `maxOut_j − consumed_j` | `_allocations[j]` |
| `ΣQ_a` | Reserved capacity: sum of `Q_j,a` over unreleased allocations, **including expired-but-unreleased ones** | `reserved[a]` |
| `R_a` | Buffer floor that new allocations must leave unreserved | `bufferFloor[a]` |
| `K_j` | Already consumed by j (paid out, and replaced by the input asset) | `consumed_j` |
| `F_a` | Free (withdrawable now) = `C_a − ΣQ_a` | `freeBacking(a)` |

### 6.2 Enforced and tested inequalities

| ID | Inequality | When | Evidence |
|---|---|---|---|
| I1 | `C_a = P_a` (no phantom or missing claims; donations are ignored) | always | invariant `invariant_backingEqualsRealClaims` |
| I2 | `C_a` = deposits − withdrawals + Σ inputs received − Σ outputs paid | always | invariant `invariant_ghostLedgerConservation` |
| I3 | `ΣQ_a = Σ_j (maxOut_j − consumed_j)` over unreleased j; `consumed_j ≤ maxOut_j` | always | invariant `invariant_reservedIsExactAndBacked` |
| I4 | `ΣQ_a ≤ C_a` | always | same invariant |
| I5 | `R_a + ΣQ_a ≤ C_a` | **at admission only** | `test_insufficientBacking_singleAndAggregate` |
| I6 | Per exchange: `amountOut ≤ Q_j,a` and `amountIn ≥ ⌈amountOut · minInPerOut⌉` | each exchange | quota, floor and malicious-hook tests |
| I7 | Hooks hold zero claims between transactions; no operator rights over the vault | always | invariant `invariant_custodyAndSolvency` |

I5 is **not** maintained after admission. The owner may withdraw down to `ΣQ_a`, which eats into `R_a`. In M0 the
owner *is* the only LP, and `R_a` is the LP-exit buffer. Phase 1 must decide whether `R_a` is a hard floor on
withdrawals too.

### 6.3 Why `R + ΣQ ≤ C` does not give unconditional exit (RISKS R1). VERIFIED.

`test_R1_reserveConditionDoesNotGrantFullExit`: C = 1,000,000, ΣQ = 800,000. A 1,000,000 withdrawal reverts with
`InsufficientFreeBacking(1_000_000, 200_000)`. After expiry it **still** reverts until someone calls `release`. Expiry
is lazy, because contracts do not run when time passes.

### 6.4 The queued-withdrawal problem, and the proposed correction (PROPOSAL)

`test_consumptionChangesAssetComposition` shows the issue the brief raised. Once Q is consumed, token1 has been
**exchanged** for token0. Expiry releases only the *unused* `Q − K`. It cannot return the token1 that was sold. A
queued withdrawal denominated "100 token1, payable at expiry" is therefore not guaranteed by expiry alone.

**Smallest defensible correction (for review):** denominate LP liabilities as **shares of the whole multi-asset
portfolio**, not as nominal amounts of one asset.

- Shares `s_i`, total `S`. LP i's claim is the fraction `s_i / S` of **every** currency's `C_a`.
- **Tier 1 (immediate):** redeem fraction φ of one's shares for `φ · (s_i/S) · F_a` in each currency `a`, paid in kind.
  This is always feasible, because it only touches free backing.
- **Tier 2 (queued):** the remaining fraction is locked. It becomes payable in kind, pro rata over `C_a` of every
  currency, once the allocations that covered it are released. The bounded-horizon statement that *can* be proven is:
  *the in-kind share fraction is redeemable no later than max(expiry of live allocations) + the time for someone to
  call `release`*. The **nominal value** of that fraction is not guaranteed, because consumption changes the asset mix
  at hook-quoted prices bounded below by each allocation's floor.
- What remains open: whether queued LPs must be ring-fenced from **new** allocations admitted after they queue. If not,
  the horizon is unbounded. The fix is to have `allocate` treat queued liabilities like `R_a` in I5.

This keeps the blueprint's two-tier architecture. It changes what is promised: an in-kind share fraction by a bounded
time, rather than a nominal amount. That is a material product-semantics change, so it needs a human decision before
Phase 1.

---

## 7. Blueprint assumptions that require correction

| Blueprint claim | Finding | Correction |
|---|---|---|
| `R_a` "guarantees unconditional LP exit rights" (§3.1) | False. See 6.3 (R1), and 6.4 for multi-asset. | Exit = free backing now, plus an in-kind share fraction after release. See 6.4. |
| "Expired commitments release automatically in O(1) at block timestamp transition without keepers" (§3.1) | Contracts do not execute when time passes. VERIFIED by `test_lazyRelease`. | Lazy release on the next interaction (`release` is permissionless after expiry). A ring buffer can make *aggregate* reconciliation O(1) per touched bucket, but someone must still transact. |
| Tier 1 "guaranteed execution" (§3.1) | Only **capacity** is reserved. Inclusion, hook pricing, the price floor, revocation and pause can all still stop a trade. | Say "reserved capacity", not "guaranteed execution". |
| Tier 3 surge via `LPFeeLibrary.OVERRIDE_FEE_FLAG` (§3.1) | A no-op for fully intercepted swaps (section 5, item 3) and only valid on dynamic-fee pools (U14). | Put fees inside the hook curve (HookA does). Use the LP-fee override only for the native-curve remainder of partial interception. |
| "Inject bounded shared liquidity" through `beforeSwapReturnDelta` (§2.2) | The return delta only re-attributes this swap's deltas between hook and caller. Liquidity must be real ERC-6909 claims moved by the vault. | The section 3.2 mechanism. |
| Hooks "verify the signature … inside beforeSwap via hookData … with zero trusted keeper" (§3.2) | A signature proves authority. Someone must still submit the transaction (RISKS R7). | M0 uses on-chain curator submission with nonce and deadline. EIP-712 adds a relayable path, not keeper-freedom. |
| "ICommitmentConsumer mixin any independent hook can inherit" (§2.2) | Inheriting does not make a hook trustworthy. | Owner whitelist, plus per-allocation quota and price floor bound the loss (section 4). |
| Quantitative claims (+70% utilisation, 17% APY, $426k/yr, 50% ceiling) | No evidence was produced or checked in M0. | Treat as hypotheses until there are simulations with stated provenance. |
| $50-capped Unichain mainnet deployment (Phase 4) | Out of scope. Real funds would be at risk regardless of the cap (RISKS R12). | Requires a separate human safety gate. |

---

## 8. Supported and unsupported paths in M0

| Path | Status |
|---|---|
| Exact-input, zeroForOne and oneForZero, HookA and HookB | Supported and tested |
| Exact-output | Rejected (`ExactOutputNotSupported`) |
| Partial interception (hook supplies part, CL curve the rest) | Not implemented |
| Native ETH | Rejected (`NativeCurrencyUnsupported`) |
| Fee-on-transfer / rebasing ERC-20 | Deposit fails closed (`SettlementMismatch`). Not otherwise analysed. |
| Multi-LP shares, queued withdrawals, ERC-4626 | Not implemented (section 6.4 proposal) |
| EIP-712 signed allocations, ring buffer, curator performance or HWM | Not implemented (Phase 1+) |
| Unreserved "Tier 2 spillover" consumption | Not implemented. Hooks can consume reserved allocations only. |
