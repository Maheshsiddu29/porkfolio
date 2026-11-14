// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {IMarketRiskAdapter} from "../../src/interfaces/IMarketRiskAdapter.sol";

/// @notice Test-only reference reader: the production vault plus the getters it served before its stored values
///         moved behind `extsload`, reading each internal state variable by name.
/// @dev Adds no state variable, so its storage layout is the vault's. It is the independent side of the lens parity
///      and storage-layout tests: these getters read storage through the compiler's own name resolution, the lens
///      through `VaultStateReader`'s slot numbers, so any disagreement is a decoding or layout error. Never deployed
///      outside tests.
contract VaultGetterHarness is SharedCommitmentVault {
    constructor(IPoolManager poolManager_, address owner_, Currency asset0_, Currency asset1_)
        SharedCommitmentVault(poolManager_, owner_, asset0_, asset1_)
    {}

    function oldBacking(Currency c) external view returns (uint256) {
        return backing[c];
    }

    function oldReserved(Currency c) external view returns (uint256) {
        return reserved[c];
    }

    function oldBufferFloor(Currency c) external view returns (uint256) {
        return bufferFloor[c];
    }

    function oldClaimableAssets(Currency c) external view returns (uint256) {
        return claimableAssets[c];
    }

    function oldSellPolicy(Currency c) external view returns (uint160, bool) {
        SellPolicy memory p = sellPolicy[c];
        return (p.minInPerOutX96, p.halted);
    }

    function oldCuratorCeiling(address a, Currency c) external view returns (uint256) {
        return curatorCeiling[a][c];
    }

    function oldCuratorReserved(address a, Currency c) external view returns (uint256) {
        return curatorReserved[a][c];
    }

    function oldHookReserved(address a, Currency c) external view returns (uint256) {
        return hookReserved[a][c];
    }

    function oldTotalShares() external view returns (uint256) {
        return totalShares;
    }

    function oldSharesOf(address a) external view returns (uint256) {
        return sharesOf[a];
    }

    function oldNextAllocationId() external view returns (uint256) {
        return nextAllocationId;
    }

    function oldNextRequestId() external view returns (uint256) {
        return nextRequestId;
    }

    function oldQueueHead() external view returns (uint256) {
        return queueHead;
    }

    function oldRiskAdapter() external view returns (IMarketRiskAdapter) {
        return riskAdapter;
    }

    function oldRiskEdgePips() external view returns (uint24) {
        return riskEdgePips;
    }

    function oldMaxUncertaintyPips() external view returns (uint24) {
        return maxUncertaintyPips;
    }

    function oldInventoryTargetPerShare(uint256 i) external view returns (uint256) {
        return inventoryTargetPerShare[i];
    }

    function oldInventoryTolerancePips(uint256 i) external view returns (uint24) {
        return inventoryTolerancePips[i];
    }

    function oldGetAllocation(uint256 id) external view returns (Allocation memory) {
        return _allocations[id];
    }

    function oldGetRequest(uint256 id) external view returns (WithdrawalRequest memory) {
        return _requests[id];
    }

    function oldGetRiskLimit(RiskScope scope, address account, Currency c) external view returns (RiskLimit memory) {
        return _riskLimit(scope, account, c);
    }

    /// @dev The vault's own admission limit, `_admissible(currency, _eligibleBacking(currency))`.
    function oldAdmissibleCapacity(Currency c) external view returns (uint256) {
        return _admissible(c, _eligibleBacking(c));
    }
}
