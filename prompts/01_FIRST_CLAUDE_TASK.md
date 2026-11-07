# CLAUDE CODE — TASK 01: Pin v4 and prove real shared-reserve custom accounting

You are the implementation agent for a UHI11 Uniswap v4 project. Before writing code, read `CLAUDE.md`, `README.md`, `docs/ARCHITECTURE.md`, `docs/REQUIREMENTS.md`, `docs/RISKS.md`, `docs/SCHEDULE.md`, and the included `docs/reference/Master_Blueprint.pdf`. Treat the PDF as a hypothesis and do not repeat its quantitative claims as validated results.

**Only do Phase 0: architecture feasibility + minimal working Foundry integration spike.** Do not implement the large multi-phase roadmap in this task.

### Step 1 — Baseline and actual upstream contracts

- Run `pwd`, `git status --short --branch`, `git log -5 --oneline` (if repo exists); inspect existing code/config. Do not overwrite untracked or user-modified files.
- Locate tools (`forge --version`, `cast --version`, `solc --version` if available) and report any missing prerequisites. If empty repo, create the smallest useful Foundry project locally. If existing repo, preserve its structure.
- Pin the v4-core, v4-periphery, forge-std dependency commits and a compiler/EVM configuration compatible with your code. Document exact commit SHAs and relevant PoolManager, Hooks, BeforeSwapDelta, ERC6909, unlock callback source files.
- No fake core or broad unpinned dependencies. Do not modify upstream dependencies except through pinned package installation.

### Step 2 — Architecture audit BEFORE relying on assumptions

Write `docs/PHASE0_FEASIBILITY.md` that:
1. Explains the concrete claim funding path: how tokens become actual PoolManager ERC-6909 claims; who owns claims; how vault authorization would release them without blanket hook allowances; and how both hook and router deltas go to zero.
2. Determines whether two genuinely distinct v4 hooks can consume the same shared backing in one v4 unlock flow, preserving per-hook quotas. Explicitly note that independent hooks need not be trustworthy and a whitelisted adapter still requires a trust model.
3. Presents a counterexample to unconditional LP full withdrawals while commitments remain locked, and specifies a precise MVP withdrawal limitation (or stops for approval if product semantics change materially).
4. Explains the meaning and limitations of `beforeSwapReturnDelta` and ERC-6909 for this design; use actual upstream Solidity source lines and tests, not speculation.
5. Distinguishes physical claim balance, reserved capacity, non-reserved spillover, obligations already consumed, and vault share liabilities. Write candidate per-currency inequalities but label unproven invariants appropriately.
6. Records no-keeper expiration as **lazy on the next interaction**, not an autonomous time-triggered on-chain action.

### Step 3 — Implement and test a minimal real-v4 spike

If you find no structural blocker in Step 2:
- Create a minimal vault/commitment gate with real ERC-6909 claim custody and a policy-checked path for sending/resolving value. Do not create unlimited `setOperator` grants to consumers. Prefer a path where the vault itself authorizes the exact amount and the transfer/burn path can be reconciled on-chain. Avoid arbitrary additional components.
- Create **two genuinely distinct hook contracts** bound to different real v4 pools, each using `beforeSwapReturnDelta` where needed. Keep pricing elementary; do not simulate successful accounting with an unbacked hook mint or a mock pool manager.
- Use a minimal Foundry test router/unlock callback for real v4 swaps. Exercise actual deposit, claim mint, swap, quote/consumption bounds and final delta settlement. Include a nonzero returned hook delta, not just a no-op callback.
- Test at least: successful authorized consumption, per-consumer quota isolation, over-quota rejection, wrong pool/asset rejection, unauthorized hook denial, input conversion and rounding boundaries, and same-transaction two-hook contention. Test that reverting the transaction rolls back funding and commitment state.
- If a hypothesized path is impossible under the actual contracts, create a minimal reproducible failing case and **STOP**. Do not fake completion and do not substitute mock-only tests for the real PoC.

### Step 4 — Validation and local commits

- Run `forge fmt --check`, `forge build`, `forge test -vvv` and relevant custom tests. Report the exact output summary, with gaps honestly stated. Ensure all contract interactions in the proof use real pinned v4 core.
- Create 2-4 **small local commits** grouped by purpose (e.g., repo setup, feasibility documentation, minimal integration tests). Use clear commit messages. Do not push.
- Print: status PASS/PARTIAL/BLOCKED; file-level change summary; exact tests run/pass/fail; explicit upstream SHAs; remaining assumptions; local commit SHAs; `git status`; next proposed task.
- Finish with: `STOPPED: no push, merge, PR, deployment, or publication performed.`

### Safety and scope reminders

- No mainnet, testnet broadcast, private keys, tokens, real funds, remote writes, PR, push, merge, UI, SDK, paper, lending, performance fees, governance or Reactive Network in this task.
- Preserve existing repo modifications. If you need to make a substantial design correction, explain the tradeoff and wait for human review rather than hiding it.
- Never promise unconditional LP exit, keeper-free action on time passage, guaranteed execution/inclusion or +70% utilization based on the blueprint alone.
