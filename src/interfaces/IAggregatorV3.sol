// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IAggregatorV3
/// @notice The read interface of a Chainlink-style push price feed. RedStone's push feeds on Unichain implement the
///         same functions (verified read-only on Unichain mainnet, chain 130; see
///         docs/architecture/ORACLE_VERIFICATION_UNICHAIN.md).
/// @dev Only the functions the price-risk adapter uses. `answer` is the price with `decimals()` decimals; `updatedAt`
///      is the timestamp of the answer. RedStone's feeds report round id 1 for every answer and revert on historical
///      rounds, so nothing here relies on round history.
interface IAggregatorV3 {
    /// @return Number of decimals in `answer`.
    function decimals() external view returns (uint8);

    /// @return roundId Feed-specific round identifier.
    /// @return answer Price, scaled by `10^decimals()`.
    /// @return startedAt Round start, seconds.
    /// @return updatedAt Time the answer was written, seconds.
    /// @return answeredInRound Legacy field.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
