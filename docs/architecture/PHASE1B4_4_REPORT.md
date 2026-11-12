# Porkfolio — Phase 1B-4.4 Report: Governance Hardening, Financial Invariants, Execution Optimization

**Status: PASS (local).** Not approved for deployment.
- **Branch:** `phase-1b-4-4-integration-hardening`, from `phase-1b-4-3-oracle-integration` at `a2685a8`.
- **Verified at the start** (matching the 1B-4.3 report):
  - vault 22,249 B at 200 runs;
  - 539 tests passed, 8 skipped (fork, no RPC);
  - fork swap gas Hook B 417,221, Hook A 444,187.
- **Labels:** PROVEN, TESTED, MEASURED, SYNTHETIC.

Detail documents:
- `GOVERNANCE_SECURITY.md`
- `INVENTORY_PROTECTION.md`
- `HOT_PATH_GAS.md`
- `ORACLE_RELAYER.md`
- `CALIBRATION_1B44.md`
- `script/README.md`

## 1. Governor security findings

Full table: G1–G19 in `GOVERNANCE_SECURITY.md`. Audited against the implementation, together with every owner and
guardian path of the vault and every hook setter.
- **Routing.** No fallback, `delegatecall` or multicall exists in the vault or the hooks, so selector-based delay
  classes cannot be routed around.
- **These hold (TESTED):**
  - every vault owner call waits;
  - no immediate arbitrary call;
  - ownership leaves only after LONG_DELAY;
  - target, selector and arguments are bound;
  - no replay;
  - cancellation cannot be bypassed;
  - only the admin schedules; the admin or the guardian cancels (the guardian never its own replacement);
  - guardian restrictions stay immediate;
  - a compromised scheduler cannot shorten any delay;
  - an executor cannot substitute calldata or target;
  - full event trail.
- **Limits documented, not fixed:**
  - G15: an id is calldata-exact, so trailing bytes give a second id. Each copy is still delayed and cancellable.
  - G16: a queued address binds the address, not its code.
  - G17: a compromised guardian can impose liveness costs.
  - G18: without a guardian, nothing tightens immediately.
  - G19: no admin rotation.

## 2. Bypasses fixed

| # | Weakness | Fix | Evidence |
|---|---|---|---|
| G2 | Hook pricing setters were immediate (1B-4.3 P-6) | The governor governs targets: the vault, and hooks whose immutable `hookOwner()` is the governor and whose `vault()` is the vault. Every hook call waits DELAY and the guardian can cancel it. No hook code changed | `test_hookParameters_waitDelay`, `test_targets_onlyVaultAndOwnHooks` |
| G13 | A floor loosening could apply to an LP still in the withdrawal queue. The delay protected only LPs who queued within `LONG_DELAY − MAX_HORIZON` = 2 days of the announcement | LONG_DELAY calls revert with `PendingWithdrawals` while `vault.pendingShares() != 0`. 0 bytes in the vault | `test_queuedLp_lateInNotice_blocksLooseningUntilFinalized` (fails without the check); stateful campaign |
| G14 | Constant delays made a testnet rehearsal of a 32-day change impractical | Delays are constructor immutables, validated. Mainnet values are a release gate (gate 3) | `test_constructor_rejectsBadDelays` |

**Not a new trust boundary.** It is the same governor, admin and guardian; the hooks' owner becomes the governor.

## 3. Governance delays

`GOVERNANCE_SECURITY.md` §3. All values are still provisional (R-3).
- **DELAY, 3 days.** Ordinary changes cannot lower the price-free floor. They change how fast the room above it can be
  used. The delay gives notice and time to cancel; queued LPs stay exposed only down to the unchanged floor.
- **LONG_DELAY, 32 days** (floor, ownership). Now a notice period. The queue check is what guarantees that **every LP
  who requests a withdrawal before execution is finalized under the old floor**.
  - Without the check, only LPs who request within 2 days are covered.
  - Griefing the check needs pending shares above `1 − b` of supply (`b` = vault exposure cap) behind older
    commitments. The guardian can release those commitments immediately.
- **GRACE, 7 days.** Matured approvals expire.

**Adversarial scenarios (TESTED):**
- a late commitment followed by a late LP;
- pause, halt and freeze during notice (exits still work);
- ownership transfer with a queued LP;
- a compromised admin replacing the guardian.

Immediate tightening is kept (guardian), and it reaches both hooks.

## 4. Inventory protection: results and counterexamples

`INVENTORY_PROTECTION.md`.

**The four quantities are kept apart:**
- Q1: per-share units.
- Q2: shortfall against the LP's own entry basket.
- Q3: cumulative realized loss.
- Q4: mark-to-market loss.

**Stateful campaign** (both hooks, malicious consumer, two curators, three LPs, queued exits, governed loosening with
the queue check, adapter replacement, price jumps, depegs, corrupted references, multi-day time):
- 256 × 128, `fail_on_revert`: **4/4 invariants, 32,768 calls, 0 reverts.**
- **Q1 and Q2 hold.** Queued requests never gained room from a loosening.

**Counterexamples** (deterministic, real vault):
- Loss of **8.65% of value at κ 5%** once gains lift holdings (C4). Remedy: re-centring `τ`.
- Cumulative realized loss **1.5 × κ · V₀** with refills and new capital.
- Depeg: **−49.5%** mark-to-market while Q1 and Q2 hold.
- **The smallest:** exact T2 fails by under one raw unit (`floor(2.85) = 2`).

**No violation of Q1 or Q2 was found.** One handler weakness was found and fixed in commit `2a94975`: an over-strict
non-vacuity rule. **Process failure:** the preceding commit `58cfe0f` was made while that rule failed 8 runs. History
was not rewritten; the fix commit records it.

## 5. Performance (MEASURED)

`HOT_PATH_GAS.md`. Unichain fork pinned at block 63,689,000, production builds, `--isolate`.

| Swap | Before | After |
|---|---|---|
| Hook B, 1,000 USDC → WETH | 417,221 | **408,181** (−2.2%) |
| Hook B, 0.5 WETH → USDC | 412,492 | **403,192** (−2.3%) |
| Hook A, 1,000 USDC → WETH | 444,187 | **435,146** (−2.0%) |
| Hook A, 0.5 WETH → USDC | 439,539 | **430,238** (−2.1%) |
| Hook A, static mode | 296,761 | 296,898 (+0.05%) |

**Kept** (each security-neutral, each measured):
- one directional floor instead of two: −303 / −563;
- adapter feed reads without allocation: −1,632 per read;
- `vault.coreInputs()`, so the hook makes 2 external calls instead of 8: −7,167.

**The optional fresh tier adds back about 1,970 gas.**

**Rejected:**
- caching the reading in transient storage: ≈ −24k, but breaks the size target and adds state;
- a hook-provided price: removes independent verification.

**Left as it is:**
- **The vault's independent adapter re-read (≈ 22k)** is the price of the security property.
- **Local static benchmark:** swaps +137, LP paths +22, vault deployment +0.83%.

## 6. Bytecode sizes (MEASURED, runtime / EIP-170 margin)

| Contract | 1B-4.3 | 1B-4.4 |
|---|---|---|
| `SharedCommitmentVault` (200 runs) | 22,249 / 2,327 | **22,440 / 2,136** (target 2,048 met; 88 B to spare, and `coreInputs` is the first thing to drop) |
| `HookA_DynamicFee` | 15,116 | 14,341 |
| `HookB_BoundedImpact` | 15,338 | 14,601 |
| `VaultGovernor` | 3,027 | 4,111 |
| `PriceRiskAdapter` | 4,641 | 5,552 |
| `VaultLens` / `CuratorAuthorization` | 8,902 / 7,409 | unchanged |

Vault storage layout: identical (30 entries). ABI: one view added (`coreInputs`).

## 7. Hook parameter governance

**Done (local).**
- Production hooks are deployed with `hookOwner = VaultGovernor`.
- `configurePool`, `configureCore` and `configureStrategy` wait DELAY, and the guardian can cancel them.
- Hook bytecode is unchanged by the governance fix.
- `VerifyDeployment` gate 5 requires `hookOwner() == governor`.
- **Cost:** the initial hook configuration also waits DELAY (stage 2 of the rehearsal).

## 8. Oracle and relayer findings

`ORACLE_RELAYER.md`.

**Four permissions kept apart:**
- obtaining fresh data: needs a RedStone credential;
- submitting it on-chain: anyone (1B-4.3 measurement; a pinned replay could not be rebuilt this phase, no recent
  relayer events found on the public RPC);
- verifying it: RedStone's contract, then the adapter and the vault;
- trading: anyone, and never dependent on a relayer.

**Finding.**
- **Before:** with the 1B-4.3 adapter, a relayer could narrow the band only by becoming mandatory, since its outage
  became a halt.
- **Fix:** an optional per-source fresh tier.
  - Relayer running: ±30 bp; stopped: ±82 bp, still filling; provider heartbeat lapsed: refuses (LP exits work); next
    push: resumes with no governance action.
  - TESTED end to end.
  - **Assumption, stated in the code:** the fresh deviation assumes how far the market can move within `freshMaxAge`.

**Availability (SYNTHETIC):** push-only fill 4.1–4.8% vs about 35–38% with fresh prices. No other provider was added.

## 9. Economic calibration evidence

`CALIBRATION_1B44.md`, SYNTHETIC.

**κ:**
- **Depletion always reaches κ.**
- **Fill barely moves** (4.1 → 4.8%).
- **Compromise loss is about 0.35–0.47 κ** push-only.
- **Per-LP worst shortfall is about 2–3 κ** in the exact-integer adversary, and re-centring helps only at high κ.
- **Recommendation:**
  - κ = 1% first, then 2%;
  - 5–15% for labelled testnet stress only;
  - re-centre daily when holdings exceed `τ` by κ/2.

**Hooks:**
- **No route beats the shared core:** 0 violations in 32 parameter sets, and 1,000 fuzz runs on the real hooks.
- **Routing across hooks gains at most 0.53 bp on average and 4.9 bp on one trade.**
- **Recommended:** Hook A fee 0 → 50 bp, Hook B 10 bp markup. With these, A serves small and medium trades and B serves
  large ones.

## 10. Testing and mutation

All local. Foundry 1.7.1, solc 0.8.26, Slither 0.11.6, Python 3.11.8. Fork reads used the public Unichain RPC,
read-only.

| Command | Result |
|---|---|
| `forge fmt --check` | clean |
| `forge test` (after `forge build --force`) | **579 passed, 0 failed, 8 skipped** (fork tests without `UNICHAIN_RPC_URL`). After the mutation runs, one suite run failed: stale incremental artifacts, and an invariant sequence persisted while mutant G1 was active. A forced rebuild and clearing `cache/invariant/failures` fixed both; the deep campaign was then re-run clean |
| `bash test/bench/security.sh` (CI profile, 10,000 fuzz runs, forced rebuild, size gate) | exit 0; vault margin 2,136 ≥ 2,048 |
| `FOUNDRY_INVARIANT_FAIL_ON_REVERT=true FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-contract "VaultInvariantsTest\|OracleRiskInvariantsTest$"` | 35 + 3 passed; 32,768 calls each; 0 reverts |
| same settings, `--match-contract InventoryProtection` | 4 invariants + liveness + 5 bounds tests passed; 32,768 calls; 0 reverts |
| `UNICHAIN_RPC_URL=https://mainnet.unichain.org UNICHAIN_FORK_BLOCK=63689000 forge test --match-path "test/fork/*" --isolate` | 8/8 passed |
| `bash test/bench/run.sh` (before: `src/` stashed; after) | §5 |
| `slither . --filter-paths "lib/\|test/\|script/" --exclude-dependencies` | 59 results (56 in 1B-4.3, run without `script/` excluded). Every result on new code was reviewed and none is a defect: the timestamp, low-level-call, assembly and reentrancy-event findings on the governor and adapter are intended, and the governor's upper-case immutables are kept for ABI continuity. The two High results are the unchanged vault false positives |
| mutation (targeted, in place with restore) | 21/21 killed (§10.1) |
| `python3 -m unittest discover -s simulations/mm` / `simulations/pricing` | 46 / 22 passed; `floor_guarantee.py` output byte-identical to 1B-4.3 |
| `python3 simulations/mm/kappa_calibration.py`, `hook_routing.py` | `results/phase144_*` |
| `forge test --match-path test/script/DeployScripts.t.sol` | 4 passed: full local rehearsal through every stage and gate; refusals |

### 10.1 Mutation

**Result: 21 mutants of this phase's new code; 21/21 killed.**
- **How it was run.** Each mutant was applied in place from a backup, its targeted suites were run (fuzz 256, invariant
  32 runs), and the original was restored.
- **Restore check.** `git diff src` was empty afterwards.

| Area | Mutants | Killed |
|---|---|---|
| `VaultGovernor`: queue check, guardian's `setGuardian` exception, LONG class, hook-owner and hook-vault checks, target-bound id, replay record, delay validation, cancel authority, GRACE window | G1–G10 | 10/10 |
| `PriceRiskAdapter` fresh tier: boundary, tier use, validity, both validations | A1–A5 | 5/5 |
| vault: `dynamicFloor` direction; `coreInputs` tolerance index, target index and asset; `dynamicFloor` rounding | V1–V4, R1 | 5/5 |
| hook edge = vault edge + 1 | H1 | 1/1 |

**Two mutants survived the first pass. Each needed a new test:**
- **A1** (fresh boundary `<=` → `<`). Killed by `test_freshTier_boundaryIsInclusive`.
- **H1** (hook edge = vault edge). Killed by `test_hookEdge_isVaultEdgePlusOne`.

**Weakness found before the run.** `test_coreInputs_matchGetters` ran on a symmetric state, where an index swap could
not fail. It now runs on an asymmetric state.

**Not run:**
- an Unichain Sepolia rehearsal (needs approval);
- an independent audit;
- formal verification;
- the RedStone permissionless-submission replay as a pinned fork test.

## 11. Remaining risks

**Security:**
- The governor limits G15–G19.
- `freshDeviation` is a market-movement assumption.
- A compromised adapter still costs up to the room above the floor, i.e. about 2–3 κ per LP in the worst case.
- Vault headroom is 88 B above target.
- No independent review.

**Economic:**
- All calibration is synthetic.
- Push-only fill is about 4–5%.
- κ is capital that is used.
- Q3 and Q4 are unbounded by design.

**Operational:**
- The queue check can delay a loosening, by up to `MAX_HORIZON` absent griefing.
- Hook configuration takes DELAY.
- A testnet deployer-admin is labelled as such and is refused with mainnet delays.

## 12. Sepolia readiness

**Ready for a separately authorized Unichain Sepolia rehearsal, with labelled test parameters,** subject to the
pre-broadcast items in `script/README.md`:
- written approval;
- the PoolManager address verified against Uniswap's list;
- the CREATE2 factory present;
- a clean build at the reviewed commit.

**Release gates (`VerifyDeployment`):**
- governor ownership (gate 1);
- deployed bytecode equal to the local build (gate 8);
- nine further gates.

Every gate passes in the local end-to-end run.

**Not ready for mainnet:** R-1 … R-6, an independent review, and an observed testnet period are outstanding.

## 13. Decisions requiring approval

- **R-3:** delays 3 / 32 / 7 days with the queue check; and the queue check itself.
- **R-4:** κ 1% first.
- **R-5:** whether to run a relayer with the fresh tier (120 s / ±15 bp proposed).
- **R-6:** Hook A ≤ 50 bp, Hook B 10 bp.
- **R-7 (new):** keep `coreInputs` (−7.2k gas per swap, uses 196 of the remaining vault bytes)?
- **R-8 (new):** authorize the Sepolia broadcast.
