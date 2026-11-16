// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IVaultState} from "../../src/interfaces/IVaultState.sol";

/// @title IndependentHookC
/// @notice Test-only example of an independently priced v4 hook that fills exact-input swaps from a registered vault
///         allocation. Its policy prices each raw input unit at one raw output unit, less a fixed spread in pips.
/// @dev This contract has no vault storage access, backing ledger or allocation ledger. The manager holds token and
///      ERC-6909 custody; the vault decides whether a quote satisfies the live floor, available room, allocation and
///      risk limits. The owner may configure a pool's spread but cannot move vault claims. A raw-unit 1:1 reference
///      assumes the paired assets have comparable raw units; this fixture uses two 18-decimal test tokens. It makes
///      no market-price or later-execution promise and is not a production strategy.
contract IndependentHookC is IHooks {
    uint256 internal constant MAX_AMOUNT = uint256(uint128(type(int128).max));
    uint256 internal constant PIPS = 1_000_000;

    IPoolManager public immutable manager;
    IVaultState public immutable vault;
    address public immutable hookOwner;
    Currency public immutable asset0;
    Currency public immutable asset1;

    /// @notice Spread on each configured pool, in parts per million. Configuration may be disabled by the owner.
    /// @dev A zero spread is allowed; the vault still rejects any quote below its own floor.
    struct QuotePolicy {
        uint24 spreadPips;
        bool enabled;
    }

    mapping(PoolId => QuotePolicy) public policies;

    event PolicySet(PoolId indexed poolId, uint24 spreadPips, bool enabled);

    error NotManager();
    error NotHookOwner();
    error InvalidIdentity();
    error InvalidPool();
    error InvalidSpread();
    error QuoteUnavailable();
    error ExactInputOnly();
    error InputTooLarge();
    error InvalidHookData();
    error DustOutput();
    error TraderMinimum(uint256 quoted, uint256 minimum);
    error NativeLiquidityDisabled();
    error CallbackDisabled();

    modifier onlyManager() {
        if (msg.sender != address(manager)) revert NotManager();
        _;
    }

    /// @dev The vault becomes an ERC-6909 operator over this hook's temporary claims. The reverse grant is never
    ///      made. The manager identity and pair are checked once, then the address permission bits are validated.
    /// @param manager_ The pinned v4 PoolManager that invokes callbacks and holds claims.
    /// @param vault_ Public vault read and exchange interface; its PoolManager must be `manager_`.
    /// @param hookOwner_ Account permitted to configure this hook's quote policy.
    constructor(IPoolManager manager_, IVaultState vault_, address hookOwner_) {
        if (
            address(manager_) == address(0) || address(vault_) == address(0) || hookOwner_ == address(0)
                || address(vault_.poolManager()) != address(manager_)
        ) revert InvalidIdentity();
        manager = manager_;
        vault = vault_;
        hookOwner = hookOwner_;
        asset0 = vault_.asset0();
        asset1 = vault_.asset1();
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        manager_.setOperator(address(vault_), true);
    }

    /// @notice Enable or disable the fixed-spread quote on one pool of this hook.
    /// @dev Only `hookOwner_`; the key must use this hook and the vault's sorted pair. A configured pool can still be
    ///      refused by the vault when its price floor or another live execution rule is tighter.
    /// @param key PoolKey whose hooks field must be this hook.
    /// @param spreadPips Input spread in 1e6 pips; less than 1e6 so a positive output is possible.
    /// @param enabled Whether this hook quotes the pool.
    function setPolicy(PoolKey calldata key, uint24 spreadPips, bool enabled) external {
        if (msg.sender != hookOwner) revert NotHookOwner();
        _checkKey(key);
        if (spreadPips >= PIPS) revert InvalidSpread();
        PoolId id = key.toId();
        policies[id] = QuotePolicy(spreadPips, enabled);
        emit PolicySet(id, spreadPips, enabled);
    }

    /// @notice Quote raw output at a 1:1 raw-unit reference less the configured spread.
    /// @dev `floor(amountIn * (1e6 - spreadPips) / 1e6)` rounds output down in favour of the vault. A 1,000-unit
    ///      input at 1,000 pips quotes 999 units. A one-unit input at 1,000 pips quotes zero and is refused by the
    ///      callback. No price oracle or other hook's state is read.
    /// @param key Configured pool.
    /// @param amountIn Raw input units, at most 2^127 - 1 in an actual swap.
    /// @return amountOut Raw output units, rounded down.
    function quote(PoolKey calldata key, uint256 amountIn) public view returns (uint256 amountOut) {
        _checkKey(key);
        QuotePolicy memory policy = policies[key.toId()];
        if (!policy.enabled) revert QuoteUnavailable();
        amountOut = FullMath.mulDiv(amountIn, PIPS - policy.spreadPips, PIPS);
    }

    /// @notice Required permissions: refuse native liquidity; intercept swaps and return an accounting delta.
    /// @return p Permission flags encoded in this hook's deployed address.
    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeAddLiquidity = true;
        p.beforeSwap = true;
        p.beforeSwapReturnDelta = true;
    }

    /// @notice Fill an exact-input swap with a vault allocation and transfer the two resulting deltas to the trader.
    /// @dev The PoolManager invokes this before its price curve. Minting input claims creates a temporary input debt
    ///      for the hook; `vault.exchange` pulls those claims and transfers its output claims; burning output claims
    ///      creates an output credit. `BeforeSwapDelta(+input,-output)` assigns both to the trader and leaves no pool
    ///      curve amount. The manager refuses the unlock unless the router settles the trader's input debt. Any
    ///      later failure rolls back the mint, vault fill, burn, allocation, flow usage and escrow state together.
    /// @param key Pool being swapped; it must be a configured pool of this hook and the vault's asset pair.
    /// @param params Exact-input swap parameters (`amountSpecified` negative).
    /// @param hookData `abi.encode(uint256 allocationId, uint256 minimumOutput)`; exactly 64 bytes.
    /// @return selector Callback selector acknowledged to the PoolManager.
    /// @return delta Specified input and unspecified output transferred to the trader, in int128 units.
    /// @return feeOverride Zero: the pool's price curve is skipped.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyManager
        returns (bytes4 selector, BeforeSwapDelta delta, uint24 feeOverride)
    {
        if (params.amountSpecified >= 0) revert ExactInputOnly();
        // This bound also excludes int256.min before negation and keeps both delta components in int128.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (params.amountSpecified < -int256(MAX_AMOUNT)) revert InputTooLarge();
        if (hookData.length != 64) revert InvalidHookData();
        (uint256 allocationId, uint256 minimumOutput) = abi.decode(hookData, (uint256, uint256));
        uint256 input = uint256(-params.amountSpecified);
        uint256 output = quote(key, input);
        if (output == 0) revert DustOutput();
        if (output < minimumOutput) revert TraderMinimum(output, minimumOutput);

        (Currency currencyIn, Currency currencyOut) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        manager.mint(address(this), currencyIn.toId(), input);
        vault.exchange(key, params.zeroForOne, allocationId, input, output);
        manager.burn(address(this), currencyOut.toId(), output);

        // output <= input <= MAX_AMOUNT, so these casts preserve the exact raw amounts.
        // forge-lint: disable-next-line(unsafe-typecast)
        delta = toBeforeSwapDelta(int128(int256(input)), -int128(int256(output)));
        feeOverride = 0;
        selector = IHooks.beforeSwap.selector;
    }

    /// @notice Refuse pool-native liquidity: intercepted swaps never reach its price curve.
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyManager
        returns (bytes4)
    {
        revert NativeLiquidityDisabled();
    }

    function _checkKey(PoolKey calldata key) internal view {
        if (
            address(key.hooks) != address(this) || Currency.unwrap(key.currency0) != Currency.unwrap(asset0)
                || Currency.unwrap(key.currency1) != Currency.unwrap(asset1)
        ) {
            revert InvalidPool();
        }
    }

    // No other callback permission is set. Explicit reverts also reject direct calls to these selectors.
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert CallbackDisabled();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert CallbackDisabled();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert CallbackDisabled();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert CallbackDisabled();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert CallbackDisabled();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert CallbackDisabled();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert CallbackDisabled();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert CallbackDisabled();
    }
}
