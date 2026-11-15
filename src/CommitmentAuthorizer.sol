// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {CuratorAuthorization} from "./CuratorAuthorization.sol";
import {ICommitmentAuthorizer} from "./interfaces/ICommitmentAuthorizer.sol";
import {ISharedCommitmentVault} from "./interfaces/ISharedCommitmentVault.sol";
import {IVaultState} from "./interfaces/IVaultState.sol";
import {IBondEscrow} from "./interfaces/IBondEscrow.sol";

/// @title CommitmentAuthorizer
/// @notice Authorization module whose every reservation is bonded: it checks the curator's authorization exactly as
///         `CuratorAuthorization` does, asks the vault to reserve, and has the fee escrow record and fund the bond, all
///         in one transaction.
/// @dev
/// Inherits every check of `CuratorAuthorization` unchanged: EIP-712 domain ("Porkfolio Vault", "1", chain id, this
/// contract's address), EOA and ERC-1271 signatures through `SignatureChecker`, the vault field, validity window,
/// deadline before expiry, pool / hook / direction consistency, per-curator nonce bitmaps, generation binding (checked
/// by the vault). It adds the bond terms:
///   - The curator signs `BondedAuthorization(AllocationAuthorization allocation,address payer,uint256 maxRate)`, an
///     EIP-712 struct that embeds the unchanged `AllocationAuthorization` type, so the curator's wallet shows the payer
///     and the highest rate it accepts next to the allocation.
///   - Only `payer` may submit it (`NotPayer`): nobody else can spend the payer's ERC-20 allowance to the escrow or
///     choose when the bond, whose size depends on the time left to expiry, is posted.
///   - After `reserveFor` returns the new allocation's id, `escrow.post(id, payer, maxRate)` fixes the rate (reverting
///     if it is above `maxRate`), computes the bond and pulls it from the payer.
/// A failure anywhere (signature, nonce, any vault check, a rate above `maxRate`, a short allowance or balance, a token
/// that delivers less than asked) reverts the whole activation: no allocation, no bond, no nonce bit, no token moved.
///
/// The unbonded entry points `activate` and `activateDirect` revert with `BondRequired`, so installing this module
/// makes every new reservation bonded. `invalidateNonces` and the views are inherited unchanged. With the escrow's rate
/// at zero the bond is zero and nothing is pulled; the reservation is still recorded in the escrow.
///
/// Holds no assets and no approvals. The payer approves the escrow (not this module) for the reserved asset.
contract CommitmentAuthorizer is CuratorAuthorization, ICommitmentAuthorizer {
    /// @notice EIP-712 type hash of `BondedAuthorization` (its encodeType appends the referenced
    ///         `AllocationAuthorization` type, as EIP-712 requires).
    bytes32 public constant BONDED_AUTHORIZATION_TYPEHASH = keccak256(
        "BondedAuthorization(AllocationAuthorization allocation,address payer,uint256 maxRate)"
        "AllocationAuthorization(address curator,uint32 generation,address vault,bytes32 poolId,address hook,"
        "address currencyIn,address currencyOut,bool zeroForOne,uint128 maxOut,uint160 minInPerOutX96,uint64 expiry,"
        "uint64 validAfter,uint64 deadline,uint256 nonce)"
    );

    /// @inheritdoc ICommitmentAuthorizer
    IBondEscrow public immutable escrow;

    /// @param vault_ The vault this module reserves in.
    /// @param escrow_ The vault's fee escrow; its `vault()` must be `vault_` (`EscrowVaultMismatch`).
    constructor(IVaultState vault_, IBondEscrow escrow_) CuratorAuthorization(vault_) {
        if (address(escrow_) == address(0)) revert ISharedCommitmentVault.ZeroAddress();
        if (address(IEscrowVault(address(escrow_)).vault()) != address(vault_)) revert EscrowVaultMismatch();
        escrow = escrow_;
    }

    /// @notice Disabled: this module only creates bonded reservations (`BondRequired`).
    function activate(AllocationAuthorization calldata, PoolKey calldata, bytes calldata)
        external
        pure
        override
        returns (uint256)
    {
        revert BondRequired();
    }

    /// @notice Disabled: this module only creates bonded reservations (`BondRequired`).
    function activateDirect(ISharedCommitmentVault.AllocationRequest calldata)
        external
        pure
        override
        returns (uint256)
    {
        revert BondRequired();
    }

    /// @inheritdoc ICommitmentAuthorizer
    /// @dev Requires msg.sender == auth.payer, then runs `CuratorAuthorization`'s signed-path checks with the bonded
    ///      digest, the nonce bit and `reserveFor`, then `escrow.post`. See the contract documentation.
    function activateBonded(BondedAuthorization calldata auth, PoolKey calldata key, bytes calldata signature)
        external
        returns (uint256 allocationId)
    {
        if (msg.sender != auth.payer) revert NotPayer(msg.sender);
        allocationId = _activateSigned(auth.allocation, key, _bondedDigest(auth), signature);
        escrow.post(allocationId, auth.payer, auth.maxRate);
    }

    /// @inheritdoc ICommitmentAuthorizer
    /// @dev The caller is both the curator and the payer. Runs `CuratorAuthorization`'s direct path, then
    ///      `escrow.post(id, msg.sender, maxRate)`.
    function activateDirectBonded(ISharedCommitmentVault.AllocationRequest calldata req, uint256 maxRate)
        external
        returns (uint256 allocationId)
    {
        allocationId = _activateDirect(req);
        escrow.post(allocationId, msg.sender, maxRate);
    }

    /// @inheritdoc ICommitmentAuthorizer
    /// @dev keccak256("\x19\x01" || domainSeparator || hashStruct(auth)), where hashStruct(auth) =
    ///      keccak256(abi.encode(BONDED_AUTHORIZATION_TYPEHASH, hashStruct(auth.allocation), auth.payer, auth.maxRate))
    ///      and hashStruct(auth.allocation) is the unbonded module's struct hash.
    function hashBondedAuthorization(BondedAuthorization calldata auth) external view returns (bytes32) {
        return _bondedDigest(auth);
    }

    function _bondedDigest(BondedAuthorization calldata auth) internal view returns (bytes32) {
        bytes32 allocationHash = keccak256(abi.encode(ALLOCATION_AUTHORIZATION_TYPEHASH, auth.allocation));
        return _hashTypedDataV4(
            keccak256(abi.encode(BONDED_AUTHORIZATION_TYPEHASH, allocationHash, auth.payer, auth.maxRate))
        );
    }
}

/// @dev The escrow's `vault()` getter, read once at deployment.
interface IEscrowVault {
    function vault() external view returns (address);
}
