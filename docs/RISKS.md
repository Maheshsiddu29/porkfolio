# Risk register and claims review — NOT YET RESOLVED

| ID | Severity | Claim / assumption | Required evidence or correction |
|----|----------|--------------------|---------------------------------|
| R1 | CRITICAL | `R + sum(Q) <= C` gives unlimited immediate exit rights. | Counterexample: C=100, R=20, Q=80, a depositor requesting 100 cannot necessarily exit without breaking Q. Define exact available-to-withdraw amount and redemption rules. |
| R2 | CRITICAL | Any independently authored hook can safely consume a vault's ERC-6909 backing. | Prove vault-enforced spending path; never give hooks blanket ERC-6909 allowances/operator status. Identify whitelist and hook adversarial assumptions. |
| R3 | CRITICAL | `beforeSwapReturnDelta` itself injects shared liquidity into arbitrary curves. | Test real PoolManager; positive/negative deltas and claim redemption must settle atomically. Avoid counting normal v4 pool liquidity and vault claims twice. |
| R4 | HIGH | Automatic O(1) expiry at timestamp transitions needs no transactions. | Contracts do not execute simply because time advances. Use lazy expiry on interaction; test skipped epochs, slot reuse, wrap and gas. Distinguish aggregate vs per-commitment complexity. |
| R5 | HIGH | Capital reservation always guarantees quoted swap execution. | Only capacity can be reserved; price, inclusion, revert conditions and sequencing remain outside the guarantee. Multi-asset mark-to-market and expiration are required. |
| R6 | HIGH | A view of a claim balance means instantly redeemable economic collateral. | Only account safe, actual assets/claims; external ERC-4626 withdrawal liquidity is not necessarily immediate. |
| R7 | HIGH | Signed curator EIP-712 messages imply no keeper/relayer is required. | Signature verifies authority; an external transaction still needs to submit it. Define actor paying gas and liveness. |
| R8 | HIGH | Dynamic fee override always works. | Only `key.fee.isDynamicFee()` pools can apply overrides. Include valid hook permission bits and deployment salt mining. |
| R9 | HIGH | Hyperbolic commitment fee is safe near `U=1`. | Divide-by-zero and overflow/rounding boundaries; cap utilization and guard denominator. |
| R10 | HIGH | `+70%`, `17% APY`, `$426k`, `50% ceiling` and white-space novelty are established. | Treat as research hypotheses pending reproducible model, provenance and competitive verification. Do not repeat as measured results. |
| R11 | HIGH | Same-block swaps are parallel EVM writes with race conditions. | EVM transactions are serially ordered; the meaningful hazard is stale off-chain liquidity advertising, sequencing, contention, and reversions. Precisely specify timing and transaction ordering. |
| R12 | HIGH | A fixed $50 TVL cap makes unaudited mainnet deployment safe. | Real funds still at risk. Use local tests and optionally controlled testnet only after owner approval; mainnet requires separate human safety gate. |

## Baseline external references

- https://developers.uniswap.org/docs/protocols/v4/security
- https://developers.uniswap.org/docs/protocols/v4/guides/unlock-callback-and-deltas
- https://developers.uniswap.org/docs/protocols/v4/guides/custom-accounting
- https://github.com/Uniswap/v4-core/blob/main/src/libraries/Hooks.sol
- https://github.com/Uniswap/v4-core/blob/main/src/ERC6909.sol
