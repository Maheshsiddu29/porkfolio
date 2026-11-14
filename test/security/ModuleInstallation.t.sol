// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {CuratorAuthorization} from "../../src/CuratorAuthorization.sol";
import {ISharedCommitmentVault, AUTH_MODULE_ID} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {ICuratorAuthorization} from "../../src/interfaces/ICuratorAuthorization.sol";
import {AuthTestBase} from "../utils/AuthTestBase.sol";
import {ProductionArtifacts} from "../utils/ProductionArtifacts.sol";
import {ModuleCandidate} from "../utils/ModuleCandidate.sol";
import {MaliciousAuthModule} from "../utils/MaliciousAuthModule.sol";
import {VaultStateReader} from "../../src/libraries/VaultStateReader.sol";

using VaultStateReader for SharedCommitmentVault;

/// @notice The vault's installation check on `setAuthModule`, repeated and idempotent changes, and replay of
///         instructions signed for a module that has since been retired. Runs on the production builds
///         (`VaultTestBase`).
/// @dev The installation check accepts a candidate only if a `staticcall` to `authModuleId()` returns AUTH_MODULE_ID
///      and then a `staticcall` to `vault()` returns this vault's address, each as the first 32 bytes of a successful
///      answer of at least 32 bytes. These tests show both sides of that: every contract that is not a module for
///      this vault, and every malformed or wrong answer, is refused without changing anything; and a contract that
///      gives both right answers is accepted whether or not it is the reviewed module. The second half is why the
///      check does not replace verifying the deployed code.
contract ModuleInstallationTest is AuthTestBase {
    ModuleCandidate internal cand;

    function setUp() public override {
        super.setUp();
        cand = new ModuleCandidate();
    }

    // ------------------------------------------------------------------
    // Installation check
    // ------------------------------------------------------------------

    /// @notice Every candidate that is not a module for this vault is refused with `InvalidAuthModule`, and the
    ///         refusal changes nothing: the installed module stays installed, is not retired, and keeps working.
    ///         Covers no code, an empty contract, contracts without the identity getter (a wallet, the vault itself,
    ///         the PoolManager, the lens, and both consumer hooks, whose `vault()` getter does name this vault), a
    ///         real module for another vault, and candidates whose `authModuleId()` or `vault()` reverts, returns
    ///         nothing, returns 31 bytes, echoes the call data, or returns a wrong word.
    function test_MI_refusesCandidatesThatAreNotModulesForThisVault() public {
        SharedCommitmentVault v2 = new SharedCommitmentVault(manager, owner, c0, c1);
        address empty = makeAddr("empty contract");
        vm.etch(empty, hex"00"); // STOP: every call succeeds and returns no data
        assertEq(address(hookA.vault()), address(vault), "the hooks name this vault");
        assertEq(address(hookB.vault()), address(vault));
        address[9] memory fixed_ = [
            makeAddr("no code"),
            empty,
            address(wallet), // a contract with functions but neither getter and no fallback
            address(vault),
            address(manager),
            address(_deployAuth(v2)), // the production module, built for another vault
            address(lens),
            address(hookA),
            address(hookB)
        ];
        for (uint256 i; i < fixed_.length; ++i) {
            _expectInstallRefused(fixed_[i]);
        }

        bytes32 self = bytes32(uint256(uint160(address(vault))));
        ModuleCandidate.Mode[5] memory modes = [
            ModuleCandidate.Mode.Revert,
            ModuleCandidate.Mode.Empty,
            ModuleCandidate.Mode.Short,
            ModuleCandidate.Mode.Echo,
            ModuleCandidate.Mode.Answer
        ];
        // vault() malformed or wrong, identity right
        bytes32[5] memory vaultWords = [self, self, self, self, bytes32(0)];
        for (uint256 i; i < modes.length; ++i) {
            cand.set(modes[i], vaultWords[i]);
            _expectInstallRefused(address(cand));
        }
        cand.set(ModuleCandidate.Mode.Answer, self | bytes32(uint256(1) << 160)); // dirty upper bits
        _expectInstallRefused(address(cand));

        // identity malformed or wrong, vault() right
        cand.set(ModuleCandidate.Mode.Answer, self);
        bytes32[5] memory idWords = [AUTH_MODULE_ID, AUTH_MODULE_ID, AUTH_MODULE_ID, AUTH_MODULE_ID, self];
        for (uint256 i; i < modes.length; ++i) {
            cand.setId(modes[i], idWords[i]);
            _expectInstallRefused(address(cand));
        }

        assertEq(vault.authModule(), address(auth), "nothing was installed or retired");
        _signAndActivate(_authz(signer, keyA, c1, 1000 ether), keyA);
    }

    /// @notice With the identity right, exactly one `vault()` word is accepted: this vault's address, left-padded with
    ///         zeros.
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

    /// @notice With `vault()` right, exactly one identity word is accepted: AUTH_MODULE_ID.
    function testFuzz_MI_onlyTheModuleIdentityIsAccepted(bytes32 w) public {
        vm.assume(w != AUTH_MODULE_ID);
        cand.set(ModuleCandidate.Mode.Answer, bytes32(uint256(uint160(address(vault)))));
        cand.setId(ModuleCandidate.Mode.Answer, w);
        _expectInstallRefused(address(cand));
        cand.setId(ModuleCandidate.Mode.Answer, AUTH_MODULE_ID);
        vm.prank(owner);
        vault.setAuthModule(address(cand));
        assertEq(vault.authModule(), address(cand));
    }

    /// @notice A fallback that gives one fixed word to every call cannot pass, whichever word it is: the two
    ///         questions need two different answers. Only a contract that tells the two selectors apart and answers
    ///         each correctly passes (see `test_MI_bothRightAnswersAreNotProofOfAModule`).
    function test_MI_oneAnswerForEverySelectorIsRefused() public {
        cand.setSameAnswerForAll(true);
        cand.set(ModuleCandidate.Mode.Answer, bytes32(uint256(uint160(address(vault)))));
        _expectInstallRefused(address(cand));
        cand.set(ModuleCandidate.Mode.Answer, AUTH_MODULE_ID);
        _expectInstallRefused(address(cand));
        cand.set(ModuleCandidate.Mode.Echo, bytes32(0));
        _expectInstallRefused(address(cand));
    }

    /// @notice Answers that only the call-success and length checks reject.
    ///         (1) A candidate that reverts with exactly the expected word as revert data, for either question. A
    ///         failed call still copies its revert data into the output buffer, so without the success check it
    ///         would read as the right answer.
    ///         (2) A 31-byte `vault()` answer, for a vault deployed at an address ending in 0xcf. The vault writes the
    ///         selector 0xfbfa77cf into the word it later reads, so the 32nd byte of that word is left over as 0xcf;
    ///         without the length check, 31 correct bytes plus that leftover byte would read as the right answer.
    ///         The same cannot be staged for the identity, whose last byte (0x0a) differs from the last byte of
    ///         its selector (0xa1); its length check is still required for the same reason.
    function test_MI_failedOrShortAnswerCannotPass() public {
        bytes32 self = bytes32(uint256(uint160(address(vault))));
        cand.set(ModuleCandidate.Mode.RevertWord, self);
        _expectInstallRefused(address(cand));
        cand.set(ModuleCandidate.Mode.Answer, self);
        cand.setId(ModuleCandidate.Mode.RevertWord, AUTH_MODULE_ID);
        _expectInstallRefused(address(cand));
        cand.setId(ModuleCandidate.Mode.Answer, AUTH_MODULE_ID);

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

    /// @notice A candidate whose getter burns all gas, on either question, makes the owner's transaction fail and pay
    ///         for it; nothing changes. The vault forwards all but 1/64 of its gas to the candidate, and the remaining
    ///         1/64 is enough to revert with the precise error.
    function test_MI_gasBurningCandidateOnlyCostsTheOwner() public {
        bytes32 self = bytes32(uint256(uint160(address(vault))));
        cand.set(ModuleCandidate.Mode.BurnGas, bytes32(0));
        _expectInstallRefusedWithGas(address(cand), 3_000_000);
        cand.set(ModuleCandidate.Mode.Answer, self);
        cand.setId(ModuleCandidate.Mode.BurnGas, bytes32(0));
        _expectInstallRefusedWithGas(address(cand), 3_000_000);
    }

    /// @notice The identity is asked first, and `vault()` only if the identity was right. A hook therefore receives
    ///         one call and is refused there; a real module receives exactly the two calls.
    function test_MI_identityAskedFirst() public {
        vm.expectCall(address(hookA), bytes(""), 1);
        vm.expectCall(address(hookA), abi.encodeWithSignature("authModuleId()"), 1);
        _expectInstallRefused(address(hookA));

        CuratorAuthorization m2 = _deployAuth(vault);
        assertEq(m2.authModuleId(), AUTH_MODULE_ID); // before the counted expectations below
        vm.expectCall(address(m2), bytes(""), 2);
        vm.expectCall(address(m2), abi.encodeWithSignature("authModuleId()"), 1);
        vm.expectCall(address(m2), abi.encodeWithSignature("vault()"), 1);
        vm.prank(owner);
        vault.setAuthModule(address(m2));
    }

    /// @notice The limit of the check. Any contract that gives both right answers is accepted: one whose answers
    ///         carry extra data, a fallback that tells the two selectors apart, and a malicious module. The check
    ///         cannot tell any of them from the reviewed module. What a malicious module can do once installed is
    ///         bounded by `reserveFor` (`AuthModuleLifecycle.t.sol`); the guardian can always disable it, and it is
    ///         then retired for good. Verifying the deployed code stays the owner's job.
    function test_MI_bothRightAnswersAreNotProofOfAModule() public {
        uint256 id = _allocate(keyA, c1, 50_000 ether);
        bytes32 self = bytes32(uint256(uint160(address(vault))));

        cand.set(ModuleCandidate.Mode.Long, self);
        cand.setId(ModuleCandidate.Mode.Long, AUTH_MODULE_ID);
        vm.prank(owner);
        vault.setAuthModule(address(cand)); // first words are right; the rest is ignored
        assertEq(vault.authModule(), address(cand), "a contract that is not a module passes");

        MaliciousAuthModule mal = new MaliciousAuthModule(ISharedCommitmentVault(address(vault)));
        vm.prank(owner);
        vault.setAuthModule(address(mal));
        assertEq(vault.authModule(), address(mal), "a malicious module passes");
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyA, c1, 1000 ether);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.CuratorNotRegistered.selector, address(this)));
        mal.forge(r, address(this), 0); // still bounded by the vault's own checks

        vm.prank(guardian);
        vault.setAuthModule(address(0));
        assertEq(vault.authModule(), address(0));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.AuthModuleRetired.selector, address(mal)));
        vault.setAuthModule(address(mal));
        _swap(keyA, true, 1000 ether, id); // existing allocations are untouched throughout
    }

    /// @notice A retired module is refused even though it still gives both right answers: the retired list is
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

    /// @dev Same as `_expectInstallRefused`, with a gas limit so a gas-burning candidate ends in reasonable time.
    function _expectInstallRefusedWithGas(address m, uint256 gasLimit) internal {
        address before = vault.authModule();
        vm.prank(owner);
        (bool ok, bytes memory ret) = address(vault).call{gas: gasLimit}(abi.encodeCall(vault.setAuthModule, (m)));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(ISharedCommitmentVault.InvalidAuthModule.selector, m));
        assertEq(vault.authModule(), before);
    }
}
