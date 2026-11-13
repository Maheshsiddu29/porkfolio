# script/ — Unichain Sepolia rehearsal

**Nothing in this directory has been run against any network.** Broadcasting, even to a testnet, needs explicit owner
approval (CLAUDE.md rule 2).
- Every script refuses chains other than Unichain Sepolia (1301) and local (31337).
- No key is stored here: pass `--account`, `--ledger` or an ephemeral `--private-key`, and the stage keys through the
  shell environment.
- `test/script/DeployScripts.t.sol` runs every stage end to end on a local chain against the production PoolManager
  build.

| Script | Stage | Who | What |
|---|---|---|---|
| `DeploySystem.s.sol` | 1 | deployer | deploys the system from production artifacts through the CREATE2 factory, initializes both pools, configures, seeds and nominates the governor; if the deployer is also the (test) admin, accepts and queues the hook configuration |
| `ExecuteQueued.s.sol` | 2 | governor admin | executes the queued hook configuration after DELAY |
| `VerifyDeployment.s.sol` | after each stage | anyone (read-only) | release gates 1–11; reverts at the first failure. `--sig "nominee()"`: gate 12, before queuing and before executing an ownership hand-over |
| `CheckQueuedConflicts.s.sol` | after every guardian action, before every `execute` | anyone (read-only) | reads every `Queued` event, simulates each still-queued vault call from the guardian's address and reverts if any loosens the current state or is owner-only (G02 report §13) |
| `Rehearse.s.sol` | 3 | per stage (see the file) | `router`, `lp`, `activate`, `swap`, `exit`, `emergency`, `recover` |
| `testnet/TestnetAggregator.sol` | — | — | **TEST ONLY** owner-set USD feed; never for mainnet |

## Labelled test parameters (defaults)

These are **test parameters, not a proposed mainnet configuration**:

| Parameter | Value |
|---|---|
| tokens | two `MockERC20` with public mint ("Porkfolio TEST A/B") |
| feeds | four `TestnetAggregator` set by the deployer |
| governor delays | 10 min / 1 h / 1 day |
| κ | 1% |
| edge | 1 bp |
| max uncertainty | 2% |
| flow cap | 40% of seed per day |
| exposure cap | 50% (a reviewed deployment choice, not a protocol constant) |
| buffer floor | 10% of seed per asset |
| Hook A fee | 0 → 50 bp over 20,000 tokens per hour |
| Hook B | 10 bp markup, 2% per-trade bound |
| adapter, RedStone-like source | fresh tier 120 s / ±15 bp |

## Environment

| Variable | Required | Meaning |
|---|---|---|
| `POOL_MANAGER` | yes | Uniswap's published v4 PoolManager for the chain (verify against Uniswap's deployment list: checklist D-4) |
| `GUARDIAN`, `CURATOR` | yes | role addresses; the guardian must differ from the admin |
| `DEPLOYER`, `GOV_ADMIN` | no | default: the broadcaster. Deployer-as-admin is refused unless DELAY < 1 day |
| `GOV_DELAY`, `GOV_LONG_DELAY`, `GOV_GRACE` | no | seconds; mainnet-like values are 259200 / 2764800 / 604800 |
| `KAPPA_PIPS`, `EDGE_PIPS`, `MAX_UNCERTAINTY_PIPS`, `SEED_AMOUNT`, `FLOW_CAP`, `EXPOSURE_BPS`, `BUFFER_FLOOR`, `SALT_NAMESPACE` | no | see `DeploySystem.Config`; `BUFFER_FLOOR` must be non-zero. `VerifyDeployment` reads `EXPOSURE_BPS` and `BUFFER_FLOOR` as the reviewed values |
| `TOKEN0` … `HOOK_B` | stages 2–3 | addresses printed by stage 1 |
| `*_KEY`, `ROUTER`, `ALLOCATION_A/B` | stage 3 | ephemeral test keys and outputs of earlier stages |
| `MAINNET_DELAYS`, `ADAPTER_CONFIG_VERSION`, `EXPECT_HOOKS_CONFIGURED` | verify | gate strictness |
| `VAULT`, `NOMINEE`, `NOMINEE_ADMIN` | gate 12 | the vault, the proposed new owner and its expected admin |
| `GOVERNOR`, `FROM_BLOCK` | conflict check | the governor and its deployment block |

## Commands (simulation only; add `--broadcast` only with written approval)

```
forge script script/DeploySystem.s.sol --rpc-url $UNICHAIN_SEPOLIA_RPC --sender $DEPLOYER
# export the printed addresses, wait DELAY
forge script script/ExecuteQueued.s.sol --rpc-url $UNICHAIN_SEPOLIA_RPC --sender $GOV_ADMIN
EXPECT_HOOKS_CONFIGURED=true forge script script/VerifyDeployment.s.sol --rpc-url $UNICHAIN_SEPOLIA_RPC
forge script script/Rehearse.s.sol --sig "run(string)" lp --rpc-url $UNICHAIN_SEPOLIA_RPC
```

## Release checklist for the rehearsal (each item needs evidence: tx hash, command output or test name)

**Before broadcasting:**
1. Written owner approval for a Sepolia broadcast, naming the deployer, admin, guardian and curator addresses (all
   test keys with no value).
2. `POOL_MANAGER` checked against Uniswap's published Unichain Sepolia deployment, and its code hash recorded.
3. The CREATE2 factory `0x4e59…956C` present on Unichain Sepolia (the script checks).
4. A clean build at the reviewed commit:
   - `bash test/bench/security.sh` passes;
   - the vault artifact is at 200 runs with headroom ≥ 2,048 B.
5. A local dry run with `forge test --match-path test/script/DeployScripts.t.sol` passes at that commit.

**Release gates after stage 1 and after stage 2** (`VerifyDeployment`; all must PASS):
- **Gate 1:** `vault.owner() == governor` and no pending nomination. *Explicit release gate.*
- **Gate 2:** the governor is bound to this vault and to the expected admin; with `MAINNET_DELAYS=true` the admin must
  be a contract (a multisig), so related calls can be executed in one transaction.
- **Gate 3:** the delays. They are TEST values on Sepolia; mainnet requires ≥ 3 / 32 / 7 days and LONG_DELAY above the
  vault's `MAX_HORIZON` (`MAINNET_DELAYS=true`).
- **Gate 4:** a guardian is set and differs from the admin.
- **Gate 5:** both hooks are owned by the governor, bound to the vault and PoolManager, registered, and carry exactly
  their permission bits.
- **Gate 6:** the authorization module is installed and bound.
- **Gate 7:** the adapter is installed, prices the pair, answers live, and its `configVersion` is recorded and later
  pinned.
- **Gate 8:** every deployed runtime code equals the local production build (immutables masked), with production
  compiler settings. *Explicit release gate: deployed bytecode verification.*
- **Gate 9:** κ, edge, uncertainty bound, inventory targets, risk limits and the curator; the vault-scope exposure cap
  and the buffer floor equal the reviewed values, and the buffer floor is non-zero. Prints the share of supply an LP
  needs to keep one request queued behind a full commitment.
- **Gate 10:** both pools initialized.
- **Gate 11** (after stage 2): both hooks configured.
- **Gate 12** (ownership hand-over only, `--sig "nominee()"`): the nominee is a production `VaultGovernor` for this
  vault and the expected admin, with the delay minimums of gate 3. Execute the nomination and the nominee's
  `acceptVaultOwnership` in one transaction when both governors share the admin; then gate 1 must pass again.

**After every guardian action and before every `execute`:** `CheckQueuedConflicts` must pass, or each change it lists
must be canceled or re-approved in writing.

**Rehearsal coverage** (stage 3; record tx hashes):
- [ ] LP deposit and instant redemption (`lp`)
- [ ] EIP-712 signed activation submitted by a third party, and a direct activation (`activate`)
- [ ] swaps through Hook A and Hook B against those allocations (`swap`)
- [ ] queued redemption, `processQueue`, `claim` (`exit`). This needs outstanding commitments to queue; with none,
      the exit is instant and the claim path is not exercised. On a local chain the claim path is covered by the test
      suite, not by this script.
- [ ] guardian pause, halt and curator freeze take effect in one transaction; the admin queues the recoveries; the
      guardian cancels a queued loosening (`emergency`)
- [ ] recoveries executed after DELAY (`recover`)
- [ ] a LONG_DELAY change refused while a redemption is queued, then executed once the queue is empty (not scripted;
      run by hand following `test_queuedLp_lateInNotice_blocksLooseningUntilFinalized`)
- [ ] relayer outage: stop updating the fresh-tier feeds for longer than 120 s and observe the band widen without a
      halt (feeds are TEST feeds here)
- [ ] block-explorer source verification for every contract (X-3)
- [ ] monitoring: `Queued`, `Canceled` and `Executed` events, feed ages, queue length, inventory against floors

**Not covered by these scripts:**
- real Chainlink or RedStone feeds on Sepolia (their existence was not checked);
- a multisig admin;
- mainnet anything.
