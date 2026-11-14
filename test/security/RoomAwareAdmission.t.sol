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
import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {VaultStateReader} from "../../src/libraries/VaultStateReader.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {MaliciousConsumerHook} from "../utils/MaliciousConsumerHook.sol";
import {MockRiskAdapter} from "../utils/MockRiskAdapter.sol";

using VaultStateReader for SharedCommitmentVault;

/// @notice Room-aware admission: a new reservation must fit both N - Q - R - D and, when the asset has an inventory
///         target, the room above the inventory floor left by existing reservations, N - L - Q.
/// @dev Fixture: VaultTestBase (1,000,000 of each asset, 1:1 floors, static mode) plus a test hook that fills exact
///      amounts. Every expected limit below is computed in the test from raw quantities, independently of the vault's
///      and the reader's formula. What admission promises is that the reserved units were sellable when admitted; it
///      promises nothing about later fills (CE-2 in ReservationDeliverability.t.sol).
contract RoomAwareAdmissionTest is VaultTestBase {
    uint160 internal constant SWAP_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

    MaliciousConsumerHook internal mal;
    PoolKey internal keyM;

    function setUp() public override {
        super.setUp();
        address m = address(uint160(0xBAD7 << 140) | SWAP_FLAGS);
        deployCodeTo("MaliciousConsumerHook.sol:MaliciousConsumerHook", abi.encode(manager, vault), m);
        mal = MaliciousConsumerHook(m);
        keyM = PoolKey(c0, c1, 3000, 60, IHooks(m));
        manager.initialize(keyM, SQRT_PRICE_1_1);
        vm.startPrank(owner);
        vault.setConsumer(m, true);
        _openLimits(ISharedCommitmentVault.RiskScope.Hook, m);
        vault.setCuratorCeiling(curator, c0, type(uint256).max);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ helpers

    function _fill(uint256 id, Currency out, uint256 amountOut, uint256 amountIn) internal {
        mal.configure(MaliciousConsumerHook.Attack.ExactAmounts, id, amountOut);
        _swapRaw(keyM, out == c1, -int256(amountIn), "");
    }

    function _expectRefused(Currency out, uint256 q, uint256 available) internal {
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyM, out, uint128(q));
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientBacking.selector, q, available));
        auth.activateDirect(r);
    }

    /// @dev L = ceil(S * tau * (1e6 - kappa) / 1e24), written out here rather than calling the vault's library.
    function _floor(uint256 i) internal view returns (uint256) {
        uint256 tau = vault.inventoryTargetPerShare(i);
        if (tau == 0) return 0;
        return FullMath.mulDivRoundingUp(vault.totalShares() * tau, 1e6 - vault.inventoryTolerancePips(i), 1e24);
    }

    /// @dev min(max(0, N - Q - R - D), max(0, N - L - Q)) from raw stored values; the second term only with a target.
    function _expectedLimit(Currency c) internal view returns (uint256 limit) {
        uint256 i = c == c1 ? 1 : 0;
        uint256 n = vault.backing(c) - vault.claimableAssets(c);
        uint256 q = vault.reserved(c);
        uint256 p = vault.pendingShares();
        uint256 d = p == 0 ? 0 : FullMath.mulDivRoundingUp(p, n, vault.totalShares());
        uint256 r = vault.bufferFloor(c);
        limit = n > q + d && n - q - d > r ? n - q - d - r : 0;
        if (vault.inventoryTargetPerShare(i) != 0) {
            uint256 l = _floor(i);
            uint256 room = n > l + q ? n - l - q : 0;
            if (room < limit) limit = room;
        }
    }

    // ------------------------------------------------------------------ boundaries

    /// @notice With an earlier reservation in place, the room left is exactly N - L - Q: that amount is admitted and
    ///         one more unit is refused, in both asset directions, with different targets per asset.
    function test_exactBoundary_bothAssets() public {
        vm.prank(owner);
        vault.setInventoryBounds(1e18, 0.9e18, 50_000, 20_000); // L0 = 950,000; L1 = ceil(0.9 * 0.98 * S) = 882,000
        for (uint256 k; k < 2; ++k) {
            Currency c = k == 0 ? c0 : c1;
            uint256 roomBefore = vault.backing(c) - _floor(k);
            // Asset1: N1 = 1,040,000 after asset0's fills paid 40,000 asset1 in; room = 1,040,000 - 882,000.
            assertEq(roomBefore, k == 0 ? 50_000 ether : 158_000 ether);
            _allocate(keyA, c, 10_000 ether); // Q > 0 before the boundary
            uint256 left = roomBefore - 10_000 ether;
            assertEq(vault.admissibleCapacity(c), left, "reader limit");
            assertEq(_expectedLimit(c), left, "independent limit");
            _expectRefused(c, left + 1, left);
            uint256 id = _allocate(keyM, c, uint128(left));
            _expectRefused(c, 1, 0);
            assertEq(vault.reserved(c), roomBefore, "Q == room right after admission");
            _fill(id, c, left, left); // every admitted unit was sellable
            assertEq(lens.inventoryRoom(vault, c), 10_000 ether, "only the first reservation's room is left");
        }
        _assertEquations();
    }

    /// @notice With LPs queued, both rules bind at their exact values: D = ceil(P * N / S) is protected by the first,
    ///         and the queued shares stay inside S, so they also raise L. Whichever is smaller is the limit.
    function test_pendingWithdrawals_bothRulesAtTheirBoundary() public {
        // A reservation without a floor, then lp0 redeems half its shares: free inventory pays about a tenth of S at
        // once and the rest (about 40% of S) queues behind the reservation.
        uint256 big = _allocate(keyA, c0, 900_000 ether);
        _redeem(lp0, vault.sharesOf(lp0) / 2, true);
        uint256 p = vault.pendingShares();
        assertGt(p, 0, "queued");
        // Release the reservation without processing the queue: P stays, free inventory returns.
        vm.prank(owner);
        vault.release(big);
        assertEq(vault.pendingShares(), p);

        // No target: the first rule alone, with D > 0.
        uint256 n0 = vault.backing(c0) - vault.claimableAssets(c0);
        uint256 d0 = FullMath.mulDivRoundingUp(p, n0, vault.totalShares());
        assertGt(d0, 0);
        assertEq(vault.admissibleCapacity(c0), n0 - d0, "N - D");
        _expectRefused(c0, n0 - d0 + 1, n0 - d0);

        // A target low enough that the first rule binds, then high enough that the room binds.
        vm.prank(owner);
        vault.setInventoryBounds(0.001e18, 0.001e18, 0, 0); // L tiny: N - D < N - L
        assertEq(vault.admissibleCapacity(c0), n0 - d0, "first rule binds");
        assertEq(_expectedLimit(c0), n0 - d0);
        vm.prank(owner);
        vault.setInventoryBounds(1e18, 1e18, 50_000, 50_000); // L = 95% of S: room < N - D
        uint256 l0 = _floor(0);
        assertEq(l0, FullMath.mulDivRoundingUp(vault.totalShares(), 950_000, 1e6), "queued shares are inside S");
        uint256 room = n0 > l0 ? n0 - l0 : 0;
        assertLt(room, n0 - d0);
        assertEq(vault.admissibleCapacity(c0), room, "room binds");
        _expectRefused(c0, room + 1, room);
        if (room != 0) _allocate(keyM, c0, uint128(room));
        _assertEquations();
    }

    /// @notice tau = 0 in static mode: no floor, so only N - Q - R - D applies (the whole asset can be reserved).
    ///         kappa = 1e6 with a target: L = 0, so the room is N and adds nothing either.
    function test_zeroTargetOrFullTolerance_noRoomRule() public {
        assertEq(vault.inventoryTargetPerShare(0), 0);
        uint256 n = vault.backing(c0);
        assertEq(vault.admissibleCapacity(c0), n);
        vm.prank(owner);
        vault.setInventoryBounds(1e18, 1e18, 1e6, 1e6);
        assertEq(_floor(0), 0);
        assertEq(vault.admissibleCapacity(c0), n, "room = N");
        uint256 id = _allocate(keyM, c0, uint128(n));
        assertEq(vault.reserved(c0), n);
        _fill(id, c0, 1000 ether, 1000 ether);
        _assertEquations();
    }

    /// @notice Adapter mode with no target for the sold asset: admission applies no room rule (there is no floor) and
    ///         admits the reservation, but every fill of it is refused, because in adapter mode an asset without a
    ///         target cannot be sold. A configuration error, not a loss: the capacity stays reserved and unsellable
    ///         until it is released. With a target set the room rule applies as in static mode.
    function test_adapterMode_zeroTarget_admittedButNeverFillable() public {
        MockRiskAdapter adapter = new MockRiskAdapter(address(token0), address(token1), 18, 18, keccak256("room"));
        adapter.set(FixedPoint96.Q96, 1000, type(uint256).max);
        vm.startPrank(owner);
        vault.setRiskBounds(100, 5000);
        vault.setRiskAdapter(IMarketRiskAdapter(address(adapter)));
        vault.setInventoryBounds(0, 1e18, 50_000, 50_000); // target only on asset1
        vm.stopPrank();

        uint256 id0 = _allocate(keyM, c0, 600_000 ether); // no room rule for asset0
        assertEq(vault.reserved(c0), 600_000 ether);
        mal.configure(MaliciousConsumerHook.Attack.ExactAmounts, id0, 1 ether);
        _expectSwapRevert(
            address(mal), abi.encodeWithSelector(ISharedCommitmentVault.InventoryBoundsNotConfigured.selector)
        );
        _swapRaw(keyM, false, -int256(2 ether), "");

        assertEq(vault.admissibleCapacity(c1), 50_000 ether, "asset1: the room");
        _expectRefused(c1, 50_000 ether + 1, 50_000 ether);
        uint256 id1 = _allocate(keyM, c1, 50_000 ether);
        _fill(id1, c1, 50_000 ether, 52_000 ether);
        _assertEquations();
    }

    /// @notice The curator ceiling and the exposure caps still refuse first when they are tighter than the room.
    function test_ceilingAndExposureCapsStillBind() public {
        vm.startPrank(owner);
        vault.setInventoryBounds(1e18, 1e18, 100_000, 100_000); // room 100,000
        vault.setCuratorCeiling(curator, c0, 30_000 ether);
        vault.setRiskLimit(ISharedCommitmentVault.RiskScope.Hook, address(mal), c0, MAX_FLOW_CAP, 500); // 5% of E
        vm.stopPrank();
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyM, c0, 30_000 ether + 1);
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.CuratorCeilingExceeded.selector, 30_000 ether + 1, 30_000 ether
            )
        );
        auth.activateDirect(r);

        vm.prank(owner);
        vault.setCuratorCeiling(curator, c0, type(uint256).max);
        r = _request(keyM, c0, 50_000 ether + 1);
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.ExposureCapExceeded.selector,
                ISharedCommitmentVault.RiskScope.Hook,
                address(mal),
                c0,
                50_000 ether + 1,
                50_000 ether
            )
        );
        auth.activateDirect(r);
        _allocate(keyM, c0, 50_000 ether);
    }

    /// @notice After a reservation fills, the room it used is gone with the sold inventory: N and Q fall together, so
    ///         N - L - Q does not move, and no new reservation can be admitted on the units just sold.
    function test_fillDoesNotReopenRoom() public {
        vm.prank(owner);
        vault.setInventoryBounds(1e18, 1e18, 50_000, 50_000);
        uint256 id = _allocate(keyM, c0, 50_000 ether);
        assertEq(vault.admissibleCapacity(c0), 0);
        _fill(id, c0, 20_000 ether, 20_000 ether);
        assertEq(vault.admissibleCapacity(c0), 0, "sold room is not admissible again");
        assertEq(vault.reserved(c0), 30_000 ether);
        assertEq(lens.inventoryRoom(vault, c0), 30_000 ether, "the room left equals what is still reserved");
    }

    /// @notice The admission limit the reader reports equals an independent computation, the vault admits exactly that
    ///         amount and refuses one more, and right after admission Q <= N - R - D and Q <= N - L (V-5), over random
    ///         targets, tolerances, buffers, earlier reservations and queued withdrawals, in either asset.
    function testFuzz_limitIsExactAndBothRulesHoldAfterAdmission(
        uint256 tauBps,
        uint256 kappa,
        uint256 buffer,
        uint256 prior,
        uint256 queueFrac,
        bool sellAsset1
    ) public {
        Currency c = sellAsset1 ? c1 : c0;
        uint256 i = sellAsset1 ? 1 : 0;
        // Optional queue: reserve without a floor, queue part of lp0, release (P stays).
        queueFrac = bound(queueFrac, 0, 3);
        if (queueFrac != 0) {
            uint256 big = _allocate(keyA, c, 990_000 ether);
            _redeem(lp0, vault.sharesOf(lp0) * queueFrac / 4, true);
            vm.prank(owner);
            vault.release(big);
        }
        // Target from 0 to 150% of the holding per share (0 = none); tolerance 0 .. 100%.
        tauBps = bound(tauBps, 0, 15_000);
        uint256 tau =
            FullMath.mulDiv(vault.backing(c) - vault.claimableAssets(c), 1e18, vault.totalShares()) * tauBps / 10_000;
        kappa = bound(kappa, 0, 1e6);
        vm.startPrank(owner);
        vault.setInventoryBounds(i == 0 ? tau : 0, i == 1 ? tau : 0, uint24(kappa), uint24(kappa));
        vault.setBufferFloor(c, bound(buffer, 0, 200_000 ether));
        vm.stopPrank();
        // An earlier reservation of part of what is admissible.
        uint256 first = vault.admissibleCapacity(c) * bound(prior, 0, 100) / 100;
        if (first != 0) _allocate(keyA, c, uint128(first));

        uint256 limit = _expectedLimit(c);
        assertEq(vault.admissibleCapacity(c), limit, "reader != independent limit");
        assertEq(lens.admissibleCapacity(vault, c), limit, "lens != independent limit");
        if (limit != 0) _allocate(keyM, c, uint128(limit));
        _expectRefused(c, 1, 0);

        uint256 n = vault.backing(c) - vault.claimableAssets(c);
        uint256 q = vault.reserved(c);
        uint256 p = vault.pendingShares();
        uint256 d = p == 0 ? 0 : FullMath.mulDivRoundingUp(p, n, vault.totalShares());
        if (limit != 0) {
            assertLe(q + vault.bufferFloor(c) + d, n, "V-5: Q <= N - R - D");
            if (tau != 0) assertLe(q + _floor(i), n, "V-5: Q <= N - L");
            assertGe(n - q, vault.bufferFloor(c) + d, "V-9: F >= R + D");
        }
        _assertEquations();
    }

    /// @notice The room is checked with the same L that fills use, so a reservation admitted at the boundary can be
    ///         filled to the last unit and one unit beyond its room would breach the floor.
    function test_admissionAndFillUseTheSameFloor() public {
        vm.prank(owner);
        vault.setInventoryBounds(0.7e18 + 3, 0, 333_333, 0); // an L with rounding: ceil(S * tau * (1 - kappa))
        uint256 room = vault.admissibleCapacity(c0);
        assertEq(room, vault.backing(c0) - VaultRiskBoundary.inventoryFloor(vault.totalShares(), 0.7e18 + 3, 333_333));
        uint256 id = _allocate(keyM, c0, uint128(room));
        _fill(id, c0, room, room);
        assertEq(vault.backing(c0), _floor(0), "N at the floor exactly");
    }
}
