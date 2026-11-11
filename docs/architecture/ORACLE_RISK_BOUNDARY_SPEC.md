# Porkfolio — Oracle Risk Boundary Specification (Phase 1B-4.2)

**Status: PROPOSED for review; production vault NOT changed.** This replaces the Phase 1B-4.1 vault proposal, whose
±25% static outer band was rejected. There is no static price band of any width in this design. Implemented in
isolation: `src/risk/VaultRiskBoundary.sol` (equations), `src/interfaces/IMarketRiskAdapter.sol`, and
`src/oracle/PriceRiskAdapter.sol` (read-only adapter). The vault integration exists only as a measured prototype in a
scratch copy: `docs/proposals/oracle-risk-boundary.patch`, not applied. Labels: PROVEN, TESTED, MEASURED, ESTIMATE,
ASSUMPTION.

## 1. What the vault enforces, independently of every hook

When a market-risk adapter is installed, each `exchange` applies, before any effect:

| Rule | Check | Fails as |
|---|---|---|
| R0 halt | the direction is not halted (guardian or owner) | `DirectionHalted` |
| R1 validity | `adapter.currentReference()` returns; it reverts on stale, missing, contradictory or sequencer-down data (§4) | the adapter's revert |
| R2 uncertainty breaker | `u <= maxUncertaintyPips` (vault parameter) | `UncertaintyTooHigh` |
| R3 directional floor | `amountIn >= ceil(amountOut * F / 2^96)` with `F = max(curator floor, F0 or F1)` | `PriceBelowFloor` |
| R4 inventory floor | `N_out - amountOut >= L_out` | `InventoryFloorBreached` |
| existing | allocation, consumer, curator status, expiry, quota, flow caps, pause | unchanged |

In adapter mode **the static vault floor is not consulted**, neither in `exchange` nor in `reserveFor`. Nothing
replaces it with a band. `setSellFloor` and its D14 rule are unchanged. They govern the vault only without an
adapter, and removing the adapter automatically closes every direction that lacks a D14-consistent static floor
(`PriceFloorNotConfigured`, existing code).

## 2. Equations and integer rounding

Units: `P` raw currency1 per raw currency0, Q64.96; `u`, `e`, `kappa` in pips (1e6 = 100%); `tau_a` raw units per
share, WAD; `S` total shares; `N_a = backing_a - claimableAssets_a`.

**Dynamic floors** (R3; `VaultRiskBoundary.dynamicFloors`):

```
w  = 1e6 + u + e
F0 = ceil(P * w / 1e6)                          minimum raw asset1 in per raw asset0 out (vault sells asset0)
F1 = ceil(ceil(2^192 / P) * w / 1e6)            minimum raw asset0 in per raw asset1 out (vault sells asset1)
fill check (existing vault code):  amountIn >= ceil(amountOut * F / 2^96)
```

Every step rounds up (toward the vault). PROVEN: `F0 * F1 >= 2^192 * (w / 1e6)^2`, so at every reference the floor pair
is D14-consistent by construction (`testFuzz_floorsConsistent`, `test_floors_are_d14_consistent_at_every_reference`).
TESTED: every price inside `P (1 +- (u + e))` is refused (`test_floors_refuse_every_price_inside_the_band`).

Example: `P = 2^96`, `u` = 4,532 pips, `e` = 0: selling 1,000 raw units of either asset needs at least
`ceil(1,004.532)` = 1,005 raw units in.

**Inventory floor** (R4; `VaultRiskBoundary.inventoryFloor`, `checkInventory`):

```
L_a = ceil(S * tau_a * (1e6 - kappa_a) / (1e18 * 1e6))
fill paying out x of asset a requires  N_a - x >= L_a           (inflows never limited)
```

No price enters. Example: 1,000,000 shares, `tau` = 1 WAD, `kappa` = 15%: `L` = 850,000.

**Capital-at-risk theorem** (PROVEN from R4; TESTED adversarially). Every outflow of asset `a` leaves `N_a >= L_a`;
inflows only raise `N_a`; in-kind LP deposits and redemptions multiply `N_a`, `S` and `L_a` by the same factor (up to
rounding). So after any sequence of fills, whatever the reference, the hooks or the adapter say,
`N_a >= min(N_a before, L_a)`. The value LPs can lose through trading is therefore

```
loss <= sum_a (N_a - L_a) * p_a          (p_a: true prices)
```

At the target composition that is `kappa` of the vault's value. An adversary who owns the reference extracts 96–99.97%
of this bound in the Python attack test, and never more (`test_malicious_reference_loss_is_bounded`). In the
simulated malicious-adapter world (price halved for a day), losses were −514 bps at `kappa` = 15% and −111 bps at
5%, against −1,030 bps with no inventory floor.

**Compatibility rule for hooks** (TESTED): every hook's own edge must be strictly greater than `e`, by at least 1 pip,
and its inventory cap must not exceed `kappa`. Otherwise the vault refuses some of the hook's quotes (never the
reverse: a mismatch causes refusals, not losses).

## 3. Parameters and who may change them

| Parameter | Lives in | Owner | Guardian | Delay |
|---|---|---|---|---|
| adapter (feeds, thresholds, staleness, sequencer, pair, decimals) | adapter, immutable | propose replacement or removal | cancel a pending change | **2 days** (LPs can exit; exits never depend on prices) |
| `e` (vault edge) | vault | any | raise only | none |
| `maxUncertaintyPips` | vault | any | lower only | none |
| `tau_a`, `kappa_a` | vault | any | same targets, lower `kappa` only | none (owner loosening is immediate, as for every existing vault limit: decision R-3) |
| hook pricing parameters (spread, depth, strategy fees) | each hook | hook owner | — | hook policy |

Installing an adapter requires that it prices exactly this vault's pair (`pair()` equals `asset0`, `asset1`) and that
it answers `currentReference()` at installation. The vault records the adapter's `configVersion` in the
`RiskAdapterSet` event.

**One adapter.** Hooks never hold an adapter address. They read it from the vault (`riskConfig()` /
`riskAdapter()`) in the same `beforeSwap` that calls `exchange`. The adapter can only change through
`executeRiskAdapter`, a separate transaction, so a hook and the vault always use the same adapter, configuration
version and feed answers within a swap. **Oracle configuration is separate from strategy:** the adapter holds only
market data rules; spreads, depths and fees stay in the hooks; the vault holds only its own safety bounds.

## 4. Feed-validation requirements (for any adapter the vault may install)

1. **Answers**: positive, below 2^128, `updatedAt` non-zero and not in the future; a revert or short return data from a
   feed reverts the read (`FeedUnusable`).
2. **Staleness**: per leg, heartbeat plus a stated grace (Chainlink 86,400 + 1,800 s; RedStone 21,600 / 10,800 +
   1,800 s on Unichain). A stale leg removes its source.
3. **Sources**: at least two live sources from **different providers**. The adapter cannot verify provider
   independence; governance must (§5 of `CORRELATED_ORACLE_FAILURES.md`: the two Chainlink USDC/USD proxies are one
   source).
4. **Agreement**: the sources' deviation brackets (threshold plus 1 bp latency margin per leg, both legs stacked for a
   cross pair) must intersect; the reference is the intersection's centre and `u` its half-width (`ReferenceBracket`).
5. **Sequencer**: Chainlink L2 sequencer uptime feed (Unichain `0x4956…F813`) up, and at least one hour since its last
   restart.
6. **Decimals**: read from each feed at construction; token decimals and the pair are constructor arguments checked
   against the vault at installation.
7. **Signed updates** (if ever added): the verifying contract's signer set, a maximum age measured against
   `block.timestamp` (not the payload's own claim), and a rule for **missing** payloads. An optional payload gives no
   protection against corrupted push feeds, because an attacker simply omits it (`FRESH_PRICE_EVALUATION.md` §4).

## 5. When market data is unavailable or contradictory

| Situation | Result |
|---|---|
| a leg stale, missing or malformed | its source is dropped; with fewer than 2 live sources every fill is refused |
| sources contradict (empty intersection) | every fill refused (`ReferenceDivergence`) |
| sources agree but the band is wide | fills refused above `maxUncertaintyPips`; below it, quotes widen with `u` |
| sequencer down / just restarted | every fill refused |
| adapter reverts or burns gas | the fill fails; nothing else changes |
| any of the above | LP deposits, redemptions, queue processing, claims, cancellations and releases are unaffected: they never read prices |

There is no fallback price anywhere. Trading resumes by itself when the data recovers. No operator action is
needed for routine trading.

## 6. Not covered

Pull-oracle verification (a credentialed dependency; not recommended as mandatory, see the evaluation). Rolling flow
windows: the existing fixed epochs allow up to two caps across a boundary, and the loss bounds account for it.
Value-based rather than unit-based inventory floors: these were rejected because they would make the backstop depend
on the price it must survive.
