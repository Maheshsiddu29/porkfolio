# C04: Independent hook integration and capital-admission research

## 1. Scope and starting state

Starting `main` was `9ac5006`, with no tracked changes and an unrelated untracked `AGENTS.md`. Work proceeds only on
`phase-3-c04-independent-hook`. The production vault, its ABI and storage layout, the authorizer, escrow, and both
existing hooks are the C03 baseline. Hook C is a test integration, not an endorsed strategy or deployment candidate.
No production cap is authorized. The C-1 experiment may use an isolated source copy or test-only contracts.

## 2. Acceptance criteria

**Independent integration.** Hook C uses the public vault exchange interface and pinned v4 PoolManager, with no
Porkfolio hook or pricing implementation. Its permission-correct address, strict callback authority, exact-input
settlement, own-claims operator grant, trader minimum, conservative price quote and failure rollback are tested on
the real manager. A governed registration and bonded authorizations allow A, B and C to trade separate pools against
one reserve. Tests independently reconcile ERC-20, ERC-6909, vault backing, allocation consumption, reserved totals,
shares, and PoolManager deltas. One-block and one-unlock contention, negative paths, expiry and the bonded lifecycle
must pass. The production vault runtime bytes, ABI and storage layout must remain identical.

**Complexity and gas.** Compare `exchange` with one and 200 live allocations under equivalent slot warmth and slot
transitions, then inspect traces for a count-dependent walk. Report the complete swap gas of all hooks and hookless
v4 under the same fixture; do not treat unmatched quote policies as a pure hook overhead estimate.

**F-8 research.** Reproduce C03's bonded queue rotation and measure refundable collateral separately from charges,
protocol fees and coalition LP fees. Vary rate, horizon, honest backing, coalition fraction and utilization. Compare
post-deposit raw per-asset caps, single-deposit limits, external-price aggregate value caps and existing curator and
exposure ceilings. Check whether a coalition below each proposed cap can still hold an honest withdrawal or a
LONG_DELAY operation. Prototype only in isolated code; measure actual production-profile runtime and path gas before
making any recommendation. A cap that merely increases temporary capital is not an economic deterrence bound.

## 3. Method and baseline

The baseline uses Foundry 1.7.1, solc 0.8.26 and the pinned repository dependencies. Production artifacts are
rebuilt by `test/bench/run.sh`; the vault uses 200 optimizer runs, and the other production contracts use the
default profile. `forge test -vvv` is the default-suite baseline. Artifact object bytes and their hashes are captured
before Hook C is added; ABI and storage layout are compared after implementation. The benchmark's isolated calls
provide full-swap gas. A matching call boundary and explicit cold/warm normalization are required for the 1 versus
200 allocation comparison. `UNICHAIN_RPC_URL` and `UNICHAIN_FORK_BLOCK` are unset at the start; fork tests are skipped.

The fresh `forge build`, `forge test -vvv` and `test/bench/run.sh` all passed before Hook C source was added. The
default suite reported **804 passed, 0 failed, 8 skipped**. The benchmark forced a clean production build: solc
0.8.26, Cancun, via-IR, `bytecode_hash = none`; 200 optimizer runs for the vault, 44,444,444 for other production
contracts. These are actual artifacts, not the smaller alternative `.vault.json` dependency builds.

| Production contract | Runtime bytes | Runtime keccak256 |
|---|---:|---|
| `SharedCommitmentVault` | 22,103 | `0x577c987b8fb266277e2c1cdcdaf8774263927e4f2c10d34f1457b9b6847f91f2` |
| `CommitmentAuthorizer` | 9,157 | `0x4a36c3b78bf5f5abce5ecae3508c7f5a0bfa0cbdb57adb115df866968715c323` |
| `BondEscrow` | 15,905 | `0xfb6b2e6093e635208e29be418b9b0d104dd8edb349e98024601193714c5e3f38` |
| `HookA_DynamicFee` | 14,341 | `0x88d94d8cd832bea54a4db52b4158a43be9fc548a277f959616b406f056d2fc53` |
| `HookB_BoundedImpact` | 14,601 | `0x6c01b9909440a02b9c28880012fc13a868f496ee8edf399fd435815cac51a339` |
| `VaultGovernor` | 4,260 | `0x006a0ed40bf291c0aefc09b2754d58669b608bda5329c8e9e82aee85e6ec34ae` |

The vault init code is 22,754 bytes (`keccak256 =
0x25e8b7b45589def37cfb81b6c3818ac15ab6ab280085a8c6da41a2d9a343c905`). Its EIP-170 headroom is
2,473 bytes, leaving 425 bytes above the project's 2,048-byte minimum. The canonical artifact ABI has SHA-256
`4173409c6de4d3f56e0c049f8e3b439789ba9caf8754377f958c05afde352bc1`. The `forge inspect` storage layout
has 32 top-level entries; after removing compiler AST IDs and canonicalizing JSON, its SHA-256 is
`9ac395e9eaa10be84841d87ca4db24e1a7ceb62f9b4749d60966be330f998358`. The same normalization must be used
for the after comparison. A temporary baseline manifest outside the repository records the init hashes and ABI
hashes of the other five production contracts too.

The isolated benchmark measured Hook A 275,560 gas, Hook B 257,692 gas and hookless v4 150,303 gas for their
respective fixture swaps. A fresh `-vvvv` trace of the same benchmark measured `vault.exchange()` at 126,819 gas
inside Hook A and 126,842 gas inside Hook B; the difference is call-context state, not an allocation-count result.
Neither `UNICHAIN_RPC_URL` nor `UNICHAIN_FORK_BLOCK` is set; no fork block is pinned and all eight fork tests skipped.

Experiments, decisions, final validation and local commits follow as work completes. A passing integration test will
not be described as an audit or as proof that F-8 is solved.

## 4. Hook C implementation under test

`test/utils/IndependentHookC.sol` implements `IHooks` directly. It imports only the pinned v4 interfaces, types and
libraries plus the vault's public `IVaultState` interface. It has no import or inheritance from either supported
hook or Porkfolio's pricing libraries. Its per-pool policy is a fixed raw-unit 1:1 reference less a spread:
`amountOut = floor(amountIn · (1e6 − spreadPips) / 1e6)`. Output rounds down in the vault's favour; zero output is
refused. This fixture's two tokens both have 18 decimals. The policy does not claim to discover market value, and
the vault may reject a quote that violates its live floor or risk limits.

Only the hook owner can configure a PoolKey, and the key must identify this hook and the vault's ordered asset pair.
The constructor verifies that its manager is the vault's manager, validates all three address permission bits, and
grants the vault ERC-6909 operator status over the hook's claims. This is a one-way grant; Hook C has no operator
authority over vault claims. The `beforeSwap` callback requires the manager, exact input, at most `2^127 − 1` raw
input units, and exactly `abi.encode(allocationId, minimumOutput)` (64 bytes). It quotes first, then mints its input
claims, calls `vault.exchange`, burns the received output claims, and returns `BeforeSwapDelta(+input, −output)`.
The hook stores no fill accounting. Pool-native liquidity additions revert, because the intercepted swap never uses
the pool's native curve. All other callback selectors revert and their permission bits are absent.

The manager's unlock accounting is the settlement authority: after the hook transfers its deltas to the trader, the
router must pay the input and take the output. A revert anywhere in the unlock rolls back the hook's temporary
claims, vault allocation and flow counters, bond state, and manager deltas. Test evidence for this sequence follows
in the integration and adversarial sections.

## 5. Real PoolManager integration and bonded lifecycle

`test/integration/IndependentHookC.t.sol` deploys a mined permission-correct Hook C alongside the production A and
B hooks. Their three PoolKeys have the same ordered asset pair but different hook addresses. Governance accepts vault
ownership, queues C's consumer registration, refuses execution one second early, and executes at its three-day ETA.
The installed bonded authorizer then creates three separate bonded allocations. In one block A, B and C each take
100 input units. C outputs exactly 99.9 units. The test independently checks the ERC-20 balances held by the
PoolManager, vault ERC-6909 claims, `N_a`, `Q_a`, each allocation's `consumed`, unchanged LP shares, zero hook claims,
and escrow conservation. Another test executes A, B and C in one PoolManager unlock; the router observes zero
unsettled currency deltas after every step. C cannot spend A's allocation, and the rejection moves no claims or
reservation. The available aggregate backing is physical, not three duplicated pool deposits.

The signed-intent lifecycle names a curator, separate payer, C pool, raw asset-one capacity, and rate cap. Activation
posts the bond in the escrow without raising LP backing. A deliberately failed C quote leaves the bond and
reservation unchanged. A successful partial fill consumes 99.9 of 1,000 output units, while the bond remains
unsynchronized on the swap path. A sync one hour after the fill charges that consumed capacity for the extra hour.
After cancellation, a second sync and settlement satisfy `charge + refund = posted bond`; early settlement reverts.
Realization raises backing by only the LP fee portion. The payer and protocol each claim their separate balances;
the escrow ends with zero claims in this fixture. No hook callback calls `escrow.sync` or `escrow.realize`.

## 6. Adversarial boundaries

`test/security/IndependentHookC.t.sol` fingerprints allocation, backing, reservations, shares, vault and hook claims,
PoolManager token balances, trader balances, escrow bond and ledgers, and all three flow records before rejected
operations. Each rejected manager swap leaves this fingerprint unchanged. The tested failures cover an unauthorized
direct callback, exact-output request, malformed hook data, dust output, oversized input, trader minimum, wrong
direction, wrong pool, expiry exactly at its boundary, deregistered hook, sell halt, frozen and revoked curator,
exhausted quota, disabled quote, curator floor, inventory floor, live dynamic floor, unconfigured direction, and
hook/curator/vault flow limits. Curator deregistration intentionally preserves an already live allocation under G05;
the test checks that accepted behavior rather than expecting a revert. The one-unlock contention and skipped input
payment tests roll back earlier fills as well as the failing step.

A fourth registered malicious fixture tries to omit input claims, burn or transfer vault claims without operator
authority, exceed quota, breach a floor, and return more output to the PoolManager than it actually burned. Each
attempt reverts the entire unlock and leaves C's independent allocation intact. The malicious hook cannot pull the
vault's ERC-6909 claims because the operator grant points from the hook to the vault, never in reverse. These checks
do **not** bound a registered hook's market-value loss more tightly than the live execution floors and configured
capacity/flow limits. The prior real-manager `ReentrancyTest` covers genuine vault reentry from token callbacks;
the PoolManager's ERC-6909 mint/burn/transfer path provides no foreign callback while `exchange` holds its lock.
Scripted-hook tests cover attempted same-unlock sequences, which are sequential calls rather than true vault
reentry. C04 does not claim a new independent reentrancy proof.

## 7. Allocation-count gas and bytecode proof

The isolated C benchmark creates allocation ID 200 in both variants. One variant cancels IDs 1–199; the other
leaves all 200 live. Both cool the vault, hook, manager, router, and two tokens before the measured swap and use the
same input, allocation ID and storage transition. `forge test --match-path test/bench/IndependentHookCGas.t.sol
--match-test test_bench_ --isolate -vvvv` measured **250,752 gas** for the full C swap and **128,819 gas** inside
`vault.exchange` in each variant. The call traces have the same exchange shape and the exchange source looks up the
specified allocation directly; it contains no allocation-count loop. This is evidence for this path and state
transition, not a formal complexity proof or a universal gas bound. In a separate one-allocation bonded fixture,
the same 1,000-unit input measured A **275,300**, B **257,634**, and C **244,197** gas; the price policies, output
amounts and pool identities differ. The C03 production benchmark's hookless reference was **150,303** gas in its
own fixture. The arithmetic C-minus-A/B/hookless differences are **−31,103 / −13,437 / +93,894** gas. These totals
cannot be subtracted to attribute a precise isolated hook premium because the quote policies and pool identities
differ, and the hookless reference uses a separate fixture.

Final production artifact and ABI/layout equality measurements are recorded in the validation section below.

## 8. F-8 attack-cost research

The prior `BondEconomicGriefingTest` remains unchanged and is inherited by
`test/security/CapitalCapResearch.t.sol`. Its fresh-capital queue rotation and rate-by-horizon matrix still pass.
The new research test reduces honest net backing from 50,000 to 1,000 raw units, then admits 200,000 coalition units
under a proposed 250,000-unit post-deposit ceiling. The resulting net assets are 201,000 and reserved output is
2,010, exceeding the honest 1,000. An honest withdrawal waits eight days. Four nine-day rotations keep a
LONG_DELAY governance operation blocked at day 32, despite every deposit remaining under the proposed ceiling.
The fixture records 6.858530737598531710 units of bond principal posted, 4.443578920905094357 units of settled
charges, 0.550304333954681824 units of refunds and an estimated 3.375895707623271008 units of coalition LP-fee
recapture. The fourth bond is still open, so these amounts are **not** a closed-run total-loss calculation.
For the settled portions alone, charged fees less that estimated LP rebate are
1.067683213281823349 units; this excludes temporary capital and the open bond's eventual charge or refund.

The one-day, half-term scenario matrix below changes honest backing, coalition capital and curator ceiling. Units
are raw token units with 18 decimals. The rebate is the coalition's proportional claim on earned LP fees, assuming
its shares remain through realization. `net` is `charge − rebate` for this single settled rotation; refundable bond
principal is excluded. The measured gas covers deposit and activation in the same test harness, not full queue
rotation or opportunity cost.

| Honest | Coalition | Post-deposit net assets | Ceiling / reserved | Coalition share | Posted / charge / refund | LP rebate / net charge | Deposit + activation gas |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 50,000 | 200,000 | 250,000 | 200,000 / 2,500 | 80% | 0.214 / 0.108 / 0.106 | 0.07776 / 0.03024 | 857,379 |
| 10,000 | 1,000,000 | 1,010,000 | 200,000 / 10,100 | 99.0099% | 0.86456 / 0.43632 / 0.42824 | 0.3888 / 0.04752 | 806,279 |
| 1,000 | 200,000 | 201,000 | 200,000 / 2,010 | 99.5024% | 0.172056 / 0.086832 / 0.085224 | 0.07776 / 0.009072 | 806,279 |
| 1,000 | 200,000 | 201,000 | 500 / 500 | 99.5024% | 0.0428 / 0.0216 / 0.0212 | 0.019343283582089552 / 0.002256716417910448 | 806,298 |
| 1,000 | 1,000,000 | 1,001,000 | 200,000 / 10,010 | 99.9000% | 0.856856 / 0.432432 / 0.424424 | 0.3888 / 0.043632 | 806,279 |

The 500-unit ceiling limits withheld capacity below the honest 1,000 in that one fixture; it does not prove a
general value-loss or liveness bound. The inherited C03 test uses 10 million units of temporary coalition capital
per rotation against 50,000 honest units. Four nine-day bonds rotated eight days apart block LONG_DELAY execution
at day 32. The guardian then raises the asset-zero buffer floor, the next rotation fails, existing bonds expire,
`processQueue(256)` drains pending withdrawals, and the re-queued operation executes. The honest wait measured
691,200 seconds. Its three rates by three horizons also quantify zero-rate and partial-term charges. Two additional
tests show a per-call limit is bypassed by two permitted 100,000-unit deposits from one LP or from two cooperating
LPs with proportional share minting. A coalition may borrow temporary capital; the test suite does not price that
funding or derive an irreversible-loss bound. Raw inventory floors and reservations are not market-value guarantees.

The inherited rate/term rows all use 10 million temporary capital units and reserve 100,500 output units. The
coalition closes halfway through the term; values below are token units with 18 decimals. `net` deducts only the
estimated coalition LP-fee rebate from the actual charge, and excludes borrowing cost and refundable bond principal.

| Rate (raw per unit-second) | Term | Posted | Charged | Refund | Coalition rebate | Net charge | Deposit + activation gas |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 1 hour | 0 | 0 | 0 | 0 | 0 | 926,358 |
| 0 | 1 day | 0 | 0 | 0 | 0 | 0 | 926,359 |
| 0 | 9 days | 0 | 0 | 0 | 0 | 0 | 926,359 |
| 1e9 | 1 hour | 0.2814 | 0.2814 | 0 | 0.12726 | 0.15414 | 1,050,535 |
| 1e9 | 1 day | 8.6028 | 4.3416 | 4.2612 | 1.96344 | 2.37816 | 1,050,535 |
| 1e9 | 9 days | 78.0684 | 39.0744 | 38.994 | 17.67096 | 21.40344 | 1,050,536 |
| 1e12 | 1 hour | 281.4 | 281.4 | 0 | 127.26 | 154.14 | 1,050,537 |
| 1e12 | 1 day | 8,602.8 | 4,341.6 | 4,261.2 | 1,963.44 | 2,378.16 | 1,050,537 |
| 1e12 | 9 days | 78,068.4 | 39,074.4 | 38,994 | 17,670.96 | 21,403.44 | 1,050,538 |

## 9. C-1 isolated capital-admission prototypes

The three unified patches in `docs/proposals/` are reviewable *research artifacts*. Each applied cleanly to the
C03 production source in a separate temporary checkout, compiled with the vault's production optimizer profile,
and ran its targeted boundary and F-8 counterexample tests. They were never applied to this branch's `src/`.
Scratch benchmark fixtures enabled a nonbinding cap on the compared production path, unless noted. The baseline
runtime was 22,103 bytes; 22,528 bytes is this project's maximum under its 2,048-byte EIP-170 headroom policy.

| Candidate | Exact admission rule | Vault runtime / delta | EIP-170 headroom / policy margin | Deposit gas delta | Redeem instant / queued | A/B swap | Allocation | Realization | Deployment | Outcome |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| A: raw per-asset net cap | Reject a deposit if either asset's *post-deposit* `N_a` exceeds its raw-unit cap | 22,376 / +273 | 2,200 / +152 | +5,461 | +44 / +22 | +44 / +44 | +44 | +22 (one-hour earned fixture) | +59,043 | Fits size, but under-cap F-8 attack succeeds |
| B: single-deposit limit | Reject one deposit above its raw-unit per-asset limit | 22,338 / +235 | 2,238 / +190 | +4,422 | +44 / +22 | +66 / +66 | +44 | +44 (one-hour earned fixture) | +50,822 | Fits size, split deposits bypass it |
| C: aggregate value cap | Multiply each asset's raw balance by an external 1e18 price reference and reject post-deposit value above cap | 22,807 / +704 | 1,769 / **−279** | +9,039 | +22 / 0 | +66 / +66 | +44 | +44 (one-hour earned fixture) | +151,925 | Fails size policy; oracle trust/liveness added; under-cap attack succeeds |
| D: current ceilings and exposure caps | Owner/guardian bound curator reservation and three exposure scopes at activation | 22,103 / +0 | 2,473 / +425 | 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 | Existing control; must choose limits against honest backing |

The deployment and main-path deltas use the same production benchmark fixtures and call boundaries for each scratch
prototype. The realization deltas come from the separate bonded-gas fixture, where the new cap is not configured;
they therefore measure incidental codegen changes rather than the cost of an enabled cap. The enabled A/B/C deposit
measurements include their storage reads and, for C, a mock external price-reference call. Other bonded-gas checks
found A/B/C first bonded-activation deltas of +176/+66/+44 gas and installed Hook A swap deltas of +44/+66/+66.
These small nonzero deltas on paths that do not consult a cap are compiler layout/codegen effects; they are not
evidence of an added external call on swaps. The exact scratch commands and results are retained in the local
prototype logs and can be reproduced by applying each patch to a fresh isolated copy of `5ac4876` with pinned
submodules. The patches themselves contain the boundary tests and benchmark fixture changes.

A and B each add two persistent cap slots, public getters, an owner setter and a revert error to the vault ABI.
C adds oracle-address and cap slots, corresponding getters, an owner setter and two errors, plus the external
price-reference interface and an additional deposit-time trust boundary. All three would change vault storage
layout, ABI, runtime and init code; none is compatible with C04-A's strict bytecode/interface equality condition.
D uses existing controls and has no new ABI or layout cost. Prototype setters are scratch-only, without a proposed
governance rollout or migration. The owner has approved research, not installation of any cap.

A admits exact-cap deposits and refuses a deposit one raw unit above the cap. Earned fee realization can later make
`N_a` exceed that deposit-only cap, as intended by its rule; swaps, redemptions, cancellation, settlement and refund
still work in its scratch tests. B permits two individually compliant deposits that jointly exceed the intended
economic threshold, including from different LP identities. C refuses deposits when its external price feed fails
or its price movement raises measured value above the cap; valid swaps, redemptions, fee realization and refunds
still work in the boundary test. C's external reference introduces governance choice of feed, staleness, decimals,
manipulation and outage risk. All three prototypes let a coalition below the tested cap block an honest withdrawal
and/or LONG_DELAY change. D avoids new code but relies on governance to choose sufficiently conservative limits
relative to honest available backing; the 500-unit matrix case illustrates a narrower exposure, not proof of safety.

**Recommendation:** do not install A, B or C as an F-8 mitigation on this evidence. A raw cap can limit absolute
admitted capital, yet that number has no derived relation to honest exit room or economic value. B is trivially
split; C fails the size policy and adds an oracle trust and liveness dependency without closing the demonstrated
attack. Retain D as an operational control, with F-8 unresolved. If a future policy needs risk inputs beyond the
vault's 425-byte margin, a separate admission module could run only on deposits/activations, but it would add
external-call, upgrade, oracle and fail-closed liveness trust. No such module or swap-path call is authorized here.

## 10. Continuing risk register and release limits

| Risk | C04 evidence | Remaining decision or limit |
|---|---|---|
| F-8 withdrawal/governance griefing | Bond rotations remain possible below the tested raw and value caps; refundable principal is not loss; LP-fee recapture lowers net cost. | No proven economic deterrence or maximum honest delay. Owner must choose an operational exposure policy or separately approve a stronger design before release. |
| Inventory floors versus value | C's fixed raw-unit quote and the F-8 matrix demonstrate capacity accounting in inventory units. | An inventory-unit floor does not bound economic value loss when asset prices differ or change. |
| Backing versus execution | Three pools share backed claims, and C's quote can be refused by live floor, flow, inventory, curator or oracle rules. | A physically backed allocation does not guarantee a later fill under every market or governance condition. |
| Bond synchronization | Hook C's delayed sync charges consumed capacity for an extra hour in the fixture. | Accepted lazy synchronization can overcharge payers; an integrator must disclose this and may sync promptly. |
| LP fee realization | The lifecycle realizes after a fill and cancellation; the C03 record shows timing changes fee recipients. | Governance/operators must realize earned fees before escrow replacement and at appropriate share-pricing checkpoints. |
| Escrow replacement | C04 does not change escrow custody or replacement rules. | C03's safe replacement procedure remains an operator/governance requirement; unsafe replacement can strand earned LP revenue. |
| External hooks | C's independent integration passes the local real-manager tests. | Registration, curator bonds, risk limits, governance and security review remain prerequisites. A malicious registered hook may consume authorized capacity at a permitted but economically poor price. |
| Fork and external analysis | No Unichain RPC/block was configured; local tests use pinned v4 contracts. | Eight read-only fork tests skipped. Historical deep campaigns, broad mutation and external static analysis remain deferred to C05; no audit or production-readiness claim follows. |

For a release decision, the owner still needs an explicit F-8 exposure and governance-liveness decision, a safe
escrow replacement operating procedure, and a review of the accepted lazy-sync and fee-attribution tradeoffs.
Unichain fork evidence, historical deep-profile runs, comprehensive mutation and external static analysis remain
unperformed here. The C04 tests do not discharge those release questions.

## 11. Validation record

`forge fmt --check` and `git diff --check` pass. `forge build` exits zero. `forge lint src` exits zero with
pre-existing diagnostic warnings on production Solidity; C04 changes no file in `src/`. The first post-integration
`forge test -vvv` run passed **835 tests, 0 failed, 8 skipped**. It compiled before the additional specific
native-liquidity callback assertion was added. The final-source `forge test -vvv` then passed **836 tests, 0 failed,
8 RPC-dependent fork tests skipped** across 87 suites. The targeted
`FOUNDRY_PROFILE=ci forge test --match-path test/integration/IndependentHookC.t.sol -vv` passes 4/4. The C security
suite passes 14/14 under the same profile, and the F-8 research suite passes 7/7. The separately rerun precise
native-liquidity callback test passes 1/1. The full `python3 test/invariant/coverage.py` gate passes all five
campaigns, 64 seeded runs at depth 128 for each, with every required counter active enough and the required
unexpected-failure counters at zero. `git apply --check` passes for each of the three isolated prototype patches.

The isolated prototype tests were run from separate copies of `5ac4876` with the pinned submodule links and the
same solc/via-IR/optimizer settings. A's cap boundary and successful normal-path test pass 2/2, B's split-deposit
test passes 1/1, and C's price/failure/normal-path test passes 1/1. Scratch runs applying each rule to the F-8
scenario pass the under-cap counterexample for A 1/1, split-deposit counterexamples for B 2/2, and the aggregate
value-cap counterexample for C 1/1. These are deliberately isolated prototypes, not a production implementation.

`test/bench/run.sh` exits zero after a forced production rebuild. It reproduces the starting compiler settings and
sizes in section 3, including the vault's 22,103-byte runtime, 22,754-byte init code, 2,473-byte EIP-170 headroom
and 425-byte project-policy margin. It reproduces A/B/hookless full-swap gas of 275,560/257,692/150,303.
Artifact-by-artifact comparison against the starting manifest finds identical runtime and init bytes, canonical ABI
hashes, compiler settings and sizes for `SharedCommitmentVault`, `CommitmentAuthorizer`, `BondEscrow`, both supported
hooks and `VaultGovernor`. The vault's normalized `forge inspect` layout hash is still
`9ac395e9eaa10be84841d87ca4db24e1a7ceb62f9b4749d60966be330f998358` across 32 top-level entries;
its runtime keccak remains `0x577c987b8fb266277e2c1cdcdaf8774263927e4f2c10d34f1457b9b6847f91f2`.
`git diff 9ac5006 -- src` is empty. Hook C registration and use therefore introduced no production vault bytecode,
ABI, storage or source change.

The final `forge test --match-path test/bench/IndependentHookCGas.t.sol --match-test test_bench_ --isolate -vv`
passes 3/3 and reproduces the section 7 figures exactly: C at 250,752 gas with one or 200 live allocations, and
one-allocation A/B/C full swaps at 275,300/257,634/244,197. A normal non-isolated `forge test -vvv` reports
different gas totals because the warm/cold transaction context differs; it is a correctness run, not the gas
comparison. The earlier `-vvvv` trace gave 128,819 gas inside `vault.exchange` in both allocation-count variants.

`test/bench/security.sh` exits zero under `FOUNDRY_PROFILE=ci`. Its forced-rebuild size gate passes all eight
production contracts, including the vault's required 2,048-byte headroom. The production-build fixture passes 4/4,
the production-artifact security suite passes 25/25, and its full CI-profile suite passes **836 tests, 0 failed,
8 RPC-dependent fork tests skipped** across 87 suites. A second post-script artifact comparison again finds the
same six production runtime/init hashes, ABI hashes, compiler settings and sizes as the starting manifest.

## 12. Changed-file inventory and review decision

`test/utils/IndependentHookC.sol` is the independent implementation fixture. The real-manager integration and
bonded lifecycle are in `test/integration/IndependentHookC.t.sol`; its adversarial companion is
`test/security/IndependentHookC.t.sol`. The latter extends `test/utils/MaliciousConsumerHook.sol` only with an
incorrect-output attack mode. `test/bench/IndependentHookCGas.t.sol` measures three-hook swaps and 1/200 live
allocations. `test/security/CapitalCapResearch.t.sol` adds F-8 counterexamples. The three
`docs/proposals/C04_CAP_{A,B,C}_RESEARCH.patch` files are isolated prototype source and test deltas, not installed
production changes. `docs/THIRD_PARTY_HOOK_INTEGRATION.md` is the external-hook guide, `README.md` updates the
project status, and this record contains the findings. No `src/` file, remote, or unrelated `AGENTS.md` changes.

Local review commits: `5ac4876` establishes the C04 baseline; `19ae4b3` adds the independent Hook C, real-manager
integration, adversarial tests, benchmark and guide; `a1cacf7` adds the F-8 counterexamples and isolated cap
patches. The final README, precise callback assertion and closeout addendum are a separate local commit.

**C04-A: PASS.** The final-source full and CI security gates passed. The independent
hook consumes the public bonded allocation through the pinned manager, three pools reconcile one reserve, negative
paths roll back, and production artifacts are identical. This is integration evidence, not an external-hook audit.
**C04-B recommendation: RESEARCH COMPLETE.** A/B/C cap mechanisms were compiled, benchmarked and challenged in
isolation; none establishes a defensible F-8 deterrence bound, and C violates the size policy. The owner has not
approved any production cap. F-8 and the C03 financial/governance release questions remain open for owner review.
