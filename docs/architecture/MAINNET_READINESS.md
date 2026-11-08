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
| D-2 | Compiler `0.8.26`, via-IR, `cancun`, `bytecode_hash = none`, optimizer setting per contract recorded | Partial | Recorded in `foundry.toml`. The vault-specific setting (D19) is pending. |
| D-3 | Unichain supports every opcode used (`TSTORE`/`TLOAD`, `MCOPY`, `PUSH0`) | Not started | Verify on a fork against the live chain, not from documentation alone. |
| D-4 | Canonical Unichain PoolManager address and bytecode confirmed against Uniswap's published deployment | Not started | — |
| D-5 | No unreviewed dependency added; OZ used only for EIP-712 and signature checks (D12) | Partial | Policy written; enforce in review. |

## 2. Stateful invariants and conservation

| ID | Item | Status | Evidence or gap |
|---|---|---|---|
| I-1 | Existing 13 vault invariants pass at 256 runs × depth 128 | Done (current code) | `PRE1B2_CLEANUP_REPORT.md` §4 |
| I-2 | Phase 1B invariants INV-P1 … INV-R1 | Partial | INV-P1 and INV-R1 implemented; INV-A1 … A4 wait for 1B-2 |
| I-3 | Architecture invariants INV-M1 … M8 and curator invariants INV-C1 … C6 | Not started | `MODULAR_RISK_ENGINE.md` §9, `CURATOR_SECURITY_MODEL.md` §7 |
| I-4 | Real ERC-6909 balance = `B_a` + donations; ghost ledger equals backing | Done | `invariant_backingEqualsRealClaims`, `invariant_ghostLedgerConservation` |
| I-5 | 10,000-run fuzz profile on every fuzz test, plus a longer campaign (≥ 1,000 runs × 256 depth) before Gate 2 | Partial | CI profile exists; long campaign not run |

## 3. Malicious curator and hook

| ID | Item | Status | Evidence or gap |
|---|---|---|---|
| H-1 | Registered hook that misprices, over-requests, pulls without funding, or passes a foreign key | Done | `VaultSecurity` compromised-hook section, `MaliciousConsumerHook` |
| H-2 | Curator at maximum ceiling with a malicious hook; loss ≤ bound | Partial | Bound documented (T-01); test listed, not written |
| H-3 | Curator volume over time is bounded (L3 flow cap) | Not started | Gap identified in `MODULAR_RISK_ENGINE.md` §7.1 |
| H-4 | Freeze and revocation stop consumption in the same block | Not started | `CURATOR_SECURITY_MODEL.md` §7 |

## 4. Malicious module and reentrancy

| ID | Item | Status | Evidence or gap |
|---|---|---|---|
| M-1 | A compromised authorization module cannot move assets, unfreeze, un-revoke, or exceed ceilings, floors or flow caps | Not started | Requires a test module that calls `reserveFor` with arbitrary inputs |
| M-2 | Guardian disables the module in one call; allocations unchanged (INV-M8) | Not started | — |
| M-3 | ERC-1271 wallet: reentrant, gas burner, return bomb, signer change | Not started | `Mock1271Wallet` modes listed in `PHASE1B_THREATS_AND_PLAN.md` |
| M-4 | Vault transient reentrancy lock on every state-changing entry point except `unlockCallback`; token-callback reentry test | Not started | `MODULAR_RISK_ENGINE.md` §4.5 |
| M-5 | No call cycle between contracts (static review plus a test that the vault never calls the module) | Not started | — |

## 5. Signatures, replay and revocation

| ID | Item | Status | Evidence or gap |
|---|---|---|---|
| S-1 | Replay: same signature, same nonce, other chain, other vault, other module, outside the window | Not started | `CURATOR_SECURITY_MODEL.md` §3 |
| S-2 | Revival: after unfreeze, deregister and re-register, revocation, generation bump | Not started | same |
| S-3 | Nonce single use across direct and signed paths (INV-C6) | Not started | — |
| S-4 | Domain separator rebuilt after a chain-id change (fork test with `vm.chainId`) | Not started | — |

## 6. Pricing and trade splitting

| ID | Item | Status | Evidence or gap |
|---|---|---|---|
| P-1 | Current behaviour characterised | Done | `TRADE_SPLITTING.md`, `TradeSplitting.t.sol` |
| P-2 | Cumulative pricing implemented with split-invariance fuzz, aggregate cap, round trip, decay and stale-price tests | Not started | `CUMULATIVE_PRICING_SPEC.md` §7 |
| P-3 | Vault floors and the directional consistency check (D14) | Done | `PricePolicy.t.sol`, `invariant_directionalFloorsConsistent` |
| P-4 | Reference-price update procedure and staleness monitoring (off-chain) | Not started | Floors and `P` are static, set by governance |

## 7. Withdrawal and insolvency

| ID | Item | Status | Evidence or gap |
|---|---|---|---|
| W-1 | FIFO queue, partial fills, cancel, claim, dust, zero-asset states, donations | Done | `QueueGriefing`, `ZeroAssetStates`, `MultiLpAccounting`, invariants |
| W-2 | Flow limits and freeze never block LP exit paths (INV-M6, INV-C5) | Not started | — |
| W-3 | Bank-run scenario: every LP redeems while the maximum capacity is committed, frozen or revoked; time to full exit ≤ `MAX_HORIZON` plus queue processing | Not started | — |
| W-4 | One asset driven to zero by trading; deposits and exits stay defined | Done | `ZeroAssetStates.t.sol` |
| W-5 | Rounding never lowers `N_a / S` for remaining holders | Done | `invariant_noDilutionByLpOperations` |

## 8. Unichain fork and testnet validation

| ID | Item | Status | Evidence or gap |
|---|---|---|---|
| F-1 | Fork tests against the live Unichain PoolManager: deposit, swap through both hooks, redeem, queue | Not started | Needs an RPC URL with no secrets committed; owner approval |
| F-2 | Gas on Unichain (L2 execution plus L1 data cost) for swap, activation and redeem | Not started | — |
| F-3 | `block.timestamp` behaviour on Unichain (block time, flashblocks) checked against flow windows and expiry | Not started | — |
| F-4 | Testnet run with test tokens covering every emergency action (pause, halt, freeze, revoke, module disable, emergency release) | Not started | Gate 2 |

## 9. Deployment and source verification

| ID | Item | Status | Evidence or gap |
|---|---|---|---|
| X-1 | Deterministic deployment script; hook addresses mined for exact permission bits (CREATE2) | Not started | Tests use `deployCodeTo`, not mining |
| X-2 | Post-deployment verification script: on-chain bytecode equals the local build; every parameter (floors, ceilings, caps, buffers, roles, module) read back and compared with the reviewed configuration | Not started | — |
| X-3 | Source verified on the Unichain explorer for every contract | Not started | — |
| X-4 | No private key in the repository, environment files, scripts or command history; deployment through a hardware wallet or multisig | Not started | — |

## 10. Governance and emergency

| ID | Item | Status | Evidence or gap |
|---|---|---|---|
| G-1 | Owner is a multisig (threshold and signers documented) | Not started | D3: required before real value |
| G-2 | Loosening actions (floor down, ceiling up, cap up, unfreeze, register, module change) go through a timelock; tightening actions do not | Not started | — |
| G-3 | Guardian is a separate key or multisig with documented response times; runbooks for curator compromise, hook compromise, module compromise, stale price | Partial | Curator runbook drafted (`CURATOR_SECURITY_MODEL.md` §4) |
| G-4 | Emergency drill on testnet: pause and halt within one block of the decision; LP exits keep working | Not started | — |
| G-5 | Monitoring and alerts: floor proximity, flow-bucket saturation, queue length, `Q_a / N_a`, guardian actions | Not started | Off-chain |

## 11. Caps for limited real value

| ID | Item | Status | Evidence or gap |
|---|---|---|---|
| C-1 | Vault TVL cap (`B_a` cap per asset, checked in `deposit` and `initialDeposit`) | Not started | **Not in the current design; must be added before Gate 3.** |
| C-2 | Per-transaction cap on `amountOut` per `exchange` | Not started | Partly covered by L1 `maxOut`; add a vault-wide per-swap maximum |
| C-3 | Vault-wide, per-curator and per-hook flow caps configured conservatively | Not started | `MODULAR_RISK_ENGINE.md` §7 |
| C-4 | Exposure cap `maxReservedBps` set low (for example ≤ 50%) | Not started | — |
| C-5 | Allow-listed depositors during Gate 3 (optional) | Not started | Decision for the owner |

## 12. Independent review

| ID | Item | Status | Evidence or gap |
|---|---|---|---|
| R-1 | Independent security review of the vault, authorization module, hooks, pricing libraries and deployment scripts at a frozen commit | Not started | Required before Gate 3 |
| R-2 | Every finding fixed with a regression test, or accepted in writing with its risk stated | Not started | — |
| R-3 | Public documentation of the trust model: owner powers, guardian powers, what is not guaranteed (`PHASE1B_PRICE_POLICY.md` §13) | Partial | In repository docs; no user-facing version |

**Not claimed anywhere:** an audit, formal verification, a guaranteed LP exit time beyond the documented bounds, or
fair-market pricing.
