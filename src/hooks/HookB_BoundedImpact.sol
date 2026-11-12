// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ISharedCommitmentVault} from "../interfaces/ISharedCommitmentVault.sol";
import {BaseCompatibleHook} from "./BaseCompatibleHook.sol";
import {CumulativePricing} from "./CumulativePricing.sol";
import {InventoryPricing} from "../pricing/InventoryPricing.sol";
import {StrategyPricing} from "../pricing/StrategyPricing.sol";

/// @title HookB_BoundedImpact
/// @notice Sells vault liquidity along a curve around a reference price, with bounded price impact. In static mode the
///         curve is this pool's own virtual constant-product position around a configured price, capped so the
///         marginal price never moves more than a set percentage from it. While the vault has a market-risk adapter
///         it prices through the shared inventory core around that adapter's reference, keeps a flat markup on the
///         input and refuses any single trade whose impact exceeds a set bound (`configureStrategy`).
/// @dev Shared-core mode keeps no hook state: the curve position is the vault's own inventory, shared with every hook,
///      and the static-mode position below is neither used nor changed. Why a markup: in shared-core mode both hooks
///      quote from the same core, so the strategy is the only difference between them. A flat markup prices every
///      trade the same whatever recent flow was; Hook A's activity fee is cheaper for occasional small trades and
///      dearer for bursts. The per-trade bound stops one trade from walking deep into the curve at once.
///
///      The rest of this section describes static mode.
///
///      State. One signed position `x` per pool: currency1 the vault has sold through this pool minus currency1 it
///      has bought back, in raw currency1. It decays linearly toward zero over time (see below).
///
///      Curve. With depth `V` and reference price `P` (raw currency1 per raw currency0), the currency0 owed for a
///      position is `C(x) = V * x / (P * (V - x))` (in Q96 form, `CumulativePricing.positionCost`). It is a constant
///      product with virtual reserves `V` currency1 and `V / P` currency0. The marginal price of currency1 is
///      `(1 / P) * (V / (V - x))^2` currency0: the reference price at `x = 0`, higher after the vault has sold
///      currency1, lower after it has bought currency1.
///
///      Pricing, exact input, `C_hat = ceil(C)`:
///        selling currency0 (zeroForOne, the vault sells currency1):
///          x' = the largest position with C_hat(x') <= C_hat(x) + amountIn      (exact, closed form)
///          out = x' - x currency1;  the unused part of the input (< the cost of one more unit) is kept by the vault
///        selling currency1 (oneForZero, the vault buys currency1):
///          x' = x - amountIn;  out = C_hat(x) - C_hat(x') currency0
///
///      Why this resists splitting. Every trade is a difference of the same integer function `C_hat`, so any
///      sequence of trades that moves the position from `a` to `b`, in pieces, in any order and in either direction,
///      exchanges exactly `C_hat(b) - C_hat(a)` currency0 (plus the remainders exact input leaves behind, which only
///      cost the swapper). One trade and its split pay the same apart from those remainders: a split into n pieces
///      can lose the swapper at most n remainders, each less than the price of one more output unit, and can never
///      gain. Buying currency1 back from the vault (oneForZero) has no remainder: its split pays exactly the same.
///      Example, V = 1,000,000, 1:1 price: 1,000 currency1 out costs C_hat(1,000) = 1,001.001 currency0 as one
///      trade or as any number of pieces.
///
///      Cap. The marginal premium `(V / (V - x))^2 - 1` reaches `maxImpactPips` at `maxPosition` (computed at
///      configuration, `CumulativePricing.maxPosition`). A trade that would end with `x > maxPosition` or
///      `x < -maxPosition` reverts with `ImpactBoundExceeded`, however the flow is split. Example: V = 1,000,000,
///      2% cap: `|x| <= 9,852`. On the negative side the vault sells currency0 and its premium there is smaller, so
///      the symmetric bound is conservative.
///
///      Round trips. Selling currency1 back moves `x` toward its start along the same curve, so a round trip
///      exchanges zero net currency0 apart from remainders: the swapper never ends with more of either asset than a
///      unit's rounding (simulations/pricing). The reverse leg is priced above the reference price when `x > 0`
///      (the vault buys currency1 back at the curve's price). The vault's own price floors (`exchange`) are checked
///      on each leg: with floors whose product is at least 1 (the vault's directional-consistency rule), a reverse
///      leg passes only where its price meets the opposite floor. With floors at the reference price, `x` can move
///      away from zero by trading and returns toward zero by decay or by a trade large enough to cross zero.
///
///      Decay. `|x|` falls by `maxPosition * elapsed / decayWindow` (rounded down) toward zero, never past it: a
///      position at the cap returns to zero after `decayWindow` seconds without trading. Decay is the only path
///      dependence and it is intentional: it is how the price returns to the reference. `decayWindow = 0` disables
///      it. The state is in storage, so splitting a trade across transactions or blocks at the same timestamp gives
///      the same result as one transaction.
///
///      Parameters. `configurePool` first applies the decay elapsed under the old parameters, then:
///      - a new depth rescales the position by `V_new / V_old` (rounded toward zero), which keeps the marginal price
///        where it was. A smaller depth then makes every later trade more expensive in both directions; a larger
///        depth makes them cheaper. Keeping the raw position instead would let a smaller depth pay buy-backs far
///        above the price the vault sold at;
///      - a new cap applies at once. If `|x|` is already beyond it, trades that move `x` further out revert and
///        trades back toward zero are allowed;
///      - a new reference price applies at once and is not phased in.
///      `hookOwner` is trusted to set prices and parameters; nothing delays a loosening change.
///
///      Not handled here. The reference price does not follow the market: if it is stale, arbitrageurs trade until
///      the curve's marginal price meets the market or the cap stops them, and the vault's price floor is the only
///      protection LPs have beyond that. Splitting across different hooks or pools is not priced together; the vault's
///      flow limits bound it.
contract HookB_BoundedImpact is BaseCompatibleHook {
    /// @dev Impact unit: 1,000,000 pips = 100%.
    uint256 internal constant PIPS = 1_000_000;

    /// @notice Pricing parameters for one pool.
    /// @param priceX96 Reference price `P`: raw currency1 per raw currency0, Q64.96. Zero means not configured.
    /// @param maxImpactPips Largest marginal premium over `P`, pips. Between 1 and 999,999.
    /// @param decayWindow Seconds for a position at the cap to decay to zero. 0 disables decay.
    /// @param depth `V`: virtual currency1 reserve of the curve, raw currency1. At most 2^95 - 1.
    /// @param maxPosition Cap on `|x|` derived from `depth` and `maxImpactPips`, raw currency1.
    struct PoolConfig {
        uint160 priceX96;
        uint24 maxImpactPips;
        uint32 decayWindow;
        uint96 depth;
        uint96 maxPosition;
    }

    /// @notice A pool's stored position.
    /// @param x Net currency1 sold by the vault through the pool at `updatedAt`, raw currency1 (signed).
    /// @param updatedAt Timestamp of the last swap or configuration, seconds.
    struct Position {
        int128 x;
        uint64 updatedAt;
    }

    /// @notice Pricing parameters by pool id.
    mapping(PoolId => PoolConfig) public poolConfig;

    /// @dev Stored position by pool id; `positionOf` returns it with decay applied.
    mapping(PoolId => Position) internal _position;

    /// @notice Hook B's strategy in shared-core mode.
    /// @param markupPips Share of every input kept before the core prices the rest (a flat markup over the core).
    /// @param maxTradeImpactPips Largest shortfall of one trade's output against the reference price, pips; a larger
    ///        trade is refused (`TradeImpactExceeded`) rather than filled deep into the curve.
    struct Strategy {
        uint24 markupPips;
        uint24 maxTradeImpactPips;
    }

    /// @notice Shared-core strategy by pool. `maxTradeImpactPips == 0`: not configured.
    mapping(PoolId => Strategy) public strategy;

    /// @notice Hook B's shared-core strategy of `poolId` was set.
    event StrategyConfigured(PoolId indexed poolId, uint24 markupPips, uint24 maxTradeImpactPips);

    /// @notice The pool has no reference price configured, so it cannot be quoted.
    error PoolNotConfigured();
    /// @notice `configurePool` was called with a key for another hook, a zero price, a depth above 2^95 - 1, an
    ///         impact cap of 0 or of 100% or more, or parameters that leave a cap of zero.
    error InvalidConfig();
    /// @notice The trade would leave the position beyond the cap, or further beyond it than it already is.
    /// @param position Position before the trade (decay applied), raw currency1.
    /// @param maxPosition Cap on `|x|`, raw currency1.
    error ImpactBoundExceeded(int256 position, uint256 maxPosition);

    /// @notice A pool's pricing parameters were set or replaced.
    /// @param position The position after decay and rescaling, raw currency1.
    event PoolConfigured(
        PoolId indexed poolId,
        uint160 priceX96,
        uint96 depth,
        uint24 maxImpactPips,
        uint32 decayWindow,
        uint256 maxPosition,
        int256 position
    );

    /// @param poolManager_ PoolManager the hook's pools live in.
    /// @param vault_ Vault that fills the swaps.
    /// @param hookOwner_ Account that may configure pricing.
    constructor(IPoolManager poolManager_, ISharedCommitmentVault vault_, address hookOwner_)
        BaseCompatibleHook(poolManager_, vault_, hookOwner_)
    {}

    /// @notice Set or replace the pricing parameters for one of this hook's pools.
    /// @dev Only `hookOwner`. Applies the decay elapsed under the old parameters, rescales the position if the depth
    ///      changes (see the contract documentation), stores the parameters and the position with the current
    ///      timestamp. Takes effect on the next swap.
    /// @param key Pool to configure. `key.hooks` must be this contract.
    /// @param priceX96 Reference price, raw currency1 per raw currency0, Q64.96. Non-zero.
    /// @param depth Curve depth `V`, raw currency1. At most 2^95 - 1, and large enough that the cap is at least 1.
    /// @param maxImpactPips Largest marginal premium, pips. Between 1 and 999,999.
    /// @param decayWindow Seconds for a position at the cap to decay to zero. 0 disables decay.
    function configurePool(
        PoolKey calldata key,
        uint160 priceX96,
        uint96 depth,
        uint24 maxImpactPips,
        uint32 decayWindow
    ) external onlyHookOwner {
        if (address(key.hooks) != address(this)) revert InvalidConfig();
        if (priceX96 == 0 || depth > CumulativePricing.MAX_DEPTH || maxImpactPips == 0 || maxImpactPips >= PIPS) {
            revert InvalidConfig();
        }
        uint256 maxPos = CumulativePricing.maxPosition(depth, maxImpactPips);
        if (maxPos == 0) revert InvalidConfig();

        PoolId id = key.toId();
        PoolConfig memory old = poolConfig[id];
        int256 x;
        if (old.priceX96 != 0) {
            x = _positionNow(old, _position[id]);
            // |x| <= 0.3 * old depth < 2^95 and depth < 2^95: the product fits. Division truncates toward zero.
            if (depth != old.depth) x = x * int256(uint256(depth)) / int256(uint256(old.depth));
        }
        // |x| < 2^95 fits int128. maxPos < depth < 2^95 fits uint96.
        // forge-lint: disable-next-line(unsafe-typecast)
        _position[id] = Position(int128(x), uint64(block.timestamp));
        // forge-lint: disable-next-line(unsafe-typecast)
        poolConfig[id] = PoolConfig(priceX96, maxImpactPips, decayWindow, depth, uint96(maxPos));
        emit PoolConfigured(id, priceX96, depth, maxImpactPips, decayWindow, maxPos, x);
    }

    /// @notice The pool's position now, with decay applied.
    /// @param key Pool to read.
    /// @return Net currency1 sold by the vault through the pool, raw currency1 (signed). 0 if not configured.
    function positionOf(PoolKey calldata key) external view returns (int256) {
        PoolId id = key.toId();
        PoolConfig memory cfg = poolConfig[id];
        if (cfg.priceX96 == 0) return 0;
        return _positionNow(cfg, _position[id]);
    }

    /// @notice Output a swap of `amountIn` would receive right now, before any vault check.
    /// @dev Reverts with `ImpactBoundExceeded` past the cap and `PoolNotConfigured` without a reference price. The
    ///      vault can still reject the swap (price floor, quota, flow limits, expiry, pause, halt). The result does not
    ///      depend on which allocation the swap uses.
    /// @param key Pool being quoted.
    /// @param zeroForOne True if the swapper sells currency0.
    /// @param amountIn Raw input amount, at most 2^127 - 1.
    /// @return amountOut Raw output amount.
    function quote(PoolKey calldata key, bool zeroForOne, uint256 amountIn) external view returns (uint256 amountOut) {
        if (amountIn > MAX_AMOUNT) revert AmountTooLarge();
        (, amountOut,) = _quoteAny(key.toId(), zeroForOne, amountIn);
    }

    /// @notice Set Hook B's shared-core strategy for one of its pools.
    /// @dev Hook owner only. The markup must be below 100% and the per-trade impact bound strictly between 0 and
    ///      100%. Example: a markup of 1,000 pips (0.1%) keeps 1 of every 1,000 raw input units before pricing; a
    ///      bound of 20,000 pips (2%) refuses any trade whose output is more than 2% below the reference value of
    ///      its input.
    /// @param key Pool to configure; its `hooks` must be this contract.
    /// @param markupPips Markup, pips of the input.
    /// @param maxTradeImpactPips Per-trade impact bound, pips.
    function configureStrategy(PoolKey calldata key, uint24 markupPips, uint24 maxTradeImpactPips)
        external
        onlyHookOwner
    {
        if (
            address(key.hooks) != address(this) || markupPips >= PIPS || maxTradeImpactPips == 0
                || maxTradeImpactPips >= PIPS
        ) {
            revert InvalidConfig();
        }
        PoolId id = key.toId();
        strategy[id] = Strategy(markupPips, maxTradeImpactPips);
        emit StrategyConfigured(id, markupPips, maxTradeImpactPips);
    }

    /// @notice Shared-core mode: a flat markup on the input, the core prices the rest, and the trade is refused if its
    ///         output falls further below the reference value than `maxTradeImpactPips` (`StrategyPricing.hookB`).
    /// @dev Hook B keeps no state in this mode (its static-mode position is not used or changed).
    /// @return amountOut Raw output.
    /// @return newState Always 0.
    function _quoteCore(PoolId id, InventoryPricing.Core memory core, bool zeroForOne, uint256 amountIn)
        internal
        view
        override
        returns (uint256 amountOut, uint256 newState)
    {
        Strategy memory st = strategy[id];
        if (st.maxTradeImpactPips == 0) revert PoolNotConfigured();
        amountOut = StrategyPricing.hookB(core, st.markupPips, st.maxTradeImpactPips, zeroForOne, amountIn).amountOut;
        newState = 0;
    }

    /// @dev See the contract documentation for the formulas. `newState` is the new position `x'` as the two's
    ///      complement bits of an int256.
    ///
    ///      Bounds. The stored `|x|` never exceeds about 0.3 V (the largest cap) and `V < 2^95`, so
    ///      `positionCost(x)` is in range. Selling currency0: `target = C_hat(x) + amountIn` is compared with
    ///      `C_hat(maxPosition + 1)` before inverting, so `positionForCost` only sees targets below the cap's cost
    ///      plus one unit (its overflow precondition), and `x' <= maxPosition` exactly when that check passes.
    ///      `x' >= x` because `C_hat(x) <= target`. Selling currency1: `x' = x - amountIn` with `amountIn < 2^127`
    ///      is checked against `-maxPosition` before `positionCost(x')` is evaluated.
    function _quote(PoolId id, bool zeroForOne, uint256 amountIn)
        internal
        view
        override
        returns (uint256 amountOut, uint256 newState)
    {
        PoolConfig memory cfg = poolConfig[id];
        if (cfg.priceX96 == 0) revert PoolNotConfigured();
        int256 x = _positionNow(cfg, _position[id]);
        int256 cap = int256(uint256(cfg.maxPosition));
        int256 x2;
        if (zeroForOne) {
            // amountIn <= 2^127 - 1 (checked by the caller) and |C_hat(x)| < 2^191: the sum fits.
            int256 target = CumulativePricing.positionCost(x, cfg.depth, cfg.priceX96) + int256(amountIn);
            if (target >= CumulativePricing.positionCost(cap + 1, cfg.depth, cfg.priceX96)) {
                revert ImpactBoundExceeded(x, cfg.maxPosition);
            }
            x2 = CumulativePricing.positionForCost(target, cfg.depth, cfg.priceX96);
            amountOut = uint256(x2 - x);
        } else {
            x2 = x - int256(amountIn);
            if (x2 < -cap) revert ImpactBoundExceeded(x, cfg.maxPosition);
            amountOut = uint256(
                CumulativePricing.positionCost(x, cfg.depth, cfg.priceX96)
                    - CumulativePricing.positionCost(x2, cfg.depth, cfg.priceX96)
            );
        }
        newState = uint256(x2);
    }

    /// @dev Stores the position `_quote` returned (|x'| <= max(cap, |x|) < 2^95 fits int128) with the current time.
    function _commit(PoolId id, bool, uint256 newState) internal override {
        // forge-lint: disable-next-line(unsafe-typecast)
        _position[id] = Position(int128(int256(newState)), uint64(block.timestamp));
    }

    /// @dev Stored position with decay applied: |x| falls by floor(maxPosition * elapsed / decayWindow), toward zero.
    function _positionNow(PoolConfig memory cfg, Position memory p) internal view returns (int256) {
        int256 x = p.x;
        uint256 m = CumulativePricing.decayed(
            x >= 0 ? uint256(x) : uint256(-x), cfg.maxPosition, cfg.decayWindow, block.timestamp - p.updatedAt
        );
        // m <= |x| < 2^95.
        return x >= 0 ? int256(m) : -int256(m);
    }
}
