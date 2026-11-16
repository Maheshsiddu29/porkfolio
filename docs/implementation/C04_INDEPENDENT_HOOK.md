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
