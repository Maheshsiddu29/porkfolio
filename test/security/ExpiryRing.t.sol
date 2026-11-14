// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {IMarketRiskAdapter} from "../../src/interfaces/IMarketRiskAdapter.sol";
import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {VaultStateReader} from "../../src/libraries/VaultStateReader.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {MaliciousConsumerHook} from "../utils/MaliciousConsumerHook.sol";
import {MockRiskAdapter} from "../utils/MockRiskAdapter.sol";

using VaultStateReader for SharedCommitmentVault;

/// @notice The expiry ring on the real vault: hour-aligned expiries, keeper-free recognition of expired capacity by
///         bounded sweeps, slot reuse, and every path that touches Q_a, against expected values computed in the test
///         from the allocations themselves (Q^live: unreleased and unexpired; Q^lazy: unreleased).
/// @dev Fixture: VaultTestBase (1,000,000 of each asset, static mode, no inventory floor) plus a test hook that fills
///      exact amounts at 1:1. The clock starts at T0, which is not an hour boundary. "Sweep" below means any call
///      that runs the vault's `_sweep`; `processQueue(0)` is used because it does nothing else.
contract ExpiryRingTest is VaultTestBase {
    uint160 internal constant SWAP_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
    uint256 internal constant H = 1 hours;

    MaliciousConsumerHook internal mal;
    PoolKey internal keyM;

    function setUp() public override {
        super.setUp();
        address m = address(uint160(0xBAD8 << 140) | SWAP_FLAGS);
        deployCodeTo("MaliciousConsumerHook.sol:MaliciousConsumerHook", abi.encode(manager, vault), m);
        mal = MaliciousConsumerHook(m);
        keyM = PoolKey(c0, c1, 3000, 60, IHooks(m));
        manager.initialize(keyM, SQRT_PRICE_1_1);
        vm.startPrank(owner);
        vault.setConsumer(m, true);
        _openLimits(ISharedCommitmentVault.RiskScope.Hook, m);
        vault.setCuratorCeiling(curator, c0, type(uint256).max);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ helpers

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp(); // via-IR may reuse a block.timestamp read from before a warp
    }

    function _bucketNow() internal view returns (uint256) {
        return _now() / H;
    }

    /// @dev An allocation on `key` selling `out`, expiring at the end of bucket `bucket`.
    function _reserveIn(PoolKey memory key, Currency out, uint256 amount, uint256 bucket) internal returns (uint256) {
        ISharedCommitmentVault.AllocationRequest memory r = _request(key, out, uint128(amount));
        r.expiry = uint64(bucket * H);
        r.deadline = uint64(_now());
        vm.prank(curator);
        return auth.activateDirect(r);
    }

    function _fill(uint256 id, Currency out, uint256 amount) internal {
        mal.configure(MaliciousConsumerHook.Attack.ExactAmounts, id, amount);
        _swapRaw(keyM, out == c1, -int256(amount), "");
    }

    function _sweep() internal {
        vault.processQueue(0);
    }

    /// @dev Q^live and Q^lazy of `c`, from the allocation records.
    function _sums(Currency c) internal view returns (uint256 live, uint256 lazy) {
        for (uint256 id = 1; id < vault.nextAllocationId(); ++id) {
            ISharedCommitmentVault.Allocation memory a = vault.getAllocation(id);
            if (a.released || !(a.currencyOut == c)) continue;
            uint256 r = a.maxOut - a.consumed;
            lazy += r;
            if (_now() < a.expiry) live += r;
        }
    }

    /// @dev V-3 for `c`: Q^live <= Q <= Q^lazy and the lens reports Q^live exactly.
    function _assertBounds(Currency c) internal view {
        (uint256 live, uint256 lazy) = _sums(c);
        uint256 q = vault.reserved(c);
        assertLe(live, q, "Q below the live sum");
        assertLe(q, lazy, "Q above the lazy sum");
        assertEq(lens.liveReserved(vault, c), live, "liveReserved");
        assertLe(lens.sweptReserved(vault, c), q, "sweptReserved above Q");
        assertGe(lens.sweptReserved(vault, c), live, "sweptReserved below live");
    }

    // ------------------------------------------------------------------ expiry rules and exact boundaries

    /// @notice The first sweep on a fresh vault takes the O(1) branch from the all-zero ring: swept jumps to the
    ///         current bucket without walking from bucket 0.
    function test_firstSweep_startsAtTheCurrentBucket() public {
        (uint64 sw, uint64 mb) = lens.expiryRing(vault, c0);
        assertEq(sw, 0);
        assertEq(mb, 0);
        uint256 g = gasleft();
        _sweep();
        assertLt(g - gasleft(), 100_000, "no walk from bucket 0");
        (sw, mb) = lens.expiryRing(vault, c0);
        assertEq(sw, _bucketNow());
        assertEq(mb, 0);
    }

    /// @notice At an hour boundary, `now + 30 days` is itself admissible and lands in bucket c + 720, the far end of
    ///         the ring; one hour more is past the horizon. An expiry one second off a boundary is refused.
    function test_expiry_30DayBoundary_atAlignedNow() public {
        vm.warp((_bucketNow() + 1) * H); // an hour boundary
        uint256 c = _bucketNow();
        uint256 id = _reserveIn(keyM, c1, 1000 ether, c + 720);
        assertEq(vault.getAllocation(id).expiry, _now() + 30 days);
        (, uint64 mb) = lens.expiryRing(vault, c1);
        assertEq(mb, c + 720, "bucket c + K");

        ISharedCommitmentVault.AllocationRequest memory r = _request(keyM, c1, 1000 ether);
        (r.deadline, r.expiry) = (uint64(_now()), uint64((c + 721) * H));
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(ISharedCommitmentVault.HorizonExceeded.selector, r.expiry, _now() + 30 days)
        );
        auth.activateDirect(r);
        r.expiry = uint64((c + 5) * H + 1);
        vm.prank(curator);
        vm.expectRevert(ISharedCommitmentVault.InvalidExpiry.selector);
        auth.activateDirect(r);
    }

    /// @notice Consumable at expiry - 1, refused at expiry. Q^live drops at the expiry second with no call; the stored
    ///         Q drops at the next sweeping call; nothing else is needed.
    function test_fillAtExpiryMinusOne_refusedAtExpiry() public {
        uint256 b = _bucketNow() + 3;
        uint256 id = _reserveIn(keyM, c1, 10_000 ether, b);
        vm.warp(b * H - 1);
        _fill(id, c1, 4000 ether);
        assertEq(lens.liveReserved(vault, c1), 6000 ether);
        vm.warp(b * H);
        assertEq(lens.liveReserved(vault, c1), 0, "live drops at the expiry second without a call");
        assertEq(vault.reserved(c1), 6000 ether, "stored Q waits for a sweep");
        mal.configure(MaliciousConsumerHook.Attack.ExactAmounts, id, 1);
        _expectSwapRevert(
            address(mal), abi.encodeWithSelector(ISharedCommitmentVault.AllocationExpired.selector, id, uint64(b * H))
        );
        _swapRaw(keyM, true, -1, "");
        _sweep();
        assertEq(vault.reserved(c1), 0, "the sweep recognized the expiry");
        assertEq(vault.curatorReserved(curator, c1), 6000 ether, "scope total waits for the close");
        _assertBounds(c1);
        _assertEquations();
    }

    // ------------------------------------------------------------------ sweep gaps

    /// @dev Reservations in buckets c+1 .. c+33 of i ether each (distinct amounts, so subtracting a wrong bucket
    ///      shows), plus, with `far`, 5 ether in bucket c + 720 that keeps maxBucket ahead of the clock. Then the clock
    ///      moves `gap` buckets and ONE sweeping call runs. The stored Q must equal the total minus exactly the
    ///      buckets that call may subtract: all of them if every recorded bucket has ended (O(1) branch), otherwise the
    ///      first min(gap, 32) after `swept` (swept = c from the reservations' own sweeps).
    function _gapCase(uint256 gap, bool far) internal {
        vm.warp((_bucketNow() + 1) * H + 17); // 17 s into a bucket
        uint256 c = _bucketNow();
        uint256 total;
        for (uint256 i = 1; i <= 33; ++i) {
            _reserveIn(keyM, c1, i * 1 ether, c + i);
            total += i * 1 ether;
        }
        if (far) {
            _reserveIn(keyM, c1, 5 ether, c + 720);
            total += 5 ether;
        }
        assertEq(vault.reserved(c1), total);
        (uint64 sw,) = lens.expiryRing(vault, c1);
        assertEq(sw, c, "reservations swept to the current bucket");

        vm.warp(_now() + gap * H);
        uint256 maxBucket = far ? c + 720 : c + 33;
        uint256 expected;
        if (c + gap >= maxBucket) {
            expected = 0;
        } else {
            uint256 walked = gap < 32 ? gap : 32;
            expected = total;
            for (uint256 i = 1; i <= walked && i <= 33; ++i) {
                expected -= i * 1 ether;
            }
        }
        assertEq(lens.sweptReserved(vault, c1), expected, "lens predicts the sweep");
        _sweep();
        assertEq(vault.reserved(c1), expected, "one sweep");
        _assertBounds(c1);
        // Further calls converge to the live sum.
        for (uint256 k; k < 30; ++k) {
            _sweep();
        }
        (uint256 live,) = _sums(c1);
        assertEq(vault.reserved(c1), live, "converged");
    }

    /// @notice Gaps of 0, 1, 32, 33, 719, 720 and 721 hours, with the far reservation (the walking path for every gap
    ///         below 720; at 720 and 721 every recorded bucket has ended) and without it (the O(1) branch once the gap
    ///         reaches the last bucket, 33).
    function test_sweepGaps() public {
        uint256[7] memory gaps = [uint256(0), 1, 32, 33, 719, 720, 721];
        for (uint256 i; i < gaps.length; ++i) {
            for (uint256 f; f < 2; ++f) {
                uint256 snap = vm.snapshotState();
                _gapCase(gaps[i], f == 1);
                vm.revertToState(snap);
            }
        }
    }

    /// @notice now = maxBucket * 1 h exactly: everything recorded has ended, so one sweep zeroes Q in O(1); one second
    ///         earlier the last bucket is live and stays counted.
    function test_sweepAtMaxBucketExactly() public {
        uint256 c = _bucketNow();
        _reserveIn(keyM, c0, 1000 ether, c + 2);
        _reserveIn(keyM, c0, 2000 ether, c + 40);
        vm.warp((c + 40) * H - 1);
        _sweep();
        assertEq(vault.reserved(c0), 2000 ether, "the last bucket is live one second before its end");
        vm.warp((c + 40) * H);
        _sweep();
        assertEq(vault.reserved(c0), 0);
        (uint64 sw,) = lens.expiryRing(vault, c0);
        assertEq(sw, c + 40);
    }

    // ------------------------------------------------------------------ slot reuse, eviction, closes

    /// @notice Bucket b, then b + 720 in the same slot, then b + 1440. Each time the older bucket has ended but no
    ///         sweep has reached it (it is more than 32 buckets ahead of `swept`), so the write evicts it: its capacity
    ///         leaves Q exactly once, the later walk over b skips it (the slot no longer carries tag b), and closing the
    ///         evicted allocation lowers the scope totals but not Q.
    function test_slotReuse_evictsOnce_acrossThreeHorizons() public {
        uint256 c = _bucketNow();
        uint256 b = c + 700;
        uint256[3] memory ids;
        uint256 far = _reserveIn(keyM, c1, 1 ether, c + 720); // keeps maxBucket ahead at time b
        ids[0] = _reserveIn(keyM, c1, 300 ether, b);
        for (uint256 k = 1; k < 3; ++k) {
            uint256 prev = b + (k - 1) * 720;
            vm.warp(prev * H + 1); // the previous bucket has just ended
            uint256 qBefore = vault.reserved(c1);
            uint256 swBefore;
            {
                (uint64 sw,) = lens.expiryRing(vault, c1);
                swBefore = sw;
            }
            // The reservation's own sweep walks 32 buckets from swBefore and does not reach `prev`.
            assertLt(swBefore + 32, prev, "the older bucket is out of the sweep's reach");
            ids[k] = _reserveIn(keyM, c1, (k + 1) * 300 ether, prev + 720);
            (uint64 tag, uint128 amount) = lens.expiryBucket(vault, c1, b % 720);
            assertEq(tag, prev + 720, "retagged");
            assertEq(amount, (k + 1) * 300 ether);
            // The 32 buckets the reservation's own sweep walked hold nothing, so Q changed by exactly: minus the
            // evicted bucket (k * 300), plus the new one ((k + 1) * 300).
            assertEq(vault.reserved(c1), qBefore - k * 300 ether + (k + 1) * 300 ether, "evicted exactly once");
            _assertBounds(c1);
            // Closing the evicted allocation: scope totals fall, Q does not.
            uint256 q = vault.reserved(c1);
            uint256 cr = vault.curatorReserved(curator, c1);
            vault.release(ids[k - 1]);
            assertEq(vault.reserved(c1), q, "evicted: Q unchanged by the close");
            assertEq(vault.curatorReserved(curator, c1), cr - k * 300 ether);
            if (k == 1) {
                // Keep maxBucket ahead of the second reuse: at b + 30 a reservation can reach b + 750 > b + 720.
                vm.warp((b + 30) * H);
                _reserveIn(keyM, c1, 1 ether, b + 750);
            }
        }
        // Walk the whole ring past the evicted buckets: nothing is subtracted twice.
        for (uint256 k; k < 60; ++k) {
            _sweep();
        }
        _assertBounds(c1);
        (uint256 live,) = _sums(c1);
        assertEq(vault.reserved(c1), live, "converged to the live sum");
        vault.release(far);
        _assertEquations();
    }

    /// @notice A close before the bucket is swept lowers Q by the remainder; a close after the sweep leaves Q alone;
    ///         both lower the curator's and the hook's totals by the remainder.
    function test_closeBeforeAndAfterSweep() public {
        uint256 c = _bucketNow();
        uint256 a = _reserveIn(keyM, c0, 1000 ether, c + 2);
        uint256 b = _reserveIn(keyM, c0, 2000 ether, c + 2);
        _fill(b, c0, 500 ether);
        vm.warp((c + 2) * H);
        // a: expired, not yet swept.
        vault.release(a);
        assertEq(vault.reserved(c0), 1500 ether, "close before the sweep: Q -= 1,000");
        assertEq(vault.curatorReserved(curator, c0), 1500 ether);
        _sweep();
        assertEq(vault.reserved(c0), 0, "the sweep takes b's remainder");
        vault.release(b);
        assertEq(vault.reserved(c0), 0, "close after the sweep: Q unchanged");
        assertEq(vault.curatorReserved(curator, c0), 0);
        assertEq(vault.hookReserved(address(mal), c0), 0);
        _assertEquations();
    }

    /// @notice Partial consumption, then expiry: the sweep removes only the unconsumed remainder (consumption already
    ///         took its part out of the bucket and of Q), and a later release changes Q by nothing.
    function test_partialConsumptionThenExpiry() public {
        uint256 c = _bucketNow();
        uint256 id = _reserveIn(keyM, c1, 10_000 ether, c + 5);
        uint256 other = _reserveIn(keyM, c1, 4000 ether, c + 9);
        _fill(id, c1, 3500 ether);
        (, uint128 amount) = lens.expiryBucket(vault, c1, (c + 5) % 720);
        assertEq(amount, 6500 ether, "consumption lowers the bucket");
        assertEq(vault.reserved(c1), 10_500 ether);
        vm.warp((c + 5) * H);
        _sweep();
        assertEq(vault.reserved(c1), 4000 ether, "only the remainder 6,500 left with the sweep");
        vault.release(id);
        assertEq(vault.reserved(c1), 4000 ether);
        assertEq(vault.curatorReserved(curator, c1), 4000 ether);
        assertEq(vault.getAllocation(id).consumed, 3500 ether);
        _fill(other, c1, 4000 ether);
        assertEq(vault.reserved(c1), 0);
        _assertEquations();
    }

    // ------------------------------------------------------------------ paths

    /// @notice Hook A, Hook B and the test hook reserve the same asset in different buckets. Each fill lowers only its
    ///         own allocation, its own bucket and Q; one hook's expiry leaves the others' capacity counted.
    function test_severalHooksCompeteForOneAsset() public {
        uint256 c = _bucketNow();
        uint256 idA = _reserveIn(keyA, c1, 5000 ether, c + 2);
        uint256 idB = _reserveIn(keyB, c1, 6000 ether, c + 4);
        uint256 idM = _reserveIn(keyM, c1, 7000 ether, c + 4);
        _swap(keyA, true, 1000 ether, idA);
        uint256 consumedA = vault.getAllocation(idA).consumed;
        assertGt(consumedA, 0);
        _swap(keyB, true, 1000 ether, idB);
        uint256 consumedB = vault.getAllocation(idB).consumed;
        _fill(idM, c1, 2000 ether);
        (, uint128 a2) = lens.expiryBucket(vault, c1, (c + 2) % 720);
        (, uint128 a4) = lens.expiryBucket(vault, c1, (c + 4) % 720);
        assertEq(a2, 5000 ether - consumedA, "Hook A's bucket");
        assertEq(a4, 13_000 ether - consumedB - 2000 ether, "Hook B and the test hook share bucket c + 4");
        assertEq(vault.reserved(c1), a2 + a4);
        assertEq(vault.getAllocation(idM).consumed, 2000 ether, "no fill touched another allocation");

        vm.warp((c + 2) * H);
        _sweep();
        assertEq(vault.reserved(c1), a4, "Hook A's expiry leaves the others counted");
        _swap(keyB, true, 500 ether, idB); // still live
        _fill(idM, c1, 1000 ether);
        _assertBounds(c1);
        _assertEquations();
    }

    /// @notice `exchange` does not sweep and reads no ring header: a fill costs the same gas whether the ring is
    ///         up to date or 700 buckets behind (same state otherwise, the vault's and the PoolManager's storage cooled
    ///         before each measurement). Forge runs a test as one transaction, so the two branches can differ by a few
    ///         gas of bookkeeping from earlier calls; a header read alone would add a cold storage read (2,100 gas) and
    ///         a sweep of the backlog 32 of them, so the bound below separates the two cases.
    function test_exchangeGas_independentOfElapsedBuckets() public {
        uint256 c = _bucketNow();
        _reserveIn(keyM, c1, 1 ether, c + 720); // keeps maxBucket ahead, so the ring stays behind
        uint256 id = _reserveIn(keyM, c1, 100_000 ether, c + 719);
        vm.warp((c + 700) * H + 5);
        uint256 snap = vm.snapshotState();
        for (uint256 k; k < 25; ++k) {
            _sweep(); // bring the ring up to date (700 buckets, 32 per call)
        }
        (uint64 sw,) = lens.expiryRing(vault, c1);
        assertEq(sw, c + 700);
        uint256 gasCurrent = _measuredFill(id);
        vm.revertToState(snap);
        (sw,) = lens.expiryRing(vault, c1);
        assertEq(sw, c, "700 buckets behind");
        uint256 gasBehind = _measuredFill(id);
        emit log_named_uint("fill gas, ring up to date", gasCurrent);
        emit log_named_uint("fill gas, ring 700 buckets behind", gasBehind);
        uint256 diff = gasBehind > gasCurrent ? gasBehind - gasCurrent : gasCurrent - gasBehind;
        assertLt(diff, 2100, "swap gas does not depend on the sweep backlog");
    }

    function _measuredFill(uint256 id) internal returns (uint256 used) {
        mal.configure(MaliciousConsumerHook.Attack.ExactAmounts, id, 100 ether);
        vm.cool(address(vault));
        vm.cool(address(manager));
        uint256 g = gasleft();
        _swapRaw(keyM, true, -int256(100 ether), "");
        used = g - gasleft();
    }

    // ------------------------------------------------------------------ LP paths and liveness

    /// @notice LPs queued behind reservations are finalized by `processQueue` alone once the reservations have
    ///         expired, oldest first, with no release; `redeem` likewise pays instantly after expiry.
    function test_queuedWithdrawals_finalizeAfterExpiryWithoutRelease() public {
        address lpA = makeAddr("lpA");
        address lpB = makeAddr("lpB");
        _depositShares(lpA, 100_000 ether);
        _depositShares(lpB, 100_000 ether);
        uint256 c = _bucketNow();
        _reserveIn(keyM, c0, 150_000 ether, c + 10); // enough for the head request only
        _reserveIn(keyA, c0, uint128(vault.admissibleCapacity(c0)), c + 20);
        (,,, uint256 rA) = _redeem(lpA, 100_000 ether, true);
        (,,, uint256 rB) = _redeem(lpB, 100_000 ether, true);
        (,,, uint256 r0) = _redeem(lp0, vault.sharesOf(lp0) / 10, true);
        assertTrue(rA != 0 && rB != 0 && r0 != 0, "all queued");
        vm.warp((c + 10) * H);
        vault.processQueue(10);
        assertEq(vault.getRequest(rA).sharesPending, 0, "the first expiry frees enough for the head");
        assertGt(vault.getRequest(rB).sharesPending + vault.getRequest(r0).sharesPending, 0, "later ones wait");
        vm.warp((c + 20) * H);
        vault.processQueue(10);
        assertEq(vault.pendingShares(), 0, "all finalized with no release");
        assertEq(vault.reserved(c0), 0);
        _assertEquations();
    }

    /// @notice An oracle outage stops fills but not expiry or exits: Q stays while the reservation is live, the sweep
    ///         reads no price, and exits proceed after expiry with the adapter still broken.
    function test_oracleOutage_expiryAndExitsUnaffected() public {
        MockRiskAdapter adapter = new MockRiskAdapter(address(token0), address(token1), 18, 18, keccak256("ring"));
        adapter.set(FixedPoint96.Q96, 1000, type(uint256).max);
        vm.startPrank(owner);
        vault.setRiskBounds(100, 5000);
        vault.setRiskAdapter(IMarketRiskAdapter(address(adapter)));
        vault.setInventoryBounds(1e18, 1e18, 500_000, 500_000);
        vm.stopPrank();
        uint256 c = _bucketNow();
        uint256 id = _reserveIn(keyM, c0, uint128(vault.admissibleCapacity(c0)), c + 6);
        (,,, uint256 rid) = _redeem(lp0, vault.sharesOf(lp0), true);
        assertGt(rid, 0);
        adapter.setBroken(true);
        mal.configure(MaliciousConsumerHook.Attack.ExactAmounts, id, 1 ether);
        vm.expectRevert();
        _swapRaw(keyM, false, -int256(2 ether), "");
        uint256 q = vault.reserved(c0);
        assertGt(q, 0);
        vm.warp((c + 6) * H - 1);
        vault.processQueue(10);
        assertEq(vault.reserved(c0), q, "live: stays reserved through the outage");
        vm.warp((c + 6) * H);
        vault.processQueue(10);
        assertEq(vault.reserved(c0), 0, "expiry recognized with the adapter broken");
        assertEq(vault.pendingShares(), 0, "the queue finalized with the adapter broken");
        vm.prank(lp0);
        vault.claim(rid);
        _assertEquations();
    }

    /// @notice 100 days without any call, then a single redeem: every recorded bucket has ended, so its sweep zeroes Q
    ///         in O(1) and the whole balance exits instantly.
    function test_longInactivity_singleRedeemExitsEverything() public {
        uint256 c = _bucketNow();
        _reserveIn(keyM, c0, 600_000 ether, c + 700);
        _reserveIn(keyA, c1, 900_000 ether, c + 300);
        assertLt(lens.deliverableShares(vault), vault.sharesOf(lp0) / 2);
        vm.warp(_now() + 100 days);
        uint256 shares = vault.sharesOf(lp0);
        (uint256 instant,,, uint256 rid) = _redeem(lp0, shares, false);
        assertEq(instant, shares, "everything instant");
        assertEq(rid, 0);
        assertEq(vault.reserved(c0), 0);
        assertEq(vault.reserved(c1), 0);
    }

    /// @notice A reservation renewed every 40 hours keeps maxBucket ahead of the clock, so sweeps walk 32 buckets per
    ///         call and fall 8 buckets further behind per renewal. Q stays between the live and lazy sums throughout,
    ///         and `processQueue(0)` calls by anyone catch it up exactly.
    function test_renewedReservations_sweepFallsBehind_butStaysBoundedAndConverges() public {
        uint256[] memory ids = new uint256[](30);
        for (uint256 k; k < 30; ++k) {
            ids[k] = _reserveIn(keyM, c1, 1000 ether + k, (_now() + 30 days) / H);
            _assertBounds(c1);
            vm.warp(_now() + 40 hours);
        }
        (uint64 sw,) = lens.expiryRing(vault, c1);
        assertLt(sw + 32, _bucketNow(), "the ring is behind");
        (uint256 live,) = _sums(c1);
        assertGt(vault.reserved(c1), live, "conservative: expired capacity still counted");
        uint256 calls;
        while (vault.reserved(c1) != live) {
            _sweep();
            ++calls;
            _assertBounds(c1);
        }
        assertGt(calls, 1);
        assertLe(calls, (_bucketNow() - sw + 31) / 32, "ceil(backlog / 32) calls");
    }

    /// @notice Griefing with many small reservations in distinct buckets: a sweep walks at most 32 buckets whatever
    ///         they hold, so its cost stays bounded (paid by the caller of the sweeping function).
    function test_sweepCost_boundedWithEveryBucketPopulated() public {
        uint256 c = _bucketNow();
        for (uint256 i = 1; i <= 40; ++i) {
            _reserveIn(keyM, c0, 1, c + i);
        }
        _reserveIn(keyM, c0, 1, c + 720);
        vm.warp((c + 40) * H);
        vm.cool(address(vault));
        uint256 g = gasleft();
        _sweep();
        uint256 used = g - gasleft();
        emit log_named_uint("processQueue(0) walking 32 populated buckets per asset, gas", used);
        assertLt(used, 200_000, "bounded");
        assertEq(vault.reserved(c0), 1 + 8, "32 buckets subtracted; 8 ended ones and the far one left");
    }
}
