// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IMarketRiskAdapter} from "../../src/interfaces/IMarketRiskAdapter.sol";

/// @notice Market-risk adapter whose answer the test sets directly. It stands for any adapter, honest or not: the
///         vault must stay inside its inventory floor whatever this returns, and must refuse malformed answers.
contract MockRiskAdapter is IMarketRiskAdapter {
    Reading internal _r;
    address internal immutable _c0;
    address internal immutable _c1;
    uint8 internal immutable _d0;
    uint8 internal immutable _d1;
    bytes32 public configVersion;
    bool public broken;

    constructor(address c0, address c1, uint8 d0, uint8 d1, bytes32 version) {
        (_c0, _c1, _d0, _d1, configVersion) = (c0, c1, d0, d1, version);
    }

    /// @param priceX96 Raw currency1 per raw currency0, Q64.96 (any value, including 0).
    /// @param uncertaintyPips Half-width of the band, pips.
    /// @param validUntil Timestamp after which the vault must refuse the reading.
    function set(uint256 priceX96, uint256 uncertaintyPips, uint256 validUntil) external {
        _r = Reading(priceX96, uncertaintyPips, validUntil, 2);
    }

    /// @notice When true, `currentReference` reverts, as a real adapter does on stale or contradictory sources.
    function setBroken(bool b) external {
        broken = b;
    }

    function currentReference() external view returns (Reading memory) {
        require(!broken, "sources unavailable");
        return _r;
    }

    function pair() external view returns (address, address, uint8, uint8) {
        return (_c0, _c1, _d0, _d1);
    }
}
