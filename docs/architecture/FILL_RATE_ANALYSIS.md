# Porkfolio — Execution Availability and Rejection Attribution (Phase 1B-4.1)

**Status: SYNTHETIC analysis.** `python3 simulations/mm/simulate.py --phase141` (74 s on 10 cores). Output:
`simulations/mm/results/phase141.md` and `phase141_summary.json`. Nine regimes (the eight of Phase 1B-4 plus an
illiquid one with a vault 10× smaller) and four stress worlds. Every candidate's parameters were chosen on calibration
seeds by the Phase 1B-4 rule (worst regime's median LP-vs-HODL, then median). Results are on held-out seeds
(4 × 9 = 36 worlds per candidate). Nothing here is historical data.

What changed from Phase 1B-4: the feed model now uses the **verified** Unichain parameters
(`ORACLE_VERIFICATION_UNICHAIN.md`): 0.5% deviation triggers, a 24 h Chainlink heartbeat and a 6 h RedStone heartbeat,
with pair brackets of ±0.82% and ±1.02%. Phase 1B-4 had assumed a 0.2% / 1 h primary.

## 1. Candidates

| | Reference | Vault floor | Selected parameters |
|---|---|---|---|
| P0 | Phase 1B-4 assumed feeds, point mid | keeper-tracked pivot | C3 (20 bps, 15%, vol 50%) |
| P1 | verified feeds, point mid (not fail-safe) | keeper-tracked pivot | 40 bps, no volatility term |
| P2 | verified feeds, **bracket** (fail-safe) | **dynamic floor at the band** | 10 bps base, band mode |
| P3 | P2 plus a **hypothetical** fresh pull source (bracket ±15 bps, one slot old) | dynamic floor | 20 bps base, band mode |
| P4 | P2's core, Hook A and Hook B strategies side by side, best-price routing | dynamic floor | as P2 |

P3's source is not verified usable on Unichain (Pyth updates need an API key; Data Streams not checked). It is
included to measure what a fresh source would be worth, not as something available.

## 2. Why Phase 1B-4 reported a 34.3% median fill

Every uninformed order that is not filled has exactly one cause. The categories are the nine of the brief.
"Trader minimum-output constraint" means the protocol offered a quote and the trader declined it because it cost more
than their tolerance against an outside venue (lognormal, median 30 bps: an assumption of the demand model).

P0, held-out, share of uninformed orders:

| regime | filled | trader declined | flow limit | commitment limit | inventory cap | floor conflict | oracle | other |
|---|---|---|---|---|---|---|---|---|
| calm balanced | 34.9 | 64.8 | 0.3 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 |
| whales | 31.4 | 55.9 | 12.2 | 0.0 | 0.4 | 0.1 | 0.0 | 0.0 |
| volatile | 19.5 | 79.3 | 0.0 | 0.0 | 0.0 | 1.1 | 0.0 | 0.0 |
| illiquid | 6.1 | 12.4 | 59.6 | 11.0 | 10.4 | 0.3 | 0.0 | 0.0 |

**The 34.3% is almost entirely a demand-model effect.** In normal markets the protocol refuses under 2% of uninformed
orders. The rest of the gap is traders declining a quote of about 34 bps when their median tolerance is 30 bps.
Conditional on a quote being offered, the fill rate is the same 35%. The figure measures the assumed demand curve
against the spread, not a protocol limitation. A different tolerance assumption moves it one-for-one; no historical
data constrains that assumption here.

## 3. Results with verified feeds

Held-out, across the nine regimes ("fill given a quote" is the range over regimes):

| | fill, median | fill given a quote | worst-regime LP vs HODL | worst world | arbitrage revenue/day, median | quoted cost, calm |
|---|---|---|---|---|---|---|
| P0 (assumed feeds) | 34.0% | 19.7–38.3% | +90.9 | +8.6 | 0.0 | 33.9 bps |
| P1 point mid, verified | 22.9% | 18.7–25.7% | +63.3 | +40.0 | **−8.7** | 35.6 bps |
| **P2 bracket + dynamic floor** | **4.8%** | 4.4–5.0% | +15.6 | −42.6 | **0.0** | **73.4 bps** |
| P3 bracket + pull (hypothetical) | 39.1% | 37.7–40.4% | **+109.3** | −32.8 | 0.0 | 34.9 bps |
| P4 two strategies on P2 | identical to P2 | | | | | |

Per market type (median LP vs HODL bps / fill %):

| market | P1 | P2 | P3 |
|---|---|---|---|
| normal (calm balanced) | +117.4 / 25.6 | +46.1 / 4.9 | +177.1 / 39.3 |
| volatile | +63.3 / 23.0 (arbitrage −111/day) | +29.7 / 5.0 | +109.3 / 34.5 |
| illiquid | +208.2 / 6.0 | +323.0 / 4.0 | +181.0 / 6.4 |
| trending | +92.3 / 23.6 | +15.6 / 4.8 | +158.2 / 39.3 |
| primary manipulated +3% | +26.1 / 27.8 | +11.5 / 4.9 | +40.4 / 39.7 |
| both feeds manipulated +3% | +4.0 (arbitrage −1,079/day) | −6.2 (arbitrage −840/day) | **+35.3 (arbitrage 0)** |
| primary outage 6 h | +18.8 (arbitrage −100/day) | +7.3 | +25.3 |
| depeg −15% | −38.2 | −21.9 | +0.5 |

Reading:
- **Fail-safe pricing on the verified push feeds alone is safe and nearly unused.** Quotes must stay outside an
  approximately ±0.8% band, so about 95% of quotes are declined. Its LP results are positive but small; the illiquid
  regime is the exception, where each rare fill earns a wide spread.
- **A point mid on the same feeds is cheaper and is arbitraged.** The reference can sit 0.5% from the market for hours,
  so arbitrage shows up in every regime (−111/day volatile, −1,079/day when both feeds are corrupted). It also cannot
  coexist with a vault floor at the band, because its quotes sit inside the band.
- **A fresh independent source fixes both.** In P3 the intersection is set by the narrow source, and quoting costs
  about 35 bps. It also turns the "both push feeds corrupted" attack into a refusal: the honest fresh source's bracket
  no longer intersects theirs.
- **P4 = P2**: on one core, Hook A is Hook B plus a fee and receives no routed flow (`SHARED_ECONOMIC_CORE_SPEC.md` §5).

## 4. Avoidable and unavoidable refusals

| Cause | Where it binds | Avoidable without relaxing a guarantee? | How |
|---|---|---|---|
| Price-floor conflict | P0/P1: 0.1–3.4% (keeper lag) | **yes** | the dynamic floor (P2/P3: 0.0% in every regime) |
| Vault flow limit | whales, volatile, illiquid (up to 59.6%) | **partly** | size flow caps to the vault and expected flow; a cap that binds is doing its job, so loosening it is a risk decision |
| Curator commitment limit | illiquid (6–12%) | **yes, operationally** | allocations sized to the vault and refreshed more often than every 6 h; capacity, not safety |
| Inventory concentration | illiquid (5–12%), whales (≤0.5%) | **no** | the shared cap is the risk limit; a larger cap is a risk decision |
| Oracle uncertainty or staleness | outage (8.2%), manipulation (0.7%) | **no** | fail-closed by design |
| LP withdrawal reservation, physical inventory | 0.0% everywhere | — | in-kind exits never compete with trading for free inventory in these worlds |
| Pricing-model limitation (dust, impact bound) | 0.0% | — | — |
| Trader minimum-output constraint | 12–95% | **only by quoting tighter**, which needs a fresher reference (P3) or accepting arbitrage risk (P1) | the reference decision (D-1) |

## 5. Conclusions for the architecture

1. Safety is not what limits fills. The vault, the cap and the oracle together refuse little in normal markets.
2. With the verified feeds, the price of safety is the width of the oracle band. The architecture should not trade
   safety for fills by pricing inside that band (P1).
3. Execution availability therefore depends on adding a fresh, independent reference to the bracket. That needs a
   verified pull source (decision D-1 in `PHASE1B4_1_REPORT.md`). Until then, P2 is the safe configuration and should
   be expected to fill little.
4. The remaining avoidable refusals are operational: flow-cap and allocation sizing for small vaults, and floor lag,
   which the dynamic floor removes.
