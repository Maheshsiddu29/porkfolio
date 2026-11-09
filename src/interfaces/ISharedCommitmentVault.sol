// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title ISharedCommitmentVault
/// @notice Types, errors, events and the hook-facing entry point of the shared two-asset reserve.
/// @dev Registered hooks consume capacity that curators reserved for them through `exchange`, a claim-for-claim swap
///      with the vault inside the PoolManager. LPs own proportional, in-kind shares of the reserve and exit through
///      an instant tier or a FIFO queue. Amounts are always raw token units (no decimal normalization). Prices are
///      Q64.96 fixed point: (raw input units per raw output unit) * 2^96.
interface ISharedCommitmentVault {
    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    /// @notice A curator's instruction to reserve vault capacity for one consumer hook on one pool, as the
    ///         authorization module passes it to `reserveFor`.
    /// @dev The module builds it from a signed `AllocationAuthorization`, or takes it from the curator's own call.
    ///      The vault checks every field itself; it does not rely on the module having checked them.
    /// @param consumer        Registered hook allowed to consume this allocation. Must equal `key.hooks`.
    /// @param key             Pool the allocation is bound to. Its currencies must be the vault's pair, in order.
    /// @param currencyOut     Currency the vault pays out (key.currency0 or key.currency1). Fixes the direction.
    /// @param maxOut          Most output, in raw units of `currencyOut`, the hook may take over the allocation's life.
    /// @param minInPerOutX96  Curator's minimum price, Q64.96 raw input per raw output. Must be at least the vault's
    ///                        floor for this direction. Trades need amountIn >= ceil(amountOut * floor / 2^96).
    /// @param expiry          Unix time at which the allocation stops being consumable (consumable while
    ///                        block.timestamp < expiry). At most MAX_HORIZON after creation.
    /// @param nonce           Curator-scoped single-use value, consumed by the authorization module (signed and
    ///                        direct instructions share one bitmap per curator). The vault only reports it in
    ///                        `AllocationCreated`.
    /// @param deadline        Last Unix time (inclusive) at which the instruction may be submitted.
    struct AllocationRequest {
        address consumer;
        PoolKey key;
        Currency currencyOut;
        uint128 maxOut;
        uint160 minInPerOutX96;
        uint64 expiry;
        uint256 nonce;
        uint64 deadline;
    }

    /// @notice Stored allocation state.
    /// @param curator        Curator that created the allocation; its reserved total tracks this allocation.
    /// @param consumer       The only hook that may consume it. Zero means the id does not exist.
    /// @param expiry         Consumable while block.timestamp < expiry; releasable by anyone from then on.
    /// @param released       Set when the allocation is closed (`release` or `cancelAllocation`). Never cleared: a
    ///                       closed allocation can never be consumed, released or canceled again.
    /// @param poolId         Pool the hook must be swapping on.
    /// @param currencyIn     Currency the vault receives.
    /// @param currencyOut    Currency the vault pays out.
    /// @param maxOut         Total capacity, raw units of `currencyOut`.
    /// @param consumed       Output already taken. Unused capacity is maxOut - consumed while not released.
    /// @param minInPerOutX96 Curator floor, Q64.96. The applied floor is max(this, live vault floor).
    struct Allocation {
        address curator;
        address consumer;
        uint64 expiry;
        bool released;
        PoolId poolId;
        Currency currencyIn;
        Currency currencyOut;
        uint128 maxOut;
        uint128 consumed;
        uint160 minInPerOutX96;
    }

    /// @notice Vault-controlled price policy for one direction, keyed by the currency the vault sells.
    /// @param minInPerOutX96 Vault floor: minimum raw input per raw output, Q64.96. Zero means the direction was
    ///                       never configured and is closed. The owner may raise or lower it, the guardian may only
    ///                       raise it, and nobody can set it back to zero.
    /// @param halted         Emergency stop for this direction: blocks new allocations and all consumption.
    struct SellPolicy {
        uint160 minInPerOutX96;
        bool halted;
    }

    /// @notice A queued redemption.
    /// @dev `sharesPending` shares are escrowed: they left the LP's balance but still count in total supply, so they
    ///      keep sharing gains and losses. Finalization converts them, possibly in several slices, into fixed
    ///      `claimable0/1` amounts that no longer change.
    /// @param lp              Account that queued the request. Only it may cancel or claim.
    /// @param canceled        Set once the LP cancels. Finalized amounts stay claimable after cancellation.
    /// @param receiver        Address the claimed assets are sent to.
    /// @param sharesRequested Shares originally queued (never changes).
    /// @param sharesPending   Shares not yet finalized or canceled.
    /// @param claimable0      Finalized asset0 not yet claimed.
    /// @param claimable1      Finalized asset1 not yet claimed.
    struct WithdrawalRequest {
        address lp;
        bool canceled;
        address receiver;
        uint128 sharesRequested;
        uint128 sharesPending;
        uint128 claimable0;
        uint128 claimable1;
    }

    /// @notice None: no such request. Pending: some shares not yet finalized (some may already be claimable).
    ///         Claimable: nothing pending, assets unclaimed. Completed: fully finalized and claimed.
    ///         Canceled: canceled and nothing left to claim.
    enum RequestStatus {
        None,
        Pending,
        Claimable,
        Completed,
        Canceled
    }

    /// @notice Emergency restriction on a curator's execution authority. It is separate from registration, which
    ///         only controls whether the curator may create new allocations.
    /// @dev None: no restriction; the curator's live allocations can be consumed. Frozen: temporary; nothing the
    ///      curator created can be consumed and it cannot create anything, but its reservations stay in place. Only
    ///      the owner can lift a freeze. Revoked: permanent; like Frozen, but it can never be lifted, and anyone may
    ///      release the curator's allocations.
    enum CuratorRestriction {
        None,
        Frozen,
        Revoked
    }

    /// @notice Why an allocation was closed, as reported in `AllocationReleased`. Every reason goes through the same
    ///         accounting: the allocation is marked released and its unused capacity leaves Q_a.
    /// @dev Expired: closed after its expiry (anyone). Emergency: closed early by the owner or guardian. Canceled:
    ///      closed by its own curator. CuratorRevoked: closed early by anyone because its curator is revoked.
    enum CloseReason {
        Expired,
        Emergency,
        Canceled,
        CuratorRevoked
    }

    /// @notice A curator's stored state. All three fields share one storage slot.
    /// @dev The four states the vault distinguishes:
    ///        Active        registered, restriction None      creates allocations; its allocations are consumable
    ///        Deregistered  not registered, restriction None  creates nothing; existing allocations stay consumable
    ///        Frozen        restriction Frozen (either registration value)  creates nothing; nothing consumable
    ///        Revoked       restriction Revoked, never registered again     creates nothing; nothing consumable, ever
    ///      Registration and restriction are independent, so deregistering a frozen curator keeps it frozen, and
    ///      re-registering a frozen curator does not lift the freeze.
    /// @param registered  True if the owner registered the curator and it has not been deregistered since.
    /// @param restriction Emergency restriction on execution; see `CuratorRestriction`.
    /// @param generation  Counter for curator instructions that have not been turned into allocations yet. It
    ///                    rises by one on every deregistration, on every unfreeze and when the curator calls
    ///                    `bumpGeneration`, and never falls. An instruction tagged with an older generation is no
    ///                    longer valid: `reserveFor` rejects any request whose generation is not the current
    ///                    one. It never wraps; at type(uint32).max every increment reverts (`GenerationExhausted`).
    struct CuratorRecord {
        bool registered;
        CuratorRestriction restriction;
        uint32 generation;
    }

    /// @notice Level at which a risk limit applies. Every limit is kept per asset sold (`currencyOut`).
    /// @dev Hook: one consumer hook, across all its pools, allocations and curators; keyed by the hook address.
    ///      Curator: one curator, across all its allocations and hooks; keyed by the curator address.
    ///      Vault: everything, across all curators and hooks; keyed by address(0).
    enum RiskScope {
        Hook,
        Curator,
        Vault
    }

    /// @notice Risk limits and gross-outflow usage of one scope in one asset.
    /// @dev Two storage slots. The first (configured, epoch, flowCap, flowUsed) is the only one `exchange` reads and
    ///      writes; the second (maxReservedBps) is read only by `reserveFor`.
    ///
    ///      Flow window. Time is divided into fixed epochs of FLOW_WINDOW seconds: epoch e covers the timestamps
    ///      [e * FLOW_WINDOW, (e + 1) * FLOW_WINDOW - 1], both ends inclusive. `flowUsed` is the gross output paid
    ///      under this scope during epoch `epoch`. When the current epoch is later than `epoch`, the stored usage
    ///      belongs to a finished window and counts as zero; the next consumption starts the new window at its own
    ///      amount. Usage never decreases inside an epoch: no inflow, cancellation, release, expiry, configuration
    ///      change, curator or hook state change, or LP operation lowers it.
    /// @param configured     True once the owner has set this record. An unconfigured record fails closed: no new
    ///                       allocation for it and no consumption under it. Never cleared.
    /// @param epoch          Index (block.timestamp / FLOW_WINDOW) of the window `flowUsed` belongs to. 40 bits:
    ///                       enough for about three billion years at a one-day window.
    /// @param flowCap        Most gross output, in raw units of the asset, per epoch. Zero allows no output.
    /// @param flowUsed       Gross output already paid in epoch `epoch`, raw units. Normally at most `flowCap`; it
    ///                       can be above it only after the cap was lowered during the epoch.
    /// @param maxReservedBps Most unused reserved capacity this scope may hold after a new allocation, in basis
    ///                       points of the asset's eligible backing E_a (see `reserveFor`). Zero allows none.
    struct RiskLimit {
        bool configured;
        uint40 epoch;
        uint104 flowCap;
        uint104 flowUsed;
        uint16 maxReservedBps;
    }

    // ------------------------------------------------------------------
    // Errors: roles and generic input
    // ------------------------------------------------------------------

    /// @notice Caller is not the owner (also returned to callers that hold no role at all).
    error NotOwner();
    /// @notice Caller of `acceptOwnership` is not the nominated owner.
    error NotPendingOwner();
    /// @notice The guardian attempted a change that would loosen a limit or restore a capability.
    error GuardianCannotIncreaseRisk();
    /// @notice A reservation was requested for a curator that is not registered.
    error CuratorNotRegistered(address curator);
    /// @notice The curator is frozen or revoked, so it cannot create allocations and its allocations cannot be
    ///         consumed.
    error CuratorRestricted(address curator, CuratorRestriction restriction);
    /// @notice The requested curator state change is not allowed from the curator's current restriction. Examples:
    ///         freezing a curator that is already frozen or revoked, lifting a freeze that is not in place, or
    ///         registering a revoked curator.
    error InvalidCuratorTransition(address curator, CuratorRestriction restriction);
    /// @notice The curator's generation is already type(uint32).max and cannot be raised again. It never wraps.
    error GenerationExhausted(address curator);
    /// @notice `reserveFor` was called by something other than the installed authorization module.
    error NotAuthModule(address caller);
    /// @notice The instruction was authorized under a generation that is no longer the curator's current one.
    error StaleGeneration(address curator, uint32 authorizedGeneration, uint32 currentGeneration);
    /// @notice This module was installed earlier and then replaced or disabled; it can never be installed again.
    error AuthModuleRetired(address module);
    /// @notice `unlockCallback` was called by something other than the PoolManager.
    error NotPoolManager();
    /// @notice A state-changing entry point was called while another one was still executing in the same
    ///         transaction (for example from a token callback during a deposit or payout).
    error ReentrantCall();
    /// @notice A required address argument was zero.
    error ZeroAddress();
    /// @notice The vault is paused; deposits, allocations and consumption are blocked.
    error Paused();
    /// @notice The constructor was given native ETH (address zero) as asset0.
    error NativeCurrencyUnsupported();
    /// @notice An amount or share count that must be positive was zero.
    error ZeroAmount();
    /// @notice An amount, or a balance it would produce, exceeds MAX_AMOUNT (2^127 - 1).
    error AmountTooLarge();
    /// @notice The PoolManager received a different ERC-20 amount than requested during a deposit (for example a
    ///         fee-on-transfer token).
    error SettlementMismatch(uint256 expected, uint256 paid);
    /// @notice The constructor's assets are equal or not sorted (asset0 must be the lower address).
    error InvalidAssetPair();
    /// @notice An allocation's pool does not trade exactly the vault's asset pair.
    error UnsupportedPair();

    // ------------------------------------------------------------------
    // Errors: shares and redemption
    // ------------------------------------------------------------------

    /// @notice `initialDeposit` was called on a vault that already has shares.
    error AlreadyInitialized();
    /// @notice A deposit or deposit preview was attempted before `initialDeposit`.
    error NotInitialized();
    /// @notice sqrt(amount0 * amount1) is not above MIN_SHARES, so no free shares would be minted.
    error InitialDepositTooSmall(uint256 shares, uint256 minimum);
    /// @notice Both net asset balances are zero. Defensive; unreachable while shares exist.
    error NoAssets();
    /// @notice A deposit would cost more than the caller's maximum, or an instant redemption would pay less than
    ///         the caller's minimum.
    error SlippageExceeded();
    /// @notice The caller tried to redeem more free shares than it holds.
    error InsufficientShares(uint256 requested, uint256 balance);
    /// @notice Only `deliverable` of `requested` shares can be paid now and the caller chose not to queue the rest.
    error InsufficientLiquidity(uint256 requested, uint256 deliverable);
    /// @notice The shares being redeemed or queued are worth zero of both assets after rounding down.
    error DustRedemption();
    /// @notice Only the request's LP may cancel or claim it.
    error NotRequestOwner(uint256 requestId);
    /// @notice The request has no pending shares left to cancel.
    error NothingPending(uint256 requestId);
    /// @notice The request has no finalized, unclaimed assets.
    error NothingToClaim(uint256 requestId);

    // ------------------------------------------------------------------
    // Errors: allocations
    // ------------------------------------------------------------------

    /// @notice The hook is not a registered consumer.
    error ConsumerNotRegistered(address consumer);
    /// @notice The hook named by an allocation, a pool key or the caller do not all match.
    error ConsumerMismatch(address expected, address actual);
    /// @notice The allocation would take the curator's reserved total above its ceiling. `available` is what is left.
    error CuratorCeilingExceeded(uint256 requested, uint256 available);
    /// @notice A currency argument is not one of the vault's two assets.
    error InvalidCurrency();
    /// @notice The requested expiry is not in the future.
    error InvalidExpiry();
    /// @notice The requested expiry is more than MAX_HORIZON in the future.
    error HorizonExceeded(uint64 expiry, uint256 maxExpiry);
    /// @notice The instruction's deadline has passed.
    error InstructionExpired(uint64 deadline);
    /// @notice The allocation exceeds what the admission rule allows: N_a - Q_a - R_a - D_a.
    error InsufficientBacking(uint256 requested, uint256 available);

    // ------------------------------------------------------------------
    // Errors: consumption and price policy
    // ------------------------------------------------------------------

    /// @notice No allocation exists with this id.
    error UnknownAllocation(uint256 allocationId);
    /// @notice The allocation was already released and can no longer be consumed or released.
    error AllocationAlreadyReleased(uint256 allocationId);
    /// @notice The allocation's expiry has been reached; it can only be released now.
    error AllocationExpired(uint256 allocationId, uint64 expiry);
    /// @notice Before expiry, only the owner or guardian may release an allocation, unless its curator is revoked.
    error AllocationNotExpired(uint256 allocationId, uint64 expiry);
    /// @notice Only the curator that created an allocation may cancel it.
    error NotAllocationCurator(uint256 allocationId, address caller);
    /// @notice The swap's pool is not the pool the allocation is bound to.
    error PoolMismatch();
    /// @notice The swap direction would make the vault pay out the allocation's input currency.
    error DirectionMismatch();
    /// @notice The requested output exceeds the allocation's unused capacity.
    error QuotaExceeded(uint256 requested, uint256 remaining);
    /// @notice The input does not meet the effective price floor. `requiredIn` = ceil(amountOut * floor / 2^96).
    error PriceBelowFloor(uint256 amountIn, uint256 requiredIn);
    /// @notice The vault floor for selling this currency was never set, so the direction is closed.
    error PriceFloorNotConfigured(Currency currencyOut);
    /// @notice The direction that sells this currency is halted.
    error DirectionHalted(Currency currencyOut);
    /// @notice A vault floor of zero was requested. Zero is reserved for "not configured".
    error ZeroPriceFloor();
    /// @notice The curator's floor is below the live vault floor for that direction.
    error FloorBelowVaultMinimum(uint256 curatorFloor, uint256 vaultFloor);
    /// @notice The hook, curator or vault-wide risk limit for this asset was never configured, so the path fails
    ///         closed. `account` is the hook or curator, or address(0) for the vault scope.
    error RiskLimitNotConfigured(RiskScope scope, address account, Currency currency);
    /// @notice The output would take this scope's gross outflow in the current window above its cap. `available` is
    ///         what is left in this window (zero when the cap was lowered below what was already used).
    error FlowLimitExceeded(RiskScope scope, address account, Currency currency, uint256 requested, uint256 available);
    /// @notice The allocation would take this scope's unused reserved capacity above its share of eligible backing.
    ///         `available` = max(0, floor(maxReservedBps * E_a / 10,000) - held).
    error ExposureCapExceeded(
        RiskScope scope, address account, Currency currency, uint256 requested, uint256 available
    );
    /// @notice A risk-limit argument is out of range: a flow cap above 2^104 - 1, basis points above 10,000, or an
    ///         account that does not match the scope (non-zero for Vault, zero for Hook or Curator).
    error InvalidRiskLimit();
    /// @notice block.timestamp / FLOW_WINDOW no longer fits the 40-bit epoch field. Every flow-limited consumption
    ///         reverts from then on rather than wrapping to an old window.
    error FlowEpochOutOfRange(uint256 epoch);
    /// @notice The two direction floors would cross: their product would be below 2^192, which would make a round
    ///         trip at the floors profitable. `requiredMinimum` = ceil(2^192 / opposite floor).
    error InconsistentDirectionalFloors(uint256 floor, uint256 requiredMinimum);

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    /// @notice The owner nominated `newOwner` (zero cancels a nomination).
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    /// @notice Ownership changed. Also emitted by the constructor with `previousOwner` = 0.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    /// @notice The guardian was appointed, replaced or removed (`newGuardian` = 0).
    event GuardianSet(address indexed previousGuardian, address indexed newGuardian);
    /// @notice A curator's record changed: registration, restriction or generation. Carries the full new record.
    ///         `by` is the caller (owner, guardian, or the curator itself for `bumpGeneration`).
    event CuratorUpdated(
        address indexed curator, bool registered, CuratorRestriction restriction, uint32 generation, address indexed by
    );
    /// @notice The authorization module changed from `previousModule` to `newModule` (zero: none installed).
    ///         `previousModule`, if non-zero, is retired for good. `by` is the owner or guardian.
    event AuthModuleSet(address indexed previousModule, address indexed newModule, address indexed by);
    /// @notice The vault was paused or unpaused.
    event PausedSet(bool paused);
    /// @notice A consumer hook was registered or revoked.
    event ConsumerSet(address indexed consumer, bool registered);
    /// @notice A curator's per-currency ceiling changed.
    event CuratorCeilingSet(address indexed curator, Currency indexed currency, uint256 ceiling);
    /// @notice The buffer floor R_a for `currency` changed.
    event BufferFloorSet(Currency indexed currency, uint256 floor);
    /// @notice A risk limit was set. `account` is the hook or curator, or address(0) for the vault scope. Usage
    ///         already recorded in the current window is unchanged. `by` is the owner or guardian.
    event RiskLimitSet(
        RiskScope indexed scope,
        address indexed account,
        Currency indexed currency,
        uint256 flowCap,
        uint16 maxReservedBps,
        address by
    );
    /// @notice The vault floor for selling `currencyOut` changed. `by` is the owner or guardian.
    event SellFloorSet(Currency indexed currencyOut, uint160 previousFloor, uint160 newFloor, address indexed by);
    /// @notice The direction selling `currencyOut` was halted or resumed. `by` is the owner or guardian.
    event SellHaltedSet(Currency indexed currencyOut, bool halted, address indexed by);
    /// @notice `caller` paid `amount0`/`amount1` and `receiver` was credited `shares` (for the first deposit, the
    ///         shares exclude the locked MIN_SHARES).
    event Deposited(address indexed caller, address indexed receiver, uint256 shares, uint256 amount0, uint256 amount1);
    /// @notice The instant part of a redemption: `shares` were burned and the amounts sent to `receiver`.
    event Redeemed(address indexed lp, address indexed receiver, uint256 shares, uint256 amount0, uint256 amount1);
    /// @notice `shares` were escrowed in a new queue entry.
    event RedeemRequested(uint256 indexed requestId, address indexed lp, address indexed receiver, uint256 shares);
    /// @notice A slice of `shares` of a request was finalized into fixed claimable amounts.
    event RequestFinalized(uint256 indexed requestId, uint256 shares, uint256 amount0, uint256 amount1);
    /// @notice The LP canceled a request and got `sharesReturned` pending shares back.
    event RequestCanceled(uint256 indexed requestId, uint256 sharesReturned);
    /// @notice Finalized assets of a request were paid to `receiver`.
    event Claimed(uint256 indexed requestId, address indexed receiver, uint256 amount0, uint256 amount1);
    /// @notice A curator reserved capacity for a hook. `nonce` is the instruction's nonce in the authorization
    ///         module.
    event AllocationCreated(
        uint256 indexed allocationId,
        address indexed curator,
        address indexed consumer,
        PoolId poolId,
        Currency currencyOut,
        uint128 maxOut,
        uint64 expiry,
        uint256 nonce
    );
    /// @notice A hook traded against an allocation. `consumed` is the allocation's cumulative output after the trade.
    event AllocationConsumed(
        uint256 indexed allocationId, address indexed consumer, uint256 amountIn, uint256 amountOut, uint128 consumed
    );
    /// @notice An allocation was closed. `by` is the caller; `unusedCapacity` (maxOut - consumed) returned to free
    ///         inventory; `reason` says which close path was used.
    event AllocationReleased(
        uint256 indexed allocationId, address indexed by, uint256 unusedCapacity, CloseReason reason
    );

    // ------------------------------------------------------------------
    // Authorization module entry point
    // ------------------------------------------------------------------

    /// @notice Reserve capacity for `curator`, as requested by the installed authorization module.
    /// @dev Callable only by `authModule`. The module vouches that `curator` authorized `req` under `generation`;
    ///      the vault itself checks everything that decides whether capital may be reserved.
    /// @param req Allocation request.
    /// @param curator Curator the allocation belongs to.
    /// @param generation Curator generation the request was authorized under; must equal the current one.
    /// @return allocationId Id of the new allocation.
    function reserveFor(AllocationRequest calldata req, address curator, uint32 generation)
        external
        returns (uint256 allocationId);

    // ------------------------------------------------------------------
    // Consumer entry point
    // ------------------------------------------------------------------

    /// @notice Swap claims with the vault against an allocation: the vault pulls `amountIn` claims of the
    ///         allocation's input currency from the calling hook and sends it `amountOut` claims of the output
    ///         currency.
    /// @dev Called by a registered hook, normally from inside `beforeSwap`. ERC-6909 transfers are not lock-gated,
    ///      so a hook could also call it outside a swap with claims it already holds; the same checks apply. The
    ///      hook must already hold the input claims and must have made the vault its ERC-6909 operator. The call
    ///      reverts unless the allocation, pool, direction, expiry, remaining capacity and price floor all check out.
    /// @param key Pool being swapped on. `key.hooks` must be the caller and the pool must be the allocation's pool.
    /// @param zeroForOne Swap direction; must make the vault pay out the allocation's `currencyOut`.
    /// @param allocationId Allocation to consume.
    /// @param amountIn Raw input claims the vault receives.
    /// @param amountOut Raw output claims the vault sends.
    function exchange(PoolKey calldata key, bool zeroForOne, uint256 allocationId, uint256 amountIn, uint256 amountOut)
        external;

    /// @notice Stored state of an allocation; an all-zero struct if the id does not exist.
    /// @param allocationId Allocation to read.
    /// @return The allocation record.
    function getAllocation(uint256 allocationId) external view returns (Allocation memory);
}
