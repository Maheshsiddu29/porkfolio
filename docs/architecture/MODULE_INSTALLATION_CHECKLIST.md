# Porkfolio — Authorization Module Installation Checklist

**Status: procedure for a future deployment. Nothing is deployed, and no deployment is authorised by this document.**
It is written for the people who will install or replace the `CuratorAuthorization` module of a deployed
`SharedCommitmentVault`, for example on Unichain. It complements `AUTH_SECURITY_RELEASE_NOTES.md` §2–§3.

## 1. What the vault checks, and what it cannot

`setAuthModule(m)` (owner only for a non-zero `m`) asks the candidate two read-only questions and reverts
`InvalidAuthModule(m)` unless both answers are exact:

| Question | Required answer | What it rules out |
|---|---|---|
| `authModuleId()` | `AUTH_MODULE_ID` = `keccak256("porkfolio.vault.auth-module.v1")` = `0xbdeb213b0a19709f7aeec009626afcfd5c945bbe39a266e02474372b6a16000a` | addresses without code, EOAs, the hooks, the PoolManager, the vault itself, tokens, wallets and other contracts that are not meant to be modules |
| `vault()` | this vault's address | a real module deployed for another vault (for example a test deployment) |

It also refuses the module that is installed now and every module that was ever retired (`AuthModuleRetired`).

**The vault cannot tell a reviewed module from a malicious one.** Any contract can return both answers; a test does
exactly that (`test_PA_auth_installLifecycleAndSpoofedModule`). The checks below are what establish that the
candidate is the reviewed code. They are not optional because the on-chain check passed.

There is no on-chain code-hash allowlist. Adding one would need a separate design decision (it fixes the module build
into the vault's bytecode or adds owner-controlled state).

## 2. Before installation

Record every value below in the change request, with the command used to obtain it.

**Network and addresses**

- [ ] Chain id read from the RPC endpoint (`cast chain-id`) equals the intended network (Unichain mainnet: 130;
      Unichain Sepolia: 1301). Use an RPC endpoint the team controls or two independent endpoints.
- [ ] Vault address equals the address in the deployment record. `cast code <vault>` is not empty, and its runtime
      code matches the reviewed vault build (below).
- [ ] Candidate module address equals the address in the deployment transaction's receipt (`contractAddress`), not
      an address copied from chat or a block explorer label.
- [ ] `authModule()` on the vault returns the module expected to be replaced (or zero).

**Constructor and immutable values**

- [ ] `cast call <module> "vault()(address)"` returns the vault address.
- [ ] `cast call <module> "authModuleId()(bytes32)"` returns `AUTH_MODULE_ID` (value in §1).
- [ ] `cast call <module> "eip712Domain()"` returns name `Porkfolio Vault`, version `1`, the chain id above and the
      module's own address as verifying contract.
- [ ] `cast call <module> "MAX_VALIDITY_WINDOW()(uint64)"` returns `86400`.
- [ ] `cast call <module> "domainSeparator()(bytes32)"` equals the separator computed off-chain from those four
      values.

**Code**

- [ ] The commit to install is tagged in review notes, and its `CuratorAuthorization.sol` and the interfaces it imports
      were reviewed.
- [ ] Independent reproducible build: at least two people, on separate machines, run `test/bench/run.sh` (or
      `forge build --force`) at that commit with Foundry 1.7.1 and the pinned `foundry.toml`, and obtain the same
      `CuratorAuthorization` runtime bytecode and init-code keccak256 (printed by `run.sh`).
- [ ] The deployed runtime code equals the build's runtime code with the immutables filled in. `CuratorAuthorization`
      has immutables (the vault address and the cached EIP-712 values), so compare after masking their positions
      (`deployedBytecode.immutableReferences` in the artifact), the same way
      `ProductionArtifacts.maskedRuntimeHash` does in the tests. Record both the masked hash and the unmasked
      `cast keccak $(cast code <module>)`.
- [ ] The creation transaction's input equals the build's init code followed by `abi.encode(vault)`.
- [ ] Source verification on the chain's explorer matches the same compiler settings (solc 0.8.26, via-IR,
      44,444,444 runs, cancun, `bytecode_hash = none`). Explorer verification is a convenience, not a substitute for
      the two local builds.

**Dry run**

- [ ] On a fork of the target chain at a recent block: `setAuthModule(candidate)` from the owner succeeds, one direct
      activation and one signed activation succeed, and a swap consumes the new allocation. No transaction is
      broadcast.

**Governance**

- [ ] The owner multisig's transaction calls exactly `setAuthModule(<candidate>)` on the vault address above; the
      signers check the decoded calldata on their own devices.
- [ ] Installing a module is a loosening action: it goes through the timelock with the agreed delay
      (`MAINNET_READINESS.md` G-1, G-2), and the queued call is announced so curators can review it.
- [ ] Review and approval are recorded (reviewers, commit, hashes, timelock id).

## 3. After installation

- [ ] `authModule()` returns the candidate; an `AuthModuleSet(previous, candidate, owner)` event was emitted.
- [ ] The previous module is retired: an owner attempt to reinstall it would revert `AuthModuleRetired` (check with
      `cast call`, which simulates and broadcasts nothing).
- [ ] Curators and relayers are told the new module address and EIP-712 domain. Instructions signed for the old
      module do not verify under the new one; curators must sign again.
- [ ] Indexers follow `AuthModuleSet` and the new module's `Activated` events.

## 4. Emergency disable

Use when the installed module is suspected to be faulty or compromised.

1. **Guardian** (or owner): `setAuthModule(address(0))`. New allocations stop in that transaction. It cannot fail
   because the module misbehaves: disabling makes no call to the module. It also succeeds when no module is
   installed, so two responders acting at once do not block each other.
2. The disabled module is retired for good: it can never be installed again, by anyone. Its unused signatures and
   nonce state can never regain authority.
3. **Guardian**: `release` the allocations created by the suspect module, found from its `Activated` events and the
   vault's `AllocationCreated` events. Existing allocations otherwise stay consumable; swaps and LP deposits,
   redemptions and claims are not affected by the disable.
4. **Owner**: resume only by deploying a new module and running §2 again in full. The guardian cannot install
   anything.
5. For a temporary stop when the module itself is not suspect, prefer a reversible control: lower the vault-scope
   exposure caps, deregister curators, or pause.

Tests of this procedure: `test_PA_auth_installLifecycleAndSpoofedModule`, `test_MI_bothRightAnswersAreNotProofOfAModule`,
`test_MI_repeatedInstallAndIdempotentDisable`, `test_MI_retiredModuleReplay`.
