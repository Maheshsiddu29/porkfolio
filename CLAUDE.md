# Project-wide instructions for Claude Code

You are the **implementation agent**, not the release manager. The human owner reviews all significant design choices and all commits.

## Absolute operating rules

1. **Never push, force-push, merge, rebase onto a protected branch, open a PR, publish, tag releases, deploy, or upload files to an external service.** Do not trigger GitHub Actions by pushing. Do not change remotes.
2. **Never use real funds, mainnet transactions, wallets containing value, production RPC/API secrets, private keys, or approvals to public protocols.** Local Foundry tests and ephemeral test wallets are allowed. Even testnet broadcasting requires approval.
3. **Never run a destructive command** (`rm -rf` on repo content, `git reset --hard`, `git clean -fdx`, mass rewrites) without approval. Protect the existing worktree and untracked files.
4. Inspect `pwd`, `git status --short --branch`, `git log -5 --oneline`, existing repository structure, toolchain, and tests before edits. Preserve user changes. If branch is dirty, do not overwrite it; present a safe plan.
5. The master blueprint is **a proposed design, not a verified protocol specification**. Validate its claims against actual pinned v4 contracts and deliberately distinguish facts, assumptions, hypotheses and observed evidence.
6. Scope strictly to the assigned phase. Do **not** add frontend, SDK, oracle, governance, performance fees, lending, Reactive Network, formal paper, and mainnet deployment during feasibility spike.
7. Use minimal, idiomatic Solidity and Foundry. Favor correctness, readability and composability over tricks. Use existing upstream interfaces; don't fabricate `PoolManager` behavior or mock away critical accounting.
8. Fail closed at every trust boundary; require verified sender/pool/currency, explicit capacity, deadlines, anti-replay where appropriate, and safe accounting. Avoid unchecked user-controlled values and blanket operator grants.
9. Tests: unit, negative-path, adversarial, and real `PoolManager` integration. Log complete commands and results. A mock-only result does not qualify as integration evidence. Do not invent gas, APY, throughput, novelty, or utilization metrics.
10. Local commits are allowed and encouraged in **2-4 coherent, reviewable commits per milestone**, when feasible. Commits must not hide test failures. Do not squash the whole milestone into one commit. Do not commit secrets, build output or large generated artifacts.
11. If upstream v4 contracts make a proposal impossible, unsafe, or materially different, **stop and report the blocker**; do not silently substitute a different protocol or pretend the proof passed.
12. Do not describe an audit, formal proof, guaranteed LP exit, or O(1) expiry as accomplished without the relevant evidence.

## Documentation and NatSpec style

Every phase that adds or changes Solidity ships the documentation with the code, in the same commit. No separate cleanup phase.

**Audience.** An intermediate Solidity developer new to this project. Write as an engineer explaining their own code: what it does, why, and what it assumes.

**NatSpec (src/).**
- Contracts: `@title`, a `@notice` that says what the contract is for, and a `@dev` for custody, trust model, roles and anything not implemented.
- Public and external functions: `@notice` (purpose), `@dev` (caller restrictions, state changes, failure conditions, rounding), `@param` for every named parameter with units (raw token units, Q64.96, pips, shares, seconds), `@return` for every return value (begin with its name when it is named).
- Important internal functions: `@dev` explaining their role in accounting or settlement.
- Structs (fields via `@param`), storage variables, events and custom errors: document whenever the meaning is not obvious from the name. Internal and private state variables take `@dev` only; solc rejects `@notice` there.

**Mathematics.** For each important calculation, state what it computes, why, the units, the rounding direction and who it favours, the boundary cases, and a small numerical example when it helps. Never trade accuracy for simplicity. Keep overflow reasoning next to `FullMath`, casts and `unchecked` blocks.

**Tests.** Explain what a non-obvious test proves and why it matters: invariant handlers and ghost variables, multi-step swaps, malicious hooks, queue ordering, rounding, expected reverts. Do not narrate setup or obvious assertions.

**Do not.**
- Restate the function name as a sentence, explain Solidity syntax, or use marketing language ("robust", "seamless", "battle-tested", "cutting-edge", "optimal").
- Claim code is secure, gas-optimal, audited or formally verified without evidence.
- Describe planned features (signed allocations, curator cancellation, epoch expiry) as implemented. Say plainly when something is not implemented.
- Mention Claude, AI agents, phases, task labels, ADR numbers or earlier revisions in `src/` comments. Design history belongs in `docs/`.
- Leave comments about bugs that no longer exist, or comments that would become wrong if an unrelated line changed.

**Comment-only changes must be verified.** Run `forge fmt --check`, `forge build` and the full suite, and compare ABI, storage layout and runtime/init bytecode before and after. With `bytecode_hash = "none"` comments should not change bytecode; if they do, explain why before committing. If documenting reveals a bug, report it separately rather than fixing it in a documentation commit.

## Required finishing report for each milestone

- **Status**: PASS / PARTIAL / BLOCKED, with reasons.
- **Architecture changes**: what was tested, what failed, what assumptions changed.
- **Files changed**, **local commits** with SHAs and descriptions.
- **Validation**: exact `forge build`, `forge test -vvv`, formatter, invariant commands and observed results, or an honest explanation of blocked tooling.
- **Residual risks and tests not run**.
- **Next action requiring human approval**.
- Last line: `STOPPED: no push, merge, PR, deployment, or publication performed.`
