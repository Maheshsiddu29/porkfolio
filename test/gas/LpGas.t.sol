// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @notice Gas references for LP operations on the real PoolManager. Each test measures exactly one vault call.
///         Authoritative numbers come from `forge test --match-contract LpGas --isolate -vvvv` (vault call frame,
///         per-transaction cold/warm accounting); the logged gasleft deltas are in-test approximations only.
///         This file imports the vault, so the vault, PoolManager and hooks here are all built under the vault's
///         optimizer profile. Gas on the production builds comes from `test/bench/run.sh`.
contract LpGasTest is VaultTestBase {
    address internal lpA = makeAddr("lpA");
    address internal lpB = makeAddr("lpB");

    function setUp() public override {
        super.setUp();
        vm.startPrank(owner);
        vault.setCuratorCeiling(curator, c0, type(uint256).max);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        vm.stopPrank();
        _fundLp(lpA, 10_000_000 ether, 10_000_000 ether);
    }

    function test_gas_initialDeposit() public {
        SharedCommitmentVault v = new SharedCommitmentVault(manager, owner, c0, c1);
        token0.mint(owner, 1000 ether);
        token1.mint(owner, 1000 ether);
        vm.startPrank(owner);
        token0.approve(address(v), type(uint256).max);
        token1.approve(address(v), type(uint256).max);
        uint256 g = gasleft();
        v.initialDeposit(1000 ether, 1000 ether, lpA);
        console2.log("initialDeposit gas:", g - gasleft());
        vm.stopPrank();
    }

    function test_gas_deposit_newLp() public {
        vm.prank(lpA);
        uint256 g = gasleft();
        vault.deposit(1000 ether, type(uint256).max, type(uint256).max, lpA);
        console2.log("deposit (new LP, both assets) gas:", g - gasleft());
    }

    function test_gas_redeem_instant_full() public {
        vm.prank(lp0);
        uint256 g = gasleft();
        vault.redeem(1000 ether, 0, 0, lp0, false);
        console2.log("redeem instant (both assets) gas:", g - gasleft());
    }

    function test_gas_redeem_queued() public {
        _allocate(keyA, c1, uint128(VAULT_FUNDING)); // F1 = 0
        vm.prank(lp0);
        uint256 g = gasleft();
        vault.redeem(1000 ether, 0, 0, lp0, true);
        console2.log("redeem fully queued (request only) gas:", g - gasleft());
    }

    function test_gas_redeem_partialInstantPlusQueue() public {
        _allocate(keyA, c1, uint128(VAULT_FUNDING - 500 ether)); // F1 = 500
        vm.prank(lp0);
        uint256 g = gasleft();
        vault.redeem(1000 ether, 0, 0, lp0, true);
        console2.log("redeem partial instant + queued remainder gas:", g - gasleft());
    }

    function test_gas_processQueue_oneRequest() public {
        uint256 id = _allocate(keyA, c1, uint128(VAULT_FUNDING));
        _redeem(lp0, 1000 ether, true);
        vm.prank(owner);
        vault.release(id);
        uint256 g = gasleft();
        vault.processQueue(1);
        console2.log("processQueue(1) finalize one request gas:", g - gasleft());
    }

    function test_gas_claim() public {
        uint256 id = _allocate(keyA, c1, uint128(VAULT_FUNDING));
        (,,, uint256 req) = _redeem(lp0, 1000 ether, true);
        vm.prank(owner);
        vault.release(id);
        vault.processQueue(1);
        vm.prank(lp0);
        uint256 g = gasleft();
        vault.claim(req);
        console2.log("claim (both assets) gas:", g - gasleft());
    }

    function test_gas_cancelRequest() public {
        _allocate(keyA, c1, uint128(VAULT_FUNDING));
        (,,, uint256 req) = _redeem(lp0, 1000 ether, true);
        vm.prank(lp0);
        uint256 g = gasleft();
        vault.cancelRequest(req);
        console2.log("cancelRequest gas:", g - gasleft());
    }

    // ---- Paths affected by inline queue processing in redeem ----

    /// A small request is pending but deliverable (inventory was released); lp0 then redeems.
    /// The head is finalized inline and lp0 exits instantly, instead of being queued behind it.
    function test_gas_redeem_whileHeadDeliverable() public {
        _depositShares(lpB, 10 ether);
        uint256 id = _allocate(keyA, c1, uint128(vault.admissibleCapacity(c1)));
        _redeem(lpB, 10 ether, true);
        vm.prank(owner);
        vault.release(id);
        vm.prank(lp0);
        uint256 g = gasleft();
        vault.redeem(1000 ether, 0, 0, lp0, true);
        console2.log("redeem while a deliverable request is pending gas:", g - gasleft());
    }

    /// The head cannot be served (token1 fully committed); lp0's redeem is queued either way.
    function test_gas_redeem_whileHeadBlocked() public {
        _depositShares(lpB, 10 ether);
        _allocate(keyA, c1, uint128(vault.admissibleCapacity(c1)));
        _redeem(lpB, 10 ether, true);
        vm.prank(lp0);
        uint256 g = gasleft();
        vault.redeem(1000 ether, 0, 0, lp0, true);
        console2.log("redeem while the head is blocked gas:", g - gasleft());
    }

    /// Ten canceled requests ahead of one live request: cost of skipping them.
    function test_gas_processQueue_skipTenCanceled() public {
        _depositShares(lpB, 11 ether);
        uint256 id = _allocate(keyA, c1, uint128(vault.admissibleCapacity(c1)));
        for (uint256 i; i < 11; ++i) {
            _redeem(lpB, 1 ether, true);
        }
        for (uint256 r = 1; r <= 10; ++r) {
            vm.prank(lpB);
            vault.cancelRequest(r);
        }
        vm.prank(owner);
        vault.release(id);
        uint256 g = gasleft();
        vault.processQueue(11);
        console2.log("processQueue over 10 canceled + 1 live gas:", g - gasleft());
    }
}
