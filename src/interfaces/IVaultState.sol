// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ISharedCommitmentVault} from "./ISharedCommitmentVault.sol";

/// @title IVaultState
/// @notice Read-only view of the vault's stored accounting: the public getters that off-chain tools and `VaultLens`
///         use to rebuild derived quantities. Every value here is read straight from storage or an immutable; none
///         is computed.
/// @dev `SharedCommitmentVault` inherits this interface, so the compiler checks that each getter exists with exactly
///      these types. Notation follows the vault: B_a = `backing`, Q_a = `reserved`, W_a = `claimableAssets`,
///      S = `totalShares`, P = `pendingShares`.
interface IVaultState is ISharedCommitmentVault {
    /// @notice First asset of the pair (the lower address).
    function asset0() external view returns (Currency);

    /// @notice Second asset of the pair (the higher address).
    function asset1() external view returns (Currency);

    /// @notice B_a: ERC-6909 claims the vault has accounted for, in raw units of `currency`.
    function backing(Currency currency) external view returns (uint256);

    /// @notice Q_a: unused capacity of all unreleased allocations selling `currency`, in raw units.
    function reserved(Currency currency) external view returns (uint256);

    /// @notice W_a: assets finalized for queued redemptions and not yet claimed, in raw units of `currency`.
    function claimableAssets(Currency currency) external view returns (uint256);

    /// @notice S: all outstanding shares, including queued shares and the locked minimum.
    function totalShares() external view returns (uint256);

    /// @notice P: shares escrowed in the withdrawal queue and not yet finalized.
    function pendingShares() external view returns (uint256);

    /// @notice Vault floor and halt flag for the direction that sells `currencyOut`.
    /// @return minInPerOutX96 Floor, Q64.96 raw input per raw output. Zero means the direction was never opened.
    /// @return halted True while the direction is halted.
    function sellPolicy(Currency currencyOut) external view returns (uint160 minInPerOutX96, bool halted);

    /// @notice Stored state of a withdrawal request; an all-zero struct if the id does not exist.
    /// @param requestId Request to read.
    /// @return The request record.
    function getRequest(uint256 requestId) external view returns (WithdrawalRequest memory);
}
