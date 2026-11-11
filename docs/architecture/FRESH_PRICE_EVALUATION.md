# Porkfolio — Fresh-Price Mechanisms on Unichain (Phase 1B-4.2)

**Status: VERIFIED where stated.** Read-only checks on Unichain mainnet (chain 130) on 2026-11-10, plus the providers'
own public repositories. No credentials were requested or used. Earlier records: `ORACLE_VERIFICATION_UNICHAIN.md`.

## 1. Sources

| Source | Style | Unichain deployment | Credentials to obtain fresh data | Evidence |
|---|---|---|---|---|
| Chainlink Data Feeds | A: read a published price | ETH/USD `0xBcE7…8CCa`, USDC/USD `0xbd1c…d75b`, sequencer `0x4956…F813` | none | ON-CHAIN; 0.5% / 24 h (ETH), 0.3% / 24 h (USDC) |
| RedStone push | A | ETH `0xe8D9…6FB2`, USDC `0xD158…9b8c`, adapter `0xFB12…4AA5` | none to read | ON-CHAIN; 0.5% / 6 h, 0.5% / 3 h |
| RedStone pull | B: verify a signed payload in the transaction | verification code is a library in the consumer contract (no shared on-chain verifier) | **yes**: the SDK routes `redstone-primary-prod` to an *authenticated* gateway (`oracle-gateway.a.redstone.finance`, API key from `apiKeyEnvPath`); unauthenticated requests got HTTP 403; the old public gateways did not connect | RedStone SDK `data-services-urls.ts`, `authenticated-gateway.ts`; probes |
| Pyth | B (update), then A (read the stored price) | `0x2880aB155794e7179c9eE2e38200202908C17B43` (`getValidTimePeriod` 60 s, version 1.4.6) | **yes**: Hermes update endpoint answered `unauthorized` | ON-CHAIN; stored ETH/USD 11.38 M s (132 days) old |
| Chainlink Data Streams | B | `VerifierProxy 2.0.0` at `0x60fAa7faC949aF392DFc858F5d97E3EEfa07E9EB`; fee manager `0xb86d1B8a3Bb1c5d7809F5E9EB009311D51d933c6` | **yes**: API key and user secret (Chainlink's own sample code); verification fees through the fee manager | Chainlink docs repository (`StreamsNetworksData.ts`); ON-CHAIN `typeAndVersion` |
| Uniswap v3 TWAP | A (on-chain, provider-independent) | factory `0x1f98…0003`; WETH/USDC 0.3% pool `0x8927…9E49`, cardinality 601 | none | ON-CHAIN; about 305,709 USDC + 514 WETH; 30-min TWAP tick 200,000 ≈ 485.06 M raw WETH per raw USDC, within 0.07% of the adapter's mid |

## 2. Cost and freshness (MEASURED unless marked)

| Mechanism | Gas | Freshness |
|---|---|---|
| two push sources (four legs) + sequencer through `PriceRiskAdapter` | 76,446 cold / 24,506 warm (fork) | as old as the 0.5% trigger allows; band ±0.82% for WETH/USDC |
| Uniswap v3 `observe([1800, 0])` | 15,659 cold (fork) | 30-minute average |
| RedStone signed-payload verification, in real Unichain relayer transactions (two feeds each) | 99,538 gas with 1,039 bytes of calldata; 134,114 with 1,497 bytes (whole transactions, including storage writes) | package stamped about 0.8 s before its block |
| Pyth update | NOT MEASURED (no payload obtainable without a key) | Pyth's own check: at most 60 s old |
| Data Streams verification | NOT MEASURED (no report obtainable without credentials) | seconds |

## 3. Style A (read a published price) vs style B (verify a signed update)

| | A: published on-chain price | B: signed update supplied with the transaction |
|---|---|---|
| Quote accuracy | limited by the deviation trigger: ±0.82% band on WETH/USDC today → quotes ≈ 70+ bps wide | limited by the payload's age window and the trader's choice of payload: ≈ 15–35 bps band (ESTIMATE from a 10–60 s window) |
| Transaction cost | ≈ 24–76k gas for the reads | reads + verification ≈ 60–130k gas (RedStone relayer evidence) + calldata ≈ 1–1.5 kB per payload + any provider fee |
| Settlement availability | permissionless: anyone can swap any time the feeds are live | needs a payload: **every current provider on Unichain requires credentials**; if the provider or the router is down, either nothing trades (mandatory payload) or the swap falls back to style A (optional payload) |
| Trust | provider's on-chain feed | provider's signer set; the trader picks which valid payload to submit (free option inside the age window); replay of a valid payload is possible until it ages out |
| FastPath fit | the quoter reads the same on-chain state; quotes stay valid until a new round | the quoter must also fetch the payload; quote and payload expire together; the cache key must include the payload hash |
| Protection against corrupted push feeds | none beyond the bracket | **only if the payload is mandatory**: with an optional payload an attacker simply omits it (simulated A4, price halved for a day: worst seed −395 bps with a 95%-available fresh source against −514 without; only a mandatory payload refuses every corrupted fill) |

## 4. Rules any signed source must meet before it may enter the adapter

1. Signer identity is checked on-chain against a fixed set (a threshold of distinct signers, for RedStone's model).
2. The age is measured against `block.timestamp` with a maximum window (seconds), and future timestamps are refused.
3. The payload's price enters the bracket intersection with the push sources, never alone. A signed price outside
   the push brackets therefore refuses the swap rather than being used.
4. Replay inside the window is accepted as a priced risk: the window, not a nonce, bounds it, and the band must
   cover the price movement within it.
5. **Missing payload**: the policy must be explicit. Either mandatory (no permissionless execution, credentialed
   dependency), or optional, which gives no extra protection against push-feed corruption, only tighter quotes when
   present.

## 5. Recommendation

No fresh-price mechanism on Unichain today can be both **permissionless and fresh**. The safest achievable operating
mode is **style A (two push providers) with the vault's inventory floor as the backstop**. Expect wide quotes (≈ 5%
of uninformed demand filled in the simulation) and accept that availability, not safety, is the cost. A
credentialed signed source improves quotes about eightfold in the simulation (fill 4.8% → 37.6%). It should be added
only as an **optional** tightening input that can never be the sole price, and only after a decision on the
credential and fee dependency (R-2). The Uniswap v3 TWAP is too thin to be a pricing source. It can be added later as
a third, provider-independent bracket with a wide threshold, to catch gross common-mode errors.
