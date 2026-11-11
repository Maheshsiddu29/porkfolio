// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @notice Settable push feed for adapter tests. Modes: normal answer, revert, short return data, gas burn.
contract MockAggregator is IAggregatorV3 {
    enum Mode {
        Normal,
        Revert,
        ShortReturn,
        BurnGas
    }

    uint8 public immutable override decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint256 public startedAt;
    Mode public mode;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        (answer, updatedAt, startedAt) = (answer_, updatedAt_, updatedAt_);
    }

    /// @dev For the sequencer feed: status (0 up, 1 down) since `since`.
    function setStatus(int256 status, uint256 since) external {
        (answer, startedAt, updatedAt) = (status, since, since);
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        if (mode == Mode.Revert) revert("feed down");
        if (mode == Mode.ShortReturn) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(0, 32)
            }
        }
        if (mode == Mode.BurnGas) {
            uint256 x;
            while (gasleft() > 1000) {
                x = uint256(keccak256(abi.encode(x)));
            }
        }
        return (1, answer, startedAt, updatedAt, 1);
    }
}
