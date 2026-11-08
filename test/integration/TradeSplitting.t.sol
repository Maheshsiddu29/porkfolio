// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {HookB_BoundedImpact} from "../../src/hooks/HookB_BoundedImpact.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {BatchSwapRouter} from "../utils/BatchSwapRouter.sol";

/// @notice Characterization tests for trade splitting. They pin how both hooks price one trade versus the same
///         total input split into several swaps inside ONE transaction (one PoolManager unlock, via
///         BatchSwapRouter), on identical starting state. They document current behaviour; they do not assert
///         that the behaviour is desirable. See docs/architecture/TRADE_SPLITTING.md.
/// @dev Expected outputs are exact values from an independent integer model of the hook formulas at a 1:1
///      reference price (gross == amountIn), with `consumed` advancing by each piece's net output:
///        HookA: u = ceil((consumed + gross) * 1e6 / maxOut), fee = base + ceil((max - base) * u / 1e6),
///               out = floor(gross * (1e6 - fee) / 1e6)
///        HookB: impact = ceil(gross * k / (maxOut - consumed)), out = floor(gross * (1e6 - impact) / 1e6)
///      Each split run is compared against the single-trade run from the same state snapshot, and every
///      split piece still passes the vault's 1:1 floor (otherwise the batch would revert).
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

    /// @notice HookA charges post-trade utilisation on the whole trade. Splitting 8,000 into 8 pieces charges the
    ///         early pieces at lower utilisation: total cost falls from 32.8 to 20.18 (-38%). The limit as n grows
    ///         is about half the utilisation component (model: 18.39 at n = 1,000).
    function test_TS_hookA_splitPaysLessFee() public {
        uint256 id = _allocate(keyA, c1, QUOTA);
        uint256 snap = vm.snapshotState();

        uint256 single = _batch(keyA, 8000 ether, 1, id);
        assertEq(single, 7967.2 ether, "single: fee 4,100 pips");
        vm.revertToState(snap);

        uint256 two = _batch(keyA, 8000 ether, 2, id);
        assertEq(two, 7974.416 ether, "2 pieces");
        vm.revertToState(snap);

        uint256 eight = _batch(keyA, 8000 ether, 8, id);
        assertEq(eight, 7979.82 ether, "8 pieces");
        assertGt(eight, two);
        assertGt(two, single);
        _assertAccountingConsistent();
    }

    /// @notice HookB charges impact on each trade relative to remaining capacity, so splitting cuts the impact
    ///         paid roughly by the number of pieces: 1,000 in one swap costs 1.0; in 10 swaps it costs 0.1054.
    function test_TS_hookB_splitAvoidsImpact() public {
        uint256 id = _allocate(keyB, c1, QUOTA);
        uint256 snap = vm.snapshotState();

        uint256 single = _batch(keyB, 1000 ether, 1, id);
        assertEq(single, 999 ether, "single: impact 1,000 pips");
        vm.revertToState(snap);

        uint256 ten = _batch(keyB, 1000 ether, 10, id);
        assertEq(ten, 999.8946 ether, "10 pieces");
        _assertAccountingConsistent();
    }

    /// @notice The impact cap is per swap, not per allocation or per transaction. With the cap binding
    ///         (impact at full quota 5% > cap 1%), one swap of 5,000 reverts with ImpactBoundExceeded(25,000,
    ///         10,000), while the same 5,000 as five swaps in one transaction all pass the cap (largest piece
    ///         8,301 pips) and execute.
    function test_TS_hookB_capIsPerSwap_splitBypassesIt() public {
        vm.prank(hookOwner);
        hookB.configurePool(keyB, PRICE_1_1_X96, 50_000, 10_000);
        uint256 id = _allocate(keyB, c1, QUOTA);

        BatchSwapRouter.Step[] memory one = new BatchSwapRouter.Step[](1);
        one[0] = BatchSwapRouter.Step(keyB, true, 5000 ether, abi.encode(id));
        _expectSwapRevert(
            address(hookB), abi.encodeWithSelector(HookB_BoundedImpact.ImpactBoundExceeded.selector, 25_000, 10_000)
        );
        vm.prank(trader);
        batchRouter.run(one, new uint256[](0), BatchSwapRouter.Mode.Settle);

        uint256 five = _batch(keyB, 5000 ether, 5, id);
        assertEq(five, 4967.778 ether, "5 pieces, all within the per-swap cap");
        assertEq(vault.getAllocation(id).consumed, five);
        _assertAccountingConsistent();
    }

    /// @notice Measured cost of splitting: gas of n pieces in one unlock versus one swap. Logged, not asserted;
    ///         the economic threshold depends on the gas price and token value, which these tests do not model.
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
