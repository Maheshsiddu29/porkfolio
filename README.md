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
