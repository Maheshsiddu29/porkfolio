// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @title BatchSwapRouter — TEST ONLY. Not for deployment.
/// @notice Executes several exact-input swaps inside ONE PoolManager.unlock() so tests can model
///         same-transaction contention between hooks, and asserts the delta reconciliation the design relies on:
///           - after every swap, each touched hook and the vault have zero currency delta;
///           - after settlement, PoolManager's NonzeroDeltaCount is zero.
///         `SkipInputPayment` deliberately under-settles to prove PoolManager rejects incorrect settlement.
contract BatchSwapRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    enum Mode {
        Settle,
        SkipInputPayment
    }

    struct Step {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        bytes hookData;
    }

    error HookDeltaNotZero(address hook, Currency currency, int256 delta);
    error VaultDeltaNotZero(Currency currency, int256 delta);
    error InsufficientOutput(uint256 step, uint256 out, uint256 minOut);

    IPoolManager public immutable manager;
    address public immutable vault;

    /// @notice Recorded after the last successful run, for test assertions.
    uint256 public lastNonzeroDeltaCount;

    constructor(IPoolManager manager_, address vault_) {
        manager = manager_;
        vault = vault_;
    }

    function run(Step[] calldata steps, uint256[] calldata minOut, Mode mode)
        external
        returns (BalanceDelta[] memory deltas)
    {
        deltas = abi.decode(manager.unlock(abi.encode(msg.sender, steps, minOut, mode)), (BalanceDelta[]));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (address payer, Step[] memory steps, uint256[] memory minOut, Mode mode) =
            abi.decode(raw, (address, Step[], uint256[], Mode));

        BalanceDelta[] memory deltas = new BalanceDelta[](steps.length);
        for (uint256 i; i < steps.length; ++i) {
            Step memory s = steps[i];
            deltas[i] = manager.swap(
                s.key,
                SwapParams({
                    zeroForOne: s.zeroForOne,
                    amountSpecified: -int256(s.amountIn),
                    sqrtPriceLimitX96: s.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                s.hookData
            );
            _assertZero(address(s.key.hooks), s.key.currency0, true);
            _assertZero(address(s.key.hooks), s.key.currency1, true);
            _assertZero(vault, s.key.currency0, false);
            _assertZero(vault, s.key.currency1, false);

            int128 outDelta = s.zeroForOne ? deltas[i].amount1() : deltas[i].amount0();
            // forge-lint: disable-next-line(unsafe-typecast)
            if (minOut.length > i && uint256(int256(outDelta)) < minOut[i]) {
                // forge-lint: disable-next-line(unsafe-typecast)
                revert InsufficientOutput(i, uint256(int256(outDelta)), minOut[i]);
            }

            _resolve(s.key.currency0, deltas[i].amount0(), payer, mode);
            _resolve(s.key.currency1, deltas[i].amount1(), payer, mode);
        }
        lastNonzeroDeltaCount = manager.getNonzeroDeltaCount();
        return abi.encode(deltas);
    }

    function _resolve(Currency c, int128 d, address payer, Mode mode) internal {
        if (d < 0) {
            if (mode == Mode.SkipInputPayment) return;
            manager.sync(c);
            // forge-lint: disable-next-line(unsafe-typecast)
            ERC20(Currency.unwrap(c)).transferFrom(payer, address(manager), uint256(-int256(d)));
            manager.settle();
        } else if (d > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            manager.take(c, payer, uint256(int256(d)));
        }
    }

    function _assertZero(address who, Currency c, bool isHook) internal view {
        int256 d = manager.currencyDelta(who, c);
        if (d != 0) {
            if (isHook) revert HookDeltaNotZero(who, c, d);
            revert VaultDeltaNotZero(c, d);
        }
    }
}
