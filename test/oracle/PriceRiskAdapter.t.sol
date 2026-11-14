// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {PriceRiskAdapter} from "../../src/oracle/PriceRiskAdapter.sol";
import {IMarketRiskAdapter} from "../../src/interfaces/IMarketRiskAdapter.sol";
import {ReferenceBracket} from "../../src/oracle/ReferenceBracket.sol";
import {MockAggregator} from "../utils/MockAggregator.sol";

/// @notice The price-risk adapter's fail-closed behaviour with mock feeds shaped like the Unichain ones (USDC as
///         currency0 with 6 decimals, WETH as currency1 with 18; Chainlink-like legs with 18-decimal answers,
///         RedStone-like legs with 8). Every path that is not a fresh, consistent pair of sources must revert.
contract PriceRiskAdapterTest is Test {
    uint256 internal constant T = 1_794_360_000;
    // Unichain USDC (currency0) and WETH (currency1); any sorted non-zero pair works for these tests.
    address internal constant USDC = 0x078D782b760474a361dDA0AF3839290b0EF57AD6;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    MockAggregator internal clUsdc;
    MockAggregator internal clEth;
    MockAggregator internal rsUsdc;
    MockAggregator internal rsEth;
    MockAggregator internal seq;
    PriceRiskAdapter internal adapter;

    function setUp() public {
        vm.warp(T);
        clUsdc = new MockAggregator(18);
        clEth = new MockAggregator(18);
        rsUsdc = new MockAggregator(8);
        rsEth = new MockAggregator(8);
        seq = new MockAggregator(0);
        // Values read on Unichain mainnet on 2026-11-10 (docs/architecture/ORACLE_VERIFICATION_UNICHAIN.md).
        clUsdc.set(999_720_000_000_000_000, T - 9700);
        clEth.set(2_048_390_000_000_000_000_000, T - 9900);
        rsUsdc.set(99_982_887, T - 1400);
        rsEth.set(205_030_881_965, T - 10_500);
        seq.setStatus(0, T - 1_000_000);
        adapter = _deploy(2);
    }

    function _deploy(uint256 minSources) internal returns (PriceRiskAdapter) {
        PriceRiskAdapter.Source memory cl = PriceRiskAdapter.Source(clUsdc, clEth, 3100, 5100, 88_200, 88_200, 0, 0, 0);
        PriceRiskAdapter.Source memory rs = PriceRiskAdapter.Source(rsUsdc, rsEth, 5100, 5100, 12_600, 23_400, 0, 0, 0);
        return new PriceRiskAdapter(cl, rs, USDC, WETH, 6, 18, IAggregatorV3(address(seq)), 3600, minSources);
    }

    /// @notice Both sources live: the reading is the centre of the two brackets' intersection. Chainlink's bracket for
    ///         WETH per USDC is about +-0.82% (30 + 50 bps thresholds, 1 bp margin each); RedStone's is about +-1.02%;
    ///         they overlap, and the result is within both.
    function test_bothSourcesLive() public view {
        IMarketRiskAdapter.Reading memory r = adapter.currentReference();
        assertEq(r.liveSources, 2);
        assertGt(r.uncertaintyPips, 7000);
        assertLt(r.uncertaintyPips, 10_300);
        assertEq(r.validUntil, T - 1400 + 12_600); // the RedStone USDC leg expires first
        // Centre near 1 USDC / 2,049 USD per WETH: raw WETH per raw USDC ~ 4.88e8, Q96.
        uint256 approx = r.priceX96 >> 96;
        assertGt(approx, 480_000_000);
        assertLt(approx, 495_000_000);
    }

    function test_sequencerDownOrInGrace() public {
        seq.setStatus(1, T - 10);
        vm.expectRevert(PriceRiskAdapter.SequencerUnavailable.selector);
        adapter.currentReference();
        seq.setStatus(0, T - 3600); // exactly the grace: still refused (now - startedAt <= grace)
        vm.expectRevert(PriceRiskAdapter.SequencerUnavailable.selector);
        adapter.currentReference();
        seq.setStatus(0, T - 3601);
        adapter.currentReference();
    }

    function test_unusableLegReverts() public {
        int256[4] memory bad = [int256(0), -1, int256(1 << 128), int256(1)];
        for (uint256 k; k < 4; ++k) {
            uint256 at = k == 3 ? T + 1 : T - 10; // last case: a timestamp in the future
            clEth.set(bad[k], at);
            vm.expectRevert(abi.encodeWithSelector(PriceRiskAdapter.FeedUnusable.selector, address(clEth)));
            adapter.currentReference();
        }
    }

    function test_feedRevertOrShortReturnReverts() public {
        rsUsdc.setMode(MockAggregator.Mode.Revert);
        vm.expectRevert(abi.encodeWithSelector(PriceRiskAdapter.FeedUnusable.selector, address(rsUsdc)));
        adapter.currentReference();
        rsUsdc.setMode(MockAggregator.Mode.ShortReturn);
        vm.expectRevert(abi.encodeWithSelector(PriceRiskAdapter.FeedUnusable.selector, address(rsUsdc)));
        adapter.currentReference();
    }

    /// @notice A feed that burns gas can only make the read fail (and with it the trade); it cannot change a result.
    function test_gasBurningFeedOnlyFails() public {
        clUsdc.setMode(MockAggregator.Mode.BurnGas);
        (bool ok,) = address(adapter).staticcall{gas: 2_000_000}(abi.encodeCall(adapter.currentReference, ()));
        assertFalse(ok);
    }

    /// @notice A stale leg removes its source; with two required the read reverts, with one required the other
    ///         source's bracket alone is used.
    function test_staleSource() public {
        rsEth.set(205_030_881_965, T - 23_401);
        vm.expectRevert(abi.encodeWithSelector(ReferenceBracket.InsufficientSources.selector, 1, 2));
        adapter.currentReference();
        PriceRiskAdapter one = _deploy(1);
        IMarketRiskAdapter.Reading memory r = one.currentReference();
        assertEq(r.liveSources, 1);
        assertGt(r.uncertaintyPips, 8000); // Chainlink's bracket alone: about 82 bps
    }

    /// @notice Sources whose brackets do not overlap contradict their own error bounds: refused, not averaged. With these
    ///         thresholds the pair brackets are about +-0.82% (Chainlink) and +-1.02% (RedStone), so they still overlap
    ///         at a 1.3% disagreement and only a gap above about 1.84% is detected.
    function test_divergenceReverts() public {
        rsEth.set(207_500_000_000, T - 10); // 1.3% above Chainlink's 2,048.39: inside both error bounds
        adapter.currentReference();
        rsEth.set(210_000_000_000, T - 10); // 2.5% above: no price satisfies both sources
        vm.expectRevert();
        adapter.currentReference();
    }

    function test_invalidConfig() public {
        PriceRiskAdapter.Source memory ok = PriceRiskAdapter.Source(clUsdc, clEth, 3100, 5100, 88_200, 88_200, 0, 0, 0);
        PriceRiskAdapter.Source memory bad =
            PriceRiskAdapter.Source(clUsdc, clEth, 1_000_000, 5100, 88_200, 88_200, 0, 0, 0);
        vm.expectRevert(PriceRiskAdapter.InvalidConfig.selector);
        new PriceRiskAdapter(ok, bad, USDC, WETH, 6, 18, IAggregatorV3(address(0)), 0, 2);
        vm.expectRevert(PriceRiskAdapter.InvalidConfig.selector);
        new PriceRiskAdapter(ok, ok, USDC, WETH, 6, 18, IAggregatorV3(address(0)), 0, 3);
        MockAggregator wide = new MockAggregator(60);
        vm.expectRevert(PriceRiskAdapter.InvalidConfig.selector);
        new PriceRiskAdapter(
            PriceRiskAdapter.Source(clUsdc, wide, 3100, 5100, 88_200, 88_200, 0, 0, 0),
            ok,
            USDC,
            WETH,
            6,
            18,
            IAggregatorV3(address(0)),
            0,
            2
        );
    }

    /// @notice The pair must be sorted and non-zero, and the configuration hash identifies the whole fixed
    ///         configuration: two adapters that differ in any parameter have different versions.
    function test_pairAndConfigVersion() public {
        (address a0, address a1, uint8 d0, uint8 d1) = adapter.pair();
        assertEq(a0, USDC);
        assertEq(a1, WETH);
        assertEq(d0, 6);
        assertEq(d1, 18);
        assertTrue(adapter.configVersion() != bytes32(0));
        assertTrue(adapter.configVersion() != _deploy(1).configVersion());
        PriceRiskAdapter.Source memory cl = PriceRiskAdapter.Source(clUsdc, clEth, 3100, 5100, 88_200, 88_200, 0, 0, 0);
        vm.expectRevert(PriceRiskAdapter.InvalidConfig.selector);
        new PriceRiskAdapter(cl, cl, WETH, USDC, 6, 18, IAggregatorV3(address(0)), 0, 2);
        vm.expectRevert(PriceRiskAdapter.InvalidConfig.selector);
        new PriceRiskAdapter(cl, cl, address(0), WETH, 6, 18, IAggregatorV3(address(0)), 0, 2);
        // Two adapters that differ only in the second source's staleness limit have different versions.
        PriceRiskAdapter.Source memory rs = PriceRiskAdapter.Source(rsUsdc, rsEth, 5100, 5100, 12_600, 23_400, 0, 0, 0);
        PriceRiskAdapter.Source memory rs2 = PriceRiskAdapter.Source(rsUsdc, rsEth, 5100, 5100, 12_600, 23_401, 0, 0, 0);
        assertTrue(
            new PriceRiskAdapter(cl, rs, USDC, WETH, 6, 18, IAggregatorV3(address(0)), 0, 2).configVersion()
                != new PriceRiskAdapter(cl, rs2, USDC, WETH, 6, 18, IAggregatorV3(address(0)), 0, 2).configVersion()
        );
        vm.expectRevert(PriceRiskAdapter.InvalidConfig.selector); // a pair of one token is not a pair
        new PriceRiskAdapter(cl, cl, USDC, USDC, 6, 6, IAggregatorV3(address(0)), 0, 2);
    }

    // ------------------------------------------------------------------ fresh tier (relayer)

    /// @dev Chainlink as push-only; RedStone with a fresh tier: +-15 bps per leg while younger than 120 s.
    function _deployFresh(uint256 minSources) internal returns (PriceRiskAdapter) {
        PriceRiskAdapter.Source memory cl = PriceRiskAdapter.Source(clUsdc, clEth, 3100, 5100, 88_200, 88_200, 0, 0, 0);
        PriceRiskAdapter.Source memory rs =
            PriceRiskAdapter.Source(rsUsdc, rsEth, 5100, 5100, 12_600, 23_400, 120, 1500, 1500);
        return new PriceRiskAdapter(cl, rs, USDC, WETH, 6, 18, IAggregatorV3(address(seq)), 3600, minSources);
    }

    /// @notice A relayer outage and recovery, as seen by the adapter. While a third party pushes RedStone's signed
    ///         packages every minute the band is narrow. When it stops, the band returns to exactly the push-only
    ///         reading 120 s after the last push: wider, not halted. Only when the provider's own heartbeat also lapses
    ///         does the source go dark; then two-source mode refuses and one-source mode falls back to Chainlink alone.
    ///         The next push restores the narrow band with no action by anyone else.
    function test_freshTier_relayerOutageAndRecovery() public {
        PriceRiskAdapter fresh = _deployFresh(2);
        PriceRiskAdapter fresh1 = _deployFresh(1);
        uint256 pushOnly = adapter.currentReference().uncertaintyPips;

        vm.warp(T + 60);
        rsUsdc.set(99_982_887, T + 30); // the relayer pushed both legs 30 s ago
        rsEth.set(205_030_881_965, T + 30);
        IMarketRiskAdapter.Reading memory r = fresh.currentReference();
        assertLt(r.uncertaintyPips, pushOnly / 2, "narrow while fresh");
        assertEq(r.validUntil, T + 30 + 120, "valid only while the legs stay fresh");
        assertEq(adapter.currentReference().uncertaintyPips, pushOnly, "push-only adapter unaffected");

        vm.warp(T + 30 + 121); // relayer silent: the legs left the fresh tier
        r = fresh.currentReference();
        assertEq(r.uncertaintyPips, adapter.currentReference().uncertaintyPips, "back to the push band");
        assertEq(r.liveSources, 2, "wider, not halted");

        vm.warp(T + 30 + 12_601); // the provider's own heartbeat lapsed too (USDC leg, 12,600 s)
        vm.expectRevert(abi.encodeWithSelector(ReferenceBracket.InsufficientSources.selector, 1, 2));
        fresh.currentReference();
        r = fresh1.currentReference();
        assertEq(r.liveSources, 1, "one-source mode: Chainlink alone");

        rsUsdc.set(99_982_887, T + 30 + 12_601); // anyone pushes again
        rsEth.set(205_030_881_965, T + 30 + 12_601);
        r = fresh.currentReference();
        assertEq(r.liveSources, 2);
        assertLt(r.uncertaintyPips, pushOnly / 2, "narrow again after recovery");
    }

    /// @notice The tier boundary is inclusive: a leg exactly `freshMaxAge` old is still fresh; one second later it is
    ///         read with the push threshold.
    function test_freshTier_boundaryIsInclusive() public {
        PriceRiskAdapter fresh = _deployFresh(2);
        rsUsdc.set(99_982_887, T);
        rsEth.set(205_030_881_965, T);
        vm.warp(T + 120);
        uint256 atLimit = fresh.currentReference().uncertaintyPips;
        vm.warp(T + 121);
        uint256 past = fresh.currentReference().uncertaintyPips;
        assertLt(atLimit, past, "fresh at exactly freshMaxAge");
        assertEq(past, adapter.currentReference().uncertaintyPips);
    }

    /// @notice Each leg picks its own tier: a fresh USDC leg with a stale-but-live ETH leg is bracketed at 15 bps on one
    ///         side and the push threshold on the other.
    function test_freshTier_perLeg() public {
        PriceRiskAdapter fresh = _deployFresh(2);
        vm.warp(T + 60);
        rsUsdc.set(99_982_887, T + 30);
        uint256 oneLeg = fresh.currentReference().uncertaintyPips;
        rsEth.set(205_030_881_965, T + 30);
        uint256 bothLegs = fresh.currentReference().uncertaintyPips;
        assertLt(bothLegs, oneLeg);
        assertLe(oneLeg, adapter.currentReference().uncertaintyPips);
    }

    /// @notice A fresh tier must be strictly shorter and no wider than the push tier, and absent means all zero.
    function test_freshTier_configValidation() public {
        PriceRiskAdapter.Source memory cl = PriceRiskAdapter.Source(clUsdc, clEth, 3100, 5100, 88_200, 88_200, 0, 0, 0);
        PriceRiskAdapter.Source[4] memory bad = [
            PriceRiskAdapter.Source(rsUsdc, rsEth, 5100, 5100, 12_600, 23_400, 12_600, 1500, 1500), // not shorter
            PriceRiskAdapter.Source(rsUsdc, rsEth, 5100, 5100, 12_600, 23_400, 120, 5101, 1500), // wider than push
            PriceRiskAdapter.Source(rsUsdc, rsEth, 5100, 5100, 12_600, 23_400, 120, 1500, 5101),
            PriceRiskAdapter.Source(rsUsdc, rsEth, 5100, 5100, 12_600, 23_400, 0, 1500, 0) // disabled but set
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(PriceRiskAdapter.InvalidConfig.selector);
            new PriceRiskAdapter(cl, bad[i], USDC, WETH, 6, 18, IAggregatorV3(address(0)), 0, 2);
        }
        assertTrue(_deployFresh(2).configVersion() != adapter.configVersion(), "the tier is part of the version");
    }
}
