// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {BaseCompatibleHook} from "../../src/hooks/BaseCompatibleHook.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {BatchSwapRouter} from "../utils/BatchSwapRouter.sol";

/// @notice End-to-end swaps through the real Uniswap v4 PoolManager, consuming shared vault liquidity.
contract SharedLiquiditySwapTest is VaultTestBase {
    using StateLibrary for *;

    uint128 internal constant QUOTA = 10_000 ether;

    // ------------------------------------------------------------------
    // Happy paths
    // ------------------------------------------------------------------

    /// @notice Executable demonstration: authorised exact-input swap, HookA, token0 -> token1.
    function test_happyPath_hookA_zeroForOne() public {
        uint256 id = _allocate(keyA, c1, QUOTA);
        uint256 amountIn = 1000 ether;

        // utilisation after trade = 1000/10000 = 10% -> fee = 500 + 4500*0.1 = 950 pips
        uint256 expectedOut = amountIn * (1e6 - 950) / 1e6;
        assertEq(hookA.quote(keyA, true, amountIn, id), expectedOut, "quote");

        uint256 t0Before = token0.balanceOf(trader);
        uint256 t1Before = token1.balanceOf(trader);
        uint256 b0Before = vault.backing(c0);
        uint256 b1Before = vault.backing(c1);

        vm.expectEmit(true, true, false, true, address(vault));
        emit ISharedCommitmentVault.AllocationConsumed(id, address(hookA), amountIn, expectedOut, uint128(expectedOut));
        BalanceDelta delta = _swap(keyA, true, amountIn, id);

        // Swapper's PoolManager delta: pays exactly amountIn, receives exactly the hook's quote.
        assertEq(delta.amount0(), -int128(int256(amountIn)), "delta0");
        assertEq(delta.amount1(), int128(int256(expectedOut)), "delta1");
        assertEq(t0Before - token0.balanceOf(trader), amountIn, "trader paid");
        assertEq(token1.balanceOf(trader) - t1Before, expectedOut, "trader received");

        // Vault: input claims in, exactly the authorised output claims out.
        assertEq(vault.backing(c0) - b0Before, amountIn, "vault in");
        assertEq(b1Before - vault.backing(c1), expectedOut, "vault out");
        assertEq(vault.reserved(c1), QUOTA - expectedOut, "reserved");
        assertEq(vault.getAllocation(id).consumed, expectedOut, "consumed");

        _assertAccountingConsistent();
    }

    function test_happyPath_hookB_oneForZero() public {
        uint256 id = _allocate(keyB, c0, QUOTA);
        uint256 amountIn = 1000 ether;
        // impact = ceil(1000 * 10_000 / 10_000) = 1000 pips
        uint256 expectedOut = amountIn * (1e6 - 1000) / 1e6;

        BalanceDelta delta = _swap(keyB, false, amountIn, id);

        assertEq(delta.amount1(), -int128(int256(amountIn)));
        assertEq(delta.amount0(), int128(int256(expectedOut)));
        assertEq(vault.reserved(c0), QUOTA - expectedOut);
        _assertAccountingConsistent();
    }

    function test_bothDirections_bothHooks() public {
        uint256 a01 = _allocate(keyA, c1, QUOTA);
        uint256 a10 = _allocate(keyA, c0, QUOTA);
        uint256 b01 = _allocate(keyB, c1, QUOTA);
        uint256 b10 = _allocate(keyB, c0, QUOTA);

        _swap(keyA, true, 100 ether, a01);
        _swap(keyA, false, 100 ether, a10);
        _swap(keyB, true, 100 ether, b01);
        _swap(keyB, false, 100 ether, b10);

        assertGt(vault.getAllocation(a01).consumed, 0);
        assertGt(vault.getAllocation(a10).consumed, 0);
        assertGt(vault.getAllocation(b01).consumed, 0);
        assertGt(vault.getAllocation(b10).consumed, 0);
        _assertAccountingConsistent();
    }

    /// @notice The hook consumes the whole specified amount, so the pool's CL state is never touched.
    function test_nativeCurveNotExecuted_poolStateUnchanged() public {
        uint256 id = _allocate(keyA, c1, QUOTA);
        (uint160 sqrtBefore, int24 tickBefore,,) = manager.getSlot0(keyA.toId());

        _swap(keyA, true, 1000 ether, id);

        (uint160 sqrtAfter, int24 tickAfter,,) = manager.getSlot0(keyA.toId());
        assertEq(sqrtAfter, sqrtBefore, "sqrtPrice moved");
        assertEq(tickAfter, tickBefore, "tick moved");
        assertEq(manager.getLiquidity(keyA.toId()), 0, "pool has native liquidity");
    }

    /// @notice Pool.swap returns early when amountToSwap == 0, BEFORE validating sqrtPriceLimitX96
    ///         (v4-core Pool.sol:320). A limit that native execution would reject is silently ignored, so
    ///         slippage protection must come from the router (min-out), not from the price limit.
    function test_priceLimitIsNotEnforcedForFullyInterceptedSwaps() public {
        uint256 id = _allocate(keyA, c1, QUOTA);
        // For zeroForOne the native path would revert PriceLimitAlreadyExceeded with limit >= current price.
        vm.prank(trader);
        BalanceDelta delta = swapRouter.swap(
            keyA,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(id)
        );
        assertGt(delta.amount1(), 0);
    }

    function test_nativeLiquidityAdd_isRejected() public {
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(manager);
        _expectHookRevert(
            address(hookA),
            IHooks.beforeAddLiquidity.selector,
            abi.encodeWithSelector(BaseCompatibleHook.NativeLiquidityDisabled.selector)
        );
        lpRouter.modifyLiquidity(keyA, ModifyLiquidityParams(-60, 60, 1 ether, 0), "");
    }

    // ------------------------------------------------------------------
    // Shared reserve across two distinct hooks
    // ------------------------------------------------------------------

    /// @notice Two different hooks on two different pools draw on the same token1 backing; each is limited
    ///         by its own allocation, and exhausting one does not reduce the other.
    function test_twoHooks_shareReserve_quotaIsolation() public {
        uint256 idA = _allocate(keyA, c1, 2000 ether);
        uint256 idB = _allocate(keyB, c1, 2000 ether);
        assertEq(vault.reserved(c1), 4000 ether);

        // Drain most of A's quota with two swaps.
        _swap(keyA, true, 1500 ether, idA);
        uint256 remainingA = 2000 ether - vault.getAllocation(idA).consumed;
        assertLt(remainingA, 600 ether);

        // A cannot go beyond its own quota even though free backing exists ...
        uint256 tooMuchOut = hookA.quote(keyA, true, 600 ether, idA);
        _expectSwapRevert(
            address(hookA),
            abi.encodeWithSelector(ISharedCommitmentVault.QuotaExceeded.selector, tooMuchOut, remainingA)
        );
        _swap(keyA, true, 600 ether, idA);

        // ... and B's full reserved slice is untouched.
        assertEq(vault.getAllocation(idB).consumed, 0);
        _swap(keyB, true, 1000 ether, idB);
        assertGt(vault.getAllocation(idB).consumed, 0);
        _assertAccountingConsistent();
    }

    /// @notice Two hooks consumed inside ONE unlock(); router asserts hook & vault deltas are zero after
    ///         each swap and that NonzeroDeltaCount is zero after settlement.
    function test_sameTx_twoHooks_deltasReconcile() public {
        uint256 idA = _allocate(keyA, c1, QUOTA);
        uint256 idB = _allocate(keyB, c0, QUOTA);

        BatchSwapRouter.Step[] memory steps = new BatchSwapRouter.Step[](2);
        steps[0] = BatchSwapRouter.Step(keyA, true, 500 ether, abi.encode(idA));
        steps[1] = BatchSwapRouter.Step(keyB, false, 500 ether, abi.encode(idB));

        vm.prank(trader);
        BalanceDelta[] memory deltas = batchRouter.run(steps, new uint256[](0), BatchSwapRouter.Mode.Settle);

        assertEq(batchRouter.lastNonzeroDeltaCount(), 0, "unsettled deltas");
        assertEq(deltas[0].amount0(), -500 ether);
        assertEq(deltas[1].amount1(), -500 ether);
        assertGt(deltas[0].amount1(), 0);
        assertGt(deltas[1].amount0(), 0);
        _assertAccountingConsistent();
    }

    /// @notice Same-transaction contention on one allocation: the second swap over-draws the quota, so the
    ///         ENTIRE transaction (including the first, valid swap) reverts. No partial state survives.
    function test_sameTx_contention_atomicRollback() public {
        uint256 id = _allocate(keyA, c1, 1500 ether);

        uint256 backing0 = vault.backing(c0);
        uint256 backing1 = vault.backing(c1);
        uint256 reserved1 = vault.reserved(c1);
        uint256 trader0 = token0.balanceOf(trader);
        uint256 trader1 = token1.balanceOf(trader);

        BatchSwapRouter.Step[] memory steps = new BatchSwapRouter.Step[](2);
        steps[0] = BatchSwapRouter.Step(keyA, true, 1000 ether, abi.encode(id));
        steps[1] = BatchSwapRouter.Step(keyA, true, 1000 ether, abi.encode(id));

        // First swap: util = ceil(1e6 * 1000/1500) = 666_667 pips; fee = 500 + ceil(4500 * 0.666667) = 3501 pips.
        uint256 out1 = 1000 ether * (1e6 - 3501) / 1e6;
        assertEq(hookA.quote(keyA, true, 1000 ether, id), out1);
        // Second swap: utilisation capped at 100% -> fee 5000 pips; exceeds the 1500 - out1 remaining.
        uint256 out2 = 1000 ether * (1e6 - 5000) / 1e6;

        vm.prank(trader);
        _expectSwapRevert(
            address(hookA),
            abi.encodeWithSelector(ISharedCommitmentVault.QuotaExceeded.selector, out2, 1500 ether - out1)
        );
        batchRouter.run(steps, new uint256[](0), BatchSwapRouter.Mode.Settle);

        assertEq(vault.backing(c0), backing0);
        assertEq(vault.backing(c1), backing1);
        assertEq(vault.reserved(c1), reserved1);
        assertEq(vault.getAllocation(id).consumed, 0);
        assertEq(token0.balanceOf(trader), trader0);
        assertEq(token1.balanceOf(trader), trader1);
        _assertAccountingConsistent();
    }

    /// @notice Router-level slippage bound (the only effective one, see price-limit test) rolls back everything.
    function test_minOut_violation_rollsBack() public {
        uint256 id = _allocate(keyA, c1, QUOTA);
        BatchSwapRouter.Step[] memory steps = new BatchSwapRouter.Step[](1);
        steps[0] = BatchSwapRouter.Step(keyA, true, 1000 ether, abi.encode(id));
        uint256[] memory minOut = new uint256[](1);
        minOut[0] = 1000 ether; // impossible: fee is non-zero
        uint256 out = hookA.quote(keyA, true, 1000 ether, id);

        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(BatchSwapRouter.InsufficientOutput.selector, 0, out, minOut[0]));
        batchRouter.run(steps, minOut, BatchSwapRouter.Mode.Settle);
        assertEq(vault.getAllocation(id).consumed, 0);
    }

    // ------------------------------------------------------------------
    // Fuzzed conservation through the real PoolManager
    // ------------------------------------------------------------------

    function testFuzz_hookA_exactAccounting(uint256 amountIn, bool zeroForOne) public {
        amountIn = bound(amountIn, 1e6, 5000 ether);
        uint256 id = _allocate(keyA, zeroForOne ? c1 : c0, QUOTA);
        _checkSwapAccounting(address(hookA), zeroForOne, amountIn, id);
    }

    function testFuzz_hookB_exactAccounting(uint256 amountIn, bool zeroForOne) public {
        amountIn = bound(amountIn, 1e6, 5000 ether);
        uint256 id = _allocate(keyB, zeroForOne ? c1 : c0, QUOTA);
        _checkSwapAccounting(address(hookB), zeroForOne, amountIn, id);
    }

    function _checkSwapAccounting(address hook, bool zeroForOne, uint256 amountIn, uint256 id) internal {
        bool isA = hook == address(hookA);
        uint256 quoted = isA ? hookA.quote(keyA, zeroForOne, amountIn, id) : hookB.quote(keyB, zeroForOne, amountIn, id);
        (uint256 inBefore, uint256 outBefore) =
            zeroForOne ? (vault.backing(c0), vault.backing(c1)) : (vault.backing(c1), vault.backing(c0));

        BalanceDelta d = _swap(isA ? keyA : keyB, zeroForOne, amountIn, id);

        (int128 dIn, int128 dOut) = zeroForOne ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        assertEq(dIn, -int128(int256(amountIn)), "swapper input delta");
        assertEq(dOut, int128(int256(quoted)), "swapper output delta");
        (uint256 inAfter, uint256 outAfter) =
            zeroForOne ? (vault.backing(c0), vault.backing(c1)) : (vault.backing(c1), vault.backing(c0));
        assertEq(inAfter - inBefore, amountIn, "vault input");
        assertEq(outBefore - outAfter, quoted, "vault output");
        // Price floor (0.99 in per out) held.
        assertGe(amountIn * 100, quoted * 99, "below floor");
        _assertAccountingConsistent();
    }
}
