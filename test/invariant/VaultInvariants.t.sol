// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @notice Random action sequences against the real PoolManager: curator allocations, swaps through both
///         hooks, time, releases, multi-LP deposits, instant/queued redemptions, queue processing,
///         cancellations and claims. Each action may revert; the invariants must hold after every step.
contract VaultHandler is Test {
    SharedCommitmentVault internal vault;
    IPoolManager internal manager;
    PoolSwapTest internal router;
    PoolKey internal keyA;
    PoolKey internal keyB;
    Currency internal c0;
    Currency internal c1;
    address internal curator;
    address internal trader;
    address internal owner;

    address[] public lps;
    uint256[] public allocationIds;
    uint256 internal nonce = 1_000_000;

    /// Ghost ledger: backing implied by deposits - payouts + swap inputs received - swap outputs paid.
    mapping(Currency => uint256) public ghostBacking;
    /// Per request: assets ever finalized and assets ever paid by claim (double-claim detection).
    mapping(uint256 => uint256[2]) internal ghostFinalized;
    mapping(uint256 => uint256[2]) internal ghostClaimed;
    mapping(uint256 => uint256) public ghostFinalizedShares;
    /// Set if a non-trade operation ever lowered N_a / S for the remaining shares.
    bool public perShareDecreased;

    uint256 public swapsOk;
    uint256 public allocationsOk;
    uint256 public releasesOk;
    uint256 public depositsOk;
    uint256 public instantOk;
    uint256 public queuedOk;
    uint256 public finalizedOk;
    uint256 public claimsOk;
    uint256 public cancelsOk;

    constructor(
        SharedCommitmentVault vault_,
        IPoolManager manager_,
        PoolSwapTest router_,
        PoolKey memory keyA_,
        PoolKey memory keyB_,
        address owner_,
        address curator_,
        address trader_,
        address[] memory lps_
    ) {
        vault = vault_;
        manager = manager_;
        router = router_;
        keyA = keyA_;
        keyB = keyB_;
        c0 = keyA_.currency0;
        c1 = keyA_.currency1;
        owner = owner_;
        curator = curator_;
        trader = trader_;
        lps = lps_;
        ghostBacking[c0] = vault_.backing(c0);
        ghostBacking[c1] = vault_.backing(c1);
        for (uint256 i; i < lps_.length; ++i) {
            vm.startPrank(lps_[i]);
            MockERC20(Currency.unwrap(c0)).approve(address(vault_), type(uint256).max);
            MockERC20(Currency.unwrap(c1)).approve(address(vault_), type(uint256).max);
            vm.stopPrank();
        }
    }

    function allocationCount() external view returns (uint256) {
        return allocationIds.length;
    }

    function lpCount() external view returns (uint256) {
        return lps.length;
    }

    function finalized(uint256 id) external view returns (uint256[2] memory) {
        return ghostFinalized[id];
    }

    function claimed(uint256 id) external view returns (uint256[2] memory) {
        return ghostClaimed[id];
    }

    // ------------------------------------------------------------------
    // Curator / trader actions
    // ------------------------------------------------------------------

    function allocate(uint256 seed, uint256 maxOut, uint256 lifetime) external {
        PoolKey memory key = seed % 2 == 0 ? keyA : keyB;
        Currency out = (seed >> 1) % 2 == 0 ? c0 : c1;
        maxOut = bound(maxOut, 1 ether, 1_500_000 ether);
        lifetime = bound(lifetime, 1, 30 days);
        ISharedCommitmentVault.AllocationRequest memory req = ISharedCommitmentVault.AllocationRequest({
            consumer: address(key.hooks),
            key: key,
            currencyOut: out,
            // forge-lint: disable-next-line(unsafe-typecast)
            maxOut: uint128(maxOut),
            minInPerOutX96: uint160(FixedPoint96.Q96 * 98 / 100),
            expiry: uint64(block.timestamp + lifetime),
            nonce: nonce++,
            deadline: uint64(block.timestamp)
        });
        vm.prank(curator);
        try vault.allocate(req) returns (uint256 id) {
            allocationIds.push(id);
            allocationsOk++;
        } catch {}
    }

    function swap(uint256 idSeed, uint256 amountIn) external {
        if (allocationIds.length == 0) return;
        uint256 id = allocationIds[idSeed % allocationIds.length];
        ISharedCommitmentVault.Allocation memory a = vault.getAllocation(id);
        PoolKey memory key = a.consumer == address(keyA.hooks) ? keyA : keyB;
        bool zeroForOne = a.currencyOut == c1;
        amountIn = bound(amountIn, 1e9, 150_000 ether);

        MockERC20(Currency.unwrap(zeroForOne ? c0 : c1)).mint(trader, amountIn);
        vm.prank(trader);
        try router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(id)
        ) returns (
            BalanceDelta d
        ) {
            int128 outDelta = zeroForOne ? d.amount1() : d.amount0();
            ghostBacking[zeroForOne ? c0 : c1] += amountIn;
            // forge-lint: disable-next-line(unsafe-typecast)
            ghostBacking[a.currencyOut] -= uint256(int256(outDelta));
            swapsOk++;
        } catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 3 days));
    }

    function release(uint256 idSeed, bool asOwner) external {
        if (allocationIds.length == 0) return;
        uint256 id = allocationIds[idSeed % allocationIds.length];
        vm.prank(asOwner ? owner : address(0xBEEF));
        try vault.release(id) {
            releasesOk++;
        } catch {}
    }

    // ------------------------------------------------------------------
    // LP actions (each checked for per-share monotonicity)
    // ------------------------------------------------------------------

    function deposit(uint256 lpSeed, uint256 shares) external {
        address lp = lps[lpSeed % lps.length];
        shares = bound(shares, 1, 200_000 ether);
        (uint256 a0, uint256 a1) = vault.previewDeposit(shares);
        MockERC20(Currency.unwrap(c0)).mint(lp, a0);
        MockERC20(Currency.unwrap(c1)).mint(lp, a1);
        (uint256 n0, uint256 n1, uint256 s) = _snapshot();
        vm.prank(lp);
        try vault.deposit(shares, a0, a1, lp) {
            ghostBacking[c0] += a0;
            ghostBacking[c1] += a1;
            depositsOk++;
            _checkMonotonic(n0, n1, s);
        } catch {}
    }

    function redeem(uint256 lpSeed, uint256 shares, bool queueRemainder) external {
        address lp = lps[lpSeed % lps.length];
        uint256 bal = vault.sharesOf(lp);
        if (bal == 0) return;
        // Mostly material redemptions (>= 10% of the LP's balance), occasionally dust-sized ones.
        shares = shares % 8 == 0 ? bound(shares, 1, bal) : bound(shares, bal / 10 + 1, bal);
        (uint256 n0, uint256 n1, uint256 s) = _snapshot();
        vm.prank(lp);
        try vault.redeem(shares, 0, 0, lp, queueRemainder) returns (
            uint256 instant, uint256 a0, uint256 a1, uint256 requestId
        ) {
            ghostBacking[c0] -= a0;
            ghostBacking[c1] -= a1;
            if (instant != 0) instantOk++;
            if (requestId != 0) queuedOk++;
            _checkMonotonic(n0, n1, s);
        } catch {}
    }

    function process(uint256 steps) external {
        steps = bound(steps, 1, 5);
        uint256 head = vault.queueHead();
        uint256 end = vault.nextRequestId();
        uint256[] memory before = new uint256[](end - head);
        for (uint256 id = head; id < end; ++id) {
            before[id - head] = vault.getRequest(id).sharesPending;
        }
        uint256[2][] memory claimableBefore = new uint256[2][](end - head);
        for (uint256 id = head; id < end; ++id) {
            ISharedCommitmentVault.WithdrawalRequest memory r = vault.getRequest(id);
            claimableBefore[id - head] = [uint256(r.claimable0), uint256(r.claimable1)];
        }
        (uint256 n0, uint256 n1, uint256 s) = _snapshot();
        uint256 done = vault.processQueue(steps);
        for (uint256 id = head; id < end; ++id) {
            ISharedCommitmentVault.WithdrawalRequest memory r = vault.getRequest(id);
            ghostFinalizedShares[id] += before[id - head] - r.sharesPending;
            ghostFinalized[id][0] += r.claimable0 - claimableBefore[id - head][0];
            ghostFinalized[id][1] += r.claimable1 - claimableBefore[id - head][1];
        }
        if (done != 0) finalizedOk++;
        _checkMonotonic(n0, n1, s);
    }

    function cancel(uint256 idSeed) external {
        uint256 end = vault.nextRequestId();
        if (end == 1) return;
        uint256 id = 1 + idSeed % (end - 1);
        address lp = vault.getRequest(id).lp;
        (uint256 n0, uint256 n1, uint256 s) = _snapshot();
        vm.prank(lp);
        try vault.cancelRequest(id) {
            cancelsOk++;
            _checkMonotonic(n0, n1, s);
        } catch {}
    }

    function claim(uint256 idSeed) external {
        uint256 end = vault.nextRequestId();
        if (end == 1) return;
        uint256 id = 1 + idSeed % (end - 1);
        address lp = vault.getRequest(id).lp;
        (uint256 n0, uint256 n1, uint256 s) = _snapshot();
        vm.prank(lp);
        try vault.claim(id) returns (uint256 a0, uint256 a1) {
            ghostClaimed[id][0] += a0;
            ghostClaimed[id][1] += a1;
            ghostBacking[c0] -= a0;
            ghostBacking[c1] -= a1;
            claimsOk++;
            _checkMonotonic(n0, n1, s);
        } catch {}
    }

    // ------------------------------------------------------------------

    function _snapshot() internal view returns (uint256, uint256, uint256) {
        return (vault.netAssets(c0), vault.netAssets(c1), vault.totalShares());
    }

    /// N'_a / S' >= N_a / S  <=>  N'_a * S >= N_a * S'  (products < 2^254, no overflow).
    function _checkMonotonic(uint256 n0, uint256 n1, uint256 s) internal {
        uint256 s2 = vault.totalShares();
        if (vault.netAssets(c0) * s < n0 * s2 || vault.netAssets(c1) * s < n1 * s2) perShareDecreased = true;
    }
}

contract VaultInvariantsTest is VaultTestBase {
    VaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        address[] memory lps = new address[](4);
        lps[0] = lp0;
        lps[1] = makeAddr("lpA");
        lps[2] = makeAddr("lpB");
        lps[3] = makeAddr("lpC");
        // Comparable LP sizes so that every LP's redemptions are material.
        for (uint256 i = 1; i < 4; ++i) {
            _depositShares(lps[i], 300_000 ether);
        }
        handler = new VaultHandler(vault, manager, swapRouter, keyA, keyB, owner, curator, trader, lps);
        vm.startPrank(owner);
        vault.setBufferFloor(c0, 50_000 ether);
        vault.setCuratorCeiling(curator, c0, type(uint256).max);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        vm.stopPrank();

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = VaultHandler.allocate.selector;
        selectors[1] = VaultHandler.swap.selector;
        selectors[2] = VaultHandler.warp.selector;
        selectors[3] = VaultHandler.release.selector;
        selectors[4] = VaultHandler.deposit.selector;
        selectors[5] = VaultHandler.redeem.selector;
        selectors[6] = VaultHandler.process.selector;
        selectors[7] = VaultHandler.cancel.selector;
        selectors[8] = VaultHandler.claim.selector;
        selectors[9] = VaultHandler.redeem.selector; // redemption weighted x2
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// B_a == vault's actual ERC-6909 balance (no phantom or missing claims; no donations in this campaign).
    function invariant_backingEqualsRealClaims() public view {
        assertEq(vault.backing(c0), _claims(address(vault), c0));
        assertEq(vault.backing(c1), _claims(address(vault), c1));
    }

    /// B_a matches an independent ledger of deposits, payouts, inputs received and outputs paid.
    function invariant_ghostLedgerConservation() public view {
        assertEq(vault.backing(c0), handler.ghostBacking(c0));
        assertEq(vault.backing(c1), handler.ghostBacking(c1));
    }

    /// Q_a == Σ over unreleased allocations of (maxOut - consumed), and Q_a + W_a <= B_a.
    function invariant_reservedIsExactAndBacked() public view {
        uint256 sum0;
        uint256 sum1;
        uint256 n = handler.allocationCount();
        for (uint256 i; i < n; ++i) {
            ISharedCommitmentVault.Allocation memory a = vault.getAllocation(handler.allocationIds(i));
            assertLe(a.consumed, a.maxOut, "consumed > maxOut");
            if (a.released) continue;
            if (a.currencyOut == c0) sum0 += a.maxOut - a.consumed;
            else sum1 += a.maxOut - a.consumed;
        }
        assertEq(vault.reserved(c0), sum0, "reserved0");
        assertEq(vault.reserved(c1), sum1, "reserved1");
        assertEq(vault.curatorReserved(curator, c0), sum0, "curatorReserved0");
        assertEq(vault.curatorReserved(curator, c1), sum1, "curatorReserved1");
        assertLe(vault.reserved(c0) + vault.claimableAssets(c0), vault.backing(c0));
        assertLe(vault.reserved(c1) + vault.claimableAssets(c1), vault.backing(c1));
    }

    /// Hooks never retain claims; no operator rights over the vault; PoolManager holds the ERC-20 behind them.
    function invariant_custodyAndSolvency() public view {
        _assertAccountingConsistent();
    }

    /// S == Σ sharesOf + P (nothing minted or burned out of thin air), P == Σ pending, W == Σ claimable.
    function invariant_sharesAndQueueConserved() public view {
        uint256 held = vault.sharesOf(address(0));
        for (uint256 i; i < handler.lpCount(); ++i) {
            held += vault.sharesOf(handler.lps(i));
        }
        assertEq(vault.totalShares(), held + vault.pendingShares(), "S != held + pending");
        assertGe(vault.totalShares(), vault.MIN_SHARES());

        uint256 p;
        uint256 w0;
        uint256 w1;
        uint256 end = vault.nextRequestId();
        for (uint256 id = 1; id < end; ++id) {
            ISharedCommitmentVault.WithdrawalRequest memory r = vault.getRequest(id);
            p += r.sharesPending;
            w0 += r.claimable0;
            w1 += r.claimable1;
            assertLe(r.sharesPending, r.sharesRequested);
            if (id < vault.queueHead()) assertEq(r.sharesPending, 0, "pending behind head");
        }
        assertEq(vault.pendingShares(), p, "P != sum pending");
        assertEq(vault.claimableAssets(c0), w0, "W0 != sum claimable");
        assertEq(vault.claimableAssets(c1), w1, "W1 != sum claimable");
    }

    /// No request is paid more than was finalized for it: claimed + claimable == finalized (no double claim).
    function invariant_noDoubleClaim() public view {
        uint256 end = vault.nextRequestId();
        for (uint256 id = 1; id < end; ++id) {
            ISharedCommitmentVault.WithdrawalRequest memory r = vault.getRequest(id);
            uint256[2] memory f = handler.finalized(id);
            uint256[2] memory c = handler.claimed(id);
            assertEq(c[0] + r.claimable0, f[0], "asset0 claimed + claimable != finalized");
            assertEq(c[1] + r.claimable1, f[1], "asset1 claimed + claimable != finalized");
        }
    }

    /// Strict FIFO: while request i still has pending shares, no later request has had any share finalized.
    function invariant_fifoOrdering() public view {
        uint256 end = vault.nextRequestId();
        uint256 firstPending = end;
        for (uint256 id = 1; id < end; ++id) {
            if (vault.getRequest(id).sharesPending != 0) {
                firstPending = id;
                break;
            }
        }
        for (uint256 id = firstPending + 1; id < end; ++id) {
            assertEq(handler.ghostFinalizedShares(id), 0, "later request finalized before earlier pending one");
        }
    }

    /// Deposits, redemptions, finalization, cancellation and claims never reduce N_a / S for remaining shares.
    function invariant_noDilutionByLpOperations() public view {
        assertFalse(handler.perShareDecreased(), "per-share basket decreased");
    }

    /// @dev Logged (not asserted) per run; only the final run's log is printed by forge.
    function afterInvariant() public view {
        console2.log("alloc/swap/release:", handler.allocationsOk(), handler.swapsOk(), handler.releasesOk());
        console2.log("deposit/instant/queued:", handler.depositsOk(), handler.instantOk(), handler.queuedOk());
        console2.log("finalize/claim/cancel:", handler.finalizedOk(), handler.claimsOk(), handler.cancelsOk());
    }

    /// @notice Guards against a vacuous campaign: a fixed handler sequence must actually exercise every LP
    ///         path (deposit, instant, queued, finalize, claim, cancel) and both hooks through the real PoolManager.
    function test_handler_makesProgress() public {
        handler.allocate(0, 10_000 ether, 1 days); // hookA, out token0
        handler.allocate(3, 10_000 ether, 1 days); // hookB, out token1
        handler.swap(0, 100 ether);
        handler.swap(1, 100 ether);
        assertEq(handler.allocationsOk(), 2);
        assertEq(handler.swapsOk(), 2);
        handler.deposit(1, 50_000 ether);
        assertEq(handler.depositsOk(), 1);
        handler.redeem(1, 7, false);
        assertEq(handler.instantOk(), 1);

        // Reserve most token1 so that large redemptions must queue.
        handler.allocate(3, 1_500_000 ether, 1 days);
        assertEq(handler.allocationsOk(), 3);
        handler.redeem(0, vault.sharesOf(lp0), true); // partially instant, remainder queued as request 1
        handler.redeem(2, vault.sharesOf(handler.lps(2)), true); // queue non-empty: fully queued, request 2
        assertEq(handler.queuedOk(), 2);
        handler.cancel(1); // id = 1 + 1 % 2 = request 2
        assertEq(handler.cancelsOk(), 1);
        handler.warp(2 days);
        for (uint256 i; i < 3; ++i) {
            handler.release(i, false);
        }
        handler.process(5);
        assertEq(handler.finalizedOk(), 1);
        handler.claim(0); // request 1
        assertEq(handler.claimsOk(), 1);

        invariant_backingEqualsRealClaims();
        invariant_ghostLedgerConservation();
        invariant_reservedIsExactAndBacked();
        invariant_custodyAndSolvency();
        invariant_sharesAndQueueConserved();
        invariant_noDoubleClaim();
        invariant_fifoOrdering();
        invariant_noDilutionByLpOperations();
    }
}
