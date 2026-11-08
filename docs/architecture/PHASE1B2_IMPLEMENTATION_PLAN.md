# Porkfolio — Phase 1B-2 Implementation Plan

**Status: IN PROGRESS.** D17 (architecture B) and D19 (vault at 2,000 runs) are approved. Step 1B-2.0 is done
(`PHASE1B2_STEP1_REPORT.md`); later steps have not started. This plan replaces the 1B-2 rows of
`PHASE1B_THREATS_AND_PLAN.md` §3. Every step follows `CLAUDE.md`:

- 2–4 coherent commits;
- NatSpec in the same commit as the code;
- each commit builds and passes the full suite;
- a stop for review at the end of each step.

**The trust boundary changes only in step 1B-2.3, and that step does not start without explicit approval.**

## Decisions needed before starting

| ID | Question | Recommendation | Blocks |
|---|---|---|---|
| D17 | Architecture A, B or C | B | 1B-2.3 |
| D18 | Unconfigured flow bucket: closed or unlimited | closed | 1B-2.2 |
| D19 | Vault optimizer setting | 2,000, margin ≥ 2,048 B | 1B-2.0 |
| D20 | Aggregate ring-buffer expiry | defer | — |
| D21 | Exposure cap `maxReservedBps` | adopt | 1B-2.2 |
| — | Confirm the superseded decisions in `CURATOR_SECURITY_MODEL.md` §9 (D6, D11, D15, D16) | — | 1B-2.1, 1B-2.3 |
| — | Is removing view functions from the vault ABI acceptable (callers move to the lens)? | yes, behind a lens with identical results | 1B-2.0 |

## Size policy (applies to every step)

- After each commit, run `forge build --force --sizes`.
- If the vault's EIP-170 margin falls below **2,048 B**, stop and report before going on. The fallback order is
  D12's levers.
- Prototype predictions for the vault at runs 2,000 (`MODULAR_RISK_ENGINE.md` §8.2):

| After step | Prototype vault runtime |
|---|---|
| 1B-2.0 (lens) | 16,682 |
| 1B-2.1 + 1B-2.2 (risk) | about 19,400 (ESTIMATE: Risk at 20,522 minus the 1,110 B the lens saves at this setting) |
| 1B-2.3 (B) | 19,391 |

The real code will be larger than the prototypes: NatSpec adds nothing, but errors, events and full checks do.
Measure; do not rely on these numbers.

## 1B-2.0 Size levers, no behaviour change (DONE)

As built: `2b82851` (benchmark harness first, so both sides are measured the same way), `ea370dd` (optimizer profile),
`b62a28f` (`VaultLens`), `a85ae4d` (lens deployment benchmark). Two deviations from the rows below:

- **`admissibleCapacity` and `getRequest` stay external on the vault.** The first is the exact admission rule the vault
  enforces, and keeping it costs 67 B. The second is the only way to read request records.
- **No test-only copy of the old views.** The lens is instead checked against the vault's real execution (deposit,
  instant redeem, queue finalization, allocation at the admission limit): in a fuzz test and in an invariant that
  runs on every campaign state. A one-off comparison against the old view code was also run (step 1 report).

Measured vault runtime at 2,000 runs: 17,035 B (prediction 16,682 B).


| # | Commit | Content | Tests and evidence |
|---|---|---|---|
| 1 | `build: vault-specific optimizer setting` | `compilation_restrictions` / `additional_compiler_profiles` for `src/SharedCommitmentVault.sol` per D19 | before/after sizes; gas tests with a note that test units importing the vault compile under its profile (`MODULAR_RISK_ENGINE.md` §8.1); a vault-only gas harness compiled separately to measure the true swap delta |
| 2 | `refactor: move view helpers to VaultLens` | new `src/VaultLens.sol` (stateless; reads public getters); vault keeps `getAllocation`, because hooks use it, plus the internal helpers | differential fuzz: lens output equals the old vault view on random states (the old views compiled into a test-only harness); the full existing suite with call sites switched to the lens; ABI diff documented |

**Stop for review.**

## 1B-2.1 Curator state, freeze, revocation, cancellation

| # | Commit | Content | Tests |
|---|---|---|---|
| 3 | `feat(vault): curator status and generation` | one packed curator slot (`status`, `generation`); `setCurator` maps to None/Active and bumps generation on deregistration; `freezeCurator`, `unfreezeCurator` (owner only, bumps generation), `revokeCurator` (terminal), `bumpGeneration`; `exchange` rejects Frozen/Revoked; `release` permissionless for Revoked | `test/security/CuratorLifecycle.t.sol`: every row of `CURATOR_SECURITY_MODEL.md` §4; frozen capacity stays in `Q_a` while LP redeem queues; revoke is terminal; INV-C1, C2, C4, C5 in the handler |
| 4 | `feat(vault): curator cancellation and shared close path` | `cancelAllocation` (any status); `_close(id, reason)` used by cancel, emergency, expiry and revoked release; `AllocationReleased` gets a reason | T-08 tests (`PHASE1B_THREATS_AND_PLAN.md`); double close reverts; INV-A3 |
| 5 | `feat(vault): transient reentrancy lock` | EIP-1153 lock on state-changing entry points except `unlockCallback` | re-entry attempts from a callback token mock on every entry point; gas delta measured |

**Stop for review.**

## 1B-2.2 Hierarchical flow limits and exposure cap

| # | Commit | Content | Tests |
|---|---|---|---|
| 6 | `feat(vault): leaky-bucket flow limits` | L2 per hook, L3 per curator, L4 vault-wide; `{uint112 cap, uint112 level, uint40-safe time}`; cap setters (owner raises, guardian lowers); D18 default | bucket arithmetic fuzz against a reference; INV-M5 with a ghost outflow log; warp across `2^32`; gaps longer than the window; bypass table in `MODULAR_RISK_ENGINE.md` §7.1, one test per row; INV-M6 differential on LP paths |
| 7 | `feat(vault): exposure cap` | L5 `maxReservedBps` checked in admission | boundary ±1; INV-M7 |
| 8 | `perf: packed curator bucket (measure, keep only if it saves gas)` | try packing the L3 bucket into the curator slot | `--isolate` swap gas before/after; revert the change if the saving is under 1,000 gas |

**Stop for review** with the measured swap gas against the prototype's +19,163.

## 1B-2.3 Authorization module (**trust boundary change; needs D17 approval**)

| # | Commit | Content | Tests |
|---|---|---|---|
| 9 | `feat(auth): CuratorAuthorization module with EIP-712 and unordered nonces` | `src/CuratorAuthorization.sol` (OZ 5.0.2 `EIP712`, `SignatureChecker`); `activate`, `activateDirect`, `invalidateNonces`; immutable vault; remapping for OZ; vault `reserveFor(req, curator, generation, signed)` restricted to `authModule`; `setAuthModule` (guardian: zero only); the vault's `allocate` and `nonceUsed` removed | `CuratorAuth.t.sol` (T-03, T-05, T-06, T-10; replay matrix S-1, revival S-2); `Mock1271Wallet` with all modes; M-1 malicious module; M-2 disable; INV-C3, C6, M2, M8 |
| 10 | `test: migrate the existing suite to the module path` | fixtures activate through the module; remove obsolete `nonceUsed` tests, replacing each with an equivalent module test | the full suite green; a count of removed versus replacement tests in the commit message |

**Stop for review.**

## 1B-2.4 Evidence

| # | Commit | Content |
|---|---|---|
| 11 | `test: Phase 1B-2 invariants, fuzzing and gas` | handler actions: activate (signed and direct), cancel, freeze, unfreeze, revoke, bump, invalidate, module disable, cap changes; all INV-M, INV-C and INV-A; 10,000-run fuzz; 256 × 128 invariants; `--isolate` gas for every path in `MODULAR_RISK_ENGINE.md` §8.2 |
| 12 | `docs: Phase 1B-2 report` | validation, sizes, gas against the prototypes, Slither triage, mutation results (M1–M11 of the earlier plan plus new ones for status, generation, buckets and the module check), residual risks |

## Later phases (not part of 1B-2)

- **1B-3 Cumulative pricing:**
  - `src/libraries/CumulativeCost.sol`;
  - hook state and decay;
  - the tests in `CUMULATIVE_PRICING_SPEC.md` §7;
  - invert the `TradeSplitting.t.sol` characterization tests into invariance properties.
- **1B-4 Readiness:**
  - TVL and per-transaction caps (`MAINNET_READINESS.md` C-1, C-2);
  - deployment and verification scripts;
  - Unichain fork tests. These need owner approval for any RPC use beyond local.

## Mutation checks to add (manual, not committed)

| Mutation | Must be caught by |
|---|---|
| `exchange` skips the Frozen/Revoked check | INV-C4, freeze tests |
| `unfreezeCurator` does not bump the generation | revival test S-2 |
| `revokeCurator` can be undone by `setCurator(true)` | INV-C2 |
| `reserveFor` accepts any caller | M-1 |
| `reserveFor` skips the generation check for signed requests | S-2 |
| Bucket decay rounds up | bucket reference fuzz, INV-M5 |
| Bucket timestamp truncated to `uint32` without wrap-safe math | the warp-across-`2^32` test |
| Flow limit applied to `redeem` | INV-M6 |
| Freeze releases capacity | INV-C5 |
| Signed path never sets the nonce bit | S-1 replay (same signature twice must revert) |
