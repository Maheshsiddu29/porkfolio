// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {stdError} from "forge-std/StdError.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {AuthModeHook} from "../utils/AuthModeHook.sol";

/// @notice Approved decision 1 evaluation: exact per-swap ERC-6909 allowance vs the current standing
///         hook -> vault operator grant. Same hook logic, same pool shape, same amounts; only authorization differs.
///         Gas numbers: run `forge test --match-contract AuthorizationComparison --isolate -vvvv` and read the
///         PoolSwapTest::swap frame (see PHASE1A_REPORT.md §5).
///         The two test hooks compared here are compiled under the vault's optimizer profile, because the file
///         imports the vault; both modes are affected equally, so the comparison between them still holds.
contract AuthorizationComparisonTest is VaultTestBase {
    uint160 internal constant FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

    AuthModeHook internal opHook;
    AuthModeHook internal alHook;
    PoolKey internal opKey;
    PoolKey internal alKey;
    uint256 internal opId;
    uint256 internal alId;

    function setUp() public override {
        super.setUp();
        (opHook, opKey) = _deploy(0x0E1, AuthModeHook.Mode.Operator);
        (alHook, alKey) = _deploy(0x0A1, AuthModeHook.Mode.Allowance);
        opId = _allocate(opKey, c1, 100_000 ether);
        alId = _allocate(alKey, c1, 100_000 ether);
    }

    function test_gas_operatorMode_swap() public {
        uint256 g = gasleft();
        _swap(opKey, true, 1000 ether, opId);
        console2.log("operator-mode swap gas:", g - gasleft());
    }

    function test_gas_allowanceMode_swap() public {
        uint256 g = gasleft();
        _swap(alKey, true, 1000 ether, alId);
        console2.log("allowance-mode swap gas:", g - gasleft());
    }

    function test_bothModes_identicalAccounting() public {
        uint256 b0 = vault.backing(c0);
        uint256 b1 = vault.backing(c1);
        _swap(opKey, true, 1000 ether, opId);
        _swap(alKey, true, 1000 ether, alId);
        assertEq(vault.backing(c0) - b0, 2000 ether);
        assertEq(b1 - vault.backing(c1), 2000 ether);
        assertEq(vault.getAllocation(opId).consumed, vault.getAllocation(alId).consumed);
        assertEq(_claims(address(opHook), c0) + _claims(address(alHook), c0), 0);
    }

    /// @notice Residual authority after a swap. Allowance mode: none. Operator mode: a standing grant, but over
    ///         a hook balance that is zero at rest (claims exist only inside beforeSwap).
    function test_residualAuthority_afterSwap() public {
        _swap(opKey, true, 1000 ether, opId);
        _swap(alKey, true, 1000 ether, alId);
        assertEq(manager.allowance(address(alHook), address(vault), c0.toId()), 0, "allowance fully consumed");
        assertFalse(manager.isOperator(address(alHook), address(vault)));
        assertTrue(manager.isOperator(address(opHook), address(vault)), "standing operator grant");
        assertEq(_claims(address(opHook), c0) + _claims(address(opHook), c1), 0, "nothing for it to act on");
        // Neither mode grants anything over the VAULT's claims.
        assertFalse(manager.isOperator(address(vault), address(opHook)));
        assertFalse(manager.isOperator(address(vault), address(alHook)));
    }

    /// @notice An allowance one wei short makes the vault's pull fail; the whole swap reverts.
    function test_allowanceMode_isExact() public {
        alHook.setApproveShortfall(1);
        _expectSwapRevert(address(alHook), stdError.arithmeticError);
        _swap(alKey, true, 1000 ether, alId);
        assertEq(vault.getAllocation(alId).consumed, 0);
    }

    function _deploy(uint256 salt, AuthModeHook.Mode mode) internal returns (AuthModeHook h, PoolKey memory key) {
        address addr = address(uint160(salt << 140) | FLAGS);
        deployCodeTo("AuthModeHook.sol:AuthModeHook", abi.encode(manager, vault, mode), addr);
        h = AuthModeHook(addr);
        key = PoolKey(c0, c1, 3000, 60, IHooks(addr));
        manager.initialize(key, SQRT_PRICE_1_1);
        vm.prank(owner);
        vault.setConsumer(addr, true);
    }
}
