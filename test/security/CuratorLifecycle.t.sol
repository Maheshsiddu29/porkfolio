// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {AuthModeHook} from "../utils/AuthModeHook.sol";

/// @notice Curator states: registration, temporary freeze, permanent revocation and the generation counter.
/// @dev The properties under test, each tied to a requirement:
///        - a frozen or revoked curator can neither create nor consume, from the same transaction on;
///        - freezing and revoking move no assets and keep every reservation (Q_a, curatorReserved) in place;
///        - only the owner lifts a freeze, and a lifted freeze raises the generation;
///        - revocation is terminal for every role, including after ownership and guardian changes;
///        - the generation only rises, never wraps, and is not restored by re-registration;
///        - after revocation anyone can release the curator's allocations, each exactly once, returning exactly
///          maxOut - consumed;
///        - LP exits keep working in every curator state.
contract CuratorLifecycleTest is VaultTestBase {
    address internal guardian = makeAddr("guardian");
    address internal curator2 = makeAddr("curator2");
    address internal lpA = makeAddr("lpA");

    /// @dev Storage slot of the `_curators` mapping (the slot `isCurator` used to occupy). `_curatorSlot` checks the
    ///      packing against `getCurator` before any test writes to it, so a layout change fails loudly.
    uint256 internal constant CURATORS_SLOT = 4;

    /// @dev Pool of a 1:1, fee-free test hook, so that an allocation can be consumed to exactly maxOut.
    PoolKey internal keyE;

    function setUp() public override {
        super.setUp();
        address e = address(uint160(0x0E1 << 140) | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        deployCodeTo("AuthModeHook.sol:AuthModeHook", abi.encode(manager, vault, AuthModeHook.Mode.Operator), e);
        keyE = PoolKey(c0, c1, 3000, 60, IHooks(e));
        manager.initialize(keyE, SQRT_PRICE_1_1);
        vm.startPrank(owner);
        vault.setConsumer(e, true);
        vault.setGuardian(guardian);
        vault.setCurator(curator2, true);
        _openLimits(ISharedCommitmentVault.RiskScope.Hook, e);
        _openLimits(ISharedCommitmentVault.RiskScope.Curator, curator2);
        vault.setCuratorCeiling(curator2, c0, VAULT_FUNDING);
        vault.setCuratorCeiling(curator2, c1, VAULT_FUNDING);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Registration and deregistration
    // ------------------------------------------------------------------

    function test_CL_registrationRecord() public {
        address fresh = makeAddr("fresh");
        _assertRecord(fresh, false, ISharedCommitmentVault.CuratorRestriction.None, 0);
        vm.prank(owner);
        vault.setCurator(fresh, true);
        _assertRecord(fresh, true, ISharedCommitmentVault.CuratorRestriction.None, 0);
        // Registering again is a no-op on the record (no generation change).
        vm.prank(owner);
        vault.setCurator(fresh, true);
        _assertRecord(fresh, true, ISharedCommitmentVault.CuratorRestriction.None, 0);
    }

    /// @notice Deregistration stops creation, raises the generation, and leaves existing allocations consumable.
    ///         Re-registration restores creation but not the old generation, so an instruction tagged with the old
    ///         generation stays dead.
    function test_CL_deregister_bumpsGeneration_keepsAllocationsConsumable() public {
        uint256 id = _allocate(keyA, c1, 10_000 ether);
        vm.prank(guardian);
        vault.setCurator(curator, false);
        _assertRecord(curator, false, ISharedCommitmentVault.CuratorRestriction.None, 1);

        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, 1 ether);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.CuratorNotRegistered.selector, curator));
        vault.allocate(req);

        _swap(keyA, true, 1000 ether, id); // still a commitment to the hook
        assertGt(vault.getAllocation(id).consumed, 0);

        vm.prank(owner);
        vault.setCurator(curator, true);
        _assertRecord(curator, true, ISharedCommitmentVault.CuratorRestriction.None, 1);
        // A second deregistration raises it again, even though nothing was signed in between.
        vm.prank(owner);
        vault.setCurator(curator, false);
        vm.prank(owner);
        vault.setCurator(curator, false);
        _assertRecord(curator, false, ISharedCommitmentVault.CuratorRestriction.None, 3);
        _assertEquations();
    }

    // ------------------------------------------------------------------
    // Freeze
    // ------------------------------------------------------------------

    /// @notice Freeze before any consumption: no creation, no consumption, the whole reservation stays, no asset
    ///         or share moves, and the curator's registration and generation are untouched.
    function test_CL_freezeBeforeConsumption() public {
        uint256 id = _allocate(keyA, c1, 10_000 ether);
        uint256[12] memory before = _snapshot();
        vm.prank(guardian);
        vault.freezeCurator(curator);
        _assertSnapshotUnchanged(before);
        _assertRecord(curator, true, ISharedCommitmentVault.CuratorRestriction.Frozen, 0);

        _expectFrozenSwap(address(hookA), curator);
        _swap(keyA, true, 1000 ether, id);
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, 1 ether);
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.CuratorRestricted.selector,
                curator,
                ISharedCommitmentVault.CuratorRestriction.Frozen
            )
        );
        vault.allocate(req);
        assertEq(vault.reserved(c1), 10_000 ether, "reservation kept while frozen");
        _assertEquations();
    }

    /// @notice Freeze after partial consumption: exactly the unconsumed remainder stays reserved, consumption
    ///         stops, and after the owner lifts the freeze the remainder can be consumed and no more.
    function test_CL_freezeDuringPartialConsumption() public {
        uint256 id = _allocate(keyA, c1, 10_000 ether);
        _swap(keyA, true, 4000 ether, id);
        uint128 consumed = vault.getAllocation(id).consumed;
        uint256 remaining = 10_000 ether - consumed;

        vm.prank(owner);
        vault.freezeCurator(curator);
        assertEq(vault.reserved(c1), remaining, "Q = maxOut - consumed while frozen");
        assertEq(vault.curatorReserved(curator, c1), remaining);
        _expectFrozenSwap(address(hookA), curator);
        _swap(keyA, true, 1 ether, id);

        vm.prank(owner);
        vault.unfreezeCurator(curator);
        _assertRecord(curator, true, ISharedCommitmentVault.CuratorRestriction.None, 1);
        _swap(keyA, true, 1000 ether, id);
        assertGt(vault.getAllocation(id).consumed, consumed, "consumption resumes after unfreeze");
        _assertEquations();
    }

    /// @notice Freeze after full consumption: nothing is reserved, so nothing is held back, and the freeze still
    ///         blocks new allocations.
    function test_CL_freezeAfterFullConsumption() public {
        uint256 id = _allocate(keyE, c1, 1000 ether);
        _swap(keyE, true, 1000 ether, id); // 1:1 hook: consumes exactly maxOut
        assertEq(vault.getAllocation(id).consumed, 1000 ether);
        assertEq(vault.curatorReserved(curator, c1), 0);
        uint256[12] memory before = _snapshot();
        vm.prank(owner);
        vault.freezeCurator(curator);
        _assertSnapshotUnchanged(before);
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyE, c1, 1 ether);
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.CuratorRestricted.selector,
                curator,
                ISharedCommitmentVault.CuratorRestriction.Frozen
            )
        );
        vault.allocate(req);
        // A fully consumed allocation releases nothing: consumed output is never returned as unused capacity.
        vm.prank(owner);
        vault.release(id);
        assertEq(vault.reserved(c1), 0);
        _assertEquations();
    }

    function test_CL_guardianFreezes_onlyOwnerUnfreezes() public {
        vm.prank(guardian);
        vault.freezeCurator(curator);
        vm.prank(guardian);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.unfreezeCurator(curator);
        vm.prank(attacker);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.unfreezeCurator(curator);
        vm.prank(curator);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.unfreezeCurator(curator);
        // Strangers and curators cannot freeze anyone, not even themselves through this entry point.
        vm.prank(attacker);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.freezeCurator(curator2);
        vm.prank(curator2);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.freezeCurator(curator2);
        _assertRecord(curator, true, ISharedCommitmentVault.CuratorRestriction.Frozen, 0);
    }

    /// @notice An ordinary re-registration does not lift an emergency freeze, and a freeze survives
    ///         deregistration. Lifting the freeze does not re-register a curator that was deregistered meanwhile.
    function test_CL_registrationAndFreezeAreIndependent() public {
        uint256 id = _allocate(keyA, c1, 10_000 ether);
        vm.prank(guardian);
        vault.freezeCurator(curator);
        vm.prank(owner);
        vault.setCurator(curator, true); // ordinary re-registration
        _assertRecord(curator, true, ISharedCommitmentVault.CuratorRestriction.Frozen, 0);
        _expectFrozenSwap(address(hookA), curator);
        _swap(keyA, true, 1 ether, id);

        vm.prank(guardian);
        vault.setCurator(curator, false); // deregister while frozen: stays frozen
        _assertRecord(curator, false, ISharedCommitmentVault.CuratorRestriction.Frozen, 1);
        _expectFrozenSwap(address(hookA), curator);
        _swap(keyA, true, 1 ether, id);

        vm.prank(owner);
        vault.unfreezeCurator(curator);
        _assertRecord(curator, false, ISharedCommitmentVault.CuratorRestriction.None, 2);
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, 1 ether);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.CuratorNotRegistered.selector, curator));
        vault.allocate(req);
        _swap(keyA, true, 1 ether, id); // a deregistered, unrestricted curator's allocation is consumable
    }

    function test_CL_invalidTransitions() public {
        vm.startPrank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.InvalidCuratorTransition.selector,
                curator,
                ISharedCommitmentVault.CuratorRestriction.None
            )
        );
        vault.unfreezeCurator(curator);
        vault.freezeCurator(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.InvalidCuratorTransition.selector,
                curator,
                ISharedCommitmentVault.CuratorRestriction.Frozen
            )
        );
        vault.freezeCurator(curator);
        vault.revokeCurator(curator); // Frozen -> Revoked is a tightening and is allowed
        bytes memory revoked = abi.encodeWithSelector(
            ISharedCommitmentVault.InvalidCuratorTransition.selector,
            curator,
            ISharedCommitmentVault.CuratorRestriction.Revoked
        );
        vm.expectRevert(revoked);
        vault.freezeCurator(curator); // Revoked -> Frozen would make it unfreezable again
        vm.expectRevert(revoked);
        vault.unfreezeCurator(curator);
        vm.expectRevert(revoked);
        vault.revokeCurator(curator);
        vm.expectRevert(revoked);
        vault.setCurator(curator, true);
        vm.stopPrank();
    }

    function test_CL_zeroAddressRejected() public {
        vm.startPrank(owner);
        vm.expectRevert(ISharedCommitmentVault.ZeroAddress.selector);
        vault.freezeCurator(address(0));
        vm.expectRevert(ISharedCommitmentVault.ZeroAddress.selector);
        vault.revokeCurator(address(0));
        vm.stopPrank();
    }

    /// @notice Freeze and revoke are emergency actions: they work while the vault is paused and while a direction
    ///         is halted, and so does the owner's unfreeze.
    function test_CL_emergencyActionsWorkWhilePaused() public {
        vm.startPrank(guardian);
        vault.setPaused(true);
        vault.setSellHalted(c1, true);
        vault.freezeCurator(curator);
        vault.revokeCurator(curator2);
        vm.stopPrank();
        vm.prank(owner);
        vault.unfreezeCurator(curator);
        vm.prank(curator);
        vault.bumpGeneration();
        _assertRecord(curator, true, ISharedCommitmentVault.CuratorRestriction.None, 2);
    }

    // ------------------------------------------------------------------
    // Revocation and permissionless cleanup
    // ------------------------------------------------------------------

    /// @notice One revocation call stops every allocation of the curator, on both hooks and in both directions,
    ///         without touching any of them; the other curator is unaffected.
    function test_CL_revoke_stopsEveryAllocationInOneCall() public {
        uint256 a1 = _allocate(keyA, c1, 10_000 ether);
        uint256 a2 = _allocate(keyA, c0, 10_000 ether);
        uint256 b1 = _allocate(keyB, c1, 10_000 ether);
        uint256 other = _allocateAs(curator2, keyA, c1, 10_000 ether);
        uint256[12] memory before = _snapshot();

        vm.prank(guardian);
        vault.revokeCurator(curator);
        _assertSnapshotUnchanged(before);
        _assertRecord(curator, false, ISharedCommitmentVault.CuratorRestriction.Revoked, 0);

        _expectRevokedSwap(address(hookA), curator);
        _swap(keyA, true, 100 ether, a1);
        _expectRevokedSwap(address(hookA), curator);
        _swap(keyA, false, 100 ether, a2);
        _expectRevokedSwap(address(hookB), curator);
        _swap(keyB, true, 100 ether, b1);
        _swap(keyA, true, 100 ether, other); // independent curator
        _assertEquations();
    }

    /// @notice After revocation anyone may release each allocation once. Each release returns exactly
    ///         maxOut - consumed, in any order, and consumed output is never returned as unused capacity.
    function test_CL_revokedCleanup_afterPartialConsumption_anyOrder() public {
        uint256 a1 = _allocate(keyA, c1, 10_000 ether);
        uint256 a2 = _allocate(keyB, c1, 20_000 ether);
        uint256 a3 = _allocate(keyA, c0, 5000 ether);
        _swap(keyA, true, 3000 ether, a1);
        _swap(keyB, true, 7000 ether, a2);
        uint256 other = _allocateAs(curator2, keyA, c1, 1000 ether);

        vm.prank(owner);
        vault.revokeCurator(curator);

        uint256[3] memory ids = [a3, a1, a2]; // arbitrary order
        for (uint256 i; i < 3; ++i) {
            ISharedCommitmentVault.Allocation memory a = vault.getAllocation(ids[i]);
            uint256 q = vault.reserved(a.currencyOut);
            uint256 cr = vault.curatorReserved(curator, a.currencyOut);
            vm.prank(attacker);
            vault.release(ids[i]);
            assertEq(q - vault.reserved(a.currencyOut), a.maxOut - a.consumed, "release != maxOut - consumed");
            assertEq(cr - vault.curatorReserved(curator, a.currencyOut), a.maxOut - a.consumed);
            assertEq(vault.getAllocation(ids[i]).consumed, a.consumed, "consumed unchanged by release");
            vm.prank(attacker);
            vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.AllocationAlreadyReleased.selector, ids[i]));
            vault.release(ids[i]);
        }
        assertEq(vault.curatorReserved(curator, c0), 0);
        assertEq(vault.curatorReserved(curator, c1), 0);
        // The other curator's allocation is untouched and still not releasable by a stranger.
        assertEq(vault.reserved(c1), 1000 ether);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.AllocationNotExpired.selector, other, vault.getAllocation(other).expiry
            )
        );
        vault.release(other);
        _assertEquations();
    }

    /// @notice Permissionless early release is only for revoked curators. A frozen or deregistered curator's
    ///         unexpired allocation stays a commitment: a stranger cannot release it (the owner, the guardian or
    ///         the curator itself can), because a freeze may be lifted.
    function test_CL_frozenOrDeregisteredAllocationNotReleasableByStranger() public {
        uint256 id = _allocate(keyA, c1, 10_000 ether);
        uint256 id2 = _allocateAs(curator2, keyA, c1, 10_000 ether);
        vm.prank(guardian);
        vault.freezeCurator(curator);
        vm.prank(guardian);
        vault.setCurator(curator2, false);
        uint64 expiry = vault.getAllocation(id).expiry;
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.AllocationNotExpired.selector, id, expiry));
        vault.release(id);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.AllocationNotExpired.selector, id2, expiry));
        vault.release(id2);
        vm.prank(guardian);
        vault.release(id);
        vm.warp(expiry);
        vm.prank(attacker);
        vault.release(id2); // after expiry anyone may
        assertEq(vault.reserved(c1), 0);
        _assertEquations();
    }

    /// @notice Revocation is terminal across owner and guardian changes: a new owner cannot re-register or
    ///         unfreeze the curator, and none of its allocations become executable again.
    function test_CL_revocationSurvivesOwnerAndGuardianChanges() public {
        uint256 id = _allocate(keyA, c1, 10_000 ether);
        vm.prank(guardian);
        vault.revokeCurator(curator);

        address newOwner = makeAddr("newOwner");
        address newGuardian = makeAddr("newGuardian");
        vm.prank(owner);
        vault.transferOwnership(newOwner);
        vm.prank(newOwner);
        vault.acceptOwnership();
        vm.prank(newOwner);
        vault.setGuardian(newGuardian);

        bytes memory revoked = abi.encodeWithSelector(
            ISharedCommitmentVault.InvalidCuratorTransition.selector,
            curator,
            ISharedCommitmentVault.CuratorRestriction.Revoked
        );
        vm.startPrank(newOwner);
        vm.expectRevert(revoked);
        vault.setCurator(curator, true);
        vm.expectRevert(revoked);
        vault.unfreezeCurator(curator);
        vault.setCuratorCeiling(curator, c1, type(uint256).max); // even with a ceiling, nothing is allowed
        vm.stopPrank();

        _expectRevokedSwap(address(hookA), curator);
        _swap(keyA, true, 1 ether, id);
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, 1 ether);
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.CuratorRestricted.selector,
                curator,
                ISharedCommitmentVault.CuratorRestriction.Revoked
            )
        );
        vault.allocate(req);
        // The curator can still raise its own generation (harmless), and cleanup still works.
        vm.prank(curator);
        assertEq(vault.bumpGeneration(), 1);
        vm.prank(attacker);
        vault.release(id);
        _expectSwapRevert(
            address(hookA), abi.encodeWithSelector(ISharedCommitmentVault.AllocationAlreadyReleased.selector, id)
        );
        _swap(keyA, true, 1 ether, id);
    }

    // ------------------------------------------------------------------
    // Guardian authority
    // ------------------------------------------------------------------

    /// @notice The guardian can only restrict: it cannot register, unfreeze, or undo a revocation, and the
    ///         curator gains nothing back from any guardian call.
    function test_CL_guardianCannotIncreaseAuthority() public {
        vm.startPrank(guardian);
        vault.freezeCurator(curator);
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setCurator(curator, true);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.unfreezeCurator(curator);
        vault.revokeCurator(curator2);
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setCurator(curator2, true);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.unfreezeCurator(curator2);
        vm.stopPrank();
        _assertRecord(curator, true, ISharedCommitmentVault.CuratorRestriction.Frozen, 0);
        _assertRecord(curator2, false, ISharedCommitmentVault.CuratorRestriction.Revoked, 0);
    }

    // ------------------------------------------------------------------
    // Generation counter
    // ------------------------------------------------------------------

    /// @notice The generation rises by exactly one on deregistration, unfreeze and self-bump; freeze, revoke and
    ///         registration leave it alone.
    function test_CL_generationRules() public {
        vm.prank(curator);
        assertEq(vault.bumpGeneration(), 1);
        vm.prank(owner);
        vault.setCurator(curator, true);
        _assertGeneration(curator, 1);
        vm.prank(owner);
        vault.freezeCurator(curator);
        _assertGeneration(curator, 1);
        vm.prank(owner);
        vault.unfreezeCurator(curator);
        _assertGeneration(curator, 2);
        vm.prank(guardian);
        vault.setCurator(curator, false);
        _assertGeneration(curator, 3);
        vm.prank(guardian);
        vault.revokeCurator(curator);
        _assertGeneration(curator, 3);
        // Any address can bump its own counter and only its own.
        vm.prank(attacker);
        vault.bumpGeneration();
        _assertGeneration(attacker, 1);
        _assertGeneration(curator, 3);
        _assertGeneration(curator2, 0);
    }

    /// @notice At type(uint32).max the counter refuses to move instead of wrapping to 0 (which would reuse every
    ///         old generation value). Deregistration, unfreeze and self-bump revert; freeze and revoke still work,
    ///         so the guardian always has a lever that stops the curator.
    function test_CL_generationExhaustion() public {
        _setGeneration(curator, type(uint32).max - 1);
        vm.prank(curator);
        assertEq(vault.bumpGeneration(), type(uint32).max);

        bytes memory exhausted = abi.encodeWithSelector(ISharedCommitmentVault.GenerationExhausted.selector, curator);
        vm.prank(curator);
        vm.expectRevert(exhausted);
        vault.bumpGeneration();
        vm.prank(guardian);
        vm.expectRevert(exhausted);
        vault.setCurator(curator, false);

        vm.prank(guardian);
        vault.freezeCurator(curator);
        vm.prank(owner);
        vm.expectRevert(exhausted);
        vault.unfreezeCurator(curator); // stays frozen: fail closed
        _assertRecord(curator, true, ISharedCommitmentVault.CuratorRestriction.Frozen, type(uint32).max);
        vm.prank(guardian);
        vault.revokeCurator(curator);
        _assertRecord(curator, false, ISharedCommitmentVault.CuratorRestriction.Revoked, type(uint32).max);
    }

    /// @notice Random sequences of every curator action by every role. After each step: the generation never
    ///         decreased, a revoked curator stayed revoked and unregistered, and only the owner ever lifted a
    ///         freeze.
    function testFuzz_CL_randomTransitions(uint256 seed) public {
        address[2] memory cs = [curator, curator2];
        uint32[2] memory lastGen;
        bool[2] memory wasRevoked;
        for (uint256 step; step < 24; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 who = r % 2;
            address c = cs[who];
            address caller = [owner, guardian, attacker, c][(r >> 8) % 4];
            ISharedCommitmentVault.CuratorRestriction prior = vault.getCurator(c).restriction;
            vm.prank(caller);
            uint256 action = (r >> 16) % 6;
            bool ok;
            if (action == 0) (ok,) = address(vault).call(abi.encodeCall(vault.setCurator, (c, true)));
            else if (action == 1) (ok,) = address(vault).call(abi.encodeCall(vault.setCurator, (c, false)));
            else if (action == 2) (ok,) = address(vault).call(abi.encodeCall(vault.freezeCurator, (c)));
            else if (action == 3) (ok,) = address(vault).call(abi.encodeCall(vault.unfreezeCurator, (c)));
            else if (action == 4) (ok,) = address(vault).call(abi.encodeCall(vault.revokeCurator, (c)));
            else (ok,) = address(vault).call(abi.encodeCall(vault.bumpGeneration, ()));

            ISharedCommitmentVault.CuratorRecord memory rec = vault.getCurator(c);
            assertGe(rec.generation, lastGen[who], "generation decreased");
            lastGen[who] = rec.generation;
            if (wasRevoked[who]) {
                assertEq(uint8(rec.restriction), uint8(ISharedCommitmentVault.CuratorRestriction.Revoked));
                assertFalse(rec.registered, "revoked curator registered");
            }
            if (rec.restriction == ISharedCommitmentVault.CuratorRestriction.Revoked) wasRevoked[who] = true;
            if (
                ok && prior == ISharedCommitmentVault.CuratorRestriction.Frozen
                    && rec.restriction == ISharedCommitmentVault.CuratorRestriction.None
            ) assertEq(caller, owner, "freeze lifted by someone other than the owner");
            if (ok && action == 0) assertTrue(caller == owner, "registration by non-owner");
        }
    }

    // ------------------------------------------------------------------
    // LP exits in every curator state
    // ------------------------------------------------------------------

    /// @notice With every unit of asset1 committed to a curator: freezing keeps the capacity reserved, so a
    ///         redemption queues instead of being paid from it; revoking lets anyone (here the LP itself) release
    ///         it, after which the queue is finalized and claimed. Claimable assets W_a are never touched by the
    ///         curator actions.
    function test_CL_lpExitsWhileFrozenThenRevoked() public {
        _depositShares(lpA, 100_000 ether);
        vm.prank(owner);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        uint256 lock = _allocate(keyA, c1, uint128(vault.admissibleCapacity(c1)));
        _swap(keyA, true, 1000 ether, lock);

        vm.prank(guardian);
        vault.freezeCurator(curator);
        (uint256 instant,,, uint256 req) = _redeem(lpA, 50_000 ether, true);
        assertEq(instant, 0, "frozen capacity is not paid out to redeemers");
        uint256 w0 = vault.claimableAssets(c0);
        uint256 w1 = vault.claimableAssets(c1);

        vm.prank(guardian);
        vault.revokeCurator(curator);
        assertEq(vault.claimableAssets(c0), w0);
        assertEq(vault.claimableAssets(c1), w1);
        vm.prank(lpA);
        vault.release(lock); // the LP cleans up the revoked curator's allocation itself
        assertGt(vault.processQueue(5), 0);
        uint256 bal0 = token0.balanceOf(lpA);
        uint256 bal1 = token1.balanceOf(lpA);
        vm.prank(lpA);
        (uint256 o0, uint256 o1) = vault.claim(req);
        assertEq(token0.balanceOf(lpA) - bal0, o0);
        assertEq(token1.balanceOf(lpA) - bal1, o1);
        assertGt(o1, 0);
        _assertEquations();
        _assertAccountingConsistent();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _allocateAs(address who, PoolKey memory key, Currency out, uint128 maxOut) internal returns (uint256) {
        ISharedCommitmentVault.AllocationRequest memory req = _request(key, out, maxOut);
        vm.prank(who);
        return vault.allocate(req);
    }

    function _assertRecord(
        address c,
        bool registered,
        ISharedCommitmentVault.CuratorRestriction restriction,
        uint32 generation
    ) internal view {
        ISharedCommitmentVault.CuratorRecord memory r = vault.getCurator(c);
        assertEq(r.registered, registered, "registered");
        assertEq(uint8(r.restriction), uint8(restriction), "restriction");
        assertEq(r.generation, generation, "generation");
    }

    function _assertGeneration(address c, uint32 generation) internal view {
        assertEq(vault.getCurator(c).generation, generation, "generation");
    }

    function _expectFrozenSwap(address hook, address c) internal {
        _expectSwapRevert(
            hook,
            abi.encodeWithSelector(
                ISharedCommitmentVault.CuratorRestricted.selector, c, ISharedCommitmentVault.CuratorRestriction.Frozen
            )
        );
    }

    function _expectRevokedSwap(address hook, address c) internal {
        _expectSwapRevert(
            hook,
            abi.encodeWithSelector(
                ISharedCommitmentVault.CuratorRestricted.selector, c, ISharedCommitmentVault.CuratorRestriction.Revoked
            )
        );
    }

    /// @dev Packing (low-order bytes first): registered (1 byte), restriction (1 byte), generation (4 bytes).
    function _setGeneration(address c, uint32 generation) internal {
        bytes32 slot = keccak256(abi.encode(c, CURATORS_SLOT));
        ISharedCommitmentVault.CuratorRecord memory r = vault.getCurator(c);
        uint256 expected = (r.registered ? 1 : 0) | (uint256(uint8(r.restriction)) << 8) | (uint256(r.generation) << 16);
        assertEq(uint256(vm.load(address(vault), slot)), expected, "curator slot layout changed");
        uint256 updated = (expected & ~(uint256(type(uint32).max) << 16)) | (uint256(generation) << 16);
        vm.store(address(vault), slot, bytes32(updated));
        assertEq(vault.getCurator(c).generation, generation);
    }

    /// @dev Everything a curator action must leave alone: real balances, B_a, W_a, Q_a, S, P and an LP balance.
    function _snapshot() internal view returns (uint256[12] memory s) {
        s[0] = _claims(address(vault), c0);
        s[1] = _claims(address(vault), c1);
        s[2] = MockERC20(Currency.unwrap(c0)).balanceOf(address(manager));
        s[3] = MockERC20(Currency.unwrap(c1)).balanceOf(address(manager));
        s[4] = vault.backing(c0);
        s[5] = vault.backing(c1);
        s[6] = vault.claimableAssets(c0) + vault.claimableAssets(c1);
        s[7] = vault.reserved(c0);
        s[8] = vault.reserved(c1);
        s[9] = vault.curatorReserved(curator, c0) + vault.curatorReserved(curator, c1);
        s[10] = vault.totalShares();
        s[11] = vault.pendingShares() + vault.sharesOf(lp0);
    }

    function _assertSnapshotUnchanged(uint256[12] memory before) internal view {
        uint256[12] memory afterSnap = _snapshot();
        for (uint256 i; i < 12; ++i) {
            assertEq(afterSnap[i], before[i], "curator action moved assets, shares or reservations");
        }
    }
}
