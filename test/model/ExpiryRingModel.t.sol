// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ExpiryRingModel, ExpiryRingGasHarness} from "./ExpiryRingModel.sol";

/// @notice Checks of the PROPOSED bucketed expiry ring (G05_V2_ARCHITECTURE.md §3.5) on a test-only model. They say
///         nothing about `src/`, whose expiry is still lazy (`release`).
/// @dev The small-K tests use K = 4 one-hour buckets, so wrap-around, slot reuse and long gaps are reached in a few
///      steps. The gas tests use the two candidate sizes: one-hour buckets (K = 720) and one-day buckets (K = 30),
///      both with a 30-day horizon.
contract ExpiryRingModelTest is Test {
    uint256 internal constant H = 1 hours;
    uint256 internal constant T0 = 1_800_000_000; // an hour boundary (500,000 h); not a day boundary

    function setUp() public {
        vm.warp(T0);
    }

    function _small() internal returns (ExpiryRingModel m) {
        m = new ExpiryRingModel(H, 4, 2);
    }

    function _at(uint256 hoursFromT0) internal pure returns (uint64) {
        return uint64(T0 + hoursFromT0 * H);
    }

    /// @notice Capacity is out of Q at its expiry second with no transaction (view), and out of the stored total after
    ///         the next sweep. One second earlier it is still live and consumable.
    function test_expiryWithoutAnyCall_exactBoundary() public {
        ExpiryRingModel m = _small();
        uint256 id = m.reserve(100, _at(2));

        vm.warp(T0 + 2 * H - 1);
        assertEq(m.liveTotal(), 100, "live one second before expiry");
        m.consume(id, 10); // still consumable
        assertEq(m.liveTotal(), 90);

        vm.warp(T0 + 2 * H);
        assertEq(m.liveTotal(), 0, "expired at its expiry second, no transaction");
        assertEq(m.total(), 90, "stored total unchanged until a sweep");
        vm.expectRevert(ExpiryRingModel.Expired.selector);
        m.consume(id, 1);

        m.readerSweep();
        assertEq(m.total(), 0, "a sweep removes it");
        assertEq(m.refUnreleased(), 90, "today's lazy Q would still hold the unreleased 90");
    }

    /// @notice A slot is reused after wrap-around: bucket b and bucket b + K share slot b % K. The tag keeps the
    ///         expired bucket from being counted again or subtracted twice.
    function test_slotReuseAfterWrap_isExact() public {
        ExpiryRingModel m = _small();
        m.reserve(50, _at(1)); // bucket b, slot b % 4
        vm.warp(T0 + 1 * H); // b expires; nobody sweeps
        uint256 id2 = m.reserve(70, _at(5)); // bucket b + 4: same slot
        assertEq(m.total(), 70, "writer swept b, then overwrote its slot");
        assertEq(m.liveTotal(), 70);
        m.close(id2);
        assertEq(m.total(), 0);
    }

    /// @notice The eviction branch: a write that finds an expired, unswept bucket in its slot subtracts it once; a
    ///         later sweep and a later close of the evicted reservation both leave the total alone.
    function test_eviction_subtractsOnce() public {
        ExpiryRingModel m = _small();
        uint256 a = m.reserve(50, _at(1));
        m.reserve(30, _at(3)); // keeps maxBucket ahead so no shortcut applies
        vm.warp(T0 + 1 * H);
        m.reserveWithoutSweep(70, _at(5)); // same slot as `a`
        assertEq(m.total(), 30 + 70, "evicted 50 subtracted at the write");
        m.readerSweep(); // walks bucket of `a`: tag no longer matches
        assertEq(m.total(), 100, "sweep does not subtract the evicted bucket again");
        m.close(a);
        assertEq(m.total(), 100, "closing the evicted reservation does not subtract again");
        assertEq(m.liveTotal(), m.refLive());
    }

    /// @notice Close before the sweep reduces the bucket; the sweep then removes only what remains. Close after the
    ///         sweep changes nothing.
    function test_closeBeforeAndAfterSweep() public {
        ExpiryRingModel m = _small();
        uint256 a = m.reserve(40, _at(1));
        uint256 b = m.reserve(60, _at(1)); // same bucket
        m.reserve(5, _at(4));
        vm.warp(T0 + 1 * H);
        m.close(a); // expired, unswept: subtract from the bucket
        assertEq(m.total(), 65);
        m.readerSweep();
        assertEq(m.total(), 5, "sweep removed the 60 left in the bucket");
        m.close(b); // swept already
        assertEq(m.total(), 5);
    }

    /// @notice After a gap longer than the horizon every bucket ever written has expired: the sweep is O(1) and the
    ///         total is zero, whatever the step cap.
    function test_longGap_shortcut() public {
        ExpiryRingModel m = _small();
        m.reserve(10, _at(4));
        m.reserve(20, _at(2));
        vm.warp(T0 + 1000 * H);
        m.readerSweep();
        assertEq(m.total(), 0);
        assertEq(m.swept(), m.nowBucket());
    }

    /// @notice A capped reader sweep leaves the total between the live sum and today's lazy sum, and repeated
    ///         sweeps reach the live sum.
    function test_readerCap_isConservative() public {
        ExpiryRingModel m = new ExpiryRingModel(H, 8, 1);
        for (uint256 i = 1; i <= 8; ++i) {
            m.reserve(uint128(i), _at(i));
        }
        vm.warp(T0 + 5 * H); // buckets 1..5 expired: 15 of 36 should leave
        m.readerSweep();
        assertEq(m.total(), 35, "one step: bucket 1 only");
        assertGe(m.total(), m.refLive());
        assertLe(m.total(), m.refUnreleased());
        for (uint256 i; i < 4; ++i) {
            m.readerSweep();
        }
        assertEq(m.total(), m.refLive(), "converged");
        assertEq(m.total(), 36 - 15);
    }

    /// @notice Differential fuzz against the reference ledger over random schedules of reserve, consume, close,
    ///         reader sweeps, writes without sweeps and time jumps of up to twice the horizon. After every step:
    ///         the view equals the reference live sum exactly, and the stored total lies between the live sum and
    ///         the lazy sum.
    function testFuzz_ringMatchesReference(uint256 seed) public {
        ExpiryRingModel m = new ExpiryRingModel(H, 6, 2);
        uint256 ops;
        for (uint256 step; step < 80; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 kind = seed % 7;
            uint256 n = m.count();
            if (kind <= 1) {
                uint256 hrs = 1 + (seed >> 8) % 6; // 1..K hours ahead of the current bucket
                uint64 expiry = uint64((m.nowBucket() + hrs) * H);
                uint128 amount = uint128(1 + (seed >> 16) % 1000);
                if (kind == 0) m.reserve(amount, expiry);
                else m.reserveWithoutSweep(amount, expiry);
                ++ops;
            } else if (kind == 2 && n != 0) {
                uint256 id = (seed >> 8) % n;
                ExpiryRingModel.Reservation memory r = m.get(id);
                if (r.closed || vm.getBlockTimestamp() >= r.expiry || r.remaining == 0) continue;
                m.consume(id, uint128(1 + (seed >> 24) % r.remaining));
                ++ops;
            } else if (kind == 3 && n != 0) {
                uint256 id = (seed >> 8) % n;
                if (m.get(id).closed) continue;
                m.close(id);
                ++ops;
            } else if (kind == 4) {
                m.readerSweep();
            } else {
                vm.warp(vm.getBlockTimestamp() + (seed >> 8) % (12 * H));
            }
            assertEq(m.liveTotal(), m.refLive(), "view == reference live sum");
            assertGe(m.total(), m.refLive(), "stored total never below live");
            assertLe(m.total(), m.refUnreleased(), "stored total never above lazy sum");
        }
        assertGt(ops, 0);
    }

    // ------------------------------------------------------------------
    // Gas (harness only; see the design note §8 for what these numbers do and do not say about a vault)
    // ------------------------------------------------------------------

    function _gasOf(address target, bytes memory data) internal returns (uint256 used) {
        vm.cool(target);
        uint256 g = gasleft();
        (bool ok,) = target.call(data);
        used = g - gasleft();
        require(ok, "call failed");
    }

    /// @notice Cold-storage gas of each ring operation at both candidate sizes, measured as the whole call into the
    ///         harness, next to `plainAdd` (today's single running total). Printed for the design note; asserted
    ///         only for the properties the design relies on.
    function test_gas_operations() public {
        _gasReport("1h buckets, K = 720, step cap 32", H, 720, 32);
        _gasReport("1d buckets, K = 30, step cap 30", 1 days, 30, 30);
    }

    function _gasReport(string memory label, uint256 width, uint256 k, uint256 steps) internal {
        vm.warp(T0);
        ExpiryRingGasHarness m = new ExpiryRingGasHarness(width, k, steps);
        address t = address(m);
        uint256 c = vm.getBlockTimestamp() / width;
        uint256 e1 = (c + 1) * width;

        m.plainAdd(1); // make `total` non-zero so that both sides compare non-zero to non-zero stores
        uint256 plain = _gasOf(t, abi.encodeCall(m.plainAdd, (100)));
        uint256 reserveFresh = _gasOf(t, abi.encodeCall(m.reserve, (100, e1)));
        uint256 reserveSameBucket = _gasOf(t, abi.encodeCall(m.reserve, (100, e1)));
        m.reserve(1, (c + k) * width); // a live bucket at the far end, so that no shortcut applies below
        uint256 removeGas = _gasOf(t, abi.encodeCall(m.remove, (e1, 10)));
        uint256 sweepNothing = _gasOf(t, abi.encodeCall(m.readerSweep, ()));

        vm.warp(e1); // one bucket expired
        uint256 sweepOne = _gasOf(t, abi.encodeCall(m.readerSweep, ()));

        // A slot that held an older, swept bucket: bucket c + 1 + k shares bucket c + 1's slot.
        uint256 reserveReuse = _gasOf(t, abi.encodeCall(m.reserve, (5, (c + 1 + k) * width)));

        // Worst case for any path: a full step cap of buckets to walk (k - 2 at most, so the far bucket stays live).
        uint256 walk = steps < k - 2 ? steps : k - 2;
        vm.warp(vm.getBlockTimestamp() + walk * width);
        uint256 sweepCap = _gasOf(t, abi.encodeCall(m.readerSweep, ()));
        vm.warp(vm.getBlockTimestamp() + walk * width);
        uint256 reserveCap = _gasOf(t, abi.encodeCall(m.reserve, (5, (vm.getBlockTimestamp() / width + 1) * width)));

        // Shortcut: everything ever written has expired.
        vm.warp(vm.getBlockTimestamp() + 3 * k * width);
        uint256 sweepShortcut = _gasOf(t, abi.encodeCall(m.readerSweep, ()));

        emit log_string(label);
        emit log_named_uint("  plain running total (today)", plain);
        emit log_named_uint("  reserve, fresh slot", reserveFresh);
        emit log_named_uint("  reserve, same bucket", reserveSameBucket);
        emit log_named_uint("  reserve, reused slot", reserveReuse);
        emit log_named_uint("  reserve, full step cap to sweep", reserveCap);
        emit log_named_uint("  remove (consume / close)", removeGas);
        emit log_named_uint("  sweep, nothing expired", sweepNothing);
        emit log_named_uint("  sweep, one bucket", sweepOne);
        emit log_named_uint("  sweep, full step cap", sweepCap);
        emit log_named_uint("  sweep, shortcut", sweepShortcut);

        assertLt(sweepShortcut, sweepOne + 5000, "shortcut is O(1)");
        assertLt(
            reserveCap, sweepCap + reserveFresh, "a write costs at most one capped sweep plus one fresh slot write"
        );
    }
}
