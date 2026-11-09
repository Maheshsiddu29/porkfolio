// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {CuratorAuthorization} from "../../src/CuratorAuthorization.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {ICuratorAuthorization} from "../../src/interfaces/ICuratorAuthorization.sol";
import {AuthTestBase} from "../utils/AuthTestBase.sol";
import {Mock1271Wallet} from "../utils/Mock1271Wallet.sol";
import {ProductionArtifacts} from "../utils/ProductionArtifacts.sol";

/// @dev Foundry's EIP-712 encoder (Rust, alloy), available as a cheatcode but not declared in this forge-std version.
interface ITypedDataEncoder {
    function eip712HashTypedData(string calldata jsonData) external pure returns (bytes32);
}

/// @notice Signed and direct curator authorization through `CuratorAuthorization`, against the production builds of
///         the module, the vault, both hooks and the PoolManager (`VaultTestBase`).
/// @dev What each group proves:
///      - Digest: the module's digest equals two encoders that share no code with it (a hand-written Solidity
///        encoding of every field, and forge's typed-data encoder fed JSON), plus a vector computed with `cast`.
///      - Terms: every signed field is bound; a relayer that changes any one of them is rejected.
///      - Signatures: wrong signer, malformed and malleable signatures, and every ERC-1271 failure mode fail closed;
///        a wallet's reentry attempt runs under `staticcall` and changes nothing.
///      - Replay: other chain, other vault, other module, same nonce, invalidated nonce; signed and direct paths share
///        one bitmap; a reverted activation does not spend its nonce.
///      - Generations: every rise of the generation (bump, deregistration, unfreeze) kills unactivated signatures, and
///        re-registration cannot bring them back; the counter's upper limit fails permanently but safely.
///      - Equivalence: the same request through the signed and the direct path produces the same allocation or the
///        same revert.
contract CuratorAuthorizationTest is AuthTestBase {
    ITypedDataEncoder internal constant TYPED =
        ITypedDataEncoder(address(uint160(uint256(keccak256("hevm cheat code")))));

    string internal constant TYPE_STRING = "AllocationAuthorization(address curator,uint32 generation,address vault,"
        "bytes32 poolId,address hook,address currencyIn,address currencyOut,bool zeroForOne,uint128 maxOut,"
        "uint160 minInPerOutX96,uint64 expiry,uint64 validAfter,uint64 deadline,uint256 nonce)";
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    /// @dev secp256k1 group order, for building the high-s twin of a valid signature.
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    // ------------------------------------------------------------------
    // Digest and domain
    // ------------------------------------------------------------------

    function test_CA_typehashAndDomain() public view {
        assertEq(auth.ALLOCATION_AUTHORIZATION_TYPEHASH(), keccak256(bytes(TYPE_STRING)));
        (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifying, bytes32 salt,) =
            auth.eip712Domain();
        assertEq(fields, hex"0f", "name, version, chainId, verifyingContract");
        assertEq(name, "Porkfolio Vault");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifying, address(auth));
        assertEq(salt, bytes32(0));
        assertEq(auth.domainSeparator(), _domainSeparator(address(auth)));
        assertEq(address(auth.vault()), address(vault));
    }

    /// @notice A fixed vector computed outside Solidity with Foundry's `cast` (`cast abi-encode` and `cast keccak`
    ///         over the type string, the field values and the domain), recorded in the Phase 1B-2.3 report.
    function test_CA_digestFixedVector() public {
        address m = address(0xA11CE);
        deployCodeTo(ProductionArtifacts.authModule(), abi.encode(address(0x5AFE)), m);
        vm.chainId(130);
        ICuratorAuthorization.AllocationAuthorization memory a = ICuratorAuthorization.AllocationAuthorization({
            curator: 0x1111111111111111111111111111111111111111,
            generation: 7,
            vault: address(0x5AFE),
            poolId: PoolId.wrap(0x0101010101010101010101010101010101010101010101010101010101010101),
            hook: address(0x88),
            currencyIn: Currency.wrap(address(0xA)),
            currencyOut: Currency.wrap(address(0xB)),
            zeroForOne: true,
            maxOut: 1000 ether,
            minInPerOutX96: uint160(1 << 96),
            expiry: 1_700_086_400,
            validAfter: 1_700_000_000,
            deadline: 1_700_003_600,
            nonce: 515
        });
        assertEq(
            CuratorAuthorization(m).ALLOCATION_AUTHORIZATION_TYPEHASH(),
            0xcb4cfc7767b621ddeb34acc1b69cf9068f48b1e6ef9d43c8a8d8a172e04761c5
        );
        assertEq(
            CuratorAuthorization(m).domainSeparator(),
            0x7eadba32d9831f3fe832fd86a5d56ec29fb4b168b219eb4d231499b5eb966b98
        );
        assertEq(
            CuratorAuthorization(m).hashAuthorization(a),
            0x36606823eec29c7e90a97c3aae053e20ecf83a162fa41db44e9a6f66c4c029e7
        );
    }

    /// @notice For arbitrary field values the module's digest equals a field-by-field Solidity encoding and forge's
    ///         typed-data encoder (alloy) given the same message as JSON.
    function testFuzz_CA_digestMatchesIndependentEncoders(ICuratorAuthorization.AllocationAuthorization memory a)
        public
        view
    {
        bytes32 digest = auth.hashAuthorization(a);
        bytes memory head = abi.encode(
            keccak256(bytes(TYPE_STRING)), a.curator, a.generation, a.vault, PoolId.unwrap(a.poolId), a.hook
        );
        bytes memory tail = abi.encode(
            Currency.unwrap(a.currencyIn),
            Currency.unwrap(a.currencyOut),
            a.zeroForOne,
            a.maxOut,
            a.minInPerOutX96,
            a.expiry,
            a.validAfter,
            a.deadline,
            a.nonce
        );
        bytes32 structHash = keccak256(bytes.concat(head, tail));
        assertEq(digest, keccak256(abi.encodePacked("\x19\x01", _domainSeparator(address(auth)), structHash)));
        assertEq(digest, TYPED.eip712HashTypedData(_json(a, address(auth))));
    }

    // ------------------------------------------------------------------
    // Signed EOA path
    // ------------------------------------------------------------------

    /// @notice A relayer with no role submits the curator's signature; the allocation is exactly the signed one and
    ///         a hook can consume it.
    function test_CA_signedEOA_relayerActivates_thenSwap() public {
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(signer, keyA, c1, 100_000 ether);
        bytes memory sig = _sign(signerKey, a);
        uint256 expectedId = vault.nextAllocationId();
        vm.expectEmit(address(auth));
        emit ICuratorAuthorization.Activated(signer, a.nonce, expectedId, true);
        uint256 id = _activate(a, keyA, sig);
        assertEq(id, expectedId);

        ISharedCommitmentVault.Allocation memory al = vault.getAllocation(id);
        assertEq(al.curator, signer);
        assertEq(al.consumer, address(hookA));
        assertEq(PoolId.unwrap(al.poolId), PoolId.unwrap(keyA.toId()));
        assertTrue(al.currencyIn == c0 && al.currencyOut == c1);
        assertEq(al.maxOut, a.maxOut);
        assertEq(al.minInPerOutX96, a.minInPerOutX96);
        assertEq(al.expiry, a.expiry);
        assertEq(al.consumed, 0);
        assertFalse(al.released);
        assertTrue(auth.isNonceUsed(signer, a.nonce));
        assertFalse(auth.isNonceUsed(relayer, a.nonce), "the submitter's bitmap is not touched");

        _swap(keyA, true, 1000 ether, id);
        assertGt(vault.getAllocation(id).consumed, 0);
        _assertAccountingConsistent();
    }

    /// @notice Each signed field is bound: changing any one of them after signing is rejected, by the field's own
    ///         consistency check where it has one and otherwise by the signature check. The untouched instruction
    ///         still activates afterwards, so none of the failures spent the nonce.
    function test_CA_everySignedFieldIsBound() public {
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(signer, keyA, c1, 100_000 ether);
        bytes memory sig = _sign(signerKey, a);
        bytes memory bad = abi.encodeWithSelector(ICuratorAuthorization.InvalidSignature.selector);
        for (uint256 i; i < 17; ++i) {
            ICuratorAuthorization.AllocationAuthorization memory m = _copy(a);
            PoolKey memory k = keyA;
            bytes memory err = bad;
            if (i == 0) m.curator = attacker;
            else if (i == 1) m.generation += 1;
            else if (i == 2) (m.vault, err) = (attacker, _err1(ICuratorAuthorization.WrongVault.selector, attacker));
            else if (i == 3) (m.poolId, err) = (keyB.toId(), _err0(ICuratorAuthorization.PoolKeyMismatch.selector));
            else if (i == 4) (m.hook, err) = (address(hookB), _err0(ICuratorAuthorization.HookMismatch.selector));
            else if (i == 5) (m.currencyIn, err) = (c1, _err0(ICuratorAuthorization.DirectionMismatch.selector));
            else if (i == 6) (m.currencyOut, err) = (c0, _err0(ICuratorAuthorization.DirectionMismatch.selector));
            else if (i == 7) (m.zeroForOne, err) = (false, _err0(ICuratorAuthorization.DirectionMismatch.selector));
            else if (i == 8) (m.currencyIn, m.currencyOut, m.zeroForOne) = (c1, c0, false); // consistent flip
            else if (i == 9) m.maxOut += 1;
            else if (i == 10) m.minInPerOutX96 += 1;
            else if (i == 11) m.expiry += 1;
            else if (i == 12) m.validAfter -= 1;
            else if (i == 13) m.deadline += 1;
            else if (i == 14) m.nonce += 1000;
            else if (i == 15) (k, m.poolId, m.hook) = (keyB, keyB.toId(), address(hookB)); // another pool, consistent
            else (k, err) = (keyB, _err0(ICuratorAuthorization.PoolKeyMismatch.selector)); // key swapped, id kept
            vm.prank(relayer);
            vm.expectRevert(err);
            auth.activate(m, k, sig);
        }
        assertFalse(auth.isNonceUsed(signer, a.nonce));
        _activate(a, keyA, sig);
    }

    // ------------------------------------------------------------------
    // Signature validation
    // ------------------------------------------------------------------

    function test_CA_wrongSigner() public {
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(signer, keyA, c1, 1000 ether);
        (, uint256 otherKey) = makeAddrAndKey("other");
        bytes memory otherSig = _sign(otherKey, a); // computed first: `_sign` itself calls the module
        _expectModuleError(ICuratorAuthorization.InvalidSignature.selector);
        _activate(a, keyA, otherSig);
        // A valid signature of the relayer over the same message does not make the relayer the curator either.
        a.curator = relayer;
        (, uint256 relayerKey) = makeAddrAndKey("relayer");
        bytes memory relayerSig = _sign(relayerKey, a);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.CuratorNotRegistered.selector, relayer));
        _activate(a, keyA, relayerSig);
    }

    /// @notice Malformed signatures fail closed with `InvalidSignature`: empty, short, long, the 64-byte (EIP-2098)
    ///         form of a valid signature (OpenZeppelin 5.0.2 `tryRecover(bytes32, bytes)` accepts 65 bytes only), the
    ///         high-s twin of a valid signature (rejected as malleable), v = 0 and 1 instead of 27 and 28, all zeros,
    ///         and a garbage signature for curator address(0).
    function test_CA_malformedSignatures() public {
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(signer, keyA, c1, 1000 ether);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, auth.hashAuthorization(a));
        bytes32 vs = bytes32(uint256(s) | (uint256(v - 27) << 255));
        bytes[] memory bad = new bytes[](8);
        bad[0] = "";
        bad[1] = abi.encodePacked(r, s);
        bad[2] = abi.encodePacked(r, s, v, uint8(0));
        bad[3] = abi.encodePacked(r, vs);
        bad[4] = abi.encodePacked(r, bytes32(SECP256K1_N - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        bad[5] = abi.encodePacked(r, s, v - 27);
        bad[6] = new bytes(65);
        bad[7] = abi.encodePacked(keccak256("x"), keccak256("y"), uint8(27));
        for (uint256 i; i < bad.length; ++i) {
            _expectModuleError(ICuratorAuthorization.InvalidSignature.selector);
            _activate(a, keyA, bad[i]);
        }
        ICuratorAuthorization.AllocationAuthorization memory z = _copy(a);
        z.curator = address(0);
        _expectModuleError(ICuratorAuthorization.InvalidSignature.selector);
        _activate(z, keyA, bad[7]);
        assertFalse(auth.isNonceUsed(signer, a.nonce));
        _activate(a, keyA, abi.encodePacked(r, s, v)); // the well-formed signature still works
    }

    // ------------------------------------------------------------------
    // Replay
    // ------------------------------------------------------------------

    /// @notice A signature made on one chain fails on another (the domain separator is rebuilt from the live chain
    ///         id) and works again on the original chain.
    function test_CA_crossChainReplay() public {
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(signer, keyA, c1, 1000 ether);
        bytes memory sig = _sign(signerKey, a);
        // Read through a call: via-IR may re-evaluate a stored `block.chainid` after vm.chainId.
        (,,, uint256 home,,,) = auth.eip712Domain();
        bytes32 homeSeparator = auth.domainSeparator();
        vm.chainId(1301);
        assertEq(auth.domainSeparator(), _domainSeparator(address(auth)));
        assertTrue(auth.domainSeparator() != homeSeparator);
        _expectModuleError(ICuratorAuthorization.InvalidSignature.selector);
        _activate(a, keyA, sig);
        vm.chainId(home);
        _activate(a, keyA, sig);
    }

    /// @notice A second vault with its own module: an instruction for vault 1 cannot be used at vault 2's module,
    ///         whether the relayer leaves the vault field alone (WrongVault) or rewrites it (InvalidSignature), and a
    ///         correctly signed instruction for vault 2 still has to pass vault 2's own registration.
    function test_CA_crossVaultReplay() public {
        SharedCommitmentVault v2 = new SharedCommitmentVault(manager, owner, c0, c1);
        CuratorAuthorization m2 = _installAuth(v2);

        ICuratorAuthorization.AllocationAuthorization memory a = _authz(signer, keyA, c1, 1000 ether);
        bytes memory sig = _sign(signerKey, a);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ICuratorAuthorization.WrongVault.selector, address(vault)));
        m2.activate(a, keyA, sig);

        ICuratorAuthorization.AllocationAuthorization memory b = _copy(a);
        b.vault = address(v2);
        vm.prank(relayer);
        vm.expectRevert(ICuratorAuthorization.InvalidSignature.selector);
        m2.activate(b, keyA, sig); // vault field rewritten
        bytes memory sigB1 = _signWith(auth, signerKey, b); // for v2, but under module 1's domain
        bytes memory sigB2 = _signWith(m2, signerKey, b); // for v2 under module 2's domain
        vm.prank(relayer);
        vm.expectRevert(ICuratorAuthorization.InvalidSignature.selector);
        m2.activate(b, keyA, sigB1);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ICuratorAuthorization.WrongVault.selector, address(v2)));
        auth.activate(b, keyA, sigB2); // signed for module 2, sent to module 1

        // Correct for vault 2: the signature passes, and vault 2 applies its own registration.
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.CuratorNotRegistered.selector, signer));
        m2.activate(b, keyA, sigB2);
        assertFalse(m2.isNonceUsed(signer, b.nonce));
        _activate(a, keyA, sig); // still valid where it belongs
    }

    function test_CA_duplicateNonce_sameAndDifferentMessage() public {
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(signer, keyA, c1, 1000 ether);
        bytes memory sig = _sign(signerKey, a);
        _activate(a, keyA, sig);
        vm.expectRevert(abi.encodeWithSelector(ICuratorAuthorization.NonceAlreadyUsed.selector, signer, a.nonce));
        _activate(a, keyA, sig);
        ICuratorAuthorization.AllocationAuthorization memory b = _authz(signer, keyB, c0, 7 ether);
        b.nonce = a.nonce;
        bytes memory sigB = _sign(signerKey, b);
        vm.expectRevert(abi.encodeWithSelector(ICuratorAuthorization.NonceAlreadyUsed.selector, signer, a.nonce));
        _activate(b, keyB, sigB);
    }

    /// @notice One bitmap per curator for both paths: an instruction the curator signed and then submitted itself
    ///         activates once, whichever path is first.
    function test_CA_signedAndDirectShareNonces() public {
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(signer, keyA, c1, 1000 ether);
        bytes memory sig = _sign(signerKey, a);
        vm.prank(signer);
        auth.activateDirect(_toRequest(a, keyA));
        vm.expectRevert(abi.encodeWithSelector(ICuratorAuthorization.NonceAlreadyUsed.selector, signer, a.nonce));
        _activate(a, keyA, sig);

        ICuratorAuthorization.AllocationAuthorization memory b = _authz(signer, keyA, c1, 1000 ether);
        _activate(b, keyA, _sign(signerKey, b));
        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(ICuratorAuthorization.NonceAlreadyUsed.selector, signer, b.nonce));
        auth.activateDirect(_toRequest(b, keyA));
    }

    function test_CA_curatorsHaveIndependentNonces() public {
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(signer, keyA, c1, 1000 ether);
        a.nonce = 42;
        _signAndActivate(a, keyA);
        ICuratorAuthorization.AllocationAuthorization memory w = _authz(address(wallet), keyA, c1, 1000 ether);
        w.nonce = 42;
        wallet.approve(auth.hashAuthorization(w), true);
        _activate(w, keyA, "");
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, 1000 ether);
        req.nonce = 42;
        vm.prank(curator);
        auth.activateDirect(req);
    }

    /// @notice Nonce n is bit n % 256 of word n / 256. Invalidation only sets bits, only in the caller's own bitmap,
    ///         and blocks activation; it works even after the module is retired.
    function test_CA_invalidateNoncesAndBitmapLayout() public {
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(signer, keyA, c1, 1000 ether);
        a.nonce = 515; // word 2, bit 3
        bytes memory sig = _sign(signerKey, a);
        vm.expectEmit(address(auth));
        emit ICuratorAuthorization.NoncesInvalidated(signer, 2, 1 << 3);
        vm.prank(signer);
        auth.invalidateNonces(2, 1 << 3);
        assertEq(auth.nonceBitmap(signer, 2), 8);
        assertTrue(auth.isNonceUsed(signer, 515));
        assertFalse(auth.isNonceUsed(signer, 514));
        assertFalse(auth.isNonceUsed(address(wallet), 515), "other curators unaffected");
        vm.expectRevert(abi.encodeWithSelector(ICuratorAuthorization.NonceAlreadyUsed.selector, signer, 515));
        _activate(a, keyA, sig);

        vm.prank(signer);
        auth.invalidateNonces(2, 1 << 3); // idempotent
        assertEq(auth.nonceBitmap(signer, 2), 8);

        // A whole word, and the highest nonce.
        vm.startPrank(signer);
        auth.invalidateNonces(0, type(uint256).max);
        auth.invalidateNonces(type(uint256).max >> 8, 1 << 255);
        vm.stopPrank();
        for (uint256 n; n < 256; n += 51) {
            assertTrue(auth.isNonceUsed(signer, n));
        }
        assertFalse(auth.isNonceUsed(signer, 256));
        assertTrue(auth.isNonceUsed(signer, type(uint256).max));

        // After retirement the curator can still invalidate in the old module.
        vm.prank(guardian);
        vault.setAuthModule(address(0));
        vm.prank(signer);
        auth.invalidateNonces(3, 1);
        assertTrue(auth.isNonceUsed(signer, 768));
    }

    /// @notice An activation the vault rejects reverts entirely, so the nonce stays unused and the same signature
    ///         activates once the reason is gone.
    function test_CA_failedActivationDoesNotConsumeNonce() public {
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(signer, keyA, c1, uint128(VAULT_FUNDING) + 1);
        bytes memory sig = _sign(signerKey, a);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.CuratorCeilingExceeded.selector, VAULT_FUNDING + 1, VAULT_FUNDING
            )
        );
        _activate(a, keyA, sig);
        assertFalse(auth.isNonceUsed(signer, a.nonce));

        ICuratorAuthorization.AllocationAuthorization memory b = _authz(signer, keyA, c1, 1000 ether);
        bytes memory sigB = _sign(signerKey, b);
        vm.prank(guardian);
        vault.setPaused(true);
        vm.expectRevert(ISharedCommitmentVault.Paused.selector);
        _activate(b, keyA, sigB);
        assertFalse(auth.isNonceUsed(signer, b.nonce));
        vm.prank(owner);
        vault.setPaused(false);
        _activate(b, keyA, sigB);
        assertTrue(auth.isNonceUsed(signer, b.nonce));
    }

    // ------------------------------------------------------------------
    // Time
    // ------------------------------------------------------------------

    /// @notice validAfter <= now <= deadline, both inclusive. The allocation's own expiry is checked by the vault
    ///         against the activation time, so a long-lived signature still produces at most a MAX_HORIZON lifetime.
    function test_CA_validityWindowAndExpiry() public {
        uint256 t = block.timestamp;
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(signer, keyA, c1, 1000 ether);
        (a.validAfter, a.deadline, a.expiry) = (uint64(t + 100), uint64(t + 200), uint64(t + 1 days));
        bytes memory sig = _sign(signerKey, a);
        vm.warp(t + 99);
        vm.expectRevert(abi.encodeWithSelector(ICuratorAuthorization.AuthorizationNotYetValid.selector, t + 100));
        _activate(a, keyA, sig);
        uint256 snap = vm.snapshotState();
        vm.warp(t + 100);
        _activate(a, keyA, sig);
        vm.revertToState(snap);
        vm.warp(t + 200);
        _activate(a, keyA, sig);
        vm.revertToState(snap);
        vm.warp(t + 201);
        vm.expectRevert(abi.encodeWithSelector(ICuratorAuthorization.AuthorizationExpired.selector, t + 200));
        _activate(a, keyA, sig);

        // Expiry beyond the horizon at activation time fails in the vault; the same signature works later.
        uint256 now_ = vm.getBlockTimestamp(); // via-IR may reuse a block.timestamp read from before vm.warp
        ICuratorAuthorization.AllocationAuthorization memory b = _authz(signer, keyA, c1, 1000 ether);
        (b.deadline, b.expiry) = (uint64(now_ + 3 days), uint64(now_ + 31 days));
        bytes memory sigB = _sign(signerKey, b);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.HorizonExceeded.selector, b.expiry, now_ + vault.MAX_HORIZON()
            )
        );
        _activate(b, keyA, sigB);
        vm.warp(now_ + 2 days);
        _activate(b, keyA, sigB);
    }

    // ------------------------------------------------------------------
    // Generations, registration and restrictions
    // ------------------------------------------------------------------

    function test_CA_generationBumpInvalidatesOutstanding() public {
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(signer, keyA, c1, 1000 ether);
        bytes memory sig = _sign(signerKey, a);
        vm.prank(signer);
        vault.bumpGeneration();
        vm.expectRevert(_stale(signer, a.generation, a.generation + 1));
        _activate(a, keyA, sig);
        a.generation += 1;
        _activate(a, keyA, _sign(signerKey, a));
        // A generation from the future is just as invalid.
        ICuratorAuthorization.AllocationAuthorization memory f = _authz(signer, keyA, c1, 1000 ether);
        f.generation += 1;
        bytes memory sigF = _sign(signerKey, f);
        vm.expectRevert(_stale(signer, f.generation, f.generation - 1));
        _activate(f, keyA, sigF);
    }

    /// @notice Deregistration raises the generation; registering again does not lower it, so a signature made before
    ///         the deregistration never comes back.
    function test_CA_deregisterReregisterCannotRevive() public {
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(signer, keyA, c1, 1000 ether);
        bytes memory sig = _sign(signerKey, a);
        vm.prank(guardian);
        vault.setCurator(signer, false);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.CuratorNotRegistered.selector, signer));
        _activate(a, keyA, sig);
        vm.prank(owner);
        vault.setCurator(signer, true);
        vm.expectRevert(_stale(signer, a.generation, a.generation + 1));
        _activate(a, keyA, sig);
    }

    function test_CA_freezeUnfreezeAndRevoke() public {
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(signer, keyA, c1, 1000 ether);
        bytes memory sig = _sign(signerKey, a);
        vm.prank(guardian);
        vault.freezeCurator(signer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.CuratorRestricted.selector,
                signer,
                ISharedCommitmentVault.CuratorRestriction.Frozen
            )
        );
        _activate(a, keyA, sig);
        vm.prank(owner);
        vault.unfreezeCurator(signer);
        vm.expectRevert(_stale(signer, a.generation, a.generation + 1));
        _activate(a, keyA, sig);

        ICuratorAuthorization.AllocationAuthorization memory b = _authz(signer, keyA, c1, 1000 ether);
        bytes memory sigB = _sign(signerKey, b);
        vm.prank(guardian);
        vault.revokeCurator(signer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.CuratorRestricted.selector,
                signer,
                ISharedCommitmentVault.CuratorRestriction.Revoked
            )
        );
        _activate(b, keyA, sigB);
        assertFalse(auth.isNonceUsed(signer, b.nonce));
    }

    /// @notice At generation type(uint32).max the counter can no longer rise: bump and deregistration revert for
    ///         good. Signatures at that generation still work, the curator can still invalidate nonces, and freeze and
    ///         revoke (which never touch the generation) still stop it.
    function test_CA_generationExhausted() public {
        _setGeneration(signer, type(uint32).max);
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(signer, keyA, c1, 1000 ether);
        assertEq(a.generation, type(uint32).max);
        _signAndActivate(a, keyA);
        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.GenerationExhausted.selector, signer));
        vault.bumpGeneration();
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.GenerationExhausted.selector, signer));
        vault.setCurator(signer, false);

        ICuratorAuthorization.AllocationAuthorization memory b = _authz(signer, keyA, c1, 1000 ether);
        bytes memory sigB = _sign(signerKey, b);
        vm.prank(signer);
        auth.invalidateNonces(b.nonce >> 8, 1 << (b.nonce & 0xff));
        vm.expectRevert(abi.encodeWithSelector(ICuratorAuthorization.NonceAlreadyUsed.selector, signer, b.nonce));
        _activate(b, keyA, sigB);

        ICuratorAuthorization.AllocationAuthorization memory c = _authz(signer, keyA, c1, 1000 ether);
        bytes memory sigC = _sign(signerKey, c);
        vm.prank(guardian);
        vault.revokeCurator(signer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.CuratorRestricted.selector,
                signer,
                ISharedCommitmentVault.CuratorRestriction.Revoked
            )
        );
        _activate(c, keyA, sigC);
    }

    // ------------------------------------------------------------------
    // ERC-1271 wallets
    // ------------------------------------------------------------------

    function test_CA_1271_validWallet() public {
        ICuratorAuthorization.AllocationAuthorization memory w = _authz(address(wallet), keyB, c0, 5000 ether);
        wallet.approve(auth.hashAuthorization(w), true);
        uint256 id = _activate(w, keyB, hex"c0ffee"); // the wallet decides; the bytes are its business
        assertEq(vault.getAllocation(id).curator, address(wallet));
        _swap(keyB, false, 1000 ether, id);
        assertGt(vault.getAllocation(id).consumed, 0);
    }

    /// @notice Every way a wallet can fail to say yes is a rejection, and none of them spends the nonce.
    function test_CA_1271_failuresFailClosed() public {
        ICuratorAuthorization.AllocationAuthorization memory w = _authz(address(wallet), keyB, c0, 5000 ether);
        // Not approved, then each failure mode with the digest approved.
        _expectModuleError(ICuratorAuthorization.InvalidSignature.selector);
        _activate(w, keyB, "");
        wallet.approve(auth.hashAuthorization(w), true);
        Mock1271Wallet.Mode[3] memory modes =
            [Mock1271Wallet.Mode.WrongValue, Mock1271Wallet.Mode.Revert, Mock1271Wallet.Mode.ShortReturn];
        for (uint256 i; i < modes.length; ++i) {
            wallet.setMode(modes[i]);
            _expectModuleError(ICuratorAuthorization.InvalidSignature.selector);
            _activate(w, keyB, "");
        }
        // An ECDSA signature by someone else does not help a wallet curator.
        wallet.setMode(Mock1271Wallet.Mode.WrongValue);
        bytes memory eoaSig = _sign(signerKey, w);
        _expectModuleError(ICuratorAuthorization.InvalidSignature.selector);
        _activate(w, keyB, eoaSig);
        assertFalse(auth.isNonceUsed(address(wallet), w.nonce));
        wallet.setMode(Mock1271Wallet.Mode.Approve);
        _activate(w, keyB, "");
    }

    /// @notice A wallet that burns all gas or returns a huge payload only makes the submitter's transaction fail or
    ///         cost more. With a bounded gas budget the activation reverts and the nonce stays unused.
    function test_CA_1271_gasBurnerAndReturnBomb() public {
        ICuratorAuthorization.AllocationAuthorization memory w = _authz(address(wallet), keyB, c0, 5000 ether);
        wallet.approve(auth.hashAuthorization(w), true);
        wallet.setMode(Mock1271Wallet.Mode.BurnGas);
        vm.prank(relayer);
        (bool ok,) = address(auth).call{gas: 2_000_000}(abi.encodeCall(auth.activate, (w, keyB, "")));
        assertFalse(ok, "gas burner");
        wallet.setMode(Mock1271Wallet.Mode.ReturnBomb);
        vm.prank(relayer);
        (ok,) = address(auth).call{gas: 500_000}(abi.encodeCall(auth.activate, (w, keyB, "")));
        assertFalse(ok, "return bomb within a small budget");
        assertFalse(auth.isNonceUsed(address(wallet), w.nonce));
        // Paid for in full, the bomb's leading word is the magic value: the wallet's answer is what counts.
        _activate(w, keyB, "");
    }

    /// @notice A wallet that withdraws its approval stops future activations; the allocation already created is
    ///         unchanged, consumable and cancellable.
    function test_CA_1271_revokedApprovalLeavesExistingAllocation() public {
        ICuratorAuthorization.AllocationAuthorization memory w1 = _authz(address(wallet), keyB, c0, 5000 ether);
        ICuratorAuthorization.AllocationAuthorization memory w2 = _authz(address(wallet), keyB, c0, 5000 ether);
        wallet.approve(auth.hashAuthorization(w1), true);
        wallet.approve(auth.hashAuthorization(w2), true);
        uint256 id = _activate(w1, keyB, "");
        ISharedCommitmentVault.Allocation memory before = vault.getAllocation(id);
        wallet.approve(auth.hashAuthorization(w1), false);
        wallet.approve(auth.hashAuthorization(w2), false);
        wallet.setMode(Mock1271Wallet.Mode.Revert);
        _expectModuleError(ICuratorAuthorization.InvalidSignature.selector);
        _activate(w2, keyB, "");
        assertEq(keccak256(abi.encode(vault.getAllocation(id))), keccak256(abi.encode(before)));
        _swap(keyB, false, 1000 ether, id);
        uint256 q = vault.reserved(c0);
        uint128 rest = vault.getAllocation(id).maxOut - vault.getAllocation(id).consumed;
        wallet.exec(address(vault), abi.encodeCall(vault.cancelAllocation, (id)));
        assertEq(q - vault.reserved(c0), rest);
    }

    /// @notice Reentry from `isValidSignature` runs under `staticcall`: the wallet's attempts to cancel its own live
    ///         allocation, to invalidate the very nonce being activated, or to activate again through the module all
    ///         fail inside the wallet, and nothing changes. A write attempted under `staticcall` is an exceptional halt
    ///         that consumes all the gas forwarded to it (63/64 of the wallet's gas, which is itself 63/64 of the
    ///         module's), so each attempt below gets its own gas budget. A wallet that propagates the failure rejects its
    ///         own instruction. A wallet that swallows it and approves leaves the module about 1/64 of the submitted gas:
    ///         with an ordinary budget the activation runs out of gas and reverts, and only a submitter willing to pay
    ///         roughly 64 times the normal cost gets the activation through, once.
    function test_CA_1271_reentrancyIsStatic() public {
        ICuratorAuthorization.AllocationAuthorization memory w0 = _authz(address(wallet), keyB, c0, 5000 ether);
        wallet.approve(auth.hashAuthorization(w0), true);
        uint256 live = _activate(w0, keyB, "");

        ICuratorAuthorization.AllocationAuthorization memory w = _authz(address(wallet), keyB, c0, 5000 ether);
        wallet.approve(auth.hashAuthorization(w), true);
        bytes[3] memory attempts = [
            abi.encodeCall(vault.cancelAllocation, (live)),
            abi.encodeCall(auth.invalidateNonces, (w.nonce >> 8, 1 << (w.nonce & 0xff))),
            abi.encodeCall(auth.activateDirect, (_request(keyB, c0, 1 ether)))
        ];
        address[3] memory targets = [address(vault), address(auth), address(auth)];
        bytes memory call_ = abi.encodeCall(auth.activate, (w, keyB, ""));
        wallet.setMode(Mock1271Wallet.Mode.ReenterStrict);
        for (uint256 i; i < 3; ++i) {
            wallet.setReentry(targets[i], attempts[i]);
            vm.prank(relayer);
            (bool ok, bytes memory ret) = address(auth).call{gas: 5_000_000}(call_);
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(ICuratorAuthorization.InvalidSignature.selector));
        }
        wallet.setMode(Mock1271Wallet.Mode.ReenterSwallow);
        wallet.setReentry(targets[0], attempts[0]);
        vm.prank(relayer);
        (bool ok1,) = address(auth).call{gas: 1_000_000}(call_);
        assertFalse(ok1, "out of gas after the burned reentry");
        assertFalse(auth.isNonceUsed(address(wallet), w.nonce));

        uint256 nextId = vault.nextAllocationId();
        vm.prank(relayer);
        (bool ok2, bytes memory ret2) = address(auth).call{gas: 60_000_000}(call_);
        assertTrue(ok2, "paid for in full");
        assertEq(abi.decode(ret2, (uint256)), nextId, "exactly one new allocation");
        assertEq(vault.nextAllocationId(), nextId + 1);
        assertFalse(vault.getAllocation(live).released, "reentrant cancel had no effect");
        assertTrue(auth.isNonceUsed(address(wallet), w.nonce));
    }

    // ------------------------------------------------------------------
    // Direct path and equivalence
    // ------------------------------------------------------------------

    /// @notice The direct path takes the curator from msg.sender only: nobody can allocate for someone else.
    function test_CA_directPath_curatorIsCaller() public {
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, 1000 ether);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.CuratorNotRegistered.selector, attacker));
        auth.activateDirect(req);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.CuratorNotRegistered.selector, relayer));
        auth.activateDirect(req);
        vm.prank(signer);
        uint256 id = auth.activateDirect(req);
        assertEq(vault.getAllocation(id).curator, signer);
        assertTrue(auth.isNonceUsed(signer, req.nonce));
        assertFalse(auth.isNonceUsed(attacker, req.nonce), "failed attempts consumed nothing");
    }

    /// @notice The same request submitted through the signed path (by a relayer) and through the direct path (by the
    ///         curator) has the same outcome: the same revert data, or the same allocation record and the same changes
    ///         to Q_a, curatorReserved and hookReserved. Fuzzed over size, floor, lifetime, pool and direction, from
    ///         well inside every limit to beyond the ceiling and the admission limit.
    function testFuzz_CA_directAndSignedEquivalent(uint256 seed, uint128 maxOut, uint64 lifetime, uint160 floorBump)
        public
    {
        PoolKey memory key = seed & 1 == 0 ? keyA : keyB;
        Currency out = seed & 2 == 0 ? c1 : c0;
        maxOut = uint128(bound(maxOut, 0, VAULT_FUNDING * 2));
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(signer, key, out, maxOut);
        a.expiry = uint64(block.timestamp + bound(lifetime, 0, 32 days));
        a.minInPerOutX96 = PRICE_1_1_X96 - 2 + uint160(bound(floorBump, 0, 4)); // around the vault floor
        bytes memory sig = _sign(signerKey, a);

        uint256 snap = vm.snapshotState();
        vm.prank(relayer);
        (bool okS, bytes memory retS) = address(auth).call(abi.encodeCall(auth.activate, (a, key, sig)));
        bytes32 stateS = _reservationState(key, out, okS ? abi.decode(retS, (uint256)) : 0);
        vm.revertToState(snap);
        vm.prank(signer);
        (bool okD, bytes memory retD) = address(auth).call(abi.encodeCall(auth.activateDirect, (_toRequest(a, key))));
        bytes32 stateD = _reservationState(key, out, okD ? abi.decode(retD, (uint256)) : 0);

        assertEq(okS, okD, "same outcome");
        assertEq(keccak256(retS), keccak256(retD), "same id or same revert data");
        assertEq(stateS, stateD, "same reservation state");
    }

    /// @notice Nobody but the installed module can call `reserveFor`, whatever role it has elsewhere.
    function test_CA_reserveForOnlyFromModule() public {
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, 1000 ether);
        address[6] memory callers = [owner, guardian, signer, address(hookA), attacker, address(this)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NotAuthModule.selector, callers[i]));
            vault.reserveFor(req, signer, 0);
        }
    }

    // ------------------------------------------------------------------
    // Signed allocations under the vault's financial limits
    // ------------------------------------------------------------------

    /// @notice Two signed instructions compete for the same backing: whichever activates first takes it, the second
    ///         fails admission atomically (its nonce stays free), and an instruction that fits the remainder works.
    function test_CA_competingAuthorizationsForSameBacking() public {
        uint256 room = vault.admissibleCapacity(c1);
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(signer, keyA, c1, uint128(room - 10));
        ICuratorAuthorization.AllocationAuthorization memory w = _authz(address(wallet), keyB, c1, 20);
        bytes memory sigA = _sign(signerKey, a);
        wallet.approve(auth.hashAuthorization(w), true);
        vm.prank(owner);
        vault.setCuratorCeiling(signer, c1, room);
        _activate(a, keyA, sigA);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientBacking.selector, 20, 10));
        _activate(w, keyB, "");
        assertFalse(auth.isNonceUsed(address(wallet), w.nonce));
        ICuratorAuthorization.AllocationAuthorization memory w2 = _authz(address(wallet), keyB, c1, 10);
        wallet.approve(auth.hashAuthorization(w2), true);
        _activate(w2, keyB, "");
        assertEq(vault.admissibleCapacity(c1), 0);
        _assertEquations();
    }

    /// @notice A signature does not bypass the exposure caps (checked at activation) or the flow caps (checked at
    ///         every exchange).
    function test_CA_exposureAndFlowCapsApplyToSignedAllocations() public {
        vm.startPrank(owner);
        vault.setRiskLimit(ISharedCommitmentVault.RiskScope.Curator, signer, c1, 500 ether, 1000); // 10% exposure
        vm.stopPrank();
        uint256 e = lens.eligibleBacking(vault, c1);
        uint128 limit = uint128(e * 1000 / 10_000);
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(signer, keyA, c1, limit + 1);
        bytes memory sig = _sign(signerKey, a);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.ExposureCapExceeded.selector,
                ISharedCommitmentVault.RiskScope.Curator,
                signer,
                c1,
                limit + 1,
                limit
            )
        );
        _activate(a, keyA, sig);
        ICuratorAuthorization.AllocationAuthorization memory b = _authz(signer, keyA, c1, limit);
        uint256 id = _signAndActivate(b, keyA);
        _swap(keyA, true, 400 ether, id);
        _expectSwapRevert(
            address(hookA),
            abi.encodeWithSelector(
                ISharedCommitmentVault.FlowLimitExceeded.selector,
                ISharedCommitmentVault.RiskScope.Curator,
                signer,
                c1,
                _quoteOut(id, 400 ether),
                500 ether - vault.getRiskLimit(ISharedCommitmentVault.RiskScope.Curator, signer, c1).flowUsed
            )
        );
        _swap(keyA, true, 400 ether, id);
    }

    /// @notice A signed allocation follows the ordinary lifecycle: partial and full consumption, cancellation by its
    ///         curator, and emergency release by the guardian, each with exact accounting.
    function test_CA_signedAllocationLifecycle() public {
        uint256 id1 = _signAndActivate(_authz(signer, keyA, c1, 3000 ether), keyA);
        _swap(keyA, true, 1000 ether, id1);
        uint128 used = vault.getAllocation(id1).consumed;
        assertGt(used, 0);
        uint256 id2 = _signAndActivate(_authz(signer, keyA, c1, 3000 ether), keyA);
        uint256 id3 = _signAndActivate(_authz(signer, keyB, c0, 3000 ether), keyB);
        uint256 q1 = vault.reserved(c1);
        vm.prank(signer);
        vault.cancelAllocation(id1);
        assertEq(q1 - vault.reserved(c1), 3000 ether - used);
        vm.prank(guardian);
        vault.release(id2);
        assertTrue(vault.getAllocation(id2).released);
        _swap(keyB, false, 2000 ether, id3);
        _assertAccountingConsistent();
        _assertEquations();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _domainSeparator(address module) internal view returns (bytes32) {
        return
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("Porkfolio Vault"), keccak256("1"), block.chainid, module));
    }

    /// @dev Deep copy: assigning a memory struct only copies the reference.
    function _copy(ICuratorAuthorization.AllocationAuthorization memory a)
        internal
        pure
        returns (ICuratorAuthorization.AllocationAuthorization memory)
    {
        return abi.decode(abi.encode(a), (ICuratorAuthorization.AllocationAuthorization));
    }

    function _err0(bytes4 sel) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(sel);
    }

    function _err1(bytes4 sel, address a) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(sel, a);
    }

    function _stale(address c, uint32 authorized, uint32 current) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ISharedCommitmentVault.StaleGeneration.selector, c, authorized, current);
    }

    /// @dev Hash of the allocation record (if any) and the reservation counters a new allocation changes.
    function _reservationState(PoolKey memory key, Currency out, uint256 id) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                id == 0 ? bytes32(0) : keccak256(abi.encode(vault.getAllocation(id))),
                vault.reserved(out),
                vault.curatorReserved(signer, out),
                vault.hookReserved(address(key.hooks), out),
                vault.nextAllocationId()
            )
        );
    }

    /// @dev HookA's output for `amountIn` against allocation `id`, measured on a snapshot.
    function _quoteOut(uint256 id, uint256 amountIn) internal returns (uint256 out) {
        uint256 snap = vm.snapshotState();
        uint128 before = vault.getAllocation(id).consumed;
        vm.prank(owner);
        vault.setRiskLimit(ISharedCommitmentVault.RiskScope.Curator, signer, c1, type(uint104).max, 1000);
        _swap(keyA, true, amountIn, id);
        out = vault.getAllocation(id).consumed - before;
        vm.revertToState(snap);
    }

    /// @dev The packing used by `CuratorLifecycle.t.sol`: registered (byte 0), restriction (byte 1), generation
    ///      (bytes 2-5) of `_curators[c]` at slot 4.
    function _setGeneration(address c, uint32 generation) internal {
        bytes32 slot = keccak256(abi.encode(c, uint256(4)));
        ISharedCommitmentVault.CuratorRecord memory r = vault.getCurator(c);
        uint256 expected = (r.registered ? 1 : 0) | (uint256(uint8(r.restriction)) << 8) | (uint256(r.generation) << 16);
        assertEq(uint256(vm.load(address(vault), slot)), expected, "curator slot layout changed");
        vm.store(
            address(vault), slot, bytes32((expected & ~(uint256(type(uint32).max) << 16)) | (uint256(generation) << 16))
        );
        assertEq(vault.getCurator(c).generation, generation);
    }

    /// @dev The typed-data JSON for forge's encoder. Integers are passed as decimal strings so values above 2^53
    ///      survive JSON parsing.
    function _json(ICuratorAuthorization.AllocationAuthorization memory a, address module)
        internal
        view
        returns (string memory)
    {
        string memory types = string.concat(
            '{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},',
            '{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],',
            '"AllocationAuthorization":[{"name":"curator","type":"address"},{"name":"generation","type":"uint32"},',
            '{"name":"vault","type":"address"},{"name":"poolId","type":"bytes32"},{"name":"hook","type":"address"},',
            '{"name":"currencyIn","type":"address"},{"name":"currencyOut","type":"address"},',
            '{"name":"zeroForOne","type":"bool"},{"name":"maxOut","type":"uint128"},',
            '{"name":"minInPerOutX96","type":"uint160"},{"name":"expiry","type":"uint64"},',
            '{"name":"validAfter","type":"uint64"},{"name":"deadline","type":"uint64"},{"name":"nonce","type":"uint256"}]}'
        );
        string memory domain = string.concat(
            '{"name":"Porkfolio Vault","version":"1","chainId":"',
            vm.toString(block.chainid),
            '","verifyingContract":"',
            vm.toString(module),
            '"}'
        );
        string memory m1 = string.concat(
            '{"curator":"',
            vm.toString(a.curator),
            '","generation":"',
            vm.toString(uint256(a.generation)),
            '","vault":"',
            vm.toString(a.vault),
            '","poolId":"',
            vm.toString(PoolId.unwrap(a.poolId)),
            '","hook":"',
            vm.toString(a.hook),
            '","currencyIn":"',
            vm.toString(Currency.unwrap(a.currencyIn))
        );
        string memory m2 = string.concat(
            '","currencyOut":"',
            vm.toString(Currency.unwrap(a.currencyOut)),
            '","zeroForOne":',
            a.zeroForOne ? "true" : "false",
            ',"maxOut":"',
            vm.toString(uint256(a.maxOut)),
            '","minInPerOutX96":"',
            vm.toString(uint256(a.minInPerOutX96)),
            '","expiry":"',
            vm.toString(uint256(a.expiry))
        );
        string memory m3 = string.concat(
            '","validAfter":"',
            vm.toString(uint256(a.validAfter)),
            '","deadline":"',
            vm.toString(uint256(a.deadline)),
            '","nonce":"',
            vm.toString(a.nonce),
            '"}'
        );
        return string.concat(
            '{"types":',
            types,
            ',"primaryType":"AllocationAuthorization","domain":',
            domain,
            ',"message":',
            m1,
            m2,
            m3,
            "}"
        );
    }
}
