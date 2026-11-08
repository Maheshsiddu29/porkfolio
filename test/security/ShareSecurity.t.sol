// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {stdError} from "forge-std/StdError.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {BatchSwapRouter} from "../utils/BatchSwapRouter.sol";
import {ClaimDonor} from "../utils/ClaimDonor.sol";
import {MaliciousConsumerHook} from "../utils/MaliciousConsumerHook.sol";

/// @notice Adversarial tests for the share and redemption layer, on the real PoolManager.
contract ShareSecurityTest is VaultTestBase {
    address internal lpA = makeAddr("lpA");
    address internal victim = makeAddr("victim");
    ClaimDonor internal donor;

    function setUp() public override {
        super.setUp();
        donor = new ClaimDonor(manager);
        vm.startPrank(owner);
        vault.setCuratorCeiling(curator, c0, type(uint256).max);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        vm.stopPrank();
    }

    // ==================================================================
    // Donation / inflation
    // ==================================================================

    /// @notice Classic first-depositor inflation attack: tiny initial deposit, then a large donation to inflate
    ///         the share price so the victim's deposit rounds to zero shares. Here donations are not counted in
    ///         N_a (backing is internal), deposits are share-denominated (no rounding to zero shares) and
    ///         MIN_SHARES are locked, so the victim loses at most 1 wei per asset and the attacker loses the
    ///         donation. Only the owner can initialize; this test keeps the worst case: a careless
    ///         owner seeds the minimum (1001/1001 wei) and assigns the single free share to the attacker.
    function test_inflationAttack_firstDepositorCannotStealFromVictim() public {
        SharedCommitmentVault v = new SharedCommitmentVault(manager, owner, c0, c1);
        _fundAndApprove(attacker, address(v), 1000 ether);
        _fundAndApprove(owner, address(v), 1001);
        vm.prank(owner);
        uint256 attackerShares = v.initialDeposit(1001, 1001, attacker);
        assertEq(attackerShares, 1);

        vm.startPrank(attacker);
        token0.approve(address(donor), type(uint256).max);
        token1.approve(address(donor), type(uint256).max);
        donor.donate(c0, 1000 ether, address(v));
        donor.donate(c1, 1000 ether, address(v));
        vm.stopPrank();
        assertEq(manager.balanceOf(address(v), c0.toId()), 1001 + 1000 ether, "donation landed");
        assertEq(v.netAssets(c0), 1001, "donation not counted");

        uint256 victimShares = 500 ether;
        (uint256 p0, uint256 p1) = v.previewDeposit(victimShares);
        assertEq(p0, 500 ether, "price unaffected by donation");
        _fundAndApprove(victim, address(v), p0);
        vm.prank(victim);
        v.deposit(victimShares, p0, p1, victim);

        vm.prank(attacker);
        (, uint256 a0, uint256 a1,) = v.redeem(1, 0, 0, attacker, false);
        assertLe(a0 + a1, 2, "attacker's 1 share is worth 1 wei per asset");
        vm.prank(victim);
        (, uint256 g0, uint256 g1,) = v.redeem(victimShares, 0, 0, victim, false);
        assertGe(g0 + 1, p0);
        assertGe(g1 + 1, p1);
        console2.log("attacker donated 2000e18, recovered:", a0 + a1);
    }

    function test_donation_toLiveVault_doesNotMoveSharePrice() public {
        _depositShares(lpA, 100_000 ether);
        (uint256 e0, uint256 e1) = vault.previewRedeem(vault.sharesOf(lpA));
        uint256 deliverable = vault.deliverableShares();

        token0.mint(attacker, 50_000 ether);
        vm.startPrank(attacker);
        token0.approve(address(donor), type(uint256).max);
        donor.donate(c0, 50_000 ether, address(vault));
        vm.stopPrank();

        (uint256 f0, uint256 f1) = vault.previewRedeem(vault.sharesOf(lpA));
        assertEq(f0, e0);
        assertEq(f1, e1);
        assertEq(vault.deliverableShares(), deliverable);
        assertEq(_claims(address(vault), c0), vault.backing(c0) + 50_000 ether, "surplus is stranded, not owned");
    }

    function test_initialDeposit_minimumAndLockedShares() public {
        SharedCommitmentVault v = new SharedCommitmentVault(manager, owner, c0, c1);
        _fundAndApprove(owner, address(v), 2002);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InitialDepositTooSmall.selector, 1000, 1000));
        v.initialDeposit(1000, 1000, attacker);
        vm.prank(owner);
        v.initialDeposit(1001, 1001, attacker);
        assertEq(v.sharesOf(address(0)), 1000, "locked forever: address(0) cannot call redeem");
        vm.prank(owner);
        vm.expectRevert(ISharedCommitmentVault.AlreadyInitialized.selector);
        v.initialDeposit(1001, 1001, attacker);
    }

    /// @notice One share always costs at least 1 wei of each non-empty asset and redeems for no more.
    function testFuzz_oneShareRounding(uint256 swapIn) public {
        swapIn = bound(swapIn, 1e9, 300_000 ether);
        uint256 id = _allocate(keyA, c1, 400_000 ether);
        _swap(keyA, true, swapIn, id);
        (uint256 p0, uint256 p1) = _depositShares(lpA, 1);
        assertGe(p0, 1);
        assertGe(p1, 1);
        (, uint256 g0, uint256 g1,) = _redeem(lpA, 1, false);
        assertLe(g0, p0);
        assertLe(g1, p1);
    }

    /// @notice Slither arbitrary-send-erc20 triage: the payer passed through unlockCallback is always the
    ///         deposit's msg.sender. An LP's standing approval cannot be spent by anyone else.
    function test_depositAlwaysPullsFromCaller() public {
        _fundLp(lpA, 1_000_000 ether, 1_000_000 ether); // lpA has approved the vault for max
        (uint256 p0, uint256 p1) = vault.previewDeposit(1000 ether);
        vm.prank(attacker); // attacker holds no tokens and names lpA's funds nowhere
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        vault.deposit(1000 ether, p0, p1, attacker);
        assertEq(token0.balanceOf(lpA), 1_000_000 ether);

        vm.prank(attacker);
        vm.expectRevert(ISharedCommitmentVault.NotPoolManager.selector);
        vault.unlockCallback(abi.encode(uint8(0), lpA, p0, p1));
    }

    // ==================================================================
    // Double redemption / double claim / authority
    // ==================================================================

    /// @notice Queued shares leave the LP's free balance at once, so they cannot be redeemed again while they wait.
    ///         After finalization the request pays exactly once: a second claim and a late cancel both revert.
    function test_sharesCannotBeRedeemedTwice() public {
        _depositShares(lpA, 100_000 ether);
        uint256 id = _allocate(keyA, c1, uint128(vault.admissibleCapacity(c1)));
        (uint256 instant,,, uint256 req) = _redeem(lpA, 100_000 ether, true);
        assertEq(instant, 0);
        assertEq(vault.sharesOf(lpA), 0, "escrowed");

        vm.prank(lpA);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientShares.selector, 1, 0));
        vault.redeem(1, 0, 0, lpA, true);

        vm.prank(lpA);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NothingToClaim.selector, req));
        vault.claim(req);

        vm.prank(owner);
        vault.release(id);
        vault.processQueue(1);
        vm.prank(lpA);
        vault.claim(req);
        vm.prank(lpA);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NothingToClaim.selector, req));
        vault.claim(req);
        vm.prank(lpA);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NothingPending.selector, req));
        vault.cancelRequest(req);
        assertEq(token0.balanceOf(lpA), 100_000 ether);
        _assertAccountingConsistent();
    }

    function test_requestAuthority() public {
        _depositShares(lpA, 100_000 ether);
        _allocate(keyA, c1, uint128(vault.admissibleCapacity(c1)));
        (,,, uint256 req) = _redeem(lpA, 100_000 ether, true);

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NotRequestOwner.selector, req));
        vault.claim(req);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NotRequestOwner.selector, req));
        vault.cancelRequest(req);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NotRequestOwner.selector, 77));
        vault.claim(77);
        vm.stopPrank();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NotRequestOwner.selector, req));
        vault.cancelRequest(req);
    }

    // ==================================================================
    // Protected capacity and solvency
    // ==================================================================

    /// @notice Finalized (claimable) assets can be reached by neither new commitments, hook consumption,
    ///         nor other LPs' redemptions; the claim pays exactly what was finalized.
    function test_claimableAssetsAreRingFenced() public {
        _depositShares(lpA, 1_000_000 ether); // S = 2M
        uint256 id = _allocate(keyA, c1, 1_500_000 ether); // F1 = 500k
        (uint256 instant,,, uint256 req) = _redeem(lpA, 1_000_000 ether, true);
        assertEq(instant, 500_000 ether);
        vm.prank(owner);
        vault.release(id);
        vault.processQueue(1);
        assertEq(vault.claimableAssets(c1), 500_000 ether);

        // N1 = B1 - W1 = 1M; a new commitment cannot exceed it.
        assertEq(vault.admissibleCapacity(c1), 1_000_000 ether);
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyA, c1, 1_000_000 ether + 1);
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.InsufficientBacking.selector, 1_000_000 ether + 1, 1_000_000 ether
            )
        );
        vault.allocate(r);
        uint256 id2 = _allocate(keyA, c1, 1_000_000 ether);

        // Another LP cannot reach it, a hook can consume the whole commitment without touching it.
        vm.prank(lp0);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientLiquidity.selector, 1, 0));
        vault.redeem(1, 0, 0, lp0, false);
        _swap(keyA, true, 1_005_025 ether, id2); // ~all of the commitment at the 50 bps max fee
        assertGt(vault.getAllocation(id2).consumed, 999_999 ether);
        assertEq(vault.freeInventory(c1), 0);
        assertEq(vault.backing(c1), 500_000 ether + vault.reserved(c1), "only claimable + unconsumed remain");

        vm.prank(lpA);
        (uint256 g0, uint256 g1) = vault.claim(req);
        assertEq(g0, 500_000 ether);
        assertEq(g1, 500_000 ether);
        _assertAccountingConsistent();
    }

    /// @notice A compromised registered hook still cannot reach claimable redemption assets.
    function test_maliciousHook_cannotReachClaimable() public {
        _depositShares(lpA, 1_000_000 ether);
        uint256 id = _allocate(keyA, c1, 1_500_000 ether);
        (,,, uint256 req) = _redeem(lpA, 1_000_000 ether, true);
        vm.prank(owner);
        vault.release(id);
        vault.processQueue(1);
        uint256 w1 = vault.claimableAssets(c1);
        uint256 b1 = vault.backing(c1);

        address addr = address(uint160(0xBAD << 140) | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        deployCodeTo("MaliciousConsumerHook.sol:MaliciousConsumerHook", abi.encode(manager, vault), addr);
        MaliciousConsumerHook m = MaliciousConsumerHook(addr);
        PoolKey memory keyM = PoolKey(c0, c1, 3000, 60, IHooks(addr));
        manager.initialize(keyM, SQRT_PRICE_1_1);
        vm.prank(owner);
        vault.setConsumer(addr, true);
        uint256 mid = _allocate(keyM, c1, 1000 ether);

        m.configure(MaliciousConsumerHook.Attack.TransferFromVault, mid, w1);
        _expectSwapRevert(addr, stdError.arithmeticError);
        _swapRaw(keyM, true, -100 ether, "");
        m.configure(MaliciousConsumerHook.Attack.OverQuota, mid, 1000 ether + 1);
        _expectSwapRevert(
            addr, abi.encodeWithSelector(ISharedCommitmentVault.QuotaExceeded.selector, 1000 ether + 1, 1000 ether)
        );
        _swapRaw(keyM, true, -2000 ether, "");

        assertEq(vault.claimableAssets(c1), w1);
        assertEq(vault.backing(c1), b1);
        vm.prank(lpA);
        vault.claim(req);
    }

    // ==================================================================
    // Rollback
    // ==================================================================

    /// @notice The vault writes shares and backing before it pulls tokens inside the unlock. If the second token
    ///         transfer fails, the whole call reverts, including the first token's transfer and the share credit.
    function test_failedDeposit_rollsBackShareState() public {
        uint256 S = vault.totalShares();
        uint256 b0 = vault.backing(c0);
        (uint256 p0, uint256 p1) = vault.previewDeposit(1000 ether);
        token0.mint(lpA, p0);
        token1.mint(lpA, p1 - 1); // one wei short of token1
        vm.startPrank(lpA);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        vault.deposit(1000 ether, p0, p1, lpA);
        vm.stopPrank();
        assertEq(vault.totalShares(), S);
        assertEq(vault.sharesOf(lpA), 0);
        assertEq(vault.backing(c0), b0);
        assertEq(token0.balanceOf(lpA), p0, "token0 leg rolled back too");
        _assertAccountingConsistent();
    }

    /// @notice A swap whose router never pays the input fails at the end of the PoolManager unlock
    ///         (CurrencyNotSettled). The vault had already updated backing and quota inside `exchange`; all of it
    ///         must roll back, leaving queued shares and supply exactly as they were.
    function test_failedSwapSettlement_leavesQueueUntouched() public {
        _depositShares(lpA, 500_000 ether);
        uint256 id = _allocate(keyA, c1, 1_400_000 ether);
        _redeem(lpA, 500_000 ether, true);
        uint256 P = vault.pendingShares();
        uint256 S = vault.totalShares();
        uint256 b0 = vault.backing(c0);
        uint256 b1 = vault.backing(c1);

        BatchSwapRouter.Step[] memory steps = new BatchSwapRouter.Step[](1);
        steps[0] = BatchSwapRouter.Step(keyA, true, 1000 ether, abi.encode(id));
        vm.prank(trader);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        batchRouter.run(steps, new uint256[](0), BatchSwapRouter.Mode.SkipInputPayment);

        assertEq(vault.pendingShares(), P);
        assertEq(vault.totalShares(), S);
        assertEq(vault.backing(c0), b0);
        assertEq(vault.backing(c1), b1);
        assertEq(vault.getAllocation(id).consumed, 0);
    }

    // ==================================================================
    // Owner and pause
    // ==================================================================

    function test_ownerHasNoPathToShareholderAssets() public {
        // Owner-only deposit/withdraw functions from an earlier design must not exist.
        (bool ok,) = address(vault).call(abi.encodeWithSignature("withdraw(address,uint256,address)", c0, 1, owner));
        assertFalse(ok);
        (ok,) = address(vault).call(abi.encodeWithSignature("deposit(address,uint256)", c0, 1));
        assertFalse(ok);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientShares.selector, 1, 0));
        vault.redeem(1, 0, 0, owner, true);

        // Emergency release moves capacity, not assets.
        uint256 id = _allocate(keyA, c1, 100_000 ether);
        uint256 b1 = vault.backing(c1);
        vm.prank(owner);
        vault.release(id);
        assertEq(vault.backing(c1), b1);
        assertEq(_claims(owner, c1) + token1.balanceOf(owner), 0);
    }

    function test_pause_blocksInflowsAndCommitments_notExits() public {
        _depositShares(lpA, 200_000 ether);
        uint256 id = _allocate(keyA, c1, 1_100_000 ether); // F1 = 100k
        vm.prank(owner);
        vault.setPaused(true);

        (uint256 p0, uint256 p1) = vault.previewDeposit(1 ether);
        _fundLp(lpA, p0, p1);
        vm.prank(lpA);
        vm.expectRevert(ISharedCommitmentVault.Paused.selector);
        vault.deposit(1 ether, p0, p1, lpA);
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyB, c0, 1 ether);
        vm.prank(curator);
        vm.expectRevert(ISharedCommitmentVault.Paused.selector);
        vault.allocate(r);
        _expectSwapRevert(address(hookA), abi.encodeWithSelector(ISharedCommitmentVault.Paused.selector));
        _swap(keyA, true, 1 ether, id);

        (uint256 instant,,, uint256 req) = _redeem(lpA, 200_000 ether, true);
        assertGt(instant, 0);
        assertGt(req, 0);
        vm.prank(owner);
        vault.release(id);
        vault.processQueue(1);
        vm.prank(lpA);
        vault.claim(req);
        assertEq(vault.sharesOf(lpA), 0);
    }

    // ==================================================================
    // Front-running bounds and queue spam
    // ==================================================================

    function test_slippageBounds_depositAndRedeem() public {
        (uint256 p0, uint256 p1) = vault.previewDeposit(100_000 ether);
        _fundLp(lpA, p0 * 2, p1 * 2);
        // A swap lands first and shifts the basket composition.
        uint256 id = _allocate(keyB, c0, 200_000 ether);
        _swap(keyB, false, 100_000 ether, id);
        vm.prank(lpA);
        vm.expectRevert(ISharedCommitmentVault.SlippageExceeded.selector);
        vault.deposit(100_000 ether, p0, p1, lpA);

        (uint256 e0, uint256 e1) = vault.previewRedeem(100_000 ether);
        vm.prank(lp0);
        vm.expectRevert(ISharedCommitmentVault.SlippageExceeded.selector);
        vault.redeem(100_000 ether, e0 + 1, e1, lp0, false);
        vm.prank(lp0);
        vault.redeem(100_000 ether, e0, e1, lp0, false);
    }

    /// @notice Many tiny requests ahead of a large one: processing is bounded per call (maxSteps) and the
    ///         large request is still served in order. Cost is borne by whoever calls processQueue.
    function test_queueSpam_boundedProcessing() public {
        _depositShares(attacker, 100 ether);
        _depositShares(lpA, 500_000 ether);
        uint256 id = _allocate(keyA, c1, uint128(vault.admissibleCapacity(c1))); // F1 = 0
        for (uint256 i; i < 50; ++i) {
            _redeem(attacker, 1 ether, true);
        }
        (,,, uint256 big) = _redeem(lpA, 500_000 ether, true);
        assertEq(big, 51);
        vm.prank(owner);
        vault.release(id);

        uint256 calls;
        while (vault.pendingShares() != 0 && calls < 20) {
            uint256 g = gasleft();
            vault.processQueue(10);
            if (calls == 0) console2.log("processQueue(10) gas:", g - gasleft());
            ++calls;
        }
        assertEq(calls, 6, "51 requests / 10 per call");
        assertEq(vault.queueHead(), 52);
        vm.prank(lpA);
        vault.claim(big);
        _assertAccountingConsistent();
    }

    function _fundAndApprove(address who, address v, uint256 amount) internal {
        token0.mint(who, amount);
        token1.mint(who, amount);
        vm.startPrank(who);
        token0.approve(v, type(uint256).max);
        token1.approve(v, type(uint256).max);
        vm.stopPrank();
    }
}
