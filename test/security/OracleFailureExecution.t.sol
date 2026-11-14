// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {IMarketRiskAdapter} from "../../src/interfaces/IMarketRiskAdapter.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {PriceRiskAdapter} from "../../src/oracle/PriceRiskAdapter.sol";
import {ReferenceBracket} from "../../src/oracle/ReferenceBracket.sol";
import {VaultRiskBoundary} from "../../src/risk/VaultRiskBoundary.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {MaliciousConsumerHook} from "../utils/MaliciousConsumerHook.sol";
import {MockAggregator} from "../utils/MockAggregator.sol";

/// @notice Oracle failures as the vault sees them, with the production `PriceRiskAdapter` over mock push feeds in the
///         configuration of the Sepolia rehearsal (script/DeploySystem.s.sol): a Chainlink-like push source at
///         31 / 51 bps per leg, a RedStone-like source at 51 / 51 bps with a 120 s / 15 bps fresh tier, two live
///         sources required, a sequencer feed with a one-hour grace; vault edge 1 bp, uncertainty bound 2%,
///         inventory tolerance 1%, and no stored price floors (adapter-only pricing, as the rehearsal deploys it).
/// @dev Fills go through a registered test hook that pays exact chosen amounts, so each test probes the vault's own
///      rule rather than a hook's quote. The production hooks read the same adapter from the vault in the same call
///      (test/integration/SharedCoreHooks.t.sol, RelayerOutage.t.sol).
contract OracleFailureExecutionTest is VaultTestBase {
    uint160 internal constant SWAP_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
    uint256 internal constant Q96 = FixedPoint96.Q96;
    uint24 internal constant EDGE = 100;
    uint24 internal constant MAX_U = 20_000;
    uint24 internal constant KAPPA = 10_000;

    address internal guardian = makeAddr("guardian");
    MaliciousConsumerHook internal mal;
    PoolKey internal keyM;
    MockAggregator internal cl0;
    MockAggregator internal cl1;
    MockAggregator internal rs0;
    MockAggregator internal rs1;
    MockAggregator internal seq;
    PriceRiskAdapter internal adapter;
    uint256 internal tau;

    function setUp() public override {
        super.setUp();
        address m = address(uint160(0xBAD7 << 140) | SWAP_FLAGS);
        deployCodeTo("MaliciousConsumerHook.sol:MaliciousConsumerHook", abi.encode(manager, vault), m);
        mal = MaliciousConsumerHook(m);
        keyM = PoolKey(c0, c1, 3000, 60, IHooks(m));
        manager.initialize(keyM, SQRT_PRICE_1_1);

        (cl0, cl1, rs0, rs1) =
        (new MockAggregator(8), new MockAggregator(8), new MockAggregator(8), new MockAggregator(8));
        seq = new MockAggregator(0);
        seq.setStatus(0, T0 - 10 days);
        _push(1e8, 1e8, T0 - 600, T0 - 600); // both sources live, RedStone in its push tier
        adapter = _adapter(cl0, cl1, rs0, rs1, 2);

        tau = FullMath.mulDiv(vault.backing(c0), 1e18, vault.totalShares());
        vm.startPrank(owner);
        vault.setConsumer(m, true);
        _openLimits(ISharedCommitmentVault.RiskScope.Hook, m);
        vault.setGuardian(guardian);
        vault.setCuratorCeiling(curator, c0, type(uint256).max);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        vault.setRiskBounds(EDGE, MAX_U);
        vault.setInventoryBounds(tau, tau, KAPPA, KAPPA);
        vault.setRiskAdapter(adapter);
        vault.setSellFloor(c0, 0);
        vault.setSellFloor(c1, 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _adapter(MockAggregator a0, MockAggregator a1, MockAggregator b0, MockAggregator b1, uint256 minSources)
        internal
        returns (PriceRiskAdapter)
    {
        return new PriceRiskAdapter(
            PriceRiskAdapter.Source(a0, a1, 3100, 5100, 88_200, 88_200, 0, 0, 0),
            PriceRiskAdapter.Source(b0, b1, 5100, 5100, 12_600, 23_400, 120, 1500, 1500),
            address(token0),
            address(token1),
            18,
            18,
            IAggregatorV3(address(seq)),
            3600,
            minSources
        );
    }

    /// @dev Sets both sources' legs: USD per asset0 and USD per asset1 (8 decimals), with each source's time.
    function _push(int256 usd0, int256 usd1, uint256 clAt, uint256 rsAt) internal {
        cl0.set(usd0, clAt);
        cl1.set(usd1, clAt);
        rs0.set(usd0, rsAt);
        rs1.set(usd1, rsAt);
    }

    function _allocM(Currency out, uint128 maxOut, uint160 curatorFloor) internal returns (uint256 id) {
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyM, out, maxOut);
        r.minInPerOutX96 = curatorFloor;
        // via-IR may reuse a block.timestamp read from before vm.warp; the cheatcode reads the current one.
        r.expiry = uint64(vm.getBlockTimestamp() + 30 days);
        r.deadline = uint64(vm.getBlockTimestamp() + 1 hours);
        vm.prank(curator);
        id = auth.activateDirect(r);
    }

    function _trade(uint256 id, Currency out, uint256 amountIn, uint256 amountOut) internal {
        _tradeExpect(id, out, amountIn, amountOut, "");
    }

    function _tradeExpect(uint256 id, Currency out, uint256 amountIn, uint256 amountOut, bytes memory reason) internal {
        mal.configure(MaliciousConsumerHook.Attack.ExactAmounts, id, amountOut);
        if (reason.length != 0) _expectSwapRevert(address(mal), reason);
        _swapRaw(keyM, out == c1, -int256(amountIn), "");
    }

    /// @dev The smallest input the vault accepts for `amountOut` of `out` under the installed adapter right now.
    function _minIn(Currency out, uint256 amountOut) internal view returns (uint256) {
        IMarketRiskAdapter.Reading memory r = vault.riskAdapter().currentReference();
        uint256 f = VaultRiskBoundary.dynamicFloor(r.priceX96, r.uncertaintyPips, vault.riskEdgePips(), out == c1);
        return FullMath.mulDivRoundingUp(amountOut, f, Q96);
    }

    function _invFloor(uint256 i) internal view returns (uint256) {
        return VaultRiskBoundary.inventoryFloor(
            vault.totalShares(), vault.inventoryTargetPerShare(i), vault.inventoryTolerancePips(i)
        );
    }

    function _net(Currency c) internal view returns (uint256) {
        return vault.backing(c) - vault.claimableAssets(c);
    }

    // ------------------------------------------------------------------
    // F-1. Scenario 4 (valid but very uncertain) and 1 (stale primary): the asset1 floor and the band's bottom
    // ------------------------------------------------------------------

    /// @dev The uncertainty the adapter reported before the G04 correction: both terms measured from the mid.
    function _midRelativeU(uint256 low, uint256 high) internal pure returns (uint256 mid, uint256 u) {
        mid = low + (high - low) / 2;
        uint256 up = FullMath.mulDivRoundingUp(high - mid, 1e6, mid);
        uint256 down = FullMath.mulDivRoundingUp(mid - low, 1e6, mid);
        u = up > down ? up : down;
    }

    /// @notice F-1 and its correction, through `exchange`. With one source required, Chainlink stale and RedStone
    ///         alone in its push tier, RedStone allows asset0 to be worth as little as 0.9949 / 1.0051 asset1, i.e.
    ///         asset1 up to 1.0051 / 0.9949 asset0. The vault's asset1 floor is (1 / P)(1 + u + e).
    ///         - Before the correction the adapter measured u from the mid (10,200 pips here). That floor is below
    ///           1 / low by about u^2 / (1 - u) = 105 pips, more than the 100-pip edge: the original counterexample,
    ///           recomputed here from the same bracket. The vault now refuses that input.
    ///         - The corrected adapter measures the lower term from the low end (10,305 pips). Its floor is at or
    ///           above 1 / low, and the fill at its minimum succeeds.
    ///         The vault's 20,000 bound accepts both readings; the edge is unchanged. With two sources required (the
    ///         rehearsal configuration) Chainlink's narrower bracket sets u near 8,265 and the floor is outside too.
    function test_F1_asset1FloorCoversBandBottom_aboveOldFailureThreshold() public {
        PriceRiskAdapter one = _adapter(cl0, cl1, rs0, rs1, 1);
        vm.warp(T0 + 88_200);
        _push(1e8, 1e8, T0 - 600, vm.getBlockTimestamp() - 600); // Chainlink stale; RedStone in its push tier
        vm.prank(owner);
        vault.setRiskAdapter(one);
        IMarketRiskAdapter.Reading memory r = one.currentReference();
        assertEq(r.liveSources, 1);
        assertLe(r.uncertaintyPips, MAX_U, "accepted by the vault");

        (uint256 low, uint256 high) = ReferenceBracket.pairBracket(1e8, 1e8, 5100, 5100, 0);
        (uint256 mid, uint256 uOld) = _midRelativeU(low, high);
        assertEq(mid, r.priceX96);
        assertEq(uOld, 10_200, "the pre-correction reading");
        assertGt(r.uncertaintyPips, uOld);
        assertGt(uOld * uOld, uint256(EDGE) * (1e6 - uOld), "above the old failure threshold");
        console2.log("u, pips (RedStone alone): before / after the correction", uOld, r.uncertaintyPips);

        uint256 out = 1000 ether;
        uint256 id = _allocM(c1, uint128(out * 3), 1);
        uint256 oldMinIn = FullMath.mulDivRoundingUp(out, VaultRiskBoundary.dynamicFloor(mid, uOld, EDGE, true), Q96);
        assertLt(oldMinIn * 994_900, out * 1_005_100, "old floor: asset1 sold below 1 / RedStone's bottom");
        uint256 minIn = _minIn(c1, out);
        assertGe(minIn * 994_900, out * 1_005_100, "corrected floor: at or above 1 / RedStone's bottom");
        console2.log("asset0 in for 1,000 asset1: old / corrected", oldMinIn, minIn);
        _tradeExpect(
            id,
            c1,
            oldMinIn,
            out,
            abi.encodeWithSelector(ISharedCommitmentVault.PriceBelowFloor.selector, oldMinIn, minIn)
        );
        _trade(id, c1, minIn, out);

        // The asset0 direction was never affected and stays at or above RedStone's top.
        uint256 id0 = _allocM(c0, uint128(out), 1);
        uint256 minIn0 = _minIn(c0, out);
        assertGe(minIn0 * 994_900, out * 1_005_100, "asset0 at or above RedStone's top");
        _trade(id0, c0, minIn0, out);

        // Two sources required, both live: Chainlink's narrower bracket is the band; the floor is outside it.
        _push(1e8, 1e8, vm.getBlockTimestamp() - 600, vm.getBlockTimestamp() - 600);
        vm.prank(owner);
        vault.setRiskAdapter(adapter);
        assertLt(adapter.currentReference().uncertaintyPips, 8300);
        uint256 minIn2 = _minIn(c1, out);
        assertGe(minIn2 * 996_900, out * 1_005_100, "outside 1 / Chainlink's bottom");
        _trade(id, c1, minIn2, out);
    }

    // ------------------------------------------------------------------
    // Scenario 5: legs in the wrong order
    // ------------------------------------------------------------------

    /// @notice An adapter built with each source's legs swapped prices the pair upside down, yet passes every check
    ///         `setRiskAdapter` makes (pair, token decimals, a valid reading now): nothing on-chain says which leg is
    ///         which asset. Asset0 is worth 2 asset1; the swapped adapter reports 0.5. A buyer then takes the whole
    ///         asset0 room above the inventory floor at about a quarter of its value, and one more raw unit is
    ///         refused. In this configuration (no stored floors) the guardian cannot add a price floor: raising a
    ///         stored floor needs one to exist. It can halt the direction. A stored floor the owner set as a sanity
    ///         bound refuses the inverted price outright, and the guardian can raise it.
    function test_swappedLegs_passInstallation_boundedByInventoryFloor() public {
        _push(2e8, 1e8, vm.getBlockTimestamp() - 600, vm.getBlockTimestamp() - 600);
        PriceRiskAdapter swapped = _adapter(cl1, cl0, rs1, rs0, 2);
        vm.prank(owner);
        vault.setRiskAdapter(swapped);
        uint256 p = swapped.currentReference().priceX96;
        assertLt(p, Q96 * 51 / 100, "about 0.5 asset1 per asset0 instead of 2");

        uint256 snap = vm.snapshotState();
        uint256 room = _net(c0) - _invFloor(0);
        uint256 id = _allocM(c0, uint128(room + 1), 1);
        uint256 floorAfter = _invFloor(0);
        _tradeExpect(
            id,
            c0,
            _minIn(c0, room + 1),
            room + 1,
            abi.encodeWithSelector(VaultRiskBoundary.InventoryFloorBreached.selector, floorAfter - 1, floorAfter)
        );
        uint256 paid = _minIn(c0, room);
        _trade(id, c0, paid, room);
        assertEq(_net(c0), _invFloor(0), "asset0 at its floor, not below");
        assertLt(paid, room * 51 / 100, "paid about a quarter of the 2x value");
        console2.log("asset0 room sold / asset1 paid", room, paid);

        vm.startPrank(guardian);
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setSellFloor(c0, uint160(2 * Q96));
        vault.setSellHalted(c0, true);
        vm.stopPrank();
        uint256 id2 = _allocM(c1, 1 ether, 1); // the other direction is unaffected by the halt
        _trade(id2, c1, _minIn(c1, 1 ether), 1 ether);
        _assertAccountingConsistent();

        vm.revertToState(snap);
        vm.prank(owner);
        vault.setSellFloor(c0, uint160(Q96)); // sanity bound: never sell asset0 below 1 asset1
        vm.prank(guardian);
        vault.setSellFloor(c0, uint160(2 * Q96)); // emergency: raised to the real price
        uint256 id3 = _allocM(c0, 1000 ether, uint160(2 * Q96));
        uint256 req = FullMath.mulDivRoundingUp(1000 ether, 2 * Q96, Q96);
        _tradeExpect(
            id3,
            c0,
            req - 1,
            1000 ether,
            abi.encodeWithSelector(ISharedCommitmentVault.PriceBelowFloor.selector, req - 1, req)
        );
    }

    // ------------------------------------------------------------------
    // Scenario 8: a jump the feeds have not followed
    // ------------------------------------------------------------------

    /// @notice The market moves 8% (asset0 to 1.08 asset1) and both providers are still within their staleness
    ///         limits at the old 1:1 answers, which is outside what their deviation thresholds promise. Every fill
    ///         is still priced at the top of the stale band or above, so buyers take asset0 at about 1.0085 while it
    ///         is worth 1.08, but only down to the inventory floor: the room (1% of the holding here) goes, one more
    ///         raw unit is refused, and LP exits are unaffected.
    function test_jumpTheFeedsMissed_lossStopsAtInventoryRoom() public {
        uint256 room = _net(c0) - _invFloor(0);
        uint256 id = _allocM(c0, uint128(room + 1), 1);
        uint256 paid = _minIn(c0, room);
        assertGe(paid * 994_900, room * 1_003_100, "priced at or above the stale band's top");
        _trade(id, c0, paid, room);
        uint256 floorAfter = _invFloor(0);
        _tradeExpect(
            id,
            c0,
            _minIn(c0, 1),
            1,
            abi.encodeWithSelector(VaultRiskBoundary.InventoryFloorBreached.selector, floorAfter - 1, floorAfter)
        );
        uint256 loss = room * 108 / 100 - paid; // asset1 terms, at the true price
        assertLt(loss, room * 72 / 1000, "less than (8% - band) of the room");
        console2.log("room / loss at the true price (asset1 raw)", room, loss);

        (uint256 inst,,,) = _redeem(lp0, 1000 ether, false);
        assertEq(inst, 1000 ether, "exits unaffected");
        _assertAccountingConsistent();
    }

    // ------------------------------------------------------------------
    // Scenarios 9 and 10: price change and outage between reservation and execution
    // ------------------------------------------------------------------

    /// @notice An allocation fixes no price. After a move up, a fill at the price of reservation time is refused;
    ///         after a move down, a fill below the reservation-time minimum is accepted. Only the curator's own floor
    ///         stays fixed.
    function test_priceMoveBetweenReservationAndExecution() public {
        uint256 id = _allocM(c0, 10_000 ether, 1);
        uint256 atReservation = _minIn(c0, 100 ether);

        _push(1.05e8, 1e8, vm.getBlockTimestamp() - 60, vm.getBlockTimestamp() - 600);
        uint256 up = _minIn(c0, 100 ether);
        assertGt(up, atReservation);
        _tradeExpect(
            id,
            c0,
            atReservation,
            100 ether,
            abi.encodeWithSelector(ISharedCommitmentVault.PriceBelowFloor.selector, atReservation, up)
        );
        _trade(id, c0, up, 100 ether);

        _push(0.95e8, 1e8, vm.getBlockTimestamp() - 60, vm.getBlockTimestamp() - 600);
        uint256 down = _minIn(c0, 100 ether);
        assertLt(down, atReservation, "the reservation did not lock its price");
        _trade(id, c0, down, 100 ether);
    }

    /// @notice An oracle outage while a reservation is outstanding and an LP is queued. Fills stop; the reservation
    ///         keeps its capacity (Q), so the LP's instant exit is limited to free inventory and the rest queues.
    ///         Queue processing, claims, deposits, cancellation and every guardian tool keep working, because none
    ///         reads the adapter. Releasing the reservation, which the guardian may do early, frees the inventory the
    ///         queue was waiting for; trading resumes when a source pushes again, with no governance action.
    function test_outageWithReservation_exitsQueueBehindItUntilReleased() public {
        uint256 id = _allocM(c0, 600_000 ether, 1);
        vm.warp(vm.getBlockTimestamp() + 23_400); // RedStone (pushed 600 s before) passes its 23,400 s limit
        bytes memory down = abi.encodeWithSelector(ReferenceBracket.InsufficientSources.selector, 1, 2);
        _tradeExpect(id, c0, 2 ether, 1 ether, down);
        assertEq(vault.reserved(c0), 600_000 ether, "capacity stays reserved while unexecutable");

        uint256 shares = vault.sharesOf(lp0) * 7 / 10;
        (uint256 inst,,, uint256 rid) = _redeem(lp0, shares, true);
        assertLt(inst, shares, "instant part limited by free inventory");
        assertGt(rid, 0);
        uint256 pending = vault.pendingShares();
        vault.processQueue(10);
        assertEq(vault.pendingShares(), pending, "nothing to finalize while the reservation holds the inventory");

        _depositShares(trader, 1000 ether);
        vm.startPrank(guardian);
        vault.setPaused(true);
        vault.setSellHalted(c1, true);
        vault.setRiskBounds(EDGE + 1, MAX_U - 1);
        vault.release(id);
        vm.stopPrank();
        vault.processQueue(10);
        assertEq(vault.pendingShares(), 0, "released inventory finalizes the queue");
        vm.prank(lp0);
        vault.claim(rid);
        _assertAccountingConsistent();

        vm.prank(owner);
        vault.setPaused(false);
        _push(1e8, 1e8, vm.getBlockTimestamp() - 60, vm.getBlockTimestamp());
        uint256 id2 = _allocM(c0, 1000 ether, 1);
        _trade(id2, c0, _minIn(c0, 1000 ether), 1000 ether);
    }

    // ------------------------------------------------------------------
    // Scenario 1: stale data cannot authorize a fill
    // ------------------------------------------------------------------

    /// @notice A RedStone push 30 s ago puts the source in its fresh tier (15 bps per leg) until 120 s. At the last
    ///         fresh second the narrow-band minimum fills; one second later the same leg is read with its push-tier
    ///         threshold and the same input is refused as below the wider floor. The reading's `validUntil` is that
    ///         tier boundary, and the adapter and the vault treat it as inclusive.
    function test_freshTierBoundary_staleNarrowBandCannotAuthorize() public {
        uint256 pushedAt = vm.getBlockTimestamp() - 30;
        _push(1e8, 1e8, vm.getBlockTimestamp() - 600, pushedAt);
        IMarketRiskAdapter.Reading memory r = adapter.currentReference();
        assertEq(r.validUntil, pushedAt + 120);
        uint256 id = _allocM(c0, 10_000 ether, 1);

        vm.warp(r.validUntil);
        uint256 narrow = _minIn(c0, 100 ether);
        _trade(id, c0, narrow, 100 ether);

        vm.warp(r.validUntil + 1);
        uint256 wide = _minIn(c0, 100 ether);
        assertGt(wide, narrow);
        _tradeExpect(
            id,
            c0,
            narrow,
            100 ether,
            abi.encodeWithSelector(ISharedCommitmentVault.PriceBelowFloor.selector, narrow, wide)
        );
    }

    // ------------------------------------------------------------------
    // Task 3: removing the adapter (static fall-back)
    // ------------------------------------------------------------------

    /// @notice The static fall-back keeps every inventory floor that has a target. An asset with no target is
    ///         refused in adapter mode, but after the owner removes the adapter (DELAY under the governor, not
    ///         LONG_DELAY) and a stored floor exists, it trades with no inventory floor at all. Not silent (owner
    ///         call, event, timelock), but a loosening of inventory protection that the selector-based delay does
    ///         not give the long notice an inventory-bound change gets.
    function test_adapterRemoval_assetWithoutTarget_losesInventoryFloor() public {
        vm.startPrank(owner);
        vault.setInventoryBounds(tau, 0, KAPPA, KAPPA);
        vault.setSellFloor(c1, uint160(Q96));
        vm.stopPrank();
        uint256 big = _net(c1) / 10; // ten times the 1% room a target would allow
        uint256 id = _allocM(c1, uint128(big), uint160(Q96));
        _tradeExpect(
            id, c1, big, big, abi.encodeWithSelector(ISharedCommitmentVault.InventoryBoundsNotConfigured.selector)
        );

        vm.prank(owner);
        vault.setRiskAdapter(IMarketRiskAdapter(address(0)));
        _trade(id, c1, big, big);
        assertEq(vault.inventoryTargetPerShare(0), tau, "asset0 keeps its floor");
        _assertAccountingConsistent();
    }
}
