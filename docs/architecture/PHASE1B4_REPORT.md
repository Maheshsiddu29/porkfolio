# Porkfolio — Phase 1B-4 Report: Long-Term Adaptive Market-Making Architecture

**Status: PASS (research), architecture recommended, implementation blocked on owner decisions D-1 to D-5 (§9).**
Branch `research/adaptive-market-making` from `phase-1b-3-cumulative-pricing` at `eaf3eff`. No production Solidity
changed: `git diff eaf3eff -- src/` is empty. Nothing is pushed, merged, deployed or published. Labels: SOURCE, OBSERVED
(named test on production artifacts), MODEL (exact integer Python), SYNTHETIC (generated worlds; not market data),
ESTIMATE (not measured).

## 1. Result in one paragraph

Hook B refuses inventory-reducing trades because it prices both directions from one zero-spread curve whose mid moves
with a decaying position, against D14 floors that can only be a single pivot. Its reverse quote is on the wrong side of
the reference, so the floor is right to refuse it. Its position is recent trading pressure, not inventory
(`PHASE1B4_ROOT_CAUSE.md`). The recommended architecture (candidate C) prices from the vault's **real** inventory,
read through existing vault getters, around a fail-closed two-feed reference. Its spread and inventory cap are tied so
that every quote straddles the reference: the vault never buys above `M(1 − h_min)` or sells below `M(1 + h_min)`,
whatever the state or parameters. That one property removes the root cause, makes floors pivoted at the reference
accept every quote, makes all trading cycles at a fixed reference lose, and makes cumulative pricing hold across hooks.
In held-out synthetic worlds C is the only candidate with no losing world (worst +8.6 bps vs HODL; worst-regime median
+90.9 bps). It needs two owner decisions that change who can affect prices: reference feeds in the hooks (D-1), and
floors that track the reference (D-2). Without D-2, C is nearly unusable in a moving market (median fill 4.7%).

## 2. What was produced

| Deliverable (task §11) | Where |
|---|---|
| 1. Root cause | `PHASE1B4_ROOT_CAUSE.md`; `simulations/mm/rootcause.py`; `test/research/HookBRootCause.t.sol` (7 tests, production artifacts) |
| 2. Protocol-wide invariants | `PRICING_INVARIANTS.md` |
| 3. Candidate comparison (A–D) | `MARKET_MAKING_CANDIDATES.md` |
| 4. Independent Python reference | `simulations/mm/model.py` (reuses the differential-tested `simulations/pricing/cumulative.py`) |
| 5. Simulation and stress results | §5; `simulations/mm/simulate.py`; `simulations/mm/results/` |
| 6. Cross-hook and shared inventory | `MARKET_MAKING_CANDIDATES.md` "Cross-hook"; §5.4 |
| 7. Oracle feasibility | `ORACLE_REFERENCE_FEASIBILITY.md` |
| 8–9. Recommended model and mathematical specification | `INVENTORY_PRICING_SPEC.md` |
| 10. Quote interface | `QUOTE_INTERFACE_SPEC.md`; vectors `simulations/mm/vectors/inventory_quote_v1.json` |
| 11. Gas, bytecode, feasibility | §6 |
| 12. Unresolved risks and assumptions | §7 |
| 13. Implementation plan and gates | §8 |

## 3. Data used, and data not used

- **BondMeBro.** The generator the task refers to was found outside this repository
  (`~/Documents/BondMeBro reserach documents /local_research_archive/simulation/calibration/run_short_window.py`, with
  `run_v7_1_l2.py` and its CSV outputs). It is 8 regimes × 4 seeds × 80,000 trades = 2.56 million generated trades.
  Each trade is a single-pool tick-impact event with a post-trade tick path over 8–10 Ethereum blocks, labelled 80%
  benign and 20% harmful. It has no order-flow sequence, no counterparty inventory and no two-sided prices, so its
  records cannot drive a market-maker simulation and were **not reused as data**. Two design choices were borrowed and
  are labelled as assumptions: the regime × seed structure, and the 80/20 split between uninformed and informed flow.
- **Historical Uniswap data.** None is available in either repository; none was fetched. Every result here is
  SYNTHETIC. Historical replay remains a gate before any mainnet parameter choice (§8, M7).

## 4. Method

`simulate.py` models the vault as the contracts do on the integers that matter: the D14 floor check on exact amounts,
directional allocations refreshed every 6 h to `min(30%, admissible)` with a 5% buffer, daily gross-output flow caps
(40% of the seeding amount per asset), and in-kind pro-rata LP exits that need free inventory in both assets. The
market is a log random walk on a 10 s grid with regime drift, volatility and jumps. The primary feed updates on a 0.2%
deviation or a 1 h heartbeat with one slot of latency; the secondary on 0.5% or 24 h with 2 bps of reporting noise
(ASSUMPTIONS; the Unichain values must be read on-chain). Flow: uninformed orders (lognormal size, median 1,500 tokens;
persistent direction; lognormal tolerance, median 30 bps against an outside venue; optional same-block splits);
informed orders (20%; they know the market 10 minutes ahead); and one arbitrageur trading against the true market net
of 3 bps. The vault holds 1,000,000 of each 18-decimal token; LP value is measured against holding the seeding basket
(HODL).

Process. Each family's parameters were chosen on **calibration seeds** (101–104) by a rule fixed in code before
running: maximise the worst regime's median LP-vs-HODL, rounded to 1 bp, then the median regime's
(`results/calibration.md`, 71 configurations: 3 for A, 8 for B, 60 for C; 3 min 36 s on 10 cores). The selections were then evaluated once on
**held-out seeds** (201–204): 8 regimes × 4 seeds = 32 worlds and 430,109 orders per candidate, plus 4 stress worlds
(45,987 orders), in 50 s. Output is byte-identical across runs and worker counts.

Metric definitions: *fill* = filled ÷ uninformed orders; *protocol acceptance* = 1 − refusals by hook or vault ÷
uninformed orders (the rest of the gap to 100% is traders declining a quote above their tolerance); *reverse* = an
order that reduces the vault's real `|N_1 − T_1|` at arrival; *exec cost* = value-weighted cost of uninformed fills
against the true market; *spread revenue* = value received minus value paid at the market at trade time; *informed
markout* = the vault's currency1 change from informed fills, valued at the 10-minute-ahead price change (adverse
selection); *concentration* = largest `|w_1 − 50%|` in percentage points of value.

## 5. Results (SYNTHETIC, held-out seeds)

### 5.1 Across regimes

| candidate | fill median | fill worst | protocol accept median | reverse fill median | LP vs HODL, median regime | LP vs HODL, worst regime | worst world | arbitrage revenue/day, median | max deviation | max concentration |
|---|---|---|---|---|---|---|---|---|---|---|
| A0 Hook B, static `P` | 6.8% | 1.1% | 32.6% | 5.1% | −44.9 | −885.6 | −2,128.9 | −1,921.6 | 105.0% | 50.0 |
| A Hook B, keeper `P` + floors | 21.5% | 16.4% | 59.3% | 21.3% | +57.2 | −37.2 | −171.2 | −13.6 | 30.9% | 15.0 |
| B1 curve + 20 bps, 2% cap | 30.2% | 26.2% | 85.9% | 30.4% | +71.6 | +48.6 | −74.9 | −5.4 | 25.6% | 9.9 |
| B2 curve + 20 bps, straddle cap | 20.6% | 16.4% | 32.6% | 21.7% | +14.8 | +4.1 | −11.8 | −6.2 | 3.6% | 11.3 |
| C1 inventory, static floors | 4.7% | 1.9% | 15.9% | 4.2% | +18.1 | −126.0 | −291.4 | −0.4 | 15.0% | 8.5 |
| C2 inventory, no volatility term | 40.5% | 30.3% | 92.9% | 43.8% | +149.4 | +48.0 | −48.7 | −3.3 | 15.0% | 10.4 |
| **C3 inventory (selected)** | 34.3% | 19.5% | **99.5%** | 37.9% | **+151.4** | **+90.9** | **+8.6** | **0.0** | 15.0% | 10.4 |
| D C3 + RFQ, inventory-checked | 40.0% | 30.8% | 50.5% | 40.4% | +81.4 | −16.4 | −207.3 | −3.8 | 15.0% | 8.9 |
| D′ C3 + RFQ, unchecked | 39.1% | 29.5% | 48.0% | 38.2% | +82.8 | −123.7 | −793.8 | −13.6 | 100.0% | 50.0 |

LP values in bps of the seeding value over 14 days. "Arbitrage revenue" is negative when the vault loses.

### 5.2 Per regime, LP vs HODL median (bps) and fill

| regime | A (keeper) | B1 | C2 | **C3** | D |
|---|---|---|---|---|---|
| calm balanced | +63.6 / 21.5% | +79.2 / 31.6% | +147.5 / 40.7% | +151.1 / 34.9% | +65.0 / 40.4% |
| one-sided flow | +52.0 / 22.0% | +71.8 / 26.2% | +142.0 / 40.4% | +142.5 / 34.5% | +84.9 / 40.7% |
| whales | +45.1 / 21.6% | +71.5 / 31.1% | +153.6 / 31.8% | +181.6 / 31.4% | +82.0 / 30.8% |
| splitters | +65.8 / 20.4% | +70.9 / 29.2% | +151.4 / 40.6% | +151.7 / 34.5% | +84.3 / 40.3% |
| volatile | −25.1 / 16.4% | +49.8 / 28.1% | +48.0 / 30.3% | +90.9 / 19.5% | −16.4 / 36.3% |
| trend | −37.2 / 22.0% | +48.6 / 33.5% | +113.5 / 40.5% | +121.9 / 32.4% | −15.3 / 39.8% |
| jump and partial recovery | +62.5 / 22.0% | +86.6 / 31.8% | +152.1 / 41.4% | +154.5 / 37.4% | +80.9 / 42.3% |
| LP withdrawals + one-sided | +90.4 / 21.3% | +109.6 / 26.8% | +221.6 / 40.0% | +219.5 / 34.0% | +131.6 / 39.7% |

Other measured quantities, C3 (median regime): execution cost 33.9 bps vs 24.7 for A (wider quotes, more of them
accepted); spread revenue 2,206 tokens/day vs 849; informed markout −27/day vs −34; turnover 0.33 of vault value per
day vs 0.19; mean deviation 2.3% of target. Volatile regime: C3 widens to about 45 bps of cost and fills 19.5%
(C2 30.3%), trading fill rate for a +43 bp better LP result; informed markout −735/day vs −792 without the term.

### 5.3 Stress worlds (3 days each, C3 unless noted)

| world | outcome |
|---|---|
| primary outage 6 h in a 5%/day market | 963 `ReferenceUnavailable` refusals; arbitrage 0.0/day; LP +17.3 bps (A0 static `P`: −110) |
| primary manipulated +3% for 30 min | 86 `ReferenceDivergence` refusals; arbitrage 0.0/day; LP +34.3 bps |
| both feeds manipulated +3% for 30 min | undetected; arbitrage −863/day (≈ 2,600 tokens, under the 150,000 × 3% bound); LP +13.6 bps |
| depeg −15% in 1 h then −3%/day | LP −24.8 bps median, −46.1 worst (A keeper −34.4; A0 static −995.2) |

### 5.4 Two hooks on one reserve

| configuration | median fill | worst-regime LP | worst world | max deviation |
|---|---|---|---|---|
| Hook A + Hook B (today) | 38.7% | −105.1 | −776.5 | 99.99% |
| Hook A + C3 | 43.5% | −90.3 | −666.8 | 99.98% |
| C3 + C-core 10 bps hook | 39.4% | +72.7 | −47.4 | 15.0% |

### 5.5 Reading the results

- The **floor pivot** decides whether any two-sided design works: C1 vs C3 is the same pricing with static vs tracking
  floors (4.7% vs 34.3% fill).
- **Real inventory plus straddle** (C) beats a decaying curve with or without a spread (A, B) on every regime's LP
  outcome. With an equal spread, C2 fills 40% against B1's 30%, because nothing is refused for state reasons.
- The **volatility term** is what makes the worst world positive; it is paid for in volatile-market fills.
- **RFQ** buys fills with LP outcome and needs the inventory check to be safe.
- **Every hook on the reserve must share the inventory signal.** One inventory-blind hook drains the reserve whatever
  the others do.
- **Withdrawal servicing** was 100% instant for every candidate except A0 (94.4%). Pricing barely affects in-kind exits,
  because trades never reduce free inventory: they consume reserved capacity. This metric does not separate the
  candidates.
- Not chosen on fees or fills: C3 neither fills the most (D, C2) nor has the highest median revenue in every regime.

## 6. Gas, bytecode and feasibility

| Item | Value | Label |
|---|---|---|
| Hook B swap today | 244,885–253,611 | OBSERVED (Phase 1B-3 bench) |
| Vault reads `N_0, N_1, S` (5 getters) | 19,549 cold, 7,049 warm | OBSERVED (`test_RC_gas_vaultInventoryReads`) |
| Marginal cost of those reads in a swap (the vault account and two `backing` slots are warm for `exchange` afterwards) | ≈ 13,000 | ESTIMATE from the measurement |
| Curve arithmetic: cost / inverse / cap | 546 / 640 / 1,464 | OBSERVED (`test_RC_gas_curveMath`) |
| C math per swap (two costs, one inverse, two straddle sides) | ≈ 3,500–4,500 | ESTIMATE from components |
| Two push-feed reads | ≈ 10,000–30,000 | ESTIMATE (no Unichain feed measured; M2 gate) |
| Four history rounds for the volatility term | ≈ 20,000–32,000, or ≈ 5,000 with a stored estimate | ESTIMATE (M2 decision) |
| Hook storage write saved (C has no hook state) | −3,000 to −5,000 | ESTIMATE |
| **C3 swap total** | **≈ 280,000–320,000** | ESTIMATE; gate M3 measures it |
| Hook runtime bytecode | Hook B 9,165 B; C hook ≈ 11–14 kB | OBSERVED / ESTIMATE; under EIP-170 (24,576) |
| Vault runtime | unchanged in this phase | OBSERVED (no `src/` diff) |

Why the extra 30–70k gas is acceptable. It buys the property that the vault cannot be priced on the wrong side of
the market. Under the same assumptions that property separates −886 bps from +91 bps in the worst regime. The
measurable trade-off is the volatility history (up to about 32k). M2 decides between reading rounds and storing an
estimate, from measured numbers.

Feasibility. Everything in C reuses `CumulativePricing` arithmetic, existing vault getters and the existing
`hookData` format. The new code is a pricing library (≈ 300 lines with documentation), a reference adapter, and one
hook. No new stateful module is required. No vault change is required **unless** D-2 option (2) or (3) is chosen.

## 7. Unresolved risks and assumptions

1. **Floors must track the reference (D-2).** Without it, C refuses one side as soon as the market moves.
   Operational re-centring needs the vault owner, who is not built for a keeper role.
2. **Reference trust (D-1).** A corrupted primary that the secondary confirms is undetectable; the loss is bounded by
   `I_max ×` the error per episode, then by flow caps and floors. The feeds' Unichain parameters are unverified.
3. **Synthetic only.** No historical calibration. Order sizes, tolerances, the informed share and feed behaviour are
   assumptions. Parameters (20 bps, 15%, 50%) are not deployment values.
4. **Skew is limited to about one spread** by design. If real one-sided flow is stronger than in these worlds, the
   inventory cap will bind more often (`InventoryLimit` refusals), rather than prices moving further.
5. **Hook A** must adopt the core or leave the shared reserve; otherwise it drains it (§5.4).
6. **Latency arbitrage** around reference updates is a market cost, priced but not removed; the jump regime shows its
   size (−169/day for one world with a 6% jump).
7. **Depth bound.** `V ≤ 2^95 − 1` limits the deviation a 10 bp spread gap can carry to about 1.98·10^25 raw.
8. **Just-in-time deposits** deepen `V` up to `V_max`. The depositor bears its share of any loss it creates, but
   `V_max` must be set.
9. **Exact output, multi-hop routing and pull oracles** are not covered.
10. **Tests not run in this phase:** no Unichain fork test, no testnet, no independent review, no remote CI, no
    historical replay, no Solidity implementation of C (so no on-chain differential test yet), and the calibration
    was not re-run for determinism (the held-out run was, twice).

## 8. Implementation plan

Essential protocol correctness (M1–M5) comes before performance and product work (M6–M7). Each gate is pass/fail.

| Milestone | Content | Depends on | Acceptance gate |
|---|---|---|---|
| **M0 Decisions** | Owner decides D-1 to D-5 (§9) | this report | written decisions in `PHASE1B_DECISIONS.md` |
| **M1 Pricing core** | `InventoryPricing.sol` library: `Ĉ` with linear extension (two-step forms), inverse, `straddle_cap`, quote; NatSpec; generated vector file | M0 | all 212 + 6 vectors equal; fuzz ≥ 100,000 runs of P-1, P-3 (straddle and D14 floors) and inverse exactness against the Solidity; overflow tests at the documented bounds; measured gas per function |
| **M2 Reference adapter** | push-feed adapter (decimals, inversion, staleness, divergence, round history or stored volatility), fail-closed errors | M0 (D-1) | every `ReferenceFailClosed` case on-chain; read-only Unichain fork test of the chosen feeds (needs approval for a public RPC); gas of two feeds and of the volatility term measured |
| **M3 Inventory hook** | new hook on `BaseCompatibleHook` reading vault state; no hook storage on the swap path; events of §10 of the spec | M1, M2 | real-PoolManager integration tests; root-cause tests inverted (reverse trades pass at a tracked pivot); invariant campaign extended with P-1, P-3, P-5, P-8 handlers, `fail_on_revert = true`; swap gas measured (target ≤ 320k, report if above); bytecode under EIP-170; vault bytecode unchanged |
| **M4 Shared reserve** | Hook A on the shared core (its flow fee as spread policy), or Hook A removed from the shared reserve | M3, D-3 | cross-hook tests: cycles lose, the cap binds across hooks, split across hooks ≤ single |
| **M5 Floor tracking** | D-2 option (1) runbook and monitoring; or option (2) vault change in its own reviewed milestone | D-2 | option (1): documented procedure plus a simulation of the chosen band and delay; option (2): full vault security suite, storage-layout and bytecode review, guardian rules unchanged |
| M6 FastPath quoter | Rust or TypeScript implementation of `QUOTE_INTERFACE_SPEC.md`; snapshot reader | M1 | 100% vector conformance; equal results against a local chain over 10,000 random swaps |
| M7 Product and calibration | SDK, dashboard, testnet deployment (approval required), historical replay for parameters | M3–M6 | historical replay reproduces the property tests' bounds; parameters chosen by the same pre-declared rule on held-out history |

## 9. Decisions requiring owner approval

- **D-1** Reference feeds as trusted hook inputs, chosen by `hookOwner`, with a change delay.
- **D-2** Floor pivot tracking: (1) owner runbook for UHI11, (2) bounded `floorKeeper` vault role later, (3) oracle
  floors in the vault (not recommended without a separate threat model).
- **D-3** Hook A: adopt the shared core, or leave the shared reserve.
- **D-4** Volatility term source: read past rounds (more gas, no state) or a stored estimate (one write per swap).
- **D-5** RFQ: excluded from the core (recommended). If wanted later, it must be inventory-checked and have its own
  flow budget.

## 10. Validation

Foundry 1.7.1, solc 0.8.26, Python 3.11.8 (standard library). All local.

| Command | Result |
|---|---|
| `forge fmt --check` | clean |
| `forge build` | exit 0 (pre-existing lint notes in `src/` only) |
| `forge test` (default profile: 1,000 fuzz runs, invariants 64 × 64) | 467 passed, 0 failed, 38 suites (the 460 of Phase 1B-3 plus 7 in `test/research/`) |
| `forge test --match-contract HookBRootCauseTest -vv` | 7 passed; logs the gas figures in §6 |
| `python3 -m unittest discover -s simulations/mm -v` | 22 passed (the random tests reach their assertions: e.g. 593/600 split cases, 300/300 cross-hook cases, 3,000/3,000 Solidity-form cases) |
| `python3 -m unittest discover -s simulations/pricing` | 22 passed (Phase 1B-3 model unchanged) |
| `python3 simulations/mm/rootcause.py` | output in `PHASE1B4_ROOT_CAUSE.md` |
| `python3 simulations/mm/vectors.py` | regenerates the committed file byte for byte (sha1 `ecd0c7007b27502ffedf984c2a8ee711bd98cfb2`) |
| `python3 simulations/mm/simulate.py --calibrate` | `results/calibration.md`, `calibration.json`; 3 min 36 s on 10 cores; not re-run for determinism |
| `python3 simulations/mm/simulate.py` | `results/heldout.md`, `heldout_summary.json`; byte-identical on a re-run with 6 workers |
| `git diff eaf3eff -- src/` | empty |
