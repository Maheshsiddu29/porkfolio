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

/// @title SharedCommitmentVault (Phase 1A: multi-LP, in-kind shares, two-tier redemption)
/// @notice Holds a shared two-asset reserve as ERC-6909 claims inside the Uniswap v4 PoolManager. Registered
///         hooks consume *reserved, bounded, expiring* capacity through an atomic claim-for-claim exchange.
///         LPs own proportional, in-kind shares of the whole reserve. This is NOT an ERC-4626 vault: there is
///         no single asset and no valuation; a share is a fraction of both asset balances.
///
/// Notation, per asset a in {asset0, asset1} (docs/architecture/SHARE_ACCOUNTING.md has the full model):
///   B_a = backing[a]           ERC-6909 claims the vault has accounted for (<= its real PM balance).
///   Q_a = reserved[a]          remaining capacity of unreleased allocations (committed backing).
///   W_a = claimableAssets[a]   assets finalized for queued redemptions, owed to specific requests.
///   N_a = B_a - W_a            net assets owned by outstanding shares (includes Q_a).
///   F_a = N_a - Q_a            immediately deliverable inventory.
///   S   = totalShares          all outstanding shares, INCLUDING escrowed pending shares and MIN_SHARES.
///   P   = pendingShares        shares escrowed in the withdrawal queue (still share P&L until finalized).
///   D_a = ceil(P * N_a / S)    pending redemption demand, protected from new allocations.
///   R_a = bufferFloor[a]       admission floor for new allocations only (not a lock on LP exits).
///
/// Solvency relations maintained by every function: Q_a + W_a <= B_a <= PM.balanceOf(vault, a);
/// W_a = sum of request claimables; P = sum of request sharesPending; S = sum(sharesOf) + P.
/// Admission rule for a new allocation of size q:  Q_a + q + R_a + D_a <= N_a.
contract SharedCommitmentVault is ISharedCommitmentVault, IUnlockCallback {
    /// @notice Largest amount accepted anywhere; PoolManager casts amounts to int128. Also caps
    ///         per-asset backing and total shares, so every stored request amount fits in uint128.
    uint256 public constant MAX_AMOUNT = uint256(uint128(type(int128).max));

    /// @notice Furthest in the future an allocation may expire, relative to its creation.
    uint256 public constant MAX_HORIZON = 30 days;

    /// @notice Shares permanently locked at initialization (held by address(0)); inflation-attack defence.
    uint256 public constant MIN_SHARES = 1000;

    /// @notice Queue steps a redemption performs before deciding on the instant tier while requests are pending.
    ///         Serves already-deliverable requests first (FIFO) so that a stale queue does not block instant
    ///         exits. Bounded so a redeemer's gas cost stays bounded however long the queue is.
    uint256 public constant INLINE_QUEUE_STEPS = 4;

    IPoolManager public immutable poolManager;
    Currency public immutable asset0;
    Currency public immutable asset1;

    address public owner;
    bool public paused;

    mapping(address consumer => bool) public isConsumer;
    mapping(address curator => mapping(Currency currency => uint256)) public curatorCeiling;
    mapping(address curator => mapping(Currency currency => uint256)) public curatorReserved;
    mapping(address curator => mapping(uint256 nonce => bool)) public nonceUsed;

    mapping(Currency currency => uint256) public backing;
    mapping(Currency currency => uint256) public reserved;
    mapping(Currency currency => uint256) public bufferFloor;
    mapping(Currency currency => uint256) public claimableAssets;

    mapping(uint256 allocationId => Allocation) internal _allocations;
    uint256 public nextAllocationId = 1;

    uint256 public totalShares;
    uint256 public pendingShares;
    mapping(address account => uint256) public sharesOf;

    mapping(uint256 requestId => WithdrawalRequest) internal _requests;
    uint256 public nextRequestId = 1;
    /// @notice Lowest request id that may still hold pending shares (strict FIFO processing pointer).
    uint256 public queueHead = 1;

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

    constructor(IPoolManager poolManager_, address owner_, Currency asset0_, Currency asset1_) {
        if (address(poolManager_) == address(0) || owner_ == address(0)) revert ZeroAddress();
        if (asset0_.isAddressZero()) revert NativeCurrencyUnsupported();
        // PoolKey currencies are sorted; requiring the same order lets allocate() match pools exactly.
        if (!(asset0_ < asset1_)) revert InvalidAssetPair();
        poolManager = poolManager_;
        owner = owner_;
        asset0 = asset0_;
        asset1 = asset1_;
        emit OwnershipTransferred(address(0), owner_);
    }

    // ==================================================================
    // Administration (no function here moves assets)
    // ==================================================================

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Emergency stop for deposits, new allocations and all consumption. Redemption, queue
    ///         processing, cancellation and claims stay available.
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

    /// @notice R_a: inventory that new allocations must leave unreserved. Does not restrict LP redemptions.
    function setBufferFloor(Currency currency, uint256 floor) external onlyOwner {
        bufferFloor[currency] = floor;
        emit BufferFloorSet(currency, floor);
    }

    // ==================================================================
    // LP deposits (proportional basket)
    // ==================================================================

    /// @notice First deposit, OWNER ONLY (the asset pair itself is fixed in the constructor). Sets the initial
    ///         basket ratio. Mints sqrt(amount0 * amount1) shares to `receiver`, of which MIN_SHARES are locked
    ///         forever; the owner pays. Both amounts must be non-zero. Because S >= MIN_SHARES afterwards, this can
    ///         run at most once. All later deposits (`deposit`) are permissionless.
    function initialDeposit(uint256 amount0, uint256 amount1, address receiver)
        external
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

    /// @notice Mint exactly `shares` by paying the current per-share basket, rounded up:
    ///         amount_a = ceil(shares * N_a / S). Cannot dilute existing holders (see SHARE_ACCOUNTING.md §3).
    function deposit(uint256 shares, uint256 maxAmount0, uint256 maxAmount1, address receiver)
        external
        whenNotPaused
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 supply = totalShares;
        if (supply == 0) revert NotInitialized();
        if (receiver == address(0)) revert ZeroAddress();
        if (shares == 0) revert ZeroAmount();
        if (shares > MAX_AMOUNT - supply) revert AmountTooLarge();

        (amount0, amount1) = _previewDeposit(shares, supply);
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

    /// @notice Redeem `shares` for their in-kind basket floor(shares * N_a / S).
    ///         If requests are pending, up to INLINE_QUEUE_STEPS of the FIFO queue are processed first.
    ///         Instant tier: only when (after that) the queue holds no pending shares, and only up to what free
    ///         inventory F_a can deliver for BOTH assets. The remainder is escrowed in the FIFO queue if
    ///         `queueRemainder`, otherwise the call reverts. `minAmount0/1` bound the instantly delivered amounts.
    function redeem(uint256 shares, uint256 minAmount0, uint256 minAmount1, address receiver, bool queueRemainder)
        external
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

    /// @notice Finalize queued requests in strict FIFO order, as far as free inventory allows. Permissionless.
    ///         The head request may be partially finalized; processing never skips past an unfinished request.
    ///         Finalized amounts are floor(s * N_a / S) at processing time and move from F_a into W_a.
    /// @param maxSteps bound on loop iterations (gas control).
    /// @return sharesFinalized total shares converted to claimable assets in this call.
    function processQueue(uint256 maxSteps) external returns (uint256 sharesFinalized) {
        return _processQueue(maxSteps);
    }

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

    /// @notice Return the still-pending (unfinalized) shares of a request to its LP. Finalized amounts stay
    ///         claimable. Only the request's LP may cancel.
    function cancelRequest(uint256 requestId) external returns (uint256 sharesReturned) {
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

    /// @notice Pay out everything finalized for a request to its receiver. Only the request's LP may claim.
    function claim(uint256 requestId) external returns (uint256 amount0, uint256 amount1) {
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

    /// @notice Reserve `req.maxOut` of `req.currencyOut` for `req.consumer` on `req.key`.
    /// @dev msg.sender is the curator. Enforces: pool is the vault's asset pair, consumer registered and bound
    ///      to the pool, curator ceiling, expiry horizon, instruction deadline, single-use nonce, and
    ///      Q_a + maxOut + R_a + D_a <= N_a (commitments, the buffer floor, pending redemptions and claimable
    ///      redemption assets are all protected).
    function allocate(AllocationRequest calldata req) external whenNotPaused returns (uint256 allocationId) {
        address curator = msg.sender;

        if (req.deadline < block.timestamp) revert InstructionExpired(req.deadline);
        if (nonceUsed[curator][req.nonce]) revert NonceAlreadyUsed(curator, req.nonce);
        if (!isConsumer[req.consumer]) revert ConsumerNotRegistered(req.consumer);
        if (address(req.key.hooks) != req.consumer) revert ConsumerMismatch(req.consumer, address(req.key.hooks));
        if (!(req.key.currency0 == asset0) || !(req.key.currency1 == asset1)) revert UnsupportedPair();

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

        uint256 admissible = admissibleCapacity(out);
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

    /// @notice Return an allocation's unused capacity to free inventory.
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
    ///      the input cannot receive output: the whole call reverts. Trade proceeds accrue to all outstanding
    ///      shares (including pending ones) through B_a; nothing here touches shares, W_a or the queue.
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

        Currency cin = a.currencyIn;
        Currency cout = a.currencyOut;
        uint256 backingIn = backing[cin];
        if (amountIn > MAX_AMOUNT - backingIn) revert AmountTooLarge();

        // Effects. amountOut <= remaining <= reserved[out] <= backing[out] - claimable[out], so no underflow
        // and claimable redemption assets are never paid to a hook.
        // forge-lint: disable-next-line(unsafe-typecast) amountOut <= remaining <= maxOut (a uint128).
        a.consumed += uint128(amountOut);
        reserved[cout] -= amountOut;
        curatorReserved[a.curator][cout] -= amountOut;
        backing[cout] -= amountOut;
        backing[cin] = backingIn + amountIn;

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

    function getRequest(uint256 requestId) external view returns (WithdrawalRequest memory) {
        return _requests[requestId];
    }

    function requestStatus(uint256 requestId) external view returns (RequestStatus) {
        WithdrawalRequest storage r = _requests[requestId];
        if (r.lp == address(0)) return RequestStatus.None;
        if (r.sharesPending != 0) return RequestStatus.Pending;
        if (r.claimable0 != 0 || r.claimable1 != 0) return RequestStatus.Claimable;
        return r.canceled ? RequestStatus.Canceled : RequestStatus.Completed;
    }

    /// @notice N_a: assets owned by outstanding shares (excludes assets already owed to finalized requests).
    function netAssets(Currency currency) public view returns (uint256) {
        return backing[currency] - claimableAssets[currency];
    }

    /// @notice F_a: assets deliverable now without touching commitments or finalized redemptions.
    function freeInventory(Currency currency) public view returns (uint256) {
        return backing[currency] - claimableAssets[currency] - reserved[currency];
    }

    /// @notice D_a = ceil(P * N_a / S): the pending queue's current pro-rata claim on asset a.
    function pendingDemand(Currency currency) public view returns (uint256) {
        uint256 p = pendingShares;
        if (p == 0) return 0;
        return FullMath.mulDivRoundingUp(p, netAssets(currency), totalShares);
    }

    /// @notice Largest new allocation of `currency` that the admission rule accepts now.
    function admissibleCapacity(Currency currency) public view returns (uint256) {
        return _sub0(netAssets(currency), reserved[currency] + bufferFloor[currency] + pendingDemand(currency));
    }

    /// @notice Shares whose basket free inventory can deliver right now (ignores queue priority).
    function deliverableShares() external view returns (uint256) {
        uint256 supply = totalShares;
        return supply == 0 ? 0 : _deliverableShares(supply);
    }

    function previewDeposit(uint256 shares) external view returns (uint256 amount0, uint256 amount1) {
        uint256 supply = totalShares;
        if (supply == 0) revert NotInitialized();
        return _previewDeposit(shares, supply);
    }

    /// @notice In-kind basket floor(shares * N_a / S) at the current state.
    function previewRedeem(uint256 shares) external view returns (uint256 amount0, uint256 amount1) {
        uint256 supply = totalShares;
        if (supply == 0) return (0, 0);
        return _entitlement(shares, supply);
    }

    // ==================================================================
    // Internal
    // ==================================================================

    function _previewDeposit(uint256 shares, uint256 supply) internal view returns (uint256 amount0, uint256 amount1) {
        uint256 n0 = netAssets(asset0);
        uint256 n1 = netAssets(asset1);
        if (n0 == 0 && n1 == 0) revert NoAssets();
        amount0 = FullMath.mulDivRoundingUp(shares, n0, supply);
        amount1 = FullMath.mulDivRoundingUp(shares, n1, supply);
    }

    function _entitlement(uint256 shares, uint256 supply) internal view returns (uint256 amount0, uint256 amount1) {
        amount0 = FullMath.mulDiv(shares, netAssets(asset0), supply);
        amount1 = FullMath.mulDiv(shares, netAssets(asset1), supply);
    }

    /// @dev max s such that floor(s * N_a / S) <= F_a for both assets: min_a floor(F_a * S / N_a).
    function _deliverableShares(uint256 supply) internal view returns (uint256 cap) {
        cap = type(uint256).max;
        uint256 n0 = netAssets(asset0);
        if (n0 != 0) cap = FullMath.mulDiv(n0 - reserved[asset0], supply, n0);
        uint256 n1 = netAssets(asset1);
        if (n1 != 0) {
            uint256 c1 = FullMath.mulDiv(n1 - reserved[asset1], supply, n1);
            if (c1 < cap) cap = c1;
        }
    }

    function _unlock(CallbackAction action, address account, uint256 amount0, uint256 amount1) internal {
        poolManager.unlock(abi.encode(action, account, amount0, amount1));
    }

    /// @dev sync -> transfer -> settle credits +amount to the vault; mint debits -amount. Net delta: 0.
    function _settleIn(Currency currency, address payer, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.sync(currency);
        SafeTransferLib.safeTransferFrom(ERC20(Currency.unwrap(currency)), payer, address(poolManager), amount);
        uint256 paid = poolManager.settle();
        if (paid != amount) revert SettlementMismatch(amount, paid); // fee-on-transfer etc. fail closed
        poolManager.mint(address(this), currency.toId(), amount);
    }

    /// @dev burn credits +amount to the vault; take debits -amount and transfers ERC-20 out. Net delta: 0.
    function _payOut(Currency currency, address to, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, to, amount);
    }

    function _getLiveAllocation(uint256 allocationId) internal view returns (Allocation storage a) {
        a = _allocations[allocationId];
        if (a.consumer == address(0)) revert UnknownAllocation(allocationId);
        if (a.released) revert AllocationAlreadyReleased(allocationId);
    }

    function _sub0(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }
}
