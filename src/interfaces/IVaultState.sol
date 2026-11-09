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

    /// @notice Stored record of a curator: registration, restriction and generation. All-zero for an address that
    ///         was never touched (not registered, no restriction, generation 0).
    /// @param curator Curator to read.
    /// @return The curator record.
    function getCurator(address curator) external view returns (CuratorRecord memory);

    /// @notice Unused capacity currently held by a hook's unreleased allocations, in raw units of `currency`.
    function hookReserved(address consumer, Currency currency) external view returns (uint256);

    /// @notice Unused capacity currently held by a curator's unreleased allocations, in raw units of `currency`.
    function curatorReserved(address curator, Currency currency) external view returns (uint256);

    /// @notice Length of one flow-limit window, in seconds.
    function FLOW_WINDOW() external view returns (uint256);

    /// @notice Stored risk limits and flow usage of one scope in one asset. All-zero (unconfigured) if never set.
    /// @dev `flowUsed` is the usage of window `epoch`; it is not reset in storage when a window ends, so compare
    ///      `epoch` with block.timestamp / FLOW_WINDOW before reading it as current usage (`VaultLens` does this).
    /// @param scope Hook, Curator or Vault.
    /// @param account The hook or curator; address(0) for the vault scope.
    /// @param currency The asset the limit applies to (the asset the vault sells).
    /// @return The stored record.
    function getRiskLimit(RiskScope scope, address account, Currency currency) external view returns (RiskLimit memory);

    /// @notice Stored state of a withdrawal request; an all-zero struct if the id does not exist.
    /// @param requestId Request to read.
    /// @return The request record.
    function getRequest(uint256 requestId) external view returns (WithdrawalRequest memory);
}
