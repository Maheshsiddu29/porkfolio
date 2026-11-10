// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ICuratorAuthorization} from "./interfaces/ICuratorAuthorization.sol";
import {ISharedCommitmentVault, AUTH_MODULE_ID} from "./interfaces/ISharedCommitmentVault.sol";
import {IVaultState} from "./interfaces/IVaultState.sol";

/// @title CuratorAuthorization
/// @notice Checks who is asking for a reservation and passes the request to one vault. A curator either signs an
///         allocation instruction off-chain (EIP-712; anyone may submit it) or sends the request itself. This contract
///         proves only that the curator authorized that exact request, once; the vault then decides whether the
///         capital can be reserved.
/// @dev
/// Trust boundary. The vault accepts `reserveFor` only from the module it has installed, and treats the call as
/// "this curator authorized this request under this generation". Everything else is decided by the vault on its own
/// state: curator registration, restriction and generation; hook and pool; pair and direction; floors; capacity,
/// ceiling, admission, exposure caps and their configuration; deadline and expiry. This contract holds no claims and
/// no assets, has no operator rights, and cannot consume, cancel, release, swap, change limits, register anyone or
/// touch LP balances. It is not on the swap path or any LP path: if it is broken, disabled or replaced, swaps, LP
/// deposits, redemptions, claims, cancellation and release keep working. A compromised module is equivalent to every
/// registered, unrestricted curator signing whatever the attacker wants, bounded by those curators' ceilings and
/// every vault-side limit.
///
/// Domain. EIP-712 with name "Porkfolio Vault", version "1", the current chain id and this contract's address as
/// verifying contract. OpenZeppelin's `EIP712` caches the separator and rebuilds it if the chain id changes, so a
/// signature made for one chain never verifies on another (for example after a fork). A replacement module has a
/// different address, so signatures made for an old module never verify on a new one. The vault address is also a
/// signed field and is checked against `vault`.
///
/// Nonces. Each curator has its own bitmap: nonce n is bit n % 256 of word n / 256. A bit is set when an instruction
/// with that nonce activates (signed or direct) or when the curator invalidates it, and is never cleared. Example:
/// nonce 515 is bit 3 of word 2. Nonces are unordered: a curator may use 7, then 3, then 1,000. Curators have
/// independent bitmaps, so two curators may both use nonce 7. A failed activation reverts as a whole, including
/// the bit, so a nonce is spent only by an allocation that exists, or by an explicit invalidation.
///
/// Generations. The vault keeps a generation counter per curator that only rises (deregistration, unfreeze, or the
/// curator's own `bumpGeneration`). A signed instruction names the generation it was signed under, and the vault
/// rejects it once the counter has moved on, so one call invalidates every outstanding signature of that curator
/// without touching nonces. Example: a curator signs at generation 7; the guardian deregisters it (8); the owner
/// registers it again (still 8). The instruction signed at 7 can never activate. On the direct path the curator is
/// the caller, so the module passes the current generation read from the vault in the same call.
///
/// Signatures. OpenZeppelin `SignatureChecker`: first ECDSA (65-byte signatures with low `s` only, no revert on bad
/// input), accepted if the recovered address is the curator; otherwise the curator's ERC-1271 `isValidSignature`
/// through `staticcall`, accepted only if it returns the magic value. An EOA with a bad signature fails, because a
/// call to an address without code returns no data. A wallet that reverts, returns garbage or runs out of gas fails
/// closed. The wallet runs inside `staticcall`, so it cannot change state here or anywhere else; it can only make the
/// submitter's transaction more expensive. A wallet's answer matters only at activation: once the allocation exists,
/// a later change of the wallet's signing policy does not alter it (the curator can cancel it in the vault).
///
/// Time fields. A signed instruction carries three times, all Unix seconds chosen by the curator: `validAfter` and
/// `deadline` bound when it may be activated (both inclusive), and `expiry` is when the resulting allocation stops
/// being consumable. This contract requires validAfter <= deadline < expiry and deadline - validAfter <=
/// MAX_VALIDITY_WINDOW, before looking at the clock. So every instruction that activates produces an allocation that
/// is still live when the activation window closes, and once an instruction becomes valid it stays usable for at
/// most one day. Example: validAfter = 1,000, deadline = 4,600 and expiry = 90,000 is accepted at any time from 1,000
/// to 4,600; deadline = 87,401 (window one second over a day) is rejected, as is expiry = 4,600. The vault then
/// requires expiry <= activation time + MAX_HORIZON. The direct path applies only deadline < expiry: the curator is
/// the caller, so there is no instruction for anyone else to hold.
///
/// What the window bound does not cover. The contract cannot know when an instruction was signed: all three times
/// are the signer's choice. A curator can sign an instruction whose window opens in a year; it is valid then, for at
/// most a day. Bounding how old a signature may be when it is used needs a signed issuance time, which this message
/// type does not have. Until then, outstanding instructions are cancelled with `invalidateNonces` (one nonce at a
/// time) or the vault's `bumpGeneration` (all of them), and die when this module is retired.
///
/// Order of an activation: check the signed fields against the submitted pool and the clock, verify the signature,
/// set the nonce bit (reverting if already set), then call the vault, which is the last action. There is no
/// reentrancy guard: the only foreign code that runs is the wallet inside `staticcall`, and the vault never calls
/// this contract.
///
/// Installation. Before installing this contract, the vault reads `authModuleId()` and `vault()` and requires
/// AUTH_MODULE_ID and its own address. That only shows the contract claims to be a module for that vault; any
/// contract can make the same claim, so the deployed code must still be checked against the reviewed build.
///
/// The contract has no owner, no upgrade mechanism and no way to clear a nonce. It is retired by the vault owner
/// installing another module or by the guardian disabling it in the vault (`setAuthModule`); the vault never
/// accepts a retired module again, so its unused signatures can never become valid.
contract CuratorAuthorization is ICuratorAuthorization, EIP712 {
    /// @notice EIP-712 type hash of `AllocationAuthorization`.
    bytes32 public constant ALLOCATION_AUTHORIZATION_TYPEHASH = keccak256(
        "AllocationAuthorization(address curator,uint32 generation,address vault,bytes32 poolId,address hook,"
        "address currencyIn,address currencyOut,bool zeroForOne,uint128 maxOut,uint160 minInPerOutX96,uint64 expiry,"
        "uint64 validAfter,uint64 deadline,uint256 nonce)"
    );

    /// @inheritdoc ICuratorAuthorization
    uint64 public constant MAX_VALIDITY_WINDOW = 1 days;

    /// @inheritdoc ICuratorAuthorization
    IVaultState public immutable vault;

    /// @inheritdoc ICuratorAuthorization
    mapping(address curator => mapping(uint256 wordPos => uint256 bits)) public nonceBitmap;

    /// @param vault_ The vault this module will request reservations from. It cannot be changed later; a module for
    ///        another vault is a separate deployment.
    constructor(IVaultState vault_) EIP712("Porkfolio Vault", "1") {
        if (address(vault_) == address(0)) revert ISharedCommitmentVault.ZeroAddress();
        vault = vault_;
    }

    /// @inheritdoc ICuratorAuthorization
    /// @dev Checks, in order: `auth.vault` is this module's vault; validAfter <= deadline; deadline - validAfter <=
    ///      MAX_VALIDITY_WINDOW; deadline < expiry; validAfter <= block.timestamp <= deadline (both inclusive); `key`
    ///      hashes to `auth.poolId` and its `hooks` is `auth.hook`; the signed currencies and
    ///      `zeroForOne` describe one direction of `key` (zeroForOne: currency0 in, currency1 out); the signature is
    ///      valid for `auth.curator`; the nonce is unused. Then sets the nonce bit and calls
    ///      `vault.reserveFor(req, auth.curator, auth.generation)`, where `req` carries the signed hook, key,
    ///      currencyOut, maxOut, floor, expiry, nonce and deadline. Any revert, including every vault-side check,
    ///      undoes the nonce bit. The vault's checks are listed on `reserveFor`.
    function activate(AllocationAuthorization calldata auth, PoolKey calldata key, bytes calldata signature)
        external
        returns (uint256 allocationId)
    {
        if (auth.vault != address(vault)) revert WrongVault(auth.vault);
        // The time fields must be consistent before the clock is consulted. The subtraction cannot underflow: the
        // first check guarantees deadline >= validAfter.
        if (auth.validAfter > auth.deadline) revert InvalidValidityWindow(auth.validAfter, auth.deadline);
        if (auth.deadline - auth.validAfter > MAX_VALIDITY_WINDOW) {
            revert ValidityWindowTooLong(auth.validAfter, auth.deadline);
        }
        _requireExpiryAfterDeadline(auth.expiry, auth.deadline);
        if (block.timestamp < auth.validAfter) revert AuthorizationNotYetValid(auth.validAfter);
        if (block.timestamp > auth.deadline) revert AuthorizationExpired(auth.deadline);
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(auth.poolId)) revert PoolKeyMismatch();
        if (address(key.hooks) != auth.hook) revert HookMismatch();
        bool forward = auth.currencyIn == key.currency0 && auth.currencyOut == key.currency1;
        bool backward = auth.currencyIn == key.currency1 && auth.currencyOut == key.currency0;
        if (auth.zeroForOne ? !forward : !backward) revert DirectionMismatch();

        if (!SignatureChecker.isValidSignatureNow(auth.curator, _digest(auth), signature)) revert InvalidSignature();
        _useNonce(auth.curator, auth.nonce);

        allocationId = vault.reserveFor(
            ISharedCommitmentVault.AllocationRequest({
                consumer: auth.hook,
                key: key,
                currencyOut: auth.currencyOut,
                maxOut: auth.maxOut,
                minInPerOutX96: auth.minInPerOutX96,
                expiry: auth.expiry,
                nonce: auth.nonce,
                deadline: auth.deadline
            }),
            auth.curator,
            auth.generation
        );
        emit Activated(auth.curator, auth.nonce, allocationId, true);
    }

    /// @inheritdoc ICuratorAuthorization
    /// @dev The curator is `msg.sender`; no signature is involved and no curator address is taken from the input.
    ///      `req.nonce` is consumed from the same bitmap as signed instructions. That is what lets a curator who
    ///      signed an instruction and then decides to submit it itself do so safely: whichever arrives first spends
    ///      the nonce and the other reverts, so one instruction never becomes two allocations. It also makes a
    ///      retried submission idempotent. The generation passed to the vault is the one the vault holds now (read
    ///      in this call), so the vault's generation check always passes here; registration, restriction and every
    ///      financial check apply exactly as for a signed activation. Like the signed path, it requires
    ///      `req.deadline` < `req.expiry` (`ExpiryNotAfterDeadline`), so the same request has the same outcome on both
    ///      paths. There is no `validAfter` and no window bound here: the request is the curator's own transaction.
    ///      `req.deadline` is checked against the clock by the vault.
    function activateDirect(ISharedCommitmentVault.AllocationRequest calldata req)
        external
        returns (uint256 allocationId)
    {
        _requireExpiryAfterDeadline(req.expiry, req.deadline);
        _useNonce(msg.sender, req.nonce);
        uint32 generation = vault.getCurator(msg.sender).generation;
        allocationId = vault.reserveFor(req, msg.sender, generation);
        emit Activated(msg.sender, req.nonce, allocationId, false);
    }

    /// @inheritdoc ICuratorAuthorization
    /// @dev Only the caller's own bitmap changes. Bits are only ever set, so calling it again, or with bits already
    ///      used, changes nothing. Works whatever the curator's state in the vault and whether or not this module is
    ///      still installed.
    function invalidateNonces(uint256 wordPos, uint256 mask) external {
        nonceBitmap[msg.sender][wordPos] |= mask;
        emit NoncesInvalidated(msg.sender, wordPos, mask);
    }

    /// @inheritdoc ICuratorAuthorization
    /// @dev keccak256("\x19\x01" || domainSeparator || keccak256(abi.encode(typehash, auth))). Every field of the
    ///      struct is a static type, so `abi.encode(typehash, auth)` is exactly EIP-712's `encodeData` (each value as
    ///      one 32-byte word; `bool` as 0 or 1, `bytes32` for the pool id).
    function hashAuthorization(AllocationAuthorization calldata auth) external view returns (bytes32) {
        return _digest(auth);
    }

    /// @inheritdoc ICuratorAuthorization
    function authModuleId() external pure returns (bytes32) {
        return AUTH_MODULE_ID;
    }

    /// @inheritdoc ICuratorAuthorization
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @inheritdoc ICuratorAuthorization
    function isNonceUsed(address curator, uint256 nonce) external view returns (bool) {
        return nonceBitmap[curator][nonce >> 8] & (1 << (nonce & 0xff)) != 0;
    }

    /// @dev Reverts with `ExpiryNotAfterDeadline` unless the allocation outlives the activation window
    ///      (deadline < expiry). Without it, an instruction activated near its deadline could produce an allocation
    ///      that is already expired, or that lives only a few seconds, while still spending the curator's nonce.
    function _requireExpiryAfterDeadline(uint64 expiry, uint64 deadline) internal pure {
        if (expiry <= deadline) revert ExpiryNotAfterDeadline(expiry, deadline);
    }

    /// @dev Sets bit `nonce % 256` of word `nonce / 256` in the curator's bitmap, reverting with `NonceAlreadyUsed`
    ///      if it is already set.
    function _useNonce(address curator, uint256 nonce) internal {
        uint256 bit = 1 << (nonce & 0xff);
        mapping(uint256 => uint256) storage bitmap = nonceBitmap[curator];
        uint256 word = bitmap[nonce >> 8];
        if (word & bit != 0) revert NonceAlreadyUsed(curator, nonce);
        bitmap[nonce >> 8] = word | bit;
    }

    /// @dev EIP-712 digest of `auth` under this module's domain on the current chain (see `hashAuthorization`).
    function _digest(AllocationAuthorization calldata auth) internal view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(ALLOCATION_AUTHORIZATION_TYPEHASH, auth)));
    }
}
