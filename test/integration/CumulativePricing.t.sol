// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {MockV4Router} from "@uniswap/v4-periphery/test/mocks/MockV4Router.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {BaseCompatibleHook} from "../../src/hooks/BaseCompatibleHook.sol";
import {HookA_DynamicFee} from "../../src/hooks/HookA_DynamicFee.sol";
import {HookB_BoundedImpact} from "../../src/hooks/HookB_BoundedImpact.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {BatchSwapRouter} from "../utils/BatchSwapRouter.sol";
import {PricingVectors} from "../utils/PricingVectors.sol";

/// @dev Helpers shared by the cumulative-pricing suites.
abstract contract PricingTestBase is VaultTestBase {
    uint128 internal constant BIG = 400_000 ether;

    /// @dev Output of a swap from its delta.
    function _out(BalanceDelta d, bool zeroForOne) internal pure returns (uint256) {
        return uint256(int256(zeroForOne ? d.amount1() : d.amount0()));
    }

    /// @dev Warps forward by `dt` seconds. Reads the timestamp through the cheatcode because under via-IR a function
    ///      may reuse its first `block.timestamp` read after an earlier warp.
    function _wait(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
    }

    /// @dev Runs `pieces` exact-input swaps in one unlock and returns the summed output.
    function _batch(PoolKey memory key, bool zeroForOne, uint256[] memory pieces, uint256 id)
        internal
        returns (uint256 out)
    {
        BatchSwapRouter.Step[] memory steps = new BatchSwapRouter.Step[](pieces.length);
        for (uint256 i; i < pieces.length; ++i) {
            steps[i] = BatchSwapRouter.Step(key, zeroForOne, pieces[i], abi.encode(id));
        }
        vm.prank(trader);
        BalanceDelta[] memory d = batchRouter.run(steps, new uint256[](0), BatchSwapRouter.Mode.Settle);
        for (uint256 i; i < d.length; ++i) {
            out += _out(d[i], zeroForOne);
        }
    }

    /// @dev Random partition of `total` into `n` pieces, each at least total / (2n): the first n - 1 are in
    ///      [total/(2n), total/n) and the last takes the rest (at least total/n).
    function _partition(uint256 total, uint256 n, uint256 seed) internal pure returns (uint256[] memory p) {
        p = new uint256[](n);
        uint256 half = total / (2 * n);
        uint256 left = total;
        for (uint256 i; i + 1 < n; ++i) {
            p[i] = half + (half == 0 ? 0 : uint256(keccak256(abi.encode(seed, i))) % half);
            left -= p[i];
        }
        p[n - 1] = left;
    }
}

/// @notice The hooks against the independent Python model, end to end: generated sequences of swaps in both
///         directions with time passing, executed through the real PoolManager, vault and production hooks. Every
///         output, revert reason and resulting pricing state must equal the model's (simulations/pricing/vectors.py,
///         vault floors 1:1 as in this fixture).
contract CumulativePricingModelTest is PricingTestBase {
    function setUp() public override {
        super.setUp();
        // Scenario A uses K = 20,000 when selling currency1 (vectors.py A_CFG); everything else is the fixture's.
        vm.prank(hookOwner);
        hookA.configurePool(keyA, PRICE_1_1_X96, A_BASE_FEE, A_MAX_FEE, A_SCALE, 20_000 ether, A_WINDOW);
    }

    function test_model_hookA_scenario() public {
        uint256 id01 = _allocate(keyA, c1, BIG);
        uint256 id10 = _allocate(keyA, c0, BIG);
        PricingVectors.StepA[] memory s = PricingVectors.scenarioA();
        for (uint256 i; i < s.length; ++i) {
            _wait(s[i].dt);
            assertEq(s[i].code, 0, "scenario A has no expected reverts");
            uint256 out =
                _out(_swap(keyA, s[i].zeroForOne, s[i].amountIn, s[i].zeroForOne ? id01 : id10), s[i].zeroForOne);
            assertEq(out, s[i].amountOut, string.concat("out ", vm.toString(i)));
            assertEq(hookA.flowLevel(keyA, s[i].zeroForOne), s[i].zeroForOne ? s[i].level0 : s[i].level1, "level");
        }
        _assertAccountingConsistent();
    }

    /// @dev The scenario includes Hook B reversals that the 1:1 floors refuse and trades past the cap. A refused swap
    ///      must leave the position exactly as the model's (which did not move).
    function test_model_hookB_scenario() public {
        uint256 id01 = _allocate(keyB, c1, BIG);
        uint256 id10 = _allocate(keyB, c0, BIG);
        (,,,, uint96 cap) = hookB.poolConfig(keyB.toId());
        PricingVectors.StepB[] memory s = PricingVectors.scenarioB();
        uint256 floors;
        uint256 caps;
        for (uint256 i; i < s.length; ++i) {
            _wait(s[i].dt);
            uint256 id = s[i].zeroForOne ? id01 : id10;
            if (s[i].code == 1) {
                _expectSwapRevert(
                    address(hookB),
                    abi.encodeWithSelector(
                        HookB_BoundedImpact.ImpactBoundExceeded.selector, hookB.positionOf(keyB), uint256(cap)
                    )
                );
                _swap(keyB, s[i].zeroForOne, s[i].amountIn, id);
                ++caps;
            } else if (s[i].code == 2) {
                uint256 quoted = hookB.quote(keyB, s[i].zeroForOne, s[i].amountIn);
                _expectSwapRevert(
                    address(hookB),
                    abi.encodeWithSelector(ISharedCommitmentVault.PriceBelowFloor.selector, s[i].amountIn, quoted)
                );
                _swap(keyB, s[i].zeroForOne, s[i].amountIn, id);
                ++floors;
            } else {
                uint256 out = _out(_swap(keyB, s[i].zeroForOne, s[i].amountIn, id), s[i].zeroForOne);
                assertEq(out, s[i].amountOut, string.concat("out ", vm.toString(i)));
                assertEq(hookB.positionOf(keyB), s[i].position, "position");
            }
        }
        assertGt(floors, 0);
        assertGt(caps, 0);
        _assertAccountingConsistent();
    }
}

/// @notice Hook B: signed position, aggregate cap, both directions, round trips, decay, parameter changes, and state
///         written only after successful settlement.
contract HookBPricingTest is PricingTestBase {
    uint256 internal constant CAP = 9_852_457_023_325_690_846_726; // depth 1,000,000, 2% (simulations/pricing)

    /// @notice Selling currency0 raises the position by exactly the output; selling currency1 lowers it by exactly
    ///         the input. Both start at the reference price: the first unit in either direction is priced at 1:1.
    function test_HBP_bothDirections_moveThePosition() public {
        uint256 id01 = _allocate(keyB, c1, BIG);
        uint256 id10 = _allocate(keyB, c0, BIG);
        uint256 out = _out(_swap(keyB, true, 500 ether, id01), true);
        assertEq(hookB.positionOf(keyB), int256(out));
        _wait(B_WINDOW); // back to zero by decay; the reverse direction is otherwise refused by the 1:1 floor
        assertEq(hookB.positionOf(keyB), 0);
        _swap(keyB, false, 700 ether, id10);
        assertEq(hookB.positionOf(keyB), -700 ether);
    }

    /// @notice Round trip, priced by the hook. After a sale of currency1 the hook would pay back exactly what it
    ///         charged (C_hat telescopes), less nothing; the swapper's only loss is the exact-input remainder. The
    ///         vault's 1:1 floors refuse the reverse leg, because buying currency1 back above the reference would sell
    ///         currency0 below its floor (the vault's directional-consistency rule makes this hold for every allowed
    ///         pair of floors; simulations/pricing/test_cumulative.py). The refused swap changes nothing.
    function test_HBP_roundTrip_hookPaysBackExactly_vaultFloorRefusesIt() public {
        uint256 id01 = _allocate(keyB, c1, BIG);
        uint256 id10 = _allocate(keyB, c0, BIG);
        uint256 paid = 3000 ether;
        uint256 got = _out(_swap(keyB, true, paid, id01), true);
        uint256 back = hookB.quote(keyB, false, got);
        assertLe(back, paid, "never more than paid");
        assertGe(back, paid - 1, "only the exact-input remainder (below one unit's price at 1:1) is lost");
        assertGt(back, got, "reverse leg is above the 1:1 reference");

        int256 x = hookB.positionOf(keyB);
        _expectSwapRevert(
            address(hookB), abi.encodeWithSelector(ISharedCommitmentVault.PriceBelowFloor.selector, got, back)
        );
        _swap(keyB, false, got, id10);
        assertEq(hookB.positionOf(keyB), x, "refused swap leaves the position");
    }

    /// @notice A trade that crosses zero is priced on the whole segment. From x = -4,000 (the vault bought 4,000
    ///         currency1 below the reference), 9,000 currency0 moves the position past zero with an average price at
    ///         or above 1:1, so the 1:1 floor accepts it. The same 9,000 split so that its first pieces end below
    ///         zero is refused, because the vault checks each piece's own price: a split cannot buy the cheap part of
    ///         the segment on its own.
    function test_HBP_crossingTrade_cannotBeSplitBelowTheFloor() public {
        uint256 id01 = _allocate(keyB, c1, BIG);
        uint256 id10 = _allocate(keyB, c0, BIG);
        _swap(keyB, false, 4000 ether, id10);
        assertEq(hookB.positionOf(keyB), -4000 ether);

        uint256[] memory parts = new uint256[](3);
        (parts[0], parts[1], parts[2]) = (2500 ether, 2500 ether, 4000 ether);
        vm.prank(trader);
        vm.expectRevert();
        batchRouter.run(_steps(keyB, true, parts, id01), new uint256[](0), BatchSwapRouter.Mode.Settle);
        assertEq(hookB.positionOf(keyB), -4000 ether, "refused split moved nothing");

        uint256 out = _out(_swap(keyB, true, 9000 ether, id01), true);
        assertLe(out, 9000 ether, "average at or above 1:1");
        assertEq(hookB.positionOf(keyB), int256(out) - 4000 ether);
        assertGt(hookB.positionOf(keyB), 0);
    }

    /// @notice The cap binds the negative side too: buying currency1 back past -cap reverts, and so does any split.
    function test_HBP_negativeCapIsAggregate() public {
        uint256 id10 = _allocate(keyB, c0, BIG);
        _swap(keyB, false, CAP, id10);
        assertEq(hookB.positionOf(keyB), -int256(CAP));
        _expectSwapRevert(
            address(hookB), abi.encodeWithSelector(HookB_BoundedImpact.ImpactBoundExceeded.selector, -int256(CAP), CAP)
        );
        _swap(keyB, false, 1, id10);
    }

    /// @notice Decay is linear toward zero at cap/window per second, never past zero, never a reset, and O(1) for any
    ///         gap (2^32 seconds included).
    function test_HBP_decay() public {
        uint256 id01 = _allocate(keyB, c1, BIG);
        _swap(keyB, true, 9950 ether, id01);
        int256 x = hookB.positionOf(keyB);
        uint256[5] memory gaps = [uint256(1), 59, 600, B_WINDOW - 1, B_WINDOW];
        uint256 elapsed;
        for (uint256 i; i < gaps.length; ++i) {
            _wait(gaps[i] - elapsed);
            elapsed = gaps[i];
            int256 expect = x - int256(CAP * elapsed / B_WINDOW);
            assertEq(hookB.positionOf(keyB), expect > 0 ? expect : int256(0));
        }
        _wait(2 ** 32);
        assertEq(hookB.positionOf(keyB), 0);
    }

    /// @notice A smaller depth rescales the position (same marginal price): later trades cost more in both directions
    ///         and a buy-back pays no more than the price the last unit sold at. A tighter cap keeps the position and
    ///         allows only trades back toward zero. A new window applies only to time after the change.
    function test_HBP_parameterChanges() public {
        uint256 id01 = _allocate(keyB, c1, BIG);
        _swap(keyB, true, 9000 ether, id01);
        int256 x = hookB.positionOf(keyB);

        vm.prank(hookOwner);
        hookB.configurePool(keyB, PRICE_1_1_X96, B_DEPTH / 2, B_MAX_IMPACT, B_WINDOW);
        assertEq(hookB.positionOf(keyB), x / 2, "rescaled with depth");

        vm.prank(hookOwner);
        hookB.configurePool(keyB, PRICE_1_1_X96, B_DEPTH / 2, 5000, B_WINDOW);
        (,,,, uint96 tight) = hookB.poolConfig(keyB.toId());
        assertGt(hookB.positionOf(keyB), int256(uint256(tight)), "beyond the new cap");
        _expectSwapRevert(
            address(hookB),
            abi.encodeWithSelector(
                HookB_BoundedImpact.ImpactBoundExceeded.selector, hookB.positionOf(keyB), uint256(tight)
            )
        );
        _swap(keyB, true, 1 ether, id01);

        // Window change: the 600 s before it decay at the old rate, the 600 s after at the new one.
        _wait(600);
        int256 before = hookB.positionOf(keyB);
        vm.prank(hookOwner);
        hookB.configurePool(keyB, PRICE_1_1_X96, B_DEPTH / 2, 5000, 2 * B_WINDOW);
        assertEq(hookB.positionOf(keyB), before, "configuration does not move the decayed position");
        _wait(600);
        assertEq(hookB.positionOf(keyB), before - int256(uint256(tight) * 600 / (2 * B_WINDOW)));
    }

    /// @notice Pricing state changes only when the vault fills the swap. Each refused swap below reaches the hook,
    ///         which computes a new state, and reverts later (in the vault, the min-output check or settlement); the
    ///         stored position is unchanged every time.
    function test_HBP_failedSwapsLeaveStateUnchanged() public {
        uint256 id01 = _allocate(keyB, c1, 20_000 ether);
        _swap(keyB, true, 1000 ether, id01);
        int256 x = hookB.positionOf(keyB);

        // 1. Quota.
        uint256 small = _allocate(keyB, c1, 1 ether);
        vm.expectRevert();
        _swap(keyB, true, 2 ether, small);
        // 2. Minimum output.
        vm.expectRevert();
        _swapRaw(keyB, true, -1 ether, abi.encode(id01, 1 ether));
        // 3. Paused vault.
        vm.prank(owner);
        vault.setPaused(true);
        vm.expectRevert();
        _swap(keyB, true, 1 ether, id01);
        vm.prank(owner);
        vault.setPaused(false);
        // 4. Frozen curator.
        vm.prank(owner);
        vault.freezeCurator(curator);
        vm.expectRevert();
        _swap(keyB, true, 1 ether, id01);
        vm.prank(owner);
        vault.unfreezeCurator(curator);
        // 5. Hook-scope flow limit.
        vm.prank(owner);
        vault.setRiskLimit(ISharedCommitmentVault.RiskScope.Hook, address(hookB), c1, 1, 10_000);
        vm.expectRevert();
        _swap(keyB, true, 1 ether, id01);
        _openLimitsAsOwner(ISharedCommitmentVault.RiskScope.Hook, address(hookB));
        // 6. Input never paid: the unlock reverts with CurrencyNotSettled after the hook committed its state.
        BatchSwapRouter.Step[] memory one = new BatchSwapRouter.Step[](1);
        one[0] = BatchSwapRouter.Step(keyB, true, 1 ether, abi.encode(id01));
        vm.prank(trader);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        batchRouter.run(one, new uint256[](0), BatchSwapRouter.Mode.SkipInputPayment);

        assertEq(hookB.positionOf(keyB), x, "no failed swap moved the position");
        _swap(keyB, true, 1 ether, id01); // and the pool still trades
        assertGt(hookB.positionOf(keyB), x);
    }

    /// @notice Allocations and curators do not affect the price: two allocations from two curators on the same pool
    ///         quote identically, and alternating between them is the same as using one.
    function test_HBP_allocationAndCuratorDoNotAffectPrice() public {
        address curator2 = makeAddr("curator2");
        vm.startPrank(owner);
        vault.setCurator(curator2, true);
        vault.setCuratorCeiling(curator2, c1, VAULT_FUNDING);
        _openLimits(ISharedCommitmentVault.RiskScope.Curator, curator2);
        vm.stopPrank();
        uint256 idA = _allocate(keyB, c1, 50_000 ether);
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyB, c1, 2000 ether);
        vm.prank(curator2);
        uint256 idB = auth.activateDirect(r);

        uint256 snap = vm.snapshotState();
        uint256 one;
        for (uint256 i; i < 4; ++i) {
            one += _out(_swap(keyB, true, 400 ether, idA), true);
        }
        int256 xOne = hookB.positionOf(keyB);
        vm.revertToState(snap);
        uint256 alt;
        for (uint256 i; i < 4; ++i) {
            alt += _out(_swap(keyB, true, 400 ether, i % 2 == 0 ? idA : idB), true);
        }
        assertEq(alt, one);
        assertEq(hookB.positionOf(keyB), xOne);
    }

    function _steps(PoolKey memory key, bool zeroForOne, uint256[] memory pieces, uint256 id)
        internal
        pure
        returns (BatchSwapRouter.Step[] memory steps)
    {
        steps = new BatchSwapRouter.Step[](pieces.length);
        for (uint256 i; i < pieces.length; ++i) {
            steps[i] = BatchSwapRouter.Step(key, zeroForOne, pieces[i], abi.encode(id));
        }
    }
}

/// @notice Hook A: per-direction flow levels, split versus single trades at non-trivial prices, curators and
///         allocations, parameter tightening, decay, and repeated execution across blocks.
contract HookAPricingTest is PricingTestBase {
    /// @notice One trade versus a random split into 1..20 pieces, either direction, any starting level, at the
    ///         reference price 2^96 - 1 (just below 1:1). There, selling currency0 loses exactly one raw unit per
    ///         conversion (floor(net * (2^96 - 1) / 2^96) = net - 1 for 0 < net < 2^96), so the split receives exactly
    ///         n - 1 units less than one trade: the bound is reached. Selling currency1 converts exactly. In both
    ///         directions the fees are identical and the final level is the same.
    function testFuzz_HAP_splitVersusSingle(uint256 pre, uint256 total, uint256 n, bool zeroForOne, uint256 seed)
        public
    {
        vm.prank(hookOwner);
        hookA.configurePool(keyA, PRICE_1_1_X96 - 1, A_BASE_FEE, A_MAX_FEE, A_SCALE, A_SCALE, A_WINDOW);
        uint256 id = _allocate(keyA, zeroForOne ? c1 : c0, BIG);
        pre = pre % 2 == 0 ? 0 : bound(pre, 1e9, 30_000 ether); // dust pre-trades are refused (ZeroOutput)
        total = bound(total, 1e9, 30_000 ether);
        n = bound(n, 1, 20);
        if (pre > 0) _swap(keyA, zeroForOne, pre, id);
        uint256 fee = hookA.feeFor(keyA, zeroForOne, total);
        uint256 levelBefore = hookA.flowLevel(keyA, zeroForOne);

        uint256 snap = vm.snapshotState();
        uint256[] memory single = new uint256[](1);
        single[0] = total;
        uint256 outSingle = _batch(keyA, zeroForOne, single, id);
        vm.revertToState(snap);

        uint256[] memory pieces = _partition(total, n, seed);
        uint256 feeSum;
        for (uint256 i; i < n; ++i) {
            feeSum += hookA.feeFor(keyA, zeroForOne, pieces[i]);
            _swap(keyA, zeroForOne, pieces[i], id);
        }
        assertEq(feeSum, fee, "fees telescope");
        assertEq(hookA.flowLevel(keyA, zeroForOne), levelBefore + total, "same final level");
        vm.revertToState(snap);

        uint256 outN = _batch(keyA, zeroForOne, pieces, id);
        assertLe(outN, outSingle, "split never receives more");
        assertEq(outSingle - outN, zeroForOne ? n - 1 : 0, "exactly one unit per extra piece selling currency0");
    }

    /// @notice The two directions keep separate levels: selling currency1 does not lower the level of selling
    ///         currency0, so a round trip pays both fees.
    function test_HAP_directionsIndependent_roundTripPaysBoth() public {
        uint256 id01 = _allocate(keyA, c1, BIG);
        uint256 id10 = _allocate(keyA, c0, BIG);
        uint256 out = _out(_swap(keyA, true, 5000 ether, id01), true);
        assertEq(hookA.flowLevel(keyA, true), 5000 ether);
        assertEq(hookA.flowLevel(keyA, false), 0);
        uint256 fee2 = hookA.feeFor(keyA, false, out);
        uint256 back = _out(_swap(keyA, false, out, id10), false);
        assertEq(back, out - fee2);
        assertEq(hookA.flowLevel(keyA, true), 5000 ether, "selling currency1 did not lower it");
        assertEq(hookA.flowLevel(keyA, false), out);
        // Level 0 -> 5,000 at K = 10,000: 2.5 + 0.45% * 5,000^2 / 20,000 = 2.5 + 5.625.
        assertEq(5000 ether - out, 8.125 ether);
    }

    /// @notice Different curators and allocations: the fee depends only on the pool's flow level. Opening a fresh
    ///         allocation (the old way to reset the fee) changes nothing.
    function test_HAP_freshAllocationDoesNotResetFee() public {
        uint256 id1 = _allocate(keyA, c1, 20_000 ether);
        _swap(keyA, true, 9000 ether, id1);
        uint256 feeOld = hookA.feeFor(keyA, true, 1000 ether);
        address curator2 = makeAddr("curator2");
        vm.startPrank(owner);
        vault.setCurator(curator2, true);
        vault.setCuratorCeiling(curator2, c1, VAULT_FUNDING);
        _openLimits(ISharedCommitmentVault.RiskScope.Curator, curator2);
        vm.stopPrank();
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyA, c1, 20_000 ether);
        vm.prank(curator2);
        uint256 id2 = auth.activateDirect(r);
        uint256 out = _out(_swap(keyA, true, 1000 ether, id2), true);
        assertEq(out, 1000 ether - feeOld, "fresh allocation pays the pool's level");
        // Level 9,000 -> 10,000: F(10,000) - F(9,000) = 27.5 - 22.725.
        assertEq(feeOld, 4.775 ether);
    }

    /// @notice Tightening (smaller K, higher fees) raises the next fee at once; the level is kept and decays at the
    ///         old rate up to the change.
    function test_HAP_parameterTightening() public {
        uint256 id = _allocate(keyA, c1, BIG);
        _swap(keyA, true, 5000 ether, id);
        _wait(900);
        uint256 loose = hookA.feeFor(keyA, true, 1000 ether);
        vm.prank(hookOwner);
        hookA.configurePool(keyA, PRICE_1_1_X96, 1000, 10_000, A_SCALE / 2, A_SCALE, A_WINDOW);
        assertEq(hookA.flowLevel(keyA, true), 5000 ether - A_SCALE * 900 / A_WINDOW, "decayed at the old rate");
        assertGt(hookA.feeFor(keyA, true, 1000 ether), loose);
    }

    /// @notice Repeated execution across blocks: 3,000 every 10 minutes against decay of 10,000 per hour (1,666.67
    ///         per 10 minutes). The level before each trade grows by 1,333.33 per round and never resets, so each fee is
    ///         at least the one before; from the 8th round on the level is above K and the whole trade pays the
    ///         maximum rate, 50 bps of 3,000 = 15 (within one raw unit of rounding).
    function test_HAP_repeatedAcrossBlocks() public {
        uint256 id = _allocate(keyA, c1, BIG);
        uint256 prev;
        for (uint256 i; i < 24; ++i) {
            vm.roll(block.number + 50);
            uint256 fee = hookA.feeFor(keyA, true, 3000 ether);
            assertGe(fee, prev, "the fee never falls under steady flow");
            if (i >= 8) assertApproxEqAbs(fee, 15 ether, 1, "maximum rate");
            prev = fee;
            _swap(keyA, true, 3000 ether, id);
            _wait(600);
        }
    }
}

/// @notice Exact input, the ignored price limit, the optional `hookData` minimum, and a real router's own minimum.
contract TraderProtectionTest is PricingTestBase {
    MockV4Router internal v4router;

    function setUp() public override {
        super.setUp();
        v4router = new MockV4Router(manager);
        vm.startPrank(trader);
        token0.approve(address(v4router), type(uint256).max);
        token1.approve(address(v4router), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice minAmountOut equal to the quote passes; one unit more reverts with the hook's InsufficientOutput and
    ///         leaves the pricing state unchanged.
    function test_TP_hookDataMinimum_exactBoundary() public {
        uint256 id = _allocate(keyB, c1, BIG);
        uint256 q = hookB.quote(keyB, true, 1000 ether);
        _expectSwapRevert(
            address(hookB), abi.encodeWithSelector(BaseCompatibleHook.InsufficientOutput.selector, q, q + 1)
        );
        _swapRaw(keyB, true, -1000 ether, abi.encode(id, q + 1));
        assertEq(hookB.positionOf(keyB), 0);
        BalanceDelta d = _swapRaw(keyB, true, -1000 ether, abi.encode(id, q));
        assertEq(_out(d, true), q);
    }

    /// @notice Sandwich on Hook B: an attacker buys currency1 ahead of a victim, so the victim's trade starts higher on
    ///         the curve. With a minimum from a pre-trade quote the victim's swap reverts; without one it executes at
    ///         the worse price. The attacker's back-run (selling currency1 back above the reference) is refused by the
    ///         vault's 1:1 floor, so the attacker cannot realise the profit through Hook B.
    function test_TP_sandwich_minimumProtectsVictim_floorStopsBackRun() public {
        uint256 id01 = _allocate(keyB, c1, BIG);
        uint256 id10 = _allocate(keyB, c0, BIG);
        uint256 expected = hookB.quote(keyB, true, 2000 ether);

        uint256 aOut = _out(_swap(keyB, true, 6000 ether, id01), true); // front-run
        uint256 worse = hookB.quote(keyB, true, 2000 ether);
        assertLt(worse, expected);
        _expectSwapRevert(
            address(hookB), abi.encodeWithSelector(BaseCompatibleHook.InsufficientOutput.selector, worse, expected)
        );
        _swapRaw(keyB, true, -2000 ether, abi.encode(id01, expected));

        assertEq(_out(_swap(keyB, true, 2000 ether, id01), true), worse); // unprotected victim
        uint256 back = hookB.quote(keyB, false, aOut);
        assertGt(back, 6000 ether, "the back-run would be profitable on the curve alone");
        _expectSwapRevert(
            address(hookB), abi.encodeWithSelector(ISharedCommitmentVault.PriceBelowFloor.selector, aOut, back)
        );
        _swap(keyB, false, aOut, id10);
    }

    /// @notice The v4 periphery router (V4Router logic via its MockV4Router harness) through the real PoolManager:
    ///         its own amountOutMinimum works with the hook's custom accounting, because it reads the delta the hook
    ///         returned. Exact boundary on both sides.
    function test_TP_v4RouterAmountOutMinimum() public {
        uint256 id = _allocate(keyA, c1, BIG);
        uint256 q = hookA.quote(keyA, true, 1000 ether);
        uint256 snap = vm.snapshotState();
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IV4Router.V4TooLittleReceived.selector, q + 1, q));
        v4router.executeActions(_v4Swap(keyA, true, 1000 ether, uint128(q + 1), abi.encode(id)));
        vm.revertToState(snap);

        uint256 before = token1.balanceOf(trader);
        vm.prank(trader);
        v4router.executeActions(_v4Swap(keyA, true, 1000 ether, uint128(q), abi.encode(id)));
        assertEq(token1.balanceOf(trader) - before, q);
        assertEq(hookA.flowLevel(keyA, true), 1000 ether);
        _assertAccountingConsistent();
    }

    /// @notice The swap's sqrtPriceLimitX96 is ignored in both directions: a limit the native curve would reject as
    ///         already exceeded does not stop the swap, and the output equals the quote.
    function test_TP_priceLimitIgnoredBothDirections() public {
        uint256 id01 = _allocate(keyA, c1, BIG);
        uint256 id10 = _allocate(keyA, c0, BIG);
        for (uint256 i; i < 2; ++i) {
            bool zeroForOne = i == 0;
            uint256 q = hookA.quote(keyA, zeroForOne, 10 ether);
            vm.prank(trader);
            BalanceDelta d = swapRouter.swap(
                keyA,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -10 ether,
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                abi.encode(zeroForOne ? id01 : id10)
            );
            assertEq(_out(d, zeroForOne), q);
        }
    }

    /// @notice Exact output is refused before pricing, so there is no exact-output path to protect.
    function test_TP_exactOutputRefused() public {
        uint256 id = _allocate(keyA, c1, BIG);
        _expectSwapRevert(address(hookA), abi.encodeWithSelector(BaseCompatibleHook.ExactOutputNotSupported.selector));
        _swapRaw(keyA, true, 1 ether, abi.encode(id));
    }

    function _v4Swap(PoolKey memory key, bool zeroForOne, uint128 amountIn, uint128 minOut, bytes memory hookData)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(IV4Router.ExactInputSingleParams(key, zeroForOne, amountIn, minOut, 0, hookData));
        (params[1], params[2]) = zeroForOne
            ? (abi.encode(key.currency0, uint256(amountIn)), abi.encode(key.currency1, uint256(0)))
            : (abi.encode(key.currency1, uint256(amountIn)), abi.encode(key.currency0, uint256(0)));
        return abi.encode(actions, params);
    }
}
