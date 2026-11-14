// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ISharedCommitmentVault} from "./ISharedCommitmentVault.sol";
import {IMarketRiskAdapter} from "./IMarketRiskAdapter.sol";

/// @title IVaultState
/// @notice The vault's read interface: the few reads other contracts call on-chain (`coreInputs` for hooks,
///         `getCurator` and `authModule` for the authorization module, `pendingShares` for the governor, the pair
///         and the flow window), and `extsload`, through which every other stored value is read.
/// @dev `SharedCommitmentVault` inherits this interface, so the compiler checks that each function exists with
///      exactly these types. Stored values not served here (B_a, Q_a, W_a, S, floors, risk parameters, limits,
///      allocations, requests) are decoded from `extsload` by `VaultStateReader`, which `VaultLens` exposes as
///      external functions under the names the values have in the vault. Notation follows the vault:
///      P = `pendingShares`.
interface IVaultState is ISharedCommitmentVault {
    /// @notice First asset of the pair (the lower address).
    function asset0() external view returns (Currency);

    /// @notice Second asset of the pair (the higher address).
    function asset1() external view returns (Currency);

    /// @notice P: shares escrowed in the withdrawal queue and not yet finalized.
    function pendingShares() external view returns (uint256);

    /// @notice Stored record of a curator: registration, restriction and generation. All-zero for an address that
    ///         was never touched (not registered, no restriction, generation 0).
    /// @param curator Curator to read.
    /// @return The curator record.
    function getCurator(address curator) external view returns (CuratorRecord memory);

    /// @notice The authorization module allowed to call `reserveFor`; zero when none is installed.
    function authModule() external view returns (address);

    /// @notice Length of one flow-limit window, in seconds.
    function FLOW_WINDOW() external view returns (uint256);

    /// @notice The vault state a hook prices from in shared-core mode, in one call.
    /// @dev In static mode (no adapter) only `adapter` (zero) is returned and the rest are zero.
    /// @return adapter `riskAdapter`.
    /// @return edgePips `riskEdgePips`.
    /// @return tolerance1Pips `inventoryTolerancePips(1)`.
    /// @return target1PerShare `inventoryTargetPerShare(1)`, raw asset1 per share scaled by 1e18.
    /// @return net1 N_1 = backing - claimable of asset1, raw units.
    /// @return shares S, `totalShares`.
    function coreInputs()
        external
        view
        returns (
            IMarketRiskAdapter adapter,
            uint256 edgePips,
            uint256 tolerance1Pips,
            uint256 target1PerShare,
            uint256 net1,
            uint256 shares
        );

    /// @notice Raw 32-byte word at persistent storage slot `slot` of the vault.
    /// @dev The generic read that v4's PoolManager also offers (`IExtsload.extsload(bytes32)`, same selector).
    ///      `VaultLens` decodes the vault's stored accounting with it; where each variable lives follows Solidity's
    ///      storage-layout rules for the vault's declaration order and is pinned by
    ///      `test/unit/VaultStorageLayout.t.sol`. Reads persistent storage only, so the transient reentrancy lock is
    ///      not visible. No access control: it exposes nothing that `eth_getStorageAt` does not already expose, and
    ///      it writes nothing.
    /// @param slot Storage slot to read.
    /// @return value The stored word; zero for a slot never written.
    function extsload(bytes32 slot) external view returns (bytes32 value);
}
