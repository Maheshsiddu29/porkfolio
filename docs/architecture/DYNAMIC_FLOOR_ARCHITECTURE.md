# Porkfolio — Dynamic Floor Architecture (Phase 1B-4.1)

**Status: SUPERSEDED by `ORACLE_RISK_BOUNDARY_SPEC.md` (Phase 1B-4.2).** The owner rejected the ±25% static outer band proposed below; the comparison of approaches A–C in §2 still stands, and `docs/proposals/vault-dynamic-floor.patch` is kept as evidence only. Original status: **DECISION PROPOSED; vault change NOT IMPLEMENTED.** The selected architecture changes the vault's trust
boundary (a new external price input), its storage layout (four appended slots) and one financial invariant (the D14
floor rule while a dynamic floor is active). Per the operating rules it is presented as a complete proposal and
stopped before any change to `src/SharedCommitmentVault.sol`. The exact change is
`docs/proposals/vault-dynamic-floor.patch`. It was applied, compiled and tested only in a scratch copy outside the
repository; `git apply --check` confirms it applies cleanly to this branch. Labels: SOURCE, MEASURED (production
compiler settings, named command), ESTIMATE.

## 1. The problem being solved

D14 floors can only be a single pivot (`PHASE1B4_ROOT_CAUSE.md`). A pivot fixed by governance makes any two-sided
quote one-sided once the market moves. In Phase 1B-4 static floors cut candidate C's fill rate from 34.3% to 4.7%. An
owner-operated runbook that moves the pivot was rejected by the owner. The floor therefore has to follow the market
automatically. It must also stay an **independent** protection: no hook may declare a price safe on its own.

## 2. The three approaches

**A. Vault-side dynamic floor with its own reference logic.** The vault reads the feeds itself, validates them, builds a
reference and refuses trades inside its band.

**B. A restricted read-only price-risk adapter shared by the hooks and the vault.** One immutable contract
(`src/oracle/PriceRiskAdapter.sol`) turns the feeds into `(mid, uncertainty)` or refuses. The hooks quote from it and
the vault independently checks every fill against it, in the same transaction, with its own floor arithmetic.

**C. Automated, tightly bounded floor updates.** A keeper contract with a new vault role pushes the D14 pivot toward
the reference, by bounded steps, subject to freshness checks.

| Question | A. Vault-side logic | **B. Shared read-only adapter + vault check (selected)** | C. Bounded floor updates |
|---|---|---|---|
| Authoritative for the market safety boundary | vault | **vault** (it computes and enforces the dynamic floor; the adapter only supplies `(mid, u)`) | vault floors, as written by the keeper |
| Who controls oracle configuration | vault owner, through vault setters | **nobody after deployment**: the adapter is immutable; replacing it is a vault-owner proposal with a 2-day delay that the guardian may cancel | keeper deployer or owner |
| Can the owner bypass the boundary? | yes, at once, by changing feeds | **only by replacing the adapter, after 2 days in public**; LPs can exit in that window (exits never depend on prices) and the guardian can cancel | yes, by changing the keeper or its bounds |
| Can a curator bypass it? | no | **no** (curator floors can only be stricter) | no |
| Can a hook bypass it? | no | **no**: the vault recomputes from the adapter; nothing the hook passes is used | no |
| Hook and vault use compatible data in one transaction | only if the hook duplicates the vault's logic exactly | **yes by construction**: both call the same view; push feeds cannot change inside a transaction (only their transmitters write, in other transactions) | **no**: the hook prices from the live reference, the vault from the last keeper write |
| Feed updates between transactions | handled on each read | **handled on each read**: every swap sees the latest answers | floors lag until the next keeper transaction |
| Directional floor inequality | must be re-derived in the vault | **by construction**: `F_sell0 * F_sell1 >= 2^192 * (1 + u + e)^2 >= 2^192` at every reference | the keeper must keep D14 at every step, ordering raise before lower |
| Guardian | must be extended to oracle settings | **unchanged powers plus**: cancel a pending adapter change, raise the dynamic edge, raise static floors, halt, pause | needs a rule for the keeper role |
| How long a stale price stays usable | per vault configuration | **per source: heartbeat + 30 min** (Chainlink 88,200 s, RedStone 23,400 / 12,600 s); within that window the bracket assumes the deviation trigger works, and a second source catches a frozen feed once the market moves more than about 1.8% | until the keeper next runs, unbounded if it stops |
| Oracle disagreement | per implementation | **refuse** when the brackets do not intersect | depends on the keeper |
| Depeg | follows feeds | **follows the feeds**; the band widens with the legs' thresholds; a peg band can be added in the adapter (not implemented) | floors move toward the depeg by bounded steps, lagging it |
| Sequencer interruption | per implementation | **refuse** while down and for one hour after restart (Chainlink uptime feed) | keeper cannot run; floors freeze |
| Infrastructure outage (feed down) | refuse | **refuse** (`FeedUnusable`, `InsufficientSources`); no fallback price | stale floors keep trading |
| Reentrancy and external calls | the vault calls feeds directly | **one staticcall from the vault, before any effect, inside `nonReentrant`**; no state change possible, and a read-only re-entry sees consistent state; a feed can only revert or burn gas (`test_gasBurningFeedOnlyFails`), which refuses the trade | keeper transactions call the vault; new role attack surface |
| Vault bytecode | ESTIMATE ≥ +5.5 kB (the adapter alone is 4,180 B), above EIP-170 at 2,000 runs | **MEASURED +1,947 B at 2,000 runs (23,996 B, margin 580); +1,581 B at 200 runs (21,199 B, margin 3,377)** | ESTIMATE about +1 kB (role, bounds, step logic) |
| Gas per swap | ESTIMATE similar to B | **MEASURED: vault-side check +8,223 gas with a cheap adapter; the adapter read is 24,391 warm / 76,331 cold** (the hook's own read warms the feeds first) | none per swap; one keeper transaction per move |
| Operational dependencies | feeds | **feeds** (two providers, sequencer feed) | feeds + a live keeper + its key |
| Failure and recovery | refuse until feeds recover | **refuse until feeds recover; no operator action needed**; to change sources, propose a new adapter (2 days) | stale floors until an operator restarts the keeper |

### Why B, and why not the others

- **A** puts a second copy of the oracle logic in the vault. That code is bigger than the vault has room for, and it
  can drift from the hooks' copy, so a hook could quote prices the vault refuses (the root cause again, one layer
  down). B keeps one implementation of the reference and two independent uses of it.
- **C** separates the floor from the transaction that uses it. In between, floors are stale by construction. The
  keeper's liveness becomes a safety dependency, the keeper's key is a new authority over prices, and the D14 ordering
  constraint has to be handled on every step. It also brings back owner-like operational intervention under a new name.
- **B** is the only option where the hook and the vault read identical data in the same transaction, the vault still
  decides on its own, and no operator acts during routine trading.

## 3. The proposed vault change (exact: `docs/proposals/vault-dynamic-floor.patch`)

Storage, appended after the last existing slot (no existing slot moves):

| Item | Type | Meaning |
|---|---|---|
| `priceRiskAdapter` | `IPriceRiskAdapter` | zero = today's behaviour exactly |
| `dynamicEdgePips` | `uint24` | extra edge beyond the band; the guardian may only raise it |
| `pendingPriceRiskAdapter`, `pendingAdapterEta` | `address`, `uint64` | the proposed change and when it may execute |
| `ADAPTER_DELAY` | constant | 2 days |
| `MAX_STATIC_BAND_PIPS` | constant | 25% |

Behaviour:

1. **`exchange`**. Effective floor = `max(vault floor, curator floor, dynamic floor)`. The dynamic floor comes from one
   `currentReference()` staticcall made before any effect: selling asset1 needs at least
   `ceil(ceil(2^192 / P) * (1e6 + u + e) / 1e6)`, selling asset0 at least `ceil(P * (1e6 + u + e) / 1e6)`. If the
   adapter reverts, the swap reverts.
2. **`setSellFloor`**. While an adapter is installed, the D14 rule becomes an outer-band rule:
   `F_this >= ceil(2^192 / F_opposite) * (1 - 25%)^2`. The static floors become an absolute circuit breaker, for
   example "never sell ETH below 1,500 or buy it above 3,000". Cycle-freedom at any fixed reference comes from the
   dynamic floors. **This is the financial-invariant change.**
3. **`proposePriceRiskAdapter` (owner) → 2 days → `executePriceRiskAdapter` (anyone)**. `cancelPriceRiskAdapter`:
   owner or guardian. Installing requires the new adapter to answer now. Removing it (zero) requires the static floors
   to be D14-consistent again, because they become the only price protection.
4. **`setDynamicEdge`**: owner any value below 10%; guardian only up.

Invariants this keeps:
- I-1 to I-7 of `PRICING_INVARIANTS.md`, unchanged. Floors only ever add to the effective floor; nothing else in
  `exchange` changes.
- With no adapter installed, the vault behaves exactly as today. MEASURED: the full suite of this branch, run against
  the patched vault together with the prototype's own three tests, gave 489 passed, 2 failed, 4 skipped (fork tests).
  The two failures are the project's size gate, which the full patch misses at 2,000 runs (§4), and a gas bound in a
  research test of this branch, since relaxed.

Invariant this changes:
- **D14 on static floors** is replaced, while an adapter is installed, by: "at every reference the effective floors are
  D14-consistent". The proof is the product inequality above. The exposure it accepts: if every feed source is
  corrupted together, the static band (up to ±25%) bounds the price the vault can be made to accept, together with
  flow caps, exposure caps and halts.

## 4. Measured cost (scratch copy, production settings)

| | Runtime bytes | EIP-170 margin | Project target (2,048) |
|---|---|---|---|
| vault today, 2,000 runs | 22,049 | 2,527 | met |
| patched vault, 2,000 runs | 23,996 | 580 | **missed** (`test_productionSizesWithinLimits` fails) |
| patched vault without edge setter and cancel, 2,000 runs | 23,548 | 1,028 | missed |
| vault today, 200 runs | 19,618 | 4,958 | met |
| **patched vault, 200 runs** | **21,199** | **3,377** | **met** |

Lowering the vault's optimizer setting from 2,000 to 200 runs costs **+0.13% to +0.36% gas** on every vault operation
(for example +526 per swap, 244,885 → 245,410 for Hook B; +455 per deposit) and saves 2,431 bytes. All 59
production-benchmark lines were compared (`test/bench/ProductionArtifactGas.t.sol`, `--isolate`). Swap gas with the
dynamic floor on: +8,223 for the vault's own work, plus the adapter read (24,391 if the hook already warmed the feeds
in the same transaction).

## 5. What the selected architecture costs economically

The architecture is correct; the verified feeds make it expensive. With Unichain's push feeds, the band the vault must
stay outside is about ±82 bps for WETH/USDC (`ORACLE_VERIFICATION_UNICHAIN.md` §5). In the matched simulation
(`FILL_RATE_ANALYSIS.md`) fail-safe pricing on those feeds alone fills about 5% of uninformed demand. A fresher
independent source in the same bracket brings it to about 39% with no arbitrage. No such source is verified usable on
Unichain today: Pyth's update endpoint needs an API key, and Data Streams was not checked. The architecture accepts
a third source without change (the adapter takes another source; the vault code is unchanged), but **adding one is a
separate decision**.

## 6. Decisions requested

- **D-2a**: approve architecture B and the vault change in `docs/proposals/vault-dynamic-floor.patch`, including the
  D14 → outer-band change while an adapter is installed.
- **D-2b**: approve compiling the vault at 200 optimizer runs (+0.13–0.36% gas everywhere, +3,377 B margin), or ask
  for code to be removed elsewhere in the vault instead.
- **D-1 (revised)**: approve Chainlink and RedStone push feeds as the two initial sources, with the thresholds and
  staleness limits in `ORACLE_VERIFICATION_UNICHAIN.md`; decide whether to pursue a pull source (credentials, fees,
  router integration) before the economics are acceptable.
