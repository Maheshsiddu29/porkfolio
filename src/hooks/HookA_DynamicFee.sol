// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {ISharedCommitmentVault} from "../interfaces/ISharedCommitmentVault.sol";
import {BaseCompatibleHook} from "./BaseCompatibleHook.sol";

/// @title HookA_DynamicFee
/// @notice Sells vault liquidity at a fixed reference price minus a fee that grows as the allocation is used up.
/// @dev Pricing, per swap:
///        gross = amountIn converted at the pool's reference price, rounded down (`_grossOut`)
///        u     = min(1, (consumed + gross) / maxOut), in pips, rounded up        (post-trade utilisation)
///        fee   = baseFeePips + ceil((maxFeePips - baseFeePips) * u)              (linear in u)
///        out   = floor(gross * (1,000,000 - fee) / 1,000,000)
///
///      Every rounding step goes against the swapper, so rounding never costs the vault. Example: base 500 pips
///      (0.05%), max 5,000 pips (0.5%), allocation maxOut 10,000, nothing consumed, 1:1 reference price.
///      Selling 1,000 gives gross 1,000 and u = 10%, so fee = 500 + 4,500 * 0.1 = 950 pips and out = 999.05.
///
///      Why the fee rises with utilisation: the less capacity an allocation has left, the scarcer that inventory is
///      for later trades, so the last units are sold at a higher spread. The fee is kept by the vault (the swapper
///      receives less output for the same input), so it accrues to all LP shares.
///
///      Properties worth knowing:
///      - u is measured with the gross amount, before the fee, while the vault records the smaller net output as
///        consumed. This slightly overstates utilisation, which again favours the vault.
///      - The fee depends on how trades are split, not just their total. Splitting one trade into several smaller
///        ones never pays more in total and usually pays less, because the earlier pieces are charged at lower
///        utilisation.
///      - An unknown allocation id reads as maxOut = 0 and is charged the maximum fee; the vault then rejects it.
///      - The reference price is set by `hookOwner` and does not follow the market. The vault's price floor is the
///        only protection LPs have against a stale or wrong price, and it only bounds how bad a trade can be.
///
///      This is not a v4 dynamic LP fee. The pool's curve never runs, so the pool's fee setting (including any
///      dynamic-fee override) is never applied; this fee exists only in the quote.
contract HookA_DynamicFee is BaseCompatibleHook {
    /// @dev Fee and utilisation unit: 1,000,000 pips = 100%, so 1 pip = 0.0001%.
    uint256 internal constant PIPS = 1_000_000;

    /// @notice Pricing parameters for one pool.
    /// @param priceX96 Reference price: raw currency1 per raw currency0, Q64.96. Zero means not configured.
    /// @param baseFeePips Fee charged at zero utilisation.
    /// @param maxFeePips Fee charged at full utilisation. Must be at least `baseFeePips` and below 100%.
    struct PoolConfig {
        uint160 priceX96;
        uint24 baseFeePips;
        uint24 maxFeePips;
    }

    /// @notice Pricing parameters by pool id.
    mapping(PoolId => PoolConfig) public poolConfig;

    /// @notice The pool has no reference price configured, so it cannot be quoted.
    error PoolNotConfigured();
    /// @notice `configurePool` was called with a key for another hook, a zero price, base > max, or max >= 100%.
    error InvalidConfig();

    /// @notice A pool's pricing parameters were set or replaced.
    event PoolConfigured(PoolId indexed poolId, uint160 priceX96, uint24 baseFeePips, uint24 maxFeePips);

    /// @param poolManager_ PoolManager the hook's pools live in.
    /// @param vault_ Vault that fills the swaps.
    /// @param hookOwner_ Account that may configure pricing.
    constructor(IPoolManager poolManager_, ISharedCommitmentVault vault_, address hookOwner_)
        BaseCompatibleHook(poolManager_, vault_, hookOwner_)
    {}

    /// @notice Set or replace the pricing parameters for one of this hook's pools.
    /// @dev Only `hookOwner`. Takes effect on the next swap, including for allocations made earlier. `maxFeePips`
    ///      below 100% keeps every quote above zero for large enough inputs.
    /// @param key Pool to configure. `key.hooks` must be this contract.
    /// @param priceX96 Reference price, raw currency1 per raw currency0, Q64.96. Non-zero.
    /// @param baseFeePips Fee at zero utilisation, in pips.
    /// @param maxFeePips Fee at full utilisation, in pips. At least `baseFeePips` and below 1,000,000.
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

    /// @notice Fee a trade of `amountIn` would pay right now, and its output before the fee.
    /// @dev Reads the allocation's current `consumed` and `maxOut` from the vault. Reverts with `PoolNotConfigured`
    ///      if the pool has no reference price.
    /// @param key Pool being quoted.
    /// @param zeroForOne True if the swapper sells currency0.
    /// @param amountIn Raw input amount.
    /// @param allocationId Allocation the trade would consume.
    /// @return feePips Fee in pips, between baseFeePips and maxFeePips.
    /// @return gross Raw output at the reference price before the fee.
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

    /// @notice Output a swap of `amountIn` would receive right now, before any vault check.
    /// @dev The vault can still reject the swap (price floor, quota, expiry, pause, halt). Useful for routers that
    ///      compute a minimum-output bound.
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

    /// @dev out = floor(gross * (PIPS - fee) / PIPS). fee < PIPS, and gross * PIPS stays far below 2^256 for any
    ///      input up to 2^127 and any uint160 price.
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
