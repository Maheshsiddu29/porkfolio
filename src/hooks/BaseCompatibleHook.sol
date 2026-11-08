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

/// @title BaseCompatibleHook
/// @notice Shared swap plumbing for hooks that fill every swap on their pool from the SharedCommitmentVault instead
///         of from pool liquidity. A concrete hook only supplies the price (`_quote`).
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
///      Who chooses the allocation. The swapper passes the allocation id as `hookData`. Any swapper may use any
///      allocation made out to this hook for this pool: an allocation reserves capacity for the hook, not for a
///      trader. The vault decides whether the trade is allowed.
///
///      Limits of this design. Only exact-input swaps are supported. The swap's `sqrtPriceLimitX96` is not enforced,
///      because the pool's curve never runs, so swappers must protect themselves with a minimum-output check in their
///      router. The pool's LP fee setting is never applied.
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
    address public immutable hookOwner;

    /// @notice A hook callback was called by something other than the PoolManager.
    error NotPoolManager();
    /// @notice A configuration function was called by someone other than `hookOwner`.
    error NotHookOwner();
    /// @notice A callback whose permission bit is not set was called directly. The PoolManager never calls these.
    error HookNotImplemented();
    /// @notice Adding liquidity to the pool's own curve is refused; this pool trades only against the vault.
    error NativeLiquidityDisabled();
    /// @notice The swap was exact output (or had amountSpecified == 0). Only exact input is supported.
    error ExactOutputNotSupported();
    /// @notice The input or the quoted output exceeds 2^127 - 1.
    error AmountTooLarge();
    /// @notice `hookData` was not exactly one ABI-encoded uint256 allocation id.
    error InvalidHookData();
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

    /// @dev Reverts unless this contract's address encodes exactly the permissions in `getHookPermissions`, because
    ///      the PoolManager decides which callbacks to call from the address bits alone. Then makes the vault an
    ///      operator over this hook's claims (see the contract documentation for why this direction is safe).
    /// @param poolManager_ PoolManager the hook's pools live in.
    /// @param vault_ Vault that fills the swaps.
    /// @param hookOwner_ Account that may configure pricing.
    constructor(IPoolManager poolManager_, ISharedCommitmentVault vault_, address hookOwner_) {
        poolManager = poolManager_;
        vault = vault_;
        hookOwner = hookOwner_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        // The vault may pull the hook's *own* transient input claims. The reverse (hook over vault) is never granted.
        poolManager_.setOperator(address(vault_), true);
    }

    /// @notice Callbacks this hook needs: beforeSwap, beforeSwapReturnDelta and beforeAddLiquidity.
    /// @return p Permission flags; every flag not set here must be clear in the hook's address.
    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeAddLiquidity = true;
        p.beforeSwap = true;
        p.beforeSwapReturnDelta = true;
    }

    /// @notice Strategy-specific pricing: output owed for `amountIn` of input on this pool and allocation.
    /// @dev Implementations may read the allocation from the vault to adjust the price, and may revert to refuse a
    ///      trade. They do not need to check the vault's price floor or quota: `exchange` enforces both on the exact
    ///      amounts, so a quote that is too generous to the swapper simply makes the swap revert.
    /// @param key Pool being swapped on.
    /// @param zeroForOne True if the swapper sells currency0.
    /// @param amountIn Raw input amount.
    /// @param allocationId Allocation the swapper chose.
    /// @return amountOut Raw output to request from the vault.
    function _quote(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 allocationId)
        internal
        view
        virtual
        returns (uint256 amountOut);

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
    ///      Rejects exact-output swaps, inputs above 2^127 - 1, `hookData` that is not exactly 32 bytes, and quotes
    ///      of zero. Every vault-side rule (registration, allocation binding, expiry, quota, price floor, pause, halt)
    ///      is enforced inside `vault.exchange`; any failure there reverts the swap.
    /// @param key Pool being swapped on.
    /// @param params Swap parameters. `amountSpecified` must be negative (exact input).
    /// @param hookData abi.encode(uint256 allocationId).
    /// @return Selector confirming the call.
    /// @return Hook delta (+amountIn specified, -amountOut unspecified).
    /// @return LP fee override; always 0 (unused, the pool's curve does not run).
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (params.amountSpecified >= 0) revert ExactOutputNotSupported();
        // Bound before negation: avoids int256.min overflow and keeps the value castable to int128.
        // forge-lint: disable-next-line(unsafe-typecast) MAX_AMOUNT = 2^127-1 fits in int256.
        if (params.amountSpecified < -int256(MAX_AMOUNT)) revert AmountTooLarge();
        if (hookData.length != 32) revert InvalidHookData();

        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 allocationId = abi.decode(hookData, (uint256));

        uint256 amountOut = _quote(key, params.zeroForOne, amountIn, allocationId);
        if (amountOut == 0) revert ZeroOutput();
        if (amountOut > MAX_AMOUNT) revert AmountTooLarge();

        (Currency cin, Currency cout) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        // 1. Mint the swapper's input as claims to this hook: hook delta[in] = -amountIn.
        poolManager.mint(address(this), cin.toId(), amountIn);
        // 2. Vault pulls those input claims and sends output claims, or reverts the whole swap.
        vault.exchange(key, params.zeroForOne, allocationId, amountIn, amountOut);
        // 3. Burn the output claims: hook delta[out] = +amountOut.
        poolManager.burn(address(this), cout.toId(), amountOut);

        emit SharedLiquiditySwap(key.toId(), allocationId, params.zeroForOne, amountIn, amountOut);

        // 4. Hand both deltas to the swapper; the hook's own deltas return to zero.
        // Both casts are safe: amountIn, amountOut <= int128.max.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(amountIn)), -int128(int256(amountOut))), 0);
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
