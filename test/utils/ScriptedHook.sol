// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseTestHooks} from "@uniswap/v4-core/src/test/BaseTestHooks.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";

/// @title ScriptedHook — TEST ONLY.
/// @notice A registered consumer hook that fills swaps 1:1 from the vault like `BaseCompatibleHook`, and can run a
///         script of arbitrary calls at three points inside `beforeSwap`: before `exchange`, between a first and an
///         optional second `exchange` that split the swap, and after them. Models a malicious or buggy hook that tries to withdraw,
///         claim, cancel, allocate or settle while a swap is in progress.
/// @dev Imports only the vault interface, so it compiles under the default optimizer profile and can be used with
///      production artifacts. Every scripted call bubbles its revert, so the PoolManager reverts the whole swap.
///      `exec` lets tests use the hook as an ordinary account (LP, curator) outside a swap.
contract ScriptedHook is BaseTestHooks {
    struct Call {
        address to;
        bytes data;
    }

    IPoolManager public immutable manager;
    ISharedCommitmentVault public immutable vault;

    Call[] internal _before;
    Call[] internal _between;
    Call[] internal _after;
    /// @notice If non-zero, the swap is filled by two `exchange` calls on the same allocation: amountIn - secondOut
    ///         first, then secondOut, with the `between` script in the middle.
    uint256 public secondOut;

    constructor(IPoolManager manager_, ISharedCommitmentVault vault_) {
        manager = manager_;
        vault = vault_;
        manager_.setOperator(address(vault_), true);
    }

    function script(Call[] calldata before_, Call[] calldata between_, Call[] calldata after_, uint256 secondOut_)
        external
    {
        delete _before;
        delete _between;
        delete _after;
        for (uint256 i; i < before_.length; ++i) {
            _before.push(before_[i]);
        }
        for (uint256 i; i < between_.length; ++i) {
            _between.push(between_[i]);
        }
        for (uint256 i; i < after_.length; ++i) {
            _after.push(after_[i]);
        }
        secondOut = secondOut_;
    }

    /// @notice Call `to` with `data` as this hook, bubbling any revert.
    function exec(address to, bytes calldata data) external returns (bytes memory ret) {
        return _call(to, data);
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        require(msg.sender == address(manager), "only manager");
        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 allocationId = abi.decode(hookData, (uint256));
        (Currency cin, Currency cout) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        uint256 out = amountIn; // 1:1, exactly at a 1:1 floor
        uint256 second = secondOut; // the swap is split: amountIn - second, then second
        require(second < amountIn, "second >= amountIn");

        _run(_before);
        manager.mint(address(this), cin.toId(), amountIn);
        vault.exchange(key, params.zeroForOne, allocationId, amountIn - second, amountIn - second);
        _run(_between);
        if (second != 0) vault.exchange(key, params.zeroForOne, allocationId, second, second);
        _run(_after);
        manager.burn(address(this), cout.toId(), out);

        // forge-lint: disable-next-line(unsafe-typecast)
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(amountIn)), -int128(int256(out))), 0);
    }

    function _run(Call[] storage calls) internal {
        for (uint256 i; i < calls.length; ++i) {
            _call(calls[i].to, calls[i].data);
        }
    }

    function _call(address to, bytes memory data) internal returns (bytes memory ret) {
        bool ok;
        (ok, ret) = to.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
