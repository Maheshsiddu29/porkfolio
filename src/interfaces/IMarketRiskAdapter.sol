// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IMarketRiskAdapter
/// @notice The one market-risk interface the vault and every pricing hook read. The vault holds the address; hooks
///         read it from the vault, so a hook cannot price from an adapter the vault does not enforce.
/// @dev An implementation is read-only and fixed at deployment: changing any feed, threshold or limit means deploying a
///      new adapter, whose installation the vault time-locks. `configVersion` identifies that fixed configuration, so a
///      quote, a log line and an off-chain quoter can name exactly which rules produced a price.
interface IMarketRiskAdapter {
    /// @notice A validated reference.
    /// @param priceX96 Mid, raw currency1 per raw currency0, Q64.96.
    /// @param uncertaintyPips Smallest `u` (pips, rounded up) with `priceX96 / (1 + u) <= p <= priceX96 * (1 + u)` for
    ///        every price `p` the live sources allow: a multiplicative half-width, so widening the mid by `(1 + u)`
    ///        covers the range read as currency1 per currency0, and widening `1 / priceX96` by `(1 + u)` covers it
    ///        read as currency0 per currency1. A half-width measured from the mid alone is not enough for the second
    ///        reading (it falls short by about `u^2`).
    /// @param validUntil Earliest time a source used here passes its staleness limit, seconds.
    /// @param liveSources Number of sources that contributed.
    struct Reading {
        uint256 priceX96;
        uint256 uncertaintyPips;
        uint256 validUntil;
        uint256 liveSources;
    }

    /// @notice The current reference. Reverts when there is no reference the adapter's rules accept (stale, missing,
    ///         contradictory, sequencer down); never returns a stored or default price.
    /// @return The reading.
    function currentReference() external view returns (Reading memory);

    /// @notice Hash of the adapter's complete fixed configuration (feeds, thresholds, staleness limits, sequencer,
    ///         pair, decimals, required sources).
    /// @return The configuration version.
    function configVersion() external view returns (bytes32);

    /// @notice The pair the adapter prices, in PoolKey order, with token decimals.
    /// @return currency0 Lower-address token.
    /// @return currency1 Higher-address token.
    /// @return decimals0 Decimals of `currency0`.
    /// @return decimals1 Decimals of `currency1`.
    function pair() external view returns (address currency0, address currency1, uint8 decimals0, uint8 decimals1);
}
