// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {HookB_BoundedImpact} from "../../src/hooks/HookB_BoundedImpact.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {BatchSwapRouter} from "../utils/BatchSwapRouter.sol";

/// @notice Trade splitting: one trade versus the same total input split into several swaps inside ONE transaction
///         (one PoolManager unlock, via BatchSwapRouter), from identical starting state. These scenarios pinned the
///         per-swap pricing that splitting used to beat (docs/architecture/TRADE_SPLITTING.md records those numbers:
///         Hook A 7,967.2 -> 7,979.82 over 8 pieces, Hook B 999 -> 999.8946 over 10 pieces, and a cap that refused one
///         swap of 5,000 but accepted five of 1,000). They now assert the opposite: the split receives no more than the
///         single trade, and the cap bounds the aggregate.
/// @dev Expected outputs are exact values from simulations/pricing/cumulative.py with the shared fixture parameters
///      (1:1 reference price, so the conversion is exact and the split and single outputs are equal to the wei).
contract TradeSplittingTest is VaultTestBase {
    uint128 internal constant QUOTA = 10_000 ether;

    /// @dev Runs `n` equal exact-input pieces of `total` in one unlock and returns the summed output.
    function _batch(PoolKey memory key, uint256 total, uint256 n, uint256 id) internal returns (uint256 out) {
        BatchSwapRouter.Step[] memory steps = new BatchSwapRouter.Step[](n);
        for (uint256 i; i < n; ++i) {
            steps[i] = BatchSwapRouter.Step(key, true, total / n, abi.encode(id));
        }
        vm.prank(trader);
        BalanceDelta[] memory d = batchRouter.run(steps, new uint256[](0), BatchSwapRouter.Mode.Settle);
        for (uint256 i; i < n; ++i) {
            out += uint256(int256(d[i].amount1()));
        }
    }

    /// @notice Hook A charges the integral of its fee rate over the flow, so the pieces' fees telescope: 8,000 in
    ///         pays 18.4 in fees as one swap, two swaps or eight swaps, and receives exactly 7,981.6 each time.
    function test_TS_hookA_splitPaysSameFee() public {
        uint256 id = _allocate(keyA, c1, QUOTA);
        uint256 snap = vm.snapshotState();

        uint256 single = _batch(keyA, 8000 ether, 1, id);
        assertEq(single, 7981.6 ether, "single: fee 18.4");
        assertEq(hookA.flowLevel(keyA, true), 8000 ether);
        vm.revertToState(snap);

        assertEq(_batch(keyA, 8000 ether, 2, id), single, "2 pieces");
        vm.revertToState(snap);

        assertEq(_batch(keyA, 8000 ether, 8, id), single, "8 pieces");
        assertEq(hookA.flowLevel(keyA, true), 8000 ether, "same final level");
        _assertAccountingConsistent();
    }

    /// @notice Hook B prices the position, not the trade: 1,000 in moves the position to 999.000999... whether as one
    ///         swap or ten, and the output is identical.
    function test_TS_hookB_splitPaysSameImpact() public {
        uint256 id = _allocate(keyB, c1, QUOTA);
        uint256 snap = vm.snapshotState();

        uint256 single = _batch(keyB, 1000 ether, 1, id);
        assertEq(single, 999_000_999_000_999_000_999, "single");
        assertEq(hookB.positionOf(keyB), int256(single));
        vm.revertToState(snap);

        assertEq(_batch(keyB, 1000 ether, 10, id), single, "10 pieces");
        assertEq(hookB.positionOf(keyB), int256(single), "same final position");
        _assertAccountingConsistent();
    }

    /// @notice The impact cap bounds the aggregate position. Depth 200,000 with a 1% cap allows |x| <= 992.56: one
    ///         swap of 5,000 reverts, and so does every split of it into 5, 10 or 100 swaps in one transaction. Spread
    ///         over separate transactions at one timestamp, the pieces execute only until the cap: 19 of 100.
    function test_TS_hookB_capIsAggregate_splitCannotBypassIt() public {
        vm.prank(hookOwner);
        hookB.configurePool(keyB, PRICE_1_1_X96, 200_000 ether, 10_000, B_WINDOW);
        uint256 cap = 992_561_958_002_172_866_945;
        (,,,, uint96 storedCap) = hookB.poolConfig(keyB.toId());
        assertEq(storedCap, cap);
        uint256 id = _allocate(keyB, c1, QUOTA);

        uint256[4] memory ns = [uint256(1), 5, 10, 100];
        for (uint256 k; k < ns.length; ++k) {
            uint256 n = ns[k];
            BatchSwapRouter.Step[] memory steps = new BatchSwapRouter.Step[](n);
            for (uint256 i; i < n; ++i) {
                steps[i] = BatchSwapRouter.Step(keyB, true, 5000 ether / n, abi.encode(id));
            }
            vm.prank(trader);
            vm.expectRevert(); // the piece that crosses the cap reverts the whole unlock
            batchRouter.run(steps, new uint256[](0), BatchSwapRouter.Mode.Settle);
            assertEq(hookB.positionOf(keyB), 0, "nothing executed");
        }

        uint256 executed;
        for (uint256 i; i < 100; ++i) {
            int256 x = hookB.positionOf(keyB);
            if (i == 19) {
                _expectSwapRevert(
                    address(hookB), abi.encodeWithSelector(HookB_BoundedImpact.ImpactBoundExceeded.selector, x, cap)
                );
                _swap(keyB, true, 50 ether, id);
                break;
            }
            executed += uint256(int256(_swap(keyB, true, 50 ether, id).amount1()));
        }
        assertEq(hookB.positionOf(keyB), 945_508_833_043_045_533_714, "19 pieces, below the cap");
        assertEq(executed, 945_508_833_043_045_533_714);
        assertEq(vault.getAllocation(id).consumed, executed);
        _assertAccountingConsistent();
    }

    /// @notice Measured cost of splitting: gas of n pieces in one unlock versus one swap. Logged, not asserted.
    ///         Splitting no longer saves fees, so this is now pure overhead for a splitter.
    function test_TS_gasPerExtraPiece() public {
        uint256 id = _allocate(keyB, c1, QUOTA);
        uint256 snap = vm.snapshotState();
        uint256 g = gasleft();
        _batch(keyB, 1000 ether, 1, id);
        uint256 g1 = g - gasleft();
        vm.revertToState(snap);
        g = gasleft();
        _batch(keyB, 1000 ether, 10, id);
        uint256 g10 = g - gasleft();
        console2.log("gas, 1 swap in one unlock:", g1);
        console2.log("gas, 10 swaps in one unlock:", g10);
        console2.log("marginal gas per extra piece:", (g10 - g1) / 9);
    }
}
