Phase 1B-4.1. SYNTHETIC worlds. Calibration seeds (101, 102, 103, 104) held-out (201, 202, 203, 204)

### Calibration, point: across regimes (median and worst regime)

| candidate | fill% median | fill% worst | reverse fill% median | LP vs HODL bps median regime | LP vs HODL bps worst regime | worst single world | arb rev/day median | max |dev|% worst |
|---|---|---|---|---|---|---|---|---|---|
| point h=5 vol=0 | 11.55 | 2.30 | 14.99 | 15.60 | -158.96 | -221.16 | -419.05 | 15.00 |
| point h=5 vol=50 | 14.33 | 4.59 | 17.96 | 28.77 | -127.55 | -168.31 | -340.72 | 15.00 |
| point h=10 vol=0 | 15.52 | 3.83 | 18.51 | 34.24 | -134.88 | -200.58 | -328.29 | 15.00 |
| point h=10 vol=50 | 19.19 | 5.12 | 22.22 | 57.12 | -73.50 | -126.93 | -250.96 | 15.00 |
| point h=20 vol=0 | 26.02 | 5.47 | 28.06 | 77.41 | -83.36 | -138.36 | -164.70 | 15.00 |
| point h=20 vol=50 | 27.39 | 5.87 | 28.51 | 95.51 | 29.67 | -17.60 | -110.19 | 15.00 |
| point h=40 vol=0 | 23.37 | 6.17 | 24.84 | 114.93 | 82.38 | 59.12 | -9.35 | 15.00 |
| point h=40 vol=50 | 18.53 | 6.16 | 20.00 | 105.24 | 67.16 | 55.14 | -1.70 | 15.00 |

Selected for point: point h=40 vol=0

### Calibration, bracket: across regimes (median and worst regime)

| candidate | fill% median | fill% worst | reverse fill% median | LP vs HODL bps median regime | LP vs HODL bps worst regime | worst single world | arb rev/day median | max |dev|% worst |
|---|---|---|---|---|---|---|---|---|---|
| bracket h=2 vol=0 | 6.78 | 5.05 | 6.79 | 53.27 | 7.20 | -71.24 | 0.00 | 14.89 |
| bracket h=5 vol=0 | 6.07 | 4.80 | 6.17 | 54.75 | 7.70 | -66.98 | 0.00 | 14.89 |
| bracket h=10 vol=0 | 4.86 | 4.25 | 5.02 | 47.03 | 13.63 | -45.28 | 0.00 | 14.89 |
| bracket h=20 vol=0 | 3.13 | 2.96 | 3.42 | 35.47 | 7.81 | -7.34 | 0.00 | 14.89 |

Selected for bracket: bracket h=10 vol=0

### Calibration, bracket_pull: across regimes (median and worst regime)

| candidate | fill% median | fill% worst | reverse fill% median | LP vs HODL bps median regime | LP vs HODL bps worst regime | worst single world | arb rev/day median | max |dev|% worst |
|---|---|---|---|---|---|---|---|---|---|
| bracket+pull h=2 | 40.80 | 6.15 | 41.18 | 87.89 | -68.22 | -111.85 | 0.00 | 14.98 |
| bracket+pull h=5 | 41.21 | 6.17 | 41.83 | 103.85 | -40.56 | -106.73 | 0.00 | 14.98 |
| bracket+pull h=10 | 41.92 | 6.34 | 43.37 | 132.76 | 14.12 | -78.06 | 0.00 | 14.98 |
| bracket+pull h=20 | 39.39 | 6.32 | 43.38 | 185.09 | 97.20 | 20.85 | 0.00 | 14.98 |

Selected for bracket_pull: bracket+pull h=20

### Held-out, Phase 1B-4.1 candidates: across regimes (median and worst regime)

| candidate | fill% median | fill% worst | reverse fill% median | LP vs HODL bps median regime | LP vs HODL bps worst regime | worst single world | arb rev/day median | max |dev|% worst |
|---|---|---|---|---|---|---|---|---|---|
| P0 C3, assumed feeds (Phase 1B-4) | 34.02 | 6.13 | 37.89 | 151.74 | 90.89 | 8.62 | 0.00 | 15.00 |
| P1 verified feeds, point mid (point h=40 vol=0) | 22.89 | 6.03 | 24.37 | 117.15 | 63.31 | 40.02 | -8.72 | 15.00 |
| P2 verified bracket + vault dynamic floor (bracket h=10 vol=0) | 4.81 | 4.03 | 5.11 | 52.67 | 15.55 | -42.61 | 0.00 | 14.88 |
| P3 bracket + hypothetical pull (bracket+pull h=20) | 39.05 | 6.39 | 43.48 | 177.14 | 109.27 | -32.79 | 0.00 | 14.98 |
| P4 Hook A + Hook B strategies on P2's shared core | 4.81 | 4.03 | 5.11 | 52.67 | 15.55 | -42.61 | 0.00 | 14.88 |

### Rejection attribution, held-out (share of uninformed orders, %)

| regime | candidate | fill% | fill% given quotable | fill% given safe demand | physical inventory | LP withdrawal reservation | curator commitment limit | vault flow limit | inventory concentration | price-floor conflict | oracle uncertainty or staleness | trader minimum-output constraint | pricing-model limitation |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| calm balanced | P0  | 34.9 | 35.0 | 35.0 | 0.0 | 0.0 | 0.0 | 0.3 | 0.0 | 0.0 | 0.0 | 64.8 | 0.0 |
| calm balanced | P1  | 25.6 | 25.7 | 25.7 | 0.0 | 0.0 | 0.0 | 0.2 | 0.0 | 0.3 | 0.0 | 74.0 | 0.0 |
| calm balanced | P2  | 4.9 | 4.9 | 4.9 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 95.1 | 0.0 |
| calm balanced | P3  | 39.3 | 40.3 | 40.3 | 0.0 | 0.0 | 0.0 | 2.7 | 0.0 | 0.0 | 0.0 | 58.1 | 0.0 |
| calm balanced | P4  | 4.9 | 4.9 | 4.9 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 95.1 | 0.0 |
| one-sided flow | P0  | 34.5 | 34.7 | 34.7 | 0.0 | 0.0 | 0.0 | 0.5 | 0.0 | 0.1 | 0.0 | 64.9 | 0.0 |
| one-sided flow | P1  | 21.9 | 21.9 | 21.9 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.2 | 0.0 | 77.9 | 0.0 |
| one-sided flow | P2  | 4.8 | 4.8 | 4.8 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 95.2 | 0.0 |
| one-sided flow | P3  | 39.0 | 39.5 | 39.5 | 0.0 | 0.0 | 0.0 | 1.2 | 0.0 | 0.0 | 0.0 | 59.7 | 0.0 |
| one-sided flow | P4  | 4.8 | 4.8 | 4.8 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 95.2 | 0.0 |
| whales | P0  | 31.4 | 36.0 | 36.0 | 0.0 | 0.0 | 0.0 | 12.2 | 0.4 | 0.1 | 0.0 | 55.9 | 0.0 |
| whales | P1  | 21.9 | 22.9 | 22.9 | 0.0 | 0.0 | 0.0 | 3.8 | 0.3 | 0.2 | 0.0 | 73.8 | 0.0 |
| whales | P2  | 4.8 | 4.8 | 4.8 | 0.0 | 0.0 | 0.0 | 0.0 | 0.5 | 0.0 | 0.0 | 94.7 | 0.0 |
| whales | P3  | 32.3 | 40.4 | 40.4 | 0.0 | 0.0 | 0.0 | 19.5 | 0.5 | 0.0 | 0.0 | 47.6 | 0.0 |
| whales | P4  | 4.8 | 4.8 | 4.8 | 0.0 | 0.0 | 0.0 | 0.0 | 0.5 | 0.0 | 0.0 | 94.7 | 0.0 |
| splitters | P0  | 34.5 | 34.6 | 34.6 | 0.0 | 0.0 | 0.0 | 0.3 | 0.0 | 0.0 | 0.0 | 65.1 | 0.0 |
| splitters | P1  | 21.6 | 21.6 | 21.6 | 0.0 | 0.0 | 0.0 | 0.1 | 0.0 | 0.2 | 0.0 | 78.1 | 0.0 |
| splitters | P2  | 4.8 | 4.8 | 4.8 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 95.2 | 0.0 |
| splitters | P3  | 39.5 | 40.0 | 40.0 | 0.0 | 0.0 | 0.0 | 1.2 | 0.0 | 0.0 | 0.0 | 59.3 | 0.0 |
| splitters | P4  | 4.8 | 4.8 | 4.8 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 95.2 | 0.0 |
| volatile | P0  | 19.5 | 19.7 | 19.7 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 1.1 | 0.0 | 79.3 | 0.0 |
| volatile | P1  | 23.0 | 25.1 | 25.1 | 0.0 | 0.0 | 0.0 | 5.2 | 0.0 | 3.4 | 0.0 | 68.4 | 0.0 |
| volatile | P2  | 5.0 | 5.0 | 5.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 95.0 | 0.0 |
| volatile | P3  | 34.5 | 40.3 | 40.3 | 0.0 | 0.0 | 0.0 | 14.0 | 0.2 | 0.0 | 0.0 | 51.2 | 0.0 |
| volatile | P4  | 5.0 | 5.0 | 5.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 95.0 | 0.0 |
| trend | P0  | 32.4 | 32.5 | 32.5 | 0.0 | 0.0 | 0.0 | 0.1 | 0.0 | 0.1 | 0.0 | 67.4 | 0.0 |
| trend | P1  | 23.6 | 23.8 | 23.8 | 0.0 | 0.0 | 0.0 | 0.2 | 0.0 | 0.5 | 0.0 | 75.7 | 0.0 |
| trend | P2  | 4.8 | 4.8 | 4.8 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 95.2 | 0.0 |
| trend | P3  | 39.3 | 40.1 | 40.1 | 0.0 | 0.0 | 0.0 | 1.9 | 0.0 | 0.0 | 0.0 | 58.8 | 0.0 |
| trend | P4  | 4.8 | 4.8 | 4.8 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 95.2 | 0.0 |
| jump and partial recovery | P0  | 37.4 | 38.3 | 38.3 | 0.0 | 0.0 | 0.0 | 1.7 | 0.1 | 0.1 | 0.5 | 60.2 | 0.0 |
| jump and partial recovery | P1  | 23.2 | 23.2 | 23.2 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.2 | 0.0 | 76.7 | 0.0 |
| jump and partial recovery | P2  | 4.6 | 4.6 | 4.6 | 0.0 | 0.0 | 0.0 | 0.0 | 0.2 | 0.0 | 0.0 | 95.2 | 0.0 |
| jump and partial recovery | P3  | 39.2 | 40.0 | 40.0 | 0.0 | 0.0 | 0.0 | 1.8 | 0.0 | 0.0 | 0.0 | 58.9 | 0.0 |
| jump and partial recovery | P4  | 4.6 | 4.6 | 4.6 | 0.0 | 0.0 | 0.0 | 0.0 | 0.2 | 0.0 | 0.0 | 95.2 | 0.0 |
| LP withdrawals + one-sided | P0  | 34.0 | 34.1 | 34.1 | 0.0 | 0.0 | 0.0 | 0.2 | 0.0 | 0.1 | 0.0 | 65.7 | 0.0 |
| LP withdrawals + one-sided | P1  | 22.9 | 23.0 | 23.0 | 0.0 | 0.0 | 0.0 | 0.3 | 0.0 | 0.3 | 0.0 | 76.5 | 0.0 |
| LP withdrawals + one-sided | P2  | 4.8 | 4.8 | 4.8 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 95.2 | 0.0 |
| LP withdrawals + one-sided | P3  | 39.0 | 39.6 | 39.6 | 0.0 | 0.0 | 0.0 | 1.3 | 0.0 | 0.0 | 0.0 | 59.6 | 0.0 |
| LP withdrawals + one-sided | P4  | 4.8 | 4.8 | 4.8 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 95.2 | 0.0 |
| illiquid (vault 10x smaller) | P0  | 6.1 | 33.0 | 33.0 | 0.0 | 0.0 | 11.0 | 59.6 | 10.4 | 0.3 | 0.0 | 12.4 | 0.0 |
| illiquid (vault 10x smaller) | P1  | 6.0 | 18.7 | 18.7 | 0.0 | 0.0 | 6.0 | 54.6 | 6.7 | 0.3 | 0.0 | 26.3 | 0.0 |
| illiquid (vault 10x smaller) | P2  | 4.0 | 4.4 | 4.4 | 0.0 | 0.0 | 0.0 | 3.9 | 5.2 | 0.0 | 0.0 | 86.8 | 0.0 |
| illiquid (vault 10x smaller) | P3  | 6.4 | 37.7 | 37.7 | 0.0 | 0.0 | 11.9 | 59.6 | 11.5 | 0.0 | 0.0 | 10.6 | 0.0 |
| illiquid (vault 10x smaller) | P4  | 4.0 | 4.4 | 4.4 | 0.0 | 0.0 | 0.0 | 3.9 | 5.2 | 0.0 | 0.0 | 86.8 | 0.0 |
| primary outage 6 h in volatility | P0  | 17.9 | 19.7 | 19.7 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 1.1 | 8.2 | 72.8 | 0.0 |
| primary outage 6 h in volatility | P1  | 20.1 | 24.6 | 24.6 | 0.0 | 0.0 | 0.0 | 6.6 | 0.0 | 3.2 | 8.2 | 61.9 | 0.0 |
| primary outage 6 h in volatility | P2  | 4.6 | 5.0 | 5.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 8.2 | 87.2 | 0.0 |
| primary outage 6 h in volatility | P3  | 32.9 | 41.4 | 41.4 | 0.0 | 0.0 | 0.0 | 12.4 | 0.0 | 0.0 | 8.2 | 46.5 | 0.0 |
| primary outage 6 h in volatility | P4  | 4.6 | 5.0 | 5.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 8.2 | 87.2 | 0.0 |
| primary manipulated +3% for 30 min | P0  | 34.9 | 35.2 | 35.2 | 0.0 | 0.0 | 0.0 | 0.1 | 0.0 | 0.0 | 0.7 | 64.3 | 0.0 |
| primary manipulated +3% for 30 min | P1  | 27.8 | 28.9 | 28.9 | 0.0 | 0.0 | 0.0 | 2.7 | 0.0 | 0.4 | 0.7 | 68.4 | 0.0 |
| primary manipulated +3% for 30 min | P2  | 4.9 | 4.9 | 4.9 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.7 | 94.4 | 0.0 |
| primary manipulated +3% for 30 min | P3  | 39.7 | 40.2 | 40.2 | 0.0 | 0.0 | 0.0 | 0.6 | 0.0 | 0.0 | 0.7 | 59.0 | 0.0 |
| primary manipulated +3% for 30 min | P4  | 4.9 | 4.9 | 4.9 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.7 | 94.4 | 0.0 |
| both feeds manipulated +3% for 30 min | P0  | 34.0 | 34.7 | 34.7 | 0.0 | 0.0 | 0.0 | 1.1 | 0.4 | 0.2 | 0.3 | 63.9 | 0.0 |
| both feeds manipulated +3% for 30 min | P1  | 27.2 | 27.4 | 27.4 | 0.0 | 0.0 | 0.0 | 0.0 | 0.4 | 0.4 | 0.0 | 72.0 | 0.0 |
| both feeds manipulated +3% for 30 min | P2  | 4.8 | 4.9 | 4.9 | 0.0 | 0.0 | 0.0 | 0.0 | 3.5 | 0.0 | 0.0 | 91.7 | 0.0 |
| both feeds manipulated +3% for 30 min | P3  | 39.5 | 39.8 | 39.8 | 0.0 | 0.0 | 0.0 | 0.1 | 0.0 | 0.0 | 0.7 | 59.7 | 0.0 |
| both feeds manipulated +3% for 30 min | P4  | 4.8 | 4.9 | 4.9 | 0.0 | 0.0 | 0.0 | 0.0 | 3.5 | 0.0 | 0.0 | 91.8 | 0.0 |
| depeg -15% in 1 h then drift | P0  | 28.2 | 28.4 | 28.4 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.6 | 0.0 | 71.2 | 0.0 |
| depeg -15% in 1 h then drift | P1  | 27.2 | 28.7 | 28.7 | 0.0 | 0.0 | 0.0 | 3.1 | 0.0 | 2.2 | 0.0 | 67.5 | 0.0 |
| depeg -15% in 1 h then drift | P2  | 5.3 | 5.3 | 5.3 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 94.7 | 0.0 |
| depeg -15% in 1 h then drift | P3  | 37.9 | 40.5 | 40.5 | 0.0 | 0.0 | 0.0 | 6.4 | 0.0 | 0.0 | 0.0 | 55.7 | 0.0 |
| depeg -15% in 1 h then drift | P4  | 5.3 | 5.3 | 5.3 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 94.7 | 0.0 |

### Economics, held-out and stress (median LP vs HODL bps / worst seed / arbitrage per day / cost bps)

- calm balanced | P0 C3, assumed feeds (Phase 1B-4): 151.1 / 146.7 / 0.0 / 33.9; max dev 11.2%
- calm balanced | P1 verified feeds, point mid (point h=40 vol=0): 117.4 / 109.9 / -8.7 / 35.6; max dev 10.4%
- calm balanced | P2 verified bracket + vault dynamic floor (bracket h=10 vol=0): 46.1 / 30.8 / 0.0 / 73.4; max dev 10.1%
- calm balanced | P3 bracket + hypothetical pull (bracket+pull h=20): 177.1 / 173.1 / 0.0 / 34.9; max dev 11.2%
- calm balanced | P4 Hook A + Hook B strategies on P2's shared core: 46.1 / 30.8 / 0.0 / 73.4; max dev 10.1%
- one-sided flow | P0 C3, assumed feeds (Phase 1B-4): 142.5 / 134.9 / 0.0 / 33.8; max dev 10.6%
- one-sided flow | P1 verified feeds, point mid (point h=40 vol=0): 106.0 / 102.9 / -4.3 / 38.9; max dev 10.3%
- one-sided flow | P2 verified bracket + vault dynamic floor (bracket h=10 vol=0): 52.7 / 48.2 / 0.0 / 74.4; max dev 8.2%
- one-sided flow | P3 bracket + hypothetical pull (bracket+pull h=20): 167.9 / 159.6 / 0.0 / 34.9; max dev 9.6%
- one-sided flow | P4 Hook A + Hook B strategies on P2's shared core: 52.7 / 48.2 / 0.0 / 74.4; max dev 8.2%
- whales | P0 C3, assumed feeds (Phase 1B-4): 181.6 / 149.1 / -1.2 / 33.4; max dev 14.9%
- whales | P1 verified feeds, point mid (point h=40 vol=0): 152.9 / 142.4 / -8.8 / 39.2; max dev 14.9%
- whales | P2 verified bracket + vault dynamic floor (bracket h=10 vol=0): 77.0 / 66.6 / 0.0 / 73.9; max dev 14.9%
- whales | P3 bracket + hypothetical pull (bracket+pull h=20): 191.1 / 181.5 / 0.0 / 34.9; max dev 14.9%
- whales | P4 Hook A + Hook B strategies on P2's shared core: 77.0 / 66.6 / 0.0 / 73.9; max dev 14.9%
- splitters | P0 C3, assumed feeds (Phase 1B-4): 151.7 / 143.5 / 0.0 / 33.8; max dev 14.1%
- splitters | P1 verified feeds, point mid (point h=40 vol=0): 101.4 / 93.7 / -3.1 / 39.3; max dev 9.8%
- splitters | P2 verified bracket + vault dynamic floor (bracket h=10 vol=0): 43.9 / 34.9 / 0.0 / 74.7; max dev 8.9%
- splitters | P3 bracket + hypothetical pull (bracket+pull h=20): 175.2 / 171.1 / 0.0 / 34.8; max dev 9.6%
- splitters | P4 Hook A + Hook B strategies on P2's shared core: 43.9 / 34.9 / 0.0 / 74.7; max dev 8.9%
- volatile | P0 C3, assumed feeds (Phase 1B-4): 90.9 / 8.6 / 0.0 / 44.8; max dev 11.2%
- volatile | P1 verified feeds, point mid (point h=40 vol=0): 63.3 / 40.0 / -111.2 / 33.8; max dev 9.5%
- volatile | P2 verified bracket + vault dynamic floor (bracket h=10 vol=0): 29.7 / -42.6 / 0.0 / 72.8; max dev 12.9%
- volatile | P3 bracket + hypothetical pull (bracket+pull h=20): 109.3 / -32.8 / 0.0 / 33.9; max dev 15.0%
- volatile | P4 Hook A + Hook B strategies on P2's shared core: 29.7 / -42.6 / 0.0 / 72.8; max dev 12.9%
- trend | P0 C3, assumed feeds (Phase 1B-4): 121.9 / 110.5 / 0.0 / 35.2; max dev 8.2%
- trend | P1 verified feeds, point mid (point h=40 vol=0): 92.3 / 75.8 / -10.9 / 36.9; max dev 9.5%
- trend | P2 verified bracket + vault dynamic floor (bracket h=10 vol=0): 15.6 / -17.8 / 0.0 / 74.0; max dev 8.5%
- trend | P3 bracket + hypothetical pull (bracket+pull h=20): 158.2 / 141.0 / 0.0 / 34.7; max dev 12.3%
- trend | P4 Hook A + Hook B strategies on P2's shared core: 15.6 / -17.8 / 0.0 / 74.0; max dev 8.5%
- jump and partial recovery | P0 C3, assumed feeds (Phase 1B-4): 154.5 / 105.0 / -168.6 / 31.9; max dev 15.0%
- jump and partial recovery | P1 verified feeds, point mid (point h=40 vol=0): 117.2 / 75.8 / -139.6 / 38.2; max dev 15.0%
- jump and partial recovery | P2 verified bracket + vault dynamic floor (bracket h=10 vol=0): 55.7 / 16.1 / -142.4 / 75.2; max dev 14.9%
- jump and partial recovery | P3 bracket + hypothetical pull (bracket+pull h=20): 177.5 / 120.4 / -191.3 / 34.9; max dev 15.0%
- jump and partial recovery | P4 Hook A + Hook B strategies on P2's shared core: 55.7 / 16.1 / -142.4 / 75.2; max dev 14.9%
- LP withdrawals + one-sided | P0 C3, assumed feeds (Phase 1B-4): 219.5 / 211.7 / -0.1 / 34.4; max dev 14.1%
- LP withdrawals + one-sided | P1 verified feeds, point mid (point h=40 vol=0): 175.2 / 150.7 / -5.6 / 38.2; max dev 12.8%
- LP withdrawals + one-sided | P2 verified bracket + vault dynamic floor (bracket h=10 vol=0): 84.7 / 41.1 / 0.0 / 74.5; max dev 12.5%
- LP withdrawals + one-sided | P3 bracket + hypothetical pull (bracket+pull h=20): 260.3 / 253.6 / 0.0 / 34.9; max dev 15.0%
- LP withdrawals + one-sided | P4 Hook A + Hook B strategies on P2's shared core: 84.7 / 41.1 / 0.0 / 74.5; max dev 12.5%
- illiquid (vault 10x smaller) | P0 C3, assumed feeds (Phase 1B-4): 169.4 / 106.4 / -0.1 / 33.9; max dev 15.0%
- illiquid (vault 10x smaller) | P1 verified feeds, point mid (point h=40 vol=0): 208.2 / 179.9 / -1.3 / 42.7; max dev 15.0%
- illiquid (vault 10x smaller) | P2 verified bracket + vault dynamic floor (bracket h=10 vol=0): 323.0 / 286.9 / 0.0 / 76.0; max dev 14.9%
- illiquid (vault 10x smaller) | P3 bracket + hypothetical pull (bracket+pull h=20): 181.0 / 119.1 / 0.0 / 35.0; max dev 15.0%
- illiquid (vault 10x smaller) | P4 Hook A + Hook B strategies on P2's shared core: 323.0 / 286.9 / 0.0 / 76.0; max dev 14.9%
- primary outage 6 h in volatility | P0 C3, assumed feeds (Phase 1B-4): 17.3 / 10.3 / 0.0 / 44.6; max dev 6.8%
- primary outage 6 h in volatility | P1 verified feeds, point mid (point h=40 vol=0): 18.8 / 10.0 / -100.3 / 34.8; max dev 10.6%
- primary outage 6 h in volatility | P2 verified bracket + vault dynamic floor (bracket h=10 vol=0): 7.3 / 6.0 / 0.0 / 73.1; max dev 7.0%
- primary outage 6 h in volatility | P3 bracket + hypothetical pull (bracket+pull h=20): 25.3 / 22.5 / 0.0 / 33.5; max dev 8.0%
- primary outage 6 h in volatility | P4 Hook A + Hook B strategies on P2's shared core: 7.3 / 6.0 / 0.0 / 73.1; max dev 7.0%
- primary manipulated +3% for 30 min | P0 C3, assumed feeds (Phase 1B-4): 34.3 / 32.3 / 0.0 / 34.1; max dev 8.7%
- primary manipulated +3% for 30 min | P1 verified feeds, point mid (point h=40 vol=0): 26.1 / 19.2 / -15.5 / 33.5; max dev 9.1%
- primary manipulated +3% for 30 min | P2 verified bracket + vault dynamic floor (bracket h=10 vol=0): 11.5 / 10.0 / 0.0 / 74.6; max dev 6.9%
- primary manipulated +3% for 30 min | P3 bracket + hypothetical pull (bracket+pull h=20): 40.4 / 36.6 / 0.0 / 34.8; max dev 8.1%
- primary manipulated +3% for 30 min | P4 Hook A + Hook B strategies on P2's shared core: 11.5 / 10.0 / 0.0 / 74.6; max dev 6.9%
- both feeds manipulated +3% for 30 min | P0 C3, assumed feeds (Phase 1B-4): 13.6 / 4.7 / -863.0 / 33.3; max dev 15.0%
- both feeds manipulated +3% for 30 min | P1 verified feeds, point mid (point h=40 vol=0): 4.0 / 0.6 / -1078.9 / 34.6; max dev 15.0%
- both feeds manipulated +3% for 30 min | P2 verified bracket + vault dynamic floor (bracket h=10 vol=0): -6.2 / -30.0 / -839.9 / 74.1; max dev 14.9%
- both feeds manipulated +3% for 30 min | P3 bracket + hypothetical pull (bracket+pull h=20): 35.3 / 25.0 / 0.0 / 34.8; max dev 6.7%
- both feeds manipulated +3% for 30 min | P4 Hook A + Hook B strategies on P2's shared core: -6.2 / -30.0 / -839.9 / 74.1; max dev 14.9%
- depeg -15% in 1 h then drift | P0 C3, assumed feeds (Phase 1B-4): -24.8 / -46.1 / -1.7 / 39.2; max dev 9.5%
- depeg -15% in 1 h then drift | P1 verified feeds, point mid (point h=40 vol=0): -38.2 / -56.5 / -64.8 / 33.1; max dev 9.2%
- depeg -15% in 1 h then drift | P2 verified bracket + vault dynamic floor (bracket h=10 vol=0): -21.9 / -84.0 / 0.0 / 72.2; max dev 8.2%
- depeg -15% in 1 h then drift | P3 bracket + hypothetical pull (bracket+pull h=20): 0.5 / -16.5 / -4.5 / 34.6; max dev 7.6%
- depeg -15% in 1 h then drift | P4 Hook A + Hook B strategies on P2's shared core: -21.9 / -84.0 / 0.0 / 72.2; max dev 8.2%
