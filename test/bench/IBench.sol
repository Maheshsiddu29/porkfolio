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
    function isConsumer(address consumer) external view returns (bool);
}

/// @notice HookA_DynamicFee's configuration and pricing views.
interface IBenchHookA {
    function configurePool(
        PoolKey calldata key,
        uint160 priceX96,
        uint24 baseFeePips,
        uint24 maxFeePips,
        uint128 scale0,
        uint128 scale1,
        uint32 decayWindow
    ) external;
    function quote(PoolKey calldata key, bool zeroForOne, uint256 amountIn) external view returns (uint256);
    function flowLevel(PoolKey calldata key, bool zeroForOne) external view returns (uint256);
}

/// @notice HookB_BoundedImpact's configuration and pricing views.
interface IBenchHookB {
    function configurePool(
        PoolKey calldata key,
        uint160 priceX96,
        uint96 depth,
        uint24 maxImpactPips,
        uint32 decayWindow
    ) external;
    function quote(PoolKey calldata key, bool zeroForOne, uint256 amountIn) external view returns (uint256);
    function positionOf(PoolKey calldata key) external view returns (int256);
}

/// @notice The public `vault()` getter that the hooks and the authorization module share.
interface IBenchVaultBound {
    function vault() external view returns (address);
}

/// @notice The `VaultGovernor` functions the benchmark calls.
interface IBenchGovernor {
    function queue(address target, bytes calldata data) external returns (bytes32 id, uint256 when);
    function execute(address target, bytes calldata data) external returns (bytes memory result);
    function acceptVaultOwnership() external;
}
