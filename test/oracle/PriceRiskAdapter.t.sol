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
        PriceRiskAdapter.Source memory cl = PriceRiskAdapter.Source(clUsdc, clEth, 3100, 5100, 88_200, 88_200);
        PriceRiskAdapter.Source memory rs = PriceRiskAdapter.Source(rsUsdc, rsEth, 5100, 5100, 12_600, 23_400);
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
        seq.setStatus(0, T - 3599);
        vm.expectRevert(PriceRiskAdapter.SequencerUnavailable.selector);
        adapter.currentReference();
        seq.setStatus(0, T - 3600);
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
        PriceRiskAdapter.Source memory ok = PriceRiskAdapter.Source(clUsdc, clEth, 3100, 5100, 88_200, 88_200);
        PriceRiskAdapter.Source memory bad = PriceRiskAdapter.Source(clUsdc, clEth, 1_000_000, 5100, 88_200, 88_200);
        vm.expectRevert(PriceRiskAdapter.InvalidConfig.selector);
        new PriceRiskAdapter(ok, bad, USDC, WETH, 6, 18, IAggregatorV3(address(0)), 0, 2);
        vm.expectRevert(PriceRiskAdapter.InvalidConfig.selector);
        new PriceRiskAdapter(ok, ok, USDC, WETH, 6, 18, IAggregatorV3(address(0)), 0, 3);
        MockAggregator wide = new MockAggregator(60);
        vm.expectRevert(PriceRiskAdapter.InvalidConfig.selector);
        new PriceRiskAdapter(
            PriceRiskAdapter.Source(clUsdc, wide, 3100, 5100, 88_200, 88_200),
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
        PriceRiskAdapter.Source memory cl = PriceRiskAdapter.Source(clUsdc, clEth, 3100, 5100, 88_200, 88_200);
        vm.expectRevert(PriceRiskAdapter.InvalidConfig.selector);
        new PriceRiskAdapter(cl, cl, WETH, USDC, 6, 18, IAggregatorV3(address(0)), 0, 2);
        vm.expectRevert(PriceRiskAdapter.InvalidConfig.selector);
        new PriceRiskAdapter(cl, cl, address(0), WETH, 6, 18, IAggregatorV3(address(0)), 0, 2);
    }
}
