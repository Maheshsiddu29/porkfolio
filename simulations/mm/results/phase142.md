Phase 1B-4.2. SYNTHETIC worlds; held-out seeds (201, 202, 203, 204)

### Held-out, Phase 1B-4.2 candidates: across regimes (median and worst regime)

| candidate | fill% median | fill% worst | reverse fill% median | LP vs HODL bps median regime | LP vs HODL bps worst regime | worst single world | arb rev/day median | max |dev|% worst |
|---|---|---|---|---|---|---|---|---|---|
| Q0 push bracket, dynamic floor only (Phase 1B-4.1) | 4.81 | 4.03 | 5.11 | 52.67 | 15.55 | -42.61 | 0.00 | 14.88 |
| Q1 push bracket + oracle risk boundary (kappa 15%) | 4.81 | 4.03 | 5.11 | 52.67 | 15.55 | -42.61 | 0.00 | 14.88 |
| Q2 push + fresh credentialed source (95% availability) + boundary | 37.61 | 6.45 | 41.84 | 170.14 | 112.61 | -17.75 | 0.00 | 14.98 |
| Q3 as Q2, kappa 5% | 37.29 | 7.46 | 44.67 | 166.92 | 113.23 | 65.36 | 0.00 | 4.99 |

### Attacks (3-day worlds, 4 seeds): LP vs HODL bps median / worst seed; arbitrage revenue per day; refusal causes (% of uninformed)

| attack | candidate | LP median | LP worst | arb/day | max dev% | oracle refusals | inventory refusals |
|---|---|---|---|---|---|---|---|
| A1 one source +1.5% for 6 h (inside the detection band) | Q0 | -10.9 | -16.9 | -295.6 | 15.0 | 0.1 | 6.5 |
| A1 one source +1.5% for 6 h (inside the detection band) | Q1 | -10.9 | -16.9 | -295.6 | 15.0 | 0.1 | 6.5 |
| A1 one source +1.5% for 6 h (inside the detection band) | Q2 | 27.5 | 20.8 | -203.0 | 15.0 | 7.5 | 0.3 |
| A1 one source +1.5% for 6 h (inside the detection band) | Q3 | 32.5 | 30.4 | -60.3 | 5.0 | 7.5 | 0.4 |
| A2 one source +3% for 30 min (detected) | Q0 | 11.0 | 8.4 | 0.0 | 5.7 | 0.7 | 0.0 |
| A2 one source +3% for 30 min (detected) | Q1 | 11.0 | 8.4 | 0.0 | 5.7 | 0.7 | 0.0 |
| A2 one source +3% for 30 min (detected) | Q2 | 37.9 | 32.4 | 0.0 | 6.6 | 0.7 | 0.0 |
| A2 one source +3% for 30 min (detected) | Q3 | 35.7 | 32.8 | 0.0 | 4.5 | 0.7 | 0.0 |
| A3 both sources +5% for 6 h (shared upstream) | Q0 | -16.9 | -42.8 | -1871.6 | 14.9 | 0.0 | 5.5 |
| A3 both sources +5% for 6 h (shared upstream) | Q1 | -16.9 | -42.8 | -1871.6 | 14.9 | 0.0 | 5.5 |
| A3 both sources +5% for 6 h (shared upstream) | Q2 | 2.3 | -10.8 | -1809.1 | 14.9 | 8.0 | 0.3 |
| A3 both sources +5% for 6 h (shared upstream) | Q3 | 22.6 | 16.6 | -578.6 | 5.0 | 8.0 | 0.4 |
| A4 malicious adapter: price halved for 1 day | Q0 | -812.4 | -1029.6 | -55588.7 | 14.9 | 0.0 | 17.4 |
| A4 malicious adapter: price halved for 1 day | Q1 | -407.4 | -514.3 | -28129.2 | 8.6 | 0.0 | 19.1 |
| A4 malicious adapter: price halved for 1 day | Q2 | -358.8 | -394.8 | -25288.5 | 8.5 | 32.2 | 0.9 |
| A4 malicious adapter: price halved for 1 day | Q3 | -96.7 | -111.3 | -7845.2 | 4.5 | 32.2 | 1.1 |
| A5 both feeds frozen through a -10% move over 2 h | Q0 | -52.1 | -70.0 | -172.0 | 14.9 | 0.2 | 3.5 |
| A5 both feeds frozen through a -10% move over 2 h | Q1 | -52.1 | -70.0 | -172.0 | 14.9 | 0.2 | 3.5 |
| A5 both feeds frozen through a -10% move over 2 h | Q2 | -41.1 | -46.4 | -3173.9 | 14.9 | 4.0 | 0.2 |
| A5 both feeds frozen through a -10% move over 2 h | Q3 | 6.2 | 4.3 | -867.3 | 5.0 | 4.0 | 0.3 |
| A6 sudden -8% jump | Q0 | -0.9 | -3.9 | 0.0 | 8.5 | 0.0 | 0.0 |
| A6 sudden -8% jump | Q1 | -0.9 | -3.9 | 0.0 | 8.5 | 0.0 | 0.0 |
| A6 sudden -8% jump | Q2 | 27.6 | 21.9 | 0.0 | 8.3 | 0.0 | 0.0 |
| A6 sudden -8% jump | Q3 | 29.1 | 25.0 | 0.0 | 3.9 | 0.0 | 0.0 |
| A7 depeg -15% in 1 h then drift | Q0 | -23.0 | -111.2 | 0.0 | 13.9 | 0.0 | 0.0 |
| A7 depeg -15% in 1 h then drift | Q1 | -23.0 | -111.2 | 0.0 | 13.9 | 0.0 | 0.0 |
| A7 depeg -15% in 1 h then drift | Q2 | 12.8 | -0.0 | -12.6 | 7.4 | 0.0 | 0.0 |
| A7 depeg -15% in 1 h then drift | Q3 | 18.3 | 9.0 | -8.2 | 4.9 | 0.0 | 0.1 |

### Inventory recovery (held-out; seconds from |deviation| > 10% back to < 5%)

- Q0 push bracket, dynamic floor only (Phase 1B-4.1): {'episodes': 68, 'median_s': 27740.0, 'max_s': 269040}
- Q1 push bracket + oracle risk boundary (kappa 15%): {'episodes': 68, 'median_s': 27740.0, 'max_s': 269040}
- Q2 push + fresh credentialed source (95% availability) + boundary: {'episodes': 107, 'median_s': 10670, 'max_s': 151920}
- Q3 as Q2, kappa 5%: {'episodes': 0, 'median_s': None, 'max_s': None}

### Strategy differentiation (held-out): across regimes (median and worst regime)

| candidate | fill% median | fill% worst | reverse fill% median | LP vs HODL bps median regime | LP vs HODL bps worst regime | worst single world | arb rev/day median | max |dev|% worst |
|---|---|---|---|---|---|---|---|---|---|
| S0 Hook B alone (no markup) | 37.61 | 6.45 | 41.84 | 170.14 | 112.61 | -17.75 | 0.00 | 14.98 |
| S1 Hook A (0->20 bps activity fee) + Hook B (10 bp markup) | 33.10 | 6.56 | 37.02 | 157.69 | 118.98 | 72.16 | 0.00 | 14.96 |
