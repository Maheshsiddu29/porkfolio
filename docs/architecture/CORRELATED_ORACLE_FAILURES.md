# Porkfolio — Correlated Oracle Failures and Loss Bounds (Phase 1B-4.2)

**Status: ANALYSIS.** Bounds: `python3 simulations/mm/attacks.py` (→ `simulations/mm/results/attack_bounds.md`).
Simulated attacks: `python3 simulations/mm/simulate.py --phase142` (→ `results/phase142.md`), 3-day worlds, 4 held-out
seeds. All SYNTHETIC; nothing here is an on-chain loss measurement.

## 1. How independent are the two sources?

| Pair | Independent of each other? | Evidence |
|---|---|---|
| Chainlink USDC/USD proxy #1 and #2 | **no**: one source | identical round id (phase 2, round 101), answers 0.99971994 vs 0.99972000 (ON-CHAIN) |
| Chainlink vs RedStone push | **operationally yes, informationally no** | separate contracts, operators and aggregation; both aggregate centralised-exchange prices, so an exchange-wide price error (a wick, a halted venue, a bad print) can reach both |
| push feeds vs Uniswap v3 TWAP on Unichain | **informationally yes** | its source is on-chain trading on Unichain; but the deepest WETH/USDC v3 pool held about 1.36 M USD (≈305,709 USDC + 514 WETH), cheap to move on a single-sequencer L2 |
| push feeds vs fresh signed sources (Pyth, RedStone pull, Data Streams) | Pyth / Data Streams: different operators; **RedStone pull shares RedStone push's data service** (`redstone-primary-prod`) | registry and SDK configuration |

**Conclusion.** Two push sources protect against **one** source failing or being manipulated. They do not protect
against an error in the market data both read. The design therefore does not rely on source independence for its
worst case: the inventory floor bounds the loss with no price at all.

## 2. Scenarios

Analytic setup (ASSUMPTIONS): 1,000,000 units of each asset at price 1 (vault value 2,000,000); `kappa` = 15% (and 5%);
flow cap 10% of holding per asset per day, fixed epochs (up to two caps across a boundary); guardian halts within 24 h;
reference band 0.82% (WETH/USDC, fork-measured); widest honest bracket ±1.02%.

The bound limits the **value extracted by trading against a wrong price**. The simulator reports that as
arbitrage revenue against the vault. "LP vs HODL" also includes the ordinary market exposure of the inventory over
the 3-day world, so it is shown separately and is not comparable with the bound.

| # | Scenario | Detection | Per-unit loss bound | Bound, `kappa` 15% | Bound, `kappa` 5% | Simulated extraction, Q1 (`kappa` 15%), mean of 4 seeds | Simulated extraction, Q3 (`kappa` 5% + fresh source) | LP vs HODL worst seed, Q1 / Q3 |
|---|---|---|---|---|---|---|---|---|
| 1 | one source manipulated by δ ≤ 1.84% | none: inside both error bounds | `2 d_h` = 2.04% | 15.3 bps | 5.1 bps | A1 (+1.5%, 6 h): 4.4 bps | 0.9 bps | −16.9 / +30.4 |
| 2 | one source manipulated by δ > 1.84% | `ReferenceDivergence`, refused | 0 | 0 | 0 | A2 (+3%): 0.0 | 0.0 | +8.4 / +32.8 |
| 3 | both sources wrong by the same δ (shared upstream) | none from the feeds | `δ − u` | δ = 5%: 31.4 bps; 20%: 143.8 bps | 10.4 / 48.0 bps | A3 (+5%, 6 h): 28.1 bps | 8.7 bps | −42.8 / +16.6 |
| 4 | malicious or mistaken adapter installed (any price) | 2-day timelock, guardian cancel, LP exit window | whole unit value | 750 bps one asset, **1,500 bps both** (the capital-at-risk bound) | 250 / **500 bps** | A4 (price halved, 1 day, one asset): 421.9 bps (no inventory floor: about 2× more) | 117.7 bps | −514.3 / −111.3 |
| 5 | both feeds frozen through a 10% move, inside their staleness limits | staleness limit (6.5 h RedStone) or guardian | `m − u` | 68.9 bps | 22.9 bps | A5: 2.6 bps | 13.0 bps | −70.0 / +4.3 |
| 6 | sudden 8% jump, feeds one round behind | next round | `J − u` | 53.9 bps (upper bound) | 17.9 bps | A6: 0.0 | 0.0 | −3.9 / +25.0 |
| 7 | stablecoin depeg 15% in 1 h, then drift | feeds follow the depeg (USDC/USD leg 0.3% threshold) | market loss on held assets, not an oracle loss | — | — | A7: 0.0 | 0.1 bps | −111.2 / +9.0 |
| 8 | feed misses its heartbeat past the staleness limit | source dropped, `InsufficientSources` | 0 | 0 | 0 | refusals only | | |
| 9 | sequencer interruption | `SequencerUnavailable` (down or < 1 h since restart) | 0 | 0 | 0 | refusals only | | |
| 10 | hook and vault on different configuration versions | impossible for the adapter (hooks read it from the vault); strategy mismatch is re-checked by the vault | 0 | 0 | 0 | refusals only | | |

Every simulated extraction is inside its analytic bound. Bound 4 holds for **any** price and any adapter. It depends only
on two things: the inventory floor, and governance not raising `kappa` during the attack (decision R-3).

## 3. What each defence buys

| Defence | Stops | Does not stop |
|---|---|---|
| two-source bracket | one source wrong by more than about 1.84% (scenario 2) | common-mode errors (3), a malicious adapter (4) |
| uncertainty breaker `maxUncertaintyPips` | trading on a wide or disputed band | errors that leave the sources in agreement |
| sequencer check | trading on prices frozen by a sequencer outage | — |
| staleness limits | a feed that stopped for longer than its heartbeat plus grace | a frozen feed inside that window (5) |
| 2-day adapter timelock + guardian cancel | a malicious or mistaken adapter becoming effective unseen | a malicious adapter once installed |
| **inventory floor `kappa`** | **every case: bounds the loss to `sum (N_a − L_a) p_a`** | nothing below that bound |
| flow caps | the speed of any loss | the total, beyond the guardian's reaction time (two caps fit in one day) |

## 4. Choosing `kappa`

`kappa` is the capital at risk under total oracle compromise. With the hooks' own inventory cap set to the same value,
it costs nothing in normal markets. In the held-out simulation, Q1 (`kappa` 15%) was identical to Q0 (no vault
floor) on every regime, and Q3 (`kappa` 5%) filled 37.3% against Q2's 37.6% with a better worst world (+65.4 vs
−17.8 bps). The recommended starting value is **5%**, with the hooks' caps at most 5%. Raising it is a deliberate
trade of capital at risk for inventory flexibility.
