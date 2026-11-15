// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {CommitmentAuthorizer} from "../../src/CommitmentAuthorizer.sol";
import {BondEscrow} from "../../src/BondEscrow.sol";
import {ICommitmentAuthorizer} from "../../src/interfaces/ICommitmentAuthorizer.sol";
import {ICuratorAuthorization} from "../../src/interfaces/ICuratorAuthorization.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {IBondEscrow} from "../../src/interfaces/IBondEscrow.sol";
import {IVaultState} from "../../src/interfaces/IVaultState.sol";
import {VaultStateReader} from "../../src/libraries/VaultStateReader.sol";
import {BondTestBase} from "../utils/BondTestBase.sol";
import {Mock1271Wallet} from "../utils/Mock1271Wallet.sol";

using VaultStateReader for SharedCommitmentVault;

/// @notice The bonded authorization path on the production builds: what the curator signs (allocation, payer, maximum
///         rate), who may submit it (the payer only), every inherited check (EOA and ERC-1271 signatures, nonce,
///         generation), and that a failure at any step leaves no allocation, no bond, no nonce bit and no token moved.
contract BondedActivationTest is BondTestBase {
    /// @dev Everything an activation could change, read before an attempt that must fail.
    struct Snapshot {
        uint256 nextId;
        uint256 reserved1;
        uint256 payerBalance;
        uint256 escrowClaims;
        uint256 openBonds;
        bool nonceUsed;
    }

    function _snap(address cur, uint256 nonce, address who) internal view returns (Snapshot memory s) {
        s.nextId = vault.nextAllocationId();
        s.reserved1 = lens.reserved(vault, c1);
        s.payerBalance = token1.balanceOf(who);
        s.escrowClaims = _claims(address(escrow), c1);
        s.openBonds = escrow.getLedger(c1).openBonds;
        s.nonceUsed = bonded.isNonceUsed(cur, nonce);
    }

    function _assertUnchanged(Snapshot memory s, address cur, uint256 nonce, address who) internal view {
        Snapshot memory t = _snap(cur, nonce, who);
        assertEq(t.nextId, s.nextId, "allocation created");
        assertEq(t.reserved1, s.reserved1, "capacity reserved");
        assertEq(t.payerBalance, s.payerBalance, "payer charged");
        assertEq(t.escrowClaims, s.escrowClaims, "escrow funded");
        assertEq(t.openBonds, s.openBonds, "bond recorded");
        assertEq(t.nonceUsed, s.nonceUsed, "nonce spent");
    }

    /// @notice An EOA curator's signed bonded instruction, submitted by the payer it names: one allocation, one bond
    ///         pulled from that payer, the curator's nonce spent, the rate fixed at the escrow's current rate.
    function test_signedEOA_payerActivates() public {
        ICommitmentAuthorizer.BondedAuthorization memory b = _bondedAuthz(signer, keyA, c1, 10_000 ether, payer, RHO);
        bytes memory sig = _signBonded(signerKey, b);
        uint256 bal = token1.balanceOf(payer);
        vm.prank(payer);
        uint256 id = bonded.activateBonded(b, keyA, sig);
        IBondEscrow.Bond memory bond = escrow.getBond(id);
        assertEq(bond.payer, payer);
        assertEq(bond.rate, RHO);
        assertEq(bal - token1.balanceOf(payer), bond.bond);
        assertGt(bond.bond, 0);
        assertEq(lens.getAllocation(vault, id).curator, signer);
        assertTrue(bonded.isNonceUsed(signer, b.allocation.nonce));
        _assertEscrowIdentity();
    }

    /// @notice Only the named payer can submit: a relayer holding a valid signature is refused, and a submitter that
    ///         rewrites the payer or the maximum rate breaks the signature. A signature over the unbonded
    ///         `AllocationAuthorization` digest does not verify as a bonded one.
    function test_payerBinding_andSignedTerms() public {
        ICommitmentAuthorizer.BondedAuthorization memory b = _bondedAuthz(signer, keyA, c1, 10_000 ether, payer, RHO);
        bytes memory sig = _signBonded(signerKey, b);
        Snapshot memory s = _snap(signer, b.allocation.nonce, payer);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ICommitmentAuthorizer.NotPayer.selector, relayer));
        bonded.activateBonded(b, keyA, sig);

        // Fresh structs: assigning a memory struct would alias `b`.
        ICommitmentAuthorizer.BondedAuthorization memory stolen =
            ICommitmentAuthorizer.BondedAuthorization(b.allocation, relayer, b.maxRate);
        vm.prank(relayer);
        vm.expectRevert(ICuratorAuthorization.InvalidSignature.selector);
        bonded.activateBonded(stolen, keyA, sig);

        ICommitmentAuthorizer.BondedAuthorization memory raised =
            ICommitmentAuthorizer.BondedAuthorization(b.allocation, payer, RHO * 1000);
        vm.prank(payer);
        vm.expectRevert(ICuratorAuthorization.InvalidSignature.selector);
        bonded.activateBonded(raised, keyA, sig);

        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(signerKey, bonded.hashAuthorization(b.allocation));
        vm.prank(payer);
        vm.expectRevert(ICuratorAuthorization.InvalidSignature.selector);
        bonded.activateBonded(b, keyA, abi.encodePacked(r, ss, v));

        _assertUnchanged(s, signer, b.allocation.nonce, payer);
        vm.prank(payer);
        bonded.activateBonded(b, keyA, sig);
    }

    /// @notice The unbonded entry points are disabled in the bonded module, so it never creates a free reservation.
    function test_unbondedEntryPointsDisabled() public {
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(signer, keyA, c1, 10_000 ether);
        bytes memory sig = _signWith(bonded, signerKey, a);
        vm.prank(relayer);
        vm.expectRevert(ICommitmentAuthorizer.BondRequired.selector);
        bonded.activate(a, keyA, sig);
        vm.prank(curator);
        vm.expectRevert(ICommitmentAuthorizer.BondRequired.selector);
        bonded.activateDirect(_request(keyA, c1, 1 ether));
    }

    /// @notice A rate above the signed maximum: refused, and nothing changes. The escrow's rate rising between
    ///         signing and activation is exactly what `maxRate` protects against.
    function test_rateRaisedAfterSigning_refused() public {
        ICommitmentAuthorizer.BondedAuthorization memory b = _bondedAuthz(signer, keyA, c1, 10_000 ether, payer, RHO);
        bytes memory sig = _signBonded(signerKey, b);
        vm.prank(owner);
        escrow.setRate(c1, RHO + 1);
        Snapshot memory s = _snap(signer, b.allocation.nonce, payer);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IBondEscrow.RateAboveMax.selector, RHO + 1, RHO));
        bonded.activateBonded(b, keyA, sig);
        _assertUnchanged(s, signer, b.allocation.nonce, payer);
    }

    /// @notice ERC-1271 curator: the wallet approves the bonded digest and the payer activates. Each way a wallet can
    ///         fail to say yes is a rejection that spends nothing.
    function test_1271Wallet_bondedActivation_andFailures() public {
        ICommitmentAuthorizer.BondedAuthorization memory b =
            _bondedAuthz(address(wallet), keyB, c1, 5000 ether, payer, RHO);
        Snapshot memory s = _snap(address(wallet), b.allocation.nonce, payer);
        vm.prank(payer);
        vm.expectRevert(ICuratorAuthorization.InvalidSignature.selector);
        bonded.activateBonded(b, keyB, "");
        wallet.approve(bonded.hashBondedAuthorization(b), true);
        Mock1271Wallet.Mode[3] memory modes =
            [Mock1271Wallet.Mode.WrongValue, Mock1271Wallet.Mode.Revert, Mock1271Wallet.Mode.ShortReturn];
        for (uint256 i; i < modes.length; ++i) {
            wallet.setMode(modes[i]);
            vm.prank(payer);
            vm.expectRevert(ICuratorAuthorization.InvalidSignature.selector);
            bonded.activateBonded(b, keyB, "");
        }
        wallet.setMode(Mock1271Wallet.Mode.BurnGas);
        vm.prank(payer);
        (bool ok,) = address(bonded).call{gas: 2_000_000}(abi.encodeCall(bonded.activateBonded, (b, keyB, "")));
        assertFalse(ok, "gas burner");
        _assertUnchanged(s, address(wallet), b.allocation.nonce, payer);

        // A wallet that tries to post a bond (or anything else) from inside its check runs under staticcall: the
        // attempt fails, the wallet still answers yes, and only the one legitimate bond exists afterwards.
        wallet.setReentry(address(escrow), abi.encodeCall(escrow.post, (1, address(wallet), RHO)));
        wallet.setMode(Mock1271Wallet.Mode.ReenterSwallow);
        vm.prank(payer);
        uint256 id = bonded.activateBonded(b, keyB, "");
        assertEq(escrow.getBond(id).payer, payer);
        assertEq(escrow.getLedger(c1).openBonds, escrow.getBond(id).bond);
    }

    /// @notice Replay and generation: the same instruction cannot activate twice (nonce), and a generation bump kills
    ///         every outstanding bonded instruction of the curator; a refused attempt leaves the nonce unspent.
    function test_replayAndGeneration() public {
        ICommitmentAuthorizer.BondedAuthorization memory b = _bondedAuthz(signer, keyA, c1, 1000 ether, payer, RHO);
        bytes memory sig = _signBonded(signerKey, b);
        vm.prank(payer);
        bonded.activateBonded(b, keyA, sig);
        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(ICuratorAuthorization.NonceAlreadyUsed.selector, signer, b.allocation.nonce)
        );
        bonded.activateBonded(b, keyA, sig);

        ICommitmentAuthorizer.BondedAuthorization memory b2 = _bondedAuthz(signer, keyA, c1, 1000 ether, payer, RHO);
        bytes memory sig2 = _signBonded(signerKey, b2);
        vm.prank(signer);
        vault.bumpGeneration();
        Snapshot memory s = _snap(signer, b2.allocation.nonce, payer);
        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.StaleGeneration.selector,
                signer,
                b2.allocation.generation,
                b2.allocation.generation + 1
            )
        );
        bonded.activateBonded(b2, keyA, sig2);
        _assertUnchanged(s, signer, b2.allocation.nonce, payer);
    }

    /// @notice Atomic rollback on every failure after the signature check: a vault refusal (admission, pause), a
    ///         short allowance, a payer without funds, and an escrow that is not the vault's. Each leaves no
    ///         allocation, no bond, no nonce bit and no token moved; the same instruction then activates once the
    ///         cause is removed.
    function test_atomicRollback_everyFailure() public {
        ICommitmentAuthorizer.BondedAuthorization memory b = _bondedAuthz(signer, keyA, c1, 10_000 ether, payer, RHO);
        bytes memory sig = _signBonded(signerKey, b);
        Snapshot memory s = _snap(signer, b.allocation.nonce, payer);

        vm.prank(owner);
        vault.setPaused(true);
        vm.prank(payer);
        vm.expectRevert(ISharedCommitmentVault.Paused.selector);
        bonded.activateBonded(b, keyA, sig);
        vm.prank(owner);
        vault.setPaused(false);

        vm.prank(owner);
        vault.setBufferFloor(c1, type(uint256).max);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientBacking.selector, 10_000 ether, 0));
        bonded.activateBonded(b, keyA, sig);
        vm.prank(owner);
        vault.setBufferFloor(c1, 0);

        vm.prank(payer);
        token1.approve(address(escrow), 0);
        vm.prank(payer);
        vm.expectRevert();
        bonded.activateBonded(b, keyA, sig);
        vm.prank(payer);
        token1.approve(address(escrow), type(uint256).max);

        uint256 funds = token1.balanceOf(payer);
        vm.prank(payer);
        token1.transfer(attacker, funds);
        vm.prank(payer);
        vm.expectRevert();
        bonded.activateBonded(b, keyA, sig);
        vm.prank(attacker);
        token1.transfer(payer, funds);

        BondEscrow other = _deployEscrow(vault, RHO, RHO, T_MIN, 0, protocol);
        vm.prank(owner);
        vault.setFeeEscrow(address(other));
        vm.prank(payer);
        vm.expectRevert(IBondEscrow.EscrowNotInstalled.selector);
        bonded.activateBonded(b, keyA, sig);
        vm.prank(owner);
        vault.setFeeEscrow(address(escrow));

        _assertUnchanged(s, signer, b.allocation.nonce, payer);
        vm.prank(payer);
        bonded.activateBonded(b, keyA, sig);
    }

    /// @notice A module whose escrow serves another vault cannot be built.
    function test_constructor_escrowMustServeTheVault() public {
        SharedCommitmentVault other = new SharedCommitmentVault(manager, owner, c0, c1);
        BondEscrow foreign = _deployEscrow(other, 0, 0, 0, 0, address(0));
        vm.expectRevert(ICommitmentAuthorizer.EscrowVaultMismatch.selector);
        new CommitmentAuthorizer(IVaultState(address(vault)), IBondEscrow(address(foreign)));
        vm.expectRevert(ISharedCommitmentVault.ZeroAddress.selector);
        new CommitmentAuthorizer(IVaultState(address(vault)), IBondEscrow(address(0)));
        assertEq(address(bonded.escrow()), address(escrow));
        assertEq(bonded.authModuleId(), auth.authModuleId(), "installable as a module");
    }
}
