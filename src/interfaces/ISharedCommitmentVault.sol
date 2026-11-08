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

    /// @notice A curator's instruction to reserve vault capacity for one consumer hook on one pool.
    /// @dev Only direct submission by the curator is implemented. The struct carries a nonce and deadline so that a
    ///      signed version could reuse the same fields, but no signature verification exists.
    /// @param consumer        Registered hook allowed to consume this allocation. Must equal `key.hooks`.
    /// @param key             Pool the allocation is bound to. Its currencies must be the vault's pair, in order.
    /// @param currencyOut     Currency the vault pays out (key.currency0 or key.currency1). Fixes the direction.
    /// @param maxOut          Most output, in raw units of `currencyOut`, the hook may take over the allocation's life.
    /// @param minInPerOutX96  Curator's minimum price, Q64.96 raw input per raw output. Must be at least the vault's
    ///                        floor for this direction. Trades need amountIn >= ceil(amountOut * floor / 2^96).
    /// @param expiry          Unix time at which the allocation stops being consumable (consumable while
    ///                        block.timestamp < expiry). At most MAX_HORIZON after creation.
    /// @param nonce           Curator-scoped single-use value. Prevents the same instruction being applied twice.
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
    /// @param released       Set by `release`. A released allocation can never be consumed again.
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

    // ------------------------------------------------------------------
    // Errors: roles and generic input
    // ------------------------------------------------------------------

    /// @notice Caller is not the owner (also returned to callers that hold no role at all).
    error NotOwner();
    /// @notice Caller of `acceptOwnership` is not the nominated owner.
    error NotPendingOwner();
    /// @notice The guardian attempted a change that would loosen a limit or restore a capability.
    error GuardianCannotIncreaseRisk();
    /// @notice `allocate` was called by an address that is not a registered curator.
    error CuratorNotRegistered(address curator);
    /// @notice `unlockCallback` was called by something other than the PoolManager.
    error NotPoolManager();
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
    /// @notice The curator already used this nonce.
    error NonceAlreadyUsed(address curator, uint256 nonce);
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
    /// @notice Only the owner or guardian may release an allocation before its expiry.
    error AllocationNotExpired(uint256 allocationId, uint64 expiry);
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
    /// @notice A curator was registered or revoked.
    event CuratorSet(address indexed curator, bool registered);
    /// @notice The vault was paused or unpaused.
    event PausedSet(bool paused);
    /// @notice A consumer hook was registered or revoked.
    event ConsumerSet(address indexed consumer, bool registered);
    /// @notice A curator's per-currency ceiling changed.
    event CuratorCeilingSet(address indexed curator, Currency indexed currency, uint256 ceiling);
    /// @notice The buffer floor R_a for `currency` changed.
    event BufferFloorSet(Currency indexed currency, uint256 floor);
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
    /// @notice A curator reserved capacity for a hook.
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
    /// @notice An allocation was closed. `by` is the caller; `unusedCapacity` returned to free inventory.
    event AllocationReleased(uint256 indexed allocationId, address indexed by, uint256 unusedCapacity);

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
