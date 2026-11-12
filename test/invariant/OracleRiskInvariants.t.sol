// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {VaultLens} from "../../src/VaultLens.sol";
import {CuratorAuthorization} from "../../src/CuratorAuthorization.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultRiskBoundary} from "../../src/risk/VaultRiskBoundary.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {MaliciousConsumerHook} from "../utils/MaliciousConsumerHook.sol";
import {MockRiskAdapter} from "../utils/MockRiskAdapter.sol";

/// @notice Drives the vault with an adversary that owns the market-risk adapter. Every handler call records the
///         per-share holdings before and after and flags a violation of T1 (INVENTORY_FLOOR_GUARANTEE.md):
///         after every call, for each asset, N/S >= min(N/S before, floor per share).
/// @dev Ghosts: `violations` (count of T1 breaches, must stay 0), `drained` (raw units taken by fills paid at a price
///      the adversary chose, to show the adversary is active), and call counters. Every external interaction is in
///      try/catch, so the campaign can run with fail_on_revert = true: a revert means the handler itself is wrong.
contract OracleRiskHandler is Test {
    uint256 internal constant Q96 = FixedPoint96.Q96;

    SharedCommitmentVault internal immutable vault;
    VaultLens internal immutable lens;
    CuratorAuthorization internal immutable auth;
    MockRiskAdapter internal immutable adapter;
    MaliciousConsumerHook internal immutable mal;
    PoolSwapTest internal immutable router;
    MockERC20 internal immutable t0;
    MockERC20 internal immutable t1;
    Currency internal immutable c0;
    Currency internal immutable c1;
    PoolKey internal keyM;
    address internal immutable curator;
    address internal immutable guardian;

    address[3] internal lps;
    uint256[] internal requests;
    uint256 internal nonce = 1_000_000;

    uint256 public violations;
    uint256 public drained;
    uint256 public fills;
    uint256 public refusedAtFloor;

    constructor(
        SharedCommitmentVault vault_,
        VaultLens lens_,
        CuratorAuthorization auth_,
        MockRiskAdapter adapter_,
        MaliciousConsumerHook mal_,
        PoolSwapTest router_,
        PoolKey memory keyM_,
        address curator_,
        address guardian_
    ) {
        (vault, lens, auth, adapter, mal, router, keyM) = (vault_, lens_, auth_, adapter_, mal_, router_, keyM_);
        (curator, guardian) = (curator_, guardian_);
        c0 = vault_.asset0();
        c1 = vault_.asset1();
        t0 = MockERC20(Currency.unwrap(c0));
        t1 = MockERC20(Currency.unwrap(c1));
        lps = [makeAddr("ilp0"), makeAddr("ilp1"), makeAddr("ilp2")];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(lps[i]);
            t0.approve(address(vault_), type(uint256).max);
            t1.approve(address(vault_), type(uint256).max);
            vm.stopPrank();
        }
        t0.approve(address(router_), type(uint256).max);
        t1.approve(address(router_), type(uint256).max);
    }

    // ---------------------------------------------------------------- T1 check around every call

    modifier checked() {
        uint256 s0 = vault.totalShares();
        uint256 n0 = _net(c0);
        uint256 n1 = _net(c1);
        _;
        uint256 s1 = vault.totalShares();
        _checkAsset(0, n0, s0, _net(c0), s1);
        _checkAsset(1, n1, s0, _net(c1), s1);
    }

    function _checkAsset(uint256 i, uint256 nBefore, uint256 sBefore, uint256 nAfter, uint256 sAfter) internal {
        // h_after >= h_before  <=>  nAfter * sBefore >= nBefore * sAfter (both products < 2^254)
        if (nAfter * sBefore >= nBefore * sAfter) return;
        uint256 target = vault.inventoryTargetPerShare(i);
        uint256 floor_ = VaultRiskBoundary.inventoryFloor(sAfter, target, vault.inventoryTolerancePips(i));
        // h_after >= floor per share  <=>  nAfter >= ceil(S * l) = floor_
        if (target != 0 && nAfter >= floor_) return;
        ++violations;
    }

    function _net(Currency c) internal view returns (uint256) {
        return vault.backing(c) - vault.claimableAssets(c);
    }

    // ---------------------------------------------------------------- adversary

    /// @notice The adversary sets any reference it likes (any price over 2^-96 .. 2^64, any uncertainty up to the bound).
    function setReference(uint256 priceSeed, uint256 uSeed) external checked {
        uint256 price = bound(priceSeed, 1, Q96 << 64);
        adapter.set(price, bound(uSeed, 0, vault.maxUncertaintyPips()), type(uint256).max);
    }

    /// @notice Buy `out` of one asset paying exactly what the current (adversarial) floor asks, sometimes asking for more
    ///         than the inventory floor allows.
    function drain(bool sellAsset1, uint256 outSeed, bool overshoot, bool extremePrice) external checked {
        Currency c = sellAsset1 ? c1 : c0;
        // The price that makes this direction cheapest: asset0 "worthless" (P = 1) or asset1 "worthless" (P = 2^160).
        if (extremePrice) adapter.set(sellAsset1 ? 2 ** 160 : 1, 0, type(uint256).max);
        uint256 room = lens.inventoryRoom(vault, c);
        uint256 out = bound(outSeed, 1, room + 2);
        if (overshoot) out = room + 1;
        if (out == 0 || out > type(uint120).max) return;
        uint256 id = _allocate(c, out);
        if (id == 0) return;
        uint256 floor_;
        try lens.effectiveFloorX96(vault, id) returns (uint256 f) {
            floor_ = f;
        } catch {
            _cancelAllocation(id);
            return;
        }
        uint256 amountIn = FullMath.mulDivRoundingUp(out, floor_, Q96);
        if (amountIn == 0 || amountIn > type(uint120).max) return _cancelAllocation(id);
        bool ok = _swap(id, c, amountIn, out);
        if (!ok) _cancelAllocation(id);
        if (ok) {
            ++fills;
            drained += out;
        } else if (out > room) {
            ++refusedAtFloor;
        }
    }

    /// @notice An honest trader pays 1% over the true price 1:1, refilling the asset the adversary drained.
    function honestFill(bool sellAsset1, uint256 outSeed) external checked {
        adapter.set(Q96, 0, type(uint256).max);
        Currency c = sellAsset1 ? c1 : c0;
        uint256 room = lens.inventoryRoom(vault, c);
        if (room == 0) return;
        uint256 out = bound(outSeed, 1, room);
        uint256 id = _allocate(c, out);
        if (id == 0) return;
        if (!_swap(id, c, out + out / 100 + 1, out)) _cancelAllocation(id);
    }

    /// @dev Unused capacity would otherwise stay reserved until expiry and block later allocations (admission rule).
    function _cancelAllocation(uint256 id) internal {
        vm.prank(curator);
        try vault.cancelAllocation(id) {} catch {}
    }

    function _allocate(Currency c, uint256 out) internal returns (uint256 id) {
        ISharedCommitmentVault.AllocationRequest memory r = ISharedCommitmentVault.AllocationRequest({
            consumer: address(mal),
            key: keyM,
            currencyOut: c,
            maxOut: uint128(out),
            minInPerOutX96: 1,
            expiry: uint64(block.timestamp + 2 hours),
            nonce: nonce++,
            deadline: uint64(block.timestamp + 1 hours)
        });
        vm.prank(curator);
        try auth.activateDirect(r) returns (uint256 i) {
            id = i;
        } catch {}
    }

    function _swap(uint256 id, Currency c, uint256 amountIn, uint256 out) internal returns (bool ok) {
        t0.mint(address(this), amountIn);
        t1.mint(address(this), amountIn);
        mal.configure(MaliciousConsumerHook.Attack.ExactAmounts, id, out);
        bool zeroForOne = c == c1;
        try router.swap(
            keyM,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            ok = true;
        } catch {}
    }

    // ---------------------------------------------------------------- LPs

    function deposit(uint256 who, uint256 sharesSeed) external checked {
        address lp = lps[who % 3];
        uint256 shares = bound(sharesSeed, 1, vault.totalShares());
        (uint256 a0, uint256 a1) = lens.previewDeposit(vault, shares);
        t0.mint(lp, a0);
        t1.mint(lp, a1);
        vm.prank(lp);
        try vault.deposit(shares, a0, a1, lp) {} catch {}
    }

    function redeem(uint256 who, uint256 fracSeed, bool queue) external checked {
        address lp = lps[who % 3];
        uint256 bal = vault.sharesOf(lp);
        if (bal == 0) return;
        uint256 shares = bound(fracSeed, 1, bal);
        vm.prank(lp);
        try vault.redeem(shares, 0, 0, lp, queue) returns (uint256, uint256, uint256, uint256 rid) {
            if (rid != 0) requests.push(rid);
        } catch {}
    }

    function processQueue(uint256 steps) external checked {
        try vault.processQueue(bound(steps, 1, 8)) {} catch {}
    }

    function claim(uint256 idx) external checked {
        if (requests.length == 0) return;
        uint256 rid = requests[idx % requests.length];
        address lp = vault.getRequest(rid).lp;
        vm.prank(lp);
        try vault.claim(rid) {} catch {}
    }

    function cancel(uint256 idx) external checked {
        if (requests.length == 0) return;
        uint256 rid = requests[idx % requests.length];
        address lp = vault.getRequest(rid).lp;
        vm.prank(lp);
        try vault.cancelRequest(rid) {} catch {}
    }

    /// @notice Guardian re-centres a floor on the current holding (raises a target) or lowers a tolerance; both only
    ///         tighten, so T1 must keep holding across them.
    function guardianTighten(bool recentre, uint256 kappaSeed) external checked {
        uint256 s = vault.totalShares();
        uint256 a0 = vault.inventoryTargetPerShare(0);
        uint256 a1 = vault.inventoryTargetPerShare(1);
        uint24 k0 = vault.inventoryTolerancePips(0);
        uint24 k1 = vault.inventoryTolerancePips(1);
        if (recentre) {
            uint256 h0 = FullMath.mulDiv(_net(c0), 1e18, s);
            uint256 h1 = FullMath.mulDiv(_net(c1), 1e18, s);
            if (h0 > a0) a0 = h0;
            if (h1 > a1) a1 = h1;
        } else {
            k0 = uint24(bound(kappaSeed, 1000, k0));
            k1 = uint24(bound(kappaSeed, 1000, k1));
        }
        vm.prank(guardian);
        try vault.setInventoryBounds(a0, a1, k0, k1) {} catch {}
    }

    function warp(uint256 secondsSeed) external checked {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 2 days));
    }
}

contract OracleRiskInvariantsTest is VaultTestBase {
    uint160 internal constant SWAP_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

    OracleRiskHandler internal handler;
    address internal guardian = makeAddr("guardian");

    function setUp() public override {
        super.setUp();
        address m = address(uint160(0xBAD << 140) | SWAP_FLAGS);
        deployCodeTo("MaliciousConsumerHook.sol:MaliciousConsumerHook", abi.encode(manager, vault), m);
        PoolKey memory keyM = PoolKey(c0, c1, 3000, 60, IHooks(m));
        manager.initialize(keyM, SQRT_PRICE_1_1);
        MockRiskAdapter adapter = new MockRiskAdapter(address(token0), address(token1), 18, 18, keccak256("inv"));
        adapter.set(FixedPoint96.Q96, 1000, type(uint256).max);
        uint256 tau = FullMath.mulDiv(vault.backing(c0), 1e18, vault.totalShares());

        vm.startPrank(owner);
        vault.setConsumer(m, true);
        _openLimits(ISharedCommitmentVault.RiskScope.Hook, m);
        vault.setGuardian(guardian);
        vault.setCuratorCeiling(curator, c0, type(uint256).max);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        vault.setRiskBounds(100, 5000);
        vault.setInventoryBounds(tau, tau, 50_000, 50_000);
        vault.setRiskAdapter(adapter);
        vault.setSellFloor(c0, 0);
        vault.setSellFloor(c1, 0);
        vm.stopPrank();

        handler = new OracleRiskHandler(
            vault, lens, auth, adapter, MaliciousConsumerHook(m), swapRouter, keyM, curator, guardian
        );
        targetContract(address(handler));
    }

    /// @notice T1: no call, by anyone, under any reference, lowers a per-share holding below min(previous, floor).
    function invariant_perShareHoldingAboveFloorOrPrevious() public view {
        assertEq(handler.violations(), 0);
    }

    /// @notice The adversary's fills never break the vault's accounting equations (claims, backing, queue, W).
    function invariant_accountingConsistent() public view {
        _assertAccountingConsistent();
    }

    /// @notice Directly, after every sequence: N_a >= L_a or the asset was never sold below it (the per-step check is
    ///         the precise statement; this one is its consequence when the vault starts at its targets).
    function invariant_holdingsAtOrAboveInventoryFloor() public view {
        for (uint256 i; i < 2; ++i) {
            Currency c = i == 0 ? c0 : c1;
            uint256 floor_ = VaultRiskBoundary.inventoryFloor(
                vault.totalShares(), vault.inventoryTargetPerShare(i), vault.inventoryTolerancePips(i)
            );
            uint256 n = vault.backing(c) - vault.claimableAssets(c);
            // A guardian re-centre may lift the floor above the current holding; then the asset can only rise.
            if (n < floor_) assertEq(lens.inventoryRoom(vault, c), 0);
        }
    }

    /// @notice Evidence the adversary was active in this run (logged, not asserted: a short run may not reach a fill).
    function afterInvariant() external view {
        console2.log("COV fills", handler.fills());
        console2.log("COV refusedAtFloor", handler.refusedAtFloor());
        console2.log("fills", handler.fills());
        console2.log("drained raw units", handler.drained());
        console2.log("refused at the inventory floor", handler.refusedAtFloor());
    }
}

/// @notice Guards against a vacuous campaign: the handler's adversary must actually land fills and be refused at the
///         floor, otherwise the invariants above would pass without testing anything.
contract OracleRiskHandlerLivenessTest is OracleRiskInvariantsTest {
    function test_handler_drainsAndIsRefusedAtFloor() public {
        handler.drain(false, 1000 ether, false, true);
        assertEq(handler.fills(), 1, "a drain fills");
        handler.drain(false, 0, true, true); // ask for the remaining room + 1
        assertEq(handler.refusedAtFloor(), 1, "overshoot refused");
        handler.drain(true, type(uint256).max, false, true); // bounded to room + 2: may fill up to the room only
        assertEq(handler.violations(), 0);
    }
}
