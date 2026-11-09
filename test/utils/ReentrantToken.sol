// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @title ReentrantToken — TEST ONLY.
/// @notice An ERC-20 that, once armed, makes one external call from inside its next `transfer` or `transferFrom`,
///         before moving any balance. Models a pair token with transfer hooks (ERC-777 style) or a malicious token.
/// @dev The inner call's result is recorded instead of bubbled, and the transfer then completes normally. This is
///      deliberate: the vault moves ERC-20 through solmate's SafeTransferLib and the PoolManager's `take`, both of
///      which replace a revert reason with their own, so bubbling would hide which check rejected the reentry. A
///      test can therefore assert on `lastReturn` (for example the `ReentrantCall` selector) and also that the outer
///      operation finished correctly. Arming is one-shot so the inner call cannot recurse through further transfers.
contract ReentrantToken is MockERC20 {
    address public target;
    bytes public payload;
    bool public armed;

    uint256 public attempts;
    bool public lastOk;
    bytes public lastReturn;

    constructor(string memory name, string memory symbol) MockERC20(name, symbol, 18) {}

    /// @notice Make one call to `target_` with `payload_` during the next transfer.
    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        armed = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _reenter();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _reenter();
        return super.transferFrom(from, to, amount);
    }

    /// @notice Selector of the last inner call's revert data (zero if it succeeded or returned nothing).
    function lastSelector() external view returns (bytes4 sel) {
        bytes memory r = lastReturn;
        if (lastOk || r.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            sel := mload(add(r, 0x20))
        }
    }

    function _reenter() internal {
        if (!armed) return;
        armed = false;
        attempts++;
        (lastOk, lastReturn) = target.call(payload);
    }
}

/// @title ReentryAgent — TEST ONLY.
/// @notice A contract account that forwards arbitrary calls and bubbles their reverts. Used as an LP, curator and
///         consumer in reentrancy tests, so that a reentrant call reaches the vault from an address that would
///         otherwise be authorized: the only thing that can reject it is the reentrancy lock.
contract ReentryAgent {
    /// @notice Call `to` with `data` and return its result, bubbling any revert unchanged.
    function exec(address to, bytes calldata data) external returns (bytes memory ret) {
        bool ok;
        (ok, ret) = to.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
