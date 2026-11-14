// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {CuratorAuthorization} from "../../src/CuratorAuthorization.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {ICuratorAuthorization} from "../../src/interfaces/ICuratorAuthorization.sol";
import {AuthTestBase} from "../utils/AuthTestBase.sol";
import {Mock1271Wallet} from "../utils/Mock1271Wallet.sol";
import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {VaultStateReader} from "../../src/libraries/VaultStateReader.sol";

using VaultStateReader for SharedCommitmentVault;

/// @notice Time rules of signed instructions, ERC-1271 failures and rollback of an activation the vault refuses.
///         Runs on the production builds (`VaultTestBase`).
/// @dev The time rules, checked by the module before it reads the clock or calls the curator's wallet:
///        validAfter <= deadline,  deadline - validAfter <= MAX_VALIDITY_WINDOW (1 day),  deadline < expiry;
///      then validAfter <= now <= deadline; then the vault requires expiry <= now + MAX_HORIZON (30 days).
///      `testFuzz_ST_timeRulesMatchReference` checks the module and vault together against that list.
contract ActivationSafetyTest is AuthTestBase {
    ISharedCommitmentVault.RiskScope internal constant HOOK = ISharedCommitmentVault.RiskScope.Hook;
    ISharedCommitmentVault.RiskScope internal constant CURATOR = ISharedCommitmentVault.RiskScope.Curator;
    ISharedCommitmentVault.RiskScope internal constant VAULT = ISharedCommitmentVault.RiskScope.Vault;
    bytes4 internal constant IS_VALID_SIGNATURE = 0x1626ba7e;
    uint64 internal constant WINDOW = 1 days;

    // ------------------------------------------------------------------
    // Signature timing
    // ------------------------------------------------------------------

    function test_ST_maxWindowIsOneDay() public view {
        assertEq(auth.MAX_VALIDITY_WINDOW(), WINDOW);
    }

    /// @notice Boundaries of the window bound and of the activation window, all inclusive where the rule says <=:
    ///         a window of exactly one day activates at both ends; one second longer is refused at any time; a
    ///         zero-length window activates in exactly its one second; an allocation may expire one second after the
    ///         deadline and is then live for exactly that second when activated at the deadline.
    function test_ST_windowBoundaries() public {
        uint64 t = uint64(block.timestamp);
        ICuratorAuthorization.AllocationAuthorization memory a = _timed(t, t + WINDOW, t + 2 days);
        bytes memory sig = _sign(signerKey, a);
        uint256 snap = vm.snapshotState();
        _activate(a, keyA, sig);
        vm.revertToState(snap);
        vm.warp(t + WINDOW);
        _activate(a, keyA, sig);
        vm.revertToState(snap);

        ICuratorAuthorization.AllocationAuthorization memory tooLong = _timed(t, t + WINDOW + 1, t + 2 days);
        bytes memory sigLong = _sign(signerKey, tooLong);
        vm.expectRevert(_tooLong(t, t + WINDOW + 1));
        _activate(tooLong, keyA, sigLong);
        vm.warp(t + 1 hours);
        vm.expectRevert(_tooLong(t, t + WINDOW + 1));
        _activate(tooLong, keyA, sigLong);
        vm.revertToState(snap);

        ICuratorAuthorization.AllocationAuthorization memory point = _timed(t + 10, t + 10, t + 11);
        bytes memory sigPoint = _sign(signerKey, point);
        vm.warp(t + 9);
        vm.expectRevert(abi.encodeWithSelector(ICuratorAuthorization.AuthorizationNotYetValid.selector, t + 10));
        _activate(point, keyA, sigPoint);
        vm.warp(t + 11);
        vm.expectRevert(abi.encodeWithSelector(ICuratorAuthorization.AuthorizationExpired.selector, t + 10));
        _activate(point, keyA, sigPoint);
        vm.warp(t + 10);
        uint256 id = _activate(point, keyA, sigPoint);
        assertEq(vault.getAllocation(id).expiry, t + 11, "live for exactly one second");
        _swap(keyA, true, 100 ether, id);
        vm.warp(t + 11);
        _expectSwapRevert(
            address(hookA), abi.encodeWithSelector(ISharedCommitmentVault.AllocationExpired.selector, id, t + 11)
        );
        _swapRaw(keyA, true, -int256(100 ether), abi.encode(id));
    }

    /// @notice Inconsistent time fields are refused with their own error at any time, before the clock is read:
    ///         validAfter after deadline, expiry equal to the deadline, and expiry before it. A deadline of
    ///         type(uint64).max can never activate, because no expiry can be after it. The direct path applies
    ///         deadline < expiry the same way.
    function test_ST_inconsistentTimesRefusedAtAnyTime() public {
        uint64 t = uint64(block.timestamp);
        ICuratorAuthorization.AllocationAuthorization[4] memory bad = [
            _timed(t + 100, t + 99, t + 1 days),
            _timed(t, t + 1 hours, t + 1 hours),
            _timed(t, t + 1 hours, t + 1),
            _timed(type(uint64).max - 1 hours, type(uint64).max, type(uint64).max)
        ];
        bytes[4] memory errs = [
            abi.encodeWithSelector(ICuratorAuthorization.InvalidValidityWindow.selector, t + 100, t + 99),
            _expiryErr(t + 1 hours, t + 1 hours),
            _expiryErr(t + 1, t + 1 hours),
            _expiryErr(type(uint64).max, type(uint64).max)
        ];
        uint64[3] memory times = [t, t + 99, t + 2 days];
        for (uint256 i; i < bad.length; ++i) {
            bytes memory sig = _sign(signerKey, bad[i]);
            for (uint256 j; j < times.length; ++j) {
                vm.warp(times[j]);
                vm.expectRevert(errs[i]);
                _activate(bad[i], keyA, sig);
            }
            vm.warp(t);
            assertFalse(auth.isNonceUsed(signer, bad[i].nonce));
        }

        ISharedCommitmentVault.AllocationRequest memory r = _request(keyA, c1, 1000 ether);
        r.expiry = r.deadline;
        vm.prank(curator);
        vm.expectRevert(_expiryErr(r.expiry, r.deadline));
        auth.activateDirect(r);
        assertFalse(auth.isNonceUsed(curator, r.nonce));
    }

    /// @notice A future-dated signature. The window bound limits how long an instruction is usable once valid, not
    ///         how long it can wait: an instruction signed today for a window a year away activates then, because
    ///         the module has no way to know when it was signed. Until then it is cancelled by invalidating its nonce,
    ///         by the curator's `bumpGeneration`, or by retiring the module; each is shown from the same state.
    function test_ST_futureDatedSignature() public {
        uint64 t = uint64(block.timestamp);
        uint64 opens = t + 365 days;
        ICuratorAuthorization.AllocationAuthorization memory a = _timed(opens, opens + 1 hours, opens + 2 days);
        bytes memory sig = _sign(signerKey, a);
        vm.expectRevert(abi.encodeWithSelector(ICuratorAuthorization.AuthorizationNotYetValid.selector, opens));
        _activate(a, keyA, sig);

        uint256 snap = vm.snapshotState();
        vm.warp(opens);
        uint256 id = _activate(a, keyA, sig);
        assertEq(vault.getAllocation(id).curator, signer, "a year-old signature activates when its window opens");
        vm.revertToState(snap);

        vm.prank(signer);
        auth.invalidateNonces(a.nonce >> 8, 1 << (a.nonce & 0xff));
        vm.warp(opens);
        vm.expectRevert(abi.encodeWithSelector(ICuratorAuthorization.NonceAlreadyUsed.selector, signer, a.nonce));
        _activate(a, keyA, sig);
        vm.revertToState(snap);

        vm.prank(signer);
        vault.bumpGeneration();
        vm.warp(opens);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.StaleGeneration.selector, signer, a.generation, a.generation + 1
            )
        );
        _activate(a, keyA, sig);
        vm.revertToState(snap);

        _installAuth(vault);
        vm.warp(opens);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NotAuthModule.selector, address(auth)));
        _activate(a, keyA, sig);
    }

    /// @notice An expired instruction is refused and spends nothing, so the curator may sign the same nonce again
    ///         with a new window.
    function test_ST_expiredSignature() public {
        uint64 t = uint64(block.timestamp);
        ICuratorAuthorization.AllocationAuthorization memory a = _timed(t, t + 1 hours, t + 1 days);
        bytes memory sig = _sign(signerKey, a);
        vm.warp(t + 1 hours + 1);
        vm.expectRevert(abi.encodeWithSelector(ICuratorAuthorization.AuthorizationExpired.selector, t + 1 hours));
        _activate(a, keyA, sig);
        assertEq(auth.nonceBitmap(signer, a.nonce >> 8), 0);
        (a.validAfter, a.deadline, a.expiry) = (t + 1 hours, t + 2 hours, t + 1 days);
        _activate(a, keyA, _sign(signerKey, a));
        assertTrue(auth.isNonceUsed(signer, a.nonce));
    }

    /// @notice The module and the vault together against a reference list of the time rules, in order. Times are
    ///         drawn around the activation time so that every rule is reached: validAfter within two days before to
    ///         one day after it, the window from one hour negative to two days, the lifetime from one hour negative to
    ///         31 days past the deadline. The activation time ranges up to 40 days below type(uint64).max.
    function testFuzz_ST_timeRulesMatchReference(uint64 at, uint256 vaOff, uint256 winOff, uint256 lifeOff) public {
        at = uint64(bound(at, block.timestamp, type(uint64).max - 40 days));
        uint64 va = uint64(at - 2 days + bound(vaOff, 0, 3 days));
        uint64 dl = uint64(va - 1 hours + bound(winOff, 0, 2 days + 1 hours));
        uint64 ex = uint64(dl - 1 hours + bound(lifeOff, 0, 31 days + 2 hours));
        vm.warp(at);
        ICuratorAuthorization.AllocationAuthorization memory a = _timed(va, dl, ex);
        bytes memory sig = _sign(signerKey, a);

        bytes memory expected;
        if (va > dl) {
            expected = abi.encodeWithSelector(ICuratorAuthorization.InvalidValidityWindow.selector, va, dl);
        } else if (dl - va > WINDOW) {
            expected = _tooLong(va, dl);
        } else if (ex <= dl) {
            expected = _expiryErr(ex, dl);
        } else if (at < va) {
            expected = abi.encodeWithSelector(ICuratorAuthorization.AuthorizationNotYetValid.selector, va);
        } else if (at > dl) {
            expected = abi.encodeWithSelector(ICuratorAuthorization.AuthorizationExpired.selector, dl);
        } else if (ex > uint256(at) + 30 days) {
            expected =
                abi.encodeWithSelector(ISharedCommitmentVault.HorizonExceeded.selector, ex, uint256(at) + 30 days);
        }

        vm.prank(relayer);
        (bool ok, bytes memory ret) = address(auth).call(abi.encodeCall(auth.activate, (a, keyA, sig)));
        if (expected.length == 0) {
            assertTrue(ok, "every rule holds: activates");
            ISharedCommitmentVault.Allocation memory al = vault.getAllocation(abi.decode(ret, (uint256)));
            assertEq(al.expiry, ex);
            assertGt(al.expiry, at, "the allocation is live when created");
        } else {
            assertFalse(ok);
            assertEq(ret, expected);
            assertFalse(auth.isNonceUsed(signer, a.nonce));
        }
    }

    /// @notice The time checks come before the signature check, so an inconsistent, early or late instruction never
    ///         reaches the curator's ERC-1271 wallet: a relayer pays nothing for wallet code on an instruction that
    ///         cannot activate. The single expectation below counts every `isValidSignature` call in the test: the
    ///         four refused instructions make none and the valid one makes exactly one.
    function test_ST_timeChecksRunBeforeWalletCode() public {
        uint64 t = uint64(block.timestamp);
        vm.expectCall(address(wallet), abi.encodeWithSelector(IS_VALID_SIGNATURE), 1);
        ICuratorAuthorization.AllocationAuthorization[4] memory bad = [
            _timedFor(address(wallet), t + 1, t, t + 1 days),
            _timedFor(address(wallet), t, t + WINDOW + 1, t + 2 days),
            _timedFor(address(wallet), t, t + 1 hours, t + 1 hours),
            _timedFor(address(wallet), t + 1, t + 1 hours, t + 1 days)
        ];
        for (uint256 i; i < bad.length; ++i) {
            wallet.approve(auth.hashAuthorization(bad[i]), true);
            vm.prank(relayer);
            (bool ok,) = address(auth).call(abi.encodeCall(auth.activate, (bad[i], keyB, "")));
            assertFalse(ok);
        }
        ICuratorAuthorization.AllocationAuthorization memory good =
            _timedFor(address(wallet), t, t + 1 hours, t + 1 days);
        wallet.approve(auth.hashAuthorization(good), true);
        _activate(good, keyB, "");
    }

    // ------------------------------------------------------------------
    // ERC-1271 failures
    // ------------------------------------------------------------------

    /// @notice Each way a contract wallet can fail to approve leaves no trace: `InvalidSignature`, no event, and the
    ///         nonce, reservation, risk, curator and custody state exactly as before. Includes a wallet that approved
    ///         a different instruction, and one that approved this instruction's digest under another module's domain
    ///         (an approval is bound to the module that computes the digest).
    function test_W_failuresLeaveNoTrace() public {
        ICuratorAuthorization.AllocationAuthorization memory w = _authz(address(wallet), keyB, c0, 5000 ether);
        ICuratorAuthorization.AllocationAuthorization memory other = _copy(w);
        other.nonce += 1;
        CuratorAuthorization m2 = _deployAuth(vault);
        bytes32 before = _state(w.nonce);

        wallet.approve(auth.hashAuthorization(other), true);
        wallet.approve(m2.hashAuthorization(w), true);
        _expectNoTrace(w, before); // Approve mode, but this digest is not approved
        wallet.approve(auth.hashAuthorization(w), true);
        Mock1271Wallet.Mode[3] memory modes =
            [Mock1271Wallet.Mode.WrongValue, Mock1271Wallet.Mode.Revert, Mock1271Wallet.Mode.ShortReturn];
        for (uint256 i; i < modes.length; ++i) {
            wallet.setMode(modes[i]);
            _expectNoTrace(w, before);
        }
        wallet.setMode(Mock1271Wallet.Mode.Approve);
        _activate(w, keyB, "");
        assertTrue(auth.isNonceUsed(address(wallet), w.nonce));
    }

    // ------------------------------------------------------------------
    // Partial activation rollback
    // ------------------------------------------------------------------

    /// @notice The module sets the nonce bit before it calls the vault, so a vault refusal must undo it. The vault
    ///         is made to refuse at its very last check (the vault-scope exposure cap, after every curator, pool,
    ///         floor, ceiling and admission check has passed) on all three paths: EOA signature, ERC-1271 wallet and
    ///         direct. Each refusal leaves no event and no change to nonces, allocation ids, Q_a, curator and hook
    ///         reservations, risk records, curator records or custody. Once the cap is raised, the very same
    ///         instructions activate and receive consecutive ids, so no id was consumed by the failures.
    function test_RB_lastVaultCheckRefusalRollsBackEverything() public {
        ISharedCommitmentVault.RiskLimit memory l = vault.getRiskLimit(VAULT, address(0), c1);
        vm.prank(owner);
        vault.setRiskLimit(VAULT, address(0), c1, l.flowCap, 1); // 0.01% of eligible backing, below 1,000 tokens

        ICuratorAuthorization.AllocationAuthorization memory e = _authz(signer, keyA, c1, 1000 ether);
        bytes memory eSig = _sign(signerKey, e);
        ICuratorAuthorization.AllocationAuthorization memory w = _authz(address(wallet), keyA, c1, 1000 ether);
        wallet.approve(auth.hashAuthorization(w), true);
        ISharedCommitmentVault.AllocationRequest memory d = _request(keyA, c1, 1000 ether);
        uint256 nextId = vault.nextAllocationId();

        for (uint256 path; path < 3; ++path) {
            bytes32 before = _state(path == 0 ? e.nonce : path == 1 ? w.nonce : d.nonce);
            vm.recordLogs();
            vm.expectPartialRevert(ISharedCommitmentVault.ExposureCapExceeded.selector);
            if (path == 0) {
                _activate(e, keyA, eSig);
            } else if (path == 1) {
                _activate(w, keyA, "");
            } else {
                vm.prank(curator);
                auth.activateDirect(d);
            }
            assertEq(vm.getRecordedLogs().length, 0, "no event");
            assertEq(_state(path == 0 ? e.nonce : path == 1 ? w.nonce : d.nonce), before, "nothing changed");
        }
        assertFalse(auth.isNonceUsed(signer, e.nonce));
        assertFalse(auth.isNonceUsed(address(wallet), w.nonce));
        assertFalse(auth.isNonceUsed(curator, d.nonce));

        vm.prank(owner);
        vault.setRiskLimit(VAULT, address(0), c1, l.flowCap, 10_000);
        assertEq(_activate(e, keyA, eSig), nextId);
        assertEq(_activate(w, keyA, ""), nextId + 1);
        vm.prank(curator);
        assertEq(auth.activateDirect(d), nextId + 2);
        _assertEquations();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev An instruction by `signer` for 1,000 of c1 on keyA with the given times.
    function _timed(uint64 va, uint64 dl, uint64 ex)
        internal
        returns (ICuratorAuthorization.AllocationAuthorization memory a)
    {
        return _timedFor(signer, va, dl, ex);
    }

    function _timedFor(address who, uint64 va, uint64 dl, uint64 ex)
        internal
        returns (ICuratorAuthorization.AllocationAuthorization memory a)
    {
        a = who == address(wallet) ? _authz(who, keyB, c0, 1000 ether) : _authz(who, keyA, c1, 1000 ether);
        (a.validAfter, a.deadline, a.expiry) = (va, dl, ex);
    }

    function _copy(ICuratorAuthorization.AllocationAuthorization memory a)
        internal
        pure
        returns (ICuratorAuthorization.AllocationAuthorization memory)
    {
        return abi.decode(abi.encode(a), (ICuratorAuthorization.AllocationAuthorization));
    }

    function _tooLong(uint64 va, uint64 dl) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ICuratorAuthorization.ValidityWindowTooLong.selector, va, dl);
    }

    function _expiryErr(uint64 ex, uint64 dl) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ICuratorAuthorization.ExpiryNotAfterDeadline.selector, ex, dl);
    }

    /// @dev Submits `w` and expects `InvalidSignature`, no event, and `_state` unchanged.
    function _expectNoTrace(ICuratorAuthorization.AllocationAuthorization memory w, bytes32 before) internal {
        vm.recordLogs();
        vm.expectRevert(ICuratorAuthorization.InvalidSignature.selector);
        _activate(w, keyB, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no event");
        assertEq(_state(w.nonce), before, "nothing changed");
    }

    /// @dev Hash of everything an activation could touch: the nonce words holding `nonce` for the three curators,
    ///      the next allocation id, Q_a, curator and hook reservations, the risk records of every scope involved,
    ///      the curator records, backing and the vault's real claim balances.
    function _state(uint256 nonce) internal view returns (bytes32 h) {
        address[3] memory cs = [signer, address(wallet), curator];
        Currency[2] memory cur = [c0, c1];
        h = keccak256(abi.encode(vault.nextAllocationId(), vault.authModule()));
        for (uint256 i; i < 3; ++i) {
            h = keccak256(abi.encode(h, auth.nonceBitmap(cs[i], nonce >> 8), vault.getCurator(cs[i])));
            for (uint256 j; j < 2; ++j) {
                h = keccak256(
                    abi.encode(h, vault.curatorReserved(cs[i], cur[j]), vault.getRiskLimit(CURATOR, cs[i], cur[j]))
                );
            }
        }
        for (uint256 j; j < 2; ++j) {
            h = keccak256(
                abi.encode(
                    h,
                    vault.reserved(cur[j]),
                    vault.backing(cur[j]),
                    _claims(address(vault), cur[j]),
                    vault.hookReserved(address(hookA), cur[j]),
                    vault.hookReserved(address(hookB), cur[j]),
                    vault.getRiskLimit(HOOK, address(hookA), cur[j]),
                    vault.getRiskLimit(HOOK, address(hookB), cur[j]),
                    vault.getRiskLimit(VAULT, address(0), cur[j])
                )
            );
        }
    }
}
