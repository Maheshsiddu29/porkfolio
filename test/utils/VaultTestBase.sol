// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {HookA_DynamicFee} from "../../src/hooks/HookA_DynamicFee.sol";
import {HookB_BoundedImpact} from "../../src/hooks/HookB_BoundedImpact.sol";
import {BatchSwapRouter} from "./BatchSwapRouter.sol";

/// @notice Shared fixture: REAL v4-core PoolManager (pinned), two distinct hooks on two distinct pools that
///         share one vault, and a funded vault. No PoolManager behaviour is mocked.
abstract contract VaultTestBase is Test {
    uint160 internal constant HOOK_FLAGS =
        Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 internal constant PRICE_1_1_X96 = uint160(FixedPoint96.Q96);
    uint256 internal constant VAULT_FUNDING = 1_000_000 ether;
    uint256 internal constant T0 = 1_700_000_000;

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    BatchSwapRouter internal batchRouter;
    MockERC20 internal token0;
    MockERC20 internal token1;
    Currency internal c0;
    Currency internal c1;

    SharedCommitmentVault internal vault;
    HookA_DynamicFee internal hookA;
    HookB_BoundedImpact internal hookB;
    PoolKey internal keyA; // HookA pool: fee 3000 / tickSpacing 60
    PoolKey internal keyB; // HookB pool: fee 500  / tickSpacing 10

    address internal owner = makeAddr("vaultOwner");
    address internal hookOwner = makeAddr("hookOwner");
    address internal curator = makeAddr("curator");
    address internal trader = makeAddr("trader");
    address internal attacker = makeAddr("attacker");
    address internal lp0 = makeAddr("lp0"); // seed LP that initializes the vault in setUp

    uint256 internal nextNonce;

    function setUp() public virtual {
        vm.warp(T0);

        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);

        MockERC20 ta = new MockERC20("Stable A", "STA", 18);
        MockERC20 tb = new MockERC20("Stable B", "STB", 18);
        (token0, token1) = address(ta) < address(tb) ? (ta, tb) : (tb, ta);
        c0 = Currency.wrap(address(token0));
        c1 = Currency.wrap(address(token1));

        vault = new SharedCommitmentVault(manager, owner, c0, c1);
        batchRouter = new BatchSwapRouter(manager, address(vault));

        hookA = HookA_DynamicFee(_deployHook("HookA_DynamicFee.sol:HookA_DynamicFee", 0xA11CE));
        hookB = HookB_BoundedImpact(_deployHook("HookB_BoundedImpact.sol:HookB_BoundedImpact", 0xB0B));

        keyA = PoolKey(c0, c1, 3000, 60, IHooks(address(hookA)));
        keyB = PoolKey(c0, c1, 500, 10, IHooks(address(hookB)));
        manager.initialize(keyA, SQRT_PRICE_1_1);
        manager.initialize(keyB, SQRT_PRICE_1_1);

        vm.startPrank(hookOwner);
        hookA.configurePool(keyA, PRICE_1_1_X96, 500, 5000); // 5 bps -> 50 bps with utilisation
        hookB.configurePool(keyB, PRICE_1_1_X96, 10_000, 20_000); // 1% impact at full quota, max 2%
        vm.stopPrank();

        vm.startPrank(owner);
        vault.setConsumer(address(hookA), true);
        vault.setConsumer(address(hookB), true);
        vault.setCurator(curator, true);
        // Vault floors of 1 raw in per 1 raw out in both directions. Their product is exactly 2^192, the tightest
        // pair the directional-consistency check accepts around the hooks' 1:1 reference price. Both hooks quote
        // strictly below 1:1 (fee or impact), so with these floors every hook quote passes in both directions.
        vault.setSellFloor(c0, PRICE_1_1_X96);
        vault.setSellFloor(c1, PRICE_1_1_X96);
        vault.setCuratorCeiling(curator, c0, VAULT_FUNDING);
        vault.setCuratorCeiling(curator, c1, VAULT_FUNDING);
        vm.stopPrank();

        _fundVault(VAULT_FUNDING, VAULT_FUNDING);

        token0.mint(trader, 10_000_000 ether);
        token1.mint(trader, 10_000_000 ether);
        vm.startPrank(trader);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(batchRouter), type(uint256).max);
        token1.approve(address(batchRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _hookAddress(uint256 salt) internal pure returns (address) {
        return address(uint160(salt << 140) | HOOK_FLAGS);
    }

    function _deployHook(string memory artifact, uint256 salt) internal returns (address hook) {
        hook = _hookAddress(salt);
        deployCodeTo(artifact, abi.encode(manager, vault, hookOwner), hook);
    }

    /// @dev The owner initializes the vault (only the owner can), paying the seed and assigning the
    ///      sqrt(amount0 * amount1) - MIN_SHARES shares to the seed LP `lp0`.
    function _fundVault(uint256 amount0, uint256 amount1) internal {
        _fundLp(owner, amount0, amount1);
        vm.prank(owner);
        vault.initialDeposit(amount0, amount1, lp0);
    }

    function _fundLp(address lp, uint256 amount0, uint256 amount1) internal {
        token0.mint(lp, amount0);
        token1.mint(lp, amount1);
        vm.startPrank(lp);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Mint `shares` to `lp` at the current basket price, funding the LP with exactly what is needed.
    function _depositShares(address lp, uint256 shares) internal returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = vault.previewDeposit(shares);
        _fundLp(lp, amount0, amount1);
        vm.prank(lp);
        vault.deposit(shares, amount0, amount1, lp);
    }

    function _redeem(address lp, uint256 shares, bool queueRemainder)
        internal
        returns (uint256 instantShares, uint256 amount0, uint256 amount1, uint256 requestId)
    {
        vm.prank(lp);
        return vault.redeem(shares, 0, 0, lp, queueRemainder);
    }

    function _request(PoolKey memory key, Currency out, uint128 maxOut)
        internal
        returns (ISharedCommitmentVault.AllocationRequest memory req)
    {
        req = ISharedCommitmentVault.AllocationRequest({
            consumer: address(key.hooks),
            key: key,
            currencyOut: out,
            maxOut: maxOut,
            minInPerOutX96: PRICE_1_1_X96, // curator floor = vault floor (it may not be lower)
            expiry: uint64(block.timestamp + 1 days),
            nonce: nextNonce++,
            deadline: uint64(block.timestamp + 1 hours)
        });
    }

    function _allocate(PoolKey memory key, Currency out, uint128 maxOut) internal returns (uint256 id) {
        ISharedCommitmentVault.AllocationRequest memory req = _request(key, out, maxOut);
        vm.prank(curator);
        id = vault.allocate(req);
    }

    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn, uint256 allocationId)
        internal
        returns (BalanceDelta)
    {
        return _swapRaw(key, zeroForOne, -int256(amountIn), abi.encode(allocationId));
    }

    function _swapRaw(PoolKey memory key, bool zeroForOne, int256 amountSpecified, bytes memory hookData)
        internal
        returns (BalanceDelta delta)
    {
        vm.prank(trader);
        delta = swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    /// @dev PoolManager wraps any hook revert as WrappedError(hook, selector, reason, HookCallFailed).
    function _expectHookRevert(address hook, bytes4 hookSelector, bytes memory reason) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                hook,
                hookSelector,
                reason,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function _expectSwapRevert(address hook, bytes memory reason) internal {
        _expectHookRevert(hook, IHooks.beforeSwap.selector, reason);
    }

    function _claims(address who, Currency c) internal view returns (uint256) {
        return manager.balanceOf(who, c.toId());
    }

    /// @dev Core conservation checks that must hold after every successful or reverted operation.
    function _assertAccountingConsistent() internal view {
        _assertAccountingConsistentWith(0, 0);
    }

    /// @dev Same, allowing for `don0/don1` ERC-6909 claims donated straight to the vault (never counted in B_a).
    function _assertAccountingConsistentWith(uint256 don0, uint256 don1) internal view {
        Currency[2] memory cs = [c0, c1];
        uint256[2] memory don = [don0, don1];
        for (uint256 i; i < 2; ++i) {
            Currency c = cs[i];
            assertEq(vault.backing(c) + don[i], _claims(address(vault), c), "backing + donations != ERC-6909 balance");
            assertLe(vault.reserved(c), vault.backing(c), "reserved > backing");
            assertLe(
                vault.reserved(c) + vault.claimableAssets(c), vault.backing(c), "commitments + claimables > backing"
            );
            assertEq(_claims(address(hookA), c), 0, "hookA holds residual claims");
            assertEq(_claims(address(hookB), c), 0, "hookB holds residual claims");
            assertGe(
                MockERC20(Currency.unwrap(c)).balanceOf(address(manager)),
                _claims(address(vault), c),
                "PoolManager ERC-20 < vault claims"
            );
        }
        assertFalse(manager.isOperator(address(vault), address(hookA)), "hookA is vault operator");
        assertFalse(manager.isOperator(address(vault), address(hookB)), "hookB is vault operator");
    }

    /// @dev Recompute every derived quantity from RAW sources (PoolManager ERC-6909 balances, request storage,
    ///      allocation storage) and compare with the vault's accounting and views. This catches a stored aggregate
    ///      drifting away from the records it summarizes, which a test reading only the vault's own views cannot:
    ///        B_a = PM balance,  W_a = Σ claimable,  P = Σ pending,  Q_a = Σ unreleased (maxOut - consumed),
    ///        N_a = B_a - W_a,  F_a = N_a - Q_a,  D_a = ceil(P * N_a / S),  admissible = max(0, N_a - Q_a - R_a - D_a).
    ///      Assumes no ERC-6909 donations to the vault in the calling test.
    function _assertEquations() internal view {
        _assertEquationsWith(0, 0);
    }

    /// @dev As `_assertEquations`, with B_a = PM balance - donated_a.
    function _assertEquationsWith(uint256 don0, uint256 don1) internal view {
        uint256[2] memory don = [don0, don1];
        uint256 S = vault.totalShares();
        uint256 P;
        uint256[2] memory W;
        for (uint256 id = 1; id < vault.nextRequestId(); ++id) {
            ISharedCommitmentVault.WithdrawalRequest memory r = vault.getRequest(id);
            P += r.sharesPending;
            W[0] += r.claimable0;
            W[1] += r.claimable1;
        }
        uint256[2] memory Q;
        for (uint256 id = 1; id < vault.nextAllocationId(); ++id) {
            ISharedCommitmentVault.Allocation memory a = vault.getAllocation(id);
            if (a.released) continue;
            Q[a.currencyOut == c0 ? 0 : 1] += a.maxOut - a.consumed;
        }
        assertEq(vault.pendingShares(), P, "P != sum pending");

        Currency[2] memory cs = [c0, c1];
        uint256 nSum;
        for (uint256 i; i < 2; ++i) {
            Currency c = cs[i];
            uint256 B = _claims(address(vault), c) - don[i];
            assertEq(vault.backing(c), B, "B != PM balance - donations");
            assertEq(vault.claimableAssets(c), W[i], "W != sum claimable");
            assertEq(vault.reserved(c), Q[i], "Q != sum allocations");
            assertLe(Q[i] + W[i], B, "Q + W > B");
            uint256 N = B - W[i];
            nSum += N;
            assertEq(vault.netAssets(c), N, "N != B - W");
            assertEq(vault.freeInventory(c), N - Q[i], "F != N - Q");
            uint256 D = P == 0 ? 0 : FullMath.mulDivRoundingUp(P, N, S);
            assertEq(vault.pendingDemand(c), D, "D != ceil(P*N/S)");
            assertLe(D, N, "D > N");
            uint256 need = Q[i] + vault.bufferFloor(c) + D;
            assertEq(vault.admissibleCapacity(c), N > need ? N - need : 0, "admission != N - Q - R - D");
        }
        if (S != 0) assertGt(nSum, 0, "shares outstanding with no assets");
    }
}
