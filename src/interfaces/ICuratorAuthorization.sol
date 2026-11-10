// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ISharedCommitmentVault} from "./ISharedCommitmentVault.sol";
import {IVaultState} from "./IVaultState.sol";

/// @title ICuratorAuthorization
/// @notice Entry points, signed message, errors and events of `CuratorAuthorization`, the contract that turns a
///         curator's instruction (signed, or sent by the curator itself) into a reservation request to its vault.
interface ICuratorAuthorization {
    /// @notice One allocation instruction, as the curator signs it with EIP-712.
    /// @dev Every field is signed, so a relayer cannot change any of them. `curator`, `generation`, `vault` and
    ///      `nonce` say who authorizes and under which conditions; the remaining fields describe exactly one
    ///      allocation. `poolId`, `hook`, `currencyIn`, `currencyOut` and `zeroForOne` overlap (the pool id commits to
    ///      both currencies and the hook), and the module checks that they all agree with the PoolKey submitted
    ///      alongside, so the curator's wallet can display them and a mistake in any one of them fails.
    /// @param curator        Address that authorizes the allocation: an EOA (ECDSA) or a contract wallet (ERC-1271).
    /// @param generation     The curator's generation in the vault when signing. The vault rejects the instruction
    ///                       once the generation has moved on (deregistration, unfreeze, or the curator's own bump).
    /// @param vault          The vault that may reserve the capacity. Must equal this module's vault.
    /// @param poolId         v4 pool id (keccak256 of the PoolKey) of the pool whose hook may consume the allocation.
    /// @param hook           The hook (consumer) that may consume it; must be the pool's `hooks` address.
    /// @param currencyIn     Currency the vault receives when the allocation is consumed.
    /// @param currencyOut    Currency the vault pays out.
    /// @param zeroForOne     Swap direction that consumes it: true when the trader pays currency0 and receives
    ///                       currency1, so the vault sells currency1.
    /// @param maxOut         Capacity: most raw units of `currencyOut` the allocation may pay out in total.
    /// @param minInPerOutX96 Curator floor: minimum raw input per raw output, Q64.96.
    /// @param expiry         Unix time from which the allocation can no longer be consumed. Required by the vault
    ///                       (at most MAX_HORIZON after activation); this is the allocation's lifetime, not the
    ///                       instruction's.
    /// @param validAfter     Earliest Unix time at which the instruction may be activated (inclusive). At most
    ///                       `deadline`.
    /// @param deadline       Latest Unix time at which the instruction may be activated (inclusive). At most
    ///                       MAX_VALIDITY_WINDOW after `validAfter`, and before `expiry`.
    /// @param nonce          Any unused number chosen by the curator; nonces need not be used in order.
    struct AllocationAuthorization {
        address curator;
        uint32 generation;
        address vault;
        PoolId poolId;
        address hook;
        Currency currencyIn;
        Currency currencyOut;
        bool zeroForOne;
        uint128 maxOut;
        uint160 minInPerOutX96;
        uint64 expiry;
        uint64 validAfter;
        uint64 deadline;
        uint256 nonce;
    }

    /// @notice The vault address in the signed message is not this module's vault.
    error WrongVault(address signedVault);
    /// @notice The instruction's `validAfter` is later than its `deadline`, so it could never be activated.
    error InvalidValidityWindow(uint64 validAfter, uint64 deadline);
    /// @notice The instruction's activation window (deadline - validAfter) is longer than MAX_VALIDITY_WINDOW.
    error ValidityWindowTooLong(uint64 validAfter, uint64 deadline);
    /// @notice The allocation's `expiry` is not after the instruction's `deadline`, so an activation inside the window
    ///         could create an allocation that is already expired or about to expire.
    error ExpiryNotAfterDeadline(uint64 expiry, uint64 deadline);
    /// @notice `block.timestamp` is before the instruction's `validAfter`.
    error AuthorizationNotYetValid(uint64 validAfter);
    /// @notice `block.timestamp` is after the instruction's `deadline`.
    error AuthorizationExpired(uint64 deadline);
    /// @notice The submitted PoolKey does not hash to the signed `poolId`.
    error PoolKeyMismatch();
    /// @notice The signed hook is not the submitted pool's `hooks` address.
    error HookMismatch();
    /// @notice The signed currencies and direction do not describe one direction of the submitted pool.
    error DirectionMismatch();
    /// @notice The signature is not valid for `curator` over this instruction (wrong signer, malformed, or the
    ///         curator's ERC-1271 wallet rejected it, reverted or returned no answer).
    error InvalidSignature();
    /// @notice This (curator, nonce) pair has already activated an allocation or was invalidated.
    error NonceAlreadyUsed(address curator, uint256 nonce);

    /// @notice An instruction became allocation `allocationId`.
    /// @param curator The curator the allocation belongs to.
    /// @param nonce The nonce the activation consumed.
    /// @param allocationId Id assigned by the vault.
    /// @param signed True for a signed activation (`activate`), false for the curator's own call (`activateDirect`).
    event Activated(address indexed curator, uint256 indexed nonce, uint256 indexed allocationId, bool signed);
    /// @notice The curator marked the nonces in `mask` of word `wordPos` as used.
    event NoncesInvalidated(address indexed curator, uint256 indexed wordPos, uint256 mask);

    /// @notice Turn a signed instruction into an allocation. Anyone may submit it.
    /// @param auth The signed instruction.
    /// @param key The pool the instruction names; must hash to `auth.poolId`.
    /// @param signature 65-byte ECDSA signature by `auth.curator`, or whatever its ERC-1271 wallet accepts.
    /// @return allocationId Id of the new allocation.
    function activate(AllocationAuthorization calldata auth, PoolKey calldata key, bytes calldata signature)
        external
        returns (uint256 allocationId);

    /// @notice Turn the caller's own instruction into an allocation; the caller is the curator.
    /// @param req The allocation request; `req.nonce` is consumed from the caller's nonce bitmap.
    /// @return allocationId Id of the new allocation.
    function activateDirect(ISharedCommitmentVault.AllocationRequest calldata req)
        external
        returns (uint256 allocationId);

    /// @notice Mark nonces of the caller as used so that no instruction carrying them can ever activate.
    /// @param wordPos Bitmap word: nonces wordPos * 256 to wordPos * 256 + 255.
    /// @param mask Bits to set; bit i stands for nonce wordPos * 256 + i.
    function invalidateNonces(uint256 wordPos, uint256 mask) external;

    /// @notice Longest activation window a signed instruction may have: deadline - validAfter, in seconds (one day).
    /// @dev Bounds how long an instruction stays usable once it becomes valid. It does not bound how long before its
    ///      window the instruction was signed; see the contract's documentation.
    function MAX_VALIDITY_WINDOW() external view returns (uint64);

    /// @notice The vault this module reserves capacity in. Fixed at deployment.
    /// @dev The vault requires this to be its own address before installing the module (`setAuthModule`).
    function vault() external view returns (IVaultState);

    /// @notice Says what kind of contract this is: always AUTH_MODULE_ID (declared in ISharedCommitmentVault.sol).
    /// @dev The vault requires this value before installing a module (`setAuthModule`), so that a contract built for
    ///      another purpose, such as a consumer hook, is refused even if it has a `vault()` getter naming the vault.
    ///      It is a fixed public label, not a secret and not a proof of what the code does: a malicious contract can
    ///      return it too.
    /// @return The constant AUTH_MODULE_ID.
    function authModuleId() external pure returns (bytes32);

    /// @notice The EIP-712 digest a curator signs for `auth`.
    function hashAuthorization(AllocationAuthorization calldata auth) external view returns (bytes32);

    /// @notice The EIP-712 domain separator for the current chain.
    function domainSeparator() external view returns (bytes32);

    /// @notice One 256-bit word of a curator's nonce bitmap.
    function nonceBitmap(address curator, uint256 wordPos) external view returns (uint256);

    /// @notice Whether `nonce` of `curator` has been consumed or invalidated.
    function isNonceUsed(address curator, uint256 nonce) external view returns (bool);
}
