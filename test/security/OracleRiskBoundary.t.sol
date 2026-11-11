// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {IMarketRiskAdapter} from "../../src/interfaces/IMarketRiskAdapter.sol";
import {VaultRiskBoundary} from "../../src/risk/VaultRiskBoundary.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {MaliciousConsumerHook} from "../utils/MaliciousConsumerHook.sol";
import {MockRiskAdapter} from "../utils/MockRiskAdapter.sol";

/// @notice The vault's market-risk boundary through the real PoolManager: the dynamic floor around the adapter's band,
///         the price-free inventory floor, malformed adapter answers, and every transition between static and adapter
///         mode (guardian restrictions must survive each one). Fills go through a registered test hook that pays exact,
///         chosen amounts, so each test probes the vault's own rule rather than a hook's pricing.
contract OracleRiskBoundaryTest is VaultTestBase {
    uint160 internal constant SWAP_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
    uint256 internal constant Q96 = FixedPoint96.Q96;
    uint24 internal constant EDGE = 100; // 1 bp
    uint24 internal constant MAX_U = 5000; // 50 bps
    uint24 internal constant KAPPA = 50_000; // 5%
    uint256 internal constant U = 1000; // 10 bps band half-width

    address internal guardian = makeAddr("guardian");
    MaliciousConsumerHook internal mal;
    PoolKey internal keyM;
    MockRiskAdapter internal adapter;
    uint256 internal tau; // per-share target of both assets, WAD (the vault starts at it)

    function setUp() public override {
        super.setUp();
        address m = address(uint160(0xBAD << 140) | SWAP_FLAGS);
        deployCodeTo("MaliciousConsumerHook.sol:MaliciousConsumerHook", abi.encode(manager, vault), m);
        mal = MaliciousConsumerHook(m);
        keyM = PoolKey(c0, c1, 3000, 60, IHooks(m));
        manager.initialize(keyM, SQRT_PRICE_1_1);
        adapter = new MockRiskAdapter(address(token0), address(token1), 18, 18, keccak256("v1"));
        adapter.set(Q96, U, type(uint256).max);
        tau = FullMath.mulDiv(vault.backing(c0), 1e18, vault.totalShares());
        vm.startPrank(owner);
        vault.setConsumer(m, true);
        _openLimits(ISharedCommitmentVault.RiskScope.Hook, m);
        vault.setGuardian(guardian);
        vault.setCuratorCeiling(curator, c0, type(uint256).max);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _install() internal {
        vm.startPrank(owner);
        vault.setRiskBounds(EDGE, MAX_U);
        vault.setInventoryBounds(tau, tau, KAPPA, KAPPA);
        vault.setRiskAdapter(adapter);
        vm.stopPrank();
    }

    /// @dev Adapter mode with the stored 1:1 floors removed, so only the adapter and the inventory floor price fills.
    function _installNoStaticFloors() internal {
        _install();
        vm.startPrank(owner);
        vault.setSellFloor(c0, 0);
        vault.setSellFloor(c1, 0);
        vm.stopPrank();
    }

    function _allocM(Currency out, uint128 maxOut, uint160 curatorFloor) internal returns (uint256 id) {
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyM, out, maxOut);
        r.minInPerOutX96 = curatorFloor;
        r.expiry = uint64(block.timestamp + 30 days);
        vm.prank(curator);
        id = auth.activateDirect(r);
    }

    function _trade(uint256 id, Currency out, uint256 amountIn, uint256 amountOut) internal {
        _tradeExpect(id, out, amountIn, amountOut, "");
    }

    function _tradeExpect(uint256 id, Currency out, uint256 amountIn, uint256 amountOut, bytes memory reason) internal {
        mal.configure(MaliciousConsumerHook.Attack.ExactAmounts, id, amountOut);
        if (reason.length != 0) _expectSwapRevert(address(mal), reason);
        _swapRaw(keyM, out == c1, -int256(amountIn), "");
    }

    /// @dev Smallest input the vault accepts for `amountOut` at Q64.96 floor `floor`.
    function _required(uint256 amountOut, uint256 floor) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(amountOut, floor, Q96);
    }

    function _dyn(Currency out, uint256 priceX96, uint256 u) internal view returns (uint256) {
        (uint256 f0, uint256 f1) = VaultRiskBoundary.dynamicFloors(priceX96, u, vault.riskEdgePips());
        return out == c0 ? f0 : f1;
    }

    function _invFloor(uint256 i) internal view returns (uint256) {
        return VaultRiskBoundary.inventoryFloor(
            vault.totalShares(), vault.inventoryTargetPerShare(i), vault.inventoryTolerancePips(i)
        );
    }

    function _net(Currency c) internal view returns (uint256) {
        return vault.backing(c) - vault.claimableAssets(c);
    }

    // ------------------------------------------------------------------
    // Dynamic floor (Task 5)
    // ------------------------------------------------------------------

    /// @notice In adapter mode a fill must pay at least the band edge P (1 + u + e), rounded up, in both directions.
    ///         One raw unit less is refused; exactly the floor is accepted. This is what refuses an in-band quote
    ///         from any hook, whatever the hook's own pricing.
    function test_dynamicFloor_bothDirections_exactBoundary() public {
        _installNoStaticFloors();
        uint256 out = 1000 ether;
        for (uint256 k; k < 2; ++k) {
            Currency c = k == 0 ? c0 : c1;
            uint256 id = _allocM(c, uint128(out * 2), 1);
            uint256 req = _required(out, _dyn(c, Q96, U));
            assertGt(req, out + out * U / 1e6, "floor lies beyond the band"); // P = 1: band edge is 1 + u
            _tradeExpect(
                id,
                c,
                req - 1,
                out,
                abi.encodeWithSelector(ISharedCommitmentVault.PriceBelowFloor.selector, req - 1, req)
            );
            _trade(id, c, req, out);
            assertEq(lens.effectiveFloorX96(vault, id), _dyn(c, Q96, U), "lens = vault floor");
        }
    }

    /// @notice The floor follows the adapter: after the reference moves, the next fill uses the new band.
    function test_dynamicFloor_tracksReference() public {
        _installNoStaticFloors();
        uint256 id = _allocM(c0, 10_000 ether, 1);
        adapter.set(Q96 * 2, U, type(uint256).max); // asset0 now worth 2 asset1
        uint256 req = _required(100 ether, _dyn(c0, Q96 * 2, U));
        _tradeExpect(
            id,
            c0,
            req - 1,
            100 ether,
            abi.encodeWithSelector(ISharedCommitmentVault.PriceBelowFloor.selector, req - 1, req)
        );
        _trade(id, c0, req, 100 ether);
    }

    /// @notice Malformed or unavailable adapter answers refuse the fill: zero price, expired reading, uncertainty
    ///         above the vault's bound, and an adapter that reverts (stale or contradictory sources).
    function test_invalidReadings_refused() public {
        _installNoStaticFloors();
        uint256 id = _allocM(c0, 10_000 ether, 1);
        uint256 req = _required(1 ether, _dyn(c0, Q96, U));

        adapter.set(0, U, type(uint256).max);
        _tradeExpect(id, c0, req, 1 ether, abi.encodeWithSelector(ISharedCommitmentVault.InvalidReference.selector));

        adapter.set(Q96, U, block.timestamp - 1);
        _tradeExpect(id, c0, req, 1 ether, abi.encodeWithSelector(ISharedCommitmentVault.InvalidReference.selector));

        adapter.set(Q96, MAX_U + 1, type(uint256).max);
        _tradeExpect(
            id,
            c0,
            req * 2,
            1 ether,
            abi.encodeWithSelector(VaultRiskBoundary.UncertaintyTooHigh.selector, MAX_U + 1, MAX_U)
        );

        adapter.set(Q96, U, type(uint256).max);
        adapter.setBroken(true);
        mal.configure(MaliciousConsumerHook.Attack.ExactAmounts, id, 1 ether);
        vm.expectRevert();
        _swapRaw(keyM, false, -int256(req), "");

        adapter.setBroken(false);
        _trade(id, c0, req, 1 ether);
    }

    // ------------------------------------------------------------------
    // Inventory floor (Task 1 corrections, Task 5)
    // ------------------------------------------------------------------

    /// @notice A malicious adapter (price ~0, zero uncertainty) lets an attacker buy for 1 raw unit, but only down to
    ///         the inventory floor: exactly N - L leaves, one more raw unit is refused, and LP accounting stays exact.
    function test_maliciousAdapter_stopsAtInventoryFloor() public {
        _installNoStaticFloors();
        for (uint256 k; k < 2; ++k) {
            Currency c = k == 0 ? c0 : c1;
            // To drain asset0 the adapter reports it worthless (P = 1); to drain asset1, asset1 worthless (P = 2^160).
            uint256 price = k == 0 ? 1 : 2 ** 160;
            adapter.set(price, 0, type(uint256).max);
            uint256 room = _net(c) - _invFloor(k);
            uint256 pay = _required(room + 1, _dyn(c, price, 0)); // what the corrupted price floor asks: dust
            assertLt(pay, room / 1e18, "the price floor alone would let the room go for dust");
            assertEq(lens.inventoryRoom(vault, c), room, "lens room");
            uint256 id = _allocM(c, uint128(room + 1), 1);
            uint256 floorAfter = _invFloor(k);
            _tradeExpect(
                id,
                c,
                pay,
                room + 1,
                abi.encodeWithSelector(VaultRiskBoundary.InventoryFloorBreached.selector, floorAfter - 1, floorAfter)
            );
            _trade(id, c, pay, room); // the whole room goes for dust, but not one raw unit more
            assertEq(_net(c), _invFloor(k), "holding at the floor");
        }
        _assertAccountingConsistent();
    }

    /// @notice The inventory floor applies in static mode too once targets are set, so leaving adapter mode (or never
    ///         entering it) does not drop it.
    function test_inventoryFloor_appliesInStaticMode() public {
        vm.prank(owner);
        vault.setInventoryBounds(tau, tau, KAPPA, KAPPA);
        uint256 room = _net(c0) - _invFloor(0);
        uint256 id = _allocM(c0, uint128(room + 1), PRICE_1_1_X96);
        _tradeExpect(
            id,
            c0,
            room + 1,
            room + 1,
            abi.encodeWithSelector(VaultRiskBoundary.InventoryFloorBreached.selector, _invFloor(0) - 1, _invFloor(0))
        );
        _trade(id, c0, room, room);
    }

    /// @notice With an adapter installed, a direction whose asset has no inventory target is refused outright.
    function test_adapterMode_requiresInventoryTarget() public {
        vm.startPrank(owner);
        vault.setRiskBounds(EDGE, MAX_U);
        vault.setInventoryBounds(tau, 0, KAPPA, KAPPA);
        vault.setRiskAdapter(adapter);
        vm.stopPrank();
        uint256 id = _allocM(c1, 10 ether, PRICE_1_1_X96);
        _tradeExpect(
            id,
            c1,
            20 ether,
            1 ether,
            abi.encodeWithSelector(ISharedCommitmentVault.InventoryBoundsNotConfigured.selector)
        );
    }

    // ------------------------------------------------------------------
    // Adapter installation (Task 5)
    // ------------------------------------------------------------------

    /// @notice An adapter must price this pair with the tokens' own decimals and answer now; only the owner installs.
    function test_setRiskAdapter_validation() public {
        MockRiskAdapter swapped = new MockRiskAdapter(address(token1), address(token0), 18, 18, bytes32(0));
        MockRiskAdapter wrongDecimals = new MockRiskAdapter(address(token0), address(token1), 6, 18, bytes32(0));
        vm.startPrank(owner);
        vault.setRiskBounds(EDGE, MAX_U);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InvalidRiskAdapter.selector, address(swapped)));
        vault.setRiskAdapter(swapped);
        vm.expectRevert(
            abi.encodeWithSelector(ISharedCommitmentVault.InvalidRiskAdapter.selector, address(wrongDecimals))
        );
        vault.setRiskAdapter(wrongDecimals);
        adapter.set(0, U, type(uint256).max);
        vm.expectRevert(ISharedCommitmentVault.InvalidReference.selector);
        vault.setRiskAdapter(adapter);
        adapter.set(Q96, U, type(uint256).max);
        vm.expectEmit(address(vault));
        emit ISharedCommitmentVault.RiskAdapterSet(address(0), address(adapter), keccak256("v1"));
        vault.setRiskAdapter(adapter);
        vm.stopPrank();

        vm.prank(guardian);
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setRiskAdapter(IMarketRiskAdapter(address(0)));
        vm.prank(attacker);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setRiskAdapter(IMarketRiskAdapter(address(0)));
    }

    // ------------------------------------------------------------------
    // Guardian protections across transitions (Task 2)
    // ------------------------------------------------------------------

    /// @notice A floor the guardian raised before the adapter was installed keeps binding in adapter mode: the fill
    ///         floor is the max of the stored floor, the curator floor and the dynamic floor.
    function test_guardianRaisedFloor_survivesInstall() public {
        vm.prank(guardian);
        vault.setSellFloor(c0, uint160(Q96 * 3 / 2)); // emergency: sell asset0 only at 1.5 or better
        _install();
        uint256 id = _allocM(c0, 100 ether, uint160(Q96 * 3 / 2));
        uint256 req = _required(10 ether, Q96 * 3 / 2);
        assertGt(req, _required(10 ether, _dyn(c0, Q96, U)), "stored floor is the binding one");
        _tradeExpect(
            id,
            c0,
            req - 1,
            10 ether,
            abi.encodeWithSelector(ISharedCommitmentVault.PriceBelowFloor.selector, req - 1, req)
        );
        _trade(id, c0, req, 10 ether);
    }

    /// @notice Clearing a stored floor is possible only in adapter mode, only by the owner (it loosens), and a cleared
    ///         floor closes the direction again when the adapter is removed.
    function test_clearStaticFloor_onlyInAdapterMode_closesOnRemoval() public {
        vm.prank(owner);
        vm.expectRevert(ISharedCommitmentVault.ZeroPriceFloor.selector);
        vault.setSellFloor(c0, 0);
        _install();
        vm.prank(guardian);
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setSellFloor(c0, 0);
        vm.prank(owner);
        vault.setSellFloor(c0, 0);
        uint256 id = _allocM(c0, 100 ether, 1);
        _trade(id, c0, _required(1 ether, _dyn(c0, Q96, U)), 1 ether);

        vm.prank(owner);
        vault.setRiskAdapter(IMarketRiskAdapter(address(0)));
        _tradeExpect(
            id,
            c0,
            10 ether,
            1 ether,
            abi.encodeWithSelector(ISharedCommitmentVault.PriceFloorNotConfigured.selector, c0)
        );
        // The other direction kept its stored floor and resumes static pricing; the inventory floor still applies.
        uint256 id1 = _allocM(c1, 100 ether, PRICE_1_1_X96);
        _trade(id1, c1, 1 ether, 1 ether);
        assertEq(vault.inventoryTargetPerShare(1), tau, "inventory bounds survive removal");
    }

    /// @notice A halt and a pause set before installation, replacement or removal stay in force across each.
    function test_haltAndPause_surviveTransitions() public {
        vm.startPrank(guardian);
        vault.setSellHalted(c1, true);
        vm.stopPrank();
        _install();
        uint256 id0 = _allocM(c0, 100 ether, PRICE_1_1_X96);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.DirectionHalted.selector, c1));
        vm.prank(curator);
        auth.activateDirect(_request(keyM, c1, 1 ether));

        MockRiskAdapter next = new MockRiskAdapter(address(token0), address(token1), 18, 18, keccak256("v2"));
        next.set(Q96, U, type(uint256).max);
        vm.prank(owner);
        vault.setRiskAdapter(next);
        vm.prank(guardian);
        vault.setPaused(true);
        _tradeExpect(id0, c0, 2 ether, 1 ether, abi.encodeWithSelector(ISharedCommitmentVault.Paused.selector));
        vm.prank(owner);
        vault.setRiskAdapter(IMarketRiskAdapter(address(0)));
        assertTrue(vault.paused(), "still paused");
        (, bool halted) = vault.sellPolicy(c1);
        assertTrue(halted, "still halted");
    }

    /// @notice Guardian may only tighten the new bounds: raise the edge, lower the uncertainty bound, raise targets,
    ///         lower tolerances. Every loosening, alone or mixed with a tightening, is refused.
    function test_guardian_canOnlyTightenRiskBounds() public {
        _install();
        vm.startPrank(guardian);
        vault.setRiskBounds(EDGE + 1, MAX_U - 1);
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setRiskBounds(EDGE, MAX_U - 1);
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setRiskBounds(EDGE + 1, MAX_U);
        vault.setInventoryBounds(tau + 1, tau, KAPPA - 1, KAPPA);
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setInventoryBounds(tau, tau, KAPPA - 1, KAPPA); // lower target 0
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setInventoryBounds(tau + 2, tau, KAPPA, KAPPA); // raise tolerance 0 while raising target 0
        vm.stopPrank();
        vm.prank(owner);
        vm.expectRevert(ISharedCommitmentVault.InventoryBoundsNotConfigured.selector);
        vault.setInventoryBounds(tau, tau, 1_000_001, KAPPA);
    }

    /// @notice Replacing the adapter while allocations are live re-prices them at once (fills read the adapter every
    ///         time); the curator's own floor keeps binding.
    function test_replaceAdapter_duringActiveAllocation() public {
        _installNoStaticFloors();
        uint256 id = _allocM(c0, 100 ether, uint160(Q96 * 11 / 10)); // curator floor 1.1
        MockRiskAdapter next = new MockRiskAdapter(address(token0), address(token1), 18, 18, keccak256("v2"));
        next.set(Q96 * 2, U, type(uint256).max);
        vm.prank(owner);
        vault.setRiskAdapter(next);
        uint256 req = _required(1 ether, _dyn(c0, Q96 * 2, U));
        _tradeExpect(
            id,
            c0,
            req - 1,
            1 ether,
            abi.encodeWithSelector(ISharedCommitmentVault.PriceBelowFloor.selector, req - 1, req)
        );
        next.set(Q96 / 2, U, type(uint256).max); // dynamic floor 0.5: the curator floor of 1.1 binds instead
        req = _required(1 ether, Q96 * 11 / 10);
        _tradeExpect(
            id,
            c0,
            req - 1,
            1 ether,
            abi.encodeWithSelector(ISharedCommitmentVault.PriceBelowFloor.selector, req - 1, req)
        );
        _trade(id, c0, req, 1 ether);
    }

    /// @notice LP paths never read the adapter: with the adapter reverting, deposits, instant and queued redemptions,
    ///         queue processing, claims and cancellation all still work, and only fills stop.
    function test_lpPaths_independentOfAdapter() public {
        _installNoStaticFloors();
        uint256 id = _allocM(c0, uint128(_net(c0) / 2), 1); // reserve half of asset0 so a redemption queues
        adapter.setBroken(true);
        _depositShares(trader, 1000 ether);
        _redeem(trader, 400 ether, true);
        (,,, uint256 rid) = _redeem(lp0, vault.sharesOf(lp0) * 9 / 10, true);
        assertGt(rid, 0, "queued behind the reservation");
        vm.prank(owner);
        vault.release(id);
        vault.processQueue(10);
        vm.prank(lp0);
        vault.claim(rid);
        _assertAccountingConsistent();
    }
}
