# Porkfolio

UHI11: heterogeneous Uniswap v4 hooks drawing on a shared commitment vault (conditional commitment engine).

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

## Phase 1B-0 — price policy and curator authorization (specification only)

No Solidity changed. Review these before any Phase 1B implementation:

- `docs/architecture/PHASE1B_PRICE_POLICY.md`: minimum execution-price policy (units, 6/18-decimal normalization,
  effective floor `max(vault floor, curator floor)`, who may tighten and loosen, static floor vs oracle).
- `docs/architecture/PHASE1B_CURATOR_AUTH.md`: EIP-712 curator authorization, nonces, lifecycle and state machine,
  roles.
- `docs/architecture/PHASE1B_THREATS_AND_PLAN.md`: threat model, invariants, required tests, commit plan.

## Phase 1B-1 — risk roles and vault-enforced price floors

```bash
forge test --match-contract "PricePolicyTest|RolesTest|HookPriceBands" -vv   # new security and integration tests
FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-contract VaultInvariants
```

- **Price floors.** A vault floor per direction (Q64.96, raw input per raw output). The effective floor is
  `max(live vault floor, curator floor)`, checked on the exact ERC-6909 amounts moved.
- **Directional consistency.** `F0 · F1 ≥ 2^192` is enforced, so no round trip at the floors is profitable.
- **Guardian.** Tighten-only.
- **Ownership.** Two-step transfer.
- **Curators.** Must be registered.

Docs:

- `docs/architecture/PHASE1B_DECISIONS.md`: approved D1–D14.
- `docs/architecture/PHASE1B1_REPORT.md`: validation, size, gas, mutations, and the Phase 1B-2 plan.

## Phase 1B-2 step 1 — vault optimizer profile and `VaultLens`

```bash
test/bench/run.sh                                                  # production-artifact sizes, settings, gas
forge test --match-contract VaultLensTest -vv                      # lens vs vault execution
FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-contract VaultInvariants
```

- **Optimizer.** The vault is compiled with `optimizer_runs = 2,000` (runtime 17,035 B, EIP-170 margin 7,541 B).
  Everything else keeps 44,444,444. Test files that import the vault compile their whole import graph at 2,000 runs, so
  production gas comes from `test/bench/`, not `test/gas/`.
- **Lens.** `src/VaultLens.sol` serves the previews, the request status, `N_a`, `F_a`, `D_a`, deliverable shares and
  an allocation's effective floor. It has no state and no authority, and the vault never calls it. Call it as
  `lens.previewDeposit(vault, shares)`.

Docs: `docs/architecture/PHASE1B2_STEP1_REPORT.md`.

## Phase 1B-2.1 — curator state, revocation, cancellation and reentrancy lock

```bash
forge test --match-contract "CuratorLifecycleTest|CuratorCancellationTest|ReentrancyTest" -vv
forge test --match-path test/bench/ProductionArtifactSecurity.t.sol -vv   # security paths on production artifacts
FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-contract VaultInvariants
test/bench/run.sh
```

- **Curators.** Registration (may create) and restriction (None, Frozen, Revoked: may its allocations execute) are
  separate. The guardian can freeze and revoke; only the owner unfreezes; revocation is permanent. A `uint32`
  generation, raised by deregistration, unfreeze and `bumpGeneration`, invalidates instructions not yet turned into
  allocations; it never wraps.
- **Closing allocations.** `cancelAllocation` (the curator, in any state) and `release` (anyone after expiry or once
  the curator is revoked; owner or guardian otherwise) share one `_close` that releases exactly `maxOut − consumed`.
- **Reentrancy.** A transient lock on the ten accounting entry points.
- **Size.** Vault runtime 19,520 B (EIP-170 margin 5,056 B).

Docs: `docs/architecture/PHASE1B2_1_REPORT.md`.

## Phase 1B-2.2 — hierarchical flow limits and exposure caps

```bash
forge test --match-contract "FlowLimitsTest|ExposureCapsTest" -vv
test/bench/security.sh       # production-build security suite: forced rebuild, artifact checks, full suite (CI fuzz)
FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-contract VaultInvariants
test/bench/run.sh
```

- **Flow limits.** Per asset sold, gross output is capped per consumer hook, per curator and vault-wide in fixed
  one-day windows. Every swap is charged at all three levels and refused if any is full; inflows are never netted.
  A fixed window allows up to twice a cap across a window boundary; no rolling-window bound is claimed.
- **Exposure caps.** A new allocation must keep the hook's, the curator's and the vault's unused reserved capacity
  within a configured share of eligible backing (`N_a − D_a`), rounded down. Checked at creation only.
- **Fail closed.** A path whose hook, curator or vault record was never configured can neither reserve nor trade. The
  owner configures; the guardian can only tighten. Nothing resets usage before the window ends.
- **Production builds.** The functional suite (including fuzz and invariants) now runs on the production PoolManager,
  hooks and lens, checked against each artifact's settings and masked runtime hash.
- **Size.** Vault runtime 22,361 B (EIP-170 margin 2,215 B).

Docs: `docs/architecture/PHASE1B2_2_REPORT.md`.

## Phase 1B-2.3 — EIP-712 curator authorization module

```bash
forge test --match-contract "CuratorAuthorizationTest|AuthModuleLifecycleTest" -vv
test/bench/security.sh       # production-build security suite (also run by .github/workflows/security.yml)
FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-contract VaultInvariants
test/bench/run.sh
```

- **Separate module.** `CuratorAuthorization` verifies a curator's EIP-712 instruction (EOA or ERC-1271 wallet;
  domain "Porkfolio Vault", version 1) or takes the curator from `msg.sender` on the direct path, spends the
  instruction's nonce from one bitmap per curator, and asks its vault to `reserveFor` the allocation. Anyone may
  submit a signed instruction; no field can be changed after signing.
- **The vault decides.** `reserveFor` accepts only the installed module and checks registration, restriction,
  generation, hook, pool, pair, direction, floors, ceiling, admission, exposure caps and deadline on its own state.
  The old `allocate` entry point is gone, so every allocation passes through this boundary.
- **Off the hot paths.** The vault never calls the module. Swaps, cancellation, release and every LP path work the
  same with the module disabled; swap and LP gas are unchanged.
- **Lifecycle.** The owner installs or replaces the module; the guardian can only disable it. A module that was
  replaced or disabled is retired for good, so its unused signatures can never come back.
- **Size.** Vault runtime 22,433 B (EIP-170 margin 2,143 B); module 6,812 B.

Docs: `docs/architecture/PHASE1B2_3_REPORT.md`.

## Phase 1B-2.4 — Authorization security closure

```bash
forge test --match-contract "ModuleInstallationTest|ActivationSafetyTest" -vv
test/bench/security.sh       # now also fails if the vault's EIP-170 margin drops below 2,048 bytes
```

- **Install check.** `setAuthModule` reads `vault()` from the candidate (one `staticcall`) and refuses anything that
  does not answer with this vault's address; re-installing the installed module is refused. This catches mistakes,
  not malice: any contract that returns the right address passes, including the hooks.
- **Time rules.** Signed instructions must satisfy validAfter <= deadline < expiry with a window of at most one day,
  checked before the clock and before any wallet code; the direct path requires deadline < expiry. The EIP-712 type
  is unchanged. How long before its window an instruction was signed is still not bounded.
- **Size.** Vault runtime 22,524 B (EIP-170 margin 2,052 B); module 7,310 B. Swap and LP gas unchanged.

Docs: `docs/architecture/PHASE1B2_4_REPORT.md`, `docs/architecture/AUTH_SECURITY_RELEASE_NOTES.md`,
`docs/architecture/PHASE1B3_PLAN.md`.

## Authorization module installation hardening

```bash
forge test --match-contract ModuleInstallationTest -vv
forge test --match-test "test_PA_auth_(moduleInstallCheck|installLifecycleAndSpoofedModule)" -vv
```

- **Identity check.** Before installing a module, `setAuthModule` asks `authModuleId()` (must be `AUTH_MODULE_ID`)
  and then `vault()` (must be this vault). The hooks, which have a `vault()` getter naming the vault, are now
  refused. A malicious contract can still give both answers: the check catches configuration mistakes, and code
  verification stays mandatory (`MODULE_INSTALLATION_CHECKLIST.md`).
- **Size.** `reserveFor` reads each request field once (−550 bytes, same checks); with the identity check the vault
  is 22,049 B (EIP-170 margin 2,527 B). Allocation paths are 2,138 gas cheaper; swaps and LP paths unchanged.

Docs: `docs/architecture/AUTH_MODULE_INSTALL_HARDENING_REPORT.md`, `docs/architecture/MODULE_INSTALLATION_CHECKLIST.md`.
