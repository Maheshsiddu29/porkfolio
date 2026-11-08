// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {ISharedCommitmentVault} from "../interfaces/ISharedCommitmentVault.sol";
import {BaseCompatibleHook} from "./BaseCompatibleHook.sol";

/// @title HookB_BoundedImpact
/// @notice Sells vault liquidity at a fixed reference price minus a price impact proportional to how much of the
///         allocation's remaining capacity the trade uses, and refuses trades whose impact would exceed a cap.
/// @dev Pricing, per swap:
///        gross     = amountIn converted at the pool's reference price, rounded down (`_grossOut`)
///        remaining = allocation maxOut - consumed
///        impact    = ceil(impactPipsAtFullQuota * gross / remaining)      (pips)
///        out       = floor(gross * (1,000,000 - impact) / 1,000,000)      if impact <= maxImpactPips, else revert
///
///      `impactPipsAtFullQuota` is the impact of a trade whose gross output equals all remaining capacity.
///      Example: impactPipsAtFullQuota = 10,000 (1%), maxImpactPips = 20,000 (2%), remaining 10,000, 1:1 price.
///      Selling 1,000 gives impact = ceil(10,000 * 1,000 / 10,000) = 1,000 pips (0.1%) and out = 999. With only
///      1,000 remaining, selling 2,001 would need 20,010 pips and reverts with `ImpactBoundExceeded`.
///
///      How it differs from HookA: HookA charges according to how full the allocation will be after the trade.
///      HookB charges according to the size of this trade relative to what is left, and caps that charge by
///      refusing the trade rather than executing it at a worse price. Like HookA, every rounding step goes against
///      the swapper, and the impact is kept by the vault.
///
///      Properties worth knowing:
///      - Impact is computed per trade, not cumulatively. Splitting a trade into n equal pieces cuts the impact
///        rate on each piece by roughly n (remaining capacity shrinks a little between pieces), so the total
///        impact paid falls. The cap therefore limits the size of a single trade, not total flow; total flow is
///        limited by the allocation's quota in the vault.
///      - If impactPipsAtFullQuota <= maxImpactPips, the cap never rejects a trade whose gross output fits the
///        remaining capacity; it can only reject trades whose gross output exceeds what is left. The cap limits
///        trade size within the remaining capacity only when impactPipsAtFullQuota > maxImpactPips.
///      - If the allocation has no remaining capacity (exhausted or unknown id) the hook quotes `gross` and lets
///        the vault reject the swap with its own, more precise error.
///      - The reference price is set by `hookOwner` and does not follow the market. The vault's price floor is the
///        only protection LPs have against a stale or wrong price.
contract HookB_BoundedImpact is BaseCompatibleHook {
    /// @dev Impact unit: 1,000,000 pips = 100%, so 1 pip = 0.0001%.
    uint256 internal constant PIPS = 1_000_000;

    /// @notice Pricing parameters for one pool.
    /// @param priceX96 Reference price: raw currency1 per raw currency0, Q64.96. Zero means not configured.
    /// @param impactPipsAtFullQuota Impact, in pips, of a trade whose gross output equals the remaining capacity.
    /// @param maxImpactPips Largest impact accepted; larger trades revert. Below 100%.
    struct PoolConfig {
        uint160 priceX96;
        uint24 impactPipsAtFullQuota;
        uint24 maxImpactPips;
    }

    /// @notice Pricing parameters by pool id.
    mapping(PoolId => PoolConfig) public poolConfig;

    /// @notice The pool has no reference price configured, so it cannot be quoted.
    error PoolNotConfigured();
    /// @notice `configurePool` was called with a key for another hook, a zero price, or maxImpactPips >= 100%.
    error InvalidConfig();
    /// @notice The trade is too large relative to the allocation's remaining capacity.
    error ImpactBoundExceeded(uint256 impactPips, uint256 maxImpactPips);

    /// @notice A pool's pricing parameters were set or replaced.
    event PoolConfigured(PoolId indexed poolId, uint160 priceX96, uint24 impactPipsAtFullQuota, uint24 maxImpactPips);

    /// @param poolManager_ PoolManager the hook's pools live in.
    /// @param vault_ Vault that fills the swaps.
    /// @param hookOwner_ Account that may configure pricing.
    constructor(IPoolManager poolManager_, ISharedCommitmentVault vault_, address hookOwner_)
        BaseCompatibleHook(poolManager_, vault_, hookOwner_)
    {}

    /// @notice Set or replace the pricing parameters for one of this hook's pools.
    /// @dev Only `hookOwner`. Takes effect on the next swap, including for allocations made earlier.
    ///      `maxImpactPips` below 100% guarantees PIPS - impact never underflows in `_quote`.
    /// @param key Pool to configure. `key.hooks` must be this contract.
    /// @param priceX96 Reference price, raw currency1 per raw currency0, Q64.96. Non-zero.
    /// @param impactPipsAtFullQuota Impact, in pips, of a trade that uses all remaining capacity.
    /// @param maxImpactPips Largest impact accepted, in pips. Below 1,000,000.
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

    /// @notice Output a swap of `amountIn` would receive right now, before any vault check.
    /// @dev Reverts with `ImpactBoundExceeded` if the trade is too large. The vault can still reject the swap
    ///      (price floor, quota, expiry, pause, halt).
    /// @param key Pool being quoted.
    /// @param zeroForOne True if the swapper sells currency0.
    /// @param amountIn Raw input amount.
    /// @param allocationId Allocation the trade would consume.
    /// @return Raw output amount.
    function quote(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 allocationId)
        external
        view
        returns (uint256)
    {
        return _quote(key, zeroForOne, amountIn, allocationId);
    }

    /// @dev See the contract documentation for the formula. Rounding: gross down, impact up, output down.
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
