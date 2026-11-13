// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {MockYieldVault, InKindYieldLedger, BookValueLedger} from "./IdleYieldModel.sol";

/// @notice Checks of the PROPOSED idle-yield accounting (FUTURE_CAPITAL_AND_YIELD_ACCOUNTING.md §3) on test-only
///         models. `src/` has no yield adapter; nothing here describes current behaviour.
/// @dev Shared setup for examples E and F: one asset, 1,000,000 units seeded against 1,000,000 shares; hooks have
///      reserved Q = 300,000; buffer floor R = 50,000; liquidity buffer K = 100,000; so 550,000 may be deployed.
contract IdleYieldModelTest is Test {
    MockERC20 internal token;
    MockYieldVault internal ext;
    InKindYieldLedger internal ledger;

    address internal lp0 = makeAddr("lp0");
    address internal lpNew = makeAddr("lpNew");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        token = new MockERC20("Asset", "A", 18);
        ext = new MockYieldVault(ERC20(address(token)));
        ledger = new InKindYieldLedger(token, ext, 50_000, 100_000);
        _fund(lp0, 1_000_000);
        vm.prank(lp0);
        ledger.seed(1_000_000, lp0);
        ledger.reserve(300_000);
    }

    function _fund(address who, uint256 amount) internal {
        token.mint(who, amount);
        vm.prank(who);
        token.approve(address(ledger), type(uint256).max);
    }

    function _deployHalf() internal {
        assertEq(ledger.deployable(), 550_000);
        ledger.deploy(500_000, 0);
        assertEq(ledger.B(), 500_000);
        assertEq(ledger.Z(), 500_000);
    }

    /// @notice Deployment and reservation limits are on physical assets only. With 500,000 in the strategy, new
    ///         reservations are limited to N - Q - R = 150,000, not to the 650,000 the total value would suggest, and
    ///         queued shares take their claim D out of both limits.
    function test_admission_physicalOnly() public {
        _deployHalf();
        assertEq(ledger.admissible(), 150_000);
        assertEq(ledger.deployable(), 50_000);
        vm.expectRevert(abi.encodeWithSelector(InKindYieldLedger.ExceedsDeployable.selector, 50_001, 50_000));
        ledger.deploy(50_001, 0);

        ledger.queueShares(100_000); // D = ceil(100,000 * 500,000 / 1,000,000) = 50,000
        assertEq(ledger.pendingDemand(), 50_000);
        assertEq(ledger.admissible(), 100_000);
        assertEq(ledger.deployable(), 0);
        vm.expectRevert(abi.encodeWithSelector(InKindYieldLedger.ExceedsAdmissible.selector, 100_001, 100_000));
        ledger.reserve(100_001);
    }

    /// @notice Example E: the strategy earns 10%. A new LP pays for the yield already earned (1.05 per share) and an
    ///         exiting LP receives it (external shares worth 1.05 per share), with no price read anywhere.
    function test_exampleE_positiveYield() public {
        _deployHalf();
        token.mint(address(ext), 50_000); // +10% on 500,000

        _fund(lpNew, 200_000);
        vm.prank(lpNew);
        (uint256 physical, uint256 forExternal) = ledger.deposit(100_000, lpNew);
        assertEq(physical, 50_000);
        assertEq(forExternal, 55_000, "previewMint(50,000 shares) at 1.1 assets per share");
        assertEq(ledger.S(), 1_100_000);

        (uint256 out, uint256 z) = ledger.redeem(100_000, lp0);
        assertEq(out, 50_000);
        assertEq(z, 50_000);
        assertEq(ext.previewRedeem(z), 55_000);
        assertEq(ext.balanceOf(lp0), 50_000, "external shares delivered in kind");
    }

    /// @notice Example F: the strategy loses 20%, then pauses. Exits keep working and bear exactly their pro-rata
    ///         loss; recalls and deposits stop; the remaining shares' basket per share does not change.
    function test_exampleF_lossAndPause() public {
        _deployHalf();
        token.burn(address(ext), 100_000); // the strategy's 500,000 is now worth 400,000
        ext.setPaused(true);

        vm.expectRevert(bytes("PAUSED"));
        ledger.recall(1, 0);
        _fund(lpNew, 200_000);
        vm.prank(lpNew);
        vm.expectRevert(bytes("PAUSED"));
        ledger.deposit(1000, lpNew);

        (uint256 out, uint256 z) = ledger.redeem(200_000, lp0);
        assertEq(out, 100_000);
        assertEq(z, 100_000);
        assertEq(ext.convertToAssets(z), 80_000, "0.9 per share: exactly the pro-rata loss");
        // Remaining 800,000 shares: 400,000 physical and 400,000 external shares, 0.5 + 0.5 per share as before.
        assertEq(ledger.net() * 1_000_000, 500_000 * ledger.S());
        assertEq(ledger.Z() * 1_000_000, 500_000 * ledger.S());
    }

    /// @notice A recall is limited by the strategy's liquidity and pays its withdrawal fee. The fee is a realized loss
    ///         that every share bears through N; `minAssets` bounds it.
    function test_recall_illiquidityAndFee() public {
        _deployHalf();
        ext.setLiquidity(10_000);
        ext.setFeeBps(100); // 1%
        vm.expectRevert(bytes("ILLIQUID"));
        ledger.recall(10_001, 0);
        vm.expectRevert(abi.encodeWithSelector(InKindYieldLedger.RecallBelowMinimum.selector, 9900, 10_000));
        ledger.recall(10_000, 10_000);
        uint256 assets = ledger.recall(10_000, 9900);
        assertEq(assets, 9900);
        assertEq(ledger.B(), 509_900);
        assertEq(ledger.Z(), 490_000);
    }

    /// @notice External shares sent straight to the ledger are not counted, as donated ERC-6909 claims are not counted
    ///         by the vault.
    function test_donatedExternalShares_notCounted() public {
        _deployHalf();
        token.mint(attacker, 1000);
        vm.startPrank(attacker);
        token.approve(address(ext), 1000);
        ext.deposit(1000, address(ledger));
        vm.stopPrank();
        assertEq(ext.balanceOf(address(ledger)), 501_000);
        assertEq(ledger.Z(), 500_000);
    }

    /// @notice First deposit into a fresh strategy whose share price an attacker inflated by donation. Without a value
    ///         check the ledger keeps 1 share worth 1,250,000 for 1,500,000 deposited; the value check refuses it.
    function test_inflationAttack_onDeployment() public {
        MockERC20 t = new MockERC20("Asset", "A", 18);
        MockYieldVault fresh = new MockYieldVault(ERC20(address(t)));
        t.mint(attacker, 1_000_001);
        vm.startPrank(attacker);
        t.approve(address(fresh), type(uint256).max);
        fresh.deposit(1, attacker); // 1 share
        t.transfer(address(fresh), 1_000_000); // donation: 1 share now redeems for 1,000,001
        vm.stopPrank();

        for (uint256 checked; checked < 2; ++checked) {
            uint256 snap = vm.snapshotState();
            InKindYieldLedger l = new InKindYieldLedger(t, fresh, 0, 0);
            t.mint(address(this), 3_000_000);
            t.approve(address(l), type(uint256).max);
            l.seed(3_000_000, address(this));
            if (checked == 1) {
                vm.expectRevert(
                    abi.encodeWithSelector(InKindYieldLedger.ValueCheckFailed.selector, 1_250_000, 1_500_000)
                );
                l.deploy(1_500_000, 100);
            } else {
                assertEq(l.deploy(1_500_000, 10_000), 1, "one share for 1,500,000");
                assertEq(fresh.previewRedeem(1), 1_250_000, "250,000 lost to the attacker's share");
            }
            vm.revertToState(snap);
        }
    }

    /// @notice Why the alternative (book value, physical exits) needs a fresh impairment check in every exit path.
    ///         After a 20% loss nobody has recorded, an LP holding 40% exits at the stale book value and takes
    ///         400,000 instead of its fair 360,000; the remaining LPs absorb the 40,000 difference.
    function test_bookValue_staleExitTransfersLoss() public {
        for (uint256 poked; poked < 2; ++poked) {
            uint256 snap = vm.snapshotState();
            BookValueLedger b = new BookValueLedger(token, ext);
            token.mint(address(this), 1_000_000);
            token.approve(address(b), type(uint256).max);
            b.seed(1_000_000, address(this));
            b.deploy(500_000);
            token.burn(address(ext), 100_000);
            if (poked == 1) b.poke();
            uint256 paid = b.redeem(400_000, lp0);
            assertEq(paid, poked == 1 ? 360_000 : 400_000);
            vm.revertToState(snap);
        }
    }

    /// @notice No LP operation lowers either part of the per-share basket (physical N / S and Z / S), whatever the
    ///         strategy's share price, and an immediate round trip never gains.
    function testFuzz_inKind_noDilutionAndNoRoundTripGain(uint256 gain, uint256 loss, uint256 s) public {
        _deployHalf();
        gain = bound(gain, 0, 2_000_000);
        loss = bound(loss, 0, 499_999);
        s = bound(s, 1, 2_000_000);
        if (gain != 0) token.mint(address(ext), gain);
        if (loss != 0) token.burn(address(ext), loss);

        uint256 n = ledger.net();
        uint256 zz = ledger.Z();
        uint256 supply = ledger.S();
        _fund(lpNew, 100_000_000);
        uint256 before = token.balanceOf(lpNew);
        vm.prank(lpNew);
        ledger.deposit(s, lpNew);
        uint256 paid = before - token.balanceOf(lpNew);
        assertGe(ledger.net() * supply, n * ledger.S(), "physical per share fell on deposit");
        assertGe(ledger.Z() * supply, zz * ledger.S(), "external per share fell on deposit");

        (uint256 out, uint256 z) = ledger.redeem(s, lpNew);
        assertGe(ledger.net() * supply, n * ledger.S(), "physical per share fell on redeem");
        assertGe(ledger.Z() * supply, zz * ledger.S(), "external per share fell on redeem");
        assertGe(paid, out + ext.convertToAssets(z), "round trip gained");
    }
}
