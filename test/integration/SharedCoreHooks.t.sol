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
import {PricingHarness} from "../pricing/PricingHarness.sol";

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

    /// @notice `coreInputs` returns exactly what the separate getters return (the hooks read it in one call), and in
    ///         static mode only the zero adapter, so a hook never prices static pools from stale core inputs.
    function test_coreInputs_matchGetters() public {
        _depositShares(makeAddr("x"), 1e21);
        // An asymmetric state, so an index or asset swap inside `coreInputs` cannot pass: different targets and
        // tolerances per asset, and N0 != N1 after a fill.
        vm.prank(guardian);
        vault.setInventoryBounds(tau + 1, tau + 2, KAPPA - 1, KAPPA - 2);
        _swapOut(keyB, true, 500 ether);
        assertTrue(vault.backing(c0) != vault.backing(c1));
        (IMarketRiskAdapter a, uint256 e, uint256 k1, uint256 t1, uint256 n1, uint256 s) = vault.coreInputs();
        assertEq(address(a), address(vault.riskAdapter()));
        assertEq(e, vault.riskEdgePips());
        assertEq(k1, vault.inventoryTolerancePips(1));
        assertEq(t1, vault.inventoryTargetPerShare(1));
        assertEq(n1, vault.backing(c1) - vault.claimableAssets(c1));
        assertEq(s, vault.totalShares());
        vm.prank(owner);
        vault.setRiskAdapter(IMarketRiskAdapter(address(0)));
        (a, e, k1, t1, n1, s) = vault.coreInputs();
        assertEq(address(a), address(0));
        assertEq(e + k1 + t1 + n1 + s, 0);
    }

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

    /// @notice Conformance on random states: after a random price and uncertainty, a random LP deposit, a random
    ///         inventory move and random Hook A activity, both hooks quote exactly what the libraries compute from the
    ///         vault's state, in both directions, and refuse exactly when the libraries refuse. The libraries are pinned
    ///         to the Python model by 240 random vectors (`test/pricing/SharedCoreVectors.t.sol`), so this closes the
    ///         chain hook = library = model on states no fixed test chose.
    function testFuzz_quotesEqualLibraries_randomStates(
        uint256 pSeed,
        uint256 uSeed,
        uint256 sharesSeed,
        uint256 moveSeed,
        uint256 amountSeed,
        bool moveDir
    ) public {
        PricingHarness h = new PricingHarness();
        vm.startPrank(owner);
        vault.setSellFloor(c0, 0); // only the adapter band and the inventory floor bind (adapter mode)
        vault.setSellFloor(c1, 0);
        vm.stopPrank();
        uint256 price = bound(pSeed, Q96 / 2, 2 * Q96);
        adapter.set(price, bound(uSeed, 0, 5000), type(uint256).max);
        _depositShares(makeAddr("fuzzLp"), bound(sharesSeed, 0, vault.totalShares() / 2) + 1);
        uint256 cap = _core().cap;
        uint256 move = bound(moveSeed, 0, cap / 3);
        if (move > 1 ether) _swapOutMinCuratorFloor(moveSeed % 2 == 0 ? keyA : keyB, moveDir, move);
        vm.warp(vm.getBlockTimestamp() + moveSeed % 2 hours);

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
        uint256 n1 = vault.backing(c1) - vault.claimableAssets(c1);
        uint256 s = vault.totalShares();
        for (uint256 d; d < 2; ++d) {
            bool zfo = d == 0;
            uint256 amountIn = bound(uint256(keccak256(abi.encode(amountSeed, d))), 1e12, 2 * cap);
            StrategyPricing.ActivityFee memory fee =
                StrategyPricing.ActivityFee(A_BASE_FEE, A_MAX_FEE, A_SCALE, A_SCALE);
            (bool okL, bytes memory retL) = address(h)
                .staticcall(
                    abi.encodeCall(
                        h.hookA,
                        (cfg, n1, s, r.priceX96, r.uncertaintyPips, fee, hookA.flowLevel(keyA, zfo), zfo, amountIn)
                    )
                );
            (bool okH, bytes memory retH) =
                address(hookA).staticcall(abi.encodeCall(hookA.quote, (keyA, zfo, amountIn)));
            assertEq(okH, okL, "Hook A: refuses exactly when the library does");
            if (okH) {
                (StrategyPricing.Quote memory q,) = abi.decode(retL, (StrategyPricing.Quote, uint256));
                assertEq(abi.decode(retH, (uint256)), q.amountOut, "Hook A");
            }
            (okL, retL) = address(h)
                .staticcall(
                    abi.encodeCall(
                        h.hookB, (cfg, n1, s, r.priceX96, r.uncertaintyPips, MARKUP, B_TRADE_IMPACT, zfo, amountIn)
                    )
                );
            (okH, retH) = address(hookB).staticcall(abi.encodeCall(hookB.quote, (keyB, zfo, amountIn)));
            assertEq(okH, okL, "Hook B: refuses exactly when the library does");
            if (okH) {
                (StrategyPricing.Quote memory q,) = abi.decode(retL, (StrategyPricing.Quote, uint256));
                assertEq(abi.decode(retH, (uint256)), q.amountOut, "Hook B");
            }
        }
    }

    /// @notice When the vault's edge exceeds a hook's own minimum edge, the hook prices with the vault edge + 1 pip, not
    ///         the vault edge itself. The extra pip pins the curve's end strictly outside the vault's floor, so rounding
    ///         can never put a quote one raw unit inside it. The difference shows at the inventory cap: an order that
    ///         would fit a curve built on the vault edge alone is refused by the hook.
    function test_hookEdge_isVaultEdgePlusOne() public {
        vm.prank(guardian);
        vault.setRiskBounds(300, 5000); // above the hooks' own 200 pips
        PricingHarness h = new PricingHarness();
        InventoryPricing.Config memory cfg = InventoryPricing.Config({
            targetPerShare: tau,
            depthPerShare: 10e18,
            depthMax: 2 ** 95 - 1,
            baseSpread: 3000,
            minEdge: 301,
            maxSpread: 40_000,
            maxDeviation: KAPPA,
            bandEdge: true
        });
        InventoryPricing.Config memory atEdge = InventoryPricing.Config({ // a separate struct: memory assignment aliases
            targetPerShare: tau,
            depthPerShare: 10e18,
            depthMax: 2 ** 95 - 1,
            baseSpread: 3000,
            minEdge: 300,
            maxSpread: 40_000,
            maxDeviation: KAPPA,
            bandEdge: true
        });
        IMarketRiskAdapter.Reading memory r = adapter.currentReference();
        uint256 n1 = vault.backing(c1) - vault.claimableAssets(c1);
        uint256 s = vault.totalShares();
        // Largest Hook A order (no per-trade bound) the curve built on the vault edge alone would fill (binary search).
        StrategyPricing.ActivityFee memory fee = StrategyPricing.ActivityFee(A_BASE_FEE, A_MAX_FEE, A_SCALE, A_SCALE);
        uint256 lo = 1 ether;
        uint256 hi = 100_000 ether;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            try h.hookA(atEdge, n1, s, r.priceX96, r.uncertaintyPips, fee, 0, true, mid) {
                lo = mid;
            } catch {
                hi = mid;
            }
        }
        (bool okPlusOne,) = address(h)
            .staticcall(abi.encodeCall(h.hookA, (cfg, n1, s, r.priceX96, r.uncertaintyPips, fee, 0, true, lo)));
        assertFalse(okPlusOne, "the order sits between the two caps");
        vm.expectPartialRevert(InventoryPricing.InventoryLimit.selector);
        hookA.quote(keyA, true, lo);
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

    /// @notice No route across the two hooks beats the shared core. A trade of `total` is cut into 1-8 random pieces,
    ///         each sent to a random hook, with up to an hour between pieces (Hook A's fee decays; the core does not).
    ///         The total output never exceeds what the strategy-free core pays for `total` in one piece from the
    ///         starting inventory: the core charge telescopes on the shared inventory and each strategy only removes
    ///         value. Routing can still pick the cheaper strategy for each piece (`simulations/mm/hook_routing.py`).
    function testFuzz_routingAcrossHooks_neverBeatsTheCore(uint256 seed, uint256 totalSeed, bool zeroForOne) public {
        uint256 total = bound(totalSeed, 10 ether, _core().cap * 8 / 10); // within the shared inventory cap
        uint256 n = bound(seed, 1, 8);
        uint256 coreOnly;
        if (zeroForOne) (coreOnly,) = InventoryPricing.ask(_core(), total);
        else (coreOnly,) = InventoryPricing.bid(_core(), total, total);
        uint256 got;
        uint256 left = total;
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 piece = i == n - 1 ? left : bound(r, 1 ether, left - (n - 1 - i) * 1 ether);
            left -= piece;
            got += _swapOut(r % 2 == 0 ? keyA : keyB, zeroForOne, piece);
            vm.warp(vm.getBlockTimestamp() + (r >> 128) % 1 hours);
        }
        assertLe(got, coreOnly);
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
