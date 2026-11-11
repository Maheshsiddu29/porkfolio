// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev The one vault getter the governor reads: the address allowed to cancel queued changes.
interface IVaultGuardian {
    function guardian() external view returns (address);
}

/// @title VaultGovernor
/// @notice Timelock that holds the owner role of one `SharedCommitmentVault`. Every owner call to the vault is queued
///         here first and can be executed only after a public delay, so LPs can see a change coming and leave before
///         it applies. Changes that lower the vault's inventory floor, or that hand the owner role elsewhere, wait
///         longer than every other change.
/// @dev
/// Roles.
///   admin      Fixed at construction (expected: a multisig). Queues, executes and cancels changes. It has no other
///              power: every vault call goes through `queue` and `execute`.
///   guardian   The vault's current guardian (read live from the vault). May cancel any queued change except one that
///              calls `setGuardian`, so a compromised guardian can delay governance but cannot block its own
///              replacement. Its immediate, risk-reducing powers (pause, halt, raise a floor, lower a tolerance...) are
///              exercised directly on the vault, not here.
///
/// What the delay covers. The vault owner can loosen any limit (`_authorize` in the vault lets the owner make any
/// change), so as long as this contract is the owner, every loosening waits. The owner role has no function that moves
/// LP assets, so this contract has no path to vault accounting either: it can only call the vault's configuration
/// functions, with exactly the calldata that was queued.
///
/// Delays.
///   LONG_DELAY (32 days)  `setInventoryBounds` and `transferOwnership`. The inventory floor is what bounds LP losses
///                         under a wrong price; a redemption queued when the change is announced is finalized within
///                         MAX_HORIZON (30 days) plus one flow window, so it completes before the change applies.
///                         `transferOwnership` gets the same delay because a new owner need not be a timelock at all.
///   DELAY (3 days)        Everything else, including changes that tighten. Immediate tightening is the guardian's job.
///   GRACE (7 days)        How long a matured change stays executable. Afterwards it must be queued again.
///
/// The trust boundary this creates is a deployment property: it holds only while `vault.owner() == address(this)`.
/// Anyone can check that on-chain, and `transferOwnership` away from this contract itself waits LONG_DELAY.
///
/// Not implemented: rotating `admin` (deploy a new governor and transfer the vault to it), batching several calls into
/// one change, calling any contract other than `vault`.
contract VaultGovernor {
    /// @notice Delay of an ordinary queued change, in seconds.
    uint256 public constant DELAY = 3 days;
    /// @notice Delay of a change to the inventory floor or to vault ownership, in seconds.
    uint256 public constant LONG_DELAY = 32 days;
    /// @notice Seconds after its earliest execution time during which a queued change may still be executed.
    uint256 public constant GRACE = 7 days;

    /// @dev Selectors of the vault calls that take LONG_DELAY. Spelled out rather than imported so the governor does
    ///      not compile the vault; `test/governance/VaultGovernor.t.sol` checks them against the vault's selectors.
    bytes4 internal constant _SET_INVENTORY_BOUNDS =
        bytes4(keccak256("setInventoryBounds(uint256,uint256,uint24,uint24)"));
    bytes4 internal constant _TRANSFER_OWNERSHIP = bytes4(keccak256("transferOwnership(address)"));
    bytes4 internal constant _SET_GUARDIAN = bytes4(keccak256("setGuardian(address)"));
    bytes4 internal constant _ACCEPT_OWNERSHIP = bytes4(keccak256("acceptOwnership()"));

    /// @notice The only contract this governor ever calls.
    address public immutable vault;
    /// @notice Account that queues, executes and cancels changes.
    address public immutable admin;

    /// @notice Earliest execution time of each queued change, by `id` = keccak256(calldata). Zero: not queued.
    mapping(bytes32 id => uint256) public eta;

    /// @notice `data` (exact vault calldata) was queued; executable in [eta, eta + GRACE].
    event Queued(bytes32 indexed id, uint256 eta, bytes data);
    /// @notice A queued change was dropped by the admin or the guardian.
    event Canceled(bytes32 indexed id, address indexed by);
    /// @notice A queued change was sent to the vault and succeeded. It can not be executed again.
    event Executed(bytes32 indexed id);

    /// @notice Caller is not the admin.
    error NotAdmin();
    /// @notice Caller is neither the admin nor the vault's guardian, or is the guardian cancelling `setGuardian`.
    error NotAllowedToCancel();
    /// @notice A zero vault or admin address at construction.
    error ZeroAddress();
    /// @notice The same calldata is already queued; cancel it first to restart its delay.
    error AlreadyQueued(bytes32 id);
    /// @notice No queued change has this calldata.
    error NotQueued(bytes32 id);
    /// @notice The change is outside its window: `block.timestamp` is before `eta` or after `eta + GRACE`.
    error NotExecutable(bytes32 id, uint256 eta);
    /// @notice Calldata shorter than a selector.
    error InvalidCall();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// @param vault_ The vault this governor will own. Ownership is handed over by the vault's current owner with
    ///        `transferOwnership(this)` followed by `acceptVaultOwnership`.
    /// @param admin_ Account that will queue and execute changes.
    constructor(address vault_, address admin_) {
        if (vault_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        vault = vault_;
        admin = admin_;
    }

    /// @notice Delay that `data` will wait once queued.
    /// @param data Vault calldata.
    /// @return Seconds: LONG_DELAY for `setInventoryBounds` and `transferOwnership`, DELAY otherwise.
    function delayFor(bytes calldata data) public pure returns (uint256) {
        if (data.length < 4) revert InvalidCall();
        bytes4 selector = bytes4(data);
        return selector == _SET_INVENTORY_BOUNDS || selector == _TRANSFER_OWNERSHIP ? LONG_DELAY : DELAY;
    }

    /// @notice Queue one vault call.
    /// @dev Admin only. Nothing about the call is validated here: a change that would revert in the vault simply fails
    ///      at `execute` and can be canceled. Queuing the same calldata twice is refused, so a change can not be
    ///      re-armed with a fresh delay while an older copy is still pending.
    /// @param data Exact calldata to send to the vault later.
    /// @return id keccak256(data).
    /// @return when Earliest execution time, seconds since the epoch.
    function queue(bytes calldata data) external onlyAdmin returns (bytes32 id, uint256 when) {
        id = keccak256(data);
        if (eta[id] != 0) revert AlreadyQueued(id);
        when = block.timestamp + delayFor(data);
        eta[id] = when;
        emit Queued(id, when, data);
    }

    /// @notice Drop a queued change.
    /// @dev Admin, or the vault's current guardian for any change except a call to `setGuardian`.
    /// @param data Calldata that was queued.
    function cancel(bytes calldata data) external {
        if (msg.sender != admin) {
            if (msg.sender != IVaultGuardian(vault).guardian() || data.length < 4 || bytes4(data) == _SET_GUARDIAN) {
                revert NotAllowedToCancel();
            }
        }
        bytes32 id = keccak256(data);
        if (eta[id] == 0) revert NotQueued(id);
        delete eta[id];
        emit Canceled(id, msg.sender);
    }

    /// @notice Send a matured change to the vault.
    /// @dev Admin only, within [eta, eta + GRACE]. The record is deleted before the call, so the same queued change can
    ///      run at most once (replay needs a new `queue` and a new delay); if the vault reverts, the whole transaction
    ///      reverts and the change stays queued. The vault's revert data is passed through unchanged.
    /// @param data Calldata that was queued.
    /// @return result The vault's return data.
    function execute(bytes calldata data) external onlyAdmin returns (bytes memory result) {
        bytes32 id = keccak256(data);
        uint256 when = eta[id];
        if (when == 0) revert NotQueued(id);
        if (block.timestamp < when || block.timestamp > when + GRACE) revert NotExecutable(id, when);
        delete eta[id];
        bool ok;
        (ok, result) = vault.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
        emit Executed(id);
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
}
