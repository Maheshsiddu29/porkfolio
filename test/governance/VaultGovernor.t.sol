// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {IMarketRiskAdapter} from "../../src/interfaces/IMarketRiskAdapter.sol";
import {VaultGovernor} from "../../src/governance/VaultGovernor.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {MockRiskAdapter} from "../utils/MockRiskAdapter.sol";

/// @notice The governor as the vault's owner: every owner call waits its delay, runs once inside its window, and can be
///         canceled by the admin or the guardian (never the guardian's own replacement). The guardian keeps its
///         immediate, risk-reducing powers on the vault. The last test shows why the floor delay exceeds MAX_HORIZON.
contract VaultGovernorTest is VaultTestBase {
    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    VaultGovernor internal gov;
    uint256 internal tau;

    function setUp() public override {
        super.setUp();
        tau = FullMath.mulDiv(vault.backing(c0), 1e18, vault.totalShares());
        gov = new VaultGovernor(address(vault), admin);
        vm.startPrank(owner);
        vault.setGuardian(guardian);
        vault.setInventoryBounds(tau, tau, 50_000, 50_000);
        vault.setRiskBounds(100, 5000);
        vault.transferOwnership(address(gov));
        vm.stopPrank();
        vm.prank(admin);
        gov.acceptVaultOwnership();
    }

    function _queue(bytes memory data) internal returns (uint256 eta) {
        vm.prank(admin);
        (, eta) = gov.queue(data);
    }

    function _execute(bytes memory data) internal {
        vm.prank(admin);
        gov.execute(data);
    }

    function test_handover_governorOwnsVault() public {
        assertEq(vault.owner(), address(gov));
        vm.prank(owner);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setRiskBounds(0, 5000);
    }

    /// @notice The long delay applies exactly to the floor setter and to ownership transfer; the selectors the governor
    ///         spells out are the vault's.
    function test_delayClasses_matchVaultSelectors() public view {
        assertEq(gov.delayFor(abi.encodeCall(vault.setInventoryBounds, (0, 0, 0, 0))), gov.LONG_DELAY());
        assertEq(gov.delayFor(abi.encodeCall(vault.transferOwnership, (address(1)))), gov.LONG_DELAY());
        assertEq(gov.delayFor(abi.encodeCall(vault.setRiskAdapter, (IMarketRiskAdapter(address(0))))), gov.DELAY());
        assertEq(gov.delayFor(abi.encodeCall(vault.setRiskBounds, (0, 0))), gov.DELAY());
        assertEq(gov.delayFor(abi.encodeCall(vault.setPaused, (false))), gov.DELAY());
    }

    /// @notice Not before eta, once inside [eta, eta + GRACE], never twice: replaying the same calldata needs a new
    ///         queue and a new delay.
    function test_delay_window_and_replay() public {
        bytes memory data = abi.encodeCall(vault.setRiskBounds, (0, 9000)); // loosens both
        uint256 eta = _queue(data);
        assertEq(eta, block.timestamp + gov.DELAY());
        bytes32 id = keccak256(data);

        vm.warp(eta - 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.NotExecutable.selector, id, eta));
        gov.execute(data);

        vm.warp(eta);
        vm.expectEmit(address(gov));
        emit VaultGovernor.Executed(id);
        _execute(data);
        assertEq(vault.maxUncertaintyPips(), 9000);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.NotQueued.selector, id));
        gov.execute(data);

        uint256 eta2 = _queue(data); // re-arming is a fresh, public delay
        assertEq(eta2, block.timestamp + gov.DELAY());
    }

    function test_expiry_afterGrace() public {
        bytes memory data = abi.encodeCall(vault.setRiskBounds, (0, 5000));
        uint256 eta = _queue(data);
        vm.warp(eta + gov.GRACE() + 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.NotExecutable.selector, keccak256(data), eta));
        gov.execute(data);
        vm.prank(admin);
        gov.cancel(data);
        assertEq(gov.eta(keccak256(data)), 0);
    }

    function test_longDelay_forFloorChange() public {
        bytes memory data = abi.encodeCall(vault.setInventoryBounds, (tau, tau, 100_000, 100_000));
        uint256 eta = _queue(data);
        assertEq(eta, block.timestamp + 32 days);
        vm.warp(block.timestamp + gov.DELAY());
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.NotExecutable.selector, keccak256(data), eta));
        gov.execute(data);
        vm.warp(eta);
        _execute(data);
        assertEq(vault.inventoryTolerancePips(0), 100_000);
    }

    /// @notice Admin and guardian may cancel; the guardian may not cancel its own replacement; nobody else may cancel.
    function test_cancel_roles() public {
        bytes memory loosen = abi.encodeCall(vault.setRiskBounds, (0, 9000));
        bytes memory replaceGuardian = abi.encodeCall(vault.setGuardian, (makeAddr("newGuardian")));
        _queue(loosen);
        _queue(replaceGuardian);

        vm.prank(attacker);
        vm.expectRevert(VaultGovernor.NotAllowedToCancel.selector);
        gov.cancel(loosen);

        vm.prank(guardian);
        vm.expectRevert(VaultGovernor.NotAllowedToCancel.selector);
        gov.cancel(replaceGuardian);

        vm.expectEmit(address(gov));
        emit VaultGovernor.Canceled(keccak256(loosen), guardian);
        vm.prank(guardian);
        gov.cancel(loosen);

        vm.prank(admin);
        gov.cancel(replaceGuardian);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.NotQueued.selector, keccak256(loosen)));
        gov.cancel(loosen);
    }

    /// @notice A change the vault rejects fails at execution with the vault's own error and stays queued, so it can be
    ///         inspected and canceled.
    function test_incorrectConfiguration_revertsAndStaysQueued() public {
        MockRiskAdapter swapped = new MockRiskAdapter(address(token1), address(token0), 18, 18, bytes32(0));
        bytes memory data = abi.encodeCall(vault.setRiskAdapter, (IMarketRiskAdapter(address(swapped))));
        uint256 eta = _queue(data);
        vm.warp(eta);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InvalidRiskAdapter.selector, address(swapped)));
        gov.execute(data);
        assertEq(gov.eta(keccak256(data)), eta, "still queued");
    }

    function test_onlyAdmin_queuesAndExecutes_noDuplicates() public {
        bytes memory data = abi.encodeCall(vault.setPaused, (false));
        vm.prank(attacker);
        vm.expectRevert(VaultGovernor.NotAdmin.selector);
        gov.queue(data);
        _queue(data);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.AlreadyQueued.selector, keccak256(data)));
        gov.queue(data);
        vm.warp(block.timestamp + gov.DELAY());
        vm.prank(attacker);
        vm.expectRevert(VaultGovernor.NotAdmin.selector);
        gov.execute(data);
        vm.prank(admin);
        vm.expectRevert(VaultGovernor.InvalidCall.selector);
        gov.queue(hex"aa");
    }

    /// @notice The guardian's emergency tightening on the vault is immediate while the governor owns it.
    function test_guardianTightening_isImmediate() public {
        vm.startPrank(guardian);
        vault.setSellHalted(c0, true);
        vault.setRiskBounds(200, 4000);
        vault.setInventoryBounds(tau, tau, 10_000, 10_000);
        vault.setPaused(true);
        vm.stopPrank();
        assertTrue(vault.paused());
        assertEq(vault.inventoryTolerancePips(1), 10_000);
    }

    /// @notice Why the floor delay exceeds MAX_HORIZON (Task 1, correction C3). An LP who asks to leave when a floor
    ///         loosening is announced may be queued behind a commitment that can last up to 30 days. With a 3-day
    ///         delay the change would apply while the LP is still queued (its shares bear the looser floor). With the
    ///         32-day delay the commitment expires first, anyone releases it, and the LP is finalized at the old floor.
    function test_queuedLp_finalizedBeforeFloorLoosening() public {
        // A curator reserves almost all asset0 for the full horizon.
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyA, c0, uint128(vault.backing(c0) * 99 / 100));
        r.expiry = uint64(block.timestamp + vault.MAX_HORIZON());
        vm.prank(curator);
        uint256 allocationId = auth.activateDirect(r);

        uint256 t0 = T0; // setUp warped here; a local copy of block.timestamp is re-read after vm.warp under via-IR
        assertEq(block.timestamp, t0);
        uint256 eta = _queue(abi.encodeCall(vault.setInventoryBounds, (0, 0, 50_000, 50_000)));
        (,,, uint256 rid) = _redeem(lp0, vault.sharesOf(lp0) / 2, true);
        assertGt(rid, 0, "queued");

        vm.warp(t0 + 3 days); // where a short delay would already let the loosening execute
        vault.processQueue(10);
        assertGt(vault.getRequest(rid).sharesPending, 0, "still queued at +3 days");

        vm.warp(t0 + vault.MAX_HORIZON());
        vault.release(allocationId); // anyone, once expired
        vault.processQueue(10);
        assertEq(vault.getRequest(rid).sharesPending, 0, "finalized before the change can apply");
        assertLt(block.timestamp, eta);

        vm.warp(eta);
        _execute(abi.encodeCall(vault.setInventoryBounds, (0, 0, 50_000, 50_000)));
        assertEq(vault.inventoryTargetPerShare(0), 0);
    }
}
