// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @title TestnetAggregator
/// @notice TEST ONLY. A USD price feed whose answer its deployer sets by hand, for the Unichain Sepolia rehearsal where
///         the production feeds may not exist. Never configure it in a mainnet adapter: whoever holds `operator` sets
///         the price. `VerifyDeployment` refuses an adapter whose `configVersion` differs from the reviewed one.
/// @dev Same `latestRoundData` shape as Chainlink. The round id increases with every update.
contract TestnetAggregator is IAggregatorV3 {
    /// @notice The only account that may set the answer.
    address public immutable operator;
    /// @notice Answer scale, as in Chainlink USD feeds (8).
    uint8 public immutable override decimals;
    int256 internal _answer;
    uint256 internal _updatedAt;
    uint80 internal _round;

    error NotOperator();

    /// @param operator_ Account allowed to post answers.
    /// @param decimals_ Answer decimals.
    constructor(address operator_, uint8 decimals_) {
        operator = operator_;
        decimals = decimals_;
    }

    /// @notice Post `answer` as of `updatedAt` (seconds; not in the future).
    function set(int256 answer, uint256 updatedAt) external {
        if (msg.sender != operator) revert NotOperator();
        (_answer, _updatedAt) = (answer, updatedAt);
        ++_round;
    }

    /// @inheritdoc IAggregatorV3
    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (_round, _answer, _updatedAt, _updatedAt, _round);
    }
}
