// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {HookA_DynamicFee} from "../../src/hooks/HookA_DynamicFee.sol";
import {HookB_BoundedImpact} from "../../src/hooks/HookB_BoundedImpact.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {MaliciousConsumerHook} from "../utils/MaliciousConsumerHook.sol";

/// @notice Phase 1B-1: the two production hooks (HookA_DynamicFee, HookB_BoundedImpact) under vault-enforced floors,
///         through the real PoolManager, in both directions, on an 18/18 pair (fixture) and a 6/18 USDC/WETH pair.
///         The hooks are unchanged: every rejection below comes from the vault, never from hook-side checks.
contract HookPriceBandsTest is VaultTestBase {
    uint256 internal constant Q96 = FixedPoint96.Q96;
    address internal guardian = makeAddr("guardian");

    function setUp() public override {
        super.setUp();
        vm.startPrank(owner);
        vault.setGuardian(guardian);
        vault.setCuratorCeiling(curator, c0, type(uint256).max);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        vm.stopPrank();
    }

    function _vaultClaims(SharedCommitmentVault v, Currency a, Currency b) internal view returns (uint256, uint256) {
        return (manager.balanceOf(address(v), a.toId()), manager.balanceOf(address(v), b.toId()));
    }

    /// @dev amountIn * 2^96 >= amountOut * floor, checked without overflow (amounts < 2^128 here; floor < 2^160).
    function _meets(uint256 amountIn, uint256 amountOut, uint256 floor) internal pure returns (bool) {
        return amountIn >= FullMath.mulDivRoundingUp(amountOut, floor, Q96);
    }

    // ------------------------------------------------------------------
    // 18/18 fixture: both hooks, both directions
    // ------------------------------------------------------------------

    function test_HB_bothHooks_bothDirections_validPrices() public {
        PoolKey[2] memory keys = [keyA, keyB];
        for (uint256 h; h < 2; ++h) {
            for (uint256 d; d < 2; ++d) {
                bool zeroForOne = d == 0;
                Currency out = zeroForOne ? c1 : c0;
                uint256 id = _allocate(keys[h], out, 50_000 ether);
                (uint256 a0, uint256 a1) = _vaultClaims(vault, c0, c1);
                _swap(keys[h], zeroForOne, 1000 ether, id);
                (uint256 b0, uint256 b1) = _vaultClaims(vault, c0, c1);
                (uint256 dIn, uint256 dOut) = zeroForOne ? (b0 - a0, a1 - b1) : (b1 - a1, a0 - b0);
                assertEq(dIn, 1000 ether);
                assertGt(dOut, 0);
                assertTrue(_meets(dIn, dOut, vault.effectiveFloorX96(id)), "measured deltas meet the floor");
                assertLt(dOut, dIn, "both hooks quote below 1:1 (fee / impact)");
            }
        }
        _assertEquations();
        _assertAccountingConsistent();
    }

    /// @notice For each hook and direction: set the vault floor to the hook's own execution price (rounded down)
    ///         and the swap executes; one floor unit higher and the vault rejects the very same swap.
    function test_HB_realHookQuote_atFloorPasses_oneUnitAboveReverts() public {
        for (uint256 h; h < 2; ++h) {
            for (uint256 d; d < 2; ++d) {
                uint256 snap = vm.snapshotState();
                _atFloorCase(h == 0, d == 0);
                vm.revertToState(snap);
            }
        }
    }

    function _atFloorCase(bool useHookA, bool zeroForOne) internal {
        PoolKey memory key = useHookA ? keyA : keyB;
        Currency out = zeroForOne ? c1 : c0;
        uint256 id = _allocate(key, out, 50_000 ether);
        uint256 x = 1000 ether;
        uint256 y = useHookA ? hookA.quote(key, zeroForOne, x, id) : hookB.quote(key, zeroForOne, x, id);
        uint256 fAt = x * Q96 / y; // largest floor the quote satisfies: ceil(y * fAt / 2^96) <= x
        assertGe(fAt, Q96);
        assertTrue(_meets(x, y, fAt) && !_meets(x, y, fAt + 1), "boundary");

        uint256 snap = vm.snapshotState();
        vm.prank(guardian);
        vault.setSellFloor(out, uint160(fAt + 1));
        _expectSwapRevert(
            address(key.hooks),
            abi.encodeWithSelector(
                ISharedCommitmentVault.PriceBelowFloor.selector, x, FullMath.mulDivRoundingUp(y, fAt + 1, Q96)
            )
        );
        _swap(key, zeroForOne, x, id);
        vm.revertToState(snap);

        vm.prank(guardian);
        vault.setSellFloor(out, uint160(fAt));
        _swap(key, zeroForOne, x, id);
        assertEq(vault.getAllocation(id).consumed, y, "executed exactly at the hook's quote");
    }

    /// @notice The hook owner (not the vault owner) misprices Hook A at 2 token1 per token0. The vault refuses the
    ///         direction that would sell token1 too cheaply, while the direction favourable to LPs still executes.
    function test_HB_hookOwnerMispricing_isDirectional() public {
        vm.prank(hookOwner);
        hookA.configurePool(keyA, uint160(2 * Q96), 500, 5000);
        uint256 id1 = _allocate(keyA, c1, 50_000 ether);
        uint256 id0 = _allocate(keyA, c0, 50_000 ether);

        uint256 y = hookA.quote(keyA, true, 1000 ether, id1); // ~1990 token1 for 1000 token0
        _expectSwapRevert(
            address(hookA), abi.encodeWithSelector(ISharedCommitmentVault.PriceBelowFloor.selector, 1000 ether, y)
        );
        _swap(keyA, true, 1000 ether, id1);

        _swap(keyA, false, 1000 ether, id0); // vault receives 1000 token1 for ~497.5 token0: favourable
        assertLt(vault.getAllocation(id0).consumed, 500 ether);
    }

    /// @notice Cycling token0 -> token1 (Hook A) -> token0 (Hook B) never profits the trader, and the vault's 1:1
    ///         valuation (k = 1 lies in the pivot interval of the 1:1 floors) never decreases (D14 proof).
    function test_HB_cyclicTradesThroughBothHooks_neverProfitable() public {
        uint256 id1 = _allocate(keyA, c1, 500_000 ether);
        uint256 id0 = _allocate(keyB, c0, 500_000 ether);
        uint256 start0 = token0.balanceOf(trader);
        uint256 start1 = token1.balanceOf(trader);
        uint256 value = vault.backing(c0) + vault.backing(c1);
        uint256 x = 10_000 ether;
        for (uint256 i; i < 5; ++i) {
            uint256 before1 = token1.balanceOf(trader);
            _swap(keyA, true, x, id1);
            uint256 got1 = token1.balanceOf(trader) - before1;
            uint256 before0 = token0.balanceOf(trader);
            _swap(keyB, false, got1, id0);
            x = token0.balanceOf(trader) - before0;
            uint256 v = vault.backing(c0) + vault.backing(c1);
            assertGe(v, value, "vault valuation at k = 1 never decreases");
            value = v;
        }
        assertLt(token0.balanceOf(trader), start0, "round trips lose");
        assertEq(token1.balanceOf(trader), start1);
        _assertEquations();
    }
}

/// @notice 6-decimal USDC / 18-decimal WETH vault with both production hooks and a price-exact test hook.
///         Numbers mirror PHASE1B_PRICE_POLICY.md §2.3 and PHASE1B_DECISIONS.md D14.
contract HookPriceBands6x18Test is VaultTestBase {
    uint256 internal constant Q96 = FixedPoint96.Q96;
    uint160 internal constant FLAGS =
        Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG;

    MockERC20 internal usdc;
    MockERC20 internal weth;
    Currency internal cU;
    Currency internal cW;
    Currency internal x0; // sorted pair of the 6/18 vault
    Currency internal x1;
    SharedCommitmentVault internal v;
    HookA_DynamicFee internal hA;
    HookB_BoundedImpact internal hB;
    MaliciousConsumerHook internal hM;
    PoolKey internal kA;
    PoolKey internal kB;
    PoolKey internal kM;

    function setUp() public override {
        super.setUp();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        cU = Currency.wrap(address(usdc));
        cW = Currency.wrap(address(weth));
        (x0, x1) = address(usdc) < address(weth) ? (cU, cW) : (cW, cU);
        v = new SharedCommitmentVault(manager, owner, x0, x1);

        address a = address(uint160(0x6A << 140) | FLAGS);
        deployCodeTo("HookA_DynamicFee.sol:HookA_DynamicFee", abi.encode(manager, v, hookOwner), a);
        address b = address(uint160(0x6B << 140) | FLAGS);
        deployCodeTo("HookB_BoundedImpact.sol:HookB_BoundedImpact", abi.encode(manager, v, hookOwner), b);
        address m = address(uint160(0x6C << 140) | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        deployCodeTo("MaliciousConsumerHook.sol:MaliciousConsumerHook", abi.encode(manager, v), m);
        (hA, hB, hM) = (HookA_DynamicFee(a), HookB_BoundedImpact(b), MaliciousConsumerHook(m));
        kA = PoolKey(x0, x1, 3000, 60, IHooks(a));
        kB = PoolKey(x0, x1, 500, 10, IHooks(b));
        kM = PoolKey(x0, x1, 3000, 60, IHooks(m));
        manager.initialize(kA, SQRT_PRICE_1_1);
        manager.initialize(kB, SQRT_PRICE_1_1);
        manager.initialize(kM, SQRT_PRICE_1_1);

        // Hooks reference 3,000 USDC per WETH, as raw currency1 per raw currency0.
        uint160 ref = _c1PerC0X96(3000);
        vm.startPrank(hookOwner);
        hA.configurePool(kA, ref, 500, 5000);
        hB.configurePool(kB, ref, 10_000, 20_000);
        vm.stopPrank();

        vm.startPrank(owner);
        v.setConsumer(a, true);
        v.setConsumer(b, true);
        v.setConsumer(m, true);
        v.setCurator(curator, true);
        v.setCuratorCeiling(curator, x0, type(uint256).max);
        v.setCuratorCeiling(curator, x1, type(uint256).max);
        vm.stopPrank();

        // Seed: 3,000,000 USDC and 1,000 WETH (owner pays, lp0 receives).
        uint256 seedU = 3_000_000e6;
        uint256 seedW = 1000 ether;
        (uint256 s0, uint256 s1) = x0 == cU ? (seedU, seedW) : (seedW, seedU);
        MockERC20(Currency.unwrap(x0)).mint(owner, s0);
        MockERC20(Currency.unwrap(x1)).mint(owner, s1);
        vm.startPrank(owner);
        MockERC20(Currency.unwrap(x0)).approve(address(v), type(uint256).max);
        MockERC20(Currency.unwrap(x1)).approve(address(v), type(uint256).max);
        v.initialDeposit(s0, s1, lp0);
        vm.stopPrank();

        usdc.mint(trader, 100_000_000e6);
        weth.mint(trader, 100_000 ether);
        vm.startPrank(trader);
        usdc.approve(address(swapRouter), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Decimal normalization (PHASE1B_PRICE_POLICY.md §2.2: F = ceil(p * 10^d_in * 2^96 / 10^d_out))
    // ------------------------------------------------------------------

    /// @dev Floor for SELLING WETH: min raw USDC per raw WETH at `p` USDC per WETH.
    function _sellWethFloor(uint256 p) internal pure returns (uint160) {
        return uint160(FullMath.mulDivRoundingUp(p * 1e6, Q96, 1e18));
    }

    /// @dev Floor for SELLING USDC: min raw WETH per raw USDC when the vault buys WETH at no more than `p` USDC.
    function _sellUsdcFloor(uint256 p) internal pure returns (uint160) {
        return uint160(FullMath.mulDivRoundingUp(1e18, Q96, p * 1e6));
    }

    /// @dev Hook reference: raw currency1 per raw currency0 at `p` USDC per WETH (rounded down).
    function _c1PerC0X96(uint256 p) internal view returns (uint160) {
        return x0 == cU ? uint160(FullMath.mulDiv(1e18, Q96, p * 1e6)) : uint160(FullMath.mulDiv(p * 1e6, Q96, 1e18));
    }

    /// @dev Configure the pivot floors: sell WETH at >= pW USDC, sell USDC at >= 1/pU WETH (vault buys at <= pU).
    function _setPivot(uint256 pW, uint256 pU) internal {
        vm.startPrank(owner);
        v.setSellFloor(cW, _sellWethFloor(pW));
        v.setSellFloor(cU, _sellUsdcFloor(pU));
        vm.stopPrank();
    }

    function _alloc(PoolKey memory key, Currency out, uint128 maxOut) internal returns (uint256 id) {
        ISharedCommitmentVault.AllocationRequest memory r = _request(key, out, maxOut);
        (r.minInPerOutX96,) = v.sellPolicy(out);
        vm.prank(curator);
        id = v.allocate(r);
    }

    /// @dev Trader sells `amountIn` of `cin` through `key`; returns the measured vault deltas (in, out).
    function _sell(PoolKey memory key, Currency cin, uint256 amountIn, uint256 id)
        internal
        returns (uint256 dIn, uint256 dOut)
    {
        Currency cout = cin == x0 ? x1 : x0;
        uint256 i0 = manager.balanceOf(address(v), cin.toId());
        uint256 o0 = manager.balanceOf(address(v), cout.toId());
        _swap(key, cin == x0, amountIn, id);
        dIn = manager.balanceOf(address(v), cin.toId()) - i0;
        dOut = o0 - manager.balanceOf(address(v), cout.toId());
    }

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------

    function test_HB_6x18_floorValuesMatchSpec() public pure {
        assertEq(_sellWethFloor(2850), 225_800_263_165_653_362_142);
        assertEq(_sellUsdcFloor(2850), 27_799_355_268_162_925_471_418_929_942_456_140_351);
        assertEq(FullMath.mulDivRoundingUp(1 ether, _sellWethFloor(2850), Q96), 2_850_000_001);
    }

    /// @notice Pivot at the hooks' reference (3,000): both hooks trade both directions, every measured execution meets
    ///         the floor, and the human-unit prices are what the decimals imply.
    function test_HB_6x18_bothHooks_bothDirections_pivotAtReference() public {
        _setPivot(3000, 3000);
        PoolKey[2] memory keys = [kA, kB];
        for (uint256 h; h < 2; ++h) {
            // Trader sells 1 WETH: the vault sells USDC.
            uint256 idU = _alloc(keys[h], cU, 1_000_000e6);
            (uint256 dIn, uint256 dOut) = _sell(keys[h], cW, 1 ether, idU);
            assertEq(dIn, 1 ether);
            assertTrue(dOut > 2950e6 && dOut < 3000e6, "~2,985 USDC for 1 WETH");
            assertGe(dIn, FullMath.mulDivRoundingUp(dOut, v.effectiveFloorX96(idU), Q96));

            // Trader sells 3,000 USDC: the vault sells WETH.
            uint256 idW = _alloc(keys[h], cW, 500 ether);
            (dIn, dOut) = _sell(keys[h], cU, 3000e6, idW);
            assertEq(dIn, 3000e6);
            assertTrue(dOut > 0.98 ether && dOut < 1 ether, "~0.995 WETH for 3,000 USDC");
            assertGe(dIn, FullMath.mulDivRoundingUp(dOut, v.effectiveFloorX96(idW), Q96));
        }
    }

    /// @notice Pivot at 2,850 (the valid D14 pair from the decision record): the vault still SELLS WETH (it receives
    ///         ~3,015 USDC each, above 2,850) but refuses to BUY WETH at ~2,985 USDC, above its 2,850 maximum bid.
    function test_HB_6x18_pivotBelowMarket_onlyFavourableDirectionExecutes() public {
        _setPivot(2850, 2850);
        uint256 idW = _alloc(kA, cW, 500 ether);
        (uint256 dIn, uint256 dOut) = _sell(kA, cU, 3000e6, idW);
        assertGt(dOut, 0);
        assertGe(dIn, FullMath.mulDivRoundingUp(dOut, _sellWethFloor(2850), Q96));

        uint256 idU = _alloc(kA, cU, 1_000_000e6);
        uint256 y = hA.quote(kA, cW == x0, 1 ether, idU);
        _expectSwapRevert(
            address(hA),
            abi.encodeWithSelector(
                ISharedCommitmentVault.PriceBelowFloor.selector,
                1 ether,
                FullMath.mulDivRoundingUp(y, _sellUsdcFloor(2850), Q96)
            )
        );
        _swap(kA, cW == x0, 1 ether, idU);
    }

    /// @notice The Phase 1B-0 worked example (2,850 / 3,150) is a crossed pair and is now rejected.
    function test_HB_6x18_crossedPhase1B0Example_rejected() public {
        vm.startPrank(owner);
        v.setSellFloor(cW, _sellWethFloor(2850));
        uint256 need = FullMath.mulDivRoundingUp(Q96, Q96, _sellWethFloor(2850));
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.InconsistentDirectionalFloors.selector, _sellUsdcFloor(3150), need
            )
        );
        v.setSellFloor(cU, _sellUsdcFloor(3150));
        vm.stopPrank();
    }

    /// @notice Exact boundary with mixed decimals: selling 1 WETH at the 2,850 floor needs 2,850.000001 USDC (the
    ///         rounded-up floor adds one raw unit); 2,850.000000 USDC reverts. Selling 1 raw USDC unit needs
    ///         ceil(F_usdc / 2^96) wei.
    function test_HB_6x18_exactBoundary_mixedDecimals() public {
        _setPivot(2850, 2850);
        uint256 idW = _alloc(kM, cW, 10 ether);
        hM.configure(MaliciousConsumerHook.Attack.ExactAmounts, idW, 1 ether);
        _expectSwapRevert(
            address(hM),
            abi.encodeWithSelector(ISharedCommitmentVault.PriceBelowFloor.selector, 2_850_000_000, 2_850_000_001)
        );
        _swapRaw(kM, cU == x0, -int256(2_850_000_000), "");
        _swapRaw(kM, cU == x0, -int256(2_850_000_001), "");
        assertEq(v.getAllocation(idW).consumed, 1 ether);

        uint256 idU = _alloc(kM, cU, 1000e6);
        uint256 req = FullMath.mulDivRoundingUp(1, _sellUsdcFloor(2850), Q96);
        assertEq(req, 350_877_193); // 1e12 / 2850 = 350,877,192.98... wei, rounded up
        hM.configure(MaliciousConsumerHook.Attack.ExactAmounts, idU, 1);
        _expectSwapRevert(
            address(hM), abi.encodeWithSelector(ISharedCommitmentVault.PriceBelowFloor.selector, req - 1, req)
        );
        _swapRaw(kM, cW == x0, -int256(req - 1), "");
        _swapRaw(kM, cW == x0, -int256(req), "");
    }
}
