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

/// @title AuthModeHook — TEST ONLY.
/// @notice Identical minimal consumer hooks (1:1 price, no fee) that differ ONLY in how they authorize the
///         vault's pull of the hook's transient input claims:
///           Operator  — `setOperator(vault, true)` once in the constructor (what BaseCompatibleHook does);
///           Allowance — `approve(vault, idIn, amountIn)` inside every beforeSwap, consumed to 0 by the pull.
///         Used to compare gas and residual authority under equal conditions.
contract AuthModeHook is BaseTestHooks {
    enum Mode {
        Operator,
        Allowance
    }

    IPoolManager public immutable manager;
    ISharedCommitmentVault public immutable vault;
    Mode public immutable mode;
    /// @dev Test knob: approve this much LESS than amountIn (Allowance mode) to show exactness.
    uint256 public approveShortfall;

    constructor(IPoolManager manager_, ISharedCommitmentVault vault_, Mode mode_) {
        manager = manager_;
        vault = vault_;
        mode = mode_;
        if (mode_ == Mode.Operator) manager_.setOperator(address(vault_), true);
    }

    function setApproveShortfall(uint256 shortfall) external {
        approveShortfall = shortfall;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        require(msg.sender == address(manager), "only manager");
        require(params.amountSpecified < 0, "exact-in only");
        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 amountOut = amountIn; // 1:1, identical in both modes
        uint256 allocationId = abi.decode(hookData, (uint256));
        (Currency cin, Currency cout) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        manager.mint(address(this), cin.toId(), amountIn);
        if (mode == Mode.Allowance) manager.approve(address(vault), cin.toId(), amountIn - approveShortfall);
        vault.exchange(key, params.zeroForOne, allocationId, amountIn, amountOut);
        manager.burn(address(this), cout.toId(), amountOut);

        // forge-lint: disable-next-line(unsafe-typecast)
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(amountIn)), -int128(int256(amountOut))), 0);
    }
}
