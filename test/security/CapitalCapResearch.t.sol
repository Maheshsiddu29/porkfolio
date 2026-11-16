// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {VaultGovernor} from "../../src/governance/VaultGovernor.sol";
import {BondEconomicGriefingTest} from "./BondEconomicGriefing.t.sol";

/// @notice F-8 counterexamples measured on the real bonded vault. The cap assertions are a research predicate,
///         not an installed deposit rule: an isolated production-profile prototype measures that rule separately.
contract CapitalCapResearchTest is BondEconomicGriefingTest {
    uint256 internal constant RAW_CAP = 250_000 ether;

    /// @notice A 250,000-unit post-deposit cap admits a 200,000-unit coalition when honest capital is only 1,000.
    ///         The coalition stays below the cap at every rotation yet holds a pending honest withdrawal and a
    ///         LONG_DELAY change. The cap limits absolute capital but does not imply a relative loss or delay bound.
    function test_f8_belowRawCap_stillBlocksHonestAndLongDelay() public {
        _redeem(lp0, 49_000 ether, false);
        uint256 honest = lens.netAssets(vault, c0);
        assertEq(honest, 1000 ether);
        VaultGovernor gov = new VaultGovernor(address(vault), admin, 3 days, 32 days, 7 days);
        vm.prank(owner);
        vault.transferOwnership(address(gov));
        vm.prank(admin);
        gov.acceptVaultOwnership();
        bytes memory change = abi.encodeCall(vault.setInventoryBounds, (tau, tau, 20_000, 20_000));
        vm.prank(admin);
        (, uint256 eta) = gov.queue(address(vault), change);

        uint256 rid = griefer.rotateWithCapital(9 days, 200_000 ether);
        uint256 n = lens.netAssets(vault, c0);
        uint256 q = lens.reserved(vault, c0);
        assertLe(n, RAW_CAP);
        assertGt(q, honest);
        (,,, uint256 honestRid) = _redeem(lp0, 999 ether, true);
        assertGt(honestRid, 0);
        uint256 honestQueuedAt = vm.getBlockTimestamp();
        uint256 honestDelay;
        for (uint256 i; i < 3; ++i) {
            vm.warp(vm.getBlockTimestamp() + 8 days);
            uint256 next = griefer.rotateWithCapital(9 days, 200_000 ether);
            assertEq(lens.getRequest(vault, rid).sharesPending, 0);
            if (i == 0) {
                assertEq(lens.getRequest(vault, honestRid).sharesPending, 0);
                honestDelay = vm.getBlockTimestamp() - honestQueuedAt;
            }
            assertLe(lens.netAssets(vault, c0), RAW_CAP);
            rid = next;
        }
        vm.warp(eta);
        uint256 pending = vault.pendingShares();
        assertGt(pending, 0);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.PendingWithdrawals.selector, pending));
        gov.execute(address(vault), change);
        console2.log("C04 F8 cap honest coalition net", honest, 200_000 ether, n);
        console2.log("C04 F8 cap reserved", q);
        console2.log("C04 F8 cap bond charge refund", griefer.totalBond(), griefer.totalCharge(), griefer.totalRefund());
        console2.log("C04 F8 cap LP rebate pending", griefer.selfRebate(), pending);
        console2.log("C04 F8 cap honest delay seconds", honestDelay);
    }

    /// @notice A per-transaction deposit limit is bypassed by two deposits from the same address; two LP identities
    ///         would work as well. No call individually exceeds 100,000 units, but the resulting reservation still
    ///         exceeds the honest backing and queues its withdrawal.
    function test_f8_singleDepositLimit_splitDepositsStillBlock() public {
        _redeem(lp0, 49_000 ether, false);
        griefer.depositCapital(100_000 ether);
        griefer.depositCapital(100_000 ether);
        assertLe(lens.netAssets(vault, c0), RAW_CAP);
        uint256 id = griefer.commitAll(9 days);
        uint256 q = lens.getAllocation(vault, id).maxOut;
        assertGt(q, 1000 ether);
        griefer.queueCapital(200_000 ether);
        (,,, uint256 honestRid) = _redeem(lp0, 999 ether, true);
        assertGt(honestRid, 0);
        console2.log("C04 F8 split deposits reserved honest queue", q, 1000 ether, honestRid);
    }

    /// @notice A per-call limit does not stop cooperating LP identities. Each mints 100,000 shares for at most
    ///         101,000 raw units per asset; the curator bonds against their combined room, the second LP queues,
    ///         and the honest LP also queues behind that same reservation.
    function test_f8_singleDepositLimit_twoLpIdentitiesStillBlock() public {
        _redeem(lp0, 49_000 ether, false);
        address lpA = makeAddr("coalitionA");
        address lpB = makeAddr("coalitionB");
        (uint256 a0, uint256 a1) = _depositShares(lpA, 100_000 ether);
        assertLe(a0, 101_000 ether);
        assertLe(a1, 101_000 ether);
        (a0, a1) = _depositShares(lpB, 100_000 ether);
        assertLe(a0, 101_000 ether);
        assertLe(a1, 101_000 ether);
        assertEq(lens.sharesOf(vault, lpA), 100_000 ether);
        assertEq(lens.sharesOf(vault, lpB), 100_000 ether);
        uint256 id = griefer.commitAll(9 days);
        assertGt(lens.getAllocation(vault, id).maxOut, 1000 ether);
        _redeem(lpA, 100_000 ether, true);
        _redeem(lpB, 100_000 ether, true);
        (,,, uint256 honestRid) = _redeem(lp0, 999 ether, true);
        assertGt(honestRid, 0);
    }

    /// @notice Honest backing, coalition size and curator ceiling change the amount that can be withheld. The
    ///         matrix logs refundable collateral and realized loss separately. It is a finite scenario set, not an
    ///         economic deterrence bound or a valuation of the temporary capital requirement.
    function test_f8_honestCapitalAndExposureMatrix() public {
        uint256[5] memory honestLevels = [uint256(50_000 ether), 10_000 ether, 1000 ether, 1000 ether, 1000 ether];
        uint256[5] memory capitalLevels =
            [uint256(200_000 ether), 1_000_000 ether, 200_000 ether, 200_000 ether, 1_000_000 ether];
        uint256[5] memory ceilings = [uint256(200_000 ether), 200_000 ether, 200_000 ether, 500 ether, 200_000 ether];
        for (uint256 i; i < honestLevels.length; ++i) {
            uint256 snap = vm.snapshotState();
            if (honestLevels[i] < 50_000 ether) _redeem(lp0, 50_000 ether - honestLevels[i], false);
            vm.prank(owner);
            vault.setCuratorCeiling(address(griefer), c0, ceilings[i]);
            uint256 beforeGas = gasleft();
            griefer.depositCapital(capitalLevels[i]);
            uint256 id = griefer.commitAll(1 days);
            uint256 gasUsed = beforeGas - gasleft();
            uint256 net = lens.netAssets(vault, c0);
            uint256 q = lens.getAllocation(vault, id).maxOut;
            uint256 posted = escrow.getBond(id).bond;
            uint256 shareFractionPips = griefer.coalitionShares() * 1_000_000 / lens.totalShares(vault);
            vm.warp(vm.getBlockTimestamp() + 12 hours);
            griefer.closeAndSettle();
            uint256 charge = griefer.totalCharge();
            uint256 refund = griefer.totalRefund();
            (uint256 lpPart,) = escrow.unrealized(c0);
            uint256 rebate = lpPart * griefer.coalitionShares() / lens.totalShares(vault);
            assertEq(posted, charge + refund);
            assertLe(rebate, charge);
            console2.log("C04 F8 matrix honest capital net", honestLevels[i], capitalLevels[i], net);
            console2.log("C04 F8 matrix q ceiling sharePips", q, ceilings[i], shareFractionPips);
            console2.log("C04 F8 matrix bond charge refund", posted, charge, refund);
            console2.log("C04 F8 matrix rebate gas", rebate, gasUsed);
            vm.revertToState(snap);
        }
    }
}
