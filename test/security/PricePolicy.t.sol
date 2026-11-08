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
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {MaliciousConsumerHook} from "../utils/MaliciousConsumerHook.sol";
import {ClaimDonor} from "../utils/ClaimDonor.sol";

/// @notice Phase 1B-1 vault-enforced minimum execution price, through the REAL PoolManager.
///         A registered test hook (`MaliciousConsumerHook`, mode ExactAmounts) lets each test choose the exact
///         input and output claims, so the vault's check is exercised at, above and below its boundary without any
///         hook pricing logic in the way: the vault must not rely on a hook to enforce its floor.
contract PricePolicyTest is VaultTestBase {
    uint160 internal constant SWAP_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
    uint256 internal constant Q96 = FixedPoint96.Q96;
    uint160 internal constant MAX_FLOOR = type(uint160).max;
    uint256 internal constant SELL_POLICY_SLOT = 11; // `forge inspect SharedCommitmentVault storageLayout`

    address internal guardian = makeAddr("guardian");
    address internal lpA = makeAddr("lpA");
    MaliciousConsumerHook internal mal;
    PoolKey internal keyM;

    function setUp() public override {
        super.setUp();
        address m = address(uint160(0xBAD << 140) | SWAP_FLAGS);
        deployCodeTo("MaliciousConsumerHook.sol:MaliciousConsumerHook", abi.encode(manager, vault), m);
        mal = MaliciousConsumerHook(m);
        keyM = PoolKey(c0, c1, 3000, 60, IHooks(m));
        manager.initialize(keyM, SQRT_PRICE_1_1);
        vm.startPrank(owner);
        vault.setConsumer(m, true);
        vault.setGuardian(guardian);
        vault.setCuratorCeiling(curator, c0, type(uint256).max);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _allocM(Currency out, uint128 maxOut, uint160 curatorFloor) internal returns (uint256 id) {
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyM, out, maxOut);
        r.minInPerOutX96 = curatorFloor;
        vm.prank(curator);
        id = vault.allocate(r);
    }

    /// @dev Swap through the registered test hook paying exactly `amountIn` for exactly `amountOut`.
    function _trade(uint256 id, Currency out, uint256 amountIn, uint256 amountOut) internal {
        _tradeExpect(id, out, amountIn, amountOut, "");
    }

    /// @dev As `_trade`, expecting the vault to revert with `reason` (wrapped by the PoolManager). The hook is
    ///      configured BEFORE the expectation is armed, so the expectation applies to the swap itself.
    function _tradeExpect(uint256 id, Currency out, uint256 amountIn, uint256 amountOut, bytes memory reason) internal {
        mal.configure(MaliciousConsumerHook.Attack.ExactAmounts, id, amountOut);
        if (reason.length != 0) _expectSwapRevert(address(mal), reason);
        _swapRaw(keyM, out == c1, -int256(amountIn), "");
    }

    function _belowFloor(uint256 amountIn, uint256 requiredIn) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ISharedCommitmentVault.PriceBelowFloor.selector, amountIn, requiredIn);
    }

    function _required(uint256 amountOut, uint256 floor) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(amountOut, floor, Q96);
    }

    /// @dev Independent reference for P1: a * b as a 512-bit (hi, lo) pair (Remco Bloemen's mulmod trick).
    function _mul512(uint256 a, uint256 b) internal pure returns (uint256 hi, uint256 lo) {
        unchecked {
            uint256 mm = mulmod(a, b, type(uint256).max);
            lo = a * b;
            hi = mm - lo - (mm < lo ? 1 : 0);
        }
    }

    /// @dev Reference: amountIn * 2^96 >= amountOut * floor, exactly, in 512-bit arithmetic.
    function _meetsFloor(uint256 amountIn, uint256 amountOut, uint256 floor) internal pure returns (bool) {
        (uint256 h1, uint256 l1) = _mul512(amountIn, Q96);
        (uint256 h2, uint256 l2) = _mul512(amountOut, floor);
        return h1 > h2 || (h1 == h2 && l1 >= l2);
    }

    /// @dev Owner reconfigures both floors in an order D14 accepts (raise the other side to the max first).
    function _setFloors(uint160 f0, uint160 f1) internal {
        vm.startPrank(owner);
        vault.setSellFloor(c1, MAX_FLOOR);
        vault.setSellFloor(c0, f0);
        vault.setSellFloor(c1, f1);
        vm.stopPrank();
    }

    function _vaultClaims() internal view returns (uint256, uint256) {
        return (_claims(address(vault), c0), _claims(address(vault), c1));
    }

    // ------------------------------------------------------------------
    // Configuration: zero, unset, invalid
    // ------------------------------------------------------------------

    function test_PP_zeroAndInvalidFloorsRejected() public {
        vm.startPrank(owner);
        vm.expectRevert(ISharedCommitmentVault.ZeroPriceFloor.selector);
        vault.setSellFloor(c0, 0);
        Currency stranger = Currency.wrap(address(new MockERC20("X", "X", 18)));
        vm.expectRevert(ISharedCommitmentVault.InvalidCurrency.selector);
        vault.setSellFloor(stranger, uint160(Q96));
        vm.expectRevert(ISharedCommitmentVault.InvalidCurrency.selector);
        vault.setSellHalted(stranger, true);
        vm.stopPrank();
        (uint160 f0,) = vault.sellPolicy(c0);
        assertEq(f0, Q96, "unchanged");

        // A zero (or any sub-vault) curator floor is rejected at allocation.
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyA, c1, 1 ether);
        r.minInPerOutX96 = 0;
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.FloorBelowVaultMinimum.selector, 0, Q96));
        vault.allocate(r);
        r.minInPerOutX96 = uint160(Q96 - 1);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.FloorBelowVaultMinimum.selector, Q96 - 1, Q96));
        vault.allocate(r);
    }

    /// @notice A vault whose floors were never configured accepts no allocation in either direction.
    function test_PP_unconfiguredDirection_isClosed() public {
        SharedCommitmentVault v = new SharedCommitmentVault(manager, owner, c0, c1);
        vm.startPrank(owner);
        v.setCurator(curator, true);
        v.setConsumer(address(hookA), true);
        v.setCuratorCeiling(curator, c1, type(uint256).max);
        v.setCuratorCeiling(curator, c0, type(uint256).max);
        v.setSellFloor(c0, uint160(Q96)); // only one direction opened
        vm.stopPrank();
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyA, c1, 1);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.PriceFloorNotConfigured.selector, c1));
        v.allocate(r);
        // Opening a direction is owner-only: the guardian cannot do it.
        vm.prank(owner);
        v.setGuardian(guardian);
        vm.prank(guardian);
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        v.setSellFloor(c1, uint160(Q96));
    }

    /// @notice Defensive fail-closed branch: floors cannot be reset to zero through any function, but if the storage
    ///         ever held zero for a live allocation's direction, `exchange` must revert rather than skip the check.
    function test_PP_unsetFloorAtExchange_failsClosed() public {
        uint256 id = _allocM(c1, 1000 ether, uint160(Q96));
        vm.store(address(vault), keccak256(abi.encode(Currency.unwrap(c1), SELL_POLICY_SLOT)), bytes32(0));
        (uint160 f1,) = vault.sellPolicy(c1);
        assertEq(f1, 0);
        _tradeExpect(
            id,
            c1,
            2000 ether,
            1000 ether,
            abi.encodeWithSelector(ISharedCommitmentVault.PriceFloorNotConfigured.selector, c1)
        );
    }

    // ------------------------------------------------------------------
    // Exact boundary, measured on claim movements
    // ------------------------------------------------------------------

    /// @notice A floor whose required input needs rounding: F = 1.5 * 2^96 + 1. At ceil(out * F / 2^96) the trade
    ///         executes and the vault's ERC-6909 balances move by exactly (in, out); one raw unit less reverts.
    function test_PP_exactlyAtFloor_passes_oneUnitBelow_reverts() public {
        uint160 f = uint160(Q96 * 3 / 2 + 1);
        uint256 out = 1000 ether + 7;
        uint256 id = _allocM(c1, uint128(out), f);
        uint256 req = _required(out, f);
        assertTrue(_meetsFloor(req, out, f) && !_meetsFloor(req - 1, out, f), "reference agrees on the boundary");

        _tradeExpect(id, c1, req - 1, out, _belowFloor(req - 1, req));

        (uint256 a0, uint256 a1) = _vaultClaims();
        _trade(id, c1, req, out);
        (uint256 b0, uint256 b1) = _vaultClaims();
        assertEq(b0 - a0, req, "measured input delta");
        assertEq(a1 - b1, out, "measured output delta");
        assertTrue(_meetsFloor(b0 - a0, a1 - b1, f), "P1 holds on the measured deltas");
        assertEq(vault.getAllocation(id).consumed, out);
        _assertEquations();
        _assertAccountingConsistent();
    }

    /// @notice Acceptance is EXACTLY the rational inequality amountIn * 2^96 >= amountOut * F_eff (512-bit reference),
    ///         for F_eff = max(vault floor, curator floor), in both directions.
    function testFuzz_PP_acceptanceIsExactRationalInequality(
        uint256 out,
        uint256 curatorFloor,
        int256 delta,
        bool sellOne
    ) public {
        out = bound(out, 1, 100_000 ether);
        curatorFloor = bound(curatorFloor, Q96, Q96 << 20);
        delta = bound(delta, -3, 3);
        Currency cOut = sellOne ? c1 : c0;
        uint256 id = _allocM(cOut, uint128(out), uint160(curatorFloor));
        uint256 feff = vault.effectiveFloorX96(id);
        assertEq(feff, curatorFloor > Q96 ? curatorFloor : Q96);

        uint256 req = _required(out, feff);
        int256 signedIn = int256(req) + delta;
        if (signedIn <= 0) return;
        uint256 amountIn = uint256(signedIn);
        bool expectOk = _meetsFloor(amountIn, out, feff);
        assertEq(expectOk, amountIn >= req, "ceil comparison == exact rational comparison");

        MockERC20(Currency.unwrap(sellOne ? c0 : c1)).mint(trader, amountIn); // the trader can always pay
        (uint256 a0, uint256 a1) = _vaultClaims();
        _tradeExpect(id, cOut, amountIn, out, expectOk ? bytes("") : _belowFloor(amountIn, req));
        (uint256 b0, uint256 b1) = _vaultClaims();
        if (expectOk) {
            (uint256 dIn, uint256 dOut) = sellOne ? (b0 - a0, a1 - b1) : (b1 - a1, a0 - b0);
            assertEq(dIn, amountIn);
            assertEq(dOut, out);
            assertTrue(_meetsFloor(dIn, dOut, feff));
        } else {
            assertEq(b0, a0, "rolled back");
            assertEq(b1, a1, "rolled back");
        }
    }

    // ------------------------------------------------------------------
    // Effective floor: vault floor is live; curator floor is never weakened
    // ------------------------------------------------------------------

    function test_PP_tighteningAppliesToOutstandingAllocations_immediately() public {
        uint256 id = _allocM(c1, 10_000 ether, uint160(Q96));
        uint256 hookAId = _allocate(keyA, c1, 10_000 ether);
        _trade(id, c1, 1000 ether, 1000 ether); // at the 1:1 floor
        _swap(keyA, true, 1000 ether, hookAId); // Hook A: ~0.95% worse than 1:1 for the trader, fine

        // Guardian tightens selling token1 to 1.02 (needs no opposite change: raising is always consistent).
        uint160 tight = uint160(Q96 * 102 / 100);
        vm.prank(guardian);
        vault.setSellFloor(c1, tight);
        assertEq(vault.effectiveFloorX96(id), tight);

        _tradeExpect(id, c1, 1000 ether, 1000 ether, _belowFloor(1000 ether, _required(1000 ether, tight)));
        // Hook A's own pricing is no longer enough: the vault rejects its quote.
        uint256 quoted = hookA.quote(keyA, true, 1000 ether, hookAId);
        _expectSwapRevert(
            address(hookA),
            abi.encodeWithSelector(
                ISharedCommitmentVault.PriceBelowFloor.selector, 1000 ether, _required(quoted, tight)
            )
        );
        _swap(keyA, true, 1000 ether, hookAId);

        // At the new floor the trade executes.
        _trade(id, c1, _required(1000 ether, tight), 1000 ether);
        _assertEquations();
    }

    function test_PP_loosening_neverGoesBelowCuratorFloor() public {
        uint160 curatorFloor = uint160(Q96 * 2);
        uint256 id = _allocM(c1, 10_000 ether, curatorFloor);
        // Owner loosens the token1 floor to 0.5 (consistent: token0 floor raised to 2 first).
        _setFloors(uint160(Q96 * 2), uint160(Q96 / 2));
        assertEq(vault.effectiveFloorX96(id), curatorFloor, "max(vault, curator)");

        uint256 between = _required(1000 ether, Q96); // above the new vault floor, below the curator's
        _tradeExpect(id, c1, between, 1000 ether, _belowFloor(between, _required(1000 ether, curatorFloor)));
        _trade(id, c1, _required(1000 ether, curatorFloor), 1000 ether);
    }

    function test_PP_guardianIsTightenOnly() public {
        vm.startPrank(guardian);
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setSellFloor(c0, uint160(Q96 - 1)); // loosening
        vault.setSellFloor(c0, uint160(Q96)); // equal: no-op, allowed
        vault.setSellFloor(c0, uint160(Q96 + 1)); // tightening
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setSellFloor(c0, uint160(Q96));
        vault.setSellHalted(c0, true);
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setSellHalted(c0, false);
        vm.stopPrank();

        vm.startPrank(attacker);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setSellFloor(c0, MAX_FLOOR); // even tightening needs a role
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setSellHalted(c1, true);
        vm.stopPrank();

        vm.startPrank(owner);
        vault.setSellHalted(c0, false);
        vault.setSellFloor(c0, uint160(Q96));
        vm.stopPrank();
        (uint160 f0, bool h0) = vault.sellPolicy(c0);
        assertEq(f0, Q96);
        assertFalse(h0);
    }

    function test_PP_halt_blocksOneDirection_only() public {
        uint256 id1 = _allocM(c1, 10_000 ether, uint160(Q96));
        uint256 id0 = _allocM(c0, 10_000 ether, uint160(Q96));
        vm.prank(guardian);
        vault.setSellHalted(c1, true);

        bytes memory halted = abi.encodeWithSelector(ISharedCommitmentVault.DirectionHalted.selector, c1);
        _tradeExpect(id1, c1, 2000 ether, 1000 ether, halted);
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyA, c1, 1 ether);
        vm.prank(curator);
        vm.expectRevert(halted);
        vault.allocate(r);
        vm.expectRevert(halted);
        vault.effectiveFloorX96(id1);

        _trade(id0, c0, 1000 ether, 1000 ether); // the opposite direction still trades
        vm.prank(owner);
        vault.setSellHalted(c1, false);
        _trade(id1, c1, 1000 ether, 1000 ether);
    }

    // ------------------------------------------------------------------
    // D14: directional consistency and cyclic trades
    // ------------------------------------------------------------------

    function test_PP_D14_inconsistentFloorsRejected_exactBoundary() public {
        // With token0 floor = 1, token1 cannot go below 1.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ISharedCommitmentVault.InconsistentDirectionalFloors.selector, Q96 - 1, Q96)
        );
        vault.setSellFloor(c1, uint160(Q96 - 1));

        // Non-trivial rounding: token1 floor = 3 * 2^96, so token0 needs >= ceil(2^192 / (3 * 2^96)) = ceil(2^96 / 3).
        vm.startPrank(owner);
        vault.setSellFloor(c1, uint160(3 * Q96));
        uint256 need = Q96 / 3 + 1; // 2^96 is not divisible by 3
        assertEq(need, FullMath.mulDivRoundingUp(Q96, Q96, 3 * Q96));
        vm.expectRevert(
            abi.encodeWithSelector(ISharedCommitmentVault.InconsistentDirectionalFloors.selector, need - 1, need)
        );
        vault.setSellFloor(c0, uint160(need - 1));
        vault.setSellFloor(c0, uint160(need));
        vm.stopPrank();
        (uint160 f0,) = vault.sellPolicy(c0);
        (uint160 f1,) = vault.sellPolicy(c1);
        (uint256 hi, uint256 lo) = _mul512(f0, f1);
        assertTrue(hi > 0 || lo >= Q96 * Q96, "F0 * F1 >= 2^192");
        (hi, lo) = _mul512(need - 1, f1);
        assertTrue(hi == 0 && lo < Q96 * Q96, "need - 1 would have crossed");
    }

    /// @notice Products up to ~2^320 are compared without overflow; the smallest legal floor against the largest is
    ///         2^32 + 1, and 2^32 is rejected.
    function test_PP_D14_extremeFloors_noOverflow() public {
        vm.startPrank(owner);
        vault.setSellFloor(c1, MAX_FLOOR);
        vault.setSellFloor(c0, MAX_FLOOR); // product ~2^320: fine
        vm.expectRevert(
            abi.encodeWithSelector(ISharedCommitmentVault.InconsistentDirectionalFloors.selector, 2 ** 32, 2 ** 32 + 1)
        );
        vault.setSellFloor(c0, 2 ** 32);
        vault.setSellFloor(c0, 2 ** 32 + 1);
        vm.stopPrank();
    }

    /// @notice What D14 prevents: a crossed pair (each side 0.99) would let a trader cycle A -> B -> A at the floors
    ///         for a profit taken from LPs. The vault refuses to configure it.
    function test_PP_D14_crossedPair_wouldBeProfitable_andIsRejected() public {
        uint256 f = Q96 * 99 / 100;
        uint256 x = 1000 ether;
        uint256 b = x * Q96 / f; // B received for x A at the floor (rounded down)
        uint256 back = b * Q96 / f; // A received for b B at the floor (rounded down)
        assertGt(back, x, "a crossed pair would be a money pump");
        vm.startPrank(owner);
        vault.setSellFloor(c1, uint160(Q96 * 2)); // make room to try lowering token0 alone first
        vault.setSellFloor(c0, uint160(f + 1)); // fine against 2
        uint256 need = FullMath.mulDivRoundingUp(Q96, Q96, f + 1);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InconsistentDirectionalFloors.selector, f, need));
        vault.setSellFloor(c1, uint160(f)); // the crossing step
        vm.stopPrank();
    }

    /// @notice With any legal pair of floors (at the D14 boundary, the most permissive case), a round trip at the
    ///         floors through the real PoolManager never returns more than it started with. Both legs execute in
    ///         every run, each EXACTLY at its floor (the trader's best possible prices).
    function testFuzz_PP_D14_roundTripAtFloors_neverProfitable(uint256 f1, uint256 out1) public {
        f1 = bound(f1, 2 ** 32 + 1, MAX_FLOOR);
        uint256 f0 = FullMath.mulDivRoundingUp(Q96, Q96, f1);
        _setFloors(uint160(f0), uint160(f1));

        // Leg 1: the vault sells out1 token1; the trader pays the minimum x = ceil(out1 * f1 / 2^96) token0.
        uint256 maxOut1 = FullMath.mulDiv(vault.MAX_AMOUNT() - vault.backing(c0), Q96, f1);
        out1 = bound(out1, 1, maxOut1 < 500_000 ether ? maxOut1 : 500_000 ether);
        uint256 x = _required(out1, f1);
        token0.mint(trader, x);
        _trade(_allocM(c1, uint128(out1), uint160(f1)), c1, x, out1);

        // Leg 2: the trader sells all out1 back; the vault pays the maximum floor(out1 * 2^96 / f0) token0.
        uint256 back = FullMath.mulDiv(out1, Q96, f0);
        if (back != 0) _trade(_allocM(c0, uint128(back), uint160(f0)), c0, out1, back);
        assertLe(back, x, "round trip at the floors is never profitable");
        _assertEquations();
    }

    // ------------------------------------------------------------------
    // Malicious hook, atomicity, overflow
    // ------------------------------------------------------------------

    function test_PP_maliciousHook_cannotBypassVaultFloor() public {
        uint256 id = _allocM(c1, 10_000 ether, uint160(Q96));
        // 1 wei for 1000 ether.
        mal.configure(MaliciousConsumerHook.Attack.BelowFloor, id, 1000 ether);
        _expectSwapRevert(address(mal), _belowFloor(1, 1000 ether));
        _swapRaw(keyM, true, -1, "");

        // Direct `exchange` OUTSIDE any swap, with claims the hook obtained elsewhere: still bound by floor + quota.
        ClaimDonor donor = new ClaimDonor(manager);
        token0.mint(address(this), 5000 ether);
        token0.approve(address(donor), type(uint256).max);
        donor.donate(c0, 5000 ether, address(mal));
        vm.startPrank(address(mal));
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.PriceBelowFloor.selector, 999 ether, 1000 ether));
        vault.exchange(keyM, true, id, 999 ether, 1000 ether);
        vault.exchange(keyM, true, id, 1000 ether, 1000 ether); // at the floor: allowed and bounded
        vm.stopPrank();
        assertEq(vault.getAllocation(id).consumed, 1000 ether);
    }

    function test_PP_pricingFailure_rollsBackAtomically() public {
        uint256 id = _allocM(c1, 10_000 ether, uint160(Q96 * 3 / 2));
        (uint256 a0, uint256 a1) = _vaultClaims();
        uint256 t0 = token0.balanceOf(trader);
        uint256 t1 = token1.balanceOf(trader);
        uint256 q = vault.reserved(c1);
        _tradeExpect(id, c1, 1000 ether, 1000 ether, _belowFloor(1000 ether, 1500 ether));
        (uint256 b0, uint256 b1) = _vaultClaims();
        assertEq(b0, a0);
        assertEq(b1, a1);
        assertEq(token0.balanceOf(trader), t0);
        assertEq(token1.balanceOf(trader), t1);
        assertEq(vault.reserved(c1), q);
        assertEq(vault.getAllocation(id).consumed, 0);
        assertEq(_claims(address(mal), c0) + _claims(address(mal), c1), 0, "hook holds nothing");
        _assertEquations();
    }

    function test_PP_overflowBoundaries() public {
        vm.prank(owner);
        vault.setSellFloor(c1, MAX_FLOOR);
        uint256 id = _allocM(c1, 1_000_000 ether, MAX_FLOOR);

        // amountOut = 1 at F = 2^160 - 1 requires ceil((2^160 - 1) / 2^96) = 2^64.
        assertEq(_required(1, MAX_FLOOR), 2 ** 64);
        _tradeExpect(id, c1, 2 ** 64 - 1, 1, _belowFloor(2 ** 64 - 1, 2 ** 64));
        _trade(id, c1, 2 ** 64, 1);

        // A full-quota output at the maximum floor needs more input than MAX_AMOUNT: a clean price revert, no panic.
        uint256 out = 1_000_000 ether - 1;
        uint256 maxIn = vault.MAX_AMOUNT();
        token0.mint(trader, maxIn);
        _tradeExpect(id, c1, maxIn, out, _belowFloor(maxIn, _required(out, MAX_FLOOR)));
    }

    // ------------------------------------------------------------------
    // LP lifecycle while trading is halted (differential)
    // ------------------------------------------------------------------

    /// @notice The same LP sequence (deposit, instant redeem, queued redeem, process, cancel, claim, expiry release)
    ///         produces identical results with both directions open, and with both directions halted at extreme
    ///         floors. Price policy never touches LP exits.
    function test_PP_lpLifecycle_identicalWhileHalted() public {
        // A live commitment of ALL admissible token1 that will never trade.
        uint256 lock = _allocM(c1, uint128(vault.admissibleCapacity(c1)), MAX_FLOOR);
        uint256 snap = vm.snapshotState();
        uint256[10] memory open_ = _lpSequence(lock);
        vm.revertToState(snap);

        vm.startPrank(guardian);
        vault.setSellFloor(c0, MAX_FLOOR);
        vault.setSellFloor(c1, MAX_FLOOR);
        vault.setSellHalted(c0, true);
        vault.setSellHalted(c1, true);
        vm.stopPrank();
        uint256[10] memory halted_ = _lpSequence(lock);
        for (uint256 i; i < 10; ++i) {
            assertEq(halted_[i], open_[i], "LP outcome changed by the price policy");
        }
    }

    function _lpSequence(uint256 lock) internal returns (uint256[10] memory r) {
        (r[0], r[1]) = _depositShares(lpA, 100_000 ether); // the only free token1 inventory
        (r[2], r[3], r[4],) = _redeem(lpA, 10_000 ether, false); // instant
        (,,, uint256 req) = _redeem(lp0, 200_000 ether, true); // partly instant, rest queued behind the lock
        (,,, uint256 req2) = _redeem(lp0, 20_000 ether, true); // queued
        assertGt(req, 0);
        assertGt(req2, 0);
        vm.prank(lp0);
        r[5] = vault.cancelRequest(req2);
        vm.warp(vault.getAllocation(lock).expiry);
        vault.release(lock); // permissionless lazy expiry
        r[6] = vault.processQueue(5);
        vm.prank(lp0);
        (r[7], r[8]) = vault.claim(req);
        r[9] = vault.sharesOf(lp0);
        _assertEquations();
    }
}
