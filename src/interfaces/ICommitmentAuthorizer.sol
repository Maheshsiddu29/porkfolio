// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ICuratorAuthorization} from "./ICuratorAuthorization.sol";
import {ISharedCommitmentVault} from "./ISharedCommitmentVault.sol";
import {IBondEscrow} from "./IBondEscrow.sol";

/// @title ICommitmentAuthorizer
/// @notice The bonded entry points of `CommitmentAuthorizer`: every reservation it creates is paid for by a bond in its
///         fee escrow, posted in the same transaction.
interface ICommitmentAuthorizer {
    /// @notice A curator's allocation instruction plus the terms of its bond, signed together (EIP-712 nested struct).
    /// @param allocation The allocation instruction, exactly as `ICuratorAuthorization.AllocationAuthorization`.
    /// @param payer The only account that may activate it; the bond is pulled from it and refunded to it.
    /// @param maxRate Highest bond rate the curator accepts, fee units per reserved unit per second times 1e18. The
    ///        activation reverts if the escrow's rate for the reserved asset is higher at that moment.
    struct BondedAuthorization {
        ICuratorAuthorization.AllocationAuthorization allocation;
        address payer;
        uint256 maxRate;
    }

    /// @notice An unbonded entry point was called; this module only creates bonded reservations.
    error BondRequired();
    /// @notice The caller is not the payer named in the signed instruction.
    error NotPayer(address caller);
    /// @notice The escrow given at deployment does not serve this module's vault.
    error EscrowVaultMismatch();

    /// @notice Turn a signed, bonded instruction into an allocation and its bond. Only `auth.payer` may submit it.
    /// @param auth The signed instruction and bond terms.
    /// @param key The pool the instruction names.
    /// @param signature The curator's signature over the `BondedAuthorization` digest (ECDSA or ERC-1271).
    /// @return allocationId Id of the new allocation.
    function activateBonded(BondedAuthorization calldata auth, PoolKey calldata key, bytes calldata signature)
        external
        returns (uint256 allocationId);

    /// @notice The curator reserves itself and pays the bond itself.
    /// @param req The allocation request; `req.nonce` is consumed from the caller's nonce bitmap.
    /// @param maxRate Highest bond rate the caller accepts.
    /// @return allocationId Id of the new allocation.
    function activateDirectBonded(ISharedCommitmentVault.AllocationRequest calldata req, uint256 maxRate)
        external
        returns (uint256 allocationId);

    /// @notice The EIP-712 digest a curator signs for `auth`.
    function hashBondedAuthorization(BondedAuthorization calldata auth) external view returns (bytes32);

    /// @notice The fee escrow every bond is posted to. Fixed at deployment.
    function escrow() external view returns (IBondEscrow);
}
