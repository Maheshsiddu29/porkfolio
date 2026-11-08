// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {ClaimDonor} from "../utils/ClaimDonor.sol";

/// @notice Phase 1A-H Task C: controlled first initialization. The asset pair is fixed by the constructor
///         (immutable, set in the deployment transaction itself); the initial reserve can only be established by
///         the owner; ordinary deposits stay permissionless afterwards.
contract InitializationTest is VaultTestBase {
    SharedCommitmentVault internal v;
    address internal lpA = makeAddr("lpA");

    function setUp() public override {
        super.setUp();
        v = new SharedCommitmentVault(manager, owner, c0, c1);
        _fund(attacker);
        _fund(curator);
        _fund(owner);
        _fund(lpA);
    }

    function _fund(address who) internal {
        token0.mint(who, 10_000_000 ether);
        token1.mint(who, 10_000_000 ether);
        vm.startPrank(who);
        token0.approve(address(v), type(uint256).max);
        token1.approve(address(v), type(uint256).max);
        vm.stopPrank();
    }

    function test_unauthorizedCallersCannotInitialize() public {
        address[3] memory callers = [attacker, curator, lpA];
        for (uint256 i; i < 3; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
            v.initialDeposit(1000 ether, 1000 ether, callers[i]);
        }
        assertEq(v.totalShares(), 0);
    }

    /// @notice Everything an attacker can do before the owner initializes either reverts or is ignored; the owner's
    ///         initialization then produces exactly the intended configuration.
    function test_preInitializationFrontRunningHasNoEffect() public {
        vm.startPrank(attacker);
        vm.expectRevert(ISharedCommitmentVault.NotInitialized.selector);
        v.deposit(1, type(uint256).max, type(uint256).max, attacker);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientShares.selector, 1, 0));
        v.redeem(1, 0, 0, attacker, true);
        assertEq(v.processQueue(10), 0);
        vm.stopPrank();

        // A donation of ERC-6909 claims before initialization is not counted.
        ClaimDonor donor = new ClaimDonor(manager);
        vm.startPrank(attacker);
        token0.approve(address(donor), type(uint256).max);
        token1.approve(address(donor), type(uint256).max);
        donor.donate(c0, 5000 ether, address(v));
        donor.donate(c1, 1, address(v));
        vm.stopPrank();

        // A registered curator cannot commit capacity of an empty vault.
        vm.startPrank(owner);
        v.setConsumer(address(hookA), true);
        v.setCurator(curator, true);
        v.setSellFloor(c1, PRICE_1_1_X96);
        v.setCuratorCeiling(curator, c1, type(uint256).max);
        vm.stopPrank();
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyA, c1, 1);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientBacking.selector, 1, 0));
        v.allocate(r);

        vm.prank(owner);
        uint256 shares = v.initialDeposit(4000 ether, 1000 ether, lpA);
        assertEq(shares, 2000 ether - v.MIN_SHARES(), "sqrt(4000e18 * 1000e18), unaffected by the donation");
        assertEq(v.backing(c0), 4000 ether);
        assertEq(v.backing(c1), 1000 ether);
        assertEq(v.sharesOf(lpA), shares);
        assertEq(v.sharesOf(address(0)), v.MIN_SHARES());
        (uint256 p0, uint256 p1) = v.previewDeposit(1 ether);
        assertEq(p0, 2 ether, "basket ratio is the owner's, 4:1 per 2 shares");
        assertEq(p1, 0.5 ether);
    }

    function test_ownerPaysReceiverOwns_lockedSharesPermanent() public {
        uint256 o0 = token0.balanceOf(owner);
        vm.prank(owner);
        v.initialDeposit(1001, 1001, lpA);
        assertEq(token0.balanceOf(owner), o0 - 1001, "payer is the owner");
        assertEq(v.sharesOf(lpA), 1);
        assertEq(v.sharesOf(address(0)), 1000);

        vm.prank(owner);
        vm.expectRevert(ISharedCommitmentVault.AlreadyInitialized.selector);
        v.initialDeposit(1 ether, 1 ether, owner);

        // Even after every redeemable share leaves, S == MIN_SHARES > 0: no re-initialization path exists.
        vm.prank(lpA);
        v.redeem(1, 0, 0, lpA, false);
        assertEq(v.totalShares(), 1000);
        vm.prank(owner);
        vm.expectRevert(ISharedCommitmentVault.AlreadyInitialized.selector);
        v.initialDeposit(1 ether, 1 ether, owner);
    }

    function test_subsequentDepositsArePermissionless() public {
        vm.prank(owner);
        v.initialDeposit(1000 ether, 1000 ether, owner);
        address[2] memory anyone = [attacker, lpA];
        for (uint256 i; i < 2; ++i) {
            vm.prank(anyone[i]);
            v.deposit(10 ether, 10 ether, 10 ether, anyone[i]);
            assertEq(v.sharesOf(anyone[i]), 10 ether);
        }
    }

    function test_ownershipTransfer_movesInitializationRight() public {
        vm.prank(owner);
        v.transferOwnership(lpA);
        // Two-step: nothing moves until the nominee accepts.
        assertEq(v.owner(), owner);
        vm.prank(lpA);
        v.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        v.initialDeposit(1000 ether, 1000 ether, owner);
        vm.prank(lpA);
        v.initialDeposit(1000 ether, 1000 ether, lpA);
        assertEq(v.sharesOf(lpA), 1000 ether - 1000);
    }

    function test_pausedVaultCannotBeInitialized() public {
        vm.startPrank(owner);
        v.setPaused(true);
        vm.expectRevert(ISharedCommitmentVault.Paused.selector);
        v.initialDeposit(1000 ether, 1000 ether, owner);
        vm.stopPrank();
    }
}
