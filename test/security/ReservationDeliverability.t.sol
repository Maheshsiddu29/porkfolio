// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultRiskBoundary} from "../../src/risk/VaultRiskBoundary.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {MaliciousConsumerHook} from "../utils/MaliciousConsumerHook.sol";

/// @notice What reserved capacity Q_a does and does not promise, when hooks and LP exits compete for one reserve.
/// @dev Fixture: 1e24 of each asset, 1e24 shares, 1:1 sell floors in static mode. A registered test hook fills at
///      exact amounts at or above the floor. docs/security/G03_LP_ACCOUNTING.md §5 (examples B and G) and §6
///      (counterexample CE-1) use these numbers.
contract ReservationDeliverabilityTest is VaultTestBase {
    uint160 internal constant SWAP_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

    MaliciousConsumerHook internal mal;
    PoolKey internal keyM;

    function setUp() public override {
        super.setUp();
        address m = address(uint160(0xBAD6 << 140) | SWAP_FLAGS);
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

    /// @dev The test hook sells exactly `amountOut` of `out` under allocation `id` for exactly `amountIn`.
    function _fill(uint256 id, Currency out, uint256 amountOut, uint256 amountIn) internal {
        mal.configure(MaliciousConsumerHook.Attack.ExactAmounts, id, amountOut);
        _swapRaw(keyM, out == c1, -int256(amountIn), "");
    }

    /// @dev tau = one raw unit per share (the 1:1 fixture's holding) and kappa = 5% for both assets, so
    ///      L_a = ceil(0.95 * S) and the room above the floor is 5% of N_a.
    function _setFloor() internal {
        vm.prank(owner);
        vault.setInventoryBounds(1e18, 1e18, 50_000, 50_000);
    }

    /// @notice Example B. Two hooks reserve the same asset: the reservations add up in Q_a, the admission rule refuses
    ///         anything beyond N_a, and a fill does not make the sold inventory admissible again.
    /// @dev A fill lowers N_out and Q_out by the same amount, so N - Q - R - D does not move: what a hook bought cannot
    ///      be promised to another hook. Only a release (or cancellation) returns capacity.
    function test_twoHooksOneAsset_noDoubleCounting() public {
        uint256 idA = _allocate(keyA, c1, 600_000 ether);
        uint256 idM = _allocate(keyM, c1, 400_000 ether);
        assertEq(vault.reserved(c1), 1_000_000 ether);
        assertEq(vault.hookReserved(address(hookA), c1), 600_000 ether);
        assertEq(vault.hookReserved(address(mal), c1), 400_000 ether);
        assertEq(vault.admissibleCapacity(c1), 0);
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyA, c1, 1);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientBacking.selector, 1, 0));
        auth.activateDirect(r);

        _fill(idM, c1, 100_000 ether, 100_000 ether);
        assertEq(lens.netAssets(vault, c1), 900_000 ether);
        assertEq(vault.reserved(c1), 900_000 ether);
        assertEq(lens.freeInventory(vault, c1), 0);
        assertEq(vault.admissibleCapacity(c1), 0, "sold inventory is not promised again");
        assertEq(vault.getAllocation(idA).consumed, 0, "the other hook's reservation is untouched");

        // The filling hook cannot go beyond its own remainder.
        mal.configure(MaliciousConsumerHook.Attack.ExactAmounts, idM, 300_000 ether + 1);
        _expectSwapRevert(
            address(mal),
            abi.encodeWithSelector(ISharedCommitmentVault.QuotaExceeded.selector, 300_000 ether + 1, 300_000 ether)
        );
        _swapRaw(keyM, true, -int256(300_000 ether + 1), "");

        vm.prank(owner);
        vault.release(idM);
        assertEq(vault.reserved(c1), 600_000 ether);
        assertEq(vault.admissibleCapacity(c1), 300_000 ether);
        _assertEquations();
    }

    /// @notice Counterexample CE-1. The admission rule does not look at the inventory floor, so a reservation can be
    ///         admitted that can never be filled in full. Here 200,000 is reserved while only 50,000 sits above the
    ///         floor; after 50,000 is sold, the next unit is refused, and the unsellable 150,000 still counts in Q_a
    ///         and is still withheld from LP exits.
    /// @dev Not a solvency defect: Q_a <= N_a holds and LPs are on the safe side. It means Q_a is an upper bound on
    ///      what hooks can buy, not a promise. A fee charged for reserved capacity would charge for these units.
    function test_admissionIgnoresInventoryFloor() public {
        _setFloor();
        assertEq(lens.inventoryRoom(vault, c1), 50_000 ether);
        uint256 id = _allocate(keyM, c1, 200_000 ether);

        _fill(id, c1, 50_000 ether, 50_000 ether);
        assertEq(lens.inventoryRoom(vault, c1), 0);

        mal.configure(MaliciousConsumerHook.Attack.ExactAmounts, id, 1);
        _expectSwapRevert(
            address(mal),
            abi.encodeWithSelector(VaultRiskBoundary.InventoryFloorBreached.selector, 950_000 ether - 1, 950_000 ether)
        );
        _swapRaw(keyM, true, -1, "");

        assertEq(vault.reserved(c1), 150_000 ether, "unsellable capacity still reserved");
        assertEq(lens.freeInventory(vault, c1), 800_000 ether, "and still withheld from exits");
        _assertEquations();
    }

    /// @notice Example G and counterexample CE-2. A reservation of 40,000 fits inside the 50,000 of room. If the hook
    ///         fills first, both the fill and a 50% LP exit succeed. If the LP exits first, the floor falls with S but
    ///         the room falls with it, to 25,000, and the same 40,000 fill is refused; only 25,000 can be sold.
    /// @dev The exit is paid entirely from free inventory and never touches Q_a, but the inventory floor is per share,
    ///      so the absolute room above it shrinks by s * (h_a - l_a) when s shares leave. LP exits can therefore make
    ///      part of an existing reservation unsellable, without any parameter change. The fill, in the other order,
    ///      never reduces what LPs can redeem instantly.
    function test_lpExitShrinksInventoryRoomOfExistingReservation() public {
        _setFloor();
        uint256 id = _allocate(keyM, c1, 40_000 ether);
        uint256 snap = vm.snapshotState();

        // Order 1: the hook fills, then the LP exits.
        uint256 deliverableBefore = lens.deliverableShares(vault);
        _fill(id, c1, 40_000 ether, 40_000 ether);
        assertGe(lens.deliverableShares(vault), deliverableBefore, "a fill never lowers instant exits");
        (uint256 instant,,,) = _redeem(lp0, 500_000 ether, false);
        assertEq(instant, 500_000 ether);
        _assertEquations();
        vm.revertToState(snap);

        // Order 2: the LP exits, then the hook tries the same fill.
        (instant,,,) = _redeem(lp0, 500_000 ether, false);
        assertEq(instant, 500_000 ether);
        assertEq(vault.reserved(c1), 40_000 ether, "the exit did not touch the reservation");
        assertEq(lens.inventoryRoom(vault, c1), 25_000 ether);
        mal.configure(MaliciousConsumerHook.Attack.ExactAmounts, id, 40_000 ether);
        _expectSwapRevert(
            address(mal),
            abi.encodeWithSelector(VaultRiskBoundary.InventoryFloorBreached.selector, 460_000 ether, 475_000 ether)
        );
        _swapRaw(keyM, true, -int256(40_000 ether), "");
        _fill(id, c1, 25_000 ether, 25_000 ether);
        assertEq(vault.reserved(c1), 15_000 ether, "15,000 reserved and unsellable");
        _assertEquations();
    }

    /// @notice Consuming an existing reservation never lowers the number of shares that can exit instantly.
    /// @dev s_max = min_a floor(F_a * S / N_a). For the sold asset F is unchanged and N falls, so F / N rises. For the
    ///      bought asset both rise by amountIn, and (F + i) / (N + i) >= F / N because F <= N. S does not change.
    ///      So swap demand cannot crowd out exits that were already possible. A reservation on the bought asset is
    ///      added so that its ratio is below one and actually moves.
    function testFuzz_exchangeNeverReducesDeliverableShares(
        uint256 reserveOut,
        uint256 fillOut,
        uint256 premiumBps,
        uint256 otherReserve,
        bool sellAsset1
    ) public {
        reserveOut = bound(reserveOut, 1, 900_000 ether);
        fillOut = bound(fillOut, 1, reserveOut);
        premiumBps = bound(premiumBps, 0, 20_000);
        otherReserve = bound(otherReserve, 0, 900_000 ether);
        Currency out = sellAsset1 ? c1 : c0;
        Currency bought = sellAsset1 ? c0 : c1;
        if (otherReserve != 0) _allocate(keyA, bought, uint128(otherReserve));
        uint256 id = _allocate(keyM, out, uint128(reserveOut));

        uint256 before = lens.deliverableShares(vault);
        _fill(id, out, fillOut, fillOut + fillOut * premiumBps / 10_000);
        assertGe(lens.deliverableShares(vault), before);
        _assertEquations();
    }
}
