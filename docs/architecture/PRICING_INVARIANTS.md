# Porkfolio — Pricing Invariants

**Status: PROPOSED for review (Phase 1B-4).** These are the guarantees any pricing architecture must preserve. Each
one is classified:

- **V (vault-enforced)** — holds whatever any hook does; the hook cannot weaken it. Evidence is the existing vault
  test suite and invariant campaign.
- **M (mathematical, hook)** — a property of the pricing function that follows from its definition in exact integers;
  proven in `INVENTORY_PRICING_SPEC.md` and checked by `simulations/mm/test_mm.py`. It holds only for hooks that
  implement the function honestly; the vault does not run the pricing.
- **E (empirical)** — measured in synthetic worlds; true under the stated assumptions, not in general.

Execution is never promised. Every invariant below is compatible with refusing a trade, and several require it.

## 1. Custody and settlement (unchanged by any pricing rule)

| ID | Invariant | Class | Evidence |
|---|---|---|---|
| I-1 | A swap can only spend unreserved-for-it capacity: `amountOut ≤ maxOut − consumed` of a live allocation; `Q_a + W_a ≤ B_a`; claimable redemption assets `W_a` and queued demand `D_a` are never paid to a hook. | V | `exchange`, `reserveFor`; `VaultInvariants.t.sol` |
| I-2 | Pricing never overrides vault risk enforcement: floor, quota, expiry, direction, flow caps, exposure caps, pause, halts and curator restrictions are checked by the vault on the exact amounts moved. | V | `exchange`; `PricePolicy.t.sol`, `FlowLimits.t.sol`, `ExposureCaps.t.sol` |
| I-3 | Settlement is atomic: input claims arrive before output leaves; any failure (hook, vault, PoolManager settlement, swapper payment) reverts everything. | V | `BaseCompatibleHook`, `SharedLiquiditySwap.t.sol` |
| I-4 | Authorization cannot be bypassed: only the installed module creates allocations; only the named registered consumer consumes them; the pool and direction must match. | V | `CuratorAuthorization.t.sol`, `AuthModuleLifecycle.t.sol` |
| I-5 | Every successful swap meets `amountIn · 2^96 ≥ amountOut · max(vault floor, curator floor)`. | V | `exchange`; `PricePolicy.t.sol` |
| I-6 | Failed swaps do not change persistent pricing state. Hook state is written after `exchange` returns, in the same call; a revert anywhere undoes it. A pricing rule whose state *is* vault inventory (candidate C) has no separate state to leave behind. | V + M | `test_HBP_failedSwapsLeaveStateUnchanged`; structural for C |
| I-7 | Opposite-direction trading cannot bypass aggregate risk limits: flow usage is gross output, never netted against inflows. | V | `FlowLimits.t.sol` |

## 2. Pricing (hook properties; they bind honest hooks only)

| ID | Invariant | Class | Holds today (Hook B) | Holds for C |
|---|---|---|---|---|
| P-1 | **Split resistance.** At fixed state and reference with no elapsed time, any partition of a trade into pieces pays at least the single trade; the loss from splitting is bounded by a few raw units per piece. | M | yes (per pool) | yes, **across all hooks sharing the reserve** (state is the vault's inventory) |
| P-2 | **Path cost.** For a fixed reference, any sequence of trades moving inventory from `a` to `b` costs the potential difference plus the spread on its total variation: detours and zig-zags never beat the direct path. | M | no spread: zig-zags cost zero beyond rounding | yes (`test_cycles_at_fixed_reference_always_lose`) |
| P-3 | **Straddle.** At a fixed reference `M`, every accepted trade is on the vault's side of `M` by at least `h_min`: the vault never buys currency1 above `M(1 − h_min)` or sells it below `M(1 + h_min)`, whatever the state, parameters, hook, curator or allocation. Consequence: any closed cycle at fixed `M` loses at least `2·h_min` of the volume it moves, and floors pivoted at `M` accept every quote. | M | **no** (the reverse leg is above `M`) | yes (`StraddleTheorem` tests) |
| P-4 | **No reset.** Pricing state cannot be reset by changing allocation, curator, transaction, block, or by waiting. | M | allocation/curator/transaction: yes; **waiting resets it** (decay) | yes: no decay; LP flows scale state and depth together (`test_lp_flows_do_not_move_the_price`) |
| P-5 | **Shared reserve.** Hooks drawing on the same reserve must not price as if each had its own inventory. | M (design) | **no**: per-hook `x` lets flow through two hooks double the exposure (`test_per_hook_state_lets_flow_through_two_hooks_double_the_vault_exposure`) | yes |
| P-6 | **Units and rounding.** Every quote is computed in raw units with explicit rounding; every rounding favours the vault; a quote that rounds to zero output is refused, never paid. Token decimals enter only through the raw price. | M | yes | yes, including 6/18-decimal pairs (`test_mixed_decimals_usdc_weth`) and dust (`test_dust_trades_also_straddle`) |
| P-7 | **No implicit price.** Missing, stale, future-dated or mutually inconsistent reference data refuses the quote; it never falls back to a stored or default price. | M | n/a (no reference input) | yes (`ReferenceFailClosed`) |
| P-8 | **Inventory-reducing trades are considered.** A trade that reduces the real imbalance is never refused because of the pricing state alone; it is refused only by the reference policy, the spread limit or a vault rule. | M | **no** (root cause) | yes (`test_inward_trades_from_beyond_the_cap_are_priced_and_straddle`) |
| P-9 | **Bounded inventory.** Inventory-increasing trades stop at a governance cap on `|N_1 − T_1|`, wherever the vault's imbalance came from. | M | cap is on `x`, not on inventory | yes |

## 3. Economic properties (empirical)

| ID | Property | Class | Where measured |
|---|---|---|---|
| E-1 | LP mark-to-market against holding the seeding basket is not negative in the median of any regime, including trend, jump and volatile regimes. | E | `PHASE1B4_REPORT.md` §5 |
| E-2 | Arbitrage revenue against the vault (trades that beat the true market) is close to zero when the reference is fresh. Arbitrage that comes from a stale reference is market arbitrage; arbitrage that comes from inconsistent quoting would be mechanical. P-3 excludes the mechanical kind at a fixed reference. | E | same |
| E-3 | LP withdrawals are serviced at least as well as today under one-sided flow. | E | same |

## 4. What no pricing rule can guarantee

- **Execution.** Underfunded, mispriced, unauthorised or out-of-limit trades are refused.
- **A correct market price.** The reference can be wrong. P-7 limits the damage from missing or inconsistent data.
  A coordinated corruption of every source is bounded only by the vault's floors, flow caps, exposure caps and halts.
- **LP profit.** Adverse selection from better-informed traders is a market cost; a spread prices it, nothing removes
  it.
- **Honest hooks.** The vault does not evaluate hook pricing. P-1 to P-9 are properties of the hooks Porkfolio ships;
  I-1 to I-7 are what bounds a dishonest hook.
