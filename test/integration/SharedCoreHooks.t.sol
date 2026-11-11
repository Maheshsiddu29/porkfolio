// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {IMarketRiskAdapter} from "../../src/interfaces/IMarketRiskAdapter.sol";
import {BaseCompatibleHook} from "../../src/hooks/BaseCompatibleHook.sol";
import {InventoryPricing} from "../../src/pricing/InventoryPricing.sol";
import {StrategyPricing} from "../../src/pricing/StrategyPricing.sol";
import {VaultRiskBoundary} from "../../src/risk/VaultRiskBoundary.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {MockRiskAdapter} from "../utils/MockRiskAdapter.sol";

/// @notice Both production hooks in shared-core mode, through the real PoolManager and the production builds: they read
///         the reference from the vault's adapter, price from the vault's inventory, and stay inside the vault's
///         boundary. Hook A adds a cumulative activity fee, Hook B a flat markup with a per-trade impact bound.
contract SharedCoreHooksTest is VaultTestBase {
    uint256 internal constant Q96 = FixedPoint96.Q96;
    uint24 internal constant EDGE = 100; // vault edge 1 bp
    uint24 internal constant U = 1000; // adapter band 10 bps
    uint24 internal constant KAPPA = 50_000; // 5%
    uint24 internal constant MARKUP = 1000; // Hook B 10 bps
    uint24 internal constant B_TRADE_IMPACT = 20_000; // Hook B 2% per trade

    address internal guardian = makeAddr("guardian");
    MockRiskAdapter internal adapter;
    uint256 internal tau;

    function setUp() public override {
        super.setUp();
        adapter = new MockRiskAdapter(address(token0), address(token1), 18, 18, keccak256("v1"));
        adapter.set(Q96, U, type(uint256).max);
        tau = FullMath.mulDiv(vault.backing(c0), 1e18, vault.totalShares());
        vm.startPrank(owner);
        vault.setGuardian(guardian);
        vault.setRiskBounds(EDGE, 5000);
        vault.setInventoryBounds(tau, tau, KAPPA, KAPPA);
        vault.setRiskAdapter(adapter);
        vm.stopPrank();
        BaseCompatibleHook.CoreParams memory p = BaseCompatibleHook.CoreParams({
            depthPerShare: 10e18, // V = 10 x the target holding
            depthMax: uint128(2 ** 95 - 1),
            baseSpreadPips: 3000,
            minEdgePips: 200,
            maxSpreadPips: 40_000,
            maxDeviationPips: KAPPA
        });
        vm.startPrank(hookOwner);
        hookA.configureCore(keyA, p);
        hookB.configureCore(keyB, p);
        hookB.configureStrategy(keyB, MARKUP, B_TRADE_IMPACT);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ helpers

    function _core() internal view returns (InventoryPricing.Core memory) {
        InventoryPricing.Config memory cfg = InventoryPricing.Config({
            targetPerShare: vault.inventoryTargetPerShare(1),
            depthPerShare: 10e18,
            depthMax: 2 ** 95 - 1,
            baseSpread: 3000,
            minEdge: 200 > uint256(vault.riskEdgePips()) + 1 ? 200 : uint256(vault.riskEdgePips()) + 1,
            maxSpread: 40_000,
            maxDeviation: vault.inventoryTolerancePips(1) < KAPPA ? vault.inventoryTolerancePips(1) : KAPPA,
            bandEdge: true
        });
        IMarketRiskAdapter.Reading memory r = adapter.currentReference();
        return InventoryPricing.coreState(
            cfg, vault.backing(c1) - vault.claimableAssets(c1), vault.totalShares(), r.priceX96, r.uncertaintyPips
        );
    }

    function _out(BalanceDelta d, bool zeroForOne) internal pure returns (uint256) {
        return uint256(int256(zeroForOne ? d.amount1() : d.amount0()));
    }

    function _swapOut(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal returns (uint256) {
        uint256 id = _allocate(key, zeroForOne ? c1 : c0, uint128(amountIn * 2));
        return _out(_swap(key, zeroForOne, amountIn, id), zeroForOne);
    }

    /// @dev As `_swapOut`, through an allocation whose curator floor is the minimum (1), so only the vault's own
    ///      floors and the hook's price decide the fill.
    function _swapOutMinCuratorFloor(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal returns (uint256) {
        ISharedCommitmentVault.AllocationRequest memory r = _request(key, zeroForOne ? c1 : c0, uint128(amountIn * 2));
        r.minInPerOutX96 = 1;
        vm.prank(curator);
        uint256 id = auth.activateDirect(r);
        return _out(_swap(key, zeroForOne, amountIn, id), zeroForOne);
    }

    // ------------------------------------------------------------------ pricing

    /// @notice Every fill of either hook, in either direction, is priced beyond the reference band widened by the
    ///         vault edge (output below input * (1 - u - e) at P = 1), and the vault accepts it.
    function test_bothHooks_fillOutsideBand() public {
        for (uint256 k; k < 4; ++k) {
            PoolKey memory key = k < 2 ? keyA : keyB;
            bool zeroForOne = k % 2 == 0;
            uint256 amountIn = 1000 ether;
            uint256 out = _swapOut(key, zeroForOne, amountIn);
            assertGt(out, 0);
            assertLt(out * 1e6, amountIn * (1e6 - uint256(U) - EDGE), "beyond the band edge");
        }
    }

    /// @notice The hooks' quotes equal the shared libraries evaluated on the vault's own state and the vault's adapter.
    function test_quotesEqualLibraries() public view {
        InventoryPricing.Core memory core = _core();
        uint256 amountIn = 777 ether;
        uint256 b = StrategyPricing.hookB(core, MARKUP, B_TRADE_IMPACT, true, amountIn).amountOut;
        assertEq(hookB.quote(keyB, true, amountIn), b, "Hook B");
        uint256 a =
            StrategyPricing.hookA(
            core, StrategyPricing.ActivityFee(A_BASE_FEE, A_MAX_FEE, A_SCALE, A_SCALE), 0, false, amountIn
        )
        .amountOut;
        assertEq(hookA.quote(keyA, false, amountIn), a, "Hook A");
    }

    /// @notice Hook A's activity fee keeps its state in shared-core mode: a swap raises the direction's flow level,
    ///         so the same trade right after pays a higher fee and receives less.
    function test_hookA_activityLevelPersistsInCoreMode() public {
        assertEq(hookA.flowLevel(keyA, true), 0);
        uint256 q0 = hookA.feeFor(keyA, true, 1000 ether);
        _swapOut(keyA, true, 1000 ether);
        assertEq(hookA.flowLevel(keyA, true), 1000 ether, "level stored");
        assertGt(hookA.feeFor(keyA, true, 1000 ether), q0, "next trade pays more");
    }

    /// @notice Hooks have no adapter of their own: their quotes follow whatever adapter the vault holds, including
    ///         after the vault's owner replaces it.
    function test_quotesFollowTheVaultsAdapter() public {
        uint256 q0 = hookB.quote(keyB, true, 100 ether);
        adapter.set(Q96 * 2, U, type(uint256).max);
        uint256 q1 = hookB.quote(keyB, true, 100 ether);
        assertApproxEqRel(q1, q0 * 2, 0.01e18, "selling asset0 at twice the price");
        MockRiskAdapter other = new MockRiskAdapter(address(token0), address(token1), 18, 18, keccak256("v2"));
        other.set(Q96 / 2, U, type(uint256).max);
        vm.prank(owner);
        vault.setRiskAdapter(other);
        assertApproxEqRel(hookB.quote(keyB, true, 100 ether), q0 / 2, 0.01e18, "the new adapter");
        assertApproxEqRel(hookA.quote(keyA, true, 100 ether), q0 / 2, 0.01e18, "Hook A too");
    }

    /// @notice An adapter that reverts stops both hooks; nothing falls back to a static price.
    function test_adapterFailure_stopsBothHooks() public {
        adapter.setBroken(true);
        vm.expectRevert(bytes("sources unavailable"));
        hookA.quote(keyA, true, 1 ether);
        vm.expectRevert(bytes("sources unavailable"));
        hookB.quote(keyB, true, 1 ether);
    }

    // ------------------------------------------------------------------ cross-hook behaviour (Task 8)

    /// @notice Routing back and forth across the two hooks always loses: after ten alternating round trips the trader
    ///         holds strictly less of what it started with, and the loss grows with every leg.
    function test_crossHookCycles_lose() public {
        uint256 amount = 5000 ether; // token0
        uint256 prev = amount;
        for (uint256 i; i < 10; ++i) {
            uint256 got1 = _swapOut(i % 2 == 0 ? keyA : keyB, true, amount);
            amount = _swapOut(i % 2 == 0 ? keyB : keyA, false, got1);
            assertLt(amount, prev, "each round trip loses");
            prev = amount;
        }
        assertLt(amount, 5000 ether * (1e6 - 2 * uint256(U + EDGE)) / 1e6, "at least the band on every leg");
    }

    /// @notice The inventory cap belongs to the vault's inventory, not to a hook: once Hook A has pushed the core to
    ///         its cap, Hook B refuses any further trade in the same direction and still serves the other direction.
    function test_inventoryCap_sharedAcrossHooks() public {
        InventoryPricing.Core memory core = _core();
        // Push with Hook A until the remaining room is small (Hook A's fee only reduces how far each trade moves it).
        for (uint256 i; i < 40; ++i) {
            core = _core();
            uint256 room = uint256(int256(core.cap) - core.inventory);
            if (room < 50 ether) break;
            try hookA.quote(keyA, true, room / 2) returns (uint256) {
                _swapOut(keyA, true, room / 2);
            } catch {
                break;
            }
        }
        core = _core();
        uint256 left = uint256(int256(core.cap) - core.inventory);
        vm.expectPartialRevert(InventoryPricing.InventoryLimit.selector);
        hookB.quote(keyB, true, left * 2);
        assertGt(hookB.quote(keyB, false, 100 ether), 0, "the other direction still trades");
    }

    /// @notice Splitting one order across the two hooks never beats the core on the whole order: each strategy only
    ///         adds to the core price.
    function test_splitAcrossHooks_paysAtLeastTheCore() public {
        uint256 x = 4000 ether;
        (uint256 coreOnly,) = InventoryPricing.ask(_core(), x);
        uint256 viaA = _swapOut(keyA, true, x / 2);
        uint256 viaB = _swapOut(keyB, true, x / 2);
        assertLe(viaA + viaB, coreOnly);
    }

    // ------------------------------------------------------------------ vault limits reach the hooks

    /// @notice The guardian's tightening on the vault reaches both hooks with no hook action. A higher vault edge
    ///         raises the hooks' own edge (vault edge + 1 pip), which pins the end of their curve further out and so
    ///         shrinks their inventory cap; once it reaches the hooks' spread they stop quoting rather than quote inside
    ///         the vault's floor. A lower kappa shrinks the cap directly.
    function test_guardianTightening_reachesHooks() public {
        uint256 capBefore = _core().cap;
        vm.prank(guardian);
        vault.setRiskBounds(2000, 5000); // edge 1 bp -> 20 bps
        assertLt(_core().cap, capBefore, "smaller cap");
        vm.prank(guardian);
        vault.setRiskBounds(3000, 5000); // edge + 1 pip + u above the hooks' spread (base 30 bps + u)
        vm.expectPartialRevert(InventoryPricing.InventoryLimit.selector);
        hookB.quote(keyB, true, 1 ether);

        vm.prank(owner);
        vault.setRiskBounds(EDGE, 5000);
        uint256 big = uint256(_core().cap) * 9 / 10;
        hookA.quote(keyA, true, big); // fits under kappa 5%
        vm.prank(guardian);
        vault.setInventoryBounds(tau, tau, 1000, 1000); // kappa 5% -> 0.1%
        vm.expectPartialRevert(InventoryPricing.InventoryLimit.selector);
        hookA.quote(keyA, true, big);
    }

    /// @notice A wrong reference (asset0 overpriced by 10%) invites one-way flow. Floors that do not come from the
    ///         adapter still bind in adapter mode: the fixture's stored 1:1 floor, and the curator's floor (which may
    ///         not be below it), refuse the mispriced fill outright.
    function test_wrongReference_refusedByStoredFloor() public {
        adapter.set(Q96 * 11 / 10, U, type(uint256).max);
        uint256 amountIn = 1000 ether;
        uint256 out = hookB.quote(keyB, true, amountIn);
        assertGt(out, amountIn, "the hook, trusting the adapter, would pay more than 1:1");
        uint256 id = _allocate(keyB, c1, uint128(out));
        _expectSwapRevert(
            address(hookB), abi.encodeWithSelector(ISharedCommitmentVault.PriceBelowFloor.selector, amountIn, out)
        );
        _swap(keyB, true, amountIn, id);
    }

    /// @notice Without stored floors, the same wrong reference is bounded by the hooks' cap, which is never beyond
    ///         kappa: the vault's asset1 holding stays at or above its inventory floor and the vault never has to step in.
    function test_wrongReference_stopsAtCapAboveVaultFloor() public {
        vm.startPrank(owner);
        vault.setSellFloor(c0, 0);
        vault.setSellFloor(c1, 0);
        vm.stopPrank();
        adapter.set(Q96 * 11 / 10, U, type(uint256).max);
        uint256 fills;
        for (uint256 i; i < 40; ++i) {
            InventoryPricing.Core memory core = _core();
            uint256 room = uint256(int256(core.cap) - core.inventory);
            if (room < 10 ether) break;
            try hookB.quote(keyB, true, room / 2) returns (uint256) {
                _swapOutMinCuratorFloor(keyB, true, room / 2);
                ++fills;
            } catch {
                break;
            }
        }
        assertGt(fills, 0, "the mispriced flow did trade");
        uint256 floor1 = VaultRiskBoundary.inventoryFloor(vault.totalShares(), tau, KAPPA);
        assertGe(vault.backing(c1) - vault.claimableAssets(c1), floor1);
    }

    /// @notice Removing the adapter returns both hooks to their static pricing, unchanged.
    function test_removingAdapter_restoresStaticPricing() public {
        vm.prank(owner);
        vault.setRiskAdapter(IMarketRiskAdapter(address(0)));
        uint256 staticQuote = hookA.quote(keyA, true, 1000 ether);
        assertEq(staticQuote, 1000 ether - hookA.feeFor(keyA, true, 1000 ether), "static 1:1 minus fee");
    }
}
