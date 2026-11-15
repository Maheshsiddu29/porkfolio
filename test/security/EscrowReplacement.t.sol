// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {BondEscrow} from "../../src/BondEscrow.sol";
import {CommitmentAuthorizer} from "../../src/CommitmentAuthorizer.sol";
import {VaultGovernor} from "../../src/governance/VaultGovernor.sol";
import {IBondEscrow} from "../../src/interfaces/IBondEscrow.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {BondTestBase} from "../utils/BondTestBase.sol";

/// @notice Exercises the G05 escrow handoff on the production vault and real PoolManager. A retired escrow keeps
///         custody of refunds and protocol fees; the procedure must drain its LP fees before the vault changes the
///         sole address allowed to call `realizeFee`.
contract EscrowReplacementTest is BondTestBase {
    uint256 internal t0;

    function setUp() public override {
        super.setUp();
        t0 = _hourAligned(vm.getBlockTimestamp()) + 1 hours;
        vm.warp(t0);
    }

    /// @notice A failed bounded realization is a reason to wait, not a successful drain. After permissionless
    ///         catch-up and the last expiry, both assets have no open bond or unpaid LP fee. Pending payer refunds
    ///         and protocol fees remain claimable from the old escrow after replacement, including when asset0 has
    ///         held no bond at all. A new module can then resume bonded activation through the new escrow.
    function test_safeHandoff_drainsLpFees_preservesRefundAndProtocolClaims() public {
        address admin = makeAddr("replacementAdmin");
        VaultGovernor gov = new VaultGovernor(address(vault), admin, 3 days, 32 days, 7 days);
        vm.startPrank(owner);
        vault.setGuardian(guardian);
        vault.transferOwnership(address(gov));
        vm.stopPrank();
        vm.prank(admin);
        gov.acceptVaultOwnership();

        uint256 live = _allocateUntil(keyS, c1, 100_000 ether, uint64(t0 + 10 days));
        uint256 early = _allocateUntil(keyS, c1, 100_000 ether, uint64(t0 + 10 days));
        vm.warp(t0 + 1 days);
        vm.prank(curator);
        vault.cancelAllocation(early);
        escrow.sync(early);
        (uint256 earlyCharge, uint256 earlyRefund) = escrow.settle(early);
        assertEq(earlyCharge, 8.64 ether);
        assertEq(earlyRefund, 77.76 ether);

        vm.prank(guardian);
        vault.setAuthModule(address(0));
        ISharedCommitmentVault.AllocationRequest memory refused = _request(keyS, c1, 100 ether);
        refused.deadline = uint64(vm.getBlockTimestamp());
        refused.expiry = _hourAligned(vm.getBlockTimestamp() + 1 days);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NotAuthModule.selector, address(bonded)));
        bonded.activateDirectBonded(refused, RHO);

        vm.warp(t0 + 3 days);
        vm.expectRevert(abi.encodeWithSelector(IBondEscrow.EscrowBehind.selector, c1));
        escrow.realize();
        assertEq(lens.feeEscrow(vault), address(escrow), "failed realization must not be treated as a drained escrow");
        assertFalse(escrow.realize(32));
        assertTrue(escrow.realize(32));

        vm.warp(t0 + 10 days);
        (uint256 finalCharge, uint256 finalRefund) = escrow.settle(live);
        assertEq(finalCharge, 86.4 ether);
        assertEq(finalRefund, 0);
        escrow.realize(type(uint256).max);
        _assertDrained(c0);
        _assertDrained(c1);
        IBondEscrow.Ledger memory oldLedger = escrow.getLedger(c1);
        assertEq(oldLedger.refundsOwed, earlyRefund);
        assertEq(oldLedger.protocolOwed, (earlyCharge + finalCharge) / 10);
        assertEq(_claims(address(escrow), c1), oldLedger.refundsOwed + oldLedger.protocolOwed);
        assertEq(_claims(address(escrow), c0), 0);

        BondEscrow nextEscrow = _deployEscrow(vault, RHO, RHO, T_MIN, PROTOCOL_BPS, protocol);
        CommitmentAuthorizer nextModule = _deployBonded(vault, nextEscrow);
        bytes memory installEscrow = abi.encodeCall(vault.setFeeEscrow, (address(nextEscrow)));
        bytes memory installModule = abi.encodeCall(vault.setAuthModule, (address(nextModule)));
        vm.prank(admin);
        (, uint256 eta) = gov.queue(address(vault), installEscrow);
        vm.prank(admin);
        gov.queue(address(vault), installModule);
        bytes32 operationId = gov.operationId(address(vault), installEscrow);
        vm.warp(eta - 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.NotExecutable.selector, operationId, eta));
        gov.execute(address(vault), installEscrow);
        vm.warp(eta);
        _assertDrained(c0);
        _assertDrained(c1);
        vm.prank(admin);
        gov.execute(address(vault), installEscrow);
        vm.prank(admin);
        gov.execute(address(vault), installModule);
        _assertDrained(c0);
        _assertDrained(c1);

        address payee = makeAddr("oldEscrowPayee");
        vm.prank(curator);
        (, uint256 refundPaid) = escrow.claimRefund(payee);
        vm.prank(protocol);
        (, uint256 protocolPaid) = escrow.claimProtocol(payee);
        assertEq(refundPaid, oldLedger.refundsOwed);
        assertEq(protocolPaid, oldLedger.protocolOwed);
        assertEq(token1.balanceOf(payee), refundPaid + protocolPaid);
        assertEq(_claims(address(escrow), c0), 0);
        assertEq(_claims(address(escrow), c1), 0);

        vm.prank(curator);
        token1.approve(address(nextEscrow), type(uint256).max);
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyS, c1, 100 ether);
        req.deadline = uint64(vm.getBlockTimestamp());
        req.expiry = _hourAligned(vm.getBlockTimestamp() + 1 days);
        vm.prank(curator);
        uint256 newId = nextModule.activateDirectBonded(req, RHO);
        assertGt(nextEscrow.getBond(newId).bond, 0);
    }

    /// @notice With neither asset ever bonded, both ledgers and both claim balances are zero. Replacing the escrow
    ///         does not require a fabricated settlement or transfer, and the old escrow has no LP fee to strand.
    function test_safeHandoff_zeroBalances() public {
        vm.prank(guardian);
        vault.setAuthModule(address(0));
        escrow.realize(type(uint256).max);
        _assertDrained(c0);
        _assertDrained(c1);
        assertEq(_claims(address(escrow), c0), 0);
        assertEq(_claims(address(escrow), c1), 0);

        BondEscrow nextEscrow = _deployEscrow(vault, RHO, RHO, T_MIN, PROTOCOL_BPS, protocol);
        vm.prank(owner);
        vault.setFeeEscrow(address(nextEscrow));
        assertEq(lens.feeEscrow(vault), address(nextEscrow));
        assertEq(_claims(address(escrow), c0), 0);
        assertEq(_claims(address(escrow), c1), 0);
    }

    /// @dev The handoff checks both the absence of open collateral and the absence of earned but unpaid LP fees.
    ///      Refund and protocol liabilities may remain: their owners can claim them from a retired escrow.
    function _assertDrained(Currency currency) internal view {
        IBondEscrow.Ledger memory ledger = escrow.getLedger(currency);
        (uint256 lpPart,) = escrow.unrealized(currency);
        assertEq(ledger.openBonds, 0, "open bond remains");
        assertEq(ledger.accrued, 0, "unsettled accrual remains");
        assertEq(lpPart, 0, "LP fee remains unpaid");
        assertEq(ledger.realized, ledger.settledCharges, "not all earned fees were realized");
    }
}
