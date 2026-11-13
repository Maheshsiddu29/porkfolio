# Porkfolio — Security Release Checklist (Unichain)

**Status: CHECKLIST. No deployment of any kind is authorized.** Testnet broadcasting also needs explicit owner approval
(`CLAUDE.md` rule 2). Every item needs evidence (a commit, test name, command output or signed-off document) before
it can be marked done. Status values: **Done**, **Partial**, **Not started**.

## Gates

| Gate | Allows | Requires |
|---|---|---|
| **Gate 1: local complete** | nothing outside the local machine | every item in sections 1–7 Done or explicitly waived by the owner |
| **Gate 2: testnet** | Unichain Sepolia deployment with test tokens only | Gate 1; sections 8–9 Done for testnet; owner approval in writing |
| **Gate 3: limited real value** | Unichain mainnet with strict caps | Gate 2 observed for an agreed period without incident; sections 10–12 Done; independent review findings fixed or accepted in writing |

## 1. Dependencies and toolchain

| ID | Item | Status | Evidence or gap |
|---|---|---|---|
| D-1 | v4-periphery, v4-core, forge-std and OZ pinned by commit (submodules plus `foundry.lock`) | Partial | Submodules pinned (`v4-periphery c6e4754`, `forge-std v1.9.7`); OZ 5.0.2 vendored through v4-core. No record yet of why these commits were chosen or of a check for known advisories. |
| D-2 | Compiler `0.8.26`, via-IR, `cancun`, `bytecode_hash = none`, optimizer setting per contract recorded | Done (local) | `foundry.toml`: vault **200 runs** through `compilation_restrictions` (since Phase 1B-4.3: the vault with the market-risk boundary is over EIP-170 at 2,000 runs; `PHASE1B4_3_REPORT.md`); hooks, `VaultLens`, `CuratorAuthorization` and `VaultGovernor` 44,444,444. `ProductionArtifacts.VAULT_RUNS = 200` and `script/README.md` (pre-broadcast check) require the same value. Test files that import the vault compile their whole import graph at 200 runs, so production gas comes from `test/bench/`. `test/bench/run.sh` reads the settings back from each artifact's metadata and fails on a mismatch (`PHASE1B2_STEP1_REPORT.md` §2). `CuratorAuthorization` uses the default (44,444,444 runs) and is checked the same way (1B-2.3). |
| D-6 | Tests exercise the bytecode that will be deployed | Done (local) | Since 1B-2.2 the shared fixture (`VaultTestBase`) deploys the PoolManager, hooks and lens (and since 1B-2.3 the authorization module) from their production artifact files, so every unit, integration, security, fuzz and invariant test runs on production builds; each is checked against its artifact's recorded settings and masked runtime-code hash (`ProductionBuilds.t.sol`). `ProductionArtifactSecurity.t.sol` (21 tests, ABI only) and the gas benchmark also use production artifacts. Command: `test/bench/security.sh` (`PHASE1B2_2_REPORT.md` §6). Not covered: comparison with an independently reproduced build or with deployed bytecode (X-2). |
| D-3 | Unichain supports every opcode used (`TSTORE`/`TLOAD`, `MCOPY`, `PUSH0`) | Not started | Verify on a fork against the live chain, not from documentation alone. |
| D-4 | Canonical Unichain PoolManager address and bytecode confirmed against Uniswap's published deployment | Not started | — |
| D-5 | No unreviewed dependency added; OZ used only for EIP-712 and signature checks (D12) | Done (local) | `CuratorAuthorization` imports only OZ 5.0.2 `EIP712` and `SignatureChecker` (and through them `ECDSA`, `MessageHashUtils`, `ShortStrings`), through an explicit `@openzeppelin/contracts/` remapping to the copy vendored in v4-core (1B-2.3). Keep enforcing in review. |
| D-7 | CI runs the production-build security suite on every push and pull request | Partial | `.github/workflows/security.yml` (actions pinned by SHA and re-checked with `git ls-remote` in 1B-2.4, Foundry v1.7.1, read-only token, no secrets): `fmt --check`, `run.sh`, `security.sh`. Since 1B-2.4 the size gate (vault margin >= 2,048 B, EIP-170, EIP-3860) is in `security.sh` and in `test_productionSizesWithinLimits`, so a local run reproduces the job. Every step was run locally. The owner pushed `phase-1b-2-4-auth-security-closure` (`5489b70`); GitHub created run 42736981219 but did **not start the job** ("account is locked due to a billing issue"), so the workflow has still **never executed on GitHub**. |

## 2. Stateful invariants and conservation

| ID | Item | Status | Evidence or gap |
|---|---|---|---|
| I-1 | Existing 13 vault invariants pass at 256 runs × depth 128 | Done (current code) | `PRE1B2_CLEANUP_REPORT.md` §4 |
| I-2 | Phase 1B invariants INV-P1 … INV-R1 | Partial | INV-P1 and INV-R1 implemented; INV-A1 … A4 wait for 1B-2 |
| I-3 | Architecture invariants INV-M1 … M8 and curator invariants INV-C1 … C6 | Partial | INV-C1, C2, C4, C5 and INV-A2, A3 (1B-2.1); flow and exposure invariants INV-F1, F2, E1 (1B-2.2; the fixed-epoch form of INV-M5 and M7, `PHASE1B2_2_REPORT.md` §5.2); INV-C3, C6, M2, M8 (1B-2.3, `PHASE1B2_3_REPORT.md` §7). The remaining INV-M rows are covered by targeted tests, not invariants. |
| I-4 | Real ERC-6909 balance = `B_a` + donations; ghost ledger equals backing | Done | `invariant_backingEqualsRealClaims`, `invariant_ghostLedgerConservation` |
| I-5 | 10,000-run fuzz profile on every fuzz test, plus a longer campaign (≥ 1,000 runs × 256 depth) before Gate 2 | Partial | CI profile exists; long campaign not run |

## 3. Malicious curator and hook

| ID | Item | Status | Evidence or gap |
|---|---|---|---|
| H-1 | Registered hook that misprices, over-requests, pulls without funding, or passes a foreign key | Done | `VaultSecurity` compromised-hook section, `MaliciousConsumerHook` |
| H-2 | Curator at maximum ceiling with a malicious hook; loss ≤ bound | Partial | Bound documented (T-01); test listed, not written |
| H-3 | Curator volume over time is bounded (L3 flow cap) | Done (local) | Per-hook, per-curator and vault-wide gross-outflow caps per fixed one-day window, fail closed when unconfigured (`PHASE1B2_2_REPORT.md` §1–2). Boundary burst up to 2 × cap documented, not removed. |
| H-4 | Freeze and revocation stop consumption in the same block | Done (local) | `exchange` checks the curator restriction on every call. `CuratorLifecycle.t.sol`, `invariant_noConsumptionWhenFrozenOrRevoked`, production-artifact tests; mutant C1 killed |

## 4. Malicious module and reentrancy

| ID | Item | Status | Evidence or gap |
|---|---|---|---|
| M-1 | A compromised authorization module cannot move assets, unfreeze, un-revoke, or exceed ceilings, floors or flow caps | Done (local) | `MaliciousAuthModule` forging `reserveFor`: `test_ML_compromisedModuleBoundedByVault`, `test_PA_auth_compromisedModuleBounded`; mutants V1–V9 (1B-2.3 report §7). Impact stated there: equivalent to every registered, unrestricted curator signing, within their ceilings and every vault limit. |
| M-2 | Guardian disables the module in one call; allocations unchanged (INV-M8) | Done (local) | `test_ML_disableStopsOnlyNewActivations`, `test_PA_auth_disableReplaceAndLpPaths`, `invariant_moduleLifecycle`. A disable retires the module for good (resume = new module). |
| M-3 | ERC-1271 wallet: reentrant, gas burner, return bomb, signer change | Done (local) | `Mock1271Wallet` modes in `CuratorAuthorization.t.sol` and `test_PA_auth_reentrantWalletIsStatic`. A write attempt under `staticcall` burns the gas forwarded to the wallet; the cost falls on the submitter. |
| M-4 | Vault transient reentrancy lock on every state-changing entry point except `unlockCallback`; token-callback reentry test | Done (local) | Lock on the ten accounting entry points; configuration setters and `bumpGeneration` deliberately unlocked (`PHASE1B2_1_REPORT.md` §5). `Reentrancy.t.sol` with a callback token; mutants C15, C16 killed |
| M-5 | No call cycle between contracts (static review plus a test that the vault calls the module only where intended) | Done (local) | The vault makes two read-only calls to a module, `authModuleId()` then `vault()`, at installation only, and none on any other path: `test_ML_vaultCallsModuleOnlyAtInstall`, `test_MI_identityAskedFirst` (`vm.expectCall` counts). The module never receives a call from the vault while it runs. |
| M-6 | Installing a module checks that it is a module (`authModuleId()` = `AUTH_MODULE_ID`) for this vault (`vault()`); re-installing the installed module is refused | Done (local) | `setAuthModule` install check: `ModuleInstallation.t.sol`, `test_PA_auth_moduleInstallCheck` (18 candidate kinds), `test_PA_auth_installLifecycleAndSpoofedModule`, INV-M9. Both hooks are now refused. **Limit:** a malicious contract that returns both answers passes; code verification against a reproduced build (X-2) and the procedure in `MODULE_INSTALLATION_CHECKLIST.md` remain required. |

## 5. Signatures, replay and revocation

| ID | Item | Status | Evidence or gap |
|---|---|---|---|
| S-1 | Replay: same signature, same nonce, other chain, other vault, other module, outside the window | Done (local) | `CuratorAuthorization.t.sol` (replay group), `AuthModuleLifecycle.t.sol` (other module), `test_PA_auth_replayAndBindingMatrix` |
| S-2 | Revival: after unfreeze, deregister and re-register, revocation, generation bump | Done (local) | `test_CA_generationBumpInvalidatesOutstanding`, `_deregisterReregisterCannotRevive`, `_freezeUnfreezeAndRevoke`; retired modules: `test_ML_retiredModuleNeverReinstalled`; mutants L4, L5, V2 |
| S-3 | Nonce single use across direct and signed paths (INV-C6) | Done (local) | `test_CA_signedAndDirectShareNonces`, `invariant_noncesSingleUse`; mutants A1–A4 |
| S-4 | Domain separator rebuilt after a chain-id change (fork test with `vm.chainId`) | Done (local) | `test_CA_crossChainReplay` (`vm.chainId`; OZ rebuilds the separator). Not run on a real fork. |
| S-5 | Signed instructions have consistent, bounded times: validAfter <= deadline < expiry, window <= 1 day | Done (local) | 1B-2.4: `ActivationSafety.t.sol` (boundaries, reference fuzz), INV-T1, `test_PA_auth_signatureTimeRules`. |
| S-6 | Bound on how long before use an instruction may be signed (issuance time) | Not started | Needs a signed `issuedAt` field and a new EIP-712 type (version "2"); owner decision. Until then: `invalidateNonces`, `bumpGeneration`, module retirement (`AUTH_SECURITY_RELEASE_NOTES.md` §5). |

## 6. Pricing and trade splitting

| ID | Item | Status | Evidence or gap |
|---|---|---|---|
| P-1 | Per-swap behaviour characterised (before Phase 1B-3) | Done | `TRADE_SPLITTING.md` §1–6 (numbers kept); the tests now assert the cumulative behaviour |
| P-2 | Cumulative pricing implemented with split-invariance fuzz, aggregate cap, round trip, decay and stale-price tests | Done (local) | `PHASE1B3_REPORT.md`; `CumulativePricing.t.sol` (unit and integration), `PricingAdversarial.t.sol`, `TradeSplitting.t.sol`, INV-P2/INV-P4, Python model `simulations/pricing/` |
| P-5 | Owner decision on Hook B reversals under D14 floors (refused until the position decays) and on decay windows | Not started | `PHASE1B3_REPORT.md` §8 |
| P-6 | Loosening delay for hook pricing parameters | Done (local) | 1B-4.4: production hooks are deployed with `hookOwner = VaultGovernor`; every hook call waits DELAY and the guardian can cancel it (`test_hookParameters_waitDelay`, `GOVERNANCE_SECURITY.md` G2). Immediate tightening stays with the vault's guardian, whose edge and kappa changes reach both hooks at once. |
| P-3 | Vault floors and the directional consistency check (D14) | Done | `PricePolicy.t.sol`, `invariant_directionalFloorsConsistent` |
| P-4 | Reference-price update procedure and staleness monitoring (off-chain) | Designed, not implemented | Replaced on-chain by the market-risk adapter (`ORACLE_RISK_BOUNDARY_SPEC.md`); monitoring of feed ages and the sequencer still needed off-chain |
| P-7 | Vault-enforced oracle risk boundary (dynamic floor, uncertainty breaker, price-free inventory floor) | Done (local, not released) | `PHASE1B4_3_REPORT.md`; `INVENTORY_FLOOR_GUARANTEE.md`; `test/security/OracleRiskBoundary.t.sol`, `test/invariant/OracleRiskInvariants.t.sol`; vault at 200 runs |
| P-8 | Market-risk adapter for the launch pair, read-only, verified on a Unichain fork | Prototype done (local) | `src/oracle/PriceRiskAdapter.sol`, `test/oracle/`, `test/fork/UnichainOracles.t.sol`; `ORACLE_VERIFICATION_UNICHAIN.md` |
| P-9 | Capital-at-risk parameter `kappa` and hooks' caps aligned (≤ `kappa`) | Alignment enforced on-chain (hooks clamp to the vault's `kappa`); value not chosen | `KAPPA_SENSITIVITY.md`: 1–2% proposed for a first mainnet launch; decision R-4 |
| P-10 | Fresh signed price source (credentialed on Unichain) | Implemented as an option, not adopted | 1B-4.4: optional fresh tier in `PriceRiskAdapter`. A relayer narrows the band while it pushes; its outage widens the band instead of halting (`test/integration/RelayerOutage.t.sol`, `ORACLE_RELAYER.md`). Whether to run one is decision R-5. |
| P-11 | Timelock owner for every risk-increasing change | Done (local) | `src/governance/VaultGovernor.sol`; `test/governance/VaultGovernor.t.sol`; a deployment must verify `vault.owner() == governor` |
| P-12 | Hooks priced from the vault's adapter and inventory (shared core) | Done (local) | `BaseCompatibleHook` shared-core mode; `test/integration/SharedCoreHooks.t.sol`; fork gas `test/fork/UnichainIntegratedSwap.t.sol` |

## 7. Withdrawal and insolvency

| ID | Item | Status | Evidence or gap |
|---|---|---|---|
| W-1 | FIFO queue, partial fills, cancel, claim, dust, zero-asset states, donations | Done | `QueueGriefing`, `ZeroAssetStates`, `MultiLpAccounting`, invariants |
| W-2 | Flow limits and freeze never block LP exit paths (INV-M6, INV-C5) | Done (local) | Freeze and revocation: `test_CL_lpExitsWhileFrozenThenRevoked`, `test_PA_lpWithdrawalDuringRestrictedTrading`, INV-C5. Flow limits: never read on LP paths (SOURCE); `test_FL_lpPathsIgnoreFlowLimits_atHighUtilization`, `test_PA_flowUsageSurvivesLifecycle_lpExitsUnaffected`, INV-F1 (no LP action changes usage); mutant F21 (flow applied to `redeem`) killed. |
| W-3 | Bank-run scenario: every LP redeems while the maximum capacity is committed, frozen or revoked; time to full exit ≤ `MAX_HORIZON` plus queue processing | Not started | — |
| W-4 | One asset driven to zero by trading; deposits and exits stay defined | Done | `ZeroAssetStates.t.sol` |
| W-5 | Rounding never lowers `N_a / S` for remaining holders | Done | `invariant_noDilutionByLpOperations` |

## 8. Unichain fork and testnet validation

| ID | Item | Status | Evidence or gap |
|---|---|---|---|
| F-1 | Fork tests against the live Unichain PoolManager: deposit, swap through both hooks, redeem, queue | Not started | Needs an RPC URL with no secrets committed; owner approval |
| F-2 | Gas on Unichain (L2 execution plus L1 data cost) for swap, activation and redeem | Not started | — |
| F-3 | `block.timestamp` behaviour on Unichain (block time, flashblocks) checked against flow windows and expiry | Not started | Flow windows are fixed one-day epochs of `block.timestamp` (1B-2.2). |
| F-4 | Testnet run with test tokens covering every emergency action (pause, halt, freeze, revoke, module disable, emergency release) | Not started | Gate 2 |

## 9. Deployment and source verification

| ID | Item | Status | Evidence or gap |
|---|---|---|---|
| X-1 | Deterministic deployment script; hook addresses mined for exact permission bits (CREATE2) | Done (local, never broadcast) | `script/DeploySystem.s.sol` (CREATE2 factory, mined hook salts, production artifacts), `ExecuteQueued.s.sol`, `Rehearse.s.sol`; run end to end on a local chain in `test/script/DeployScripts.t.sol`. Sepolia only, with test parameters. |
| X-2 | Post-deployment verification script: on-chain bytecode equals the local build; every parameter read back and compared with the reviewed configuration | Done (local, never broadcast) | `script/VerifyDeployment.s.sol` gates 1–11, including `vault.owner() == governor`, `hookOwner() == governor` and masked runtime-code equality with the production artifacts (`ProductionArtifacts.requireProduction`). |
| X-3 | Source verified on the Unichain explorer for every contract | Not started | — |
| X-4 | No private key in the repository, environment files, scripts or command history; deployment through a hardware wallet or multisig | Not started | — |

## 10. Governance and emergency

| ID | Item | Status | Evidence or gap |
|---|---|---|---|
| G-1 | Owner is a multisig (threshold and signers documented) | Not started | D3: required before real value |
| G-2 | Loosening actions (floor down, ceiling up, cap up, unfreeze, register, module change) go through a timelock; tightening actions do not | Done (local) | `VaultGovernor` owns the vault and the hooks. Tightening goes through the guardian, immediately. A LONG_DELAY change (floor, ownership) also waits for an empty withdrawal queue (`GOVERNANCE_SECURITY.md`). Mainnet values still need R-3. |
| G-3 | Guardian is a separate key or multisig with documented response times; runbooks for curator compromise, hook compromise, module compromise, stale price | Partial | Curator runbook drafted (`CURATOR_SECURITY_MODEL.md` §4); module-compromise and exhausted-generation runbooks in `AUTH_SECURITY_RELEASE_NOTES.md` §3–§4 |
| G-4 | Emergency drill on testnet: pause and halt within one block of the decision; LP exits keep working | Not started | — |
| G-5 | Monitoring and alerts: floor proximity, flow-bucket saturation, queue length, `Q_a / N_a`, guardian actions | Not started | Off-chain |
| G-6 | Vault-scope exposure cap and a non-zero buffer floor in both assets, at the reviewed values. They set the capital needed to hold a LONG_DELAY change with one queued request (`G02_GOVERNANCE_LIVENESS.md` §5). The value is a reviewed choice; 50% is the rehearsal default, not a protocol invariant | Done (local, gated) | `DeploySystem` sets `BUFFER_FLOOR` and refuses zero; `VerifyDeployment` gate 9 compares cap and floor with the reviewed values and prints the blocking thresholds; `test_gates_deploymentPolicies`. Mainnet values not chosen (C-4) |
| G-7 | Inventory targets configured before any LP share exists | Done (local, gated) | `DeploySystem` sets targets and the buffer floor before `initialDeposit` and checks the target against the minted shares; gate 9 requires non-zero targets |
| G-8 | Vault owned by the reviewed governor with no pending nomination. A hand-over nominates only a production `VaultGovernor` for this vault, and is accepted in the nominating transaction where the admins coincide. Once a nomination has executed, nothing on-chain stops the nominee accepting, even during a retraction's DELAY | Done (local, gated) | Gate 1; gate 12 (`VerifyDeployment --sig "nominee()"`); `test_gate12_nomineeMustBeAReviewedGovernor`, `test_atomicHandover_leavesNoAcceptanceWindow`, `test_pendingNominee_canAcceptDuringRetractionDelay`. Decision R-13 |
| G-9 | Related governance calls in one transaction: release expired commitments, `processQueue`, `execute` for a LONG_DELAY change; nomination and acceptance for a hand-over | Partial (gated) | Gate 2 (mainnet): the admin must be a contract. That the multisig actually batches is procedural (G-1) |
| G-10 | After every guardian action and before every `execute`, no queued change loosens the current state unless it is re-approved in writing | Done (local, tool) | `script/CheckQueuedConflicts.s.sol`; `test_guardianCancellation_missesAPaddedCopy_conflictCheckFindsIt`, `test_conflictCheck_verdictsAfterGuardianEmergency`. Not run against a chain. Decision R-14 (on-chain rejection, not adopted) |
| G-11 | Blocked LONG_DELAY change: apply a lever no later than `queuedAt + LONG_DELAY + GRACE − MAX_HORIZON` (9 days at 32 / 7 / 30); later, cancel and re-queue with the lever held, or release in an emergency | Procedure documented | `G02_GOVERNANCE_LIVENESS.md` §13.1; gate 3 (mainnet) requires `LONG_DELAY > MAX_HORIZON`; `test_leverDeadline_isQueueTimePlusNineDays`, `test_leverAfterEta_originalExpires_recoveryPaths` |

## 11. Caps for limited real value

| ID | Item | Status | Evidence or gap |
|---|---|---|---|
| C-1 | Vault TVL cap (`B_a` cap per asset, checked in `deposit` and `initialDeposit`) | Not started | **Not in the current design; must be added before Gate 3.** |
| C-2 | Per-transaction cap on `amountOut` per `exchange` | Not started | Partly covered by L1 `maxOut`; add a vault-wide per-swap maximum |
| C-3 | Vault-wide, per-curator and per-hook flow caps configured conservatively | Partial | Mechanism built (1B-2.2); values not chosen. Size caps for the documented boundary burst (2 × cap). |
| C-4 | Exposure cap `maxReservedBps` set low (for example ≤ 50%) | Partial | Mechanism built at hook, curator and vault scope (1B-2.2); values not chosen. The vault-scope value and the buffer floor are now checked against the reviewed configuration (G-6). |
| C-5 | Allow-listed depositors during Gate 3 (optional) | Not started | Decision for the owner |

## 12. Independent review

| ID | Item | Status | Evidence or gap |
|---|---|---|---|
| R-1 | Independent security review of the vault, authorization module, hooks, pricing libraries and deployment scripts at a frozen commit | Not started | Required before Gate 3 |
| R-2 | Every finding fixed with a regression test, or accepted in writing with its risk stated | Not started | — |
| R-3 | Public documentation of the trust model: owner powers, guardian powers, what is not guaranteed (`PHASE1B_PRICE_POLICY.md` §13) | Partial | In repository docs; `AUTH_SECURITY_RELEASE_NOTES.md` (1B-2.4) states the owner trust boundary and operator guidance; no user-facing version |

**Not claimed anywhere:** an audit, formal verification, a guaranteed LP exit time beyond the documented bounds, or
fair-market pricing.
