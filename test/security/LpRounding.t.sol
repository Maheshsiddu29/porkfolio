// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {MaliciousConsumerHook} from "../utils/MaliciousConsumerHook.sol";
import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {VaultStateReader} from "../../src/libraries/VaultStateReader.sol";

using VaultStateReader for SharedCommitmentVault;

/// @notice Rounding when one LP position leaves in several pieces: split instant redemptions and queue finalization
///         in several slices.
/// @dev The shared fixture holds 1e24 of each asset against 1e24 shares, so one share is worth exactly one raw unit and
///      no rounding is ever visible. `setUp` shrinks the vault to 11,000 shares and runs one trade above the floor, so
///      a share is worth 1.707 raw asset0 and 0.697 raw asset1. Every payout then loses a visible fraction of a unit.
///
///      What is proven (docs/security/G03_LP_ACCOUNTING.md §4.4): with only the LP's own pieces in between, the pieces
///      together pay no more than the same shares redeemed at once, and at most k - 1 raw units less per asset for k
///      pieces. Upper bound: no LP operation lowers N_a / S, so after the pieces N_a - T >= (S - s) * N_a / S, i.e.
///      T <= s * N_a / S, and T is an integer. Lower bound: each piece pays more than its exact share at the starting
///      rate minus one unit. The units the LP loses stay with the remaining shares.
contract LpRoundingTest is VaultTestBase {
    uint160 internal constant SWAP_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

    address internal lpA = makeAddr("lpA");
    MaliciousConsumerHook internal mal;
    PoolKey internal keyM;

    function setUp() public override {
        super.setUp();
        address m = address(uint160(0xBAD5 << 140) | SWAP_FLAGS);
        deployCodeTo("MaliciousConsumerHook.sol:MaliciousConsumerHook", abi.encode(manager, vault), m);
        mal = MaliciousConsumerHook(m);
        keyM = PoolKey(c0, c1, 3000, 60, IHooks(m));
        manager.initialize(keyM, SQRT_PRICE_1_1);
        vm.startPrank(owner);
        vault.setConsumer(m, true);
        _openLimits(ISharedCommitmentVault.RiskScope.Hook, m);
        vm.stopPrank();

        // S = 11,000 and N0 = N1 = 11,000; then the vault sells 3,333 asset1 for 7,777 asset0 (above the 1:1 floor).
        _redeem(lp0, vault.sharesOf(lp0) - 10_000, false);
        _tradeAt(c1, 3333, 7777);
        assertEq(vault.totalShares(), 11_000);
        assertEq(lens.netAssets(vault, c0), 18_777);
        assertEq(lens.netAssets(vault, c1), 7667);
    }

    /// @dev The registered test hook sells exactly `amountOut` of `out` for exactly `amountIn` of the other asset.
    function _tradeAt(Currency out, uint256 amountOut, uint256 amountIn) internal {
        uint256 id = _allocate(keyM, out, uint128(amountOut));
        mal.configure(MaliciousConsumerHook.Attack.ExactAmounts, id, amountOut);
        _swapRaw(keyM, out == c1, -int256(amountIn), "");
    }

    /// @dev N0 * S_before >= N0_before * S (both assets): the per-share basket did not fall.
    function _assertNoDilution(uint256 n0, uint256 n1, uint256 s) internal view {
        uint256 sNow = vault.totalShares();
        assertGe(lens.netAssets(vault, c0) * s, n0 * sNow, "asset0 per share fell");
        assertGe(lens.netAssets(vault, c1) * s, n1 * sNow, "asset1 per share fell");
    }

    /// @notice Splitting an instant redemption into k pieces never pays more than redeeming once, and pays at most
    ///         k - 1 raw units less of each asset.
    /// @dev If splitting could pay more, an LP could extract the remaining holders' share of rounding by redeeming
    ///      one share at a time. Both branches start from the same state (a snapshot), so the comparison is exact.
    function testFuzz_splitInstantRedemption_neverPaysMoreThanOneShot(uint256 shares, uint256 pieces, uint256 seed)
        public
    {
        shares = bound(shares, 2, 50_000);
        pieces = bound(pieces, 2, 12);
        if (pieces > shares) pieces = shares;
        _depositShares(lpA, shares);

        uint256 snap = vm.snapshotState();
        (uint256 all, uint256 one0, uint256 one1,) = _redeem(lpA, shares, false);
        assertEq(all, shares, "nothing reserved: the whole position is instant");
        vm.revertToState(snap);

        uint256 got0;
        uint256 got1;
        uint256 left = shares;
        for (uint256 i; i < pieces; ++i) {
            // Pseudo-random piece sizes, each at least 1, summing to `shares`.
            uint256 piece =
                i == pieces - 1 ? left : 1 + uint256(keccak256(abi.encode(seed, i))) % (left - (pieces - i) + 1);
            left -= piece;
            uint256 n0 = lens.netAssets(vault, c0);
            uint256 n1 = lens.netAssets(vault, c1);
            uint256 s = vault.totalShares();
            (, uint256 a0, uint256 a1,) = _redeem(lpA, piece, false);
            got0 += a0;
            got1 += a1;
            _assertNoDilution(n0, n1, s);
        }
        assertEq(left, 0);
        assertLe(got0, one0, "split paid more asset0");
        assertLe(got1, one1, "split paid more asset1");
        assertLe(one0 - got0, pieces - 1, "asset0 loss above k - 1 units");
        assertLe(one1 - got1, pieces - 1, "asset1 loss above k - 1 units");
        _assertEquations();
    }

    /// @notice A queued request finalized in several slices, as reserved capacity is released piece by piece, is paid
    ///         no more than the same request finalized in one slice, and at most (slices - 1) raw units less per asset.
    ///         A slice can pay zero of one asset: here the first slice is one share, worth 1.707 asset0 and 0.697
    ///         asset1, and pays (1, 0).
    /// @dev The slice count is not the LP's choice. Whoever frees inventory in small steps (a curator releasing small
    ///      allocations, depositors, a keeper calling `processQueue` after each release) decides it. The cost to the
    ///      request is under one raw unit per asset per slice, and the units it loses go to every remaining share
    ///      pro rata, so the party choosing the slice count gains only its own pro-rata part of them.
    function test_queueSlices_roundingBoundedBySliceCount() public {
        _depositShares(lpA, 5000); // S = 16,000; N0 = 27,312; N1 = 11,152
        assertEq(lens.netAssets(vault, c0), 27_312);
        assertEq(lens.netAssets(vault, c1), 11_152);

        // Reserve every unit of asset1 in five allocations, so nothing of the request is deliverable.
        uint128[5] memory chunks = [uint128(1), 1, 7, 1000, 0];
        chunks[4] = uint128(11_152 - 1009);
        uint256[5] memory ids;
        for (uint256 i; i < 5; ++i) {
            ids[i] = _allocate(keyA, c1, chunks[i]);
        }
        (uint256 instant,,, uint256 req) = _redeem(lpA, 5000, true);
        assertEq(instant, 0, "asset1 fully reserved");

        // One slice: release everything, then finalize.
        uint256 snap = vm.snapshotState();
        vm.startPrank(owner);
        for (uint256 i; i < 5; ++i) {
            vault.release(ids[i]);
        }
        vm.stopPrank();
        assertEq(vault.processQueue(1), 5000);
        ISharedCommitmentVault.WithdrawalRequest memory once = vault.getRequest(req);
        assertEq(once.claimable0, FullMath.mulDiv(5000, 27_312, 16_000)); // floor(8,535) = 8,535
        assertEq(once.claimable1, FullMath.mulDiv(5000, 11_152, 16_000)); // floor(3,485) = 3,485
        vm.revertToState(snap);

        // Several slices: release one allocation at a time and finalize after each.
        uint256 slices;
        uint256 pendingBefore = 5000;
        for (uint256 i; i < 5; ++i) {
            uint256 claimable1Before = vault.getRequest(req).claimable1;
            uint256 claimable0Before = vault.getRequest(req).claimable0;
            vm.prank(owner);
            vault.release(ids[i]);
            uint256 n0 = lens.netAssets(vault, c0);
            uint256 n1 = lens.netAssets(vault, c1);
            uint256 s = vault.totalShares();
            vault.processQueue(1);
            _assertNoDilution(n0, n1, s);
            uint256 pendingNow = vault.getRequest(req).sharesPending;
            if (pendingNow < pendingBefore) ++slices;
            if (i == 0) {
                // First slice: freeing one unit of asset1 makes floor(1 * 16,000 / 11,152) = 1 share deliverable,
                // and that share pays floor(1.707) = 1 asset0 and floor(0.697) = 0 asset1.
                assertEq(pendingBefore - pendingNow, 1, "one-share slice");
                assertEq(vault.getRequest(req).claimable0 - claimable0Before, 1);
                assertEq(vault.getRequest(req).claimable1 - claimable1Before, 0, "slice paid no asset1");
            }
            pendingBefore = pendingNow;
        }
        ISharedCommitmentVault.WithdrawalRequest memory sliced = vault.getRequest(req);
        assertEq(sliced.sharesPending, 0);
        assertEq(slices, 5);
        assertLe(sliced.claimable0, once.claimable0, "slices paid more asset0");
        assertLe(sliced.claimable1, once.claimable1, "slices paid more asset1");
        assertLe(once.claimable0 - sliced.claimable0, slices - 1);
        assertLe(once.claimable1 - sliced.claimable1, slices - 1);
        // The units the request lost stayed in N_a for the 11,000 remaining shares.
        assertEq(lens.netAssets(vault, c0), 27_312 - sliced.claimable0);
        assertEq(lens.netAssets(vault, c1), 11_152 - sliced.claimable1);
        emit log_named_uint("one slice: asset0", once.claimable0);
        emit log_named_uint("one slice: asset1", once.claimable1);
        emit log_named_uint("five slices: asset0", sliced.claimable0);
        emit log_named_uint("five slices: asset1", sliced.claimable1);
        _assertEquations();
    }

    /// @notice Deposit then redeem k times in a row: each round trip loses at most one raw unit per asset and never
    ///         gains, and the per-share basket of the remaining holders never falls.
    /// @dev The repeated form of `testFuzz_depositRedeemRoundTrip_neverProfitable`, at a basket where every payout
    ///      rounds. It shows the round-trip loss does not compound into a gain for the LP however often it repeats.
    function testFuzz_repeatedRoundTrips_neverGain(uint256 shares, uint256 rounds) public {
        shares = bound(shares, 1, 20_000);
        rounds = bound(rounds, 1, 10);
        uint256 paid0;
        uint256 paid1;
        uint256 got0;
        uint256 got1;
        for (uint256 i; i < rounds; ++i) {
            uint256 n0 = lens.netAssets(vault, c0);
            uint256 n1 = lens.netAssets(vault, c1);
            uint256 s = vault.totalShares();
            (uint256 p0, uint256 p1) = _depositShares(lpA, shares);
            _assertNoDilution(n0, n1, s);
            // Checked against the state just after the deposit, so a redemption that rounded up would fail here even
            // though the deposit's round-up would hide it from a whole-round-trip comparison.
            n0 = lens.netAssets(vault, c0);
            n1 = lens.netAssets(vault, c1);
            s = vault.totalShares();
            (, uint256 a0, uint256 a1,) = _redeem(lpA, shares, false);
            _assertNoDilution(n0, n1, s);
            assertLe(a0, p0);
            assertLe(a1, p1);
            assertLe(p0 - a0, 1, "round trip lost more than one unit of asset0");
            assertLe(p1 - a1, 1, "round trip lost more than one unit of asset1");
            paid0 += p0;
            paid1 += p1;
            got0 += a0;
            got1 += a1;
        }
        assertLe(got0, paid0);
        assertLe(got1, paid1);
        _assertEquations();
    }
}
