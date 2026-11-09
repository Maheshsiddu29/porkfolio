// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @notice Regression and boundary tests for `admissibleCapacity` and the admission check in `allocate`.
/// @dev The defect these tests pin down: capacity used to be computed as N - (Q + R + D). R (the buffer floor) is an
///      unbounded admin input, and the guardian is allowed to raise it to any value, so Q + R + D could overflow and
///      `admissibleCapacity` and `allocate` reverted with an arithmetic panic (0x11) instead of returning 0 and
///      `InsufficientBacking`. The fixed computation subtracts each term with a floor at zero.
///
///      Reference model. `_reference` computes max(0, N - (Q + R + D)) exactly by forming Q + R + D as a two-limb
///      (carry, low) sum and comparing it with N. It shares no code path with the vault: no sequential
///      subtraction, no `FullMath` (D is recomputed from P, N, S with plain arithmetic that cannot overflow for
///      amounts within MAX_AMOUNT).
contract AdmissibleCapacityTest is VaultTestBase {
    using stdStorage for StdStorage;

    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant MAX_AMOUNT = uint256(uint128(type(int128).max));

    address internal guardian = makeAddr("guardian");

    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        vault.setGuardian(guardian);
    }

    // ------------------------------------------------------------------
    // Reference model
    // ------------------------------------------------------------------

    /// @dev Exact max(0, n - (q + r + d)) without overflow: (hi, lo) is the 257+-bit sum q + r + d.
    function _reference(uint256 n, uint256 q, uint256 r, uint256 d) internal pure returns (uint256) {
        uint256 hi;
        uint256 lo;
        unchecked {
            lo = q + r;
            if (lo < q) ++hi;
            uint256 lo2 = lo + d;
            if (lo2 < lo) ++hi;
            lo = lo2;
        }
        if (hi != 0 || lo >= n) return 0;
        return n - lo;
    }

    /// @dev Independent D = ceil(p * n / s). Requires p, n <= 2^127 and s >= 1, so p * n + s - 1 < 2^255.
    function _referenceDemand(uint256 p, uint256 n, uint256 s) internal pure returns (uint256) {
        if (p == 0) return 0;
        return (p * n + s - 1) / s;
    }

    /// @dev Reference capacity of `c` computed from the vault's raw storage values.
    function _referenceFor(Currency c) internal view returns (uint256) {
        uint256 n = vault.backing(c) - vault.claimableAssets(c);
        uint256 d = _referenceDemand(vault.pendingShares(), n, vault.totalShares());
        return _reference(n, vault.reserved(c), vault.bufferFloor(c), d);
    }

    /// @dev Sanity checks on the reference model itself, so a wrong model cannot make the fuzz tests vacuous.
    function test_AC_referenceModel_selfCheck() public pure {
        assertEq(_reference(1000, 300, 100, 150), 450, "documented example");
        assertEq(_reference(1000, 1000, 0, 0), 0);
        assertEq(_reference(1000, 999, 0, 0), 1);
        assertEq(_reference(1000, 0, MAX, 0), 0);
        assertEq(_reference(1000, 1, MAX, 0), 0, "single carry");
        assertEq(_reference(1000, MAX, MAX, MAX), 0, "double carry");
        assertEq(_reference(MAX, 0, MAX - 1, 0), 1);
        assertEq(_referenceDemand(300, 1001, 1000), 301, "ceil(300.3)");
        assertEq(_referenceDemand(0, 1001, 1000), 0);
    }

    // ------------------------------------------------------------------
    // Regression: unbounded buffer floor
    // ------------------------------------------------------------------

    /// @notice The guardian may only raise the buffer floor, and raising it to type(uint256).max is a legitimate
    ///         "stop all new allocations in this asset" action. It must read as zero capacity and make `allocate`
    ///         fail with the meaningful `InsufficientBacking`, not an arithmetic panic.
    function test_AC_guardianMaxBufferFloor_zeroCapacity_meaningfulRevert() public {
        _allocate(keyA, c1, 1000 ether); // Q > 0 so Q + R overflows even without pending demand
        vm.prank(guardian);
        vault.setBufferFloor(c1, MAX);

        assertEq(vault.admissibleCapacity(c1), 0);

        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, 1);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientBacking.selector, 1, 0));
        auth.activateDirect(req);

        // The other asset is unaffected.
        assertEq(vault.admissibleCapacity(c0), _referenceFor(c0));
        assertGt(vault.admissibleCapacity(c0), 0);
    }

    /// @notice Every buffer floor at or near the top of the range, with Q > 0 and D > 0, gives zero capacity and
    ///         no panic. R = MAX - Q - D is the largest value whose sum Q + R + D does not overflow; one more
    ///         overflows by exactly one.
    function test_AC_bufferFloorNearMax_withReservedAndPending() public {
        _setUpReservedAndPending();
        uint256 q = vault.reserved(c1);
        uint256 d = lens.pendingDemand(vault, c1);
        assertGt(q, 0, "fixture: Q > 0");
        assertGt(d, 0, "fixture: D > 0");

        uint256[6] memory floors = [MAX, MAX - 1, MAX - q - d, MAX - q - d + 1, MAX - q, MAX - d];
        for (uint256 i; i < floors.length; ++i) {
            vm.prank(owner);
            vault.setBufferFloor(c1, floors[i]);
            assertEq(vault.admissibleCapacity(c1), 0, "capacity must be 0");

            ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, 1);
            vm.prank(curator);
            vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientBacking.selector, 1, 0));
            auth.activateDirect(req);
        }
    }

    // ------------------------------------------------------------------
    // Exact boundaries are preserved
    // ------------------------------------------------------------------

    /// @notice With Q, R and D all non-zero, the admission rule Q + q + R + D <= N admits exactly the largest q
    ///         that fits: allocating `cap` succeeds, after which capacity is 0 and one more unit is refused;
    ///         a buffer floor one unit higher refuses `cap` and reports `cap - 1` as available.
    function test_AC_exactBoundary_withAllTermsNonZero() public {
        _setUpReservedAndPending();
        uint256 n = lens.netAssets(vault, c1);
        uint256 q = vault.reserved(c1);
        uint256 d = lens.pendingDemand(vault, c1);
        uint256 cap = 777 ether;
        uint256 r = n - q - d - cap;

        // One unit too much buffer: cap no longer fits.
        vm.prank(owner);
        vault.setBufferFloor(c1, r + 1);
        assertEq(vault.admissibleCapacity(c1), cap - 1);
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, uint128(cap));
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientBacking.selector, cap, cap - 1));
        auth.activateDirect(req);

        // Exact fit.
        vm.prank(owner);
        vault.setBufferFloor(c1, r);
        assertEq(vault.admissibleCapacity(c1), cap);
        _allocate(keyA, c1, uint128(cap));
        assertEq(vault.admissibleCapacity(c1), 0);
        assertEq(
            vault.reserved(c1) + vault.bufferFloor(c1) + lens.pendingDemand(vault, c1), n, "Q + R + D == N exactly"
        );

        req = _request(keyA, c1, 1);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientBacking.selector, 1, 0));
        auth.activateDirect(req);
    }

    // ------------------------------------------------------------------
    // Fuzz: independent Q, R, D and backing against the reference
    // ------------------------------------------------------------------

    /// @notice Arbitrary, independent storage values (Q and R anywhere in uint256, including values that break the
    ///         vault's own invariant Q <= N). The view must never revert and must equal the exact reference.
    ///         Backing stays within MAX_AMOUNT and P <= S, W <= B, because the vault enforces those on every path
    ///         and `netAssets`/`pendingDemand` rely on them.
    function testFuzz_AC_independentValues_matchReference(
        uint256 b,
        uint256 w,
        uint256 q,
        uint256 r,
        uint256 s,
        uint256 p
    ) public {
        b = bound(b, 0, MAX_AMOUNT);
        w = bound(w, 0, b);
        s = bound(s, 1, MAX_AMOUNT);
        p = bound(p, 0, s);
        _write(c1, b, w, q, r, s, p);

        uint256 n = b - w;
        uint256 d = _referenceDemand(p, n, s);
        assertEq(lens.pendingDemand(vault, c1), d, "D matches the independent ceil");
        assertEq(vault.admissibleCapacity(c1), _reference(n, q, r, d), "capacity matches reference");
    }

    /// @notice The state space the vault can actually reach (Q <= N, D <= N) with R anywhere in uint256. Where the
    ///         old formula N - (Q + R + D) did not overflow, the new result is identical to it, so no valid
    ///         boundary moved. Where it overflowed, the result is 0.
    function testFuzz_AC_reachableValues_equalOldFormulaWhenNoOverflow(
        uint256 b,
        uint256 w,
        uint256 q,
        uint256 r,
        uint256 s,
        uint256 p,
        bool hugeR
    ) public {
        b = bound(b, 0, MAX_AMOUNT);
        w = bound(w, 0, b);
        uint256 n = b - w;
        q = bound(q, 0, n);
        s = bound(s, 1, MAX_AMOUNT);
        p = bound(p, 0, s);
        r = hugeR ? bound(r, MAX - 2 * MAX_AMOUNT - 2, MAX) : bound(r, 0, n + 1);
        _write(c1, b, w, q, r, s, p);

        uint256 d = _referenceDemand(p, n, s);
        uint256 got = vault.admissibleCapacity(c1);
        assertEq(got, _reference(n, q, r, d));

        (bool overflow, uint256 sum) = _tryAdd3(q, r, d);
        if (!overflow) assertEq(got, sum >= n ? 0 : n - sum, "old formula, where it was defined");
        else assertEq(got, 0);
    }

    /// @notice End to end through `allocate` on real state (a live allocation and a real queued redemption): for a
    ///         random buffer floor and request size, `allocate` succeeds exactly when the request fits the reference
    ///         capacity, and otherwise reverts with `InsufficientBacking(requested, reference)`.
    function testFuzz_AC_allocateAgreesWithReference(uint256 r, uint256 maxOut, bool hugeR) public {
        _setUpReservedAndPending();
        uint256 n = lens.netAssets(vault, c1);
        r = hugeR ? bound(r, MAX - 4 * MAX_AMOUNT, MAX) : bound(r, 0, n);
        vm.prank(owner);
        vault.setBufferFloor(c1, r);

        uint256 expected = _referenceFor(c1);
        assertEq(vault.admissibleCapacity(c1), expected);

        maxOut = bound(maxOut, 1, n + 1);
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, uint128(maxOut));
        vm.prank(owner);
        vault.setCuratorCeiling(curator, c1, MAX); // isolate the admission rule from the curator ceiling
        uint256 qBefore = vault.reserved(c1);

        vm.prank(curator);
        if (maxOut > expected) {
            vm.expectRevert(
                abi.encodeWithSelector(ISharedCommitmentVault.InsufficientBacking.selector, maxOut, expected)
            );
            auth.activateDirect(req);
            assertEq(vault.reserved(c1), qBefore);
        } else {
            auth.activateDirect(req);
            assertEq(vault.reserved(c1), qBefore + maxOut);
            assertLe(
                vault.reserved(c1) + vault.bufferFloor(c1) + lens.pendingDemand(vault, c1), n, "admission rule held"
            );
        }
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Real state with Q_1 > 0, D_1 > 0 and room left (Q_1 + D_1 < N_1), reached only through public calls:
    ///      a curator reserves all admissible asset1, so an LP's redemption has no free asset1 and is queued in full;
    ///      the owner then releases that allocation early (the queue is not processed, so P stays) and the curator
    ///      reserves a smaller amount. End state: N1 = 1.2M, Q1 = 300k, D1 = 200k (ether units).
    function _setUpReservedAndPending() internal {
        vm.prank(owner);
        vault.setCuratorCeiling(curator, c1, MAX);
        address lp = makeAddr("lpQueue");
        _depositShares(lp, 200_000 ether);

        uint256 blocker = _allocate(keyA, c1, uint128(vault.admissibleCapacity(c1)));
        (uint256 instant,,, uint256 requestId) = _redeem(lp, 200_000 ether, true);
        assertEq(instant, 0, "fixture: nothing instant");
        assertGt(requestId, 0, "fixture: request queued");

        vm.prank(owner);
        vault.release(blocker);
        _allocate(keyA, c1, 300_000 ether);

        assertGt(vault.pendingShares(), 0, "fixture: P > 0");
        assertGt(lens.netAssets(vault, c1), vault.reserved(c1) + lens.pendingDemand(vault, c1), "fixture: room left");
    }

    function _write(Currency c, uint256 b, uint256 w, uint256 q, uint256 r, uint256 s, uint256 p) internal {
        address a = Currency.unwrap(c);
        stdstore.target(address(vault)).sig("backing(address)").with_key(a).checked_write(b);
        stdstore.target(address(vault)).sig("claimableAssets(address)").with_key(a).checked_write(w);
        stdstore.target(address(vault)).sig("reserved(address)").with_key(a).checked_write(q);
        stdstore.target(address(vault)).sig("bufferFloor(address)").with_key(a).checked_write(r);
        stdstore.target(address(vault)).sig("totalShares()").checked_write(s);
        stdstore.target(address(vault)).sig("pendingShares()").checked_write(p);
    }

    function _tryAdd3(uint256 x, uint256 y, uint256 z) internal pure returns (bool overflow, uint256 sum) {
        unchecked {
            sum = x + y;
            if (sum < x) return (true, 0);
            uint256 sum2 = sum + z;
            if (sum2 < sum) return (true, 0);
            return (false, sum2);
        }
    }
}
