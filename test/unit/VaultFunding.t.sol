// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @notice Funding (ERC-20 -> ERC-6909) and withdrawal paths through the real PoolManager, and the
///         reserve condition's limits on exit liquidity.
contract VaultFundingTest is VaultTestBase {
    function test_deposit_mintsRealClaimsBackedByErc20() public view {
        // setUp deposited VAULT_FUNDING of each token through unlock -> sync -> transfer -> settle -> mint.
        assertEq(_claims(address(vault), c0), VAULT_FUNDING);
        assertEq(_claims(address(vault), c1), VAULT_FUNDING);
        assertEq(token0.balanceOf(address(manager)), VAULT_FUNDING, "ERC-20 actually held by PoolManager");
        assertEq(token1.balanceOf(address(manager)), VAULT_FUNDING);
        assertEq(vault.backing(c0), VAULT_FUNDING);
        assertEq(token0.balanceOf(owner), 0);
    }

    function test_withdraw_burnsClaimsAndReturnsErc20() public {
        address to = makeAddr("recipient");
        vm.prank(owner);
        vault.withdraw(c0, 400 ether, to);
        assertEq(token0.balanceOf(to), 400 ether);
        assertEq(_claims(address(vault), c0), VAULT_FUNDING - 400 ether);
        assertEq(vault.backing(c0), VAULT_FUNDING - 400 ether);
        _assertAccountingConsistent();
    }

    function test_funding_accessControlAndValidation() public {
        vm.prank(attacker);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.deposit(c0, 1);

        vm.prank(attacker);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.withdraw(c0, 1, attacker);

        vm.startPrank(owner);
        vm.expectRevert(ISharedCommitmentVault.NativeCurrencyUnsupported.selector);
        vault.deposit(Currency.wrap(address(0)), 1);
        vm.expectRevert(ISharedCommitmentVault.ZeroAmount.selector);
        vault.deposit(c0, 0);
        vm.expectRevert(ISharedCommitmentVault.AmountTooLarge.selector);
        vault.deposit(c0, uint256(uint128(type(int128).max)) + 1);
        vm.expectRevert(ISharedCommitmentVault.ZeroAddress.selector);
        vault.withdraw(c0, 1, address(0));
        vm.stopPrank();
    }

    function test_admin_onlyOwner() public {
        vm.startPrank(attacker);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setConsumer(attacker, true);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setCuratorCeiling(attacker, c0, 1);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setBufferFloor(c0, 0);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setPaused(true);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.transferOwnership(attacker);
        vm.stopPrank();

        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        vault.transferOwnership(newOwner);
        assertEq(vault.owner(), newOwner);
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(ISharedCommitmentVault.ZeroAddress.selector);
        new SharedCommitmentVault(IPoolManager(address(0)), owner);
        vm.expectRevert(ISharedCommitmentVault.ZeroAddress.selector);
        new SharedCommitmentVault(manager, address(0));
    }

    /// @notice RISKS.md R1 counterexample, executable. With C = 100, ΣQ = 80, the reserve condition
    ///         R + ΣQ <= C holds, yet a 100-unit exit cannot be honoured without breaking the commitment.
    ///         Only C - ΣQ is withdrawable until allocations are consumed or (lazily) released.
    function test_R1_reserveConditionDoesNotGrantFullExit() public {
        uint256 C = vault.backing(c1);
        uint128 Q = uint128(C * 80 / 100);
        uint256 id = _allocate(keyA, c1, Q);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientFreeBacking.selector, C, C - Q));
        vault.withdraw(c1, C, owner);

        vm.prank(owner);
        vault.withdraw(c1, C - Q, owner); // exactly the free amount
        assertEq(vault.freeBacking(c1), 0);

        // After expiry the capacity is NOT returned until someone calls release (lazy expiry).
        vm.warp(vault.getAllocation(id).expiry);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientFreeBacking.selector, 1, 0));
        vault.withdraw(c1, 1, owner);

        vault.release(id);
        vm.prank(owner);
        vault.withdraw(c1, Q, owner);
        assertEq(vault.backing(c1), 0);
        _assertAccountingConsistent();
    }

    /// @notice After consumption, the LP's position is no longer denominated in the original asset.
    ///         Expiry cannot "give back" token1 that was sold for token0 — the liability must be valued
    ///         across both assets (Phase 1 liability model).
    function test_consumptionChangesAssetComposition() public {
        uint256 id = _allocate(keyA, c1, 10_000 ether);
        _swap(keyA, true, 5000 ether, id);
        uint256 sold = vault.getAllocation(id).consumed;

        vm.warp(vault.getAllocation(id).expiry);
        vault.release(id);

        assertEq(vault.backing(c1), VAULT_FUNDING - sold, "token1 permanently reduced");
        assertEq(vault.backing(c0), VAULT_FUNDING + 5000 ether, "token0 increased");
        assertEq(vault.freeBacking(c1), VAULT_FUNDING - sold);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.InsufficientFreeBacking.selector, VAULT_FUNDING, VAULT_FUNDING - sold
            )
        );
        vault.withdraw(c1, VAULT_FUNDING, owner);
    }

    /// @notice Withdrawals open their own unlock; they cannot run while PoolManager is already unlocked
    ///         (e.g. re-entered from inside a swap), because PoolManager.unlock reverts AlreadyUnlocked.
    function test_withdraw_cannotNestInsideUnlock() public {
        NestedWithdrawer n = new NestedWithdrawer(manager, vault);
        vm.prank(owner);
        vault.transferOwnership(address(n));
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        n.go(c0);
    }
}

/// @dev TEST ONLY: becomes vault owner and tries to withdraw from inside its own unlock callback.
contract NestedWithdrawer {
    IPoolManager internal immutable manager;
    SharedCommitmentVault internal immutable vault;

    constructor(IPoolManager manager_, SharedCommitmentVault vault_) {
        manager = manager_;
        vault = vault_;
    }

    function go(Currency c) external {
        manager.unlock(abi.encode(c));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        vault.withdraw(abi.decode(data, (Currency)), 1 ether, address(this));
        return "";
    }
}
