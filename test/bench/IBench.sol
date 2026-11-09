// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IVaultState} from "../../src/interfaces/IVaultState.sol";

/// @notice The vault entry points the production-artifact tests call. Declared here so that no file in test/bench/
///         imports the vault source: a file that imports it is compiled, with everything it imports, under the
///         vault's optimizer profile (see README.md).
interface IBenchVault is IVaultState {
    function initialDeposit(uint256 amount0, uint256 amount1, address receiver) external returns (uint256);
    function deposit(uint256 shares, uint256 maxAmount0, uint256 maxAmount1, address receiver)
        external
        returns (uint256, uint256);
    function redeem(uint256 shares, uint256 minAmount0, uint256 minAmount1, address receiver, bool queueRemainder)
        external
        returns (uint256, uint256, uint256, uint256);
    function processQueue(uint256 maxSteps) external returns (uint256);
    function cancelRequest(uint256 requestId) external returns (uint256);
    function claim(uint256 requestId) external returns (uint256, uint256);
    function setAuthModule(address module) external;
    function release(uint256 allocationId) external;
    function cancelAllocation(uint256 allocationId) external;
    function setConsumer(address consumer, bool registered) external;
    function setCurator(address curator, bool registered) external;
    function freezeCurator(address curator) external;
    function unfreezeCurator(address curator) external;
    function revokeCurator(address curator) external;
    function bumpGeneration() external returns (uint32);
    function setCuratorCeiling(address curator, Currency currency, uint256 ceiling) external;
    function setRiskLimit(RiskScope scope, address account, Currency currency, uint256 flowCap, uint16 maxReservedBps)
        external;
    function setSellFloor(Currency currencyOut, uint160 minInPerOutX96) external;
    function setSellHalted(Currency currencyOut, bool halted) external;
    function setPaused(bool paused_) external;
    function setGuardian(address newGuardian) external;
    function admissibleCapacity(Currency currency) external view returns (uint256);
    function curatorReserved(address curator, Currency currency) external view returns (uint256);
    function sharesOf(address account) external view returns (uint256);
    function isConsumer(address consumer) external view returns (bool);
}

/// @notice `configurePool` has the same parameter types on both hooks (price, then two pip values).
interface IBenchHook {
    function configurePool(PoolKey calldata key, uint160 priceX96, uint24 a, uint24 b) external;
}
