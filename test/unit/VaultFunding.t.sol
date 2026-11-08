// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @notice Funding (ERC-20 -> ERC-6909) and redemption paths through the real PoolManager, and the
///         reserve condition's limits on exit liquidity.
/// @dev These tests predate LP shares, when the owner funded the vault directly. Each keeps its original intent,
///      expressed through LP shares (see PHASE1A_REPORT.md §4).
contract VaultFundingTest is VaultTestBase {
    function test_initialDeposit_mintsSharesBackedByRealClaims() public view {
        // setUp initialized the vault through unlock -> sync -> transfer -> settle -> mint (both assets).
        assertEq(_claims(address(vault), c0), VAULT_FUNDING);
        assertEq(_claims(address(vault), c1), VAULT_FUNDING);
        assertEq(token0.balanceOf(address(manager)), VAULT_FUNDING, "ERC-20 actually held by PoolManager");
        assertEq(token1.balanceOf(address(manager)), VAULT_FUNDING);
        assertEq(vault.backing(c0), VAULT_FUNDING);
        assertEq(token0.balanceOf(lp0), 0);
        // sqrt(1e24 * 1e24) = 1e24 shares; MIN_SHARES locked at address(0).
        assertEq(vault.totalShares(), VAULT_FUNDING);
        assertEq(vault.sharesOf(address(0)), vault.MIN_SHARES());
        assertEq(vault.sharesOf(lp0), VAULT_FUNDING - vault.MIN_SHARES());
    }

    function test_instantRedeem_burnsClaimsAndReturnsErc20() public {
        address to = makeAddr("recipient");
        vm.prank(lp0);
        (uint256 instant, uint256 a0, uint256 a1, uint256 requestId) =
            vault.redeem(400 ether, 400 ether, 400 ether, to, false);
        assertEq(instant, 400 ether);
        assertEq(requestId, 0);
        assertEq(a0, 400 ether); // N_a / S == 1 exactly
        assertEq(a1, 400 ether);
        assertEq(token0.balanceOf(to), 400 ether);
        assertEq(token1.balanceOf(to), 400 ether);
        assertEq(_claims(address(vault), c0), VAULT_FUNDING - 400 ether);
        assertEq(vault.backing(c0), VAULT_FUNDING - 400 ether);
        assertEq(vault.totalShares(), VAULT_FUNDING - 400 ether);
        _assertAccountingConsistent();
    }

    function test_funding_accessControlAndValidation() public {
        // The owner holds no shares and has no other asset path.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientShares.selector, 1, 0));
        vault.redeem(1, 0, 0, owner, true);

        uint256 maxAmt = vault.MAX_AMOUNT();
        uint256 supply = vault.totalShares();
        vm.prank(lp0);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.initialDeposit(1 ether, 1 ether, lp0);
        vm.prank(owner);
        vm.expectRevert(ISharedCommitmentVault.AlreadyInitialized.selector);
        vault.initialDeposit(1 ether, 1 ether, lp0);
        vm.startPrank(lp0);
        vm.expectRevert(ISharedCommitmentVault.ZeroAmount.selector);
        vault.deposit(0, type(uint256).max, type(uint256).max, lp0);
        vm.expectRevert(ISharedCommitmentVault.ZeroAddress.selector);
        vault.deposit(1, type(uint256).max, type(uint256).max, address(0));
        vm.expectRevert(ISharedCommitmentVault.AmountTooLarge.selector);
        vault.deposit(maxAmt - supply + 1, type(uint256).max, type(uint256).max, lp0);
        vm.expectRevert(ISharedCommitmentVault.SlippageExceeded.selector);
        vault.deposit(1 ether, 1 ether - 1, 1 ether, lp0);
        vm.expectRevert(ISharedCommitmentVault.ZeroAmount.selector);
        vault.redeem(0, 0, 0, lp0, false);
        vm.expectRevert(ISharedCommitmentVault.ZeroAddress.selector);
        vault.redeem(1, 0, 0, address(0), false);
        vm.expectRevert(ISharedCommitmentVault.SlippageExceeded.selector);
        vault.redeem(1 ether, 1 ether + 1, 0, lp0, false);
        vm.stopPrank();

        SharedCommitmentVault fresh = new SharedCommitmentVault(manager, owner, c0, c1);
        vm.expectRevert(ISharedCommitmentVault.NotInitialized.selector);
        fresh.deposit(1, 1, 1, lp0);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        fresh.initialDeposit(1 ether, 1 ether, lp0);
        vm.startPrank(owner);
        vm.expectRevert(ISharedCommitmentVault.ZeroAmount.selector);
        fresh.initialDeposit(0, 1, lp0);
        vm.expectRevert(ISharedCommitmentVault.ZeroAddress.selector);
        fresh.initialDeposit(1, 1, address(0));
        vm.expectRevert(ISharedCommitmentVault.AmountTooLarge.selector);
        fresh.initialDeposit(maxAmt + 1, 1, lp0);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InitialDepositTooSmall.selector, 1000, 1000));
        fresh.initialDeposit(1000, 1000, lp0);
        vm.stopPrank();
        (uint256 p0, uint256 p1) = fresh.previewRedeem(1);
        assertEq(p0 + p1, 0);
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
        assertEq(vault.owner(), owner, "two-step: owner unchanged until accepted");
        assertEq(vault.pendingOwner(), newOwner);
        vm.prank(newOwner);
        vault.acceptOwnership();
        assertEq(vault.owner(), newOwner);
    }

    function test_constructor_rejectsZeroAddressesAndBadPairs() public {
        vm.expectRevert(ISharedCommitmentVault.ZeroAddress.selector);
        new SharedCommitmentVault(IPoolManager(address(0)), owner, c0, c1);
        vm.expectRevert(ISharedCommitmentVault.ZeroAddress.selector);
        new SharedCommitmentVault(manager, address(0), c0, c1);
        vm.expectRevert(ISharedCommitmentVault.NativeCurrencyUnsupported.selector);
        new SharedCommitmentVault(manager, owner, Currency.wrap(address(0)), c1);
        vm.expectRevert(ISharedCommitmentVault.InvalidAssetPair.selector);
        new SharedCommitmentVault(manager, owner, c1, c0);
        vm.expectRevert(ISharedCommitmentVault.InvalidAssetPair.selector);
        new SharedCommitmentVault(manager, owner, c0, c0);
    }

    /// @notice RISKS.md R1 counterexample, executable. With 80% of token1 committed (Q1 = 0.8 * N1), every
    ///         commitment is fully backed, yet the sole LP can exit only 20% instantly: an in-kind exit needs BOTH
    ///         assets pro rata, and F1 limits it. The rest waits in the queue until capacity is (lazily) released.
    ///         Backed commitments do not imply immediate full withdrawal.
    function test_R1_reserveConditionDoesNotGrantFullExit() public {
        uint256 C = vault.backing(c1);
        uint128 Q = uint128(C * 80 / 100);
        uint256 id = _allocate(keyA, c1, Q);
        uint256 lpShares = vault.sharesOf(lp0);
        uint256 S = vault.totalShares();

        uint256 deliverable = vault.deliverableShares();
        assertEq(deliverable, S * 20 / 100);
        vm.prank(lp0);
        vm.expectRevert(
            abi.encodeWithSelector(ISharedCommitmentVault.InsufficientLiquidity.selector, lpShares, deliverable)
        );
        vault.redeem(lpShares, 0, 0, lp0, false);

        (uint256 instant, uint256 a0, uint256 a1, uint256 requestId) = _redeem(lp0, lpShares, true);
        assertEq(instant, deliverable);
        assertEq(a1, C - Q, "exactly the free token1");
        assertEq(a0, C - Q, "token0 delivered pro rata, not more");
        assertEq(vault.freeInventory(c1), 0);
        assertEq(vault.pendingShares(), lpShares - instant);

        // After expiry the capacity is NOT returned until someone calls release (lazy expiry).
        vm.warp(vault.getAllocation(id).expiry);
        assertEq(vault.processQueue(10), 0);
        assertEq(uint8(vault.requestStatus(requestId)), uint8(ISharedCommitmentVault.RequestStatus.Pending));

        vault.release(id);
        assertEq(vault.processQueue(10), lpShares - instant);
        vm.prank(lp0);
        (uint256 c0Out, uint256 c1Out) = vault.claim(requestId);
        assertEq(c0Out, lpShares - instant);
        assertEq(c1Out, lpShares - instant);
        // Only the locked MIN_SHARES' basket remains.
        assertEq(vault.totalShares(), vault.MIN_SHARES());
        assertEq(vault.backing(c1), vault.MIN_SHARES());
        _assertAccountingConsistent();
    }

    /// @notice After consumption, the LP's position is no longer denominated in the original assets.
    ///         Expiry cannot "give back" token1 that was sold for token0: the redemption is in kind.
    function test_consumptionChangesAssetComposition() public {
        uint256 id = _allocate(keyA, c1, 10_000 ether);
        _swap(keyA, true, 5000 ether, id);
        uint256 sold = vault.getAllocation(id).consumed;

        vm.warp(vault.getAllocation(id).expiry);
        vault.release(id);

        assertEq(vault.backing(c1), VAULT_FUNDING - sold, "token1 permanently reduced");
        assertEq(vault.backing(c0), VAULT_FUNDING + 5000 ether, "token0 increased");

        uint256 lpShares = vault.sharesOf(lp0);
        uint256 S = vault.totalShares();
        (uint256 instant, uint256 a0, uint256 a1,) = _redeem(lp0, lpShares, false);
        assertEq(instant, lpShares);
        assertEq(a0, FullMath.mulDiv(lpShares, VAULT_FUNDING + 5000 ether, S));
        assertEq(a1, FullMath.mulDiv(lpShares, VAULT_FUNDING - sold, S));
        assertGt(a0, VAULT_FUNDING - 1000, "more token0 than deposited");
        assertLt(a1, VAULT_FUNDING - sold + 1, "less token1 than deposited");
        _assertAccountingConsistent();
    }

    /// @notice Redemptions open their own unlock; they cannot run while PoolManager is already unlocked
    ///         (e.g. re-entered from inside a swap), because PoolManager.unlock reverts AlreadyUnlocked.
    function test_redeem_cannotNestInsideUnlock() public {
        NestedRedeemer n = new NestedRedeemer(manager, vault);
        (uint256 a0, uint256 a1) = vault.previewDeposit(1 ether);
        token0.mint(address(n), a0);
        token1.mint(address(n), a1);
        n.depositShares(1 ether);
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        n.go();
    }
}

/// @dev TEST ONLY: an LP contract that tries to redeem from inside its own unlock callback.
contract NestedRedeemer {
    IPoolManager internal immutable manager;
    SharedCommitmentVault internal immutable vault;

    constructor(IPoolManager manager_, SharedCommitmentVault vault_) {
        manager = manager_;
        vault = vault_;
    }

    function depositShares(uint256 shares) external {
        MockERC20(Currency.unwrap(vault.asset0())).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(vault.asset1())).approve(address(vault), type(uint256).max);
        vault.deposit(shares, type(uint256).max, type(uint256).max, address(this));
    }

    function go() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        vault.redeem(1 ether, 0, 0, address(this), false);
        return "";
    }
}
