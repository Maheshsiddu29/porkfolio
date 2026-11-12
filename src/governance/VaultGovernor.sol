// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev The vault getters the governor reads: the address allowed to cancel queued changes, and the shares still
///      waiting in the withdrawal queue.
interface IGovernedVault {
    function guardian() external view returns (address);
    function pendingShares() external view returns (uint256);
}

/// @title VaultGovernor
/// @notice Timelock that holds the owner role of one `SharedCommitmentVault` and the `hookOwner` role of the hooks built
///         for that vault. Every owner call is queued here first and can be executed only after a public delay, so LPs
///         can see a change coming and leave before it applies. Changes that lower the vault's inventory floor, or
///         that hand the vault's owner role elsewhere, wait longer than every other change and cannot apply while any
///         LP is still waiting in the withdrawal queue.
/// @dev
/// Roles.
///   admin      Fixed at construction (expected: a multisig). Queues, executes and cancels changes. It has no other
///              power: every call to a governed contract goes through `queue` and `execute`.
///   guardian   The vault's current guardian (read live from the vault). May cancel any queued change except a call to
///              the vault's `setGuardian`, so a compromised guardian can delay governance but cannot block its own
///              replacement. Its immediate, risk-reducing powers (pause, halt, raise a floor, raise the edge, lower a
///              tolerance, revoke a hook...) are exercised directly on the vault, not here. Those vault limits also
///              bind every hook in shared-core mode, so tightening never waits for a hook change.
///
/// Targets. A queued call names its target, which must be either `vault` or a hook whose immutable `hookOwner()` is this
/// governor and whose `vault()` is `vault`. The operation id is keccak256(abi.encode(target, data)), so a queued change
/// binds the target, the selector and every argument; `execute` can only send exactly what was queued, to exactly the
/// contract it was queued for. Nothing else is callable: this contract has no arbitrary-call path, no `delegatecall`,
/// no upgrade and no way to change `admin`.
///
/// What the delay covers. The vault owner can loosen any vault limit (`_authorize` in the vault lets the owner make any
/// change) and the hook owner sets each hook's pricing inside the vault's boundary. As long as this contract holds both
/// roles, every such change waits. Neither role has a function that moves LP assets, so this contract has no path to
/// vault accounting either.
///
/// Delays (set at construction; read them on-chain, they are part of the reviewed configuration).
///   LONG_DELAY  Vault `setInventoryBounds`, and `transferOwnership` to a non-zero nominee. The inventory floor is the
///               only protection that holds under a wrong price (it bounds what each share can lose against its entry
///               basket), and a new owner need not be a timelock at all, so both get the longest notice. The class
///               follows the selector, not the direction of the change: a call that tightens when queued can loosen by
///               the time it executes if the guardian tightened further in between.
///   DELAY       Every other vault call and every hook call, including changes that tighten. Immediate tightening is the
///               guardian's job. `transferOwnership(address(0))` is here too: it only withdraws a pending nomination,
///               which no LP needs notice of, and holding it to LONG_DELAY and the queue check would leave a nominee
///               the admin wants to retract free to accept for as long as LPs are queued.
///   GRACE       How long a matured change stays executable. Afterwards it must be queued again.
///
/// Queued LPs keep their floor. An LP whose redemption is queued still holds shares, so a looser floor would apply to
/// it. A commitment that existed when the LP queued can hold the request for up to the vault's MAX_HORIZON, which
/// exceeds any useful notice period, so a delay alone protects only LPs who queue early enough. `execute` therefore
/// refuses a LONG_DELAY call while `vault.pendingShares()` is non-zero: every redemption requested before the change
/// applies is finalized under the old floor first. Finalized amounts are fixed and no later floor change reaches them.
/// The admin calls the vault's permissionless `processQueue` in the same transaction to finalize what is deliverable;
/// what is not deliverable makes the change wait (and possibly expire after GRACE), which only delays a loosening.
/// A request is undeliverable only while commitments older than it hold the inventory it needs, so a curator that
/// keeps re-committing while an LP keeps queuing can hold a LONG_DELAY change for as long as new commitments are
/// allowed. Stopping new commitments (guardian: buffer floor, vault exposure cap, pause, deregistration) lets every
/// older commitment expire within the vault's MAX_HORIZON, after which the queue can always be emptied.
///
/// The check binds when a nomination executes, not when the nominee accepts. After `transferOwnership(nominee)` has
/// executed, the nominee may accept at any time; if it is not a timelock, LPs who queue after the nomination are not
/// protected from it. Nominate only a reviewed governor, and have it accept in the same transaction.
///
/// The trust boundary is a deployment property: it holds only while `vault.owner() == address(this)` and each hook's
/// `hookOwner() == address(this)`. Anyone can check both on-chain. Ownership of the vault can leave this contract only
/// through a queued `transferOwnership`, which waits LONG_DELAY. `hookOwner` is immutable in the hooks.
///
/// Not implemented: rotating `admin` (deploy a new governor and transfer the vault to it; hooks would be redeployed),
/// batching several calls into one change, binding the code of an address argument (see the release checklist: a
/// queued address must already hold the reviewed, non-upgradeable code).
contract VaultGovernor {
    /// @notice Delay of an ordinary queued change, in seconds.
    uint256 public immutable DELAY;
    /// @notice Delay of a change to the vault's inventory floor or ownership, in seconds.
    uint256 public immutable LONG_DELAY;
    /// @notice Seconds after its earliest execution time during which a queued change may still be executed.
    uint256 public immutable GRACE;

    /// @dev Vault selectors with special treatment. Spelled out rather than imported so the governor does not compile
    ///      the vault; `test/governance/VaultGovernor.t.sol` checks them against the vault's selectors.
    bytes4 internal constant _SET_INVENTORY_BOUNDS =
        bytes4(keccak256("setInventoryBounds(uint256,uint256,uint24,uint24)"));
    bytes4 internal constant _TRANSFER_OWNERSHIP = bytes4(keccak256("transferOwnership(address)"));
    bytes4 internal constant _SET_GUARDIAN = bytes4(keccak256("setGuardian(address)"));
    bytes4 internal constant _ACCEPT_OWNERSHIP = bytes4(keccak256("acceptOwnership()"));
    /// @dev Getters a governed hook must answer: `hookOwner()` and `vault()`.
    bytes4 internal constant _HOOK_OWNER = bytes4(keccak256("hookOwner()"));
    bytes4 internal constant _VAULT = bytes4(keccak256("vault()"));

    /// @notice The vault this governor owns. Every governed hook must name it.
    address public immutable vault;
    /// @notice Account that queues, executes and cancels changes.
    address public immutable admin;

    /// @notice Earliest execution time of each queued change, by `operationId(target, data)`. Zero: not queued.
    mapping(bytes32 id => uint256) public eta;

    /// @notice `data` (exact calldata for `target`) was queued; executable in [eta, eta + GRACE].
    event Queued(bytes32 indexed id, address indexed target, uint256 eta, bytes data);
    /// @notice A queued change was dropped by the admin or the guardian.
    event Canceled(bytes32 indexed id, address indexed by);
    /// @notice A queued change was sent to its target and succeeded. It can not be executed again.
    event Executed(bytes32 indexed id, address indexed target);

    /// @notice Caller is not the admin.
    error NotAdmin();
    /// @notice Caller is neither the admin nor the vault's guardian, or is the guardian cancelling `setGuardian`.
    error NotAllowedToCancel();
    /// @notice A zero vault or admin address at construction.
    error ZeroAddress();
    /// @notice Delays out of range at construction: zero, LONG_DELAY below DELAY, or anything above 365 days.
    error InvalidDelays();
    /// @notice The same call is already queued; cancel it first to restart its delay.
    error AlreadyQueued(bytes32 id);
    /// @notice No queued change has this target and calldata.
    error NotQueued(bytes32 id);
    /// @notice The change is outside its window: `block.timestamp` is before `eta` or after `eta + GRACE`.
    error NotExecutable(bytes32 id, uint256 eta);
    /// @notice Calldata shorter than a selector.
    error InvalidCall();
    /// @notice The target is neither the vault nor a hook of this vault owned by this governor.
    error InvalidTarget(address target);
    /// @notice A LONG_DELAY change was executed while LPs were still queued for withdrawal.
    /// @param pendingShares Shares still waiting in the vault's withdrawal queue.
    error PendingWithdrawals(uint256 pendingShares);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// @param vault_ The vault this governor will own. Ownership is handed over by the vault's current owner with
    ///        `transferOwnership(this)` followed by `acceptVaultOwnership`.
    /// @param admin_ Account that will queue and execute changes.
    /// @param delay DELAY, seconds. Proposed for mainnet: 3 days.
    /// @param longDelay LONG_DELAY, seconds; at least `delay`. Proposed for mainnet: 32 days.
    /// @param grace GRACE, seconds. Proposed for mainnet: 7 days.
    constructor(address vault_, address admin_, uint256 delay, uint256 longDelay, uint256 grace) {
        if (vault_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        if (delay == 0 || grace == 0 || longDelay < delay || longDelay > 365 days || grace > 365 days) {
            revert InvalidDelays();
        }
        vault = vault_;
        admin = admin_;
        DELAY = delay;
        LONG_DELAY = longDelay;
        GRACE = grace;
    }

    /// @notice Id of the change that sends `data` to `target`.
    /// @param target Governed contract.
    /// @param data Exact calldata.
    /// @return keccak256(abi.encode(target, data)).
    function operationId(address target, bytes calldata data) public pure returns (bytes32) {
        return keccak256(abi.encode(target, data));
    }

    /// @notice Delay that `data` sent to `target` will wait once queued.
    /// @dev Reverts with `InvalidCall` for calldata shorter than a selector and with `InvalidTarget` for a target that is
    ///      neither the vault nor one of its hooks owned by this governor.
    /// @param target Governed contract.
    /// @param data Calldata.
    /// @return Seconds: LONG_DELAY for the vault's `setInventoryBounds` and for its `transferOwnership` to a non-zero
    ///         nominee, DELAY otherwise.
    function delayFor(address target, bytes calldata data) public view returns (uint256) {
        if (data.length < 4) revert InvalidCall();
        if (target != vault) {
            if (_answer(target, _HOOK_OWNER) != address(this) || _answer(target, _VAULT) != vault) {
                revert InvalidTarget(target);
            }
            return DELAY;
        }
        return _isLong(data) ? LONG_DELAY : DELAY;
    }

    /// @notice Queue one call to a governed contract.
    /// @dev Admin only. The call itself is not validated here: a change that would revert simply fails at `execute` and
    ///      can be canceled. Queuing the same target and calldata twice is refused, so a change can not be re-armed
    ///      with a fresh delay while an older copy is still pending. Calldata that differs only in bytes the target
    ///      ignores (for example trailing bytes) is a different id; monitors must decode `data`, not compare ids.
    /// @param target `vault`, or a hook of `vault` whose `hookOwner()` is this contract.
    /// @param data Exact calldata to send to `target` later.
    /// @return id `operationId(target, data)`.
    /// @return when Earliest execution time, seconds since the epoch.
    function queue(address target, bytes calldata data) external onlyAdmin returns (bytes32 id, uint256 when) {
        id = operationId(target, data);
        if (eta[id] != 0) revert AlreadyQueued(id);
        when = block.timestamp + delayFor(target, data);
        eta[id] = when;
        emit Queued(id, target, when, data);
    }

    /// @notice Drop a queued change.
    /// @dev Admin, or the vault's current guardian for any change except a call to the vault's `setGuardian`.
    /// @param target Target the change was queued for.
    /// @param data Calldata that was queued.
    function cancel(address target, bytes calldata data) external {
        if (msg.sender != admin) {
            if (
                msg.sender != IGovernedVault(vault).guardian()
                    || (target == vault && (data.length < 4 || bytes4(data) == _SET_GUARDIAN))
            ) revert NotAllowedToCancel();
        }
        bytes32 id = operationId(target, data);
        if (eta[id] == 0) revert NotQueued(id);
        delete eta[id];
        emit Canceled(id, msg.sender);
    }

    /// @notice Send a matured change to its target.
    /// @dev Admin only, within [eta, eta + GRACE]. A LONG_DELAY change also requires `vault.pendingShares() == 0`
    ///      (`PendingWithdrawals`), see the contract documentation. The record is deleted before the call, so the same
    ///      queued change can run at most once (replay needs a new `queue` and a new delay); if the target reverts, the
    ///      whole transaction reverts and the change stays queued. The target's revert data is passed through
    ///      unchanged.
    /// @param target Target the change was queued for.
    /// @param data Calldata that was queued.
    /// @return result The target's return data.
    function execute(address target, bytes calldata data) external onlyAdmin returns (bytes memory result) {
        bytes32 id = operationId(target, data);
        uint256 when = eta[id];
        if (when == 0) revert NotQueued(id);
        if (block.timestamp < when || block.timestamp > when + GRACE) revert NotExecutable(id, when);
        if (target == vault && _isLong(data)) {
            uint256 pending = IGovernedVault(vault).pendingShares();
            if (pending != 0) revert PendingWithdrawals(pending);
        }
        delete eta[id];
        bool ok;
        (ok, result) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
        emit Executed(id, target);
    }

    /// @notice Complete a handover of vault ownership to this contract.
    /// @dev Admin only, without delay: accepting ownership puts the vault under the delays, it never removes one.
    function acceptVaultOwnership() external onlyAdmin {
        (bool ok, bytes memory result) = vault.call(abi.encodeWithSelector(_ACCEPT_OWNERSHIP));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    /// @dev True for the vault calls that take LONG_DELAY. `data` is at least 4 bytes (checked by every caller's path:
    ///      `delayFor` at queue time, and only queued calldata reaches `execute`).
    ///      `transferOwnership` is short only when its argument word is present and zero. The vault's ABI decoder
    ///      rejects an address word with non-zero upper bits and calldata without a full word, so the zero word is
    ///      exactly the case in which the vault stores `pendingOwner = address(0)`; bytes after that word are ignored by
    ///      the vault and do not change the effect. Anything shorter stays LONG_DELAY (and would revert in the vault).
    function _isLong(bytes calldata data) internal pure returns (bool) {
        bytes4 selector = bytes4(data);
        if (selector == _SET_INVENTORY_BOUNDS) return true;
        if (selector != _TRANSFER_OWNERSHIP) return false;
        return data.length < 36 || bytes32(data[4:36]) != bytes32(0);
    }

    /// @dev The address a zero-argument getter of `target` returns, or address(0) if the call fails, returns fewer than
    ///      32 bytes, or returns a word with dirty upper bits. A `staticcall`, so the target cannot change state; an
    ///      account without code answers with no data and therefore address(0).
    function _answer(address target, bytes4 selector) internal view returns (address value) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSelector(selector));
        if (!ok || ret.length < 32) return address(0);
        uint256 word = abi.decode(ret, (uint256));
        if (word >> 160 != 0) return address(0);
        value = address(uint160(word));
    }
}
