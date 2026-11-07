// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {ISharedCommitmentVault} from "../interfaces/ISharedCommitmentVault.sol";
import {BaseCompatibleHook} from "./BaseCompatibleHook.sol";

/// @title HookA_DynamicFee (Milestone 0)
/// @notice Sells vault liquidity at a fixed reference price minus a fee that rises linearly with the
///         allocation's post-trade utilisation u = min(1, (consumed + gross) / maxOut):
///             fee = base + (max - base) * u      (u and the fee term both rounded up, favouring the vault)
/// @dev Because the hook consumes the full specified amount, the pool's own LP fee (and any
///      LPFeeLibrary.OVERRIDE_FEE_FLAG override) is never applied — the dynamic fee lives in this curve.
contract HookA_DynamicFee is BaseCompatibleHook {
    uint256 internal constant PIPS = 1_000_000;

    struct PoolConfig {
        uint160 priceX96;
        uint24 baseFeePips;
        uint24 maxFeePips;
    }

    mapping(PoolId => PoolConfig) public poolConfig;

    error PoolNotConfigured();
    error InvalidConfig();

    event PoolConfigured(PoolId indexed poolId, uint160 priceX96, uint24 baseFeePips, uint24 maxFeePips);

    constructor(IPoolManager poolManager_, ISharedCommitmentVault vault_, address hookOwner_)
        BaseCompatibleHook(poolManager_, vault_, hookOwner_)
    {}

    function configurePool(PoolKey calldata key, uint160 priceX96, uint24 baseFeePips, uint24 maxFeePips)
        external
        onlyHookOwner
    {
        if (address(key.hooks) != address(this)) revert InvalidConfig();
        if (priceX96 == 0 || baseFeePips > maxFeePips || maxFeePips >= PIPS) revert InvalidConfig();
        PoolId id = key.toId();
        poolConfig[id] = PoolConfig(priceX96, baseFeePips, maxFeePips);
        emit PoolConfigured(id, priceX96, baseFeePips, maxFeePips);
    }

    /// @notice Current fee (pips) that a trade of `amountIn` would pay.
    function feeFor(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 allocationId)
        public
        view
        returns (uint256 feePips, uint256 gross)
    {
        PoolConfig memory cfg = poolConfig[key.toId()];
        if (cfg.priceX96 == 0) revert PoolNotConfigured();
        gross = _grossOut(cfg.priceX96, zeroForOne, amountIn);

        ISharedCommitmentVault.Allocation memory a = vault.getAllocation(allocationId);
        // Utilisation and fee both round UP so that rounding always favours the vault.
        uint256 utilPips = a.maxOut == 0 ? PIPS : FullMath.mulDivRoundingUp(uint256(a.consumed) + gross, PIPS, a.maxOut);
        if (utilPips > PIPS) utilPips = PIPS;
        feePips = cfg.baseFeePips + FullMath.mulDivRoundingUp(cfg.maxFeePips - cfg.baseFeePips, utilPips, PIPS);
    }

    function quote(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 allocationId)
        external
        view
        returns (uint256)
    {
        return _quote(key, zeroForOne, amountIn, allocationId);
    }

    function _quote(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 allocationId)
        internal
        view
        override
        returns (uint256)
    {
        (uint256 feePips, uint256 gross) = feeFor(key, zeroForOne, amountIn, allocationId);
        return gross * (PIPS - feePips) / PIPS;
    }
}
