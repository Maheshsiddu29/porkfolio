// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {CuratorAuthorization} from "../../src/CuratorAuthorization.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {ICuratorAuthorization} from "../../src/interfaces/ICuratorAuthorization.sol";
import {AuthTestBase} from "../utils/AuthTestBase.sol";
import {ProductionArtifacts} from "../utils/ProductionArtifacts.sol";
import {ModuleCandidate} from "../utils/ModuleCandidate.sol";
import {MaliciousAuthModule} from "../utils/MaliciousAuthModule.sol";

/// @notice The vault's installation check on `setAuthModule`, repeated and idempotent changes, and replay of
///         instructions signed for a module that has since been retired. Runs on the production builds
///         (`VaultTestBase`).
/// @dev The installation check accepts a candidate only if a `staticcall` to `vault()` succeeds and its first 32
///      returned bytes are exactly this vault's address. These tests show both sides of that: every malformed or
///      wrong answer is refused without changing anything, and a contract that gives the right answer is accepted
///      whether or not it is a real module. The second half is why the check does not replace review.
contract ModuleInstallationTest is AuthTestBase {
    ModuleCandidate internal cand;

    function setUp() public override {
        super.setUp();
        cand = new ModuleCandidate();
    }

    // ------------------------------------------------------------------
    // Installation check
    // ------------------------------------------------------------------

    /// @notice Every candidate that does not answer `vault()` with this vault is refused with `InvalidAuthModule`,
    ///         and the refusal changes nothing: the installed module stays installed, is not retired, and keeps
    ///         working. Covers no code, a contract without the getter, the vault itself, the PoolManager, a module
    ///         for another vault, and a getter that reverts, returns nothing, returns 31 bytes, returns zero, or
    ///         returns this address with dirty upper bits.
    function test_MI_refusesCandidatesThatDoNotReportThisVault() public {
        SharedCommitmentVault v2 = new SharedCommitmentVault(manager, owner, c0, c1);
        address[6] memory fixed_ = [
            makeAddr("no code"),
            address(wallet), // a contract with functions but no `vault()` and no fallback
            address(vault),
            address(manager),
            address(_deployAuth(v2)), // the production module, built for another vault
            address(lens)
        ];
        for (uint256 i; i < fixed_.length; ++i) {
            _expectInstallRefused(fixed_[i]);
        }

        bytes32 self = bytes32(uint256(uint160(address(vault))));
        ModuleCandidate.Mode[4] memory modes = [
            ModuleCandidate.Mode.Revert,
            ModuleCandidate.Mode.Empty,
            ModuleCandidate.Mode.Short,
            ModuleCandidate.Mode.Answer
        ];
        bytes32[4] memory words = [self, self, self, bytes32(0)];
        for (uint256 i; i < modes.length; ++i) {
            cand.set(modes[i], words[i]);
            _expectInstallRefused(address(cand));
        }
        cand.set(ModuleCandidate.Mode.Answer, self | bytes32(uint256(1) << 160)); // dirty upper bits
        _expectInstallRefused(address(cand));

        assertEq(vault.authModule(), address(auth), "nothing was installed or retired");
        _signAndActivate(_authz(signer, keyA, c1, 1000 ether), keyA);
    }

    /// @notice Exactly one 32-byte value is accepted: this vault's address, left-padded with zeros. Any other word is
    ///         refused. This is the whole decision rule of the check.
    function testFuzz_MI_onlyThisVaultsAddressIsAccepted(bytes32 w) public {
        bytes32 self = bytes32(uint256(uint160(address(vault))));
        vm.assume(w != self);
        cand.set(ModuleCandidate.Mode.Answer, w);
        _expectInstallRefused(address(cand));
        cand.set(ModuleCandidate.Mode.Answer, self);
        vm.prank(owner);
        vault.setAuthModule(address(cand));
        assertEq(vault.authModule(), address(cand));
    }

    /// @notice Two answers that only the call-success and length checks reject.
    ///         (1) A candidate that reverts with exactly this vault's address as revert data. A failed call still
    ///         copies its revert data into the output buffer, so without the success check it would read as the
    ///         right answer.
    ///         (2) A 31-byte answer, for a vault deployed at an address ending in 0xcf. The vault writes the selector
    ///         0xfbfa77cf into the word it later reads, so the 32nd byte of that word is left over as 0xcf; without
    ///         the length check, 31 correct bytes plus that leftover byte would read as the right answer.
    function test_MI_failedOrShortAnswerCannotPassAsTheVault() public {
        cand.set(ModuleCandidate.Mode.RevertWord, bytes32(uint256(uint160(address(vault)))));
        _expectInstallRefused(address(cand));

        address at = address(uint160(0xC0FFEE) << 136 | 0xcf);
        deployCodeTo(ProductionArtifacts.VAULT, abi.encode(manager, owner, c0, c1), at);
        cand.set(ModuleCandidate.Mode.Short, bytes32(uint256(uint160(at))));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InvalidAuthModule.selector, address(cand)));
        SharedCommitmentVault(at).setAuthModule(address(cand));
        cand.set(ModuleCandidate.Mode.Answer, bytes32(uint256(uint160(at))));
        vm.prank(owner);
        SharedCommitmentVault(at).setAuthModule(address(cand)); // the full answer is accepted: the setup is sound
    }

    /// @notice A candidate whose getter burns all gas makes the owner's transaction fail and pay for it; nothing
    ///         changes. The vault forwards all but 1/64 of its gas to the candidate, and the remaining 1/64 is enough
    ///         to revert with the precise error.
    function test_MI_gasBurningCandidateOnlyCostsTheOwner() public {
        cand.set(ModuleCandidate.Mode.BurnGas, bytes32(0));
        vm.prank(owner);
        (bool ok, bytes memory ret) =
            address(vault).call{gas: 3_000_000}(abi.encodeCall(vault.setAuthModule, (address(cand))));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(ISharedCommitmentVault.InvalidAuthModule.selector, address(cand)));
        assertEq(vault.authModule(), address(auth));
    }

    /// @notice The limit of the check. Any contract that answers `vault()` with this address is accepted: a getter
    ///         followed by extra data, a contract that is not a module at all, a malicious module, and even a
    ///         consumer hook, whose own `vault()` getter names this vault. Installed by mistake, the hook creates
    ///         nothing (it has no code that calls `reserveFor`), new allocations stop until the owner installs a
    ///         real module, and the hook's consumer role is unaffected when it is retired as a module. A malicious
    ///         module is bounded by `reserveFor` (`AuthModuleLifecycle.t.sol`). Review of what is installed stays the
    ///         owner's job.
    function test_MI_rightAnswerIsNotProofOfAModule() public {
        uint256 id = _allocate(keyA, c1, 50_000 ether);
        bytes32 self = bytes32(uint256(uint160(address(vault))));

        cand.set(ModuleCandidate.Mode.Long, self);
        vm.prank(owner);
        vault.setAuthModule(address(cand)); // first word is right; the rest is ignored
        MaliciousAuthModule mal = new MaliciousAuthModule(ISharedCommitmentVault(address(vault)));
        vm.prank(owner);
        vault.setAuthModule(address(mal));
        assertEq(vault.authModule(), address(mal));

        vm.prank(owner);
        vault.setAuthModule(address(hookA));
        assertEq(vault.authModule(), address(hookA), "a hook passes the check");
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(signer, keyA, c1, 1000 ether);
        bytes memory sig = _sign(signerKey, a);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NotAuthModule.selector, address(auth)));
        _activate(a, keyA, sig);
        _swap(keyA, true, 1000 ether, id); // its consumer role and existing allocations are untouched

        CuratorAuthorization m2 = _installAuth(vault); // retires the hook as a module
        assertTrue(vault.isConsumer(address(hookA)), "still a registered consumer");
        _swap(keyA, true, 1000 ether, id);
        vm.prank(relayer);
        uint256 id2 = m2.activate(a, keyA, _signWith(m2, signerKey, a));
        _swap(keyA, true, 500 ether, id2);
    }

    /// @notice A retired module is refused even though it still answers `vault()` correctly: the retired list is
    ///         checked independently of the installation check.
    function test_MI_retiredModulePassesCheckButIsRefused() public {
        CuratorAuthorization m2 = _installAuth(vault);
        assertEq(address(auth.vault()), address(vault), "the retired module still reports this vault");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.AuthModuleRetired.selector, address(auth)));
        vault.setAuthModule(address(auth));
        assertEq(vault.authModule(), address(m2));
    }

    // ------------------------------------------------------------------
    // Repeated and idempotent changes
    // ------------------------------------------------------------------

    /// @notice Installing the module that is already installed is refused with `AuthModuleRetired` and emits
    ///         nothing; the module stays installed and keeps working. Disabling is idempotent: the guardian and the
    ///         owner can always set zero, also when no module is installed, so an emergency disable never fails
    ///         because someone else got there first. Module changes work while the vault is paused.
    function test_MI_repeatedInstallAndIdempotentDisable() public {
        vm.recordLogs();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.AuthModuleRetired.selector, address(auth)));
        vault.setAuthModule(address(auth));
        assertEq(vm.getRecordedLogs().length, 0, "no event");
        assertEq(vault.authModule(), address(auth));
        _signAndActivate(_authz(signer, keyA, c1, 1000 ether), keyA);

        vm.prank(guardian);
        vault.setAuthModule(address(0));
        vm.expectEmit(address(vault));
        emit ISharedCommitmentVault.AuthModuleSet(address(0), address(0), guardian);
        vm.prank(guardian);
        vault.setAuthModule(address(0));
        vm.prank(owner);
        vault.setAuthModule(address(0));
        assertEq(vault.authModule(), address(0));

        vm.prank(guardian);
        vault.setPaused(true);
        CuratorAuthorization m2 = _deployAuth(vault);
        vm.prank(owner);
        vault.setAuthModule(address(m2));
        assertEq(vault.authModule(), address(m2), "installation works while paused");
    }

    // ------------------------------------------------------------------
    // Replay against retired modules
    // ------------------------------------------------------------------

    /// @notice Instructions signed for a module that has been retired can never create anything, whichever module
    ///         they are sent to:
    ///         - to the retired module: an already-used nonce is refused by its own bitmap; an unused one passes the
    ///           module's checks but the vault refuses the call (`NotAuthModule`), and the revert also undoes the
    ///           nonce bit, so the retired module's state is unchanged;
    ///         - to the new module: the signature is over another domain (`InvalidSignature`);
    ///         - the retired module's direct path is refused the same way.
    ///         Nonce spaces are per module: the same nonce, signed again for the new module, activates there. A curator
    ///         can still invalidate nonces in a retired module; that changes nothing in the vault. A chain of
    ///         retirements (replace, then guardian disable, then a third module) keeps every earlier module dead.
    function test_MI_retiredModuleReplay() public {
        ICuratorAuthorization.AllocationAuthorization memory used = _authz(signer, keyA, c1, 1000 ether);
        bytes memory usedSig = _sign(signerKey, used);
        uint256 id = _activate(used, keyA, usedSig);
        ICuratorAuthorization.AllocationAuthorization memory unused = _authz(signer, keyA, c1, 1000 ether);
        bytes memory unusedSig = _sign(signerKey, unused);
        ICuratorAuthorization.AllocationAuthorization memory w = _authz(address(wallet), keyB, c0, 1000 ether);
        wallet.approve(auth.hashAuthorization(w), true);

        CuratorAuthorization m2 = _installAuth(vault);

        vm.expectRevert(abi.encodeWithSelector(ICuratorAuthorization.NonceAlreadyUsed.selector, signer, used.nonce));
        _activate(used, keyA, usedSig);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NotAuthModule.selector, address(auth)));
        _activate(unused, keyA, unusedSig);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NotAuthModule.selector, address(auth)));
        _activate(w, keyB, "");
        ISharedCommitmentVault.AllocationRequest memory r = _toRequest(unused, keyA);
        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NotAuthModule.selector, address(auth)));
        auth.activateDirect(r);
        assertFalse(auth.isNonceUsed(signer, unused.nonce), "the vault's refusal undid the bit");
        assertFalse(auth.isNonceUsed(address(wallet), w.nonce));

        vm.startPrank(relayer);
        vm.expectRevert(ICuratorAuthorization.InvalidSignature.selector);
        m2.activate(used, keyA, usedSig);
        vm.expectRevert(ICuratorAuthorization.InvalidSignature.selector);
        m2.activate(unused, keyA, unusedSig);
        vm.expectRevert(ICuratorAuthorization.InvalidSignature.selector);
        m2.activate(w, keyB, ""); // the wallet approved the old module's digest, not the new one
        uint256 id2 = m2.activate(used, keyA, _signWith(m2, signerKey, used)); // same nonce, new domain
        vm.stopPrank();
        assertEq(vault.getAllocation(id2).curator, signer);

        vm.prank(signer);
        auth.invalidateNonces(unused.nonce >> 8, 1 << (unused.nonce & 0xff));
        assertTrue(auth.isNonceUsed(signer, unused.nonce));
        assertFalse(m2.isNonceUsed(signer, unused.nonce), "bitmaps are per module");

        vm.prank(guardian);
        vault.setAuthModule(address(0));
        CuratorAuthorization m3 = _installAuth(vault);
        ICuratorAuthorization.AllocationAuthorization memory forM2 = _authz(signer, keyA, c1, 1000 ether);
        bytes memory forM2Sig = _signWith(m2, signerKey, forM2);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NotAuthModule.selector, address(m2)));
        vm.prank(relayer);
        m2.activate(forM2, keyA, forM2Sig);
        vm.startPrank(relayer);
        vm.expectRevert(ICuratorAuthorization.InvalidSignature.selector);
        m3.activate(forM2, keyA, forM2Sig);
        vm.expectRevert(ICuratorAuthorization.InvalidSignature.selector);
        m3.activate(unused, keyA, unusedSig);
        vm.stopPrank();
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.AuthModuleRetired.selector, address(auth)));
        vault.setAuthModule(address(auth));
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.AuthModuleRetired.selector, address(m2)));
        vault.setAuthModule(address(m2));
        vm.stopPrank();

        _swap(keyA, true, 1000 ether, id); // allocations made through retired modules are unaffected
        _assertEquations();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _expectInstallRefused(address m) internal {
        address before = vault.authModule();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InvalidAuthModule.selector, m));
        vault.setAuthModule(m);
        assertEq(vault.authModule(), before);
    }
}
