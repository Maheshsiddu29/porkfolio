// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {VaultRiskBoundary} from "../../src/risk/VaultRiskBoundary.sol";

/// @notice Arithmetic checks behind the V2 reservation guarantee (G05_V2_ARCHITECTURE.md §2.3): with a per-share
///         inventory floor and pro-rata in-kind exits, no rule can keep all three of (i) LP exits limited only by free
///         inventory, (ii) the floor on every fill, and (iii) every admitted unit staying sellable.
/// @dev Uses the vault's own formulas: payouts floor(s * N / S), deliverable shares floor(F * S / N), and the floor
///      L = `VaultRiskBoundary.inventoryFloor`. One asset is followed; the other asset's limit on exits can only make
///      the exit smaller, which does not change the conclusion for the exits these tests allow.
contract CommitmentConflictsTest is Test {
    uint256 internal constant WAD = 1e18;

    function _floor(uint256 s, uint256 tau, uint24 kappa) internal pure returns (uint256) {
        return VaultRiskBoundary.inventoryFloor(s, tau, kappa);
    }

    /// @notice (i) + (ii) break (iii). Start with the whole room above the floor reserved, which room-aware admission
    ///         allows (Q = N - L). Let LPs take the largest exit the free-inventory rule allows. The room left is
    ///         smaller than Q: part of the reservation can no longer be sold, although it was admissible and the exit
    ///         never touched Q. The room shrinks in proportion to the shares that left.
    /// @dev Q - room' = paid + L' - L >= floor(s h) - ceil(s l) - 1 > 0 once s (h - l) >= 3 raw units, where h = N / S
    ///      and l = tau (1 - kappa). The bounds keep s (h - l) far above that.
    function testFuzz_freeInventoryExit_shrinksRoomBelowReserved(uint256 supply, uint256 extra, uint256 tau, uint24 k)
        public
        pure
    {
        supply = bound(supply, 1e9 * WAD, 1e15 * WAD);
        tau = bound(tau, WAD / 1000, 1000 * WAD); // raw units per share, scaled by 1e18
        k = uint24(bound(k, 1000, 500_000)); // 0.1% .. 50% tolerance
        // Holdings at least the target per share, plus some extra.
        uint256 n = FullMath.mulDiv(supply, tau, WAD);
        n += bound(extra, 0, n);
        uint256 l = _floor(supply, tau, k);
        vm.assume(n > l);

        uint256 q = n - l; // whole room reserved: Q + q <= N - L holds with equality
        uint256 f = n - q; // free inventory = L
        uint256 s = FullMath.mulDiv(f, supply, n); // deliverable shares
        uint256 paid = FullMath.mulDiv(s, n, supply);
        assertLe(paid, f, "the exit is paid from free inventory");

        uint256 n2 = n - paid;
        uint256 l2 = _floor(supply - s, tau, k);
        uint256 room2 = n2 > l2 ? n2 - l2 : 0;
        assertLt(room2, q, "part of the admitted reservation is no longer sellable");
        // room' ~ room * (S - s) / S: the room is a per-share quantity, the reservation is not.
        uint256 scaled = FullMath.mulDiv(q, supply - s, supply);
        assertApproxEqAbs(room2, scaled, 3);
    }

    /// @notice The price of (iii): if exits had to keep the room at least Q, a reservation of Q would hold back
    ///         Q / (h - l) shares instead of Q / h. At h = tau and kappa = 5% that is twenty times as many. With the
    ///         whole room reserved no LP could leave at all, while the free-inventory rule lets 95% leave.
    function test_hardExecutableRule_costsOneOverKappa() public pure {
        uint256 supply = 1_000_000 ether;
        uint256 n = 1_000_000 ether;
        uint256 tau = WAD; // one raw unit per share
        uint24 kappa = 50_000; // 5%
        uint256 l = _floor(supply, tau, kappa);
        assertEq(l, 950_000 ether);

        // Half the room reserved.
        uint256 q = 25_000 ether;
        uint256 freeRule = FullMath.mulDiv(n - q, supply, n); // shares that may exit today
        assertEq(freeRule, 975_000 ether, "97.5% of shares can exit under the free-inventory rule");
        // Room-preserving rule: (S - s)(h - l) >= Q  =>  s <= S - Q / (h - l), with h - l = 0.05 per share.
        uint256 hardRule = supply - FullMath.mulDivRoundingUp(q, supply, n - l);
        assertEq(hardRule, 500_000 ether, "only 50% could exit if the reservation had to stay sellable");

        // Whole room reserved.
        q = 50_000 ether;
        assertEq(FullMath.mulDiv(n - q, supply, n), 950_000 ether);
        assertEq(supply - FullMath.mulDivRoundingUp(q, supply, n - l), 0, "no exit at all");
    }

    /// @notice Why a pro-rata cap per fill (each reservation may sell r_j * room / Q) does not make shrunken room
    ///         exclusive: after one reservation sells its share, the ratio room / Q falls for everyone else. Two
    ///         reservations of 50 against a room of 50 are each "entitled" to 25; after the first sells 25 the
    ///         second's entitlement is 50 * 25 / 75 = 16.67, not 25.
    function test_proRataFillCap_isNotStable() public pure {
        uint256 room = 50;
        uint256 q = 100;
        uint256 rj = 50;
        uint256 rk = 50;
        assertEq(rj * room / q, 25);
        assertEq(rk * room / q, 25);
        room -= 25;
        q -= 25;
        assertEq(rk * room / q, 16, "the second reservation's share fell from 25 to 16");
    }

    /// @notice Counterexample CE-1 under room-aware admission. With 50,000 above the floor, today's rule admits
    ///         200,000 (the free-inventory limit); the V2 rule admits at most 50,000, all of it sellable at admission.
    function test_roomAwareAdmission_refusesCE1() public pure {
        uint256 supply = 1_000_000 ether;
        uint256 n = 1_000_000 ether;
        uint256 l = _floor(supply, WAD, 50_000);
        uint256 reserved = 0;
        uint256 bufferFloor = 0;
        uint256 pendingDemand = 0;
        uint256 todayLimit = n - reserved - bufferFloor - pendingDemand;
        uint256 v2Limit = todayLimit < n - l - reserved ? todayLimit : n - l - reserved;
        assertGe(todayLimit, 200_000 ether, "today: 200,000 is admissible");
        assertEq(v2Limit, 50_000 ether, "V2: only the room above the floor");
    }
}
