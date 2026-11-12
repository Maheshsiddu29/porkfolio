# Phase 1B-4.4 inventory-tolerance calibration (SYNTHETIC)

### Exact-integer adversary: worst LP shortfall / entry value, by kappa and re-centring cadence

The adversary sets every fill price (malicious adapter); honest flow pays a 30 bp fee; 60 random sequences of 300 steps per cell; the worst of 6 price vectors including a full depeg of either asset.

| kappa | never re-centred | re-centred every 50 steps | re-centred every 10 steps | T1 violations | T2 breaches |
|---|---|---|---|---|---|
| 1% | 0.0239 (2.39 kappa) | 0.0239 (2.39 kappa) | 0.0235 (2.35 kappa) | 0 | 0 |
| 2% | 0.0551 (2.76 kappa) | 0.0552 (2.76 kappa) | 0.0464 (2.32 kappa) | 0 | 0 |
| 5% | 0.1118 (2.24 kappa) | 0.1118 (2.24 kappa) | 0.0949 (1.90 kappa) | 0 | 0 |
| 10% | 0.2099 (2.10 kappa) | 0.2099 (2.10 kappa) | 0.1812 (1.81 kappa) | 0 | 0 |
| 15% | 0.4098 (2.73 kappa) | 0.4113 (2.74 kappa) | 0.2869 (1.91 kappa) | 0 | 0 |

### Agent-based model (held-out seeds (201, 202, 203, 204) , 9 regimes; attacks: 7 x 4 seeds)

| candidate | fill% median | fill% worst regime | max dev% (asset1) | max dev / kappa | LP vs HODL bps median | LP exits paid instantly % (min) | recovery median s (episodes) | A4 worst bps | A4 / kappa |
|---|---|---|---|---|---|---|---|---|---|
| P01 push-only, kappa 1% | 4.14 | 1.44 | 0.99 | 0.99 | 32.0 | 100.0 | - (0) | -39.0 | 0.39 |
| F01 push + fresh (95%), kappa 1% | 35.20 | 12.28 | 1.00 | 1.00 | 127.3 | 100.0 | - (0) | -13.1 | 0.13 |
| P02 push-only, kappa 2% | 4.56 | 2.29 | 1.98 | 0.99 | 40.6 | 100.0 | - (0) | -88.9 | 0.44 |
| F02 push + fresh (95%), kappa 2% | 36.99 | 10.48 | 2.00 | 1.00 | 151.5 | 100.0 | - (0) | -38.5 | 0.19 |
| P05 push-only, kappa 5% | 4.70 | 3.38 | 4.96 | 0.99 | 48.5 | 100.0 | - (0) | -232.7 | 0.47 |
| F05 push + fresh (95%), kappa 5% | 37.29 | 7.46 | 4.99 | 1.00 | 166.9 | 100.0 | - (0) | -111.3 | 0.22 |
| P10 push-only, kappa 10% | 4.81 | 3.87 | 9.92 | 0.99 | 51.4 | 100.0 | - (0) | -386.0 | 0.39 |
| F10 push + fresh (95%), kappa 10% | 37.49 | 6.75 | 9.98 | 1.00 | 169.7 | 100.0 | - (0) | -254.2 | 0.25 |
| P15 push-only, kappa 15% | 4.81 | 4.03 | 14.88 | 0.99 | 52.7 | 100.0 | 27740 (68) | -514.3 | 0.34 |
| F15 push + fresh (95%), kappa 15% | 37.61 | 6.45 | 14.98 | 1.00 | 170.1 | 100.0 | 10670 (107) | -394.8 | 0.26 |
