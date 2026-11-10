// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ISharedCommitmentVault} from "../interfaces/ISharedCommitmentVault.sol";
import {BaseCompatibleHook} from "./BaseCompatibleHook.sol";
import {CumulativePricing} from "./CumulativePricing.sol";

/// @title HookA_DynamicFee
/// @notice Sells vault liquidity at a fixed reference price, charging a fee whose rate rises with the recent flow
///         through the pool in the trade's direction.
/// @dev State. One flow level per pool and direction: the gross input swapped in that direction, in raw units of
///      that direction's input currency, decaying linearly toward zero over time. The two directions are independent:
///      selling currency0 never lowers the level for selling currency1, so a round trip pays both fees. The level does
///      not depend on which allocation or curator fills the trade.
///
///      Fee. The marginal fee rate at level `u` is `base + (max - base) * min(1, u / K)` pips, where `K` is the
///      direction's scale. A trade that moves the level from `s` to `s + amountIn` pays the integral of that rate over
///      the trade, as one fixed integer function of the level (`CumulativePricing.cumulativeFee`, rounded up):
///
///        fee = F_hat(s + amountIn) - F_hat(s)                       raw input units, <= amountIn
///        out = (amountIn - fee) converted at the reference price, rounded down (`_grossOut`)
///
///      Why this resists splitting. The fees of the pieces telescope: n pieces from `s` pay exactly
///      `F_hat(s + total) - F_hat(s)`, the same as one trade. The only difference is the final conversion, rounded
///      down once per piece, so a split receives at most n - 1 raw output units less than one trade and never more.
///      Example, 1:1 price, base 500 pips (0.05%), max 5,000 pips (0.5%), K = 10,000, level 0: 8,000 in pays
///      4 + 14.4 = 18.4 in fees as one trade, as 8 trades or as 1,000 trades. The fee is kept by the vault (the
///      swapper receives less output for the same input), so it accrues to all LP shares.
///
///      Decay. The level falls by `K * elapsed / decayWindow` (rounded down), never below zero: a level of `K` (the
///      level at which the rate reaches `max`) returns to zero after `decayWindow` seconds without trading. Waiting is
///      therefore the only way to pay a lower rate, and it lowers the rate for everyone. `decayWindow = 0` disables
///      decay. The level is in storage, so splitting across transactions at the same timestamp changes nothing.
///
///      Parameters. `configurePool` applies the decay elapsed under the old parameters to both directions and keeps
///      the levels. New fees, scales, window and price apply from the next swap. A smaller `K` or higher fees raise
///      the next trade's fee; a larger `K` or lower fees lower it. `hookOwner` is trusted; nothing delays a loosening
///      change.
///
///      Not handled here. The reference price does not follow the market, and the fee never exceeds `max`, so a market
///      move larger than the fee lets arbitrageurs trade until the vault's price floor, quota or flow limits stop them.
///      This is not a v4 dynamic LP fee: the pool's curve never runs, so the pool's fee setting is never applied.
contract HookA_DynamicFee is BaseCompatibleHook {
    /// @dev Fee unit: 1,000,000 pips = 100%.
    uint256 internal constant PIPS = 1_000_000;

    /// @notice Pricing parameters for one pool.
    /// @param priceX96 Reference price: raw currency1 per raw currency0, Q64.96. Zero means not configured.
    /// @param baseFeePips Fee rate at level 0, pips.
    /// @param maxFeePips Fee rate at and above the scale, pips. At least `baseFeePips` and below 100%.
    /// @param decayWindow Seconds for a level equal to the scale to decay to zero. 0 disables decay.
    /// @param scale0 `K` for selling currency0, raw currency0.
    /// @param scale1 `K` for selling currency1, raw currency1.
    struct PoolConfig {
        uint160 priceX96;
        uint24 baseFeePips;
        uint24 maxFeePips;
        uint32 decayWindow;
        uint128 scale0;
        uint128 scale1;
    }

    /// @notice A stored flow level.
    /// @param level Gross input in this direction at `updatedAt`, decayed, raw input units.
    /// @param updatedAt Timestamp of the last swap in this direction or configuration, seconds.
    struct FlowState {
        uint128 level;
        uint64 updatedAt;
    }

    /// @notice Pricing parameters by pool id.
    mapping(PoolId => PoolConfig) public poolConfig;

    /// @dev Stored flow level by pool id and direction (true: selling currency0).
    mapping(PoolId => mapping(bool => FlowState)) internal _flow;

    /// @notice The pool has no reference price configured, so it cannot be quoted.
    error PoolNotConfigured();
    /// @notice `configurePool` was called with a key for another hook, a zero price, base > max, max >= 100%, or a
    ///         zero scale.
    error InvalidConfig();

    /// @notice A pool's pricing parameters were set or replaced.
    event PoolConfigured(
        PoolId indexed poolId,
        uint160 priceX96,
        uint24 baseFeePips,
        uint24 maxFeePips,
        uint128 scale0,
        uint128 scale1,
        uint32 decayWindow
    );

    /// @param poolManager_ PoolManager the hook's pools live in.
    /// @param vault_ Vault that fills the swaps.
    /// @param hookOwner_ Account that may configure pricing.
    constructor(IPoolManager poolManager_, ISharedCommitmentVault vault_, address hookOwner_)
        BaseCompatibleHook(poolManager_, vault_, hookOwner_)
    {}

    /// @notice Set or replace the pricing parameters for one of this hook's pools.
    /// @dev Only `hookOwner`. If the pool was configured before, first applies the decay elapsed under the old
    ///      parameters to both directions and restarts their clocks; the levels are kept. Takes effect on the next
    ///      swap.
    /// @param key Pool to configure. `key.hooks` must be this contract.
    /// @param priceX96 Reference price, raw currency1 per raw currency0, Q64.96. Non-zero.
    /// @param baseFeePips Fee rate at level 0, pips.
    /// @param maxFeePips Fee rate at and above the scale, pips. At least `baseFeePips` and below 1,000,000.
    /// @param scale0 Level at which selling currency0 reaches `maxFeePips`, raw currency0. Non-zero.
    /// @param scale1 Level at which selling currency1 reaches `maxFeePips`, raw currency1. Non-zero.
    /// @param decayWindow Seconds for a level equal to the scale to decay to zero. 0 disables decay.
    function configurePool(
        PoolKey calldata key,
        uint160 priceX96,
        uint24 baseFeePips,
        uint24 maxFeePips,
        uint128 scale0,
        uint128 scale1,
        uint32 decayWindow
    ) external onlyHookOwner {
        if (address(key.hooks) != address(this)) revert InvalidConfig();
        if (priceX96 == 0 || baseFeePips > maxFeePips || maxFeePips >= PIPS || scale0 == 0 || scale1 == 0) {
            revert InvalidConfig();
        }
        PoolId id = key.toId();
        PoolConfig memory old = poolConfig[id];
        if (old.priceX96 != 0) {
            _settle(id, old, true);
            _settle(id, old, false);
        }
        poolConfig[id] = PoolConfig(priceX96, baseFeePips, maxFeePips, decayWindow, scale0, scale1);
        emit PoolConfigured(id, priceX96, baseFeePips, maxFeePips, scale0, scale1, decayWindow);
    }

    /// @notice The flow level in one direction now, with decay applied.
    /// @param key Pool to read.
    /// @param zeroForOne True for the level of selling currency0.
    /// @return Raw units of that direction's input currency. 0 if not configured.
    function flowLevel(PoolKey calldata key, bool zeroForOne) external view returns (uint256) {
        PoolId id = key.toId();
        PoolConfig memory cfg = poolConfig[id];
        if (cfg.priceX96 == 0) return 0;
        return _levelNow(cfg, _flow[id][zeroForOne], zeroForOne);
    }

    /// @notice Fee a swap of `amountIn` would pay right now.
    /// @dev Reverts with `PoolNotConfigured` without a reference price, and with `AmountTooLarge` if the level would
    ///      pass 2^128 - 1.
    /// @param key Pool being quoted.
    /// @param zeroForOne True if the swapper sells currency0.
    /// @param amountIn Raw input amount.
    /// @return fee Raw input units kept as the fee; at most `amountIn`.
    function feeFor(PoolKey calldata key, bool zeroForOne, uint256 amountIn) external view returns (uint256 fee) {
        (fee,) = _fee(key.toId(), zeroForOne, amountIn);
    }

    /// @notice Output a swap of `amountIn` would receive right now, before any vault check.
    /// @dev The vault can still reject the swap (price floor, quota, flow limits, expiry, pause, halt). The result does
    ///      not depend on which allocation the swap uses. Useful for routers that compute a minimum-output bound.
    /// @param key Pool being quoted.
    /// @param zeroForOne True if the swapper sells currency0.
    /// @param amountIn Raw input amount.
    /// @return amountOut Raw output amount.
    function quote(PoolKey calldata key, bool zeroForOne, uint256 amountIn) external view returns (uint256 amountOut) {
        (amountOut,) = _quote(key.toId(), zeroForOne, amountIn);
    }

    /// @dev out = (amountIn - fee) at the reference price, rounded down. `newState` is the new level.
    function _quote(PoolId id, bool zeroForOne, uint256 amountIn)
        internal
        view
        override
        returns (uint256 amountOut, uint256 newState)
    {
        uint256 fee;
        (fee, newState) = _fee(id, zeroForOne, amountIn);
        amountOut = _grossOut(poolConfig[id].priceX96, zeroForOne, amountIn - fee);
    }

    /// @dev fee = F_hat(s + amountIn) - F_hat(s), with s the decayed level. fee <= amountIn (see
    ///      `CumulativePricing.cumulativeFee`), so `amountIn - fee` cannot underflow. The new level is kept below
    ///      2^128 so that it fits the stored uint128 and stays within `cumulativeFee`'s overflow bounds; reaching it
    ///      needs more than 3.4 * 10^20 whole 18-decimal tokens of undecayed flow.
    function _fee(PoolId id, bool zeroForOne, uint256 amountIn) internal view returns (uint256 fee, uint256 level) {
        PoolConfig memory cfg = poolConfig[id];
        if (cfg.priceX96 == 0) revert PoolNotConfigured();
        uint256 s = _levelNow(cfg, _flow[id][zeroForOne], zeroForOne);
        level = s + amountIn;
        if (level > type(uint128).max) revert AmountTooLarge();
        uint256 k = zeroForOne ? cfg.scale0 : cfg.scale1;
        fee = CumulativePricing.cumulativeFee(level, k, cfg.baseFeePips, cfg.maxFeePips)
            - CumulativePricing.cumulativeFee(s, k, cfg.baseFeePips, cfg.maxFeePips);
    }

    /// @dev Stores the level `_quote` returned (below 2^128) with the current time.
    function _commit(PoolId id, bool zeroForOne, uint256 newState) internal override {
        // forge-lint: disable-next-line(unsafe-typecast)
        _flow[id][zeroForOne] = FlowState(uint128(newState), uint64(block.timestamp));
    }

    /// @dev Applies the decay elapsed under `cfg` to one direction and restarts its clock.
    function _settle(PoolId id, PoolConfig memory cfg, bool zeroForOne) internal {
        FlowState storage f = _flow[id][zeroForOne];
        // The decayed level is at most the stored uint128 level.
        // forge-lint: disable-next-line(unsafe-typecast)
        f.level = uint128(_levelNow(cfg, f, zeroForOne));
        f.updatedAt = uint64(block.timestamp);
    }

    /// @dev Stored level with decay applied: falls by floor(K * elapsed / decayWindow), not below zero.
    function _levelNow(PoolConfig memory cfg, FlowState memory f, bool zeroForOne) internal view returns (uint256) {
        return CumulativePricing.decayed(
            f.level, zeroForOne ? cfg.scale0 : cfg.scale1, cfg.decayWindow, block.timestamp - f.updatedAt
        );
    }
}
