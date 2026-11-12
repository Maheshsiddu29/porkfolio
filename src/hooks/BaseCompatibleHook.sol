// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

import {ISharedCommitmentVault} from "../interfaces/ISharedCommitmentVault.sol";
import {IVaultState} from "../interfaces/IVaultState.sol";
import {IMarketRiskAdapter} from "../interfaces/IMarketRiskAdapter.sol";
import {InventoryPricing} from "../pricing/InventoryPricing.sol";

/// @title BaseCompatibleHook
/// @notice Shared swap plumbing for hooks that fill every swap on their pool from the SharedCommitmentVault instead
///         of from pool liquidity. A concrete hook supplies the price (`_quote`) and stores its pricing state
///         (`_commit`).
/// @dev Swap flow, exact input of X, quoted output Y. All steps run inside `beforeSwap` while the swapper's router
///      holds the PoolManager unlock:
///
///        step                                hook delta[in]  hook delta[out]  hook claims (in / out)
///        1. poolManager.mint(this, in, X)        -X              0               X / 0
///        2. vault.exchange(..., X, Y)            -X              0               0 / Y
///        3. poolManager.burn(this, out, Y)       -X             +Y               0 / 0
///        4. return BeforeSwapDelta(+X, -Y)        0               0               0 / 0
///
///      Why mint first. The swapper has not paid yet; routers pay at the end of the unlock. Minting X input claims
///      lets the hook hand the vault real claims now, in exchange for a debt of X on the hook's own delta. Step 4
///      moves that debt to the swapper, so the swapper must later pay X of ERC-20 into the PoolManager.
///
///      Why burn the output. The vault pays in claims, not ERC-20. Burning the Y output claims gives the hook a
///      credit of Y, and step 4 passes that credit to the swapper, who can then `take` Y of ERC-20 (or mint it as
///      claims). The hook ends the swap holding no claims and owing nothing.
///
///      What the returned delta means. A `BeforeSwapDelta` is two int128 values: the specified-currency delta
///      (here the input, because the swap is exact input) and the unspecified-currency delta (here the output).
///      The PoolManager adds the specified value to the amount still to be swapped: -X + X = 0, so the pool's own
///      price curve does not run at all. It then adds both values to the hook's delta and subtracts them from the
///      swapper's: +X credits the hook with the input the swapper now owes, and -Y debits the hook for the output the
///      swapper is now owed. The swapper ends at -X input and +Y output.
///
///      What happens if anything is wrong. The PoolManager reverts the whole unlock with `CurrencyNotSettled` unless
///      every account's delta is zero at the end. If the vault rejects the trade, if the hook's quote reverts, or if
///      the swapper does not pay X, the entire transaction reverts and none of the steps above take effect: no
///      claims stay minted, the vault's accounting is unchanged, and the allocation is not consumed.
///
///      Authority. The constructor makes the vault an ERC-6909 operator over this hook's claims so step 2 can pull
///      the X input claims. Nothing grants the hook any authority over the vault's claims; it can only receive the
///      output the vault decides to send. The hook normally holds claims only during one `beforeSwap`, so between
///      swaps the operator grant has nothing to act on, and the vault only uses it inside `exchange`, which only the
///      hook itself can call for its allocations.
///
///      Who chooses the allocation. The swapper passes the allocation id in `hookData`. Any swapper may use any
///      allocation made out to this hook for this pool: an allocation reserves capacity for the hook, not for a
///      trader. The vault decides whether the trade is allowed. The allocation does not affect the price: concrete
///      hooks price from their own per-pool state, so choosing a different allocation or curator changes nothing.
///
///      Pricing state. A concrete hook prices with `_quote`, a view that returns the output and the hook's new
///      pricing state, and stores that state with `_commit` only after `vault.exchange` has returned. If the vault,
///      the PoolManager settlement or the swapper's payment fails, the whole transaction reverts, so a failed swap
///      never changes the state. Nothing can swap on the same pool between `_quote` and `_commit`: the only external
///      calls in between are `poolManager.mint`, `vault.exchange` (non-reentrant, and it calls only the
///      PoolManager's ERC-6909 functions, which make no callbacks) and `poolManager.burn`.
///
///      Exact input and price limits. Only exact-input swaps are supported. The swap's `sqrtPriceLimitX96` is
///      ignored: this hook takes the whole amount, so the PoolManager passes zero to the pool's swap function,
///      which returns before it reads the limit (`Pool.swap`, pinned v4-core), and the pool's price never moves.
///      The pool's LP fee setting is never applied either.
///
///      Minimum output. `hookData` may carry a minimum output: `abi.encode(allocationId, minAmountOut)` (64
///      bytes) makes the swap revert with `InsufficientOutput` if the quote is below `minAmountOut`. The 32-byte
///      form `abi.encode(allocationId)` sets no minimum. The bound protects only swappers whose router or
///      integration encodes it; it is not a general slippage guarantee. Routers that check the amount received
///      after the swap (for example the v4 `V4Router`'s `amountOutMinimum`) protect their users independently of
///      this field, because the hook's output reaches the swapper as an ordinary PoolManager delta.
///
///      Two pricing modes, chosen by the vault, never by the hook or the swapper.
///        Static mode (the vault has no market-risk adapter): the concrete hook prices with `_quote` from its own
///        per-pool configuration, around the price its owner configured.
///        Shared-core mode (the vault has an adapter): the hook reads that adapter from the vault, the vault's net
///        currency1 holding N1, the share supply S and the vault's inventory target tau_1, and prices through
///        `InventoryPricing` in band mode (every quote lies outside the reference band widened by the edge), then
///        applies its own strategy (`_quoteCore`). Nothing in the hook selects the adapter, so a hook cannot price
///        from a weaker one than the vault enforces. The vault re-reads the same adapter inside `exchange` in the
///        same transaction; for an adapter that is a view of on-chain state, as `PriceRiskAdapter` is, both reads see
///        the same state because nothing between them touches the feeds. That is consistency, not independence: one
///        corrupted adapter misleads both, and what bounds the damage is the vault's inventory floor.
///        Two vault limits feed the core so that a tightening by the vault's guardian reaches every hook at once:
///        the core's deviation cap is at most the vault's tolerance kappa_1, and the hook's edge is at least the
///        vault's edge plus 1 pip (an equal edge would let rounding put a quote one raw unit inside the vault floor).
///
///      Permissions: beforeSwap, beforeSwapReturnDelta, and beforeAddLiquidity (only to reject native liquidity,
///      which could never be traded because every swap is intercepted). The deployed address must encode exactly
///      these permission bits; the constructor checks this.
abstract contract BaseCompatibleHook is IHooks {
    /// @dev 2^127 - 1. Amounts must fit in int128 because `BeforeSwapDelta` and the PoolManager's deltas are int128.
    uint256 internal constant MAX_AMOUNT = uint256(uint128(type(int128).max));

    /// @notice The Uniswap v4 PoolManager this hook is attached to. Only it may call the hook callbacks.
    IPoolManager public immutable poolManager;
    /// @notice The vault that fills this hook's swaps.
    ISharedCommitmentVault public immutable vault;
    /// @notice Account allowed to configure pool pricing on the concrete hook. It has no authority over the vault.
    /// @dev Immutable. In the production deployment it is the vault's `VaultGovernor`, so every pricing change waits
    ///      the governor's delay and can be canceled by the vault's guardian; the release checklist verifies this.
    address public immutable hookOwner;

    /// @dev 1e6 pips = 100%.
    uint256 internal constant _PIPS = 1_000_000;

    /// @notice Shared-core parameters of one pool, used only while the vault has a market-risk adapter.
    /// @param depthPerShare Curve depth V per share, raw currency1 scaled by 1e18; V = S * depthPerShare / 1e18,
    ///        capped at `depthMax`. Larger depth means a flatter price curve.
    /// @param depthMax Largest V, raw currency1. Below 2^95 (the core's overflow bound).
    /// @param baseSpreadPips Half-spread before uncertainty; the core adds the adapter's uncertainty u to it.
    /// @param minEdgePips Smallest edge beyond the reference band; raised to the vault's edge + 1 when lower.
    /// @param maxSpreadPips Largest half-spread (base + u) the pool will quote; wider readings are refused.
    /// @param maxDeviationPips Largest inventory deviation from target, pips of T1; lowered to the vault's kappa_1.
    struct CoreParams {
        uint128 depthPerShare;
        uint128 depthMax;
        uint24 baseSpreadPips;
        uint24 minEdgePips;
        uint24 maxSpreadPips;
        uint24 maxDeviationPips;
    }

    /// @notice Shared-core parameters by pool. All-zero: the pool cannot trade in shared-core mode.
    mapping(PoolId => CoreParams) public coreParams;

    /// @notice Shared-core parameters of `poolId` were set.
    event CoreConfigured(PoolId indexed poolId, CoreParams params);

    /// @notice The vault has a market-risk adapter but this pool has no shared-core parameters.
    error CoreNotConfigured();
    /// @notice Shared-core parameters out of range (zero depth, depth at or above 2^95, a spread or deviation of
    ///         100% or more, or a key for another hook).
    error InvalidCoreConfig();

    /// @notice A hook callback was called by something other than the PoolManager.
    error NotPoolManager();
    /// @notice A configuration function was called by someone other than `hookOwner`.
    error NotHookOwner();
    /// @notice A callback whose permission bit is not set was called directly. The PoolManager never calls these.
    error HookNotImplemented();
    /// @notice Adding liquidity to the pool's own curve is refused; this pool trades only against the vault.
    error NativeLiquidityDisabled();
    /// @notice The swap was exact output (amountSpecified > 0). Only exact input is supported.
    error ExactOutputNotSupported();
    /// @notice The swap had amountSpecified == 0. The pinned PoolManager already rejects this with
    ///         `SwapAmountCannotBeZero` before any hook runs, so this only fires if a PoolManager does not.
    error ZeroInput();
    /// @notice A constructor argument was address(0).
    error ZeroAddress();
    /// @notice The input or the quoted output exceeds 2^127 - 1.
    error AmountTooLarge();
    /// @notice `hookData` was neither `abi.encode(allocationId)` (32 bytes) nor
    ///         `abi.encode(allocationId, minAmountOut)` (64 bytes).
    error InvalidHookData();
    /// @notice The quoted output is below the minimum the swapper put in `hookData`.
    /// @param amountOut Raw output the hook would have paid.
    /// @param minAmountOut Raw minimum the swapper asked for.
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    /// @notice The quote rounded down to zero output; the swap is refused instead of taking input for nothing.
    error ZeroOutput();

    /// @notice A swap on `poolId` was filled from the vault against `allocationId`.
    /// @param poolId Pool the swap ran on.
    /// @param allocationId Allocation consumed.
    /// @param zeroForOne True if the swapper sold currency0.
    /// @param amountIn Raw input paid by the swapper and received by the vault.
    /// @param amountOut Raw output paid by the vault and owed to the swapper.
    event SharedLiquiditySwap(
        PoolId indexed poolId, uint256 indexed allocationId, bool zeroForOne, uint256 amountIn, uint256 amountOut
    );

    /// @dev Hook callbacks must only be invoked by the PoolManager; otherwise anyone could trigger mint/burn calls
    ///      outside a real swap.
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @dev Restricts pricing configuration to `hookOwner`.
    modifier onlyHookOwner() {
        if (msg.sender != hookOwner) revert NotHookOwner();
        _;
    }

    /// @dev Reverts with `ZeroAddress` if any argument is zero: all three are immutable, and a hook built with a
    ///      zero vault or owner could never fill a swap or be configured. Then reverts unless this contract's address
    ///      encodes exactly the permissions in `getHookPermissions`, because the PoolManager decides which callbacks
    ///      to call from the address bits alone. Finally makes the vault an operator over this hook's claims (see the
    ///      contract documentation for why this direction is safe).
    /// @param poolManager_ PoolManager the hook's pools live in. Non-zero.
    /// @param vault_ Vault that fills the swaps. Non-zero.
    /// @param hookOwner_ Account that may configure pricing. Non-zero.
    constructor(IPoolManager poolManager_, ISharedCommitmentVault vault_, address hookOwner_) {
        if (address(poolManager_) == address(0) || address(vault_) == address(0) || hookOwner_ == address(0)) {
            revert ZeroAddress();
        }
        poolManager = poolManager_;
        vault = vault_;
        hookOwner = hookOwner_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        // The vault may pull the hook's *own* transient input claims. The reverse (hook over vault) is never granted.
        poolManager_.setOperator(address(vault_), true);
    }

    /// @notice Set the shared-core parameters of one of this hook's pools.
    /// @dev Hook owner only. Takes effect on the next swap. The parameters shape the hook's quotes inside the vault's
    ///      boundary; they cannot widen what the vault accepts. See `CoreParams` for units.
    /// @param key Pool to configure; its `hooks` must be this contract.
    /// @param params New parameters.
    function configureCore(PoolKey calldata key, CoreParams calldata params) external onlyHookOwner {
        if (
            address(key.hooks) != address(this) || params.depthPerShare == 0 || params.depthMax == 0
                || params.depthMax >= 2 ** 95 || params.baseSpreadPips >= _PIPS || params.minEdgePips >= _PIPS
                || params.maxSpreadPips >= _PIPS || params.maxDeviationPips >= _PIPS
        ) revert InvalidCoreConfig();
        PoolId id = key.toId();
        coreParams[id] = params;
        emit CoreConfigured(id, params);
    }

    /// @notice Callbacks this hook needs: beforeSwap, beforeSwapReturnDelta and beforeAddLiquidity.
    /// @return p Permission flags; every flag not set here must be clear in the hook's address.
    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeAddLiquidity = true;
        p.beforeSwap = true;
        p.beforeSwapReturnDelta = true;
    }

    /// @notice Strategy-specific pricing: output owed for `amountIn` of input on this pool right now, and the pricing
    ///         state the hook will store if the swap succeeds.
    /// @dev A view: it must not write the state, because the vault may still reject the trade. Implementations may
    ///      revert to refuse a trade. They do not need to check the vault's price floor or quota: `exchange` enforces
    ///      both on the exact amounts, so a quote that is too generous to the swapper simply makes the swap revert.
    /// @param id Pool being swapped on.
    /// @param zeroForOne True if the swapper sells currency0.
    /// @param amountIn Raw input amount, at most 2^127 - 1.
    /// @return amountOut Raw output to request from the vault.
    /// @return newState Hook-defined encoding of the pricing state after this trade, passed back to `_commit`.
    function _quote(PoolId id, bool zeroForOne, uint256 amountIn)
        internal
        view
        virtual
        returns (uint256 amountOut, uint256 newState);

    /// @notice Strategy pricing in shared-core mode: output for `amountIn` given the core state, and the strategy state
    ///         to store if the swap succeeds.
    /// @dev A view, like `_quote`. The core already includes the reference, the vault's inventory and the band.
    /// @param id Pool being swapped on.
    /// @param core Core state built by `_coreState` for this swap.
    /// @param zeroForOne True if the swapper sells currency0.
    /// @param amountIn Raw input amount, at most 2^127 - 1.
    /// @return amountOut Raw output to request from the vault.
    /// @return newState Strategy state after this trade, passed to `_commitCore`.
    function _quoteCore(PoolId id, InventoryPricing.Core memory core, bool zeroForOne, uint256 amountIn)
        internal
        view
        virtual
        returns (uint256 amountOut, uint256 newState);

    /// @notice Store the strategy state `_quoteCore` computed, after the vault has filled the trade.
    /// @dev Default: no strategy state.
    function _commitCore(PoolId id, bool zeroForOne, uint256 newState) internal virtual {}

    /// @notice Shared-core state for one swap, or `coreMode = false` when the vault has no adapter (static mode).
    /// @dev Two external reads: `vault.coreInputs()` (the adapter, the vault's edge, kappa_1, tau_1, net asset1 holding
    ///      N1 = B1 - W1 and share supply S, in one call), then the adapter's reading. N1 is the vault's asset1; a pool
    ///      whose currency1 is not the vault's asset1 can never be filled (the vault checks the pair on every fill).
    ///      The adapter's revert (stale, contradictory or unavailable sources) reverts the swap. The vault re-reads the
    ///      adapter itself inside `exchange` and enforces its own floor, so the hook adds no validity checks of its own
    ///      beyond what `InventoryPricing.coreState` requires (spread at most maxSpread, non-zero depth).
    /// @param id Pool being priced.
    /// @return coreMode True when the vault has an adapter.
    /// @return core The core state; meaningless when `coreMode` is false.
    function _coreState(PoolId id) internal view returns (bool coreMode, InventoryPricing.Core memory core) {
        (IMarketRiskAdapter adapter, uint256 edge, uint256 maxDeviation, uint256 target1, uint256 n1, uint256 shares) =
            IVaultState(address(vault)).coreInputs();
        if (address(adapter) == address(0)) return (false, core);
        CoreParams memory p = coreParams[id];
        if (p.depthPerShare == 0) revert CoreNotConfigured();
        IMarketRiskAdapter.Reading memory r = adapter.currentReference();
        if (p.maxDeviationPips < maxDeviation) maxDeviation = p.maxDeviationPips;
        uint256 minEdge = edge + 1;
        if (p.minEdgePips > minEdge) minEdge = p.minEdgePips;
        InventoryPricing.Config memory cfg = InventoryPricing.Config({
            targetPerShare: target1,
            depthPerShare: p.depthPerShare,
            depthMax: p.depthMax,
            baseSpread: p.baseSpreadPips,
            minEdge: minEdge,
            maxSpread: p.maxSpreadPips,
            maxDeviation: maxDeviation,
            bandEdge: true
        });
        core = InventoryPricing.coreState(cfg, n1, shares, r.priceX96, r.uncertaintyPips);
        coreMode = true;
    }

    /// @notice Output for `amountIn` in whichever mode the vault is in, and the state to commit.
    /// @dev Used by `beforeSwap` and by the concrete hooks' `quote` views, so a quote and a swap in the same block
    ///      price identically.
    function _quoteAny(PoolId id, bool zeroForOne, uint256 amountIn)
        internal
        view
        returns (bool coreMode, uint256 amountOut, uint256 newState)
    {
        InventoryPricing.Core memory core;
        (coreMode, core) = _coreState(id);
        (amountOut, newState) = coreMode ? _quoteCore(id, core, zeroForOne, amountIn) : _quote(id, zeroForOne, amountIn);
    }

    /// @notice Store the pricing state `_quote` computed, after the vault has filled the trade.
    /// @param id Pool the swap ran on.
    /// @param zeroForOne True if the swapper sold currency0.
    /// @param newState The value `_quote` returned for this swap.
    function _commit(PoolId id, bool zeroForOne, uint256 newState) internal virtual;

    /// @notice Output at a fixed reference price before any fee or impact, rounded down in favour of the vault.
    /// @dev Selling currency0: amountIn * price / 2^96. Selling currency1: amountIn * 2^96 / price. FullMath keeps
    ///      the intermediate product in 512 bits. Example with price = 2 * 2^96 (2 raw currency1 per raw currency0):
    ///      1,000 currency0 in gives 2,000 currency1; 1,001 currency1 in gives floor(500.5) = 500 currency0.
    /// @param priceX96 Raw currency1 per raw currency0, Q64.96. Must be non-zero.
    /// @param zeroForOne True if the input is currency0.
    /// @param amountIn Raw input amount.
    /// @return Raw output amount at the reference price.
    function _grossOut(uint160 priceX96, bool zeroForOne, uint256 amountIn) internal pure returns (uint256) {
        return zeroForOne
            ? FullMath.mulDiv(amountIn, priceX96, FixedPoint96.Q96)
            : FullMath.mulDiv(amountIn, FixedPoint96.Q96, priceX96);
    }

    // ------------------------------------------------------------------
    // Active callbacks
    // ------------------------------------------------------------------

    /// @notice Fills the whole swap from the vault and tells the PoolManager to skip the pool's own curve.
    /// @dev See the contract documentation for the four settlement steps and why the deltas net to zero.
    ///      Rejects exact-output swaps, zero-amount swaps, inputs above 2^127 - 1, `hookData` that is not 32 or 64
    ///      bytes, quotes of zero and quotes below the swapper's minimum. Every vault-side rule (registration,
    ///      allocation binding, expiry, quota, price floor, flow and exposure limits, pause, halt) is enforced inside
    ///      `vault.exchange`; any failure there reverts the swap. The pricing state is stored after `exchange`
    ///      returns.
    /// @param key Pool being swapped on.
    /// @param params Swap parameters. `amountSpecified` must be negative (exact input). `sqrtPriceLimitX96` is
    ///        ignored (see the contract documentation).
    /// @param hookData abi.encode(uint256 allocationId) or abi.encode(uint256 allocationId, uint256 minAmountOut).
    /// @return Selector confirming the call.
    /// @return Hook delta (+amountIn specified, -amountOut unspecified).
    /// @return LP fee override; always 0 (unused, the pool's curve does not run).
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (params.amountSpecified >= 0) {
            if (params.amountSpecified == 0) revert ZeroInput();
            revert ExactOutputNotSupported();
        }
        // Bound before negation: avoids int256.min overflow and keeps the value castable to int128.
        // forge-lint: disable-next-line(unsafe-typecast) MAX_AMOUNT = 2^127-1 fits in int256.
        if (params.amountSpecified < -int256(MAX_AMOUNT)) revert AmountTooLarge();

        uint256 allocationId;
        uint256 minAmountOut;
        if (hookData.length == 32) {
            allocationId = abi.decode(hookData, (uint256));
        } else if (hookData.length == 64) {
            (allocationId, minAmountOut) = abi.decode(hookData, (uint256, uint256));
        } else {
            revert InvalidHookData();
        }

        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 amountOut = _fill(key, params.zeroForOne, amountIn, allocationId, minAmountOut);

        // 4. Hand both deltas to the swapper; the hook's own deltas return to zero.
        // Both casts are safe: amountIn, amountOut <= int128.max.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(amountIn)), -int128(int256(amountOut))), 0);
    }

    /// @dev Steps 1-3 of the swap flow (see the contract documentation) and the state update: price in the vault's
    ///      current mode, check the swapper's minimum, mint the input claims, let the vault fill, burn the output
    ///      claims, store the pricing state. Split out of `beforeSwap` only to keep the compiler's stack within limits.
    function _fill(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 allocationId, uint256 minAmountOut)
        internal
        returns (uint256 amountOut)
    {
        PoolId id = key.toId();

        bool coreMode;
        uint256 newState;
        (coreMode, amountOut, newState) = _quoteAny(id, zeroForOne, amountIn);
        if (amountOut == 0) revert ZeroOutput();
        if (amountOut > MAX_AMOUNT) revert AmountTooLarge();
        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);

        (Currency cin, Currency cout) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        // 1. Mint the swapper's input as claims to this hook: hook delta[in] = -amountIn.
        poolManager.mint(address(this), cin.toId(), amountIn);
        // 2. Vault pulls those input claims and sends output claims, or reverts the whole swap.
        vault.exchange(key, zeroForOne, allocationId, amountIn, amountOut);
        // 3. Burn the output claims: hook delta[out] = +amountOut.
        poolManager.burn(address(this), cout.toId(), amountOut);
        // The vault has filled the trade: store the pricing state it was quoted from.
        if (coreMode) _commitCore(id, zeroForOne, newState);
        else _commit(id, zeroForOne, newState);

        emit SharedLiquiditySwap(id, allocationId, zeroForOne, amountIn, amountOut);
    }

    /// @notice Always reverts: liquidity added to the pool's curve could never be traded, because every swap is
    ///         filled by the vault before the curve runs.
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert NativeLiquidityDisabled();
    }

    // ------------------------------------------------------------------
    // Disabled callbacks (permission bits are not set; PoolManager never calls these)
    // ------------------------------------------------------------------

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
