// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {IndependentHookCIntegrationTest} from "../integration/IndependentHookC.t.sol";

/// @notice Isolated gas comparison for the same C allocation id after creating 200 bonded allocations. In the
///         one-live variant, 199 are canceled before measurement. All contracts and their slots are cooled, so
///         prior setup does not make one variant's swap artificially warm. The target allocation and the direction
///         have the same storage transitions in both cases; only the count of other live allocations differs.
contract IndependentHookCGasTest is IndependentHookCIntegrationTest {
    function _coolPath(address hook) internal {
        vm.cool(address(vault));
        vm.cool(hook);
        vm.cool(address(manager));
        vm.cool(address(swapRouter));
        vm.cool(address(token0));
        vm.cool(address(token1));
    }

    function _measure(bool keepAll) internal returns (uint256 gasUsed) {
        _registerDirect();
        uint256[200] memory ids;
        vm.pauseGasMetering();
        for (uint256 i; i < 200; ++i) {
            ids[i] = _allocate(keyC, c1, 10 ether);
        }
        if (!keepAll) {
            for (uint256 i; i < 199; ++i) {
                vm.prank(curator);
                vault.cancelAllocation(ids[i]);
            }
        }
        assertEq(ids[199], 200);
        assertEq(lens.getAllocation(vault, ids[199]).consumed, 0);
        assertEq(lens.reserved(vault, c1), keepAll ? 2000 ether : 10 ether);
        _coolPath(address(hookC));
        vm.resumeGasMetering();

        uint256 beforeGas = gasleft();
        _swapC(1 ether, ids[199], 0);
        gasUsed = beforeGas - gasleft();
        assertEq(lens.getAllocation(vault, ids[199]).consumed, 0.999 ether);
        _assertAccountingConsistent();
    }

    function test_bench_oneLiveAllocation() public {
        uint256 gasUsed = _measure(false);
        console2.log("C04 BENCH Hook C one live allocation, id 200", gasUsed);
    }

    function test_bench_200LiveAllocations() public {
        uint256 gasUsed = _measure(true);
        console2.log("C04 BENCH Hook C 200 live allocations, id 200", gasUsed);
    }

    /// @notice Same 1,000-unit input and one allocation in the same bonded fixture. The price policies and pool
    ///         identifiers differ, so these are full-swap measurements, not an isolated hook-code premium.
    function test_bench_threeHooksSameFixture() public {
        _registerDirect();
        uint256 snap = vm.snapshotState();
        uint256 id = _allocate(keyA, c1, 2000 ether);
        _coolPath(address(hookA));
        uint256 beforeGas = gasleft();
        _swap(keyA, true, 1000 ether, id);
        console2.log("C04 BENCH Hook A 1000 bonded", beforeGas - gasleft());
        vm.revertToState(snap);

        snap = vm.snapshotState();
        id = _allocate(keyB, c1, 2000 ether);
        _coolPath(address(hookB));
        beforeGas = gasleft();
        _swap(keyB, true, 1000 ether, id);
        console2.log("C04 BENCH Hook B 1000 bonded", beforeGas - gasleft());
        vm.revertToState(snap);

        id = _allocate(keyC, c1, 2000 ether);
        _coolPath(address(hookC));
        beforeGas = gasleft();
        _swapC(1000 ether, id, 998 ether);
        console2.log("C04 BENCH Hook C 1000 bonded", beforeGas - gasleft());
    }
}
