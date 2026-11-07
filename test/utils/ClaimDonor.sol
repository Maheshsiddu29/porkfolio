// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @title ClaimDonor — TEST ONLY.
/// @notice Pays ERC-20 into the real PoolManager and mints the resulting ERC-6909 claims directly to an
///         arbitrary address (e.g. the vault), modelling an unsolicited "donation" of claims.
contract ClaimDonor is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function donate(Currency currency, uint256 amount, address to) external {
        manager.unlock(abi.encode(currency, amount, to, msg.sender));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (Currency currency, uint256 amount, address to, address payer) =
            abi.decode(data, (Currency, uint256, address, address));
        manager.sync(currency);
        ERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), amount);
        manager.settle();
        manager.mint(to, currency.toId(), amount);
        return "";
    }
}
