// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {BaseCompatibleHook} from "../../src/hooks/BaseCompatibleHook.sol";
import {HookA_DynamicFee} from "../../src/hooks/HookA_DynamicFee.sol";
import {HookB_BoundedImpact} from "../../src/hooks/HookB_BoundedImpact.sol";
import {BatchSwapRouter} from "../utils/BatchSwapRouter.sol";
import {PricingTestBase} from "../integration/CumulativePricing.t.sol";

/// @notice Attacks on cumulative pricing through the real PoolManager, vault and production hooks: splitting in one
///         transaction and across transactions, across allocations and curators, round trips and manipulation,
///         sandwiches, decay farming, stale reference prices, parameter changes under open positions, extreme inputs,
///         failed settlement, and splitting across the two hooks against the vault's aggregate flow limit.
/// @dev Expected values marked "model" come from simulations/pricing/cumulative.py.
contract PricingAdversarialTest is PricingTestBase {
    uint256 internal constant B_CAP = 9_852_457_023_325_690_846_726;

    // ------------------------------------------------------------------
    // Splitting
    // ------------------------------------------------------------------

    /// @notice One trade of 8,000 against 2, 5, 10 and 100 equal pieces, in one transaction and as separate
    ///         transactions at one timestamp, on both hooks. At the 1:1 reference every conversion is exact, so all
    ///         eight runs per hook receive exactly the single trade's output and end in the same pricing state.
    function test_ADV_split_2_5_10_100_sameAndCrossTx() public {
        uint256[4] memory ns = [uint256(2), 5, 10, 100];
        for (uint256 h; h < 2; ++h) {
            PoolKey memory key = h == 0 ? keyA : keyB;
            uint256 id = _allocate(key, c1, BIG);
            uint256 snap = vm.snapshotState();
            uint256[] memory one = new uint256[](1);
            one[0] = 8000 ether;
            uint256 single = _batch(key, true, one, id);
            bytes32 state = _state(h == 0);
            vm.revertToState(snap);
            for (uint256 k; k < ns.length; ++k) {
                uint256[] memory pieces = new uint256[](ns[k]);
                for (uint256 i; i < ns[k]; ++i) {
                    pieces[i] = 8000 ether / ns[k];
                }
                assertEq(_batch(key, true, pieces, id), single, "same transaction");
                assertEq(_state(h == 0), state);
                vm.revertToState(snap);
                uint256 sum;
                for (uint256 i; i < ns[k]; ++i) {
                    sum += _out(_swap(key, true, pieces[i], id), true);
                }
                assertEq(sum, single, "separate transactions");
                assertEq(_state(h == 0), state);
                vm.revertToState(snap);
            }
        }
    }

    /// @notice Splitting across three allocations from two curators on the same pool is the same as one trade: the
    ///         pricing state belongs to the pool, so the allocation a piece uses does not matter.
    function test_ADV_split_acrossAllocationsAndCurators() public {
        address curator2 = makeAddr("curator2");
        vm.startPrank(owner);
        vault.setCurator(curator2, true);
        vault.setCuratorCeiling(curator2, c1, VAULT_FUNDING);
        _openLimits(ISharedCommitmentVault.RiskScope.Curator, curator2);
        vm.stopPrank();
        for (uint256 h; h < 2; ++h) {
            PoolKey memory key = h == 0 ? keyA : keyB;
            uint256[3] memory ids;
            ids[0] = _allocate(key, c1, 3000 ether);
            ids[1] = _allocate(key, c1, 3000 ether);
            ISharedCommitmentVault.AllocationRequest memory r = _request(key, c1, 3000 ether);
            vm.prank(curator2);
            ids[2] = auth.activateDirect(r);
            uint256 big = _allocate(key, c1, 10_000 ether);

            uint256 snap = vm.snapshotState();
            uint256 single = _out(_swap(key, true, 7500 ether, big), true);
            vm.revertToState(snap);
            uint256 split;
            for (uint256 i; i < 3; ++i) {
                split += _out(_swap(key, true, 2500 ether, ids[i]), true);
            }
            assertEq(split, single);
            vm.revertToState(snap);
        }
    }

    // ------------------------------------------------------------------
    // Manipulation and round trips
    // ------------------------------------------------------------------

    /// @notice Hook A has no reverse leg to recover a manipulation. An attacker who pushes the level up to overcharge
    ///         a victim pays the higher fee rate on the push, and the opposite direction has its own level, so a round
    ///         trip pays both fees. The victim pays more; the vault keeps every extra fee.
    function test_ADV_hookA_pushLevel_costsAttacker() public {
        uint256 id01 = _allocate(keyA, c1, BIG);
        uint256 id10 = _allocate(keyA, c0, BIG);
        uint256 victimAlone = hookA.feeFor(keyA, true, 2000 ether);
        uint256 a0 = token0.balanceOf(attacker);
        token0.mint(attacker, 10_000 ether);
        token1.mint(attacker, 10_000 ether);
        vm.startPrank(attacker);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        uint256 got = _attackerSwap(keyA, true, 8000 ether, id01);
        uint256 victimFee = hookA.feeFor(keyA, true, 2000 ether);
        assertGt(victimFee, victimAlone, "victim pays more");
        _swap(keyA, true, 2000 ether, id01);
        uint256 back = _attackerSwap(keyA, false, got, id10);
        // Attacker started with 10,000 + a0 of currency0 and ends with less: both fees paid.
        assertLt(token0.balanceOf(attacker), 10_000 ether + a0);
        assertEq(10_000 ether + a0 - token0.balanceOf(attacker), 8000 ether - back);
        assertGt(8000 ether - back, hookA.feeFor(keyA, false, 0) + (8000 ether - got), "paid more than the first fee");
    }

    /// @notice Hook A sandwich: the front-run raises the victim's fee, but the attacker's exit is the other direction
    ///         at its own level, so the attacker cannot sell back into the raised price. Net result for the attacker
    ///         is a loss of both fees.
    function test_ADV_hookA_sandwichUnprofitable() public {
        uint256 id01 = _allocate(keyA, c1, BIG);
        uint256 id10 = _allocate(keyA, c0, BIG);
        token0.mint(attacker, 6000 ether);
        vm.startPrank(attacker);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
        uint256 got = _attackerSwap(keyA, true, 6000 ether, id01);
        _swap(keyA, true, 3000 ether, id01);
        uint256 back = _attackerSwap(keyA, false, got, id10);
        assertLt(back, 6000 ether);
    }

    // ------------------------------------------------------------------
    // Time
    // ------------------------------------------------------------------

    /// @notice Decay farming on Hook A: waiting dt between two pieces lowers the second piece's starting level by at
    ///         most K * dt / window, so its fee falls by at most that much flow at the maximum rate (plus one unit of
    ///         rounding). Waiting is the intended way for the price to recover; the bound is what it can be worth.
    ///         The fee is a difference of two rounded-up values, so when waiting lowers the exact fee by less than one
    ///         unit the integer fee can rise by one: waiting never costs more than one raw unit.
    function testFuzz_ADV_hookA_decayGainBounded(uint256 g1, uint256 g2, uint256 dt) public {
        g1 = bound(g1, 1 ether, 20_000 ether);
        g2 = bound(g2, 1 ether, 20_000 ether);
        dt = bound(dt, 0, 2 * A_WINDOW);
        uint256 id = _allocate(keyA, c1, BIG);
        _swap(keyA, true, g1, id);
        uint256 now0 = hookA.feeFor(keyA, true, g2);
        _wait(dt);
        uint256 later = hookA.feeFor(keyA, true, g2);
        assertLe(later, now0 + 1, "waiting costs at most one unit of rounding");
        if (later < now0) assertLe(now0 - later, (uint256(A_SCALE) * dt / A_WINDOW) * A_MAX_FEE / 1e6 + 1);
    }

    /// @notice Decay farming on Hook B: a trader who refills the position to the cap each time it decays can buy at
    ///         most cap * dt / window currency1 per dt near the cap's prices, never more than one cap's worth without
    ///         waiting. After half a window, the next sale is capped at half the cap.
    function test_ADV_hookB_decayRefillBounded() public {
        uint256 id = _allocate(keyB, c1, BIG);
        _swap(keyB, true, 9_950_493_836_207_795_336_338, id); // model: C_hat(cap), reaches the cap exactly
        assertEq(hookB.positionOf(keyB), int256(B_CAP));
        _wait(B_WINDOW / 2);
        int256 x = hookB.positionOf(keyB);
        assertEq(uint256(int256(B_CAP) - x), B_CAP * (B_WINDOW / 2) / B_WINDOW);
        // The most that can now be bought is back up to the cap.
        uint256 most = 20_000 ether;
        _expectSwapRevert(
            address(hookB), abi.encodeWithSelector(HookB_BoundedImpact.ImpactBoundExceeded.selector, x, B_CAP)
        );
        _swap(keyB, true, most, id);
    }

    // ------------------------------------------------------------------
    // Stale reference price
    // ------------------------------------------------------------------

    /// @notice The market values currency1 1%, 5% and 50% above Hook B's reference. The arbitrageur's best trade
    ///         is to buy until the marginal price meets the market or the cap stops it. LP loss at market prices
    ///         (model): 24.88 at +1% (stops at 4,962.8, where the marginal price is 1.01), 394.59 at +5% and 4,828.19
    ///         at +50% (both stopped by the 2% cap at 9,852.5). Cumulative pricing bounds the loss through the cap;
    ///         it does not remove it. Buying one more token at +1% earns less than it costs.
    function test_ADV_hookB_staleReference_lossBoundedByCap() public {
        uint256[3] memory bps = [uint256(100), 500, 5000];
        uint256[3] memory xs = [uint256(4_962_809_790_010_864_334_726), B_CAP, B_CAP];
        uint256[3] memory ins =
            [uint256(4_987_562_112_089_027_021_927), 9_950_493_836_207_795_336_338, 9_950_493_836_207_795_336_338];
        uint256[3] memory losses =
            [uint256(24_875_775_821_945_956_146), 394_586_038_284_180_052_724, 4_828_191_698_780_740_933_751];
        for (uint256 i; i < 3; ++i) {
            uint256 snap = vm.snapshotState();
            uint256 id = _allocate(keyB, c1, BIG);
            uint256 out = _out(_swap(keyB, true, ins[i], id), true);
            assertEq(out, xs[i]);
            assertEq(out * (10_000 + bps[i]) / 10_000 - ins[i], losses[i], "LP loss at market (model)");
            if (i == 0) {
                // One more token is bought above the market: the arbitrage optimum is the model's x*.
                uint256 extraIn = 1 ether;
                uint256 extraOut = hookB.quote(keyB, true, extraIn);
                assertLt(extraOut * 10_100 / 10_000, extraIn, "beyond x*, the arbitrage loses");
            } else {
                _expectSwapRevert(
                    address(hookB),
                    abi.encodeWithSelector(HookB_BoundedImpact.ImpactBoundExceeded.selector, int256(B_CAP), B_CAP)
                );
                _swap(keyB, true, 1 ether, id);
            }
            vm.revertToState(snap);
        }
    }

    /// @notice Hook A's fee never exceeds 50 bps, so with the market 1% above its reference an arbitrageur keeps
    ///         buying; nothing in the pricing stops it. The vault-scope flow limit does (FlowLimitExceeded).
    function test_ADV_hookA_staleReference_boundedOnlyByVaultLimits() public {
        uint256 id = _allocate(keyA, c1, BIG);
        vm.prank(owner);
        vault.setRiskLimit(ISharedCommitmentVault.RiskScope.Vault, address(0), c1, 50_000 ether, 10_000);
        uint256 bought;
        for (uint256 i; i < 5; ++i) {
            uint256 out = _out(_swap(keyA, true, 10_000 ether, id), true);
            assertGt(out * 10_100 / 10_000, 10_000 ether, "each trade profitable at market");
            bought += out;
        }
        vm.expectRevert();
        _swap(keyA, true, 10_000 ether, id);
        assertLe(bought, 50_000 ether);
    }

    /// @notice A reference-price change mid-position re-anchors the curve and keeps the position. Doubling P halves
    ///         every currency0 cost, so 100 currency0 now buys what 200 bought before (within the rounding of the two
    ///         integer cost functions). This is the stale-price lever the owner controls; it is not phased in.
    function test_ADV_hookB_priceChangeKeepsPosition() public {
        uint256 id = _allocate(keyB, c1, BIG);
        _swap(keyB, true, 5000 ether, id);
        int256 x = hookB.positionOf(keyB);
        uint256 twoHundredBefore = hookB.quote(keyB, true, 200 ether);
        vm.prank(hookOwner);
        hookB.configurePool(keyB, PRICE_1_1_X96 * 2, B_DEPTH, B_MAX_IMPACT, B_WINDOW);
        assertEq(hookB.positionOf(keyB), x);
        assertApproxEqAbs(hookB.quote(keyB, true, 100 ether), twoHundredBefore, 4);
    }

    // ------------------------------------------------------------------
    // Extremes
    // ------------------------------------------------------------------

    /// @notice The largest input either hook accepts (2^127 - 1) is refused cleanly: Hook B by its cap, Hook A by the
    ///         vault's quota. Dust is refused with ZeroOutput. Tiny and maximal depths trade correctly.
    function test_ADV_extremeInputsAndDepths() public {
        uint256 maxIn = uint256(uint128(type(int128).max));
        uint256 idA = _allocate(keyA, c1, BIG);
        uint256 idB = _allocate(keyB, c1, BIG);
        token0.mint(trader, maxIn);
        _expectSwapRevert(
            address(hookB), abi.encodeWithSelector(HookB_BoundedImpact.ImpactBoundExceeded.selector, int256(0), B_CAP)
        );
        _swap(keyB, true, maxIn, idB);
        vm.expectRevert(); // QuotaExceeded in the vault: the hook's output is computed, never wrapped
        _swap(keyA, true, maxIn, idA);
        _expectSwapRevert(address(hookB), abi.encodeWithSelector(BaseCompatibleHook.ZeroOutput.selector));
        _swap(keyB, true, 1, idB);

        // Depth 1,000 raw units, 99.9999% cap: position cap floor(1,000 * (1 - 1/sqrt(1.999999))) = 292 (model).
        vm.prank(hookOwner);
        hookB.configurePool(keyB, PRICE_1_1_X96, 1000, 999_999, B_WINDOW);
        (,,,, uint96 tiny) = hookB.poolConfig(keyB.toId());
        assertEq(tiny, 292);
        uint256 id10 = _allocate(keyB, c0, BIG);
        _swap(keyB, false, 200, id10);
        assertEq(hookB.positionOf(keyB), -200);
        // Depth at the maximum (2^95 - 1, about 3.96e10 tokens): a 1,000-token trade moves the price by 2.5e-8.
        _wait(B_WINDOW);
        vm.prank(hookOwner);
        hookB.configurePool(keyB, PRICE_1_1_X96, uint96(2 ** 95 - 1), B_MAX_IMPACT, B_WINDOW);
        uint256 out = _out(_swap(keyB, false, 1000 ether, id10), false);
        assertLe(out, 1000 ether);
        assertGe(out, 1000 ether - 1000 ether / 1e7); // impact q / V = 1,000 / 3.96e10 = 2.5e-8
    }

    /// @notice Hook A's level is checked against 2^128 before it is stored: a level that would pass it reverts with
    ///         AmountTooLarge instead of truncating.
    function test_ADV_hookA_levelOverflowRefused() public {
        uint256 maxIn = uint256(uint128(type(int128).max));
        // Huge K and zero fee keep the output at the input, and a huge allocation lets the vault fill it.
        vm.prank(hookOwner);
        hookA.configurePool(keyA, PRICE_1_1_X96, 0, 0, type(uint128).max, type(uint128).max, 0);
        assertEq(hookA.feeFor(keyA, true, maxIn), 0);
        assertEq(hookA.quote(keyA, true, maxIn), maxIn);
        // Two such inputs exceed 2^128 - 1 in level terms.
        vm.store(address(hookA), _flowSlot(keyA, true), bytes32(uint256(type(uint128).max)));
        vm.expectRevert(BaseCompatibleHook.AmountTooLarge.selector);
        hookA.quote(keyA, true, 1);
    }

    // ------------------------------------------------------------------
    // Settlement failure and cross-hook limits
    // ------------------------------------------------------------------

    /// @notice A swap whose input is never paid reverts the whole unlock after the hook has stored its new level;
    ///         the level is rolled back with everything else.
    function test_ADV_hookA_unpaidSettlementRollsBackLevel() public {
        uint256 id = _allocate(keyA, c1, BIG);
        _swap(keyA, true, 1000 ether, id);
        BatchSwapRouter.Step[] memory one = new BatchSwapRouter.Step[](1);
        one[0] = BatchSwapRouter.Step(keyA, true, 5000 ether, abi.encode(id));
        vm.prank(trader);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        batchRouter.run(one, new uint256[](0), BatchSwapRouter.Mode.SkipInputPayment);
        assertEq(hookA.flowLevel(keyA, true), 1000 ether);
    }

    /// @notice Splitting across the two hooks is not priced together: each hook has its own state, so a trader takes
    ///         the cheap start of each curve. What bounds the total is the vault-scope flow limit on the output asset,
    ///         which counts both hooks' flow.
    function test_ADV_crossHookSplit_boundedByVaultFlowLimit() public {
        uint256 idA = _allocate(keyA, c1, BIG);
        uint256 idB = _allocate(keyB, c1, BIG);
        uint256 snap = vm.snapshotState();
        uint256 oneHook = _out(_swap(keyB, true, 8000 ether, idB), true);
        vm.revertToState(snap);
        uint256 twoHooks =
            _out(_swap(keyA, true, 4000 ether, idA), true) + _out(_swap(keyB, true, 4000 ether, idB), true);
        assertGt(twoHooks, oneHook, "two curves are cheaper than one: not prevented by pricing");
        vm.revertToState(snap);

        vm.prank(owner);
        vault.setRiskLimit(ISharedCommitmentVault.RiskScope.Vault, address(0), c1, 6000 ether, 10_000);
        uint256 got = _out(_swap(keyA, true, 3000 ether, idA), true) + _out(_swap(keyB, true, 2900 ether, idB), true);
        assertLe(got, 6000 ether);
        vm.expectRevert();
        _swap(keyB, true, 200 ether, idB);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _attackerSwap(PoolKey memory key, bool zeroForOne, uint256 amountIn, uint256 id)
        internal
        returns (uint256)
    {
        address saved = trader;
        trader = attacker;
        BalanceDelta d = _swap(key, zeroForOne, amountIn, id);
        trader = saved;
        return _out(d, zeroForOne);
    }

    /// @dev Pricing state of the fixture pool of hook A (both levels) or hook B (position), as one word.
    function _state(bool isA) internal view returns (bytes32) {
        if (isA) return keccak256(abi.encode(hookA.flowLevel(keyA, true), hookA.flowLevel(keyA, false)));
        return bytes32(uint256(hookB.positionOf(keyB)));
    }

    /// @dev Storage slot of HookA's `_flow[id][zeroForOne]`. `coreParams` (inherited) is slot 0, `poolConfig` slot 1
    ///      and `_flow` slot 2 (the hook's only storage; immutables are in code).
    function _flowSlot(PoolKey memory key, bool zeroForOne) internal pure returns (bytes32) {
        bytes32 inner = keccak256(abi.encode(key.toId(), uint256(2)));
        return keccak256(abi.encode(zeroForOne, inner));
    }
}
