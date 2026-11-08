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

/// @title MaliciousConsumerHook — TEST ONLY.
/// @notice Models a *registered* (whitelisted) consumer hook that has been compromised or is buggy.
///         Used to show which losses the vault prevents on its own and which are bounded only by
///         quota and price floor.
contract MaliciousConsumerHook is BaseTestHooks {
    enum Attack {
        SkipInputFunding, // call vault.exchange without minting the input claims
        BurnVaultClaims, // burn the vault's ERC-6909 claims directly
        TransferFromVault, // ERC-6909 transferFrom(vault -> hook)
        OverQuota, // request more output than the allocation's remaining capacity
        BelowFloor, // pay 1 wei of input for the output
        ExactAmounts // fund the swap's full input and request exactly `amountOut` (e.g. a trade AT the floor)
    }

    IPoolManager public immutable manager;
    ISharedCommitmentVault public immutable vault;
    Attack public attack;
    uint256 public allocationId;
    uint256 public amountOut;

    constructor(IPoolManager manager_, ISharedCommitmentVault vault_) {
        manager = manager_;
        vault = vault_;
        manager_.setOperator(address(vault_), true);
    }

    function configure(Attack attack_, uint256 allocationId_, uint256 amountOut_) external {
        attack = attack_;
        allocationId = allocationId_;
        amountOut = amountOut_;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 amountIn = uint256(-params.amountSpecified);
        (Currency cin, Currency cout) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        if (attack == Attack.SkipInputFunding) {
            vault.exchange(key, params.zeroForOne, allocationId, amountIn, amountOut);
        } else if (attack == Attack.BurnVaultClaims) {
            manager.burn(address(vault), cout.toId(), amountOut);
        } else if (attack == Attack.TransferFromVault) {
            manager.transferFrom(address(vault), address(this), cout.toId(), amountOut);
        } else if (attack == Attack.OverQuota || attack == Attack.ExactAmounts) {
            manager.mint(address(this), cin.toId(), amountIn);
            vault.exchange(key, params.zeroForOne, allocationId, amountIn, amountOut);
        } else if (attack == Attack.BelowFloor) {
            manager.mint(address(this), cin.toId(), 1);
            vault.exchange(key, params.zeroForOne, allocationId, 1, amountOut);
        }
        // Every attack branch above reverts when the vault behaves correctly; only ExactAmounts at an admissible
        // price reaches this point.
        manager.burn(address(this), cout.toId(), amountOut);
        // forge-lint: disable-next-line(unsafe-typecast)
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(amountIn)), -int128(int256(amountOut))), 0);
    }
}
