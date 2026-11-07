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

## Required finishing report for each milestone

- **Status**: PASS / PARTIAL / BLOCKED, with reasons.
- **Architecture changes**: what was tested, what failed, what assumptions changed.
- **Files changed**, **local commits** with SHAs and descriptions.
- **Validation**: exact `forge build`, `forge test -vvv`, formatter, invariant commands and observed results, or an honest explanation of blocked tooling.
- **Residual risks and tests not run**.
- **Next action requiring human approval**.
- Last line: `STOPPED: no push, merge, PR, deployment, or publication performed.`
