// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {VaultStateReader} from "../../src/libraries/VaultStateReader.sol";

using VaultStateReader for SharedCommitmentVault;

/// @notice Multi-LP ownership, deposits and two-tier redemption, interleaved with real swaps through both hooks
///         on the real PoolManager.
contract MultiLpAccountingTest is VaultTestBase {
    address internal lpA = makeAddr("lpA");
    address internal lpB = makeAddr("lpB");
    address internal lpC = makeAddr("lpC");

    function setUp() public override {
        super.setUp();
        vm.startPrank(owner);
        vault.setCuratorCeiling(curator, c0, type(uint256).max);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        vm.stopPrank();
        // Swaps here move hundreds of thousands of tokens to shift LP baskets; pricing is tested elsewhere.
        _deepenHookB();
    }

    // ------------------------------------------------------------------
    // Executable demonstration
    // ------------------------------------------------------------------

    /// @notice Three LPs, swaps through both hooks between deposits and redemptions, then a full exit.
    ///         Every LP is paid exactly floor(shares * N_a / S) of each asset at the time its shares leave,
    ///         every depositor paid ceil(shares * N_a / S); nothing is created or lost (ghost totals below).
    function test_demo_threeLps_interleavedSwapsDepositsRedemptions() public {
        uint256 in0 = VAULT_FUNDING;
        uint256 in1 = VAULT_FUNDING;
        uint256 out0;
        uint256 out1;

        // lpA joins at the initial 1:1 basket.
        (uint256 a0, uint256 a1) = _depositShares(lpA, 500_000 ether);
        assertEq(a0, 500_000 ether);
        assertEq(a1, 500_000 ether);
        in0 += a0;
        in1 += a1;

        // Curator commits capacity to both hooks; traders swap in both directions.
        uint256 idA = _allocate(keyA, c1, 200_000 ether); // hookA sells token1
        uint256 idB = _allocate(keyB, c0, 200_000 ether); // hookB sells token0
        _swap(keyA, true, 100_000 ether, idA);
        _swap(keyB, false, 50_000 ether, idB);
        in0 += 100_000 ether;
        in1 += 50_000 ether;
        out1 += vault.getAllocation(idA).consumed;
        out0 += vault.getAllocation(idB).consumed;
        _logState("after swaps");

        // lpB joins after the trades at the new composition, paying ceil(shares * N_a / S).
        uint256 S = vault.totalShares();
        uint256 n0 = lens.netAssets(vault, c0);
        uint256 n1 = lens.netAssets(vault, c1);
        (a0, a1) = _depositShares(lpB, 250_000 ether);
        assertEq(a0, FullMath.mulDivRoundingUp(250_000 ether, n0, S));
        assertEq(a1, FullMath.mulDivRoundingUp(250_000 ether, n1, S));
        in0 += a0;
        in1 += a1;

        // lpA partially exits instantly at floor(shares * N_a / S).
        S = vault.totalShares();
        n0 = lens.netAssets(vault, c0);
        n1 = lens.netAssets(vault, c1);
        (uint256 instant, uint256 r0, uint256 r1,) = _redeem(lpA, 200_000 ether, false);
        assertEq(instant, 200_000 ether);
        assertEq(r0, FullMath.mulDiv(200_000 ether, n0, S));
        assertEq(r1, FullMath.mulDiv(200_000 ether, n1, S));
        out0 += r0;
        out1 += r1;

        // Same per-share basket for every holder: proportional treatment.
        _assertProportional(lp0);
        _assertProportional(lpA);
        _assertProportional(lpB);

        // Everyone exits after the commitments expire and are released.
        vm.warp(block.timestamp + 1 days);
        vault.release(idA);
        vault.release(idB);
        address[3] memory lps = [lp0, lpA, lpB];
        for (uint256 i; i < 3; ++i) {
            (, r0, r1,) = _redeem(lps[i], vault.sharesOf(lps[i]), false);
            out0 += r0;
            out1 += r1;
            console2.log("exit", i, r0, r1);
        }
        _logState("after full exit");

        // Conservation: what remains is exactly in - out, and it backs only the locked MIN_SHARES.
        assertEq(vault.totalShares(), vault.MIN_SHARES());
        assertEq(vault.backing(c0), in0 - out0);
        assertEq(vault.backing(c1), in1 - out1);
        _assertAccountingConsistent();
    }

    // ------------------------------------------------------------------
    // Deposits: no dilution, no free round trip
    // ------------------------------------------------------------------

    function test_depositAfterTrades_doesNotDiluteExistingHolders() public {
        uint256 id = _allocate(keyA, c1, 300_000 ether);
        _swap(keyA, true, 200_000 ether, id);

        (uint256 before0, uint256 before1) = lens.previewRedeem(vault, vault.sharesOf(lp0));
        _depositShares(lpA, 777_777 ether + 13);
        (uint256 after0, uint256 after1) = lens.previewRedeem(vault, vault.sharesOf(lp0));
        assertGe(after0, before0, "lp0 token0 claim diluted");
        assertGe(after1, before1, "lp0 token1 claim diluted");
    }

    /// @notice Depositing and immediately redeeming the same shares never returns more than was paid.
    function testFuzz_depositRedeemRoundTrip_neverProfitable(uint256 shares, uint256 swapIn, bool zeroForOne) public {
        shares = bound(shares, 1, 5_000_000 ether);
        swapIn = bound(swapIn, 0, 400_000 ether);
        if (swapIn > 1e9) {
            uint256 id = _allocate(zeroForOne ? keyA : keyB, zeroForOne ? c1 : c0, 500_000 ether);
            _swap(zeroForOne ? keyA : keyB, zeroForOne, swapIn, id);
        }
        (uint256 paid0, uint256 paid1) = _depositShares(lpA, shares);
        (uint256 instant, uint256 got0, uint256 got1,) = _redeem(lpA, shares, true);
        assertEq(instant, shares, "free inventory covers the depositor's own basket");
        assertLe(got0, paid0);
        assertLe(got1, paid1);
        assertLe(paid0 - got0, 1, "rounding loss > 1 wei");
        assertLe(paid1 - got1, 1, "rounding loss > 1 wei");
        _assertAccountingConsistent();
    }

    function test_partialThenFullRedemption() public {
        _depositShares(lpA, 100_000 ether);
        (uint256 i1, uint256 x0, uint256 x1,) = _redeem(lpA, 40_000 ether, false);
        (uint256 i2, uint256 y0, uint256 y1,) = _redeem(lpA, 60_000 ether, false);
        assertEq(i1 + i2, 100_000 ether);
        assertEq(vault.sharesOf(lpA), 0);
        assertEq(x0 + y0, 100_000 ether);
        assertEq(x1 + y1, 100_000 ether);
        assertEq(token0.balanceOf(lpA), 100_000 ether);
        vm.prank(lpA);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientShares.selector, 1, 0));
        vault.redeem(1, 0, 0, lpA, true);
    }

    // ------------------------------------------------------------------
    // Queue under active commitments
    // ------------------------------------------------------------------

    /// @notice Queued redemption while 90% of token1 is committed. Pending demand is protected from new
    ///         allocations; after expiry + release the queue finalizes and pays in kind.
    function test_queuedRedemptionDuringActiveCommitments() public {
        _depositShares(lpA, 1_000_000 ether); // S = 2M, N = 2M / 2M
        uint256 id = _allocate(keyA, c1, 1_800_000 ether); // F1 = 200k

        (uint256 instant, uint256 r0, uint256 r1, uint256 req) = _redeem(lpA, 1_000_000 ether, true);
        assertEq(instant, 200_000 ether, "F1 / N1 * S");
        assertEq(r0, 200_000 ether);
        assertEq(r1, 200_000 ether);
        assertEq(vault.pendingShares(), 800_000 ether);
        assertEq(uint8(lens.requestStatus(vault, req)), uint8(ISharedCommitmentVault.RequestStatus.Pending));

        // Nothing is free in token1, and pending demand (800k token0) now blocks token0 allocations beyond
        // N0 - D0 = 1.8M - 800k.
        assertEq(lens.pendingDemand(vault, c0), 800_000 ether);
        assertEq(vault.admissibleCapacity(c0), 1_000_000 ether);
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyB, c0, 1_000_000 ether + 1);
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.InsufficientBacking.selector, 1_000_000 ether + 1, 1_000_000 ether
            )
        );
        auth.activateDirect(r);
        assertEq(vault.processQueue(10), 0, "no token1 inventory yet");

        // Commitment partly consumed, then expires and is released.
        _swap(keyA, true, 300_000 ether, id);
        uint256 sold = vault.getAllocation(id).consumed;
        vm.warp(vault.getAllocation(id).expiry);
        vault.release(id);

        uint256 S = vault.totalShares();
        uint256 n0 = lens.netAssets(vault, c0);
        uint256 n1 = lens.netAssets(vault, c1);
        assertEq(vault.processQueue(10), 800_000 ether);
        assertEq(uint8(lens.requestStatus(vault, req)), uint8(ISharedCommitmentVault.RequestStatus.Claimable));
        ISharedCommitmentVault.WithdrawalRequest memory w = vault.getRequest(req);
        assertEq(w.claimable0, FullMath.mulDiv(800_000 ether, n0, S));
        assertEq(w.claimable1, FullMath.mulDiv(800_000 ether, n1, S));
        // The pending shares shared the trade: more token0, less token1 than a pre-trade exit.
        assertGt(w.claimable0, 800_000 ether);
        assertLt(w.claimable1, 800_000 ether);
        assertGt(sold, 0);

        vm.prank(lpA);
        (uint256 c0Out, uint256 c1Out) = vault.claim(req);
        assertEq(c0Out, w.claimable0);
        assertEq(c1Out, w.claimable1);
        assertEq(uint8(lens.requestStatus(vault, req)), uint8(ISharedCommitmentVault.RequestStatus.Completed));
        _assertAccountingConsistent();
    }

    /// @notice Competing requests are served strictly FIFO with partial head fills; a later instant redeemer
    ///         cannot jump the queue; equal requests finalized in one call receive identical baskets.
    function test_fifoFairness_competingRequests() public {
        _depositShares(lpA, 300_000 ether);
        _depositShares(lpB, 300_000 ether);
        _depositShares(lpC, 300_000 ether); // S = 1.9M
        uint256 id1 = _allocate(keyA, c1, 1_000_000 ether);
        uint256 id2 = _allocate(keyB, c1, 900_000 ether); // F1 = 0

        (uint256 iA,,, uint256 reqA) = _redeem(lpA, 300_000 ether, true);
        (uint256 iB,,, uint256 reqB) = _redeem(lpB, 300_000 ether, true);
        (uint256 iC,,, uint256 reqC) = _redeem(lpC, 300_000 ether, true);
        assertEq(iA + iB + iC, 0);

        // Owner emergency-releases the smaller commitment: 900k token1 freed, exactly A + B + C, nothing for later.
        vm.prank(owner);
        vault.release(id2);
        // lp0 tries to exit instantly while others wait: fully queued instead (no queue jumping).
        (uint256 i0,,, uint256 req0) = _redeem(lp0, 100_000 ether, true);
        assertEq(i0, 0);
        vm.prank(lp0);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientLiquidity.selector, 1, 0));
        vault.redeem(1, 0, 0, lp0, false);

        vault.processQueue(10);
        ISharedCommitmentVault.WithdrawalRequest memory a = vault.getRequest(reqA);
        ISharedCommitmentVault.WithdrawalRequest memory b = vault.getRequest(reqB);
        ISharedCommitmentVault.WithdrawalRequest memory c = vault.getRequest(reqC);
        assertEq(a.sharesPending, 0);
        assertEq(b.sharesPending, 0);
        assertEq(a.claimable0, b.claimable0, "equal requests, equal basket");
        assertEq(a.claimable1, b.claimable1, "equal requests, equal basket");
        assertEq(c.sharesPending + c.claimable1, 300_000 ether, "C partially filled with the remaining 300k");
        assertEq(c.claimable1, 300_000 ether);
        assertEq(c.sharesPending, 0);
        assertEq(vault.getRequest(req0).sharesPending, 100_000 ether, "lp0 behind C, untouched");
        assertEq(lens.freeInventory(vault, c1), 0);
        assertEq(vault.queueHead(), req0);

        // Remaining commitment expires; lp0's request completes last.
        vm.warp(vault.getAllocation(id1).expiry);
        vault.release(id1);
        vault.processQueue(10);
        assertEq(vault.pendingShares(), 0);
        address[4] memory who = [lpA, lpB, lpC, lp0];
        uint256[4] memory ids = [reqA, reqB, reqC, req0];
        for (uint256 i; i < 4; ++i) {
            vm.prank(who[i]);
            vault.claim(ids[i]);
        }
        _assertAccountingConsistent();
    }

    /// @notice Partial head fill: the head request is drained progressively as pre-existing commitments are
    ///         released; the finalized part can be claimed while the rest is still pending.
    function test_partialHeadFill_acrossReleases() public {
        _depositShares(lpA, 1_000_000 ether); // S = 2M
        uint256 id1 = _allocate(keyA, c1, 400_000 ether);
        uint256 id2 = _allocate(keyB, c1, 1_600_000 ether); // F1 = 0
        (uint256 instant,,, uint256 req) = _redeem(lpA, 1_000_000 ether, true);
        assertEq(instant, 0);

        vm.prank(owner);
        vault.release(id1); // F1 = 400k
        assertEq(vault.processQueue(10), 400_000 ether);
        assertEq(vault.getRequest(req).sharesPending, 600_000 ether);
        assertEq(uint8(lens.requestStatus(vault, req)), uint8(ISharedCommitmentVault.RequestStatus.Pending));
        assertEq(vault.queueHead(), req, "head stays on a partially filled request");

        vm.prank(lpA);
        (uint256 g0, uint256 g1) = vault.claim(req); // claim the finalized slice early
        assertEq(g0, 400_000 ether);
        assertEq(g1, 400_000 ether);

        vm.prank(owner);
        vault.release(id2);
        assertEq(vault.processQueue(10), 600_000 ether);
        assertEq(uint8(lens.requestStatus(vault, req)), uint8(ISharedCommitmentVault.RequestStatus.Claimable));
        vm.prank(lpA);
        (g0, g1) = vault.claim(req);
        assertEq(g0, 600_000 ether);
        assertEq(g1, 600_000 ether);
        assertEq(token1.balanceOf(lpA), 1_000_000 ether);
        _assertAccountingConsistent();
    }

    /// @notice Escrowed shares keep their economic exposure: a queued LP and an identical LP who did not queue
    ///         end with the same per-share basket.
    function test_pendingSharesKeepPnL_sameAsHolding() public {
        _depositShares(lpA, 400_000 ether);
        _depositShares(lpB, 400_000 ether);
        uint256 id = _allocate(keyA, c1, 1_800_000 ether);
        (uint256 instant,,, uint256 req) = _redeem(lpA, 400_000 ether, true);
        assertEq(instant, 0, "F1 == 0");
        _swap(keyA, true, 500_000 ether, id); // trades while A is queued
        vm.warp(vault.getAllocation(id).expiry);
        vault.release(id);
        vault.processQueue(1);
        ISharedCommitmentVault.WithdrawalRequest memory w = vault.getRequest(req);
        (uint256 b0, uint256 b1) = lens.previewRedeem(vault, vault.sharesOf(lpB));
        // A's shares left the supply, so B's preview uses a slightly different S; floor rounding differs by <= 1.
        assertApproxEqAbs(w.claimable0, b0, 1);
        assertApproxEqAbs(w.claimable1, b1, 1);
    }

    /// @notice Adverse inventory: hooks sell almost all token1. Nobody can redeem token1 that is not there;
    ///         every holder's basket shifts the same way; deposits are priced at the new composition.
    function test_adverseInventory_assetNearlyDrained() public {
        uint256 id = _allocate(keyA, c1, uint128(VAULT_FUNDING));
        _swap(keyA, true, 1_000_000 ether, id); // ~99.5% of token1 sold
        uint256 left1 = lens.netAssets(vault, c1);
        assertLt(left1, VAULT_FUNDING / 100);

        (uint256 p0, uint256 p1) = lens.previewDeposit(vault, 1_000_000 ether);
        assertGt(p0, 1_990_000 ether);
        assertEq(p1, FullMath.mulDivRoundingUp(1_000_000 ether, left1, vault.totalShares()));

        // Free token1 is exactly what the allocation did not sell; the full exit must wait for release.
        (uint256 instant,,,) = _redeem(lp0, vault.sharesOf(lp0), true);
        assertEq(instant, 0, "remaining token1 is still reserved");
        vm.warp(vault.getAllocation(id).expiry);
        vault.release(id);
        vault.processQueue(1);
        vm.prank(lp0);
        (uint256 got0, uint256 got1) = vault.claim(1);
        assertGt(got0, 1_990_000 ether);
        assertLt(got1, VAULT_FUNDING / 100);
        _assertAccountingConsistent();
    }

    // ------------------------------------------------------------------
    // Cancellation and status machine
    // ------------------------------------------------------------------

    function test_cancel_returnsPendingShares_statusTransitions() public {
        _depositShares(lpA, 500_000 ether); // S = 1.5M
        _allocate(keyA, c1, 1_100_000 ether);
        uint256 id2 = _allocate(keyB, c1, 400_000 ether); // F1 = 0
        (uint256 instant,,, uint256 req) = _redeem(lpA, 500_000 ether, true);
        assertEq(instant, 0);
        assertEq(vault.sharesOf(lpA), 0);

        // Partial finalization: a pre-existing commitment is released, freeing 400k of the 500k needed.
        vm.prank(owner);
        vault.release(id2);
        uint256 S = vault.totalShares();
        uint256 deliverable = lens.deliverableShares(vault);
        assertEq(deliverable, 400_000 ether);
        assertEq(vault.processQueue(1), deliverable);
        assertEq(uint8(lens.requestStatus(vault, req)), uint8(ISharedCommitmentVault.RequestStatus.Pending));
        assertEq(vault.totalShares(), S - deliverable);

        vm.prank(lp0);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NotRequestOwner.selector, req));
        vault.cancelRequest(req);

        vm.prank(lpA);
        uint256 returned = vault.cancelRequest(req);
        assertEq(returned, 500_000 ether - deliverable);
        assertEq(vault.sharesOf(lpA), returned);
        assertEq(vault.pendingShares(), 0);
        assertEq(uint8(lens.requestStatus(vault, req)), uint8(ISharedCommitmentVault.RequestStatus.Claimable));

        vm.prank(lpA);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NothingPending.selector, req));
        vault.cancelRequest(req);

        vm.prank(lpA);
        (uint256 g0, uint256 g1) = vault.claim(req);
        assertGt(g0 + g1, 0);
        assertEq(uint8(lens.requestStatus(vault, req)), uint8(ISharedCommitmentVault.RequestStatus.Canceled));
        vm.prank(lpA);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NothingToClaim.selector, req));
        vault.claim(req);
        assertEq(uint8(lens.requestStatus(vault, 999)), uint8(ISharedCommitmentVault.RequestStatus.None));
        _assertAccountingConsistent();
    }

    // ------------------------------------------------------------------
    // Liveness: bounded by the commitment horizon (argument in SHARE_ACCOUNTING.md §6)
    // ------------------------------------------------------------------

    /// @notice Whatever commitments exist when a request is queued, and whatever allocations curators attempt
    ///         afterwards, the queue fully finalizes once the pre-existing commitments have expired (<= MAX_HORIZON)
    ///         and been released, provided someone calls release and processQueue.
    function testFuzz_queueDrainsAfterHorizon(uint256 q1, uint256 q0, uint256 later, uint256 swapIn, uint256 share)
        public
    {
        _depositShares(lpA, 1_000_000 ether);
        q1 = bound(q1, 1 ether, 2_000_000 ether);
        q0 = bound(q0, 0, 1_900_000 ether);
        uint256 id1 = _allocate(keyA, c1, uint128(q1));
        uint256 id0 = q0 > 0 ? _allocate(keyB, c0, uint128(q0)) : 0;

        share = bound(share, 1 ether, vault.sharesOf(lpA));
        _redeem(lpA, share, true);
        _redeem(lp0, vault.sharesOf(lp0) / 2, true);

        // A curator then reserves as much token1 as admission allows, for 20 days (outliving the old ones).
        later = bound(later, 1 ether, 2_000_000 ether);
        uint256 cap = vault.admissibleCapacity(c1);
        if (cap > 0) {
            ISharedCommitmentVault.AllocationRequest memory r = _request(keyB, c1, uint128(later < cap ? later : cap));
            r.expiry = uint64(block.timestamp + 20 days);
            vm.prank(curator);
            auth.activateDirect(r);
        }
        // Traders keep consuming the old commitment.
        swapIn = bound(swapIn, 0, q1 / 2);
        if (swapIn > 1 ether) _swap(keyA, true, swapIn, id1);

        // Only the commitments that existed when the requests were queued are released.
        vm.warp(block.timestamp + 1 days);
        vault.release(id1);
        if (id0 != 0) vault.release(id0);
        vault.processQueue(10);
        assertEq(vault.pendingShares(), 0, "queue did not drain");
        _assertAccountingConsistent();
    }

    // ------------------------------------------------------------------
    // Decimals
    // ------------------------------------------------------------------

    /// @notice 6-decimal / 18-decimal pair: the share rule is unit-agnostic; only the init geometric mean
    ///         depends on units, and it only sets the share scale.
    function test_decimals_6and18() public {
        MockERC20 usd = new MockERC20("USD6", "USD6", 6);
        MockERC20 eth = new MockERC20("ETH18", "ETH18", 18);
        (MockERC20 t0, MockERC20 t1) = address(usd) < address(eth) ? (usd, eth) : (eth, usd);
        SharedCommitmentVault v =
            new SharedCommitmentVault(manager, owner, Currency.wrap(address(t0)), Currency.wrap(address(t1)));
        uint256 amt0 = t0 == usd ? 3_000_000e6 : 1000 ether;
        uint256 amt1 = t1 == usd ? 3_000_000e6 : 1000 ether;

        _mintApprove(t0, t1, address(v), owner, amt0, amt1);
        vm.prank(owner);
        uint256 shares = v.initialDeposit(amt0, amt1, lpA);
        assertEq(shares + v.MIN_SHARES(), v.totalShares());

        uint256 sharesB = v.totalShares() / 3;
        (uint256 p0, uint256 p1) = lens.previewDeposit(v, sharesB);
        _mintApprove(t0, t1, address(v), lpB, p0, p1);
        vm.prank(lpB);
        v.deposit(sharesB, p0, p1, lpB);
        // lpB bought 1/4 of the new supply and paid 1/3 of each pre-deposit balance, rounded up.
        assertEq(p0, FullMath.mulDivRoundingUp(sharesB, amt0, shares + v.MIN_SHARES()));
        vm.prank(lpB);
        (uint256 instant, uint256 r0, uint256 r1,) = v.redeem(sharesB, 0, 0, lpB, false);
        assertEq(instant, sharesB);
        assertLe(r0, p0);
        assertLe(r1, p1);
        assertLe(p0 - r0, 1);
        assertLe(p1 - r1, 1);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _mintApprove(MockERC20 t0, MockERC20 t1, address v, address lp, uint256 a0, uint256 a1) internal {
        t0.mint(lp, a0);
        t1.mint(lp, a1);
        vm.startPrank(lp);
        t0.approve(v, type(uint256).max);
        t1.approve(v, type(uint256).max);
        vm.stopPrank();
    }

    function _assertProportional(address lp) internal view {
        uint256 s = vault.sharesOf(lp);
        (uint256 e0, uint256 e1) = lens.previewRedeem(vault, s);
        assertEq(e0, FullMath.mulDiv(s, lens.netAssets(vault, c0), vault.totalShares()));
        assertEq(e1, FullMath.mulDiv(s, lens.netAssets(vault, c1), vault.totalShares()));
    }

    function _logState(string memory label) internal view {
        console2.log(label);
        console2.log("  S, N0, N1:", vault.totalShares(), lens.netAssets(vault, c0), lens.netAssets(vault, c1));
        console2.log("  Q0, Q1   :", vault.reserved(c0), vault.reserved(c1));
    }
}
