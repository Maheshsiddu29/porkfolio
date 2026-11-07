# UHI11: Heterogeneous v4 Hooks / Conditional Commitment Engine

This is a **Claude Code kickoff pack**, not a deployed protocol or completed Solidity implementation. It contains the user-supplied research blueprint, agent guardrails, a risk register, a scoped proof-of-feasibility task, and a schedule aligned with UHI11. The architecture is a *hypothesis* until tested against a pinned version of real Uniswap v4 contracts.

## Getting started

1. Extract the pack into a **new local repository directory** or carefully merge the documentation files into the existing project. Do not overwrite an existing `CLAUDE.md` without reviewing it.
2. Open a terminal at the repository root; run `git status` and ensure it is the intended local repo.
3. Launch Claude Code in the directory, and paste `prompts/01_FIRST_CLAUDE_TASK.md` into the conversation.
4. Review its findings, patches, local commits, and test output before approving any second phase.
5. **Manual publishing only**. Claude Code must not push/merge/open PRs, deploy, or use funded keys.

## Design identity

**Shared liquidity backplane + bounded curator commitments**. Distinct Uniswap v4 hooks could draw from a shared reserve through a policy-enforcing vault/adapter under explicit capacity limits. MVP goal: prove real v4 PoolManager ERC-6909 and return-delta integration before promising generic composability or guaranteed exits.

## Inputs

- `docs/reference/Master_Blueprint.pdf`: original user-supplied seven-page blueprint (research and proposed claims; **not** verified facts).
- `docs/ARCHITECTURE.md`: proposed system map and trust boundaries.
- `docs/REQUIREMENTS.md`: scoped acceptance criteria and non-goals.
- `docs/RISKS.md`: architectural questions that can invalidate the design.
- `docs/SCHEDULE.md`: competition-first timeline.

## Official technical references

- https://developers.uniswap.org/docs/protocols/v4/guides/custom-accounting
- https://developers.uniswap.org/docs/protocols/v4/guides/erc-6909
- https://developers.uniswap.org/docs/protocols/v4/guides/unlock-callback-and-deltas
- https://developers.uniswap.org/docs/protocols/v4/security
- https://github.com/Uniswap/v4-core
- https://github.com/Uniswap/v4-periphery
- UHI11 schedule: https://atrium.academy/sponsors

Claude must pin upstream dependency commits and record them. Never assume moving `main` is reproducible.

## Milestone 0 — build and test

```bash
git submodule update --init --recursive   # pinned v4-periphery (+ transitive v4-core) and forge-std
forge build
forge test -vvv                           # real PoolManager integration, adversarial, invariant, gas
forge fmt --check
forge test --match-contract GasBaseline -vv --isolate
```

Layout: `src/` (vault, hooks), `test/{integration,security,unit,invariant,gas,utils}`, `docs/architecture/`
(`ACCOUNTING_FLOW.md` — verified v4 behaviour, settlement mechanism, solvency model, blueprint corrections;
`MILESTONE0_REPORT.md` — validation evidence). `script/`, `simulations/`, `sdk/`, `frontend/` are reserved placeholders.

## Phase 1A — multi-LP shares and two-tier redemption

```bash
forge test -vvv                                                   # full suite (M0 regression + Phase 1A)
forge test --match-test test_demo_threeLps -vv                    # executable multi-LP demonstration
forge test --match-contract "LpGas|AuthorizationComparison|GasBaseline" --isolate -vvvv   # gas traces
FOUNDRY_PROFILE=ci forge test --match-test testFuzz               # 10,000-run fuzzing
```

The vault is a two-asset, in-kind, proportional-share reserve. It is not an ERC-4626 vault.

- **Model and derivations:** `docs/architecture/SHARE_ACCOUNTING.md`.
- **Validation, gas, decisions and Phase 1B proposal:** `docs/architecture/PHASE1A_REPORT.md`.

## Phase 1A-H — redemption security hardening

Changes:

- **Owner-only initialization.** Only the owner can seed the vault.
- **Inline queue processing in `redeem`.** A redeem now serves already-deliverable queued requests before the instant
  tier.
- **Defined zero-asset and dust behaviour.**

Docs:

- `docs/architecture/PHASE1AH_REPORT.md`: problems reproduced, fixes, validation, before/after gas.
- `docs/architecture/SHARE_ACCOUNTING.md` §10: zero-asset and dust states.
