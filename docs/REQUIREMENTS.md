# Product and engineering requirements — first milestone

## North-star claim

Allow at least **two different deployed hook contracts**, attached to two actual v4 pools, to use a common pool of ERC-6909 backing **without violating a defined per-currency reservation invariant**. Preserve a human-auditable account of who can consume what.

## Phase 0 acceptance (one local feasibility spike, no external deployment)

- [ ] Pin Foundry-compatible `v4-core` and `v4-periphery` versions/commits and document compiler/EVM settings (Cancun transient storage where used).
- [ ] Instantiate and use real Uniswap v4 `PoolManager` in Foundry integration tests. No fake-only `PoolManager`.
- [ ] Demonstrate non-zero ERC-6909 claim custody from an actual token deposit through `unlock` and correct delta settlement; do not describe an unbacked mint as funding.
- [ ] Demonstrate a non-zero `beforeSwapReturnDelta` interaction with actual v4 core where hook and router deltas reconcile by unlock end.
- [ ] Demonstrate two distinct hook contracts/pool keys and shared-reserve interaction, **or** produce a minimal, reproducible blocker with exact reason and line-level upstream evidence.
- [ ] A cap/buffer check must fail closed for over-allocation, wrong hook, wrong pool, and wrong currency. Model single and same-tx multi-swap contention, not imagined parallel EVM writes.
- [ ] Include one safety test where an unauthorized consumer cannot use the vault's ERC-6909 claims. No unlimited operator approvals.
- [ ] Precisely specify the guaranteed and non-guaranteed properties of any reserved capital; an immediate full-LP exit is not assumed.
- [ ] Include a reproducible command list, local git commits and a decision log.

## Allowed minimal design for spike

- One stablecoin-like ERC-20 for initial backing, and a second token to form actual v4 pool keys; add a third token only if needed to make the heterogeneous nature of the two pools convincing.
- A vault/registry implementing only the checks needed to prove custody and isolation.
- Two small but genuinely distinct v4 hooks. The first can apply a bounded fee policy and the second a bounded impact/spread policy. Avoid substituting only mocked hooks.
- Use a trusted minimal test router (`unlockCallback`) to prove the accounting path. Explicitly label it test-only.
- Phase 0 does **not** require end-user UI, upgradeability, optimistic quotes, full ERC-4626 support or production-ready economics.

## Deferred until green gate

- EIP-712 signed curator intents and nonces
- Epoch/ring-buffer mechanism and proofs
- Full multi-asset risk model and no-keeper liveness specification
- High-water-mark fees, manager reputation and governance
- ERC-4626 external lending/yield, Reactive Network and migration
- Mainnet TVL, protocol token, SDK, paper, leaderboard, production deployments

## Test quality

Include positive and negative cases. For swaps eventually cover: exact-in/out × both directions, negative and positive returned deltas, price limits, partial fills, int128/uint128 bounds, decimals and rounding. In Phase 0, if only one direction works, explicitly label the unproven cases rather than implying completeness.
