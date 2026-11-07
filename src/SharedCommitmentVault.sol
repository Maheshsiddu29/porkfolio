// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

import {ISharedCommitmentVault} from "./interfaces/ISharedCommitmentVault.sol";

/// @title SharedCommitmentVault (Milestone 0 vertical slice)
/// @notice Holds a shared reserve as ERC-6909 claims inside the Uniswap v4 PoolManager and lets
///         registered hooks consume *reserved, bounded, expiring* capacity through an atomic
///         claim-for-claim exchange. No hook ever receives operator rights or allowance over vault claims.
///
/// Per-currency accounting (all in units of the currency, a = currency):
///   backing[a]   C_a  — claims the vault has accounted for. Invariant: backing[a] <= PM.balanceOf(vault, a).
///   reserved[a]  ΣQ_a — sum over live allocations of (maxOut - consumed).  Invariant: reserved[a] <= backing[a].
///   bufferFloor[a] R_a — minimum unreserved backing that new allocations must leave untouched.
///   Admission rule (checked at allocation time only):  R_a + ΣQ_a <= C_a.
///
/// Milestone-0 scope limits (deliberate, see docs/architecture/ACCOUNTING_FLOW.md):
///   - Single funder (owner) — no LP shares, no queued withdrawals, no multi-asset valuation.
///   - Exact-input consumption only; expiry is per-allocation and recognised lazily (no ring buffer yet).
///   - Allocations are submitted on-chain by curators; EIP-712 signatures are Phase 1.
///   - ERC-20 currencies only (native ETH rejected).
contract SharedCommitmentVault is ISharedCommitmentVault, IUnlockCallback {
    /// @notice Largest amount accepted anywhere; PoolManager casts amounts to int128.
    uint256 public constant MAX_AMOUNT = uint256(uint128(type(int128).max));

    /// @notice Furthest in the future an allocation may expire, relative to its creation.
    uint256 public constant MAX_HORIZON = 30 days;

    IPoolManager public immutable poolManager;

    address public owner;
    bool public paused;

    mapping(address consumer => bool) public isConsumer;
    mapping(address curator => mapping(Currency currency => uint256)) public curatorCeiling;
    mapping(address curator => mapping(Currency currency => uint256)) public curatorReserved;
    mapping(address curator => mapping(uint256 nonce => bool)) public nonceUsed;

    mapping(Currency currency => uint256) public backing;
    mapping(Currency currency => uint256) public reserved;
    mapping(Currency currency => uint256) public bufferFloor;

    mapping(uint256 allocationId => Allocation) internal _allocations;
    uint256 public nextAllocationId = 1;

    enum CallbackAction {
        Deposit,
        Withdraw
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    constructor(IPoolManager poolManager_, address owner_) {
        if (address(poolManager_) == address(0) || owner_ == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    // ==================================================================
    // Administration
    // ==================================================================

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Emergency stop for new allocations and all consumption. Deposits/withdrawals stay available.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Register or revoke a compatible hook. Revocation takes effect immediately for consumption.
    function setConsumer(address consumer, bool registered) external onlyOwner {
        if (consumer == address(0)) revert ZeroAddress();
        isConsumer[consumer] = registered;
        emit ConsumerSet(consumer, registered);
    }

    /// @notice Maximum outstanding reserved capacity a curator may hold in `currency`. Zero = not authorised.
    function setCuratorCeiling(address curator, Currency currency, uint256 ceiling) external onlyOwner {
        if (curator == address(0)) revert ZeroAddress();
        curatorCeiling[curator][currency] = ceiling;
        emit CuratorCeilingSet(curator, currency, ceiling);
    }

    /// @notice R_a: backing that must remain unreserved when new allocations are admitted.
    function setBufferFloor(Currency currency, uint256 floor) external onlyOwner {
        bufferFloor[currency] = floor;
        emit BufferFloorSet(currency, floor);
    }

    // ==================================================================
    // Funding: ERC-20 -> ERC-6909 claims held by the vault
    // ==================================================================

    /// @notice Pull `amount` ERC-20 from the owner, settle it into the PoolManager, and mint claims to the vault.
    function deposit(Currency currency, uint256 amount) external onlyOwner {
        _checkFundingArgs(currency, amount);
        backing[currency] += amount; // effects first; the whole call reverts if settlement fails
        poolManager.unlock(abi.encode(CallbackAction.Deposit, currency, amount, address(0)));
        emit Deposited(currency, msg.sender, amount);
    }

    /// @notice Burn `amount` unreserved claims and send the underlying ERC-20 to `to`.
    /// @dev Only backing not reserved by live (or expired-but-unreleased) allocations is withdrawable.
    function withdraw(Currency currency, uint256 amount, address to) external onlyOwner {
        _checkFundingArgs(currency, amount);
        if (to == address(0)) revert ZeroAddress();
        uint256 free = backing[currency] - reserved[currency];
        if (amount > free) revert InsufficientFreeBacking(amount, free);
        backing[currency] -= amount;
        poolManager.unlock(abi.encode(CallbackAction.Withdraw, currency, amount, to));
        emit Withdrawn(currency, to, amount);
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Reachable only via this vault's own `poolManager.unlock` call (PoolManager calls back msg.sender).
    ///      Deposits always pull from `owner`; `account` is used only as the withdrawal recipient.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (CallbackAction action, Currency currency, uint256 amount, address account) =
            abi.decode(data, (CallbackAction, Currency, uint256, address));

        if (action == CallbackAction.Deposit) {
            // sync -> transfer -> settle credits +amount to the vault; mint debits -amount. Net delta: 0.
            poolManager.sync(currency);
            SafeTransferLib.safeTransferFrom(ERC20(Currency.unwrap(currency)), owner, address(poolManager), amount);
            uint256 paid = poolManager.settle();
            if (paid != amount) revert SettlementMismatch(amount, paid); // fee-on-transfer etc. fail closed
            poolManager.mint(address(this), currency.toId(), amount);
        } else {
            // burn credits +amount to the vault; take debits -amount and transfers ERC-20 out. Net delta: 0.
            poolManager.burn(address(this), currency.toId(), amount);
            poolManager.take(currency, account, amount);
        }
        return "";
    }

    // ==================================================================
    // Curator allocations (capacity reservation)
    // ==================================================================

    /// @notice Reserve `req.maxOut` of `req.currencyOut` for `req.consumer` on `req.key`.
    /// @dev msg.sender is the curator. Enforces: consumer registered and bound to the pool, curator ceiling,
    ///      expiry horizon, instruction deadline, single-use nonce, and R + ΣQ <= C.
    function allocate(AllocationRequest calldata req) external whenNotPaused returns (uint256 allocationId) {
        address curator = msg.sender;

        if (req.deadline < block.timestamp) revert InstructionExpired(req.deadline);
        if (nonceUsed[curator][req.nonce]) revert NonceAlreadyUsed(curator, req.nonce);
        if (!isConsumer[req.consumer]) revert ConsumerNotRegistered(req.consumer);
        if (address(req.key.hooks) != req.consumer) revert ConsumerMismatch(req.consumer, address(req.key.hooks));

        bool outIsCurrency0 = req.currencyOut == req.key.currency0;
        if (!outIsCurrency0 && !(req.currencyOut == req.key.currency1)) revert InvalidCurrency();
        Currency currencyIn = outIsCurrency0 ? req.key.currency1 : req.key.currency0;

        if (req.maxOut == 0) revert ZeroAmount();
        if (req.maxOut > MAX_AMOUNT) revert AmountTooLarge();
        if (req.expiry <= block.timestamp) revert InvalidExpiry();
        if (req.expiry > block.timestamp + MAX_HORIZON) {
            revert HorizonExceeded(req.expiry, block.timestamp + MAX_HORIZON);
        }

        Currency out = req.currencyOut;
        uint256 curatorAvailable = _sub0(curatorCeiling[curator][out], curatorReserved[curator][out]);
        if (req.maxOut > curatorAvailable) revert CuratorCeilingExceeded(req.maxOut, curatorAvailable);

        // Admission rule: R_a + ΣQ_a + newQ <= C_a
        uint256 admissible = _sub0(backing[out], reserved[out] + bufferFloor[out]);
        if (req.maxOut > admissible) revert InsufficientBacking(req.maxOut, admissible);

        nonceUsed[curator][req.nonce] = true;
        reserved[out] += req.maxOut;
        curatorReserved[curator][out] += req.maxOut;

        allocationId = nextAllocationId++;
        PoolId poolId = req.key.toId();
        _allocations[allocationId] = Allocation({
            curator: curator,
            consumer: req.consumer,
            expiry: req.expiry,
            released: false,
            poolId: poolId,
            currencyIn: currencyIn,
            currencyOut: out,
            maxOut: req.maxOut,
            consumed: 0,
            minInPerOutX96: req.minInPerOutX96
        });

        emit AllocationCreated(allocationId, curator, req.consumer, poolId, out, req.maxOut, req.expiry, req.nonce);
    }

    /// @notice Return an allocation's unused capacity to the free pool.
    /// @dev Expiry is recognised lazily: after `expiry` anyone may release. Before expiry only the owner
    ///      may release (emergency), because an unexpired allocation is a commitment to its consumer.
    function release(uint256 allocationId) external {
        Allocation storage a = _getLiveAllocation(allocationId);
        if (block.timestamp < a.expiry && msg.sender != owner) revert AllocationNotExpired(allocationId, a.expiry);

        uint256 unused = a.maxOut - a.consumed;
        a.released = true;
        reserved[a.currencyOut] -= unused;
        curatorReserved[a.curator][a.currencyOut] -= unused;

        emit AllocationReleased(allocationId, msg.sender, unused);
    }

    // ==================================================================
    // Consumption (called by a registered hook from inside beforeSwap)
    // ==================================================================

    /// @inheritdoc ISharedCommitmentVault
    /// @dev Caller (the hook) must have minted `amountIn` input claims to itself and made this vault its
    ///      ERC-6909 operator. The vault pulls input before pushing output, so a hook that has not funded
    ///      the input cannot receive output: the whole call reverts.
    function exchange(PoolKey calldata key, bool zeroForOne, uint256 allocationId, uint256 amountIn, uint256 amountOut)
        external
        whenNotPaused
    {
        if (!isConsumer[msg.sender]) revert ConsumerNotRegistered(msg.sender);

        Allocation storage a = _getLiveAllocation(allocationId);
        if (a.consumer != msg.sender) revert ConsumerMismatch(a.consumer, msg.sender);
        if (address(key.hooks) != msg.sender) revert ConsumerMismatch(msg.sender, address(key.hooks));
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(a.poolId)) revert PoolMismatch();
        if (block.timestamp >= a.expiry) revert AllocationExpired(allocationId, a.expiry);
        if (!((zeroForOne ? key.currency1 : key.currency0) == a.currencyOut)) revert DirectionMismatch();

        if (amountIn == 0 || amountOut == 0) revert ZeroAmount();
        if (amountIn > MAX_AMOUNT || amountOut > MAX_AMOUNT) revert AmountTooLarge();

        uint256 remaining = a.maxOut - a.consumed;
        if (amountOut > remaining) revert QuotaExceeded(amountOut, remaining);

        uint256 requiredIn = FullMath.mulDivRoundingUp(amountOut, a.minInPerOutX96, FixedPoint96.Q96);
        if (amountIn < requiredIn) revert PriceBelowFloor(amountIn, requiredIn);

        // Effects. amountOut <= remaining <= reserved[out] <= backing[out], so no underflow.
        Currency cin = a.currencyIn;
        Currency cout = a.currencyOut;
        // forge-lint: disable-next-line(unsafe-typecast) amountOut <= remaining <= maxOut (a uint128).
        a.consumed += uint128(amountOut);
        reserved[cout] -= amountOut;
        curatorReserved[a.curator][cout] -= amountOut;
        backing[cout] -= amountOut;
        backing[cin] += amountIn;

        // Interactions: pull input first, then push exactly the authorised output.
        poolManager.transferFrom(msg.sender, address(this), cin.toId(), amountIn);
        poolManager.transfer(msg.sender, cout.toId(), amountOut);

        emit AllocationConsumed(allocationId, msg.sender, amountIn, amountOut, a.consumed);
    }

    // ==================================================================
    // Views
    // ==================================================================

    function getAllocation(uint256 allocationId) external view returns (Allocation memory) {
        return _allocations[allocationId];
    }

    /// @notice Backing not reserved by any unreleased allocation (what the owner may withdraw now).
    function freeBacking(Currency currency) external view returns (uint256) {
        return backing[currency] - reserved[currency];
    }

    // ==================================================================
    // Internal
    // ==================================================================

    function _getLiveAllocation(uint256 allocationId) internal view returns (Allocation storage a) {
        a = _allocations[allocationId];
        if (a.consumer == address(0)) revert UnknownAllocation(allocationId);
        if (a.released) revert AllocationAlreadyReleased(allocationId);
    }

    function _checkFundingArgs(Currency currency, uint256 amount) internal pure {
        if (currency.isAddressZero()) revert NativeCurrencyUnsupported();
        if (amount == 0) revert ZeroAmount();
        if (amount > MAX_AMOUNT) revert AmountTooLarge();
    }

    function _sub0(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }
}
