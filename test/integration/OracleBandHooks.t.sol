// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {CuratorAuthorization} from "../../src/CuratorAuthorization.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {IVaultState} from "../../src/interfaces/IVaultState.sol";
import {IMarketRiskAdapter} from "../../src/interfaces/IMarketRiskAdapter.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {PriceRiskAdapter} from "../../src/oracle/PriceRiskAdapter.sol";
import {VaultRiskBoundary} from "../../src/risk/VaultRiskBoundary.sol";
import {BaseCompatibleHook} from "../../src/hooks/BaseCompatibleHook.sol";
import {HookA_DynamicFee} from "../../src/hooks/HookA_DynamicFee.sol";
import {HookB_BoundedImpact} from "../../src/hooks/HookB_BoundedImpact.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {MockAggregator} from "../utils/MockAggregator.sol";
import {ProductionArtifacts} from "../utils/ProductionArtifacts.sol";
import {VaultStateReader} from "../../src/libraries/VaultStateReader.sol";

using VaultStateReader for SharedCommitmentVault;

/// @notice Both production hooks against the corrected reference uncertainty, end to end: the production adapter over
///         mock feeds, the vault, Hook A and Hook B in shared-core mode, the real PoolManager, in the rehearsal's
///         configuration (script/DeploySystem.s.sol: base spread 30 bps, hook edge 2 bps over a 1 bp vault edge,
///         Hook B markup 10 bps and 2% per-trade bound, kappa 1%, uncertainty bound 2%, no stored floors).
/// @dev The matrix: two token-decimal pairs (18/18 at 1:1; 6/18 at 3,000 USD per 18-decimal token) × six reference
///      states (two sources in the push and fresh tiers; one source at, below and above the uncertainty at which the
///      earlier mid-relative definition failed; one source near the vault's bound) × both hooks × both directions.
///      Each cell trades in one direction until something refuses, so the last fill sits at an inventory limit (the
///      hook's cap or the vault's floor). For every attempt:
///        - if the hook quotes, the vault's own floor accepts the quoted input (the hook never quotes inside the
///          vault's floor);
///        - every fill's executed price is outside every live source's bracket, checked exactly;
///        - every refusal is the hook's (spread, cap, impact, dust) or the vault's (inventory floor, uncertainty
///          bound), never `PriceBelowFloor`, and changes nothing.
contract OracleBandHooksTest is VaultTestBase {
    uint256 internal constant Q96 = FixedPoint96.Q96;
    uint24 internal constant EDGE = 100;
    uint24 internal constant MAX_U = 20_000;
    uint24 internal constant KAPPA = 10_000;

    /// @dev One complete system for one pair of token decimals.
    struct Sys {
        SharedCommitmentVault v;
        CuratorAuthorization av;
        address hA;
        address hB;
        PoolKey kA;
        PoolKey kB;
        Currency x0;
        Currency x1;
        uint8 td0;
        uint8 td1;
        uint256 usd0; // USD per whole token of x0, 8 decimals
        uint256 usd1;
        MockAggregator cl0; // 18-decimal legs
        MockAggregator cl1;
        MockAggregator rs0; // 8-decimal legs
        MockAggregator rs1;
    }

    /// @dev One reference state. `rsDev` is the RedStone-like source's push deviation per leg; the fresh tier is
    ///      120 s / 1,500 pips as in the rehearsal.
    struct Case {
        string name;
        uint256 minSources;
        bool clLive;
        uint256 rsAge;
        uint256 rsDev;
    }

    /// @dev An exact bracket: a0 (1e6 +- d0) 10^e / (a1 (1e6 -+ d1)).
    struct Leg {
        uint256 a0;
        uint256 a1;
        uint256 d0;
        uint256 d1;
        int256 e;
    }

    uint256 internal salt = 0x7A0;

    // ------------------------------------------------------------------
    // System
    // ------------------------------------------------------------------

    function _system(uint8 decA, uint8 decB, uint256 usdA, uint256 usdB) internal returns (Sys memory s) {
        MockERC20 ta = new MockERC20("A", "A", decA);
        MockERC20 tb = new MockERC20("B", "B", decB);
        bool aFirst = address(ta) < address(tb);
        (s.x0, s.x1) = aFirst
            ? (Currency.wrap(address(ta)), Currency.wrap(address(tb)))
            : (Currency.wrap(address(tb)), Currency.wrap(address(ta)));
        (s.td0, s.td1, s.usd0, s.usd1) = aFirst ? (decA, decB, usdA, usdB) : (decB, decA, usdB, usdA);
        s.v = new SharedCommitmentVault(manager, owner, s.x0, s.x1);
        s.av = _installAuth(s.v);
        s.hA = address(uint160(++salt << 140) | HOOK_FLAGS);
        deployCodeTo(ProductionArtifacts.HOOK_A, abi.encode(manager, s.v, hookOwner), s.hA);
        s.hB = address(uint160(++salt << 140) | HOOK_FLAGS);
        deployCodeTo(ProductionArtifacts.HOOK_B, abi.encode(manager, s.v, hookOwner), s.hB);
        s.kA = PoolKey(s.x0, s.x1, 3000, 60, IHooks(s.hA));
        s.kB = PoolKey(s.x0, s.x1, 500, 10, IHooks(s.hB));
        manager.initialize(s.kA, SQRT_PRICE_1_1);
        manager.initialize(s.kB, SQRT_PRICE_1_1);

        (s.cl0, s.cl1, s.rs0, s.rs1) =
        (new MockAggregator(18), new MockAggregator(18), new MockAggregator(8), new MockAggregator(8));
        _feeds(s, Case("", 2, true, 600, 5100));

        // 1,000,000 USD of each asset.
        uint256 seed0 = 1_000_000 * 10 ** s.td0 * 1e8 / s.usd0;
        uint256 seed1 = 1_000_000 * 10 ** s.td1 * 1e8 / s.usd1;
        vm.startPrank(owner);
        s.v.setConsumer(s.hA, true);
        s.v.setConsumer(s.hB, true);
        s.v.setCurator(curator, true);
        s.v.setCuratorCeiling(curator, s.x0, type(uint256).max);
        s.v.setCuratorCeiling(curator, s.x1, type(uint256).max);
        address[4] memory scoped = [address(0), s.hA, s.hB, curator];
        for (uint256 i; i < 4; ++i) {
            ISharedCommitmentVault.RiskScope sc = i == 0
                ? ISharedCommitmentVault.RiskScope.Vault
                : i == 3 ? ISharedCommitmentVault.RiskScope.Curator : ISharedCommitmentVault.RiskScope.Hook;
            s.v.setRiskLimit(sc, scoped[i], s.x0, seed0 * 4 / 10, 5000);
            s.v.setRiskLimit(sc, scoped[i], s.x1, seed1 * 4 / 10, 5000);
        }
        s.v.setRiskBounds(EDGE, MAX_U);
        s.v.setBufferFloor(s.x0, seed0 / 10);
        s.v.setBufferFloor(s.x1, seed1 / 10);
        MockERC20(Currency.unwrap(s.x0)).mint(owner, seed0);
        MockERC20(Currency.unwrap(s.x1)).mint(owner, seed1);
        MockERC20(Currency.unwrap(s.x0)).approve(address(s.v), seed0);
        MockERC20(Currency.unwrap(s.x1)).approve(address(s.v), seed1);
        s.v.initialDeposit(seed0, seed1, lp0);
        uint256 tau0 = FullMath.mulDiv(seed0, 1e18, s.v.totalShares());
        uint256 tau1 = FullMath.mulDiv(seed1, 1e18, s.v.totalShares());
        s.v.setInventoryBounds(tau0, tau1, KAPPA, KAPPA);
        s.v.setRiskAdapter(_adapter(s, Case("", 2, true, 600, 5100)));
        vm.stopPrank();

        BaseCompatibleHook.CoreParams memory p = BaseCompatibleHook.CoreParams({
            depthPerShare: uint128(10 * tau1),
            depthMax: uint128(2 ** 95 - 1),
            baseSpreadPips: 3000,
            minEdgePips: 200,
            maxSpreadPips: 40_000,
            maxDeviationPips: 50_000
        });
        vm.startPrank(hookOwner);
        HookA_DynamicFee(s.hA).configurePool(s.kA, uint160(Q96), 0, 5000, 20_000e18, 20_000e18, 3600);
        BaseCompatibleHook(s.hA).configureCore(s.kA, p);
        HookB_BoundedImpact(s.hB).configurePool(s.kB, uint160(Q96), 1_000_000e18, 20_000, 3600);
        BaseCompatibleHook(s.hB).configureCore(s.kB, p);
        HookB_BoundedImpact(s.hB).configureStrategy(s.kB, 1000, 20_000);
        vm.stopPrank();

        MockERC20(Currency.unwrap(s.x0)).mint(trader, seed0 * 10);
        MockERC20(Currency.unwrap(s.x1)).mint(trader, seed1 * 10);
        vm.startPrank(trader);
        MockERC20(Currency.unwrap(s.x0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(s.x1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Both sources' answers at the system's USD prices; Chainlink live 60 s ago or stale, RedStone `rsAge` old.
    function _feeds(Sys memory s, Case memory c) internal {
        uint256 now_ = vm.getBlockTimestamp();
        uint256 clAt = c.clLive ? now_ - 60 : now_ - 88_201;
        s.cl0.set(int256(s.usd0 * 1e10), clAt);
        s.cl1.set(int256(s.usd1 * 1e10), clAt);
        s.rs0.set(int256(s.usd0), now_ - c.rsAge);
        s.rs1.set(int256(s.usd1), now_ - c.rsAge);
    }

    function _adapter(Sys memory s, Case memory c) internal returns (PriceRiskAdapter) {
        return new PriceRiskAdapter(
            PriceRiskAdapter.Source(s.cl0, s.cl1, 3100, 5100, 88_200, 88_200, 0, 0, 0),
            PriceRiskAdapter.Source(s.rs0, s.rs1, c.rsDev, c.rsDev, 12_600, 23_400, 120, 1500, 1500),
            Currency.unwrap(s.x0),
            Currency.unwrap(s.x1),
            s.td0,
            s.td1,
            IAggregatorV3(address(0)),
            0,
            c.minSources
        );
    }

    /// @dev Installs the case's adapter and feed state; returns the live sources' exact brackets.
    function _enter(Sys memory s, Case memory c) internal returns (Leg[2] memory legs, uint256 n) {
        _feeds(s, c);
        PriceRiskAdapter ad = _adapter(s, c);
        vm.prank(owner);
        s.v.setRiskAdapter(ad);
        int256 e = int256(uint256(s.td1)) - int256(uint256(s.td0));
        if (c.clLive) legs[n++] = Leg(s.usd0, s.usd1, 3100, 5100, e);
        if (c.rsAge <= 23_400) {
            uint256 d = c.rsAge <= 120 ? 1500 : c.rsDev;
            legs[n++] = Leg(s.usd0, s.usd1, d, d, e);
        }
        assertEq(ad.currentReference().liveSources, n);
    }

    // ------------------------------------------------------------------
    // Exact band check (as in test/oracle/OracleFailureModes.t.sol)
    // ------------------------------------------------------------------

    function _mul512(uint256 a, uint256 b) internal pure returns (uint256 hi, uint256 lo) {
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            lo := mul(a, b)
            hi := sub(sub(mm, lo), lt(mm, lo))
        }
    }

    function _geq(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (bool) {
        (uint256 h1, uint256 l1) = _mul512(a, b);
        (uint256 h2, uint256 l2) = _mul512(c, d);
        return h1 > h2 || (h1 == h2 && l1 >= l2);
    }

    /// @dev `inAmt` raw input for `outAmt` raw output is at or beyond source `s`'s bracket in the vault's favour.
    function _outside(Leg memory s, bool sellAsset1, uint256 inAmt, uint256 outAmt) internal pure returns (bool) {
        uint256 up = s.e > 0 ? 10 ** uint256(s.e) : 1;
        uint256 down = s.e < 0 ? 10 ** uint256(-s.e) : 1;
        if (!sellAsset1) return _geq(inAmt, s.a1 * (1e6 - s.d1) * down, outAmt, s.a0 * (1e6 + s.d0) * up);
        return _geq(inAmt, s.a0 * (1e6 - s.d0) * up, outAmt, s.a1 * (1e6 + s.d1) * down);
    }

    // ------------------------------------------------------------------
    // One cell: trade in one direction until refused
    // ------------------------------------------------------------------

    function swapExternal(PoolKey memory key, bool zfo, uint256 amountIn, uint256 id) external returns (uint256) {
        BalanceDelta d = _swap(key, zfo, amountIn, id);
        return uint256(int256(zfo ? d.amount1() : d.amount0()));
    }

    function _alloc(Sys memory s, PoolKey memory key, Currency out, uint256 maxOut) internal returns (uint256) {
        ISharedCommitmentVault.AllocationRequest memory r = ISharedCommitmentVault.AllocationRequest({
            consumer: address(key.hooks),
            key: key,
            currencyOut: out,
            maxOut: uint128(maxOut),
            minInPerOutX96: 1,
            expiry: uint64(vm.getBlockTimestamp() + 30 days),
            nonce: nextNonce++,
            deadline: uint64(vm.getBlockTimestamp() + 1 hours)
        });
        vm.prank(curator);
        return s.av.activateDirect(r);
    }

    /// @dev The selector of the innermost reason of a PoolManager-wrapped hook revert.
    function _reason(bytes memory err) internal pure returns (bytes4 sel) {
        if (err.length >= 4 && bytes4(err) == CustomRevert.WrappedError.selector) {
            bytes memory body = new bytes(err.length - 4);
            for (uint256 i; i < body.length; ++i) {
                body[i] = err[i + 4];
            }
            (,, bytes memory reason,) = abi.decode(body, (address, bytes4, bytes, bytes));
            return bytes4(reason);
        }
        return bytes4(err);
    }

    function _quote(PoolKey memory key, bool useA, bool zfo, uint256 amountIn) internal view returns (bool, uint256) {
        if (useA) {
            try HookA_DynamicFee(address(key.hooks)).quote(key, zfo, amountIn) returns (uint256 x) {
                return (true, x);
            } catch {}
        } else {
            try HookB_BoundedImpact(address(key.hooks)).quote(key, zfo, amountIn) returns (uint256 x) {
                return (true, x);
            } catch {}
        }
        return (false, 0);
    }

    /// @return nFills Fills in this cell.
    /// @return last Selector of the refusal that ended it.
    function _cell(Sys memory s, Leg[2] memory legs, uint256 n, bool useA, bool zfo)
        internal
        returns (uint256 nFills, bytes4 last)
    {
        PoolKey memory key = useA ? s.kA : s.kB;
        Currency cin = zfo ? s.x0 : s.x1;
        Currency cout = zfo ? s.x1 : s.x0;
        uint256 id = _alloc(s, key, cout, s.v.backing(cout) / 5);
        uint256 chunk = s.v.backing(cin) / 500;
        uint256[2] memory sizes = [10 ** (zfo ? s.td0 : s.td1) / 1000 + 1, chunk];
        for (uint256 k; k < 40; ++k) {
            uint256 amountIn = sizes[k == 0 ? 0 : 1];
            uint256 q;
            bool quoted;
            (quoted, q) = _quote(key, useA, zfo, amountIn);
            if (quoted) {
                try lens.effectiveFloorX96(IVaultState(address(s.v)), id) returns (uint256 f) {
                    assertGe(amountIn, FullMath.mulDivRoundingUp(q, f, Q96), "hook quoted inside the vault floor");
                } catch {}
            }
            try this.swapExternal(key, zfo, amountIn, id) returns (uint256 out) {
                assertTrue(quoted, "filled without a quote");
                assertEq(out, q, "fill equals quote");
                bool ok = _outside(legs[0], zfo, amountIn, out);
                if (!ok && n == 2) ok = _outside(legs[1], zfo, amountIn, out);
                assertTrue(ok, "fill inside a live source's band");
                ++nFills;
            } catch (bytes memory err) {
                bytes4 r = _reason(err);
                assertTrue(r != ISharedCommitmentVault.PriceBelowFloor.selector, "vault refused a hook quote on price");
                if (k > 0) return (nFills, r); // the tiny first trade may round to nothing; a later refusal ends it
            }
        }
        revert("cell never reached a limit");
    }

    function _cases() internal pure returns (Case[6] memory c) {
        c[0] = Case("two sources, push tier", 2, true, 600, 5100);
        c[1] = Case("two sources, fresh tier", 2, true, 30, 5100);
        c[2] = Case("one source, Chainlink alone", 1, true, 23_401, 5100);
        c[3] = Case("one source, near the old threshold", 1, false, 600, 4970);
        c[4] = Case("one source, above the old threshold", 1, false, 600, 5100);
        c[5] = Case("one source, near the vault bound", 1, false, 600, 9650);
    }

    function _matrix(Sys memory s, string memory label) internal returns (uint256 total) {
        Case[6] memory cs = _cases();
        for (uint256 i; i < cs.length; ++i) {
            (Leg[2] memory legs, uint256 n) = _enter(s, cs[i]);
            uint256 u = s.v.riskAdapter().currentReference().uncertaintyPips;
            uint256[4] memory got;
            for (uint256 j; j < 4; ++j) {
                uint256 snap = vm.snapshotState();
                bytes4 last;
                (got[j], last) = _cell(s, legs, n, j < 2, j % 2 == 0);
                vm.revertToState(snap);
                total += got[j];
                console2.logBytes4(last);
            }
            console2.log(label, cs[i].name);
            console2.log("  u pips; fills A zfo / A oneForZero / B zfo / B oneForZero", u, got[0], got[1]);
            console2.log("                                                         ", got[2], got[3]);
            // Hook A fills in every state; Hook B whenever its 2% bound leaves room for base + u + markup.
            assertGt(got[0] * got[1], 0, "Hook A fills both directions");
            if (3000 + u + 1000 < 18_000) assertGt(got[2] * got[3], 0, "Hook B fills both directions");
        }
    }

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------

    /// @notice 18/18 decimals at 1:1. The matrix above; no hook quote is ever inside the vault's floor, and no fill is
    ///         inside any live source's bracket, in either direction, up to the inventory limits.
    function test_matrix_18x18() public {
        Sys memory s = _system(18, 18, 1e8, 1e8);
        uint256 total = _matrix(s, "18/18");
        assertGt(total, 100);
        console2.log("fills", total);
    }

    /// @notice 6/18 decimals at 3,000 USD per 18-decimal token: the decimal shift is non-zero and the reciprocal
    ///         direction has a raw price far from 1, so normalization and rounding are exercised on both floors.
    function test_matrix_6x18() public {
        Sys memory s = _system(6, 18, 1e8, 3000e8);
        uint256 total = _matrix(s, "6/18");
        assertGt(total, 100);
        console2.log("fills", total);
    }

    /// @notice At the vault's uncertainty bound. With the reading's `u` as the bound, both hooks' fills go through
    ///         (Hook B only if its own 2% bound allows); one pip lower, the guardian's tightening refuses every swap
    ///         on both hooks with `UncertaintyTooHigh` and nothing moves.
    function test_atVaultBound_acceptsThenRefusesOnePipLower() public {
        Sys memory s = _system(18, 18, 1e8, 1e8);
        (Leg[2] memory legs, uint256 n) = _enter(s, Case("", 1, false, 600, 9650));
        uint256 u = s.v.riskAdapter().currentReference().uncertaintyPips;
        assertGt(u, 19_000);
        assertLe(u, MAX_U);
        vm.prank(owner);
        s.v.setRiskBounds(EDGE, uint24(u));
        uint256 snap = vm.snapshotState();
        (uint256 got,) = _cell(s, legs, n, true, true);
        assertGt(got, 0, "Hook A fills at the bound");
        vm.revertToState(snap);

        address guardian = makeAddr("guardian");
        vm.prank(owner);
        s.v.setGuardian(guardian);
        vm.prank(guardian);
        s.v.setRiskBounds(EDGE, uint24(u - 1));
        for (uint256 j; j < 4; ++j) {
            PoolKey memory key = j < 2 ? s.kA : s.kB;
            bool zfo = j % 2 == 0;
            uint256 id = _alloc(s, key, zfo ? s.x1 : s.x0, 1000e18);
            uint256 b0 = s.v.backing(s.x0);
            try this.swapExternal(key, zfo, 100e18, id) returns (uint256) {
                revert("filled above the bound");
            } catch (bytes memory err) {
                bytes4 r = _reason(err);
                // Hook B may refuse first on its own impact bound; Hook A reaches the vault.
                if (j < 2) assertEq(r, VaultRiskBoundary.UncertaintyTooHigh.selector);
            }
            assertEq(s.v.backing(s.x0), b0, "nothing moved");
        }
    }
}
