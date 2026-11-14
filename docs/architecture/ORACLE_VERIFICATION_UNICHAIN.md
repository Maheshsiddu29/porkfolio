# Porkfolio — Oracle Verification on Unichain (Phase 1B-4.1)

> **Correction (G04, 2026-11-13).** The measurements below are unchanged.
> - **Uncertainty.** The uncertainty here (8,200 pips) uses the pre-G04 definition, measured from the mid on both
>   sides. The corrected adapter measures the lower side from the bracket's low end (`docs/security/G04_ORACLE_SAFETY.md`
>   §5, F-1) and reported 8,268 pips on a Unichain fork on 2026-11-13.
> - **Sequencer feed.** The uptime feed `0x4956…F813` came from Chainlink's feed directory. It is not on Chainlink's L2
>   Sequencer Uptime Feeds page, which no longer adds networks; see G04 §2.4.

**Status: VERIFIED where stated (read-only).** All on-chain values were read on 2026-11-10 from the public Unichain
mainnet RPC (`https://mainnet.unichain.org`, chain id 130; block about 63,611,362, timestamp about 1,794,359,743),
using `cast call` and a local Foundry fork. Nothing was broadcast, no key was used, and no paid or authenticated API
was used. Labels: ON-CHAIN (read from the contract), REGISTRY (the provider's own published configuration), FORK
(measured on a local fork by `test/fork/UnichainOracles.t.sol`), NOT VERIFIED.

Reproduce:

```
cast chain-id --rpc-url https://mainnet.unichain.org                                   # 130
UNICHAIN_RPC_URL=https://mainnet.unichain.org forge test --match-contract UnichainOraclesForkTest -vv
```

## 1. Sources found, and where each address came from

| Provider | Address source | Model | Status |
|---|---|---|---|
| Chainlink Data Feeds | Chainlink reference-data directory, `feeds-ethereum-mainnet-unichain-1.json` (12 feeds) | push | verified on-chain |
| RedStone push | RedStone relayer manifest, `redstone-oracles-monorepo/packages/relayer-remote-config/main/relayer-manifests-multi-feed/unichainMultiFeed.json` (12 feeds) | push | verified on-chain |
| Pyth | Pyth contract-manager store, `contract_manager/src/store/contracts/EvmPriceFeedContracts.json` (`unichain`, network 130) | pull | contract verified; **usable updates NOT VERIFIED** (§4) |
| Api3, Chronicle, eOracle, Stork | listed in Uniswap's "Oracles on Unichain" page | various | NOT VERIFIED (no addresses obtained in this phase) |

Token addresses (ON-CHAIN, and listed on Uniswap's Unichain contract-address page): USDC
`0x078D782b760474a361dDA0AF3839290b0EF57AD6` (6 decimals), WETH `0x4200000000000000000000000000000000000006`
(18 decimals). USDC has the lower address, so in a WETH/USDC pool USDC is currency0 and WETH currency1.

## 2. Feed records

| Feed | Contract (proxy / feed) | Pair, units | Decimals | Update rule (REGISTRY) | Latest answer and age (ON-CHAIN) | History | Aggregator |
|---|---|---|---|---|---|---|---|
| Chainlink ETH/USD | `0xBcE70e194940a157f3A80566505a7E96f5238CCa` | USD per ETH | 18 | 0.5% deviation, 86,400 s heartbeat | 2,048.39366098; 9,902 s | `getRoundData` works (phase 1, round 6,241) | `DualAggregator 1.0.0` at `0x171CD463…89af5` |
| Chainlink USDC/USD (#1) | `0xbd1cD1518eFB92a92100da62D4C488c810dFd75b` | USD per USDC | 18 | 0.3%, 86,400 s | 0.99971994; 9,724 s | works (phase 2, round 101) | `AccessControlledOCR2Aggregator 1.0.0` |
| Chainlink USDC/USD (#2) | `0x7E0145617F93fd5fc507Cf68D628Ebf59C76c04c` | USD per USDC | 18 | 0.3%, 86,400 s | 0.99972000; 9,689 s | works (phase 2, round 101) | `DualAggregator 1.0.0` |
| Chainlink BTC/USD | `0xC13f3E310Dd7436FA24338174acB64254b9A8039` | USD per BTC | 18 | 0.5%, 86,400 s | 73,323.70; 715 s | works | `DualAggregator 1.0.0` |
| Chainlink L2 sequencer uptime | `0x495639D9914e7D270c5dCC641BfB1d807423F813` | status (0 = up) | 0 | — | 0 (up); `startedAt` 1,793,291,075 | — | version 1 |
| RedStone ETH | `0xe8D9FbC10e00ecc9f0694617075fDAF657a76FB2` | USD per ETH | 8 | 0.5% deviation, 21,600 s heartbeat | 2,050.30881965; 10,505 s | **none**: round id is always 1 and `getRoundData` reverts | multi-feed adapter `0xFB1267A29C0aa19daae4a483ea895862A69e4AA5` |
| RedStone USDC | `0xD15862FC3D5407A03B696548b6902D6464A69b8c` | USD per USDC | 8 | 0.5%, 10,800 s | 0.99982887; 1,439 s | none | same adapter |
| Pyth (contract) | `0x2880aB155794e7179c9eE2e38200202908C17B43` | ETH/USD id `0xff61…0ace`; USDC/USD id `0xeaa0…c94a` (ids from Pyth's Hermes metadata API) | expo −8 | pull; `getValidTimePeriod()` = 60 s; version `1.4.6`; empty update fee 0 | stored ETH/USD price is **11,381,302 s (about 132 days) old**; USDC/USD about 1.2 years | — | proxy, implementation `0x99fa5f40…92a2` |

Observed update behaviour, from the last 60 rounds (ON-CHAIN, `getRoundData`):

| Feed | Gap between rounds (median / max) | Price change per round (min / median / max) | Reading |
|---|---|---|---|
| Chainlink ETH/USD | 1,560 s / 24,157 s | 50.14 / 54.12 / 90.05 bps | updates only on the 0.5% trigger; can sit 0.5% from the market for hours; a fast move can overshoot the trigger by 0.4% before the next round |
| Chainlink BTC/USD | 2,761 s / 77,243 s | 50.08 / 53.83 / 106.81 bps | same behaviour |
| Chainlink USDC/USD (both proxies) | 86,424 s / 86,430 s | 0.01–0.04 / 0.22–0.33 / 3.43 bps | heartbeat only for 60 days: USDC never moved 0.3% |

Staleness rules that follow: a staleness limit can only detect a dead feed after its heartbeat (24 h for Chainlink,
6 h / 3 h for RedStone). Freshness of the **price** cannot be inferred from age on a deviation-triggered feed: a 9,000 s
old answer is normal and still within 0.5% of the market while the feed is live.

## 3. Independence

- **The two Chainlink USDC/USD proxies are not independent of each other.** Their latest round id is identical
  (phase 2, round 101) and their answers differ by 6·10^-8 (0.99971994 vs 0.99972000), with different aggregator
  contracts. They are treated as one source.
- **Chainlink and RedStone are separate providers** with separate node operators and separate on-chain contracts.
  Both read similar market data; this is independence of operation, not of the underlying market.
- **The divergence check is coarse at these thresholds.** For the WETH/USDC ratio each provider's bracket stacks its
  two legs' thresholds: about ±0.82% (Chainlink: 50 + 30 bps, plus 1 bp margin per leg) and about ±1.02% (RedStone:
  50 + 50, plus margins). Two honest feeds can therefore differ by up to about 1.84% before the intersection is empty
  (`test_divergenceReverts`). A smaller manipulation of one source is not detected; it only shifts the intersection
  inside both error bounds.

## 4. Pull feeds: not verified as usable

- Pyth on Unichain only holds a fresh price inside a transaction that also submits a signed update. The stored price
  is about 132 days old, so without an in-transaction update it is unusable (FORK, `test_fork_pythStoredPriceAge`).
- Pyth's public Hermes endpoint returned `unauthorized` for update payloads on 2026-11-10 (the price-feed metadata
  endpoint still answered). Using it needs an API key. No key was requested or used, so neither the update fee nor
  the verification gas could be measured with a real payload: **NOT VERIFIED**.
- Chainlink Data Streams is listed for Unichain in Chainlink's changelog. Its verifier address, report format and
  access terms were not checked: **NOT VERIFIED**.

## 5. Fork experiment (FORK, measured)

`PriceRiskAdapter` deployed on a local Unichain mainnet fork, configured for WETH/USDC with Chainlink (USDC/USD #1,
ETH/USD) and RedStone (USDC, ETH) as its two sources, thresholds plus 1 bp margin, staleness = heartbeat + 30 min,
sequencer feed with a one-hour grace:

| Measurement | Value |
|---|---|
| `currentReference()`, all five feeds cold | 76,331 gas |
| `currentReference()`, warm | 24,391 gas |
| one `latestRoundData`, cold (Chainlink ETH / USDC, RedStone ETH / USDC, sequencer) | 16,553 / 18,865 / 24,011 / 15,011 / 16,755 gas |
| four Chainlink `getRoundData`, warm proxy | 24,878 gas |
| Pyth `getPriceUnsafe`, cold | 11,206 gas |
| Reading | mid 488,071,100 raw WETH per raw USDC (about 2,048.9 USD per ETH); uncertainty **8,200 pips (82 bps)**; valid for 10,192 s; 2 live sources |

The 82 bps is the decisive number. It is the half-width of the WETH/USDC price range that every live source still
allows. A quote that must stay outside that range, which is what a vault-side dynamic floor enforces, costs the
trader at least that much.

## 6. Testing approach where sources are unavailable

- **Unichain Sepolia (1301).** Chainlink lists five feeds there (`feeds-ethereum-testnet-sepolia-unichain-1.json`,
  8 decimals, 0.3–0.5% thresholds, 24 h heartbeats). RedStone publishes `unichainTestnetMultiFeed.json`. Neither was
  read on-chain in this phase. A testnet deployment would use them, with the same adapter configuration as above.
- **Local tests.** `test/oracle/PriceRiskAdapter.t.sol` drives the adapter with mock feeds shaped like the verified
  ones (decimals, thresholds, ages). The mocks prove the adapter's fail-closed logic. **They do not prove anything
  about mainnet oracle safety**; that rests on the providers.
