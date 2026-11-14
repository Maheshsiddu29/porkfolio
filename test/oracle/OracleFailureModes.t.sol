// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {IMarketRiskAdapter} from "../../src/interfaces/IMarketRiskAdapter.sol";
import {PriceRiskAdapter} from "../../src/oracle/PriceRiskAdapter.sol";
import {ReferenceBracket} from "../../src/oracle/ReferenceBracket.sol";
import {VaultRiskBoundary} from "../../src/risk/VaultRiskBoundary.sol";
import {MockAggregator} from "../utils/MockAggregator.sol";

/// @notice Oracle failure modes that the adapter tests in `PriceRiskAdapter.t.sol` do not pin down: what an
///         unavailable second source does when one source would suffice, malformed sequencer answers, what "age" means
///         when the feed itself reports it, how much a fall-back to one source can move each directional floor, and
///         whether decimal normalization and integer rounding can ever put a fill price inside a live source's bracket.
/// @dev Feeds and thresholds follow the Unichain configuration (docs/architecture/ORACLE_VERIFICATION_UNICHAIN.md):
///      a Chainlink-like source at 31 / 51 bps per leg with an 88,200 s limit, a RedStone-like source at 51 / 51 bps
///      with 12,600 / 23,400 s limits, the sequencer feed with a one-hour grace.
contract OracleFailureModesTest is Test {
    uint256 internal constant T = 1_794_360_000;
    uint256 internal constant Q96 = FixedPoint96.Q96;
    address internal constant USDC = 0x078D782b760474a361dDA0AF3839290b0EF57AD6;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    MockAggregator internal clUsdc;
    MockAggregator internal clEth;
    MockAggregator internal rsUsdc;
    MockAggregator internal rsEth;
    MockAggregator internal seq;

    function setUp() public {
        vm.warp(T);
        clUsdc = new MockAggregator(18);
        clEth = new MockAggregator(18);
        rsUsdc = new MockAggregator(8);
        rsEth = new MockAggregator(8);
        seq = new MockAggregator(0);
        clUsdc.set(999_720_000_000_000_000, T - 9700);
        clEth.set(2_048_390_000_000_000_000_000, T - 9900);
        rsUsdc.set(99_982_887, T - 1400);
        rsEth.set(205_030_881_965, T - 10_500);
        seq.setStatus(0, T - 1_000_000);
    }

    function _deploy(uint256 minSources, uint256 freshMaxAge, uint256 freshDev) internal returns (PriceRiskAdapter) {
        PriceRiskAdapter.Source memory cl = PriceRiskAdapter.Source(clUsdc, clEth, 3100, 5100, 88_200, 88_200, 0, 0, 0);
        PriceRiskAdapter.Source memory rs =
            PriceRiskAdapter.Source(rsUsdc, rsEth, 5100, 5100, 12_600, 23_400, freshMaxAge, freshDev, freshDev);
        return new PriceRiskAdapter(cl, rs, USDC, WETH, 6, 18, IAggregatorV3(address(seq)), 3600, minSources);
    }

    // ------------------------------------------------------------------
    // Scenario 2: an unavailable fallback
    // ------------------------------------------------------------------

    /// @notice With one source required, a second source that is merely stale is dropped and the first prices alone,
    ///         but a second source that reverts or answers zero stops every read. The adapter treats "old" as "not
    ///         live" and "broken" as "refuse everything", so a broken fallback costs availability even when the
    ///         primary would satisfy `minSources`. This is fail-closed, and it differs from ORACLE_RISK_BOUNDARY_SPEC.md
    ///         §5, which says a missing or malformed leg only drops its source.
    function test_unavailableFallback_haltsEvenWhenOneSourceSuffices() public {
        PriceRiskAdapter one = _deploy(1, 0, 0);
        assertEq(one.currentReference().liveSources, 2);

        rsEth.set(205_030_881_965, T - 23_401); // stale: dropped
        IMarketRiskAdapter.Reading memory r = one.currentReference();
        assertEq(r.liveSources, 1, "stale fallback dropped, primary alone");

        rsEth.setMode(MockAggregator.Mode.Revert); // unavailable: refuses
        vm.expectRevert(abi.encodeWithSelector(PriceRiskAdapter.FeedUnusable.selector, address(rsEth)));
        one.currentReference();

        rsEth.setMode(MockAggregator.Mode.Normal);
        rsEth.set(0, T - 23_401); // zero answer, even on a leg that is also stale: refuses
        vm.expectRevert(abi.encodeWithSelector(PriceRiskAdapter.FeedUnusable.selector, address(rsEth)));
        one.currentReference();
    }

    // ------------------------------------------------------------------
    // Scenario 6: malformed sequencer answers
    // ------------------------------------------------------------------

    /// @notice The sequencer feed must answer 0 (up) or 1 (down); anything else is unusable. A restart time in the
    ///         future keeps the grace period running. An answer of "up since time 0" is accepted as up for decades:
    ///         the adapter does not treat `startedAt == 0` as an invalid round, so the deployment must confirm the
    ///         configured sequencer feed is initialized (Unichain's reported 1,793,291,075 on 2026-11-10).
    function test_sequencerMalformedAnswers() public {
        PriceRiskAdapter a = _deploy(2, 0, 0);
        int256[2] memory bad = [int256(2), -1];
        for (uint256 k; k < 2; ++k) {
            seq.setStatus(bad[k], T - 1_000_000);
            vm.expectRevert(abi.encodeWithSelector(PriceRiskAdapter.FeedUnusable.selector, address(seq)));
            a.currentReference();
        }
        seq.setStatus(0, T + 100);
        vm.expectRevert(PriceRiskAdapter.SequencerUnavailable.selector);
        a.currentReference();

        seq.setStatus(0, 0);
        assertEq(a.currentReference().liveSources, 2, "startedAt = 0 reads as up since 1970");
    }

    // ------------------------------------------------------------------
    // Scenario 7: replayed or expired signed updates
    // ------------------------------------------------------------------

    /// @notice The adapter's only notion of freshness is the `updatedAt` the feed reports. It cannot see signatures
    ///         or package timestamps. Two consequences, both assumptions about the provider rather than checks here:
    ///         (1) a feed that stores an old price with a new `updatedAt` gets the fresh tier's narrow band around that
    ///         old price; (2) a feed that rolls back to an older answer with its older `updatedAt` is accepted while
    ///         that age is inside the push tier, although the newer answer proved the market had moved. RedStone's
    ///         adapter refuses older packages (ORACLE_RELAYER.md §1); this test shows what happens if it did not.
    ///         An update older than the staleness limit, or dated in the future, is refused here.
    function test_freshnessIsTheFeedsClaim_replayAndRollback() public {
        PriceRiskAdapter fresh = _deploy(2, 120, 1500);
        rsUsdc.set(99_982_887, T);
        rsEth.set(205_030_881_965, T);
        uint256 uFresh = fresh.currentReference().uncertaintyPips;
        assertLt(uFresh, 3100, "narrow band while the legs claim to be new");

        // (1) Replay: the 2,050.31 price, first published hours ago, re-stored with a new timestamp. Same narrow band.
        vm.warp(T + 6 hours);
        clUsdc.set(999_720_000_000_000_000, T + 6 hours - 60);
        clEth.set(2_048_390_000_000_000_000_000, T + 6 hours - 60);
        rsUsdc.set(99_982_887, T + 6 hours);
        rsEth.set(205_030_881_965, T + 6 hours);
        assertEq(fresh.currentReference().uncertaintyPips, uFresh, "replayed price gets the fresh band");

        // (2) Rollback: RedStone ETH had moved to 2,070 at T + 6 h; the feed returns to the 2,050.31 answer dated
        //     T + 6 h - 2 h. Accepted with the push-tier band, although the newer answer existed.
        rsEth.set(207_000_000_000, T + 6 hours);
        rsEth.set(205_030_881_965, T + 4 hours);
        IMarketRiskAdapter.Reading memory r = fresh.currentReference();
        assertEq(r.liveSources, 2, "rollback within the push tier accepted");
        assertGt(r.uncertaintyPips, uFresh);

        // Expired (past the 23,400 s limit) and future-dated updates are refused.
        rsEth.set(205_030_881_965, T + 6 hours - 23_401);
        vm.expectRevert(abi.encodeWithSelector(ReferenceBracket.InsufficientSources.selector, 1, 2));
        fresh.currentReference();
        rsEth.set(205_030_881_965, T + 6 hours + 1);
        vm.expectRevert(abi.encodeWithSelector(PriceRiskAdapter.FeedUnusable.selector, address(rsEth)));
        fresh.currentReference();
    }

    // ------------------------------------------------------------------
    // Scenario 1 / Task 3: what a fall-back to one source does to each floor
    // ------------------------------------------------------------------

    /// @notice When a source goes stale and the adapter (with `minSources = 1`) prices from the other alone, the band
    ///         widens to that source's bracket. Each directional floor stays at or beyond the top (or bottom) of every
    ///         price the remaining source allows. It is not true that each floor only rises: the edge `e` is applied
    ///         to the mid, and when the remaining bracket's mid is lower the asset0 floor loses about
    ///         `e * (mid_2 - mid_1)`, while the wider bracket's larger `u` raises it. At the configured 1 bp edge the
    ///         asset0 floor rises (by about 49 pips here; before the G04 correction of `u` it fell by 0.28 pip); with
    ///         a 5% edge it falls. The asset1 floor rises.
    function test_fallbackToOneSource_staysOutsideRemainingBand() public {
        MockAggregator a0 = new MockAggregator(8);
        MockAggregator a1 = new MockAggregator(8);
        MockAggregator b0 = new MockAggregator(8);
        MockAggregator b1 = new MockAggregator(8);
        a0.set(1e8, T);
        a1.set(1e8, T);
        b0.set(1.01e8, T); // B says asset0 is 1% dearer: the intersection is A's upper part
        b1.set(1e8, T);
        PriceRiskAdapter ad = new PriceRiskAdapter(
            PriceRiskAdapter.Source(a0, a1, 3100, 5100, 88_200, 88_200, 0, 0, 0),
            PriceRiskAdapter.Source(b0, b1, 5100, 5100, 12_600, 23_400, 0, 0, 0),
            USDC,
            WETH,
            18,
            18,
            IAggregatorV3(address(0)),
            0,
            1
        );
        IMarketRiskAdapter.Reading memory two = ad.currentReference();
        b1.set(1e8, T - 23_401); // B stale: A alone
        IMarketRiskAdapter.Reading memory one = ad.currentReference();
        assertEq(two.liveSources, 2);
        assertEq(one.liveSources, 1);
        assertLt(one.priceX96, two.priceX96, "mid moves down to A's centre");

        // A's exact top: 1.0031 / 0.9949; its exact bottom: 0.9969 / 1.0051 (raw per raw, both tokens 18 decimals).
        for (uint256 edge = 100; edge <= 50_000; edge += 49_900) {
            uint256 f0One = VaultRiskBoundary.dynamicFloor(one.priceX96, one.uncertaintyPips, edge, false);
            uint256 f0Two = VaultRiskBoundary.dynamicFloor(two.priceX96, two.uncertaintyPips, edge, false);
            uint256 f1One = VaultRiskBoundary.dynamicFloor(one.priceX96, one.uncertaintyPips, edge, true);
            uint256 f1Two = VaultRiskBoundary.dynamicFloor(two.priceX96, two.uncertaintyPips, edge, true);
            assertGe(f0One * 994_900, Q96 * 1_003_100, "asset0 floor at or above A's top");
            assertGe(f1One * 996_900, Q96 * 1_005_100, "asset1 floor at or above 1 / A's bottom");
            assertGt(f1One, f1Two, "asset1 floor rises");
            console2.log("edge pips", edge);
            console2.log("asset0 floor Q96: one source / two", f0One, f0Two);
            if (edge == 100) {
                assertGt(f0One, f0Two, "at the configured edge the asset0 floor rises");
            } else {
                assertLt(f0One, f0Two, "with a 5% edge the asset0 floor visibly falls");
            }
        }
    }

    // ------------------------------------------------------------------
    // Task 3: normalization and rounding against every live bracket
    // ------------------------------------------------------------------

    /// @dev The vault's fill rule, `ceil(amountOut * floor / 2^96)`, as an external call so an overflow (which the
    ///      vault turns into a revert, i.e. a refusal) can be skipped.
    function requiredIn(uint256 priceX96, uint256 u, uint256 edge, bool sellAsset1, uint256 amountOut)
        external
        pure
        returns (uint256)
    {
        return FullMath.mulDivRoundingUp(amountOut, VaultRiskBoundary.dynamicFloor(priceX96, u, edge, sellAsset1), Q96);
    }

    /// @dev 512-bit products: (hi, lo) of a * b.
    function _mul512(uint256 a, uint256 b) internal pure returns (uint256 hi, uint256 lo) {
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            lo := mul(a, b)
            hi := sub(sub(mm, lo), lt(mm, lo))
        }
    }

    /// @dev a * b >= c * d, exactly.
    function _geq(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (bool) {
        (uint256 h1, uint256 l1) = _mul512(a, b);
        (uint256 h2, uint256 l2) = _mul512(c, d);
        return h1 > h2 || (h1 == h2 && l1 >= l2);
    }

    struct Leg {
        uint256 a0;
        uint256 a1;
        uint256 d0;
        uint256 d1;
        int256 e;
    }

    /// @dev Exact check that `inAmt` raw input for `outAmt` raw output is at or beyond source `s`'s bracket:
    ///      selling asset0 needs inAmt / outAmt >= a0 (1e6 + d0) 10^e / (a1 (1e6 - d1)); selling asset1 needs
    ///      inAmt / outAmt >= a1 (1e6 + d1) / (a0 (1e6 - d0) 10^e). Every factor is below 2^185, so each side is one
    ///      exact 512-bit product.
    function _outsideBracket(Leg memory s, bool sellAsset1, uint256 inAmt, uint256 outAmt)
        internal
        pure
        returns (bool)
    {
        uint256 up = s.e > 0 ? 10 ** uint256(s.e) : 1;
        uint256 down = s.e < 0 ? 10 ** uint256(-s.e) : 1;
        if (!sellAsset1) return _geq(inAmt, s.a1 * (1e6 - s.d1) * down, outAmt, s.a0 * (1e6 + s.d0) * up);
        return _geq(inAmt, s.a0 * (1e6 - s.d0) * up, outAmt, s.a1 * (1e6 + s.d1) * down);
    }

    /// @notice For random answers, thresholds, feed and token decimals, the input the vault requires for any output,
    ///         measured exactly against every live source's bracket, is never inside the band: selling asset0 it is at
    ///         or above the lowest of the sources' tops; selling asset1 at or above the reciprocal of the highest
    ///         bottom. So no combination of decimal shift, bracket rounding, mid/uncertainty rounding, floor rounding
    ///         and the final `ceil(amountOut * floor / 2^96)` puts a fill inside the band, in either direction and for
    ///         any edge including zero. Before the G04 correction the asset1 half held only when
    ///         `e * (1e6 - u) >= u^2` (finding F-1); the companion test counts how many cases the old uncertainty
    ///         would have failed. Readings the adapter refuses (degenerate or contradictory brackets) and floors
    ///         that overflow (refused by the vault) are skipped; both are refusals.
    function testFuzz_normalizedFloorNeverInsideTheBand(
        uint256[2] memory answers,
        uint256[4] memory devs,
        uint256[2] memory offsets,
        uint8[2] memory feedDecimals,
        uint8[2] memory tokenDecimals,
        uint256 edge,
        uint256 amountOut,
        bool twoSources
    ) public {
        _checkBand(answers, devs, offsets, feedDecimals, tokenDecimals, edge, amountOut, twoSources);
    }

    /// @notice Non-vacuity of the fuzz test above: over 300 derived cases, each kind of exact check runs often
    ///         (asset0 with one and two sources, asset1, and asset1 cases the pre-correction uncertainty would have
    ///         failed) and refusals stay a minority.
    function test_normalizedFloor_checksAreExercised() public {
        uint256[5] memory hits;
        for (uint256 i; i < 300; ++i) {
            uint256 h = uint256(keccak256(abi.encode(i)));
            uint256[2] memory answers = [h % 2 ** 64, (h >> 64) % 2 ** 64];
            uint256[4] memory devs = [h >> 5, h >> 11, h >> 17, h >> 23];
            uint256[2] memory offsets = [h >> 29, h >> 37];
            uint8[2] memory fd = [uint8(h >> 41), uint8(h >> 49)];
            uint8[2] memory td = [uint8(h >> 57), uint8(h >> 65)];
            uint256 snap = vm.snapshotState();
            uint256[5] memory c = _checkBand(answers, devs, offsets, fd, td, h >> 73, h >> 81, (h >> 99) & 1 == 1);
            vm.revertToState(snap);
            for (uint256 k; k < 5; ++k) {
                hits[k] += c[k];
            }
        }
        // [refused, asset0 one source, asset0 two sources, asset1 checked, asset1 outside the pre-correction bound]
        console2.log("refused / asset0 one / asset0 two", hits[0], hits[1], hits[2]);
        console2.log("asset1 checked / of which outside the pre-correction bound", hits[3], hits[4]);
        assertLt(hits[0], 60, "refusals");
        assertGt(hits[1], 60, "asset0, one source");
        assertGt(hits[2], 60, "asset0, two sources");
        assertGt(hits[3], 200, "asset1 checked");
        assertGt(hits[4], 10, "asset1 cases outside the pre-correction bound occur and are checked");
    }

    /// @dev Builds source A from two feeds with fuzzed decimals and answers, and source B from A's answers moved by up
    ///      to 2% per leg (so the two usually overlap), with the vault's 18-or-other token decimals. Returns counts:
    ///      [refused, asset0 checked with one source, with two, asset1 checked, asset1 cases with
    ///      `e (1e6 - u) < u^2`, which only the corrected uncertainty covers].
    function _checkBand(
        uint256[2] memory answers,
        uint256[4] memory devs,
        uint256[2] memory offsets,
        uint8[2] memory feedDecimals,
        uint8[2] memory tokenDecimals,
        uint256 edge,
        uint256 amountOut,
        bool twoSources
    ) internal returns (uint256[5] memory c) {
        uint8 t0 = uint8(bound(tokenDecimals[0], 0, 24));
        uint8 t1 = uint8(bound(tokenDecimals[1], 0, 24));
        uint8 fd0 = uint8(bound(feedDecimals[0], 0, 24));
        uint8 fd1 = uint8(bound(feedDecimals[1], 0, 24));
        Leg memory sa;
        Leg memory sb;
        sa.a0 = bound(answers[0], 1e3, type(uint64).max / 2);
        sa.a1 = bound(answers[1], 1e3, type(uint64).max / 2);
        sb.a0 = sa.a0 + sa.a0 * bound(offsets[0], 0, 20_000) / 1e6;
        sb.a1 = sa.a1 + sa.a1 * bound(offsets[1], 0, 20_000) / 1e6;
        (sa.d0, sa.d1, sb.d0, sb.d1) =
        (bound(devs[0], 0, 50_000), bound(devs[1], 0, 50_000), bound(devs[2], 0, 50_000), bound(devs[3], 0, 50_000));
        sa.e = int256(uint256(fd1) + t1) - int256(uint256(fd0) + t0);
        sb.e = sa.e;
        if (sa.e < -30 || sa.e > 30) {
            c[0] = 1;
            return c; // the adapter refuses this configuration at deployment
        }
        MockAggregator[4] memory f =
            [new MockAggregator(fd0), new MockAggregator(fd1), new MockAggregator(fd0), new MockAggregator(fd1)];
        f[0].set(int256(sa.a0), T);
        f[1].set(int256(sa.a1), T);
        f[2].set(int256(sb.a0), T);
        f[3].set(int256(sb.a1), twoSources ? T : T - 23_401); // one source: B is stale
        PriceRiskAdapter ad = new PriceRiskAdapter(
            PriceRiskAdapter.Source(f[0], f[1], sa.d0, sa.d1, 88_200, 88_200, 0, 0, 0),
            PriceRiskAdapter.Source(f[2], f[3], sb.d0, sb.d1, 12_600, 23_400, 0, 0, 0),
            USDC,
            WETH,
            t0,
            t1,
            IAggregatorV3(address(0)),
            0,
            1
        );
        IMarketRiskAdapter.Reading memory r;
        try ad.currentReference() returns (IMarketRiskAdapter.Reading memory got) {
            r = got;
        } catch {
            c[0] = 1;
            return c; // refused: degenerate or contradictory brackets
        }
        assertEq(r.liveSources, twoSources ? 2 : 1);
        edge = bound(edge, 0, 10_000);
        amountOut = bound(amountOut, 1, type(uint64).max);
        uint256 u = r.uncertaintyPips;
        for (uint256 k; k < 2; ++k) {
            bool sell1 = k == 1;
            if (sell1 && (u >= 1e6 || edge * (1e6 - u) < u * u)) c[4] += 1; // the region F-1 affected
            uint256 inAmt;
            try this.requiredIn(r.priceX96, u, edge, sell1, amountOut) returns (uint256 x) {
                inAmt = x;
            } catch {
                continue; // overflow: the vault reverts, i.e. refuses
            }
            bool ok = _outsideBracket(sa, sell1, inAmt, amountOut);
            if (twoSources && !ok) ok = _outsideBracket(sb, sell1, inAmt, amountOut);
            assertTrue(ok, sell1 ? "asset1 sold inside the band" : "asset0 sold inside the band");
            if (sell1) c[3] += 1;
            else if (twoSources) c[2] += 1;
            else c[1] += 1;
        }
    }
}
