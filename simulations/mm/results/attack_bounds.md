
### kappa 15%, flow cap 10% of holding per asset per day, guardian 24 h (ASSUMPTIONS)

| scenario | detection | loss per unit (fraction of price) | units at risk (per asset) | loss (value) | loss (bps of vault) | note |
|---|---|---|---|---|---|---|
| one source manipulated, delta <= 1.84% | none (inside both error bounds) | 0.0204 | 150,000 | 3,060 | 15.3 | per-unit bound 2 d_h holds for any delta below detection |
| one source manipulated, delta > 1.84% | ReferenceDivergence: refused | 0.0000 | 0 | 0 | 0.0 | fail closed |
| both sources wrong by 3% (shared upstream) | none from the feeds | 0.0218 | 150,000 | 3,270 | 16.4 | kappa and flow caps bound the units |
| both sources wrong by 5% (shared upstream) | none from the feeds | 0.0418 | 150,000 | 6,270 | 31.4 | kappa and flow caps bound the units |
| both sources wrong by 20% (shared upstream) | none from the feeds | 0.1918 | 150,000 | 28,770 | 143.8 | kappa and flow caps bound the units |
| malicious adapter (any price), both assets | timelock + guardian cancel before install | 1.0000 | 300,000 | 300,000 | 1,500.0 | the capital-at-risk bound: sum (N_a - L_a) p_a, rate-limited |
| both feeds frozen through a 5% move | staleness limit (6.5 h) or guardian | 0.0418 | 150,000 | 6,270 | 31.4 | units over 6.5 h |
| both feeds frozen through a 10% move | staleness limit (6.5 h) or guardian | 0.0918 | 150,000 | 13,770 | 68.9 | units over 6.5 h |
| sudden 8% jump, one-round feed lag | next round | 0.0718 | 150,000 | 10,770 | 53.9 | upper bound; the lag is usually much shorter than a flow window |
| feed misses its heartbeat past the staleness limit | source dropped: InsufficientSources | 0.0000 | 0 | 0 | 0.0 | availability loss only |
| sequencer down, or within 1 h of restart | SequencerUnavailable | 0.0000 | 0 | 0 | 0.0 | availability loss only |
| hook prices from a different configuration | vault re-checks with its own adapter | 0.0000 | 0 | 0 | 0.0 | hooks read the adapter from the vault; a mismatch can only cause refusals |

### kappa 15%, flow cap 40% of holding per asset per day, guardian 24 h (ASSUMPTIONS)

| scenario | detection | loss per unit (fraction of price) | units at risk (per asset) | loss (value) | loss (bps of vault) | note |
|---|---|---|---|---|---|---|
| one source manipulated, delta <= 1.84% | none (inside both error bounds) | 0.0204 | 150,000 | 3,060 | 15.3 | per-unit bound 2 d_h holds for any delta below detection |
| one source manipulated, delta > 1.84% | ReferenceDivergence: refused | 0.0000 | 0 | 0 | 0.0 | fail closed |
| both sources wrong by 3% (shared upstream) | none from the feeds | 0.0218 | 150,000 | 3,270 | 16.4 | kappa and flow caps bound the units |
| both sources wrong by 5% (shared upstream) | none from the feeds | 0.0418 | 150,000 | 6,270 | 31.4 | kappa and flow caps bound the units |
| both sources wrong by 20% (shared upstream) | none from the feeds | 0.1918 | 150,000 | 28,770 | 143.8 | kappa and flow caps bound the units |
| malicious adapter (any price), both assets | timelock + guardian cancel before install | 1.0000 | 300,000 | 300,000 | 1,500.0 | the capital-at-risk bound: sum (N_a - L_a) p_a, rate-limited |
| both feeds frozen through a 5% move | staleness limit (6.5 h) or guardian | 0.0418 | 150,000 | 6,270 | 31.4 | units over 6.5 h |
| both feeds frozen through a 10% move | staleness limit (6.5 h) or guardian | 0.0918 | 150,000 | 13,770 | 68.9 | units over 6.5 h |
| sudden 8% jump, one-round feed lag | next round | 0.0718 | 150,000 | 10,770 | 53.9 | upper bound; the lag is usually much shorter than a flow window |
| feed misses its heartbeat past the staleness limit | source dropped: InsufficientSources | 0.0000 | 0 | 0 | 0.0 | availability loss only |
| sequencer down, or within 1 h of restart | SequencerUnavailable | 0.0000 | 0 | 0 | 0.0 | availability loss only |
| hook prices from a different configuration | vault re-checks with its own adapter | 0.0000 | 0 | 0 | 0.0 | hooks read the adapter from the vault; a mismatch can only cause refusals |

### kappa 5%, flow cap 10% of holding per asset per day, guardian 24 h (ASSUMPTIONS)

| scenario | detection | loss per unit (fraction of price) | units at risk (per asset) | loss (value) | loss (bps of vault) | note |
|---|---|---|---|---|---|---|
| one source manipulated, delta <= 1.84% | none (inside both error bounds) | 0.0204 | 50,000 | 1,020 | 5.1 | per-unit bound 2 d_h holds for any delta below detection |
| one source manipulated, delta > 1.84% | ReferenceDivergence: refused | 0.0000 | 0 | 0 | 0.0 | fail closed |
| both sources wrong by 3% (shared upstream) | none from the feeds | 0.0218 | 50,000 | 1,090 | 5.5 | kappa and flow caps bound the units |
| both sources wrong by 5% (shared upstream) | none from the feeds | 0.0418 | 50,000 | 2,090 | 10.4 | kappa and flow caps bound the units |
| both sources wrong by 20% (shared upstream) | none from the feeds | 0.1918 | 50,000 | 9,590 | 48.0 | kappa and flow caps bound the units |
| malicious adapter (any price), both assets | timelock + guardian cancel before install | 1.0000 | 100,000 | 100,000 | 500.0 | the capital-at-risk bound: sum (N_a - L_a) p_a, rate-limited |
| both feeds frozen through a 5% move | staleness limit (6.5 h) or guardian | 0.0418 | 50,000 | 2,090 | 10.4 | units over 6.5 h |
| both feeds frozen through a 10% move | staleness limit (6.5 h) or guardian | 0.0918 | 50,000 | 4,590 | 22.9 | units over 6.5 h |
| sudden 8% jump, one-round feed lag | next round | 0.0718 | 50,000 | 3,590 | 17.9 | upper bound; the lag is usually much shorter than a flow window |
| feed misses its heartbeat past the staleness limit | source dropped: InsufficientSources | 0.0000 | 0 | 0 | 0.0 | availability loss only |
| sequencer down, or within 1 h of restart | SequencerUnavailable | 0.0000 | 0 | 0 | 0.0 | availability loss only |
| hook prices from a different configuration | vault re-checks with its own adapter | 0.0000 | 0 | 0 | 0.0 | hooks read the adapter from the vault; a mismatch can only cause refusals |
