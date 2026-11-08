// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title ISharedCommitmentVault
/// @notice Interface of the shared two-asset ERC-6909 reserve. Compatible hooks consume reserved capacity
///         through `exchange`, an atomic claim-for-claim swap mediated by the vault. LPs own proportional,
///         in-kind shares of the reserve and exit through two-tier (instant + queued) redemption.
interface ISharedCommitmentVault {
    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    /// @notice A curator instruction to reserve vault capacity for one consumer hook on one pool.
    /// @dev Shaped so that Phase 1 can accept the same struct via an EIP-712 signature.
    /// @param consumer        Registered hook allowed to consume this allocation. Must equal `key.hooks`.
    /// @param key             Pool the allocation is bound to.
    /// @param currencyOut     Currency the vault pays out (must be key.currency0 or key.currency1).
    /// @param maxOut          Gross outflow capacity Q reserved for this allocation.
    /// @param minInPerOutX96  Worst price the vault accepts: amountIn >= ceil(amountOut * minInPerOutX96 / 2^96).
    /// @param expiry          Allocation is consumable while block.timestamp < expiry.
    /// @param nonce           Curator-scoped single-use nonce (replay protection).
    /// @param deadline        Instruction must be submitted while block.timestamp <= deadline.
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

    /// @notice Vault-controlled price policy for one direction, keyed by the currency the vault SELLS.
    /// @param minInPerOutX96 Vault floor f_v: minimum raw input per raw output, Q64.96. Zero = never configured
    ///                       (direction closed). Can be raised by owner or guardian, lowered only by the owner,
    ///                       never reset to zero.
    /// @param halted         Emergency stop for this direction (new allocations and consumption).
    struct SellPolicy {
        uint160 minInPerOutX96;
        bool halted;
    }

    /// @notice A queued redemption. `sharesPending` shares are escrowed and still carry P&L; finalized
    ///         portions are converted into fixed `claimable0/1` amounts owed to `receiver`.
    struct WithdrawalRequest {
        address lp;
        bool canceled;
        address receiver;
        uint128 sharesRequested;
        uint128 sharesPending;
        uint128 claimable0;
        uint128 claimable1;
    }

    /// @notice Pending: some shares not yet finalized. Claimable: fully finalized, assets unclaimed.
    ///         Completed: fully finalized and claimed. Canceled: canceled and nothing left to claim.
    enum RequestStatus {
        None,
        Pending,
        Claimable,
        Completed,
        Canceled
    }

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error NotOwner();
    error NotPendingOwner();
    error GuardianCannotIncreaseRisk();
    error CuratorNotRegistered(address curator);
    error NotPoolManager();
    error ZeroAddress();
    error Paused();
    error NativeCurrencyUnsupported();
    error ZeroAmount();
    error AmountTooLarge();
    error SettlementMismatch(uint256 expected, uint256 paid);
    error InvalidAssetPair();
    error UnsupportedPair();

    error AlreadyInitialized();
    error NotInitialized();
    error InitialDepositTooSmall(uint256 shares, uint256 minimum);
    error NoAssets();
    error SlippageExceeded();
    error InsufficientShares(uint256 requested, uint256 balance);
    error InsufficientLiquidity(uint256 requested, uint256 deliverable);
    error DustRedemption();
    error NotRequestOwner(uint256 requestId);
    error NothingPending(uint256 requestId);
    error NothingToClaim(uint256 requestId);

    error ConsumerNotRegistered(address consumer);
    error ConsumerMismatch(address expected, address actual);
    error CuratorCeilingExceeded(uint256 requested, uint256 available);
    error InvalidCurrency();
    error InvalidExpiry();
    error HorizonExceeded(uint64 expiry, uint256 maxExpiry);
    error InstructionExpired(uint64 deadline);
    error NonceAlreadyUsed(address curator, uint256 nonce);
    error InsufficientBacking(uint256 requested, uint256 available);

    error UnknownAllocation(uint256 allocationId);
    error AllocationAlreadyReleased(uint256 allocationId);
    error AllocationExpired(uint256 allocationId, uint64 expiry);
    error AllocationNotExpired(uint256 allocationId, uint64 expiry);
    error PoolMismatch();
    error DirectionMismatch();
    error QuotaExceeded(uint256 requested, uint256 remaining);
    error PriceBelowFloor(uint256 amountIn, uint256 requiredIn);
    error PriceFloorNotConfigured(Currency currencyOut);
    error DirectionHalted(Currency currencyOut);
    error ZeroPriceFloor();
    error FloorBelowVaultMinimum(uint256 curatorFloor, uint256 vaultFloor);
    error InconsistentDirectionalFloors(uint256 floor, uint256 requiredMinimum);

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event GuardianSet(address indexed previousGuardian, address indexed newGuardian);
    event CuratorSet(address indexed curator, bool registered);
    event PausedSet(bool paused);
    event ConsumerSet(address indexed consumer, bool registered);
    event CuratorCeilingSet(address indexed curator, Currency indexed currency, uint256 ceiling);
    event BufferFloorSet(Currency indexed currency, uint256 floor);
    event SellFloorSet(Currency indexed currencyOut, uint160 previousFloor, uint160 newFloor, address indexed by);
    event SellHaltedSet(Currency indexed currencyOut, bool halted, address indexed by);
    event Deposited(address indexed caller, address indexed receiver, uint256 shares, uint256 amount0, uint256 amount1);
    event Redeemed(address indexed lp, address indexed receiver, uint256 shares, uint256 amount0, uint256 amount1);
    event RedeemRequested(uint256 indexed requestId, address indexed lp, address indexed receiver, uint256 shares);
    event RequestFinalized(uint256 indexed requestId, uint256 shares, uint256 amount0, uint256 amount1);
    event RequestCanceled(uint256 indexed requestId, uint256 sharesReturned);
    event Claimed(uint256 indexed requestId, address indexed receiver, uint256 amount0, uint256 amount1);
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
    event AllocationConsumed(
        uint256 indexed allocationId, address indexed consumer, uint256 amountIn, uint256 amountOut, uint128 consumed
    );
    event AllocationReleased(uint256 indexed allocationId, address indexed by, uint256 unusedCapacity);

    // ------------------------------------------------------------------
    // Consumer entry point
    // ------------------------------------------------------------------

    /// @notice Atomically exchange `amountIn` claims of the allocation's input currency (pulled from the
    ///         calling hook) for `amountOut` claims of its output currency (pushed to the calling hook).
    function exchange(PoolKey calldata key, bool zeroForOne, uint256 allocationId, uint256 amountIn, uint256 amountOut)
        external;

    function getAllocation(uint256 allocationId) external view returns (Allocation memory);
}
