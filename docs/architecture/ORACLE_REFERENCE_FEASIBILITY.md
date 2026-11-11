# Porkfolio — Market Reference and Oracle Feasibility (Phase 1B-4)

**Status: RESEARCH, decisions D-1 and D-2 need owner approval.** Nothing here is integrated. Labels: DOC (stated in
provider or Uniswap documentation, read on 2026-11-10; not verified on-chain), SOURCE (this repository), SYNTHETIC
(simulation), DESIGN (proposal).

## 1. What the reference is for

Candidate C (`INVENTORY_PRICING_SPEC.md`) quotes a spread around a mid `M` and needs an uncertainty `u` to widen that
spread. `M` is the most dangerous input in the design. If it is wrong, every quote is wrong on the same side and
arbitrage takes inventory until the inventory cap, the vault's flow caps or the floors stop it. The requirements:

1. independent of anything a trader on this pool can move cheaply;
2. fresh enough that `h + u` covers the distance the market can move before the reference does;
3. **never substituted**: when the reference is missing, stale or inconsistent, refuse; never fall back to a stored or
   default price (P-7).

## 2. The intercepted pool's own price is not a reference

SOURCE: `BaseCompatibleHook.beforeSwap` returns a delta that consumes the whole input, so the pool's curve never runs
and its `sqrtPriceX96` stays at its initialization value forever. The Porkfolio pool's tick carries **no information**
about the market. Any other v4 pool's tick or TWAP (through an oracle hook) is a market price, but one an attacker can
move in the same transaction or across a few blocks at a cost set by that pool's liquidity. It is usable only as a
divergence check, never as the mid.

## 3. Sources available on Unichain

DOC: Uniswap's Unichain developer documentation ("Oracles on Unichain") lists Api3, Pyth, RedStone (push and pull),
Stork, eOracle and Chronicle on Unichain Mainnet and Sepolia, and Gas Network on Mainnet. Its "Data Feeds" page lists
Chainlink. Chainlink's changelog dates Data Feeds on Unichain Mainnet to 2026-03-03 (Sepolia 2025-02-10). Chainlink
Data Streams (pull, low latency) is also listed for Unichain. The per-pair heartbeat and deviation thresholds for
Unichain could **not** be retrieved in this phase (the Chainlink feed page returned HTTP 429). Other L2 ETH/USD feeds
are documented at 0.05–0.15% deviation thresholds, Ethereum mainnet at 0.5%. **Every feed address, pair, decimals,
heartbeat and threshold must be read on-chain before configuration.**

| Criterion | Push feed (Chainlink Data Feeds; RedStone push; Chronicle; Api3; eOracle) | Pull feed (Pyth; RedStone pull; Stork; Chainlink Data Streams) | Another v4 pool's TWAP (oracle hook) |
|---|---|---|---|
| Availability on Unichain | DOC: yes, pair coverage varies by provider | DOC: yes | only where a deep pool with an oracle hook exists |
| Freshness | bounded by the deviation threshold and heartbeat | as fresh as the update the transaction carries | lags by the TWAP window |
| Update path | provider's transmitters; no trader input | the **trader** submits a signed update in the swap transaction | on-chain swaps |
| Manipulation resistance | provider's aggregation; not movable on-chain | signatures cannot be forged, but the trader chooses **which** valid update to submit inside the freshness window (free option) | costly but possible; cost scales with pool depth and window |
| Gas | one external view call, cold ≈ 5–15k (estimate; proxy plus aggregator) | update verification plus fee, typically tens of thousands (estimate); router must carry the payload | observation reads, ≈ 5–20k (estimate) |
| Failure behaviour | stale answer (heartbeat missed); `updatedAt` exposes it | no update supplied: falls back to the last stored price, which must then be age-checked | stale window, or no observation |
| Depeg detection | yes if the pair (or the USD legs) is fed | yes | yes, but the pool itself can depeg |
| Operational dependency | provider network | provider network, plus routers that carry updates | the pool's liquidity |
| Round history (for the volatility term) | Chainlink: `getRoundData` by round id. Others: varies (DOC not checked per provider) | stored price only | the observation buffer |

## 4. Recommended reference architecture (DESIGN)

- **Primary:** a push feed for the pair, ideally Chainlink Data Feeds on Unichain where the pair (or both USD legs) is
  listed. Push keeps the swap path free of trader-supplied price data, so routers need no new payload, and no trader
  can choose among updates.
- **Secondary:** a push feed from a **different provider**, used only for the divergence check and never as the mid.
- **Uncertainty** `u` = divergence + age widening + realized-volatility widening (spec §3). Volatility comes from the
  primary's last four rounds where the provider exposes round history. Otherwise it needs a small hook-stored
  estimate, which is one extra storage write per swap (decision for M2).
- **Refusals, never substitutes:** stale primary → `StaleReference`; missing primary → `ReferenceUnavailable`;
  divergence above `max_divergence` → `ReferenceDivergence`; secondary missing → widen by `missing_penalty`, or refuse
  in strict mode; future timestamp → `ReferenceUnavailable`.
- **Pull feeds and Data Streams** are deferred. They can only be added as an optional fast path that never becomes
  the sole reference, because the free option they give the trader must be priced first.

## 5. Required behaviour under stress

SYNTHETIC numbers are from the stress worlds of `simulate.py` (held-out seeds, 3-day worlds, candidate C3).

| Situation | Behaviour | Evidence |
|---|---|---|
| Reference stale | refuse every quote until a fresh round | `ReferenceFailClosed`; outage world: `ReferenceUnavailable` refusals, arbitrage 0.0/day |
| Two references disagree | widen by the divergence; refuse above `max_divergence` (1% in the simulation) | primary manipulated +3% for 30 min: 86 `ReferenceDivergence` refusals, arbitrage 0.0/day, LP +34 bps |
| Abrupt move | the primary lags by at most one round; the volatility term widens the spread after the first rounds of a fast market | jump regime (−6%): arbitrage −169/day in the jump world, LP still +154 bps median (market arbitrage, not mechanical) |
| Source unavailable | refuse | outage world as above |
| Liquidity collapse elsewhere | not visible to a price feed; bounded by the inventory cap, the flow caps and the guardian's halt | — |
| Token depeg | the reference follows the depeg; quotes stay two-sided around the new price; for pegged pairs a governance **peg band** that refuses outside `|M − peg| ≤ b` is recommended (DESIGN, not simulated) | depeg world (−15% in 1 h): C3 −24.8 bps median vs −995 for a static `P` |
| Adversary manipulates the reference | one source: divergence refusal. All sources together: undetectable by the hook; loss bounded by `I_max × manipulation` per reference episode, then by flow caps and floors | both feeds +3% for 30 min: arbitrage −863/day over 3 days (≈ 2,600 tokens), below the 150,000 × 3% = 4,500 bound |
| Sustained trend | the reference follows; inventory stays within the cap; floors must follow too (D-2) | trend regime: +121.9 bps median, worst world +110.5 |

## 6. Decisions that need approval

- **D-1: reference trust in the hooks.** `hookOwner` would choose the feed addresses and the reference policy. That
  makes the feeds trusted inputs of the hooks (as `P` is today), not of the vault. The vault's floors, flow caps,
  exposure caps and halts remain the bound against a wrong or malicious reference. Feed changes should take effect
  only after a delay, in the same way as the loosening delay proposed in D-P3.
- **D-2: floor pivot tracking.** D14 floors can only be a pivot, and only the vault owner can lower a floor. With a
  static pivot any two-sided quote becomes one-sided as soon as the market moves: C1 (static floors) reaches a median
  fill of 4.7% against 34.3% for C3. Options:
  1. *Operational:* the owner, a multisig, re-centres the floors when the reference moves more than a band (the
     simulation used 10 bps with a 60 s delay; a slower human process will refuse more). No code change. Adequate for
     a testnet demo, not for production.
  2. *Vault change:* a restricted `floorKeeper` role that may move the D14 pivot by at most a bounded step per
     interval and never outside an owner-set range. Adds code and a role to the audited vault.
  3. *Vault change:* an oracle-relative floor in the vault itself. This makes the reference a **vault** trust input,
     the largest change of the three.

  The recommended order is (1) for UHI11, then (2) after review. (3) needs a separate threat model.

Both decisions change who can affect prices. Neither is implemented, and neither should be until it is approved.

## Sources

- Uniswap, "Oracles on Unichain": https://developers.uniswap.org/docs/unichain/tools/oracles
- Uniswap, "Data Feeds" (Unichain): https://developers.uniswap.org/docs/unichain/tools/data-feeds
- Chainlink changelog, "Data Feeds expands to Unichain Mainnet": https://dev.chain.link/changelog/data-feeds-expands-to-unichain-mainnet
- Chainlink changelog, "Data Feeds on Unichain Sepolia": https://dev.chain.link/changelog/data-feeds-on-unichain-sepolia
- RedStone blog, Unichain integration (vendor source): https://blog.redstone.finance/2025/02/11/redstone-the-go-to-blockchain-oracle-powering-unichains-defi/
- Pyth, pull-oracle design (vendor source): https://pyth.network/blog/pyth-a-new-model-to-the-price-oracle
- Chainlink ETH/USD feed pages for other networks (deviation thresholds quoted above): https://data.chain.link/feeds/arbitrum/mainnet/eth-usd, https://data.chain.link/feeds/base/base/eth-usd, https://data.chain.link/feeds/ethereum/mainnet/eth-usd
