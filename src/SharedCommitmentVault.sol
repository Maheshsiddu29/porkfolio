// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

import {ISharedCommitmentVault} from "./interfaces/ISharedCommitmentVault.sol";
import {IVaultState} from "./interfaces/IVaultState.sol";

/// @title SharedCommitmentVault
/// @notice A two-asset reserve that several Uniswap v4 hooks can sell from. LPs deposit both assets and receive
///         shares; curators reserve slices of the reserve for specific hooks; hooks swap against those slices from
///         inside `beforeSwap`. This is not an ERC-4626 vault: there is no single underlying asset and no on-chain
///         valuation. A share is a fraction of both asset balances and is always paid out in kind.
/// @dev
/// Custody. The reserve is held as ERC-6909 claims on the PoolManager, not as ERC-20 balances in this contract. A
/// claim is the PoolManager's IOU for ERC-20 it already holds. Holding claims lets a swap move reserve assets with
/// cheap claim transfers inside the PoolManager's unlock, and lets a hook turn the claims it receives into the
/// swap's output by burning them. ERC-20 only moves at the edges: when an LP deposits (the vault mints claims) and
/// when an LP or a redemption receiver is paid (the vault burns claims and takes the ERC-20 out).
///
/// Shared reserve. Any number of registered hooks, each on its own pool over the same two currencies, draw on the
/// same balances. They cannot draw freely. A hook can only consume an allocation: capacity a curator reserved for
/// that hook, on one pool, in one direction, up to a maximum output, until an expiry, at or above a minimum price.
/// Reserving capacity (`reserveFor`) moves no assets; it only stops the same inventory from being promised twice or
/// paid out to redeeming LPs while the commitment is live.
///
/// Authority over claims. The vault never calls `setOperator` or `approve` on the PoolManager, so nobody else can
/// move the vault's claims. The relationship runs the other way: each hook makes the vault an operator over the
/// hook's own claims, so that `exchange` can pull the input claims the hook just minted. The vault pulls input
/// before it pushes output, so a hook that has not funded its input cannot receive output.
///
/// Notation, per asset a in {asset0, asset1}. `docs/architecture/SHARE_ACCOUNTING.md` has derivations.
///   B_a = backing[a]           Claims the vault has accounted for. Never more than its real PoolManager balance;
///                              claims donated straight to the vault are not counted.
///   Q_a = reserved[a]          Unused capacity of all unreleased allocations selling a.
///   W_a = claimableAssets[a]   Assets already finalized for queued redemptions and owed to specific requests.
///   N_a = B_a - W_a            Net assets owned by outstanding shares (includes Q_a).
///   F_a = N_a - Q_a            Free inventory: what can be paid out now without breaking a commitment.
///   S   = totalShares          All outstanding shares, including queued shares and the locked MIN_SHARES.
///   P   = pendingShares        Shares waiting in the withdrawal queue. They still carry gains and losses.
///   D_a = ceil(P * N_a / S)    The queue's current pro-rata claim on a. New allocations may not take it.
///   R_a = bufferFloor[a]       Inventory that new allocations must leave untouched. Does not restrict LP exits.
///
/// Accounting relations every external function maintains:
///   Q_a + W_a <= B_a <= PoolManager.balanceOf(vault, a)
///   W_a = sum of request claimables;  P = sum of request sharesPending;  S = sum(sharesOf) + P.
/// Admission rule for a new allocation of size q:  Q_a + q + R_a + D_a <= N_a.
///
/// Roles.
///   Owner     Configures everything, initializes the vault, can loosen limits. Has no function that moves LP assets.
///   Guardian  Optional emergency role. May only make changes that reduce risk (see `_authorize`).
///   Curator   Registered address that reserves capacity for hooks, within its own per-currency ceiling, through
///             the authorization module (a signed instruction, or a call to the module).
///   Module    The installed authorization module (`authModule`): the only caller of `reserveFor`.
///   Consumer  Registered hook that calls `exchange` against allocations made out to it.
///   LP        Anyone, after initialization: deposits, redeems, cancels and claims its own requests.
///
/// Curator lifecycle. Each curator has a `CuratorRecord` with two independent controls and a counter:
///   registered   whether it may create new allocations (owner registers; owner or guardian deregisters);
///   restriction  None, Frozen or Revoked: whether its existing allocations may be consumed. Frozen is imposed by
///                the owner or guardian and lifted only by the owner. Revoked is permanent.
///   generation   counter that invalidates curator instructions not yet turned into allocations. It only rises.
/// A curator may create allocations only while registered and unrestricted. Its allocations may be consumed while it
/// is unrestricted, whether or not it is still registered. Freezing and revoking move no assets and keep every
/// reservation in place; the reserved capacity is returned only when each allocation is released.
///
/// Reentrancy. The vault calls three kinds of external code: the PoolManager (trusted, canonical v4), the two pair
/// ERC-20s and nothing else. ERC-6909 claim transfers make no external calls, and `exchange` performs only claim
/// transfers, so no foreign code runs inside it. Foreign code can run only inside an ERC-20 transfer: the deposit's
/// `transferFrom` (from `unlockCallback`, through `_settleIn`) and the payout's `transfer` (made by the PoolManager
/// inside `take`, through `_payOut`). In the deposit window B_a has already been raised but the matching claims
/// are not minted yet, so B_a briefly exceeds the real claim balance. Every entry point that reads or changes
/// share, queue or commitment accounting therefore holds a transaction-scoped lock (`nonReentrant`), and a call to
/// any of them from inside such a window reverts with `ReentrantCall`. `unlockCallback` deliberately does not take
/// the lock: it only ever runs inside the vault's own `unlock`, while the lock is already held. Configuration setters
/// and `bumpGeneration` do not take it: they make no external calls and read no accounting. Nested `unlock` is
/// separately impossible: the PoolManager reverts with `AlreadyUnlocked`. Hooks that call `exchange` inside
/// `beforeSwap` are not affected: the lock is only held while a vault entry point is executing.
///
/// Risk limits. Each asset the vault sells has limits at three scopes: per consumer hook, per curator and
/// vault-wide (`RiskScope`, one `RiskLimit` record per scope and asset). Each record holds two limits:
///   flow cap        gross output paid under the scope in the current fixed window of FLOW_WINDOW seconds;
///   exposure cap    unused reserved capacity the scope may hold, in basis points of eligible backing
///                   E_a = N_a - D_a (net assets minus the queue's pro-rata claim).
/// Every `exchange` adds its output to all three flow records and reverts if any would exceed its cap. Every
/// `reserveFor` checks all three exposure caps. A record the owner never configured fails closed at both points.
/// The four quantities are kept apart:
///   reserved capacity   Q_a, curatorReserved, hookReserved: promised but not yet paid; falls on consumption,
///                       cancellation, release and expiry-release;
///   gross outflow       RiskLimit.flowUsed: paid in the current window; only consumption raises it, nothing
///                       lowers it before the window ends, and inflows are never netted against it;
///   free inventory      F_a = N_a - Q_a: what LP exits can be paid from;
///   LP liabilities      W_a (finalized, owed) and D_a (queued, pro rata).
/// Flow and exposure limits apply only to `reserveFor` and `exchange`. Deposits, redemptions, queue processing,
/// claims, request cancellation, `release` and `cancelAllocation` never read them. The limits bound how much and how
/// fast the reserve can be sold; they say nothing about the price received, which only the floors bound.
///
/// Read-only helpers. This contract serves its stored records (public getters, `getAllocation`, `getRequest`) and
/// the admission limit `admissibleCapacity`. Previews, request status, N_a, F_a, D_a, deliverable shares and an
/// allocation's effective floor are computed by `VaultLens`, a separate stateless contract that reads the getters
/// declared in `IVaultState`. Nothing in this contract calls the lens; every check here uses its own internal copy
/// of those formulas.
///
/// Authorization module. New allocations are created only through `reserveFor`, which only `authModule` may call.
/// The module (`CuratorAuthorization`) verifies the curator's EIP-712 signature, or that the curator itself is
/// calling, and keeps the curators' nonces; it then tells the vault "this curator authorized this request under this
/// generation". The vault trusts it for nothing else: registration, restriction, generation, hook, pool, pair,
/// direction, floors, capacity, ceiling, admission, exposure caps and deadline are all checked here. The module holds
/// no assets and is not involved in `exchange`, cancellation, release or any LP path, so disabling or replacing it
/// (`setAuthModule`) affects only the creation of new allocations. The vault calls the module once, read-only, when
/// the owner installs it (to read `vault()`), and never otherwise. A compromised module can do at most what every
/// registered, unrestricted curator could do together: reserve within their ceilings and every vault-side limit.
///
/// Not implemented here: rolling-window flow limits (the flow window is a fixed epoch; see `FLOW_WINDOW`),
/// path-independent cumulative pricing, epoch-based expiry of commitments, transferable share tokens, and any
/// protocol, curator or performance fee.
contract SharedCommitmentVault is ISharedCommitmentVault, IVaultState, IUnlockCallback {
    /// @notice Largest amount accepted for any single asset amount, per-asset backing, or the share supply:
    ///         2^127 - 1.
    /// @dev The PoolManager converts amounts to int128 for its delta accounting, so anything larger would revert
    ///      deep inside it. Capping backing and supply here also guarantees that every amount stored in a
    ///      `WithdrawalRequest` or `Allocation` fits in uint128.
    uint256 public constant MAX_AMOUNT = uint256(uint128(type(int128).max));

    /// @notice Longest lifetime an allocation may have, measured from the block that creates it.
    /// @dev This bounds how long a queued redemption can be blocked by commitments that existed when it was
    ///      queued, provided someone calls `release` after they expire.
    uint256 public constant MAX_HORIZON = 30 days;

    /// @notice Shares minted to address(0) by `initialDeposit` and never redeemable.
    /// @dev Keeping S >= 1000 forever means no later operation divides by zero, the per-share basket can never be
    ///      reset by redeeming everything, and an attacker cannot cheaply make one share worth a huge amount.
    uint256 public constant MIN_SHARES = 1000;

    /// @notice How many queue entries `redeem` processes before it decides whether an instant exit is possible.
    /// @dev Without this step, a request that free inventory could already pay, but that nobody has processed yet,
    ///      would block every instant exit (instant exits are only allowed while nothing is pending). The bound
    ///      keeps a redeemer's extra gas cost fixed however long the queue grows.
    uint256 public constant INLINE_QUEUE_STEPS = 4;

    /// @notice Length of one flow-limit window, in seconds.
    /// @dev Windows are fixed epochs aligned to Unix time: epoch e = floor(block.timestamp / FLOW_WINDOW) covers
    ///      [e * FLOW_WINDOW, (e + 1) * FLOW_WINDOW - 1]. A trade at exactly (e + 1) * FLOW_WINDOW is in epoch e + 1.
    ///      Boundary burst: a fixed epoch is not a rolling window. A scope can pay its full cap in the last second of
    ///      one epoch and its full cap again in the first second of the next, so up to 2 * cap can leave within two
    ///      seconds, and any interval of T seconds can see up to (ceil(T / FLOW_WINDOW) + 1) * cap. Within a single
    ///      epoch the total never exceeds the cap in force at each trade.
    uint256 public constant FLOW_WINDOW = 1 days;

    /// @dev Denominator of the exposure caps: 10,000 basis points = 100%.
    uint256 internal constant _BPS = 10_000;

    /// @notice The Uniswap v4 PoolManager that holds the ERC-20 behind the vault's claims.
    IPoolManager public immutable poolManager;
    /// @notice First asset of the pair. Always the lower address, matching v4 `PoolKey.currency0` ordering.
    Currency public immutable asset0;
    /// @notice Second asset of the pair. Always the higher address, matching v4 `PoolKey.currency1` ordering.
    Currency public immutable asset1;

    /// @notice Current owner. See the role table in the contract documentation.
    address public owner;
    /// @notice When true, deposits, new allocations and all `exchange` calls revert. LP exits keep working.
    /// @dev Declared after `owner` so both share one storage slot; owner-gated, pause-checked calls read it once.
    bool public paused;
    /// @notice Nominee of a two-step ownership transfer. Zero when no transfer is pending.
    address public pendingOwner;
    /// @notice Emergency role that may only reduce risk. Zero means there is no guardian.
    address public guardian;

    /// @notice Hooks allowed to call `exchange` and to be named as an allocation's consumer.
    mapping(address consumer => bool) public isConsumer;
    /// @dev Curator records (registration, restriction, generation), one storage slot each. Read with
    ///      `getCurator`. See `CuratorRecord` for the states they encode.
    mapping(address curator => CuratorRecord) internal _curators;
    /// @notice Most unused capacity, in raw units of `currency`, that a curator may hold across its unreleased
    ///         allocations. Zero means the curator can allocate nothing in that currency.
    mapping(address curator => mapping(Currency currency => uint256)) public curatorCeiling;
    /// @notice Unused capacity currently held by a curator's unreleased allocations, in raw units of `currency`.
    /// @dev Moves in lockstep with `reserved`: raised by `reserveFor`, lowered by `exchange`, `release` and
    ///      `cancelAllocation`.
    mapping(address curator => mapping(Currency currency => uint256)) public curatorReserved;

    /// @notice B_a: ERC-6909 claims the vault has accounted for, in raw units of the asset.
    mapping(Currency currency => uint256) public backing;
    /// @notice Q_a: total unused capacity of all unreleased allocations that sell this asset.
    mapping(Currency currency => uint256) public reserved;
    /// @notice R_a: inventory that new allocations must leave unreserved. Existing allocations and LP exits are
    ///         not affected by it.
    mapping(Currency currency => uint256) public bufferFloor;
    /// @notice Vault price floor and halt flag for the direction in which the vault sells `currencyOut`.
    mapping(Currency currencyOut => SellPolicy) public sellPolicy;
    /// @notice W_a: assets finalized for queued redemptions but not yet claimed. These belong to specific
    ///         requests, not to the remaining shares, and no path except `claim` reduces them.
    mapping(Currency currency => uint256) public claimableAssets;

    /// @dev Allocation records by id. Ids start at 1, so an all-zero record (consumer == address(0)) means
    ///      "unknown allocation".
    mapping(uint256 allocationId => Allocation) internal _allocations;
    /// @notice Id the next successful `reserveFor` call will assign.
    uint256 public nextAllocationId = 1;

    /// @notice S: all outstanding shares, including queued shares and the MIN_SHARES held by address(0).
    uint256 public totalShares;
    /// @notice P: shares escrowed in the withdrawal queue and not yet finalized.
    uint256 public pendingShares;
    /// @notice Free (not escrowed) shares of each account. Shares are not transferable.
    mapping(address account => uint256) public sharesOf;

    /// @dev Withdrawal requests by id. Ids start at 1 and increase, which defines FIFO order.
    mapping(uint256 requestId => WithdrawalRequest) internal _requests;
    /// @notice Id the next queued redemption will receive.
    uint256 public nextRequestId = 1;
    /// @notice Lowest request id that may still hold pending shares. Every request below it is finished or
    ///         canceled, so queue processing starts here.
    uint256 public queueHead = 1;

    /// @notice Unused capacity currently held by a hook's unreleased allocations, in raw units of `currency`.
    /// @dev The per-hook counterpart of `curatorReserved`, and like it the sum of maxOut - consumed over the hook's
    ///      unreleased allocations: raised by `allocate`, lowered by `exchange` and `_close`. Summed over all hooks it
    ///      equals Q_a. Used only for the hook-scope exposure cap.
    mapping(address consumer => mapping(Currency currency => uint256)) public hookReserved;
    /// @dev Risk limits by keccak256(abi.encode(scope, account, currency)); see `RiskLimit` and `getRiskLimit`.
    mapping(bytes32 key => RiskLimit) internal _riskLimits;

    /// @notice The authorization module, the only address allowed to call `reserveFor`. Zero: none installed, so no
    ///         new allocation can be created.
    address public authModule;
    /// @dev Modules that were installed and then replaced or disabled. A retired module can never be installed again.
    mapping(address module => bool) internal _retiredAuthModule;

    /// @dev Transient-storage (EIP-1153) slot of the reentrancy lock: keccak256 of
    ///      "porkfolio.SharedCommitmentVault.reentrancyLock". Transient storage is cleared at the end of every
    ///      transaction and rolled back with a revert, so the lock can never stay set by mistake.
    bytes32 private constant _REENTRANCY_LOCK_SLOT = 0xbc86ec4092e271d217b22411f5f8c1533dd8caf0c495b30a01b8a9361c37fd9e;

    /// @notice Which leg `unlockCallback` should run.
    enum CallbackAction {
        Deposit,
        Withdraw
    }

    /// @dev Reverts with `NotOwner` unless the caller is the current owner.
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev Reverts with `Paused` while the vault is paused. Applied to inflows and consumption only.
    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    /// @dev Transaction-scoped lock shared by every entry point that touches share, queue or commitment accounting
    ///      (see "Reentrancy" in the contract documentation). Listed first on each function, so a reentrant call
    ///      fails with `ReentrantCall` before any other check runs.
    modifier nonReentrant() {
        _enterLock();
        _;
        _exitLock();
    }

    /// @notice Fixes the PoolManager and the asset pair for the lifetime of the vault.
    /// @dev The pair must be given in PoolKey order (asset0 < asset1) so `reserveFor` can compare it field by field
    ///      with a pool's currencies. Native ETH (address zero) is rejected because deposits pull ERC-20 with
    ///      `transferFrom`. Price floors start unset, so no allocation is possible until the owner opens a
    ///      direction with `setSellFloor`.
    /// @param poolManager_ Uniswap v4 PoolManager the vault keeps its claims in.
    /// @param owner_ Initial owner.
    /// @param asset0_ Lower-address ERC-20 of the pair.
    /// @param asset1_ Higher-address ERC-20 of the pair.
    constructor(IPoolManager poolManager_, address owner_, Currency asset0_, Currency asset1_) {
        if (address(poolManager_) == address(0) || owner_ == address(0)) revert ZeroAddress();
        if (asset0_.isAddressZero()) revert NativeCurrencyUnsupported();
        // PoolKey currencies are sorted; requiring the same order lets reserveFor() match pools exactly.
        if (!(asset0_ < asset1_)) revert InvalidAssetPair();
        poolManager = poolManager_;
        owner = owner_;
        asset0 = asset0_;
        asset1 = asset1_;
        emit OwnershipTransferred(address(0), owner_);
    }

    // ==================================================================
    // Administration (no function here moves assets)
    //
    // Owner: every configuration change. Guardian: only changes that REDUCE risk (pause, deregister,
    // freeze or revoke a curator, lower a ceiling or a configured risk limit, raise a buffer floor, raise a price
    // floor, halt a direction, disable the authorization module, emergency release); it can never loosen, register,
    // unfreeze, unpause, resume, install a module, or touch ownership or the guardian slot.
    // Anyone else: nothing.
    // ==================================================================

    /// @notice Step 1 of a two-step ownership transfer: nominate `newOwner`.
    /// @dev Owner only. Ownership does not move until the nominee calls `acceptOwnership`, so a typo cannot hand
    ///      the vault to an address nobody controls. Nominating address(0) cancels a pending nomination.
    /// @param newOwner Address that may accept ownership, or zero to cancel.
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Step 2 of a two-step ownership transfer: the nominee takes ownership.
    /// @dev Only `pendingOwner` may call. Clears the nomination so it cannot be replayed. The guardian is not
    ///      changed; the new owner can replace it with `setGuardian`.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /// @notice Appoint a guardian, replace it, or remove it by passing address(0).
    /// @dev Owner only. The guardian cannot call this, so it cannot appoint a successor or remove itself.
    /// @param newGuardian New guardian, or zero for none.
    function setGuardian(address newGuardian) external onlyOwner {
        emit GuardianSet(guardian, newGuardian);
        guardian = newGuardian;
    }

    /// @notice Pause or unpause deposits, new allocations and all hook consumption.
    /// @dev Redemption, queue processing, request cancellation, claims, `release` and `cancelAllocation` stay
    ///      available while paused, so a pause can never trap LP assets or stop a curator reducing its exposure.
    ///      Owner may pause and unpause; the guardian may only pause.
    /// @param paused_ True to pause, false to unpause.
    function setPaused(bool paused_) external {
        _authorize(paused_);
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Register or revoke a hook as a consumer.
    /// @dev Revocation takes effect immediately: the hook's next `exchange` reverts. Its allocations stay
    ///      reserved until they are released (by anyone after expiry, or early by the owner or guardian) or
    ///      canceled by their curator. Owner may register and revoke; the guardian may only revoke.
    /// @param consumer Hook address. Must be non-zero.
    /// @param registered True to register, false to revoke.
    function setConsumer(address consumer, bool registered) external {
        if (consumer == address(0)) revert ZeroAddress();
        _authorize(!registered);
        isConsumer[consumer] = registered;
        emit ConsumerSet(consumer, registered);
    }

    /// @notice Register a curator, or deregister it.
    /// @dev Registration controls only whether the curator may create new allocations. It does not touch the
    ///      curator's restriction, so registering a frozen curator leaves it frozen, and a revoked curator can never
    ///      be registered again (`InvalidCuratorTransition`). Registration alone grants no capacity: the curator also
    ///      needs a non-zero `curatorCeiling`. Owner may register and deregister; the guardian may only deregister.
    ///
    ///      Deregistration stops new allocations at once and raises the curator's generation by one, so any
    ///      instruction the curator issued earlier but that was never turned into an allocation is dead, and
    ///      registering the curator again later does not bring it back. Example: a curator at generation 4 is
    ///      deregistered (generation 5) and registered again (still 5); an instruction tagged 4 stays invalid.
    ///      Allocations the curator already made are commitments to their hooks and stay consumable; to stop them,
    ///      freeze or revoke the curator, or release the allocations. Deregistering also raises the generation when
    ///      the curator is already deregistered. Reverts with `GenerationExhausted` if the generation is already
    ///      type(uint32).max; `freezeCurator` and `revokeCurator` never touch the generation and still work then.
    /// @param curator Curator address. Must be non-zero.
    /// @param registered True to register, false to deregister.
    function setCurator(address curator, bool registered) external {
        if (curator == address(0)) revert ZeroAddress();
        _authorize(!registered);
        CuratorRecord memory r = _curators[curator];
        if (registered) {
            if (r.restriction == CuratorRestriction.Revoked) revert InvalidCuratorTransition(curator, r.restriction);
        } else {
            r.generation = _nextGeneration(curator, r.generation);
        }
        r.registered = registered;
        _writeCurator(curator, r);
    }

    /// @notice Temporarily suspend a curator: it can create nothing, and none of its allocations can be consumed.
    /// @dev Owner or guardian. Takes effect in the same transaction: the next `exchange` against any of the
    ///      curator's allocations reverts with `CuratorRestricted`, however many allocations there are, because
    ///      `exchange` reads the curator's restriction on every call. Nothing else changes: no assets move, the
    ///      curator's allocations keep their reservations in Q_a and `curatorReserved`, and registration and
    ///      generation are untouched. Keeping the reservations means an unfreeze can never leave an allocation
    ///      without backing; the cost is that LP exits treat that capacity as committed until the allocations are
    ///      canceled, released by the owner or guardian, or expire (at most MAX_HORIZON). Reverts with
    ///      `InvalidCuratorTransition` unless the curator is currently unrestricted. Works while paused.
    /// @param curator Curator to freeze. Must be non-zero; it need not be registered.
    function freezeCurator(address curator) external {
        if (curator == address(0)) revert ZeroAddress();
        _authorize(true);
        CuratorRecord memory r = _curators[curator];
        if (r.restriction != CuratorRestriction.None) revert InvalidCuratorTransition(curator, r.restriction);
        r.restriction = CuratorRestriction.Frozen;
        _writeCurator(curator, r);
    }

    /// @notice Lift a freeze. The curator's existing allocations become consumable again.
    /// @dev Owner only: the guardian can impose a freeze but never lift one. Raises the generation by one, so
    ///      instructions issued before or during the freeze cannot be turned into allocations afterwards. Does not
    ///      change registration: a curator deregistered while frozen comes back deregistered. Reverts with
    ///      `InvalidCuratorTransition` unless the curator is frozen (a revoked curator can never be unfrozen), and
    ///      with `GenerationExhausted` if the generation cannot be raised, in which case the curator stays frozen.
    /// @param curator Frozen curator.
    function unfreezeCurator(address curator) external onlyOwner {
        CuratorRecord memory r = _curators[curator];
        if (r.restriction != CuratorRestriction.Frozen) revert InvalidCuratorTransition(curator, r.restriction);
        r.restriction = CuratorRestriction.None;
        r.generation = _nextGeneration(curator, r.generation);
        _writeCurator(curator, r);
    }

    /// @notice Permanently revoke a curator: it can never create or execute again, and anyone may release its
    ///         allocations.
    /// @dev Owner or guardian. One storage write whatever the number of allocations: `exchange` rejects every
    ///      allocation of a revoked curator from this transaction on. The reservations stay in Q_a and
    ///      `curatorReserved` until each allocation is closed; `release` accepts a call from anyone for an
    ///      allocation of a revoked curator, so keepers, LPs or the guardian can clean up one allocation per call.
    ///      Until then that capacity cannot be consumed by anyone and is not available to LP exits; it is never
    ///      double counted, because each allocation can be closed only once. Also deregisters the curator.
    ///      Revocation is terminal: `setCurator(c, true)` and `unfreezeCurator` revert for a revoked curator, even
    ///      after the owner or guardian changes. The generation is not changed (revocation must never fail); a
    ///      revoked curator cannot create allocations whatever its generation. Reverts with
    ///      `InvalidCuratorTransition` if the curator is already revoked. Works while paused.
    /// @param curator Curator to revoke. Must be non-zero; it need not be registered.
    function revokeCurator(address curator) external {
        if (curator == address(0)) revert ZeroAddress();
        _authorize(true);
        CuratorRecord memory r = _curators[curator];
        if (r.restriction == CuratorRestriction.Revoked) revert InvalidCuratorTransition(curator, r.restriction);
        r.registered = false;
        r.restriction = CuratorRestriction.Revoked;
        _writeCurator(curator, r);
    }

    /// @notice Raise the caller's own generation by one, invalidating every instruction it issued that has not
    ///         been turned into an allocation yet.
    /// @dev Anyone may call; it only changes the caller's own record. Works in every state and while paused, so a
    ///      deregistered, frozen or revoked curator can still invalidate its outstanding instructions. Allocations
    ///      that already exist are not affected. Reverts with `GenerationExhausted` at type(uint32).max.
    /// @return generation The caller's new generation.
    function bumpGeneration() external returns (uint32 generation) {
        CuratorRecord memory r = _curators[msg.sender];
        generation = _nextGeneration(msg.sender, r.generation);
        r.generation = generation;
        _writeCurator(msg.sender, r);
    }

    /// @notice Set the most unused capacity `curator` may hold in `currency` across its unreleased allocations.
    /// @dev The ceiling is checked only when a new allocation is made. Lowering it below what the curator already
    ///      holds is allowed: existing allocations are untouched and the curator simply cannot allocate more until
    ///      consumption or releases bring it back under the ceiling. Owner may raise or lower; the guardian may
    ///      only lower (or set the same value).
    /// @param curator Curator whose limit changes. Must be non-zero.
    /// @param currency Currency the vault would sell under this curator's allocations.
    /// @param ceiling New limit in raw units of `currency`. Zero blocks new allocations in that currency.
    function setCuratorCeiling(address curator, Currency currency, uint256 ceiling) external {
        if (curator == address(0)) revert ZeroAddress();
        _authorize(ceiling <= curatorCeiling[curator][currency]);
        curatorCeiling[curator][currency] = ceiling;
        emit CuratorCeilingSet(curator, currency, ceiling);
    }

    /// @notice Configure the flow cap and the exposure cap of one scope in one asset.
    /// @dev Authorization. The owner may set any values, which also marks the record configured; configuring is the
    ///      only way to open a path (an unconfigured record blocks allocation and consumption). The guardian may
    ///      only tighten a record that is already configured: both new values must be at most the current ones.
    ///      Configuring a new record or raising either value is `GuardianCannotIncreaseRisk` for the guardian. A
    ///      record can never be unconfigured; set both values to zero to close it.
    ///
    ///      Effect on recorded usage. Only `flowCap` and `maxReservedBps` change. `flowUsed` and `epoch` are left as
    ///      they are, so no change can erase output already paid in the current window. Raising a cap lets the scope
    ///      pay the difference in this window. Lowering a cap below what was already used in this window blocks any
    ///      further output until the next window, which then starts at zero under the new cap. A cap change never
    ///      cancels or shrinks an existing allocation: the exposure cap is checked only when an allocation is created,
    ///      and an allocation that was within the cap stays valid when the cap or the backing later falls (its
    ///      consumption is still bounded by the flow caps, the floors and its own maxOut).
    ///
    ///      Works while paused. Records are keyed by address, not by curator generation or registration, so
    ///      deregistering, re-registering, freezing, unfreezing or revoking a curator, or unregistering and
    ///      re-registering a hook, never resets them; nor does replacing the owner or the guardian.
    /// @param scope Hook, Curator or Vault.
    /// @param account The hook or curator for those scopes (non-zero); address(0) for the vault scope.
    /// @param currency Asset the vault sells under this limit. Must be asset0 or asset1.
    /// @param flowCap Most gross output per window, raw units of `currency`. At most 2^104 - 1 (about 2 * 10^13
    ///        whole tokens at 18 decimals).
    /// @param maxReservedBps Exposure cap in basis points of eligible backing, at most 10,000.
    function setRiskLimit(RiskScope scope, address account, Currency currency, uint256 flowCap, uint16 maxReservedBps)
        external
    {
        _otherAsset(currency); // validates currency
        if ((scope == RiskScope.Vault) != (account == address(0))) revert InvalidRiskLimit();
        if (flowCap > type(uint104).max || maxReservedBps > _BPS) revert InvalidRiskLimit();
        RiskLimit storage l = _riskLimit(scope, account, currency);
        _authorize(l.configured && flowCap <= l.flowCap && maxReservedBps <= l.maxReservedBps);
        l.configured = true;
        // forge-lint: disable-next-line(unsafe-typecast) flowCap <= type(uint104).max, checked above.
        l.flowCap = uint104(flowCap);
        l.maxReservedBps = maxReservedBps;
        emit RiskLimitSet(scope, account, currency, flowCap, maxReservedBps, msg.sender);
    }

    /// @notice Set R_a, the inventory of `currency` that new allocations must leave unreserved.
    /// @dev Checked only by `reserveFor`, through the admission rule (`admissibleCapacity`). It does not reserve anything for a particular
    ///      LP and does not limit redemptions. Raising it above current free inventory does not affect existing
    ///      allocations; it only stops new ones. Owner may raise or lower; the guardian may only raise (or set the
    ///      same value).
    /// @param currency Asset the buffer applies to.
    /// @param floor New buffer, in raw units of `currency`.
    function setBufferFloor(Currency currency, uint256 floor) external {
        _authorize(floor >= bufferFloor[currency]);
        bufferFloor[currency] = floor;
        emit BufferFloorSet(currency, floor);
    }

    /// @notice Set the vault's minimum price for trades in which it sells `currencyOut`.
    /// @dev The floor is a Q64.96 fixed-point number: (minimum raw input units per raw output unit) * 2^96. A
    ///      value of 2^96 means "at least 1 raw unit in per raw unit out". Raw units ignore token decimals, so for a
    ///      6-decimal input and an 18-decimal output the ratio includes a factor of 10^6 / 10^18. Example: to sell
    ///      WETH (18 decimals) for at least 2,850 USDC (6 decimals) per WETH, the ratio is 2,850e6 / 1e18 and the
    ///      floor is ceil(2.85e-9 * 2^96) = 225,800,263,165,653,362,142.
    ///
    ///      Authorization. Opening a direction (from unset) or lowering a floor is owner-only. The guardian may only
    ///      raise a floor that is already set. Zero is rejected because zero is how "never configured" is stored;
    ///      use `setSellHalted` to stop a direction.
    ///
    ///      Directional consistency. When the opposite direction is also configured, the two floors must satisfy
    ///      F_this * F_opposite >= 2^192, i.e. (F_this / 2^96) * (F_opposite / 2^96) >= 1. If the product were
    ///      below 1, a trader could sell asset A to the vault at one floor, sell the proceeds back at the other
    ///      floor, and end with more A than they started with, at LP expense. Example: both floors at 0.99 * 2^96
    ///      turn 1,000 A into about 1,010.1 B and then about 1,020.3 A. With the product >= 1 there is a price k
    ///      at which every trade the floors allow leaves A + k * B in the vault no lower, so no sequence of trades
    ///      at or above the floors can leave the vault with less of both assets. The product can reach 2^320, so
    ///      it is never computed in 256 bits. The check uses the equivalent integer form
    ///      F_this >= ceil(2^192 / F_opposite), computed with FullMath's 512-bit intermediate; the result is at
    ///      most 2^192 because F_opposite >= 1. One consequence: once both directions are open, neither floor can be
    ///      below ceil(2^192 / (2^160 - 1)) = 2^32 + 1. Raising a floor only increases the product, so a guardian
    ///      tightening always passes this check.
    ///
    ///      The new floor applies at once to every outstanding allocation in this direction, because `exchange`
    ///      reads the live floor on every trade. A floor is a lower bound chosen by governance. It does not track
    ///      the market and does not guarantee fair value: trades anywhere above it are accepted.
    /// @param currencyOut Asset the vault sells in the direction being configured. Must be asset0 or asset1.
    /// @param minInPerOutX96 New floor, Q64.96 raw input per raw output. Must be non-zero.
    function setSellFloor(Currency currencyOut, uint160 minInPerOutX96) external {
        if (minInPerOutX96 == 0) revert ZeroPriceFloor();
        Currency opposite = _otherAsset(currencyOut);
        SellPolicy storage policy = sellPolicy[currencyOut];
        uint160 previous = policy.minInPerOutX96;
        _authorize(previous != 0 && minInPerOutX96 >= previous);
        uint256 oppositeFloor = sellPolicy[opposite].minInPerOutX96;
        if (oppositeFloor != 0) {
            // ceil(2^192 / oppositeFloor): the smallest floor in this direction that keeps the pair non-crossing.
            uint256 requiredMinimum = FullMath.mulDivRoundingUp(FixedPoint96.Q96, FixedPoint96.Q96, oppositeFloor);
            if (minInPerOutX96 < requiredMinimum) {
                revert InconsistentDirectionalFloors(minInPerOutX96, requiredMinimum);
            }
        }
        policy.minInPerOutX96 = minInPerOutX96;
        emit SellFloorSet(currencyOut, previous, minInPerOutX96, msg.sender);
    }

    /// @notice Halt or resume the direction in which the vault sells `currencyOut`.
    /// @dev A halt blocks new allocations and every `exchange` in that direction immediately, including against
    ///      existing allocations. The opposite direction and all LP exits are unaffected. Owner or guardian may
    ///      halt; only the owner may resume. A direction whose floor is not set yet may be halted too; the halt then
    ///      stays in force after the owner opens the direction.
    /// @param currencyOut Asset the vault sells in the affected direction. Must be asset0 or asset1.
    /// @param halted True to halt, false to resume.
    function setSellHalted(Currency currencyOut, bool halted) external {
        _otherAsset(currencyOut); // validates currencyOut
        _authorize(halted);
        sellPolicy[currencyOut].halted = halted;
        emit SellHaltedSet(currencyOut, halted, msg.sender);
    }

    // ==================================================================
    // LP deposits (proportional basket)
    // ==================================================================

    /// @notice Seed the empty vault and fix the initial ratio between the two assets.
    /// @dev Owner only, and the owner pays both amounts. Shares minted = floor(sqrt(amount0 * amount1)). Of these,
    ///      MIN_SHARES go to address(0) and can never be redeemed; `receiver` gets the rest. Example: seeding
    ///      1,000,000 raw units of asset0 and 4,000,000 of asset1 mints sqrt(4e12) = 2,000,000 shares, so
    ///      `receiver` gets 1,999,000. The geometric mean only sets the scale of the share unit. Later deposits and
    ///      redemptions are ratios of current balances, so token decimals do not matter after this point.
    ///
    ///      Locking MIN_SHARES is a defence against the classic first-depositor attack. Here it is a second line of
    ///      defence: donated claims are never counted in B_a, and later deposits name a share amount rather than an
    ///      asset amount, so a depositor cannot be rounded down to zero shares.
    ///
    ///      Can run once: afterwards totalShares >= MIN_SHARES forever. Reverts while paused.
    /// @param amount0 Raw units of asset0 to deposit. Non-zero and at most MAX_AMOUNT.
    /// @param amount1 Raw units of asset1 to deposit. Non-zero and at most MAX_AMOUNT.
    /// @param receiver Account credited with the free shares. Non-zero.
    /// @return shares Shares credited to `receiver` (total minted minus MIN_SHARES).
    function initialDeposit(uint256 amount0, uint256 amount1, address receiver)
        external
        nonReentrant
        onlyOwner
        whenNotPaused
        returns (uint256 shares)
    {
        if (totalShares != 0) revert AlreadyInitialized();
        if (receiver == address(0)) revert ZeroAddress();
        if (amount0 == 0 || amount1 == 0) revert ZeroAmount();
        if (amount0 > MAX_AMOUNT || amount1 > MAX_AMOUNT) revert AmountTooLarge();

        // amount0 * amount1 < 2^254: no overflow. root <= MAX_AMOUNT.
        uint256 root = FixedPointMathLib.sqrt(amount0 * amount1);
        if (root <= MIN_SHARES) revert InitialDepositTooSmall(root, MIN_SHARES);
        shares = root - MIN_SHARES;

        // Before initialization no allocation can exist (admission needs N_a > 0), so B_a == 0 here.
        totalShares = root;
        sharesOf[address(0)] = MIN_SHARES;
        sharesOf[receiver] = shares;
        backing[asset0] = amount0;
        backing[asset1] = amount1;

        _unlock(CallbackAction.Deposit, msg.sender, amount0, amount1);
        emit Deposited(msg.sender, receiver, shares, amount0, amount1);
    }

    /// @notice Buy exactly `shares` new shares by paying the current per-share amount of both assets.
    /// @dev Permissionless once the vault is initialized. The caller pays amount_a = ceil(shares * N_a / S) of each
    ///      asset, pulled with `transferFrom` from msg.sender. Example: with S = 1,000, N0 = 2,000 and N1 = 501,
    ///      buying 10 shares costs ceil(20) = 20 of asset0 and ceil(5.01) = 6 of asset1.
    ///
    ///      Rounding up means the depositor never pays less than the exact pro-rata amount, so N_a / S never falls
    ///      for existing holders. Paired with redemptions rounding down, depositing and immediately redeeming the
    ///      same shares can lose up to 1 raw unit per asset and never gains. The basket uses N_a, not B_a: assets
    ///      already finalized for queued redemptions belong to those requests, not to the shares being priced.
    ///
    ///      If one asset's N_a is zero (possible after a hook sold all of it), the deposit pays zero of it and a
    ///      non-zero amount of the other. Reverts while paused.
    /// @param shares Shares to mint. Non-zero; S + shares must not exceed MAX_AMOUNT.
    /// @param maxAmount0 Most asset0 the caller is willing to pay (slippage bound against trades in between).
    /// @param maxAmount1 Most asset1 the caller is willing to pay.
    /// @param receiver Account credited with the new shares. Non-zero.
    /// @return amount0 Raw asset0 paid.
    /// @return amount1 Raw asset1 paid.
    function deposit(uint256 shares, uint256 maxAmount0, uint256 maxAmount1, address receiver)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 supply = totalShares;
        if (supply == 0) revert NotInitialized();
        if (receiver == address(0)) revert ZeroAddress();
        if (shares == 0) revert ZeroAmount();
        if (shares > MAX_AMOUNT - supply) revert AmountTooLarge();

        (amount0, amount1) = _depositAmounts(shares, supply);
        if (amount0 > maxAmount0 || amount1 > maxAmount1) revert SlippageExceeded();
        if (amount0 > MAX_AMOUNT - backing[asset0] || amount1 > MAX_AMOUNT - backing[asset1]) {
            revert AmountTooLarge();
        }

        totalShares = supply + shares;
        sharesOf[receiver] += shares;
        backing[asset0] += amount0;
        backing[asset1] += amount1;

        _unlock(CallbackAction.Deposit, msg.sender, amount0, amount1);
        emit Deposited(msg.sender, receiver, shares, amount0, amount1);
    }

    // ==================================================================
    // Redemption: instant tier + FIFO queue
    // ==================================================================

    /// @notice Redeem shares for their in-kind basket, instantly where possible and through the queue otherwise.
    /// @dev Works while paused. Steps:
    ///      1. If any shares are pending, process up to INLINE_QUEUE_STEPS queue entries first (see
    ///         INLINE_QUEUE_STEPS for why).
    ///      2. Instant tier. Allowed only if nothing is pending after step 1, so a new redeemer can never overtake
    ///         a queued one. The instant portion is the largest share count whose basket free inventory can pay in
    ///         BOTH assets (`_deliverableShares`). Each share pays floor(shares * N_a / S) of each asset, rounded
    ///         down so the remaining holders never lose to rounding. Example: with S = 1,000 and N1 = 501,
    ///         redeeming 10 shares pays floor(5.01) = 5 of asset1.
    ///      3. Whatever is left becomes a new queue entry if `queueRemainder` is true, otherwise the call reverts
    ///         with `InsufficientLiquidity`. Queued shares leave the caller's balance but stay in S, so they keep
    ///         sharing trading gains and losses until they are finalized.
    ///
    ///      Dust handling: a redemption whose basket rounds to zero in both assets reverts with `DustRedemption`
    ///      rather than burning shares for nothing. If only the instant slice would round to zero, the whole amount
    ///      is queued instead.
    ///
    ///      The slippage bounds apply only to the instantly delivered amounts. When everything is queued those
    ///      amounts are zero, so any non-zero minimum reverts.
    /// @param shares Shares to redeem from the caller's free balance. Non-zero.
    /// @param minAmount0 Least asset0 the instant portion must pay.
    /// @param minAmount1 Least asset1 the instant portion must pay.
    /// @param receiver Address paid now, and the payee of the queued request if one is created. Non-zero.
    /// @param queueRemainder True to queue any part that cannot be paid now; false to revert instead.
    /// @return instantShares Shares burned and paid out in this call.
    /// @return amount0 Raw asset0 sent to `receiver` now.
    /// @return amount1 Raw asset1 sent to `receiver` now.
    /// @return requestId Id of the new queue entry, or 0 if nothing was queued.
    function redeem(uint256 shares, uint256 minAmount0, uint256 minAmount1, address receiver, bool queueRemainder)
        external
        nonReentrant
        returns (uint256 instantShares, uint256 amount0, uint256 amount1, uint256 requestId)
    {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        uint256 balance = sharesOf[msg.sender];
        if (shares > balance) revert InsufficientShares(shares, balance);

        // Queued LPs have priority over newly freed inventory. Serve them first (bounded), then allow an instant
        // exit only if nobody is still waiting. Without this step a deliverable-but-unprocessed request would
        // block every instant exit until someone called processQueue separately.
        if (pendingShares != 0) _processQueue(INLINE_QUEUE_STEPS);
        uint256 supply = totalShares;
        if (pendingShares == 0) {
            uint256 deliverable = _deliverableShares(supply);
            instantShares = shares < deliverable ? shares : deliverable;
            if (instantShares != 0) {
                (amount0, amount1) = _entitlement(instantShares, supply);
                if (amount0 == 0 && amount1 == 0) {
                    if (instantShares == shares) revert DustRedemption();
                    instantShares = 0; // partial instant portion is dust: queue everything instead
                }
            }
        }
        if (amount0 < minAmount0 || amount1 < minAmount1) revert SlippageExceeded();

        uint256 remainder = shares - instantShares;
        if (remainder != 0) {
            if (!queueRemainder) revert InsufficientLiquidity(shares, instantShares);
            (uint256 e0, uint256 e1) = _entitlement(remainder, supply);
            if (e0 == 0 && e1 == 0) revert DustRedemption();
        }

        sharesOf[msg.sender] = balance - shares;

        if (remainder != 0) {
            // Escrow: the shares leave the LP's balance but stay in totalShares (S), so N_a / S, and with it every
            // trade's gain or loss, keeps applying to them until they are finalized.
            pendingShares += remainder;
            requestId = nextRequestId++;
            // forge-lint: disable-next-line(unsafe-typecast) remainder <= S <= MAX_AMOUNT < 2^128.
            uint128 r = uint128(remainder);
            _requests[requestId] = WithdrawalRequest({
                lp: msg.sender,
                canceled: false,
                receiver: receiver,
                sharesRequested: r,
                sharesPending: r,
                claimable0: 0,
                claimable1: 0
            });
            emit RedeemRequested(requestId, msg.sender, receiver, remainder);
        }

        if (instantShares != 0) {
            // amount_a <= F_a <= B_a, so these cannot underflow; Q_a and W_a stay covered.
            totalShares = supply - instantShares;
            backing[asset0] -= amount0;
            backing[asset1] -= amount1;
            _unlock(CallbackAction.Withdraw, receiver, amount0, amount1);
            emit Redeemed(msg.sender, receiver, instantShares, amount0, amount1);
        }
    }

    /// @notice Finalize queued requests, oldest first, as far as free inventory allows. Anyone may call.
    /// @dev Finalizing converts a request's pending shares into fixed asset amounts at that moment's rate,
    ///      floor(s * N_a / S), burns the shares, and moves the assets from free inventory into W_a, where they are
    ///      owed to that request and can only leave through `claim`. From then on the request no longer shares in
    ///      trading results.
    ///
    ///      Ordering is strict FIFO by request id. Only the request at the head may be partially finalized, and
    ///      processing stops there until more inventory is free; it never skips ahead to a later, smaller request
    ///      that would fit. This keeps every waiting LP's position in line fixed. The tradeoff is head-of-line
    ///      blocking: a large head request absorbs freed inventory before anyone behind it.
    ///
    ///      Canceled or completed entries are skipped at the cost of one step each. A partial slice whose basket
    ///      rounds to zero in both assets is not finalized (that would burn shares for nothing); a whole request
    ///      that rounds to zero is finalized at zero so it cannot block the queue forever.
    /// @param maxSteps Most queue entries to visit in this call, to bound gas. Zero does nothing.
    /// @return sharesFinalized Total shares converted into claimable assets in this call.
    function processQueue(uint256 maxSteps) external nonReentrant returns (uint256 sharesFinalized) {
        return _processQueue(maxSteps);
    }

    /// @dev Shared by `processQueue` and the inline step in `redeem`. Visits at most `maxSteps` entries starting at
    ///      `queueHead` and advances `queueHead` past every entry it completes or skips. It stops early at a head
    ///      request that cannot be completed with current free inventory. Each finalized slice of s shares lowers P
    ///      and S by s and raises W_a by floor(s * N_a / S). Because s never exceeds `_deliverableShares`, that
    ///      amount is at most F_a, so finalization never uses reserved capacity.
    /// @param maxSteps Most entries to visit.
    /// @return sharesFinalized Total shares finalized.
    function _processQueue(uint256 maxSteps) internal returns (uint256 sharesFinalized) {
        uint256 id = queueHead;
        uint256 end = nextRequestId;
        for (uint256 step; step < maxSteps && id < end; ++step) {
            WithdrawalRequest storage r = _requests[id];
            uint256 pending = r.sharesPending;
            if (pending == 0) {
                ++id; // canceled or already finalized
                continue;
            }

            uint256 supply = totalShares;
            uint256 deliverable = _deliverableShares(supply);
            uint256 s = pending < deliverable ? pending : deliverable;
            if (s == 0) break;
            (uint256 e0, uint256 e1) = _entitlement(s, supply);
            // Never burn a partial slice for nothing; wait for more inventory instead.
            if (e0 == 0 && e1 == 0 && s < pending) break;

            // forge-lint: disable-next-line(unsafe-typecast) s <= pending (a uint128).
            r.sharesPending = uint128(pending - s);
            // forge-lint: disable-next-line(unsafe-typecast) e_a <= F_a <= B_a <= MAX_AMOUNT.
            r.claimable0 += uint128(e0);
            // forge-lint: disable-next-line(unsafe-typecast) e_a <= F_a <= B_a <= MAX_AMOUNT.
            r.claimable1 += uint128(e1);
            pendingShares -= s;
            totalShares = supply - s;
            claimableAssets[asset0] += e0;
            claimableAssets[asset1] += e1;
            sharesFinalized += s;
            emit RequestFinalized(id, s, e0, e1);

            if (s < pending) break; // inventory exhausted at the head
            ++id;
        }
        queueHead = id;
    }

    /// @notice Withdraw a request's still-pending shares back to the LP's free balance.
    /// @dev Only the request's LP may cancel. Amounts already finalized for the request stay claimable through
    ///      `claim`. Re-queuing the returned shares later creates a new request at the back of the line.
    ///      Cancelling lowers P, which lowers pending demand D_a and can make more capacity admissible for curators.
    /// @param requestId Request to cancel.
    /// @return sharesReturned Shares moved back to the LP's balance.
    function cancelRequest(uint256 requestId) external nonReentrant returns (uint256 sharesReturned) {
        WithdrawalRequest storage r = _requests[requestId];
        if (r.lp != msg.sender) revert NotRequestOwner(requestId);
        sharesReturned = r.sharesPending;
        if (sharesReturned == 0) revert NothingPending(requestId);
        r.sharesPending = 0;
        r.canceled = true;
        pendingShares -= sharesReturned;
        sharesOf[msg.sender] += sharesReturned;
        emit RequestCanceled(requestId, sharesReturned);
    }

    /// @notice Pay out everything finalized so far for a request.
    /// @dev Only the request's LP may call; the assets go to the request's `receiver`. Can be called after a
    ///      partial finalization and again later. The request's claimable amounts are zeroed before the external
    ///      payout, and W_a and B_a fall by the same amounts, so N_a and the remaining holders' basket do not change.
    /// @param requestId Request to claim.
    /// @return amount0 Raw asset0 paid to the receiver.
    /// @return amount1 Raw asset1 paid to the receiver.
    function claim(uint256 requestId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        WithdrawalRequest storage r = _requests[requestId];
        if (r.lp != msg.sender) revert NotRequestOwner(requestId);
        amount0 = r.claimable0;
        amount1 = r.claimable1;
        if (amount0 == 0 && amount1 == 0) revert NothingToClaim(requestId);

        r.claimable0 = 0;
        r.claimable1 = 0;
        claimableAssets[asset0] -= amount0;
        claimableAssets[asset1] -= amount1;
        backing[asset0] -= amount0;
        backing[asset1] -= amount1;

        address receiver = r.receiver;
        _unlock(CallbackAction.Withdraw, receiver, amount0, amount1);
        emit Claimed(requestId, receiver, amount0, amount1);
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Reachable only via this vault's own `poolManager.unlock` (PoolManager calls back msg.sender), so
    ///      `account` always originates from this contract: the depositor (msg.sender) or a redemption receiver.
    ///      Deposit: pull ERC-20 into the PoolManager and mint the matching claims to the vault. Withdraw: burn the
    ///      vault's claims and send the ERC-20 to `account`. Each leg leaves the vault's PoolManager delta at zero,
    ///      which `unlock` requires before it returns. It does not take the reentrancy lock: the entry point that
    ///      called `unlock` already holds it, and any vault entry point a token calls from inside these legs reverts
    ///      with `ReentrantCall`.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (CallbackAction action, address account, uint256 amount0, uint256 amount1) =
            abi.decode(data, (CallbackAction, address, uint256, uint256));

        if (action == CallbackAction.Deposit) {
            _settleIn(asset0, account, amount0);
            _settleIn(asset1, account, amount1);
        } else {
            _payOut(asset0, account, amount0);
            _payOut(asset1, account, amount1);
        }
        return "";
    }

    // ==================================================================
    // Curator allocations (capacity reservation)
    // ==================================================================

    /// @notice Reserve up to `req.maxOut` of `req.currencyOut` for one hook on one pool, on behalf of `curator`.
    /// @dev Only the installed authorization module (`authModule`) may call. The module vouches for one fact: that
    ///      `curator` authorized exactly `req` under `generation` (by an EIP-712 signature, or by calling the module
    ///      itself). Nothing else the module could say is trusted; every check below runs here on the vault's own
    ///      state. An allocation is a promise that the vault will keep this much of one asset available for the
    ///      named hook until `req.expiry`, at no worse than `req.minInPerOutX96`. No assets move; Q_a and the
    ///      curator's and hook's reserved totals rise by `maxOut`.
    ///
    ///      Checks, in order: caller is the installed module; curator neither frozen nor revoked; curator registered;
    ///      `generation` equals the curator's current generation; deadline not passed; consumer registered and equal
    ///      to `key.hooks`; pool currencies equal the vault's pair; `currencyOut` is one of them; direction
    ///      configured and not halted; curator floor >= vault floor; non-zero `maxOut` within MAX_AMOUNT; expiry in
    ///      the future and within MAX_HORIZON; curator ceiling; the admission rule Q_a + maxOut + R_a + D_a <= N_a;
    ///      and the exposure caps of the hook, the curator and the vault. Nonces are the module's: the vault does not
    ///      track them, and only reports `req.nonce` in `AllocationCreated`. Each allocation gets a new id, so two
    ///      requests can never produce the same allocation.
    ///
    ///      Generation. A request authorized before the curator's generation last rose (deregistration, unfreeze or
    ///      the curator's own `bumpGeneration`) fails with `StaleGeneration`, even if the curator has since been
    ///      registered again. The module passes the generation the curator signed; on the direct path, where the
    ///      curator is the caller, it passes the current one.
    ///
    ///      Admission and eligible backing. E_a = N_a - D_a is net assets minus the queue's pro-rata claim. The
    ///      admission limit is max(0, E_a - Q_a - R_a), computed by subtracting in turn with a floor at zero, which
    ///      equals max(0, N_a - Q_a - R_a - D_a) (see `admissibleCapacity`). It protects three things from being
    ///      promised to a hook: existing commitments (Q_a), the buffer (R_a), and the queue's pro-rata share (D_a).
    ///      Claimable assets W_a are excluded because N_a = B_a - W_a.
    ///
    ///      Exposure caps. For each scope, with `held` its current unused reserved capacity (hookReserved,
    ///      curatorReserved or Q_a) and `bps` its maxReservedBps, the allocation is accepted only if
    ///
    ///          (held + maxOut) * 10,000 <= bps * E_a
    ///
    ///      Both sides are exact integers below 2^142, so there is no rounding in the check itself; it is the same as
    ///      held + maxOut <= floor(bps * E_a / 10,000), i.e. the cap rounds down, against the curator and in favour
    ///      of LPs. D_a is rounded up, which lowers E_a further. Example: E_a = 1,000,001 and bps = 2,500 allow
    ///      held + maxOut <= 250,000. A record that was never configured reverts with `RiskLimitNotConfigured`, so a
    ///      path needs its hook, curator and vault records configured in this asset before anything can be reserved
    ///      on it. The exposure cap is an amount check only: it does not value the two assets against each other
    ///      and does not bound the price at which reserved capacity is later sold.
    ///
    ///      Floors. A curator floor below the live vault floor is rejected here, and `exchange` also applies
    ///      max(vault floor, curator floor), so a later vault-floor increase still binds this allocation. Because the
    ///      vault floor is at least 1, a zero curator floor is always rejected.
    /// @param req Allocation instruction; see `AllocationRequest` for the fields.
    /// @param curator Curator the allocation belongs to (the signer, or the caller of the module's direct path).
    /// @param generation Curator generation the instruction was authorized under.
    /// @return allocationId Id of the new allocation. The swapper passes it to the hook as hookData.
    function reserveFor(AllocationRequest calldata req, address curator, uint32 generation)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 allocationId)
    {
        if (msg.sender != authModule) revert NotAuthModule(msg.sender);
        CuratorRecord memory record = _curators[curator];
        if (record.restriction != CuratorRestriction.None) revert CuratorRestricted(curator, record.restriction);
        if (!record.registered) revert CuratorNotRegistered(curator);
        if (generation != record.generation) revert StaleGeneration(curator, generation, record.generation);
        if (req.deadline < block.timestamp) revert InstructionExpired(req.deadline);
        // Fields of `req` used more than once are copied to locals where they are first read. Every calldata read
        // of a struct field also re-checks that the value fits its type, so reading each field once keeps the code
        // smaller; the checks and their order are the same.
        address consumer = req.consumer;
        if (!isConsumer[consumer]) revert ConsumerNotRegistered(consumer);
        if (address(req.key.hooks) != consumer) revert ConsumerMismatch(consumer, address(req.key.hooks));
        if (!(req.key.currency0 == asset0) || !(req.key.currency1 == asset1)) revert UnsupportedPair();

        // The key's currencies are the pair (checked above), so this also checks that currencyOut is one of them.
        Currency out = req.currencyOut;
        Currency currencyIn = _otherAsset(out);

        // The direction must be configured and not halted, and the curator floor may only be at least as strict as
        // the vault floor. Zero curator floors are therefore always rejected (vault floor >= 1).
        uint160 vaultFloor = _vaultFloor(out);
        uint160 curatorFloor = req.minInPerOutX96;
        if (curatorFloor < vaultFloor) revert FloorBelowVaultMinimum(curatorFloor, vaultFloor);

        uint128 maxOut = req.maxOut;
        if (maxOut == 0) revert ZeroAmount();
        if (maxOut > MAX_AMOUNT) revert AmountTooLarge();
        uint64 expiry = req.expiry;
        if (expiry <= block.timestamp) revert InvalidExpiry();
        if (expiry > block.timestamp + MAX_HORIZON) {
            revert HorizonExceeded(expiry, block.timestamp + MAX_HORIZON);
        }

        uint256 curatorAvailable = _sub0(curatorCeiling[curator][out], curatorReserved[curator][out]);
        if (maxOut > curatorAvailable) revert CuratorCeilingExceeded(maxOut, curatorAvailable);

        uint256 eligible = _eligibleBacking(out);
        uint256 admissible = _admissible(out, eligible);
        if (maxOut > admissible) revert InsufficientBacking(maxOut, admissible);
        _checkExposure(RiskScope.Hook, consumer, out, hookReserved[consumer][out], maxOut, eligible);
        _checkExposure(RiskScope.Curator, curator, out, curatorReserved[curator][out], maxOut, eligible);
        _checkExposure(RiskScope.Vault, address(0), out, reserved[out], maxOut, eligible);

        reserved[out] += maxOut;
        curatorReserved[curator][out] += maxOut;
        hookReserved[consumer][out] += maxOut;

        allocationId = nextAllocationId++;
        PoolId poolId = req.key.toId();
        _allocations[allocationId] = Allocation({
            curator: curator,
            consumer: consumer,
            expiry: expiry,
            released: false,
            poolId: poolId,
            currencyIn: currencyIn,
            currencyOut: out,
            maxOut: maxOut,
            consumed: 0,
            minInPerOutX96: curatorFloor
        });

        emit AllocationCreated(allocationId, curator, consumer, poolId, out, maxOut, expiry, req.nonce);
    }

    /// @notice Install, replace or disable the authorization module, the only caller `reserveFor` accepts.
    /// @dev Owner: may install a module that was never installed before (replacing the current one) or set zero.
    ///      Guardian: may only set zero, which stops every new allocation through the module in this transaction.
    ///      Nobody else. The module being replaced, if any, is retired for good: it can never be installed again
    ///      (`AuthModuleRetired`). That is what keeps an old module's unused signatures and nonce state from ever
    ///      regaining authority, whether the module was replaced or disabled. Installing the module that is already
    ///      installed also reverts with `AuthModuleRetired`, because installing retires the current module first.
    ///      Resuming after a disable therefore means deploying a new module; to stop new allocations temporarily
    ///      instead, lower the vault-scope exposure caps (`setRiskLimit`), deregister curators or pause.
    ///
    ///      Installation check. A non-zero `module` must answer `vault()` with exactly this vault's address, or the
    ///      call reverts with `InvalidAuthModule`. The vault reads it with one `staticcall`, so the candidate cannot
    ///      change any state. The check fails closed when the address has no code (the call returns no data), when
    ///      the contract has no such getter or its getter reverts, when it returns fewer than 32 bytes, and when the
    ///      first returned word is not this address with clean upper bits. Only the first 32 bytes of the answer
    ///      are copied. All remaining gas is forwarded, so a candidate that burns gas makes this transaction fail.
    ///      This catches deployment mistakes such as a module built for another vault, a wrong address or an
    ///      unrelated contract. It does not prove the module is safe: a malicious contract can return this address
    ///      and do anything else. Code review, source verification and the owner's governance process are still
    ///      required; what a module can do once installed is bounded by `reserveFor`'s checks. This is the only
    ///      call from the vault to a module.
    ///
    ///      Nothing else changes: existing allocations stay consumable, cancellable and releasable; swaps, LP
    ///      deposits, redemptions, queue processing and claims never involve the module; flow usage, exposure
    ///      records and curator records are untouched. Signatures made for the old module do not verify under a new
    ///      one, because the EIP-712 domain includes the module's address. Works while paused.
    /// @param module New module, or address(0) to disable.
    function setAuthModule(address module) external {
        _authorize(module == address(0));
        if (module != address(0)) {
            bool ok;
            assembly ("memory-safe") {
                // Calldata is the 4-byte selector of `vault()` (0xfbfa77cf), stored in the last 4 bytes of the
                // scratch word at 0x00, so it starts at offset 28. The answer's first word overwrites that word.
                mstore(0x00, 0xfbfa77cf)
                let success := staticcall(gas(), module, 28, 4, 0x00, 0x20)
                // Read returndatasize and the answer only after the call: Yul evaluates arguments right to left.
                ok := and(success, and(gt(returndatasize(), 31), eq(mload(0x00), address())))
            }
            if (!ok) revert InvalidAuthModule(module);
        }
        address previous = authModule;
        if (previous != address(0)) _retiredAuthModule[previous] = true;
        if (_retiredAuthModule[module]) revert AuthModuleRetired(module);
        authModule = module;
        emit AuthModuleSet(previous, module, msg.sender);
    }

    /// @notice Close an allocation and return its unused capacity to free inventory.
    /// @dev Expiry is lazy: time passing does not change any storage. An expired allocation can no longer be
    ///      consumed, but its unused capacity stays in Q_a until someone calls this function. Who may call:
    ///        - anyone, once the allocation has expired;
    ///        - anyone, if its curator is revoked (permissionless cleanup: nobody can consume it any more);
    ///        - otherwise only the owner or the guardian, as an emergency measure, because an unexpired allocation
    ///          of a curator in good standing is a commitment to its consumer.
    ///      Works while paused and whatever the curator's state. The reason recorded in `AllocationReleased` is, in
    ///      this order of precedence: Expired, CuratorRevoked, Emergency.
    ///      Accounting is `_close`: no assets move, Q_a and the curator's reserved total fall by maxOut - consumed,
    ///      which raises F_a and can let queued redemptions progress. Capacity already consumed is never returned.
    /// @param allocationId Allocation to release. Must exist and not already be closed.
    function release(uint256 allocationId) external nonReentrant {
        Allocation storage a = _getLiveAllocation(allocationId);
        CloseReason reason;
        if (block.timestamp >= a.expiry) {
            reason = CloseReason.Expired;
        } else if (_curators[a.curator].restriction == CuratorRestriction.Revoked) {
            reason = CloseReason.CuratorRevoked;
        } else if (msg.sender == owner || msg.sender == guardian) {
            reason = CloseReason.Emergency;
        } else {
            revert AllocationNotExpired(allocationId, a.expiry);
        }
        _close(allocationId, a, reason);
    }

    /// @notice Cancel one of the caller's own allocations and return its unused capacity to free inventory.
    /// @dev Only the allocation's curator may call, in any state: registered or not, frozen or revoked, while the
    ///      vault is paused or a direction is halted, and before or after expiry. A curator can therefore always
    ///      reduce its own exposure, and nobody can cancel another curator's allocation. Cancellation is permanent:
    ///      the allocation is closed and can never be consumed or reopened, and its id is never reused.
    ///      Accounting is `_close`: only the unconsumed remainder maxOut - consumed is released; output already
    ///      consumed was exchanged for input that belongs to all shares and is not touched. No assets move.
    ///      Example: maxOut 10,000, consumed 3,500: Q_a and curatorReserved fall by 6,500 and `consumed` stays 3,500.
    /// @param allocationId Allocation to cancel. Must exist and not already be closed.
    function cancelAllocation(uint256 allocationId) external nonReentrant {
        Allocation storage a = _getLiveAllocation(allocationId);
        if (msg.sender != a.curator) revert NotAllocationCurator(allocationId, msg.sender);
        _close(allocationId, a, CloseReason.Canceled);
    }

    // ==================================================================
    // Consumption (called by a registered hook from inside beforeSwap)
    // ==================================================================

    /// @inheritdoc ISharedCommitmentVault
    /// @dev The caller must be a registered consumer and the allocation's named consumer, the allocation's curator
    ///      must be neither frozen nor revoked (its registration does not matter), and `key` must be the
    ///      allocation's pool with `key.hooks` equal to the caller. The trade must be in the allocation's direction,
    ///      before its expiry, within its remaining capacity, and at or above the effective price floor:
    ///
    ///          amountIn * 2^96 >= amountOut * max(live vault floor, allocation's curator floor)
    ///
    ///      checked as amountIn >= ceil(amountOut * floor / 2^96). Rounding up makes the integer comparison
    ///      equivalent to the exact rational one. Example: with a floor of 1.5 * 2^96, an output of 1,001 raw units
    ///      requires ceil(1,501.5) = 1,502 raw units of input. The amounts checked are exactly the claim amounts
    ///      transferred below, so the price is enforced on what actually moves, not on a hook's quote.
    ///
    ///      Accounting. On the output side, `consumed` rises by amountOut while Q_out and B_out both fall by it, so
    ///      free inventory F_out is unchanged. On the input side B_in rises by amountIn, raising N_in and F_in.
    ///      Shares, W_a and the queue are not touched; the trade's gain or loss reaches every outstanding share,
    ///      including queued ones, through N_a / S.
    ///
    ///      Settlement. The caller must already hold `amountIn` input claims (normally minted moments earlier in
    ///      `beforeSwap`) and must have made this vault its ERC-6909 operator. The vault pulls the input claims first
    ///      and then sends the output claims. If the hook has not funded the input, the pull underflows and the whole
    ///      transaction reverts, so output can never leave without input arriving. The vault holds no operator rights
    ///      over anyone else's claims and grants none over its own.
    ///
    ///      Flow limits. `amountOut`, the exact output transferred below, is added to the current-window usage of
    ///      three records of `currencyOut`: the calling hook's, the allocation curator's and the vault's. The call
    ///      reverts with `FlowLimitExceeded` if any of them would exceed its cap, and with `RiskLimitNotConfigured` if
    ///      any is unconfigured. The vault computes the usage itself from the amount it pays; nothing a hook reports
    ///      is trusted. Usage is gross: the input received is never subtracted, so trading back and forth cannot
    ///      free capacity. A revert anywhere in the swap rolls all three records back with everything else.
    ///
    ///      A floor only guarantees that trades are no worse than the configured minimum. It does not guarantee
    ///      the trade happened at a fair market price; a registered hook can sell the full remaining quota at
    ///      exactly the floor.
    function exchange(PoolKey calldata key, bool zeroForOne, uint256 allocationId, uint256 amountIn, uint256 amountOut)
        external
        nonReentrant
        whenNotPaused
    {
        if (!isConsumer[msg.sender]) revert ConsumerNotRegistered(msg.sender);

        Allocation storage a = _getLiveAllocation(allocationId);
        if (a.consumer != msg.sender) revert ConsumerMismatch(a.consumer, msg.sender);
        // A frozen or revoked curator's allocations stop here, in the same block as the freeze or revocation.
        address curator = a.curator;
        CuratorRestriction restriction = _curators[curator].restriction;
        if (restriction != CuratorRestriction.None) revert CuratorRestricted(curator, restriction);
        if (address(key.hooks) != msg.sender) revert ConsumerMismatch(msg.sender, address(key.hooks));
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(a.poolId)) revert PoolMismatch();
        if (block.timestamp >= a.expiry) revert AllocationExpired(allocationId, a.expiry);
        if (!((zeroForOne ? key.currency1 : key.currency0) == a.currencyOut)) revert DirectionMismatch();

        if (amountIn == 0 || amountOut == 0) revert ZeroAmount();
        if (amountIn > MAX_AMOUNT || amountOut > MAX_AMOUNT) revert AmountTooLarge();

        uint256 remaining = a.maxOut - a.consumed;
        if (amountOut > remaining) revert QuotaExceeded(amountOut, remaining);

        Currency cin = a.currencyIn;
        Currency cout = a.currencyOut;

        // Execution price on the exact claim amounts moved below (ERC-6909 transfers are exact):
        // amountIn * 2^96 >= amountOut * max(f_v live now, f_c). amountOut < 2^127 and F < 2^160, so FullMath's
        // 512-bit product cannot overflow and the result (< 2^191) fits; ceil makes the comparison exact.
        // _effectiveFloor also reverts if this direction is unconfigured or halted.
        uint256 requiredIn = FullMath.mulDivRoundingUp(amountOut, _effectiveFloor(a), FixedPoint96.Q96);
        if (amountIn < requiredIn) revert PriceBelowFloor(amountIn, requiredIn);

        uint256 backingIn = backing[cin];
        if (amountIn > MAX_AMOUNT - backingIn) revert AmountTooLarge();

        // Flow limits, before any other effect. Each call checks and records in one step.
        uint256 epoch = _flowEpoch();
        _consumeFlow(RiskScope.Hook, msg.sender, cout, amountOut, epoch);
        _consumeFlow(RiskScope.Curator, curator, cout, amountOut, epoch);
        _consumeFlow(RiskScope.Vault, address(0), cout, amountOut, epoch);

        // Effects. amountOut <= remaining <= reserved[out] <= backing[out] - claimable[out], so no underflow
        // and claimable redemption assets are never paid to a hook. hookReserved and curatorReserved hold this
        // allocation's remaining capacity, so they cannot underflow either.
        // forge-lint: disable-next-line(unsafe-typecast) amountOut <= remaining <= maxOut (a uint128).
        a.consumed += uint128(amountOut);
        reserved[cout] -= amountOut;
        curatorReserved[curator][cout] -= amountOut;
        hookReserved[msg.sender][cout] -= amountOut;
        backing[cout] -= amountOut;
        backing[cin] = backingIn + amountIn;

        // Interactions: pull input first, then push exactly the authorised output.
        poolManager.transferFrom(msg.sender, address(this), cin.toId(), amountIn);
        poolManager.transfer(msg.sender, cout.toId(), amountOut);

        emit AllocationConsumed(allocationId, msg.sender, amountIn, amountOut, a.consumed);
    }

    // ==================================================================
    // Views. Derived values and previews are in VaultLens (see the contract documentation).
    // ==================================================================

    /// @notice Stored state of an allocation. Returns an all-zero struct for an unknown id.
    /// @param allocationId Allocation to read.
    /// @return The allocation record.
    function getAllocation(uint256 allocationId) external view returns (Allocation memory) {
        return _allocations[allocationId];
    }

    /// @notice Stored record of a curator. All-zero for an address that was never touched.
    /// @param curator Curator to read.
    /// @return The curator record.
    function getCurator(address curator) external view returns (CuratorRecord memory) {
        return _curators[curator];
    }

    /// @notice Stored risk limits and flow usage of one scope in one asset. All-zero if never configured.
    /// @dev `flowUsed` belongs to window `epoch`; it is current usage only while `epoch` equals
    ///      block.timestamp / FLOW_WINDOW. `VaultLens.flowAvailable` applies that rule.
    /// @param scope Hook, Curator or Vault.
    /// @param account The hook or curator; address(0) for the vault scope.
    /// @param currency Asset the limit applies to.
    /// @return The stored record.
    function getRiskLimit(RiskScope scope, address account, Currency currency)
        external
        view
        returns (RiskLimit memory)
    {
        return _riskLimit(scope, account, currency);
    }

    /// @notice Stored state of a withdrawal request. Returns an all-zero struct for an unknown id.
    /// @param requestId Request to read.
    /// @return The request record.
    function getRequest(uint256 requestId) external view returns (WithdrawalRequest memory) {
        return _requests[requestId];
    }

    /// @notice Largest new allocation of `currency` the admission rule accepts right now: N_a - Q_a - R_a - D_a,
    ///         or 0 if that is negative.
    /// @dev Example: N_a = 1,000, Q_a = 300, R_a = 100 and D_a = 150 give 450. This does not include the curator's
    ///      own ceiling or the exposure caps, which `reserveFor` checks separately.
    ///
    ///      Computed as max(0, max(0, E_a - Q_a) - R_a) with E_a = N_a - D_a (exact, since D_a <= N_a), the same
    ///      E_a the exposure caps use. Each term is subtracted in turn with a floor at zero instead of summing
    ///      Q_a + R_a + D_a first. R_a is an admin input with no upper bound (the guardian may raise it to
    ///      type(uint256).max to stop new allocations in this asset), so the sum could overflow and revert with a
    ///      panic. Because every term is non-negative, the floored chain equals max(0, N - D - Q - R) exactly: once an
    ///      intermediate result reaches zero, the exact value is already <= 0. The result is therefore unchanged
    ///      wherever the sum did not overflow, and is 0 (so `reserveFor` reverts with `InsufficientBacking`) wherever
    ///      it did.
    /// @param currency Asset the allocation would sell.
    /// @return Raw units of `currency`.
    function admissibleCapacity(Currency currency) external view returns (uint256) {
        return _admissible(currency, _eligibleBacking(currency));
    }

    // ==================================================================
    // Internal
    // ==================================================================

    /// @dev N_a = B_a - W_a: assets owned by outstanding shares, i.e. backing minus assets already owed to finalized
    ///      requests. Committed capacity Q_a is included, because it still belongs to the shareholders. Cannot
    ///      underflow: every path keeps W_a <= B_a. Returns 0 for a currency outside the pair.
    function _netAssets(Currency currency) internal view returns (uint256) {
        return backing[currency] - claimableAssets[currency];
    }

    /// @dev E_a = N_a - D_a: net assets minus the queue's pro-rata claim, the backing new allocations may be measured
    ///      against. D_a <= N_a because P <= S, so this cannot underflow.
    function _eligibleBacking(Currency currency) internal view returns (uint256) {
        return _netAssets(currency) - _pendingDemand(currency);
    }

    /// @dev Admission limit max(0, E_a - Q_a - R_a), with each term subtracted in turn and floored at zero (see
    ///      `admissibleCapacity` for why that equals max(0, N_a - Q_a - R_a - D_a) and never overflows).
    function _admissible(Currency currency, uint256 eligible) internal view returns (uint256) {
        return _sub0(_sub0(eligible, reserved[currency]), bufferFloor[currency]);
    }

    /// @dev D_a = ceil(P * N_a / S): what the pending queue would be owed in `currency` if it were finalized now.
    ///      Rounded up so that capacity protected for the queue is never less than its exact pro-rata share.
    ///      Example: P = 300, S = 1,000 and N_a = 1,001 give ceil(300.3) = 301. The value moves with N_a, so trades
    ///      change it. It protects the queue's capacity, not the value it will receive: queued shares still share
    ///      losses. P > 0 implies S >= P > 0, so the division is safe. Returns 0 when nothing is pending.
    function _pendingDemand(Currency currency) internal view returns (uint256) {
        uint256 p = pendingShares;
        if (p == 0) return 0;
        return FullMath.mulDivRoundingUp(p, _netAssets(currency), totalShares);
    }

    /// @dev Deposit price for `shares`: ceil(shares * N_a / supply) of each asset. FullMath keeps the intermediate
    ///      product in 512 bits, so no overflow is possible for amounts within MAX_AMOUNT. Reverts with `NoAssets` if
    ///      both N_a are zero; this state cannot be reached while shares exist (a trade can empty at most one asset,
    ///      and the locked MIN_SHARES stop redemptions from emptying either), so the check is defensive.
    ///      `VaultLens.previewDeposit` repeats this formula for callers choosing `maxAmount0/1`.
    function _depositAmounts(uint256 shares, uint256 supply) internal view returns (uint256 amount0, uint256 amount1) {
        uint256 n0 = _netAssets(asset0);
        uint256 n1 = _netAssets(asset1);
        if (n0 == 0 && n1 == 0) revert NoAssets();
        amount0 = FullMath.mulDivRoundingUp(shares, n0, supply);
        amount1 = FullMath.mulDivRoundingUp(shares, n1, supply);
    }

    /// @dev Redemption value of `shares`: floor(shares * N_a / supply) of each asset. Used for instant redemptions
    ///      and queue finalization; `VaultLens.previewRedeem` repeats it. Rounding down means the redeemer, not the
    ///      remaining holders, absorbs the fraction, so N_a / S never falls when shares leave.
    function _entitlement(uint256 shares, uint256 supply) internal view returns (uint256 amount0, uint256 amount1) {
        amount0 = FullMath.mulDiv(shares, _netAssets(asset0), supply);
        amount1 = FullMath.mulDiv(shares, _netAssets(asset1), supply);
    }

    /// @dev Largest s such that floor(s * N_a / S) <= F_a for both assets, i.e. min over a of floor(F_a * S / N_a),
    ///      where F_a = N_a - Q_a. An in-kind exit needs both assets, so the scarcer one sets the limit. Example:
    ///      S = 2,000, N0 = 1,000 with Q0 = 400 (F0 = 600), and N1 = 500 with Q1 = 0 (F1 = 500): asset0 allows
    ///      floor(600 * 2,000 / 1,000) = 1,200 shares, asset1 allows 2,000, so the result is 1,200. An asset with
    ///      N_a = 0 places no limit (its basket share is zero anyway). If both are zero the result is
    ///      type(uint256).max, which callers then cap by the shares actually requested.
    function _deliverableShares(uint256 supply) internal view returns (uint256 cap) {
        cap = type(uint256).max;
        uint256 n0 = _netAssets(asset0);
        if (n0 != 0) cap = FullMath.mulDiv(n0 - reserved[asset0], supply, n0);
        uint256 n1 = _netAssets(asset1);
        if (n1 != 0) {
            uint256 c1 = FullMath.mulDiv(n1 - reserved[asset1], supply, n1);
            if (c1 < cap) cap = c1;
        }
    }

    /// @dev Enters the PoolManager's unlock. The PoolManager calls back `unlockCallback` on this contract with the
    ///      same data, and reverts the whole transaction if the vault's deltas are not zero when it returns.
    function _unlock(CallbackAction action, address account, uint256 amount0, uint256 amount1) internal {
        poolManager.unlock(abi.encode(action, account, amount0, amount1));
    }

    /// @dev Moves `amount` of ERC-20 from `payer` into the PoolManager and mints the same amount of claims to the
    ///      vault. sync -> transfer -> settle credits +amount to the vault's delta; mint debits -amount. Net delta: 0.
    ///      `settle` reports what actually arrived; anything other than `amount` (for example a fee-on-transfer
    ///      token) reverts so that B_a never exceeds the ERC-20 the PoolManager really received.
    function _settleIn(Currency currency, address payer, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.sync(currency);
        SafeTransferLib.safeTransferFrom(ERC20(Currency.unwrap(currency)), payer, address(poolManager), amount);
        uint256 paid = poolManager.settle();
        if (paid != amount) revert SettlementMismatch(amount, paid); // fee-on-transfer etc. fail closed
        poolManager.mint(address(this), currency.toId(), amount);
    }

    /// @dev Burns `amount` of the vault's claims and sends the same amount of ERC-20 to `to`.
    ///      burn credits +amount to the vault's delta; take debits -amount and transfers ERC-20 out. Net delta: 0.
    function _payOut(Currency currency, address to, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, to, amount);
    }

    /// @dev The one place an allocation is closed; used by `release` (expiry, emergency, revoked-curator cleanup)
    ///      and `cancelAllocation`. Precondition: `a` was loaded with `_getLiveAllocation`, which reverts for an
    ///      unknown or already closed id, so each allocation passes through here at most once.
    ///
    ///      Effects, in one step: `released` is set, then Q_out, curatorReserved[curator][out] and
    ///      hookReserved[consumer][out] all fall by unused = maxOut - consumed. These are exactly this allocation's
    ///      contribution to the three sums (each is maintained as the sum of maxOut - consumed over unreleased
    ///      allocations), so none can underflow and no other allocation's share is touched. `consumed` is not
    ///      changed, no claims, B_a, W_a, shares or queue entries move, and no flow usage is returned: closing
    ///      releases capacity that was never paid out, while output already paid stays counted in its window.
    function _close(uint256 allocationId, Allocation storage a, CloseReason reason) internal {
        uint256 unused = a.maxOut - a.consumed;
        a.released = true;
        Currency out = a.currencyOut;
        reserved[out] -= unused;
        curatorReserved[a.curator][out] -= unused;
        hookReserved[a.consumer][out] -= unused;
        emit AllocationReleased(allocationId, msg.sender, unused, reason);
    }

    /// @dev Loads an allocation that exists and has not been released. Expiry is checked by the caller where it
    ///      matters, because `release` must accept expired allocations and `exchange` must reject them.
    function _getLiveAllocation(uint256 allocationId) internal view returns (Allocation storage a) {
        a = _allocations[allocationId];
        if (a.consumer == address(0)) revert UnknownAllocation(allocationId);
        if (a.released) revert AllocationAlreadyReleased(allocationId);
    }

    /// @dev Live vault floor of the direction selling `currencyOut`; reverts unless configured and not halted.
    ///      A floor of zero means the direction was never opened, so it fails closed rather than allowing any price.
    function _vaultFloor(Currency currencyOut) internal view returns (uint160 floor) {
        SellPolicy memory policy = sellPolicy[currencyOut];
        floor = policy.minInPerOutX96;
        if (floor == 0) revert PriceFloorNotConfigured(currencyOut);
        if (policy.halted) revert DirectionHalted(currencyOut);
    }

    /// @dev max(live vault floor, allocation's curator floor). The vault floor is read on every call, so a change by
    ///      the owner or guardian applies to existing allocations immediately. Taking the max means lowering the
    ///      vault floor can never weaken the floor a curator chose.
    function _effectiveFloor(Allocation storage a) internal view returns (uint256) {
        uint160 vaultFloor = _vaultFloor(a.currencyOut);
        uint160 curatorFloor = a.minInPerOutX96;
        return curatorFloor > vaultFloor ? curatorFloor : vaultFloor;
    }

    /// @dev Returns the other asset of the pair. Reverts with `InvalidCurrency` if `currency` is not in the pair,
    ///      which is also how the policy setters validate their argument.
    function _otherAsset(Currency currency) internal view returns (Currency) {
        if (currency == asset0) return asset1;
        if (currency == asset1) return asset0;
        revert InvalidCurrency();
    }

    /// @dev Single authorization rule for every configuration setter.
    ///      Owner: always allowed. Guardian: allowed only when the caller-supplied `riskReducing` is true;
    ///      otherwise `GuardianCannotIncreaseRisk`. Anyone else: `NotOwner`. Each setter computes `riskReducing`
    ///      from its own arguments (for example "new ceiling <= old ceiling"), so the guardian can tighten but never
    ///      loosen. msg.sender is never address(0), so an unset guardian authorizes nobody.
    function _authorize(bool riskReducing) internal view {
        if (msg.sender == owner) return;
        if (msg.sender == guardian) {
            if (riskReducing) return;
            revert GuardianCannotIncreaseRisk();
        }
        revert NotOwner();
    }

    /// @dev Takes the reentrancy lock, or reverts with `ReentrantCall` if it is already held in this transaction.
    function _enterLock() internal {
        bytes32 slot = _REENTRANCY_LOCK_SLOT;
        bool locked;
        assembly ("memory-safe") {
            locked := tload(slot)
        }
        if (locked) revert ReentrantCall();
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
    }

    /// @dev Releases the reentrancy lock so that a later call in the same transaction (for example a second swap in
    ///      one PoolManager unlock) can enter again.
    function _exitLock() internal {
        bytes32 slot = _REENTRANCY_LOCK_SLOT;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    /// @dev Stores a curator record and emits it in full. Every change to a curator goes through here.
    function _writeCurator(address curator, CuratorRecord memory r) internal {
        _curators[curator] = r;
        emit CuratorUpdated(curator, r.registered, r.restriction, r.generation, msg.sender);
    }

    /// @dev generation + 1, or `GenerationExhausted` at type(uint32).max. Never wraps to 0, so a generation value is
    ///      never used twice for the same curator. Reaching the maximum takes 2^32 - 1 increments, each a separate
    ///      call by the owner, the guardian or the curator itself.
    function _nextGeneration(address curator, uint32 generation) internal pure returns (uint32) {
        if (generation == type(uint32).max) revert GenerationExhausted(curator);
        return generation + 1;
    }

    /// @dev Storage record of one scope in one asset. The key hashes all three inputs, so records of different scopes,
    ///      accounts or assets never share a slot.
    function _riskLimit(RiskScope scope, address account, Currency currency) internal view returns (RiskLimit storage) {
        return _riskLimits[keccak256(abi.encode(scope, account, currency))];
    }

    /// @dev Current flow window: floor(block.timestamp / FLOW_WINDOW), full 256-bit timestamp, no truncation. The
    ///      result is stored in 40 bits; once it no longer fits (around year 3 billion at a one-day window) every
    ///      flow-limited consumption reverts with `FlowEpochOutOfRange` instead of wrapping to an old window, which
    ///      could otherwise look like an unused window.
    function _flowEpoch() internal view returns (uint256 epoch) {
        epoch = block.timestamp / FLOW_WINDOW;
        if (epoch > type(uint40).max) revert FlowEpochOutOfRange(epoch);
    }

    /// @dev Adds `amount` to the gross outflow of one scope in window `epoch`, or reverts.
    ///      used = (stored epoch == epoch) ? flowUsed : 0. A stored epoch below the current one is a finished window,
    ///      however many windows were skipped, so the usage restarts from zero in O(1); nothing iterates over the
    ///      skipped windows. The check is used + amount <= flowCap, computed in 256 bits (used < 2^104 and
    ///      amount < 2^127, so no overflow), and the new usage is then at most flowCap < 2^104, so the narrowing
    ///      store is exact. If the cap was lowered below `used`, the available amount is zero. Reverts with
    ///      `RiskLimitNotConfigured` for an unconfigured record (fail closed).
    function _consumeFlow(RiskScope scope, address account, Currency currency, uint256 amount, uint256 epoch) internal {
        RiskLimit storage l = _riskLimit(scope, account, currency);
        if (!l.configured) revert RiskLimitNotConfigured(scope, account, currency);
        uint256 used = l.epoch == epoch ? l.flowUsed : 0;
        uint256 cap = l.flowCap;
        if (used + amount > cap) revert FlowLimitExceeded(scope, account, currency, amount, _sub0(cap, used));
        // forge-lint: disable-next-line(unsafe-typecast) epoch <= type(uint40).max (`_flowEpoch`).
        l.epoch = uint40(epoch);
        // forge-lint: disable-next-line(unsafe-typecast) used + amount <= cap <= type(uint104).max.
        l.flowUsed = uint104(used + amount);
    }

    /// @dev Exposure cap of one scope for a new allocation of `amount`: reverts unless the record is configured and
    ///      (held + amount) * 10,000 <= maxReservedBps * eligible (see `reserveFor`). held + amount < 2^128 because
    ///      both are bounded by MAX_AMOUNT, and maxReservedBps * eligible <= 10,000 * 2^127, so neither product can
    ///      overflow. The reported `available` is floor(bps * eligible / 10,000) - held, floored at zero.
    function _checkExposure(
        RiskScope scope,
        address account,
        Currency currency,
        uint256 held,
        uint256 amount,
        uint256 eligible
    ) internal view {
        RiskLimit storage l = _riskLimit(scope, account, currency);
        if (!l.configured) revert RiskLimitNotConfigured(scope, account, currency);
        uint256 limit = l.maxReservedBps * eligible;
        if ((held + amount) * _BPS > limit) {
            revert ExposureCapExceeded(scope, account, currency, amount, _sub0(limit / _BPS, held));
        }
    }

    /// @dev a - b, or 0 if b > a.
    function _sub0(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }
}
