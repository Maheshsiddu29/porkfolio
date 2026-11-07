// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @notice Gas baselines for one exact-input swap through PoolSwapTest (test router) on the real PoolManager.
///         Numbers include router overhead and are meant only for relative comparison under identical settings.
///         Run with `forge test --match-contract GasBaseline -vv --isolate` for per-transaction cold/warm accounting.
contract GasBaselineTest is VaultTestBase {
    function test_gas_hookA_swap_zeroForOne() public {
        uint256 id = _allocate(keyA, c1, 100_000 ether);
        uint256 g = gasleft();
        _swap(keyA, true, 1000 ether, id);
        console2.log("hookA exact-in swap (router+PM+hook+vault) gas:", g - gasleft());
    }

    function test_gas_hookB_swap_oneForZero() public {
        uint256 id = _allocate(keyB, c0, 100_000 ether);
        uint256 g = gasleft();
        _swap(keyB, false, 1000 ether, id);
        console2.log("hookB exact-in swap (router+PM+hook+vault) gas:", g - gasleft());
    }

    /// @notice Reference: same router, same amount, a hookless v4 pool with native concentrated liquidity.
    function test_gas_nativeV4_swap_reference() public {
        PoolKey memory plain = PoolKey(c0, c1, 3000, 60, IHooks(address(0)));
        manager.initialize(plain, SQRT_PRICE_1_1);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        token0.mint(address(this), 10_000_000 ether);
        token1.mint(address(this), 10_000_000 ether);
        token0.approve(address(lp), type(uint256).max);
        token1.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(plain, ModifyLiquidityParams(-6000, 6000, 1_000_000 ether, 0), "");

        uint256 g = gasleft();
        _swapRaw(plain, true, -1000 ether, "");
        console2.log("native v4 CL exact-in swap (router+PM) gas:", g - gasleft());
    }

    function test_gas_allocate() public {
        uint256 g = gasleft();
        _allocate(keyA, c1, 100_000 ether);
        console2.log("allocate gas:", g - gasleft());
    }
}
