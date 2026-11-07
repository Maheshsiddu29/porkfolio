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

/// @title BaseCompatibleHook (Milestone 0)
/// @notice Common custom-accounting integration for hooks that sell vault liquidity via beforeSwapReturnDelta.
///
/// Settlement sequence inside `beforeSwap` (exact input, amountSpecified = -X):
///   1. poolManager.mint(this, in, X)        hook delta[in]  -= X   (hook now holds X input claims)
///   2. vault.exchange(..., X, Y)            vault pulls X input claims, pushes Y output claims (ERC-6909 only)
///   3. poolManager.burn(this, out, Y)       hook delta[out] += Y
///   4. return BeforeSwapDelta(+X, -Y)       PoolManager adds hookDelta: delta[in] += X, delta[out] -= Y
///   => hook ends at zero in both currencies; the swapper owes X input and is owed Y output.
///   amountToSwap becomes 0, so the pool's concentrated-liquidity curve is not executed at all.
///
/// Permissions: beforeSwap, beforeSwapReturnDelta, beforeAddLiquidity (to reject native liquidity, which
/// could never be traded because every swap is intercepted).
abstract contract BaseCompatibleHook is IHooks {
    uint256 internal constant MAX_AMOUNT = uint256(uint128(type(int128).max));

    IPoolManager public immutable poolManager;
    ISharedCommitmentVault public immutable vault;
    address public immutable hookOwner;

    error NotPoolManager();
    error NotHookOwner();
    error HookNotImplemented();
    error NativeLiquidityDisabled();
    error ExactOutputNotSupported();
    error AmountTooLarge();
    error InvalidHookData();
    error ZeroOutput();

    event SharedLiquiditySwap(
        PoolId indexed poolId, uint256 indexed allocationId, bool zeroForOne, uint256 amountIn, uint256 amountOut
    );

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyHookOwner() {
        if (msg.sender != hookOwner) revert NotHookOwner();
        _;
    }

    constructor(IPoolManager poolManager_, ISharedCommitmentVault vault_, address hookOwner_) {
        poolManager = poolManager_;
        vault = vault_;
        hookOwner = hookOwner_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        // The vault may pull the hook's *own* transient input claims. The reverse (hook over vault) is never granted.
        poolManager_.setOperator(address(vault_), true);
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeAddLiquidity = true;
        p.beforeSwap = true;
        p.beforeSwapReturnDelta = true;
    }

    /// @notice Strategy-specific pricing: output owed for `amountIn` of input on this pool/allocation.
    function _quote(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 allocationId)
        internal
        view
        virtual
        returns (uint256 amountOut);

    /// @notice Gross output at a fixed reference price, rounded down (in favour of the vault).
    /// @param priceX96 amount of currency1 per unit of currency0, Q64.96.
    function _grossOut(uint160 priceX96, bool zeroForOne, uint256 amountIn) internal pure returns (uint256) {
        return zeroForOne
            ? FullMath.mulDiv(amountIn, priceX96, FixedPoint96.Q96)
            : FullMath.mulDiv(amountIn, FixedPoint96.Q96, priceX96);
    }

    // ------------------------------------------------------------------
    // Active callbacks
    // ------------------------------------------------------------------

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

        poolManager.mint(address(this), cin.toId(), amountIn);
        vault.exchange(key, params.zeroForOne, allocationId, amountIn, amountOut);
        poolManager.burn(address(this), cout.toId(), amountOut);

        emit SharedLiquiditySwap(key.toId(), allocationId, params.zeroForOne, amountIn, amountOut);

        // Both casts are safe: amountIn, amountOut <= int128.max.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(amountIn)), -int128(int256(amountOut))), 0);
    }

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
