// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @notice Role security: two-step ownership, a guardian that can only REDUCE risk, explicitly
///         registered curators, and the guarantee that no emergency action moves LP assets or blocks LP exits.
contract RolesTest is VaultTestBase {
    address internal guardian = makeAddr("guardian");
    address internal lpA = makeAddr("lpA");

    function setUp() public override {
        super.setUp();
        vm.startPrank(owner);
        vault.setGuardian(guardian);
        vault.setCuratorCeiling(curator, c0, type(uint256).max);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Two-step ownership
    // ------------------------------------------------------------------

    function test_RO_twoStepOwnership() public {
        address nominee = makeAddr("nominee");
        vm.prank(owner);
        vault.transferOwnership(nominee);
        assertEq(vault.owner(), owner, "nothing moves before acceptance");
        assertEq(vault.pendingOwner(), nominee);

        // Only the nominee can accept; the old owner keeps every right meanwhile.
        address[3] memory others = [attacker, guardian, owner];
        for (uint256 i; i < 3; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(ISharedCommitmentVault.NotPendingOwner.selector);
            vault.acceptOwnership();
        }
        vm.prank(owner);
        vault.setBufferFloor(c0, 1);

        vm.prank(nominee);
        vault.acceptOwnership();
        assertEq(vault.owner(), nominee);
        assertEq(vault.pendingOwner(), address(0), "nomination consumed");
        assertEq(vault.guardian(), guardian, "guardian unaffected by ownership transfer");

        // The old owner is now a stranger.
        vm.prank(owner);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setBufferFloor(c0, 0);
        // A consumed nomination cannot be replayed.
        vm.prank(nominee);
        vm.expectRevert(ISharedCommitmentVault.NotPendingOwner.selector);
        vault.acceptOwnership();
    }

    function test_RO_nominationCanBeReplacedOrCanceled() public {
        address n1 = makeAddr("n1");
        address n2 = makeAddr("n2");
        vm.startPrank(owner);
        vault.transferOwnership(n1);
        vault.transferOwnership(n2); // replaces n1
        vm.stopPrank();
        vm.prank(n1);
        vm.expectRevert(ISharedCommitmentVault.NotPendingOwner.selector);
        vault.acceptOwnership();

        vm.prank(owner);
        vault.transferOwnership(address(0)); // cancel
        vm.prank(n2);
        vm.expectRevert(ISharedCommitmentVault.NotPendingOwner.selector);
        vault.acceptOwnership();
        assertEq(vault.owner(), owner);
    }

    // ------------------------------------------------------------------
    // Guardian: risk-reducing only, never escalates
    // ------------------------------------------------------------------

    /// @notice The guardian can neither turn itself into the owner nor appoint someone else, and every setter it
    ///         can reach accepts only the risk-reducing direction (tighten, revoke, pause), never the reverse.
    function test_RO_guardianCannotEscalateOrIncreaseRisk() public {
        vm.startPrank(guardian);
        // Ownership and the guardian slot are owner-only (plain NotOwner: these are not risk actions at all).
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.transferOwnership(guardian);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setGuardian(attacker);
        vm.expectRevert(ISharedCommitmentVault.NotPendingOwner.selector);
        vault.acceptOwnership();

        // Every risk-INCREASING change is refused.
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setConsumer(attacker, true);
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setCurator(attacker, true);
        vault.setCuratorCeiling(curator, c0, 100 ether); // lowering: allowed
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setCuratorCeiling(curator, c0, 100 ether + 1); // raising back: refused
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setCuratorCeiling(attacker, c0, 1);
        vm.stopPrank();

        vm.prank(owner);
        vault.setBufferFloor(c0, 100 ether);
        vm.startPrank(guardian);
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setBufferFloor(c0, 99 ether);
        vault.setPaused(true);
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setPaused(false);
        vm.stopPrank();

        assertEq(vault.owner(), owner);
        assertEq(vault.guardian(), guardian);
        assertTrue(vault.paused());
    }

    function test_RO_strangersCannotConfigure() public {
        vm.startPrank(attacker);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setGuardian(attacker);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setCurator(attacker, true);
        // Strangers cannot even perform risk-REDUCING changes.
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setCurator(curator, false);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setConsumer(address(hookA), false);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setCuratorCeiling(curator, c0, 0);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setBufferFloor(c0, 1);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setPaused(true);
        vm.stopPrank();
    }

    function test_RO_removedGuardianLosesEveryPower() public {
        vm.prank(owner);
        vault.setGuardian(address(0));
        vm.startPrank(guardian);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setPaused(true);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setConsumer(address(hookA), false);
        vm.stopPrank();
        uint256 id = _allocate(keyA, c1, 1000 ether);
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.AllocationNotExpired.selector, id, vault.getAllocation(id).expiry
            )
        );
        vault.release(id);
    }

    /// @notice Every guardian power, applied together, moves no asset and changes no share balance.
    function test_RO_guardianEmergencyActions_moveNoAssets() public {
        uint256 id = _allocate(keyA, c1, 100_000 ether);
        _swap(keyA, true, 1000 ether, id);
        uint256[8] memory before = _assetSnapshot();

        vm.startPrank(guardian);
        vault.setPaused(true);
        vault.setConsumer(address(hookA), false);
        vault.setCurator(curator, false);
        vault.setCuratorCeiling(curator, c1, 0);
        vault.setBufferFloor(c1, type(uint256).max);
        vault.release(id); // emergency release before expiry
        vm.stopPrank();

        uint256[8] memory afterSnap = _assetSnapshot();
        for (uint256 i; i < 8; ++i) {
            assertEq(afterSnap[i], before[i], "guardian action moved assets or shares");
        }
        assertTrue(vault.getAllocation(id).released);
        assertEq(vault.reserved(c1), 0, "capacity returned to free inventory");
        _assertEquations();
        _assertAccountingConsistent();
    }

    // ------------------------------------------------------------------
    // Curator registry
    // ------------------------------------------------------------------

    function test_RO_curatorRegistry() public {
        uint256 id = _allocate(keyA, c1, 10_000 ether);

        // Guardian deregisters: new allocations are refused immediately.
        vm.prank(guardian);
        vault.setCurator(curator, false);
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, 1 ether);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.CuratorNotRegistered.selector, curator));
        vault.allocate(req);

        // An existing allocation is a commitment: still consumable until released (CA §7.5), and the guardian can
        // release it at once.
        _swap(keyA, true, 1000 ether, id);
        vm.prank(guardian);
        vault.release(id);
        _expectSwapRevert(
            address(hookA), abi.encodeWithSelector(ISharedCommitmentVault.AllocationAlreadyReleased.selector, id)
        );
        _swap(keyA, true, 1000 ether, id);

        // Only the owner can re-register.
        vm.prank(guardian);
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setCurator(curator, true);
        vm.prank(owner);
        vault.setCurator(curator, true);
        vm.prank(curator);
        vault.allocate(req);
        _assertEquations();
    }

    function test_RO_zeroAddressRejected() public {
        vm.startPrank(owner);
        vm.expectRevert(ISharedCommitmentVault.ZeroAddress.selector);
        vault.setCurator(address(0), true);
        vm.expectRevert(ISharedCommitmentVault.ZeroAddress.selector);
        vault.setConsumer(address(0), true);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Emergency state never blocks LP exits
    // ------------------------------------------------------------------

    /// @notice With the guardian's full emergency posture in place, every eligible LP exit path still works:
    ///         instant redeem, queued redeem, queue processing, cancel, claim, and permissionless expiry release.
    function test_RO_guardianPause_doesNotBlockLpExits() public {
        _depositShares(lpA, 100_000 ether);
        uint256 lock = _allocate(keyA, c1, uint128(vault.admissibleCapacity(c1)));
        (uint256 instant,,, uint256 req) = _redeem(lpA, 50_000 ether, true);
        assertEq(instant, 0, "queued behind the lock");

        vm.startPrank(guardian);
        vault.setPaused(true);
        vault.setConsumer(address(hookA), false);
        vault.setCurator(curator, false);
        vm.stopPrank();

        // Lazy expiry release is permissionless even while paused.
        vm.warp(vault.getAllocation(lock).expiry);
        vm.prank(attacker);
        vault.release(lock);
        assertGt(vault.processQueue(5), 0);
        vm.prank(lpA);
        (uint256 o0, uint256 o1) = vault.claim(req);
        assertGt(o0 + o1, 0);

        (,,, uint256 req2) = _redeem(lpA, 10_000 ether, true); // instant now (queue empty, inventory free)
        assertEq(req2, 0);
        _lockAll();
        (,,, uint256 req3) = _redeem(lpA, 10_000 ether, true);
        assertGt(req3, 0);
        vm.prank(lpA);
        vault.cancelRequest(req3);
        _assertEquations();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _lockAll() internal {
        vm.prank(owner);
        vault.setPaused(false);
        vm.startPrank(owner);
        vault.setCurator(curator, true);
        vault.setConsumer(address(hookA), true);
        vm.stopPrank();
        _allocate(keyA, c1, uint128(vault.admissibleCapacity(c1)));
        vm.prank(guardian);
        vault.setPaused(true);
    }

    function _assetSnapshot() internal view returns (uint256[8] memory s) {
        s[0] = _claims(address(vault), c0);
        s[1] = _claims(address(vault), c1);
        s[2] = MockERC20(Currency.unwrap(c0)).balanceOf(address(manager));
        s[3] = MockERC20(Currency.unwrap(c1)).balanceOf(address(manager));
        s[4] = vault.backing(c0);
        s[5] = vault.backing(c1);
        s[6] = vault.totalShares();
        s[7] = vault.sharesOf(lp0);
    }
}
