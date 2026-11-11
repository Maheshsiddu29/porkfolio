# Porkfolio — Deterministic Quote Interface (FastPath contract)

**Status: PROPOSED, not implemented. Version 2 for the shared core and the price-risk adapter is in
`SHARED_ECONOMIC_CORE_SPEC.md` §6 (Phase 1B-4.1); this document remains the base.** This defines what an off-chain quoter must compute so that its answer equals the
on-chain settlement to the last raw unit. It is the contract the future FastPath service must meet. FastPath itself
(caching, Redis, a quote server) is out of scope and not built here.

**Hard rule.** The off-chain path is optional. A direct swap through the PoolManager computes the same quote on-chain
from on-chain state and never depends on any server being reachable.

## 1. Three implementations, one function

| Implementation | Role | Status |
|---|---|---|
| Solidity pricing core | authoritative settlement inside `beforeSwap` | milestone M1/M3 |
| Python (`simulations/mm/model.py`) | reference for analysis and conformance | done (this phase) |
| Rust or TypeScript quoter | low-latency quotes for routers and the dashboard | milestone M6 |

All three take the same **snapshot** (§3) and **request** (§2) and return the same **result** (§4), integer for integer,
including the refusal reason. Conformance is checked against `simulations/mm/vectors/inventory_quote_v1.json`
(format `porkfolio.inventory-quote.vectors/1`: 212 quote cases including 97 refusals, and 6 reference cases;
integers as decimal strings). M1 adds the same vectors as a generated Solidity file, the approach `PricingVectors.sol`
already uses, so `ffi` and file-system permissions stay as they are.

## 2. Request

| Field | Type | Meaning |
|---|---|---|
| `chainId` | uint256 | chain the quote is for |
| `poolManager` | address | v4 PoolManager |
| `poolKey` | (currency0, currency1, fee, tickSpacing, hooks) | identifies pool and hook; `poolId = keccak256(poolKey)` |
| `zeroForOne` | bool | true: trader sells currency0 |
| `amountIn` | uint256 | exact input, raw units, ≤ 2^127 − 1 |
| `slippagePips` | uint32 | caller's tolerance, used only to derive `minAmountOut` |

Exact output is not supported, as on-chain.

## 3. Snapshot (everything the quote depends on)

Read at **one block**, with an `eth_call` at a fixed block tag or a single view that returns all fields. Mixing blocks is
the main way an off-chain quote diverges from settlement.

| Group | Fields | On-chain source |
|---|---|---|
| block | `blockNumber`, `timestamp` | header |
| vault | `n0 = backing(c0) − claimableAssets(c0)`, `n1` likewise, `shares = totalShares()` | vault getters |
| reference | primary `(answer, roundId, updatedAt, decimals)`, secondary the same, primary history `(price, updatedAt)` for the last `k` rounds | feed getters |
| configuration | `τ, v, V_max, h_base, h_min, h_max, δ_max`, reference policy, feed addresses, hook spread policy | hook getters |
| vault rules (to predict refusals) | sell floors and halts, allocation `(maxOut, consumed, expiry, direction, curator restriction)`, flow usage and caps of the three scopes, `paused` | vault getters / `VaultLens` |

**Versions.**

```
configVersion = keccak256(abi.encode(all configuration fields, feed addresses))
stateVersion  = keccak256(abi.encode(chainId, hook, poolId, n0, n1, shares,
                                     primary.roundId, secondary.roundId, configVersion))
```

`stateVersion` changes whenever any input to the pricing function changes: any swap through any hook on the reserve,
any LP deposit, redemption or finalization, any new reference round, any configuration change. It does not include
the timestamp. With `age_widen = 0` (the calibrated setting) the quote does not depend on time except through the
staleness limit, and that limit is captured by `validUntil`.

## 4. Result

| Field | Meaning |
|---|---|
| `status` | `OK` or `REFUSED` |
| `reason` | 0 none; pricing: 1 `ZeroInput`, 2 `AmountTooLarge`, 3 `ReferenceUnavailable`, 4 `StaleReference`, 5 `ReferenceDivergence`, 6 `SecondaryUnavailable`, 7 `SpreadTooWide`, 8 `NoDepth`, 9 `InventoryLimit`, 10 `ZeroOutput`; predicted vault refusals: 20 `PriceBelowFloor`, 21 `QuotaExceeded`, 22 `FlowLimitExceeded`, 23 `DirectionHalted`, 24 `Paused`, 25 `NoUsableAllocation`, 26 `CuratorRestricted` |
| `amountOut` | raw output, rounded as in `INVENTORY_PRICING_SPEC.md` §6 |
| `minAmountOut` | `floor(amountOut · (10^6 − slippagePips) / 10^6)` |
| `mid`, `uncertaintyPips`, `halfSpreadPips` | the resolved reference and spread |
| `inventoryBefore`, `inventoryAfter`, `cap`, `depth` | pricing state, for display and audit |
| `allocationId` | a usable allocation: this hook, pool and direction, unexpired, unrestricted curator, `maxOut − consumed ≥ amountOut` |
| `stateVersion`, `blockNumber` | the snapshot the quote is valid for |
| `validUntil` | `min(primary.updatedAt + max_age, allocation.expiry − 1)` and, if set, the secondary's age limit (timestamps) |
| `hookData` | `abi.encode(allocationId, minAmountOut)`, the existing 64-byte form, so no new swap format is needed |

The pricing reasons (1–10) are exact: they are the function's own refusals. The vault reasons (20–26) are a
**prediction**: the vault re-checks everything at execution, and only its answer counts.

## 5. Validity, concurrency and ordering

- A quote is **exact** for its `stateVersion`. Settlement on a different state gives a different amount. The swap
  still succeeds whenever the new amount is at least `minAmountOut` and the vault accepts it.
- **Concurrent swaps.** Two quotes for the same snapshot are both exact only for whichever executes first. The
  second executes against the first's inventory change; the straddle bound guarantees that its price stays on the
  vault's side of the reference, and `minAmountOut` bounds what the trader accepts. No quote reserves inventory.
- **Block ordering.** Unichain block builders order transactions; the quoter cannot know the order. A quoter that sees
  pending state (for example flashblocks) may quote against it, but must report that `blockNumber` and must not
  claim finality.
- **Invalidation.** Re-quote when `stateVersion` changes, when `timestamp > validUntil`, or when the chosen allocation
  no longer has room. A cache keyed by `(poolId, zeroForOne, amountIn, stateVersion)` is always exact. A cache keyed
  without `stateVersion` is not.
- **No strict-version swaps.** A `hookData` variant that reverts unless `stateVersion` is unchanged was considered and
  rejected. It would turn every concurrent swap into a refusal, and `minAmountOut` already protects the trader.

## 6. Failure independence

If the quoter is down, routers call the hook's on-chain `quote` view (same code, same refusals) or simply swap with
their own `minAmountOut`. If the quoter is wrong, the swap settles at the on-chain price or reverts on `minAmountOut`.
In neither case can the quoter move funds, set a price, or bypass a vault rule. The quoter holds no keys.

## 7. What this interface does not include

RFQ signatures, intent auctions, reserving inventory for a quote, and any server-side price input. Each of these
would add trust (see candidate D in `MARKET_MAKING_CANDIDATES.md`) and needs its own decision.
