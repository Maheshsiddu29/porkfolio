// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {ISharedCommitmentVault} from "../interfaces/ISharedCommitmentVault.sol";
import {BaseCompatibleHook} from "./BaseCompatibleHook.sol";

/// @title HookB_BoundedImpact (Milestone 0)
/// @notice Sells vault liquidity at a fixed reference price with a linear price impact proportional to the
///         trade's share of the allocation's *remaining* capacity:
///             impact = ceil(impactAtFull * gross / remaining)
///         Trades whose impact would exceed `maxImpactPips` revert instead of executing at a worse price.
contract HookB_BoundedImpact is BaseCompatibleHook {
    uint256 internal constant PIPS = 1_000_000;

    struct PoolConfig {
        uint160 priceX96;
        uint24 impactPipsAtFullQuota;
        uint24 maxImpactPips;
    }

    mapping(PoolId => PoolConfig) public poolConfig;

    error PoolNotConfigured();
    error InvalidConfig();
    error ImpactBoundExceeded(uint256 impactPips, uint256 maxImpactPips);

    event PoolConfigured(PoolId indexed poolId, uint160 priceX96, uint24 impactPipsAtFullQuota, uint24 maxImpactPips);

    constructor(IPoolManager poolManager_, ISharedCommitmentVault vault_, address hookOwner_)
        BaseCompatibleHook(poolManager_, vault_, hookOwner_)
    {}

    function configurePool(PoolKey calldata key, uint160 priceX96, uint24 impactPipsAtFullQuota, uint24 maxImpactPips)
        external
        onlyHookOwner
    {
        if (address(key.hooks) != address(this)) revert InvalidConfig();
        if (priceX96 == 0 || maxImpactPips >= PIPS) revert InvalidConfig();
        PoolId id = key.toId();
        poolConfig[id] = PoolConfig(priceX96, impactPipsAtFullQuota, maxImpactPips);
        emit PoolConfigured(id, priceX96, impactPipsAtFullQuota, maxImpactPips);
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
        PoolConfig memory cfg = poolConfig[key.toId()];
        if (cfg.priceX96 == 0) revert PoolNotConfigured();
        uint256 gross = _grossOut(cfg.priceX96, zeroForOne, amountIn);

        ISharedCommitmentVault.Allocation memory a = vault.getAllocation(allocationId);
        uint256 remaining = a.maxOut - a.consumed;
        // Unknown or exhausted allocation: defer the authoritative rejection to the vault.
        if (remaining == 0) return gross;

        uint256 impactPips = FullMath.mulDivRoundingUp(gross, cfg.impactPipsAtFullQuota, remaining);
        if (impactPips > cfg.maxImpactPips) revert ImpactBoundExceeded(impactPips, cfg.maxImpactPips);
        return gross * (PIPS - impactPips) / PIPS;
    }
}
