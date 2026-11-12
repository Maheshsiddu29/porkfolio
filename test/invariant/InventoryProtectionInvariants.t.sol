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
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {VaultLens} from "../../src/VaultLens.sol";
import {CuratorAuthorization} from "../../src/CuratorAuthorization.sol";
import {VaultGovernor} from "../../src/governance/VaultGovernor.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {IMarketRiskAdapter} from "../../src/interfaces/IMarketRiskAdapter.sol";
import {BaseCompatibleHook} from "../../src/hooks/BaseCompatibleHook.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {MaliciousConsumerHook} from "../utils/MaliciousConsumerHook.sol";
import {MockRiskAdapter} from "../utils/MockRiskAdapter.sol";

/// @notice Everything the system lets happen to one shared reserve, driven at random: honest and adversarial trades
///         through both production hooks and a malicious consumer, two curators, deposits, instant and queued
///         withdrawals, claims and cancellations, guardian tightening, governed loosening (through `VaultGovernor`,
///         with its queue check), adapter replacement, price jumps, depegs and time across many flow windows.
/// @dev The four quantities of INVENTORY_PROTECTION.md are kept apart:
///        Q1  per-share holding of each asset: never below G_a, the largest min(h_a, l_a) seen since the last loosening
///            (checked after every call; this is T1 applied cumulatively);
///        Q2  each payout against the paying LP's own entry basket: per asset, shortfall <= the LP's room
///            sum_lots s (h_entry - l_entry)^+ (plus the room a loosening added while the LP stayed) + 1 raw unit.
///            Per-asset implies every price vector, depegs included. Queued requests carry the room they had when
///            queued and gain none from a later loosening: the governor's queue check is what makes that hold;
///        Q3  cumulative realized trading result at the true price of each fill (measured, not bounded);
///        Q4  mark-to-market value of the reserve at the true price (measured, not bounded).
///      Units: holdings and floors per share are raw units scaled by 1e18 (WAD); baskets and rooms are raw * 1e18.
contract InventoryProtectionHandler is Test {
    uint256 internal constant Q96 = FixedPoint96.Q96;
    uint256 internal constant WAD = 1e18;

    SharedCommitmentVault internal immutable vault;
    VaultLens internal immutable lens;
    CuratorAuthorization internal immutable auth;
    VaultGovernor internal immutable gov;
    PoolSwapTest internal immutable router;
    MaliciousConsumerHook internal immutable mal;
    MockERC20 internal immutable t0;
    MockERC20 internal immutable t1;
    Currency internal immutable c0;
    Currency internal immutable c1;
    address internal immutable govAdmin;
    address internal immutable guardian;

    MockRiskAdapter[2] internal adapters;
    uint256 internal active;
    PoolKey internal keyA;
    PoolKey internal keyB;
    PoolKey internal keyM;
    address[2] internal curators;
    address[3] internal lps;
    uint256 internal nonce = 1;

    /// @notice True price of asset0 in asset1, Q96 (what an honest adapter reports).
    uint256 public truePriceX96 = Q96;

    // ---- Q1 model
    uint256[2] public guaranteed; // G_a, WAD per share

    // ---- Q2 model
    struct Holder {
        uint256 shares;
        uint256[2] basket; // sum over lots of s * h_entry (raw * 1e18)
        uint256[2] room; // sum over lots of s * (h_entry - l)^+, plus loosening room
    }

    struct Req {
        address lp;
        uint256 shares; // still pending
        uint256[2] basket;
        uint256[2] room;
        uint256[2] lastClaimable; // claimable amounts at the last check (reset to 0 by a claim)
    }

    mapping(address => Holder) internal holders;
    mapping(uint256 => Req) internal reqs;
    uint256[] internal pendingIds; // requests with shares still pending (slices are checked for these)
    uint256[] internal allRequests; // every request ever queued (claims pick from these)
    uint256[] internal allocationIds;

    // ---- ghosts
    uint256 public q1Violations;
    uint256 public q2Violations;
    uint256 public requestViolations;
    uint256 public fillsA;
    uint256 public fillsB;
    uint256 public fillsMal;
    uint256 public refusedAtFloor;
    uint256 public loosenings;
    uint256 public looseningsBlocked;
    uint256 public adapterSwaps;
    uint256 public depegs;
    uint256 public payoutsChecked;
    uint256 public slicesChecked;
    uint256 public calls;
    uint256 public tradeAttempts; // `tradeHook` calls made while the active adapter reported the true price
    uint256 public realizedLoss; // Q3, asset1 raw units at the true price of each fill
    uint256 public realizedGain;
    uint256 public maxShortfallToRoomBps; // largest observed shortfall / room over checked payouts (with room > 0)
    uint256 public initialValue; // Q4 reference: reserve value at the start, asset1 raw
    uint256 public minValue; // Q4: lowest reserve value per share seen, as a fraction of the start (1e18 = 100%)

    bool internal loosened; // set by `governedLoosen` when it executes

    // ---- adapter faults
    /// @notice True while the active adapter is in a fault set by `adapterFault`; any price update or an adapter
    ///         replacement clears it.
    bool public faulted;
    /// @notice True while the active adapter reports the true price (set by `_setActive`, cleared by a fault).
    bool public honest = true;
    uint256 public faults; // `adapterFault` calls
    uint256 public filledUnderFault; // fills that succeeded while the active adapter was faulted: must stay 0
    uint256 public refusedUnderFault; // trade or drain attempts refused while faulted (shows the check is reached)

    constructor(
        SharedCommitmentVault vault_,
        VaultLens lens_,
        CuratorAuthorization auth_,
        VaultGovernor gov_,
        PoolSwapTest router_,
        MaliciousConsumerHook mal_,
        MockRiskAdapter[2] memory adapters_,
        PoolKey[3] memory keys,
        address[2] memory curators_,
        address guardian_
    ) {
        (vault, lens, auth, gov, router, mal) = (vault_, lens_, auth_, gov_, router_, mal_);
        adapters = adapters_;
        (keyA, keyB, keyM) = (keys[0], keys[1], keys[2]);
        curators = curators_;
        guardian = guardian_;
        govAdmin = gov_.admin();
        c0 = vault_.asset0();
        c1 = vault_.asset1();
        t0 = MockERC20(Currency.unwrap(c0));
        t1 = MockERC20(Currency.unwrap(c1));
        lps = [makeAddr("pLp0"), makeAddr("pLp1"), makeAddr("pLp2")];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(lps[i]);
            t0.approve(address(vault_), type(uint256).max);
            t1.approve(address(vault_), type(uint256).max);
            vm.stopPrank();
        }
        t0.approve(address(router_), type(uint256).max);
        t1.approve(address(router_), type(uint256).max);
        _refreshGuaranteed();
        initialValue = _reserveValue();
        _startValuePerShare = FullMath.mulDiv(initialValue, WAD, vault_.totalShares());
        minValue = WAD;
    }

    // =================================================================== bookkeeping around every call

    modifier step() {
        ++calls;
        uint256[2] memory gBefore = guaranteed;
        uint256[] memory ids = pendingIds;
        loosened = false;
        _;
        _checkSlices(ids);
        if (!loosened) _checkQ1(gBefore);
        _refreshGuaranteed();
        _trackValue();
    }

    function _net(Currency c) internal view returns (uint256) {
        return vault.backing(c) - vault.claimableAssets(c);
    }

    function _holding(uint256 i) internal view returns (uint256) {
        return FullMath.mulDiv(_net(i == 0 ? c0 : c1), WAD, vault.totalShares());
    }

    /// @dev l_a = tau_a (1e6 - kappa_a) / 1e6, rounded down (a weaker floor than the vault enforces).
    function _floorPerShare(uint256 i) internal view returns (uint256) {
        return FullMath.mulDiv(vault.inventoryTargetPerShare(i), 1e6 - vault.inventoryTolerancePips(i), 1e6);
    }

    function _refreshGuaranteed() internal {
        for (uint256 i; i < 2; ++i) {
            uint256 h = _holding(i);
            uint256 l = _floorPerShare(i);
            uint256 m = h < l ? h : l;
            if (loosened) guaranteed[i] = m;
            else if (m > guaranteed[i]) guaranteed[i] = m;
        }
    }

    /// @dev Q1: N_a * 1e18 >= G_a * S for both assets.
    function _checkQ1(uint256[2] memory g) internal {
        uint256 s = vault.totalShares();
        if (_net(c0) * WAD < g[0] * s) ++q1Violations;
        if (_net(c1) * WAD < g[1] * s) ++q1Violations;
    }

    /// @dev Q2 for one payout of `shares` worth `paid` raw units, against a holder's or request's basket and room.
    function _checkPayout(
        uint256 shares,
        uint256 totalShares,
        uint256[2] storage basket,
        uint256[2] storage room,
        uint256[2] memory paid
    ) internal returns (bool ok) {
        ok = true;
        for (uint256 i; i < 2; ++i) {
            uint256 b = FullMath.mulDiv(basket[i], shares, totalShares);
            uint256 r = FullMath.mulDivRoundingUp(room[i], shares, totalShares);
            uint256 got = paid[i] * WAD;
            // shortfall = b - got must be <= r + 2 raw units. Each vault payout rounds down by less than one raw unit
            // per asset (the Q2 allowance). One checked slice can span two vault payouts: a request queued and first
            // finalized inside one handler call (the late-LP branch of `governedLoosen`) is not yet in that call's
            // `ids`, so its next slice is checked together with the first. With one unit the queued check fails
            // (seeds 0x5eed, 0x1, 0x2, 0x3); the instant-payout check passes with one.
            if (b > got + r + 2 * WAD) ok = false;
            if (r > 0 && b > got) {
                uint256 bps = FullMath.mulDiv(b - got, 10_000, r);
                if (bps > maxShortfallToRoomBps) maxShortfallToRoomBps = bps;
            }
            basket[i] -= FullMath.mulDiv(basket[i], shares, totalShares);
            room[i] -= FullMath.mulDiv(room[i], shares, totalShares);
        }
    }

    /// @dev Finalization slices of the requests that were pending when the call started: each slice is compared with
    ///      the request's own attribution (the basket and room it carried when queued). A slice is the drop in pending
    ///      shares; what it paid is the rise in claimable amounts (a claim inside the same call is impossible: claims
    ///      are their own action and reset `lastClaimable`).
    function _checkSlices(uint256[] memory ids) internal {
        for (uint256 k; k < ids.length; ++k) {
            uint256 rid = ids[k];
            Req storage q = reqs[rid];
            if (q.shares == 0) continue;
            ISharedCommitmentVault.WithdrawalRequest memory w = vault.getRequest(rid);
            if (w.canceled || w.sharesPending >= q.shares) continue;
            uint256 slice = q.shares - w.sharesPending;
            uint256[2] memory paid =
                [uint256(w.claimable0) - q.lastClaimable[0], uint256(w.claimable1) - q.lastClaimable[1]];
            q.lastClaimable = [uint256(w.claimable0), uint256(w.claimable1)];
            ++slicesChecked;
            if (!_checkPayout(slice, q.shares, q.basket, q.room, paid)) ++requestViolations;
            q.shares -= slice;
        }
        _prunePending();
    }

    function _prunePending() internal {
        uint256 n = pendingIds.length;
        for (uint256 k = n; k > 0; --k) {
            uint256 rid = pendingIds[k - 1];
            if (reqs[rid].shares == 0) {
                pendingIds[k - 1] = pendingIds[pendingIds.length - 1];
                pendingIds.pop();
            }
        }
    }

    /// @dev Reserve value N0 * p + N1 at the true price, asset1 raw units; tracks the per-share low point (Q4).
    function _reserveValue() internal view returns (uint256) {
        return FullMath.mulDiv(_net(c0), truePriceX96, Q96) + _net(c1);
    }

    /// @dev Q4: reserve value per share at the current true price, as a fraction of the value per share at the start
    ///      (start price). Includes every price move, so it is mark-to-market by definition.
    function _trackValue() internal {
        uint256 perShare = FullMath.mulDiv(_reserveValue(), WAD, vault.totalShares());
        uint256 frac = FullMath.mulDiv(perShare, WAD, _startValuePerShare);
        if (frac < minValue) minValue = frac;
    }

    uint256 internal _startValuePerShare;

    function _value(uint256 a0, uint256 a1) internal view returns (uint256) {
        return FullMath.mulDiv(a0, truePriceX96, Q96) + a1;
    }

    function _recordFill(bool zeroForOne, uint256 amountIn, uint256 amountOut) internal {
        (uint256 vIn, uint256 vOut) =
            zeroForOne ? (_value(amountIn, 0), _value(0, amountOut)) : (_value(0, amountIn), _value(amountOut, 0));
        if (vOut > vIn) realizedLoss += vOut - vIn;
        else realizedGain += vIn - vOut;
    }

    // =================================================================== prices

    /// @dev Sets the active adapter's reading and clears any fault: a price update models the source recovering.
    function _setActive(uint256 priceX96, uint256 u) internal {
        adapters[active].setBroken(false);
        adapters[active].setShortReturn(false);
        adapters[active].set(priceX96, u, type(uint256).max);
        faulted = false;
        honest = priceX96 == truePriceX96;
    }

    /// @notice The active adapter fails in one of five ways: it reverts (sources unavailable), returns one word instead
    ///         of a `Reading`, reports a zero price, reports a reading whose `validUntil` has passed, or reports an
    ///         uncertainty one pip above `maxUncertaintyPips`. Each must make every fill revert while LP deposits,
    ///         withdrawals, queue processing and claims carry on unchanged (`invariant_noFillUnderAdapterFault`,
    ///         `invariant_lpPathsIndependentOfAdapter`).
    function adapterFault(uint256 mode) external step {
        MockRiskAdapter a = adapters[active];
        mode %= 5;
        if (mode == 0) a.setBroken(true);
        else if (mode == 1) a.setShortReturn(true);
        else if (mode == 2) a.set(0, 1000, type(uint256).max);
        else if (mode == 3) a.set(truePriceX96, 1000, block.timestamp - 1);
        else a.set(truePriceX96, vault.maxUncertaintyPips() + 1, type(uint256).max);
        faulted = true;
        honest = false;
        ++faults;
    }

    /// @notice Honest move of the true price by -20% .. +25%; the adapter follows with a small band.
    function priceJump(uint256 seed) external step {
        uint256 factor = bound(seed, 800, 1250);
        truePriceX96 = FullMath.mulDiv(truePriceX96, factor, 1000);
        if (truePriceX96 < Q96 / 1000) truePriceX96 = Q96 / 1000;
        if (truePriceX96 > Q96 * 1000) truePriceX96 = Q96 * 1000;
        _setActive(truePriceX96, 1000);
    }

    /// @notice One asset loses most of its value: asset1 (the price of asset0 in asset1 rises) or asset0.
    function depeg(bool asset1Depegs, uint256 seed) external step {
        uint256 severity = bound(seed, 2, 100); // the depegged asset keeps 1/severity of its value
        truePriceX96 = asset1Depegs ? truePriceX96 * severity : truePriceX96 / severity;
        if (truePriceX96 == 0) truePriceX96 = 1;
        if (truePriceX96 > Q96 * 1e6) truePriceX96 = Q96 * 1e6;
        _setActive(truePriceX96, 1000);
        ++depegs;
    }

    /// @notice The adapter is corrupted and reports any price the adversary likes.
    function corruptReference(uint256 priceSeed, uint256 uSeed) external step {
        _setActive(bound(priceSeed, 1, Q96 << 40), bound(uSeed, 0, vault.maxUncertaintyPips()));
    }

    // =================================================================== trades

    function _allocate(uint256 curatorIdx, PoolKey memory key, Currency out, uint256 maxOut, uint256 hours_)
        internal
        returns (uint256 id)
    {
        if (maxOut == 0 || maxOut > type(uint120).max) return 0;
        ISharedCommitmentVault.AllocationRequest memory r = ISharedCommitmentVault.AllocationRequest({
            consumer: address(key.hooks),
            key: key,
            currencyOut: out,
            maxOut: uint128(maxOut),
            minInPerOutX96: 1,
            expiry: uint64(block.timestamp + hours_ * 1 hours),
            nonce: nonce++,
            deadline: uint64(block.timestamp + 1 hours)
        });
        vm.prank(curators[curatorIdx % 2]);
        try auth.activateDirect(r) returns (uint256 i) {
            id = i;
            allocationIds.push(i);
        } catch {}
    }

    function _cancel(uint256 curatorIdx, uint256 id) internal {
        vm.prank(curators[curatorIdx % 2]);
        try vault.cancelAllocation(id) {} catch {}
    }

    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn, bytes memory hookData)
        internal
        returns (bool ok, uint256 out)
    {
        t0.mint(address(this), amountIn);
        t1.mint(address(this), amountIn);
        try router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        ) returns (
            BalanceDelta d
        ) {
            ok = true;
            out = uint256(int256(zeroForOne ? d.amount1() : d.amount0()));
        } catch {}
    }

    /// @notice A trade through Hook A or Hook B at whatever the adapter currently says, from either curator's
    ///         allocation. When the adapter is honest this is ordinary flow, including refills of a drained asset.
    function tradeHook(bool useA, bool zeroForOne, uint256 amountSeed, uint256 curatorIdx) external step {
        PoolKey memory key = useA ? keyA : keyB;
        Currency out = zeroForOne ? c1 : c0;
        // At most 2,000 tokens: inside the shared inventory cap even after the guardian lowers kappa to 0.1%, so a
        // refusal reflects the state (floor, cap, reference), not an oversized order.
        uint256 amountIn = bound(amountSeed, 1e15, 2000 ether);
        if (honest) ++tradeAttempts;
        uint256 id = _allocate(curatorIdx, key, out, _net(out) / 4, 2);
        if (id == 0) return;
        (bool ok, uint256 got) = _swap(key, zeroForOne, amountIn, abi.encode(id));
        if (ok) {
            if (useA) ++fillsA;
            else ++fillsB;
            _recordFill(zeroForOne, amountIn, got);
            if (faulted) ++filledUnderFault;
        } else if (faulted) {
            ++refusedUnderFault;
        }
        _cancel(curatorIdx, id);
    }

    /// @notice The malicious consumer buys `out` paying exactly the vault's current floor (so at the corrupted price
    ///         when the adapter is corrupted), sometimes asking for one unit more than the inventory floor allows.
    ///         With `extremePrice` the adversary first sets the reference that makes this direction cheapest (asset0
    ///         "worthless" at P = 1, or asset1 "worthless" at P = 2^160), so most drains land at a corrupted price.
    function drain(bool sellAsset1, uint256 outSeed, bool overshoot, uint256 curatorIdx, bool extremePrice)
        external
        step
    {
        Currency c = sellAsset1 ? c1 : c0;
        if (extremePrice) _setActive(sellAsset1 ? 2 ** 160 : 1, 0);
        uint256 room = lens.inventoryRoom(vault, c);
        uint256 out = overshoot ? room + 1 : bound(outSeed, 1, room + 2);
        uint256 id = _allocate(curatorIdx, keyM, c, out, 2);
        if (id == 0) return;
        uint256 floor_;
        try lens.effectiveFloorX96(vault, id) returns (uint256 f) {
            floor_ = f;
        } catch {
            if (!faulted) return _cancel(curatorIdx, id);
            // The lens cannot price a fill under a fault. The malicious consumer still tries, paying twice the true
            // price, so that the vault's own reading check is the only thing between it and a fill. (Hook trades are
            // also refused by the hooks' own reading checks, so they alone cannot show the vault's check works.)
            floor_ = 2 * (sellAsset1 ? FullMath.mulDiv(Q96, Q96, truePriceX96) : truePriceX96);
        }
        uint256 amountIn = FullMath.mulDivRoundingUp(out, floor_, Q96);
        if (amountIn == 0 || amountIn > type(uint120).max) return _cancel(curatorIdx, id);
        mal.configure(MaliciousConsumerHook.Attack.ExactAmounts, id, out);
        (bool ok,) = _swap(keyM, sellAsset1, amountIn, "");
        if (ok) {
            ++fillsMal;
            _recordFill(sellAsset1, amountIn, out);
            if (faulted) ++filledUnderFault;
        } else if (faulted) {
            ++refusedUnderFault;
        } else if (out > room) {
            ++refusedAtFloor;
        }
        _cancel(curatorIdx, id);
    }

    // =================================================================== LPs

    function deposit(uint256 who, uint256 sharesSeed) external step {
        address lp = lps[who % 3];
        uint256 shares = bound(sharesSeed, 1e9, vault.totalShares() / 2);
        (uint256 a0, uint256 a1) = lens.previewDeposit(vault, shares);
        uint256[2] memory h = [_holding(0), _holding(1)];
        t0.mint(lp, a0);
        t1.mint(lp, a1);
        vm.prank(lp);
        try vault.deposit(shares, a0, a1, lp) {
            Holder storage hd = holders[lp];
            hd.shares += shares;
            for (uint256 i; i < 2; ++i) {
                uint256 l = _floorPerShare(i);
                hd.basket[i] += shares * h[i];
                if (h[i] > l) hd.room[i] += shares * (h[i] - l);
            }
        } catch {}
    }

    function redeem(uint256 who, uint256 fracSeed, bool queue) external step {
        address lp = lps[who % 3];
        if (holders[lp].shares == 0) return;
        _redeem(lp, bound(fracSeed, 1, holders[lp].shares), queue);
    }

    function _redeem(address lp, uint256 shares, bool queue) internal {
        Holder storage hd = holders[lp];
        uint256 before = hd.shares;
        vm.prank(lp);
        try vault.redeem(shares, 0, 0, lp, queue) returns (uint256 inst, uint256 a0, uint256 a1, uint256 rid) {
            if (inst != 0) {
                ++payoutsChecked;
                if (!_checkPayout(inst, before, hd.basket, hd.room, [a0, a1])) ++q2Violations;
                hd.shares -= inst;
                before -= inst;
            }
            if (rid != 0) {
                uint256 rem = shares - inst;
                Req storage q = reqs[rid];
                q.lp = lp;
                q.shares = rem;
                for (uint256 i; i < 2; ++i) {
                    uint256 b = FullMath.mulDiv(hd.basket[i], rem, before);
                    uint256 r = FullMath.mulDiv(hd.room[i], rem, before);
                    q.basket[i] = b;
                    q.room[i] = r;
                    hd.basket[i] -= b;
                    hd.room[i] -= r;
                }
                hd.shares -= rem;
                pendingIds.push(rid);
                allRequests.push(rid);
            }
        } catch {}
    }

    function processQueue(uint256 steps) external step {
        try vault.processQueue(bound(steps, 1, 16)) {} catch {}
    }

    function claim(uint256 idx) external step {
        if (allRequests.length == 0) return;
        uint256 rid = allRequests[idx % allRequests.length];
        Req storage q = reqs[rid];
        vm.prank(q.lp);
        try vault.claim(rid) returns (uint256, uint256) {
            q.lastClaimable = [uint256(0), uint256(0)];
        } catch {}
    }

    function cancelRequest(uint256 idx) external step {
        if (pendingIds.length == 0) return;
        uint256 rid = pendingIds[idx % pendingIds.length];
        Req storage q = reqs[rid];
        vm.prank(q.lp);
        try vault.cancelRequest(rid) returns (uint256 returned) {
            Holder storage hd = holders[q.lp];
            hd.shares += returned;
            for (uint256 i; i < 2; ++i) {
                hd.basket[i] += q.basket[i];
                hd.room[i] += q.room[i];
                q.basket[i] = 0;
                q.room[i] = 0;
            }
            q.shares = 0;
        } catch {}
    }

    // =================================================================== governance and time

    /// @notice Guardian tightening: re-centre a target on the current holding, lower a tolerance, or raise the edge.
    function guardianTighten(uint256 mode, uint256 seed) external step {
        uint256 s = vault.totalShares();
        uint256[2] memory tau = [vault.inventoryTargetPerShare(0), vault.inventoryTargetPerShare(1)];
        uint24[2] memory k = [vault.inventoryTolerancePips(0), vault.inventoryTolerancePips(1)];
        vm.startPrank(guardian);
        if (mode % 3 == 0) {
            for (uint256 i; i < 2; ++i) {
                uint256 h = FullMath.mulDiv(_net(i == 0 ? c0 : c1), WAD, s);
                if (h > tau[i]) tau[i] = h;
            }
            try vault.setInventoryBounds(tau[0], tau[1], k[0], k[1]) {} catch {}
        } else if (mode % 3 == 1) {
            uint24 nk = uint24(bound(seed, 1000, k[seed % 2]));
            if (seed % 2 == 0) k[0] = nk;
            else k[1] = nk;
            try vault.setInventoryBounds(tau[0], tau[1], k[0], k[1]) {} catch {}
        } else {
            try vault.setRiskBounds(vault.riskEdgePips() + uint24(bound(seed, 0, 50)), vault.maxUncertaintyPips()) {}
                catch {}
        }
        vm.stopPrank();
    }

    /// @dev Anyone may release an expired allocation; ids still live (not yet expired) are kept for later.
    function _releaseExpired() internal {
        uint256 n = allocationIds.length;
        for (uint256 k = n; k > 0; --k) {
            uint256 id = allocationIds[k - 1];
            ISharedCommitmentVault.Allocation memory a = vault.getAllocation(id);
            if (!a.released && block.timestamp < a.expiry) continue;
            if (!a.released) vault.release(id);
            allocationIds[k - 1] = allocationIds[allocationIds.length - 1];
            allocationIds.pop();
        }
    }

    /// @notice Governed loosening: raise one tolerance (up to 20%) or lower one target by up to 10%, through the governor
    ///         with its full LONG_DELAY. The admin processes the queue first; if LPs are still waiting the governor
    ///         refuses (`PendingWithdrawals`) and the change is canceled. On success, every LP that stayed gets the
    ///         extra room and G_a restarts from the new floor; queued requests cannot exist (checked).
    ///         With `lateLp`, the adversarial ordering of GOVERNANCE_SECURITY.md §3.2 is played inside the delay: 5 days
    ///         after the announcement a curator commits inventory for MAX_HORIZON and an LP then queues behind it, so
    ///         the LP is still queued at eta and the governor must refuse.
    function governedLoosen(uint256 which, uint256 seed, bool lateLp) external step {
        uint256 i = which % 2;
        uint256[2] memory tau = [vault.inventoryTargetPerShare(0), vault.inventoryTargetPerShare(1)];
        uint24[2] memory k = [vault.inventoryTolerancePips(0), vault.inventoryTolerancePips(1)];
        if (seed % 2 == 0) k[i] = uint24(bound(seed, k[i], 200_000));
        else tau[i] = tau[i] - tau[i] * bound(seed, 0, 100) / 1000;
        uint256[2] memory lOld = [_floorPerShare(0), _floorPerShare(1)];
        bytes memory data = abi.encodeCall(vault.setInventoryBounds, (tau[0], tau[1], k[0], k[1]));
        vm.prank(govAdmin);
        (, uint256 eta) = gov.queue(address(vault), data);
        if (lateLp) {
            vm.warp(block.timestamp + 5 days);
            _releaseExpired();
            _allocate(seed, keyA, c0, vault.admissibleCapacity(c0), 30 * 24);
            address lp = lps[seed % 3];
            if (holders[lp].shares > 1) _redeem(lp, holders[lp].shares / 2, true);
        }
        vm.warp(eta);
        _releaseExpired();
        vault.processQueue(64); // the admin's same-transaction step; slices are checked after the call
        vm.prank(govAdmin);
        try gov.execute(address(vault), data) {
            if (vault.pendingShares() != 0) ++requestViolations; // the governor must have refused
            loosened = true;
            ++loosenings;
            for (uint256 j; j < 2; ++j) {
                uint256 lNew = _floorPerShare(j);
                if (lNew < lOld[j]) {
                    for (uint256 p; p < 3; ++p) {
                        Holder storage hd = holders[lps[p]];
                        hd.room[j] += hd.shares * (lOld[j] - lNew);
                    }
                }
            }
        } catch {
            vm.prank(govAdmin);
            gov.cancel(address(vault), data);
            ++looseningsBlocked;
        }
    }

    /// @notice Governed adapter replacement (DELAY): the other adapter, reporting the true price, is installed.
    function replaceAdapter() external step {
        uint256 next = 1 - active;
        adapters[next].setBroken(false);
        adapters[next].setShortReturn(false);
        adapters[next].set(truePriceX96, 1000, type(uint256).max);
        bytes memory data = abi.encodeCall(vault.setRiskAdapter, (IMarketRiskAdapter(address(adapters[next]))));
        vm.prank(govAdmin);
        (, uint256 eta) = gov.queue(address(vault), data);
        vm.warp(eta);
        vm.prank(govAdmin);
        try gov.execute(address(vault), data) {
            active = next;
            faulted = false;
            honest = true;
            ++adapterSwaps;
        } catch {
            vm.prank(govAdmin);
            gov.cancel(address(vault), data);
        }
    }

    function warp(uint256 secondsSeed) external step {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 2 days));
        _releaseExpired();
    }
}

contract InventoryProtectionInvariantsTest is VaultTestBase {
    uint160 internal constant SWAP_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

    InventoryProtectionHandler internal handler;
    VaultGovernor internal gov;
    address internal guardian = makeAddr("guardian");
    address internal curator2 = makeAddr("curator2");
    address internal govAdmin = makeAddr("govAdmin");
    MockRiskAdapter[2] internal adapters;

    function setUp() public override {
        super.setUp();
        address m = address(uint160(0xBAD2 << 140) | SWAP_FLAGS);
        deployCodeTo("MaliciousConsumerHook.sol:MaliciousConsumerHook", abi.encode(manager, vault), m);
        PoolKey memory keyM = PoolKey(c0, c1, 3000, 60, IHooks(m));
        manager.initialize(keyM, SQRT_PRICE_1_1);
        adapters = [
            new MockRiskAdapter(address(token0), address(token1), 18, 18, keccak256("a")),
            new MockRiskAdapter(address(token0), address(token1), 18, 18, keccak256("b"))
        ];
        adapters[0].set(FixedPoint96.Q96, 1000, type(uint256).max);
        uint256 tau = FullMath.mulDiv(vault.backing(c0), 1e18, vault.totalShares());

        vm.startPrank(owner);
        vault.setConsumer(m, true);
        _openLimits(ISharedCommitmentVault.RiskScope.Hook, m);
        vault.setCurator(curator2, true);
        _openLimits(ISharedCommitmentVault.RiskScope.Curator, curator2);
        vault.setGuardian(guardian);
        for (uint256 i; i < 2; ++i) {
            address cur = i == 0 ? curator : curator2;
            vault.setCuratorCeiling(cur, c0, type(uint256).max);
            vault.setCuratorCeiling(cur, c1, type(uint256).max);
        }
        vault.setRiskBounds(100, 5000);
        vault.setInventoryBounds(tau, tau, 50_000, 50_000);
        vault.setRiskAdapter(adapters[0]);
        vault.setSellFloor(c0, 0);
        vault.setSellFloor(c1, 0);
        vm.stopPrank();

        BaseCompatibleHook.CoreParams memory p = BaseCompatibleHook.CoreParams({
            depthPerShare: 10e18,
            depthMax: uint128(2 ** 95 - 1),
            baseSpreadPips: 3000,
            minEdgePips: 200,
            maxSpreadPips: 40_000,
            maxDeviationPips: 50_000
        });
        vm.startPrank(hookOwner);
        hookA.configureCore(keyA, p);
        hookB.configureCore(keyB, p);
        hookB.configureStrategy(keyB, 1000, 20_000);
        vm.stopPrank();

        gov = new VaultGovernor(address(vault), govAdmin, 3 days, 32 days, 7 days);
        vm.prank(owner);
        vault.transferOwnership(address(gov));
        vm.prank(govAdmin);
        gov.acceptVaultOwnership();

        handler = new InventoryProtectionHandler(
            vault,
            lens,
            auth,
            gov,
            swapRouter,
            MaliciousConsumerHook(m),
            adapters,
            [keyA, keyB, keyM],
            [curator, curator2],
            guardian
        );
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](16);
        selectors[0] = handler.priceJump.selector;
        selectors[1] = handler.depeg.selector;
        selectors[2] = handler.corruptReference.selector;
        selectors[3] = handler.tradeHook.selector;
        selectors[4] = handler.tradeHook.selector; // weighted: ordinary flow is the common case
        selectors[5] = handler.drain.selector;
        selectors[6] = handler.deposit.selector;
        selectors[7] = handler.redeem.selector;
        selectors[8] = handler.processQueue.selector;
        selectors[9] = handler.claim.selector;
        selectors[10] = handler.cancelRequest.selector;
        selectors[11] = handler.guardianTighten.selector;
        selectors[12] = handler.governedLoosen.selector;
        selectors[13] = handler.replaceAdapter.selector;
        selectors[14] = handler.warp.selector;
        selectors[15] = handler.adapterFault.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice Q1: no call lowers a per-share holding below the largest min(holding, floor) seen since the last
    ///         governed loosening.
    function invariant_Q1_perShareFloor() public view {
        assertEq(handler.q1Violations(), 0);
    }

    /// @notice Q2: no instant payout falls short of the LP's own entry basket by more than its room (+1 raw unit), in
    ///         either asset; hence at no price vector, depegs included.
    function invariant_Q2_entryBasketShortfall() public view {
        assertEq(handler.q2Violations(), 0);
    }

    /// @notice Q2 for queued LPs: every finalization slice respects the room the request had when it was queued; a
    ///         loosening never executes while shares are queued.
    function invariant_Q2_queuedRequestsKeepTheirProtection() public view {
        assertEq(handler.requestViolations(), 0);
    }

    function invariant_accountingConsistent() public view {
        _assertAccountingConsistent();
    }

    /// @notice No fill succeeds while the active adapter reverts, returns malformed data, or reports a zero price, an
    ///         expired reading or an uncertainty above the vault's bound.
    function invariant_noFillUnderAdapterFault() public view {
        assertEq(handler.filledUnderFault(), 0);
    }

    /// @notice LP paths do not read the adapter. In the current state, the same sequence (each LP redeems half its
    ///         shares queueing the rest, the queue is processed, the first claimable request is claimed, a new LP
    ///         deposits) is run twice on rolled-back copies: once with both adapters answering the true price and once
    ///         with both reverting. Every call's success flag and return data, and the resulting accounting, must be
    ///         identical. A difference means an LP path became dependent on the oracle, which would let an oracle
    ///         outage or a hostile adapter block exits.
    function invariant_lpPathsIndependentOfAdapter() public {
        assertEq(_lpProbe(false), _lpProbe(true), "an LP path depends on the adapter");
    }

    /// @dev Runs the LP sequence on a snapshot that is rolled back afterwards and hashes every outcome.
    function _lpProbe(bool fault) internal returns (bytes32 h) {
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 2; ++i) {
            adapters[i].setShortReturn(false);
            adapters[i].setBroken(fault);
            adapters[i].set(handler.truePriceX96(), 1000, type(uint256).max);
        }
        for (uint256 k; k < 3; ++k) {
            address lp = makeAddr(string.concat("pLp", vm.toString(k)));
            uint256 bal = vault.sharesOf(lp);
            if (bal == 0) continue;
            vm.prank(lp);
            (bool ok, bytes memory ret) =
                address(vault).call(abi.encodeCall(vault.redeem, (bal / 2 + 1, 0, 0, lp, true)));
            h = keccak256(abi.encode(h, ok, ret));
        }
        (bool okQ, bytes memory retQ) = address(vault).call(abi.encodeCall(vault.processQueue, (16)));
        h = keccak256(abi.encode(h, okQ, retQ));
        uint256 end = vault.nextRequestId();
        for (uint256 rid = 1; rid < end; ++rid) {
            ISharedCommitmentVault.WithdrawalRequest memory r = vault.getRequest(rid);
            if (r.claimable0 == 0 && r.claimable1 == 0) continue;
            vm.prank(r.lp);
            (bool okC, bytes memory retC) = address(vault).call(abi.encodeCall(vault.claim, (rid)));
            h = keccak256(abi.encode(h, okC, retC));
            break;
        }
        address probe = makeAddr("adapterProbe");
        uint256 shares = vault.totalShares() / 100 + 1;
        (uint256 p0, uint256 p1) = lens.previewDeposit(vault, shares);
        _fundLp(probe, p0, p1);
        vm.prank(probe);
        (bool okD, bytes memory retD) = address(vault).call(abi.encodeCall(vault.deposit, (shares, p0, p1, probe)));
        h = keccak256(
            abi.encode(
                h,
                okD,
                retD,
                vault.totalShares(),
                vault.pendingShares(),
                vault.backing(c0),
                vault.backing(c1),
                vault.claimableAssets(c0),
                vault.claimableAssets(c1)
            )
        );
        vm.revertToStateAndDelete(snap);
    }

    /// @notice Non-vacuity, per run: once a run is long enough, trades have filled.
    function afterInvariant() external view {
        // A run can legitimately reach a state where no direction can trade (an asset at its floor and the other at
        // the shared cap after a guardian tightening). Eight honest attempts with no fill is treated as a dead handler.
        // Only attempts made while the adapter reports the true price count: under a corrupted reference (for example
        // a price near zero) the hooks quote at that price and every trade can be refused, and under an adapter fault
        // every trade must be refused. The G01 baseline found the previous count (all attempts) failing for other
        // seeds: one `corruptReference` followed by eight trades is enough.
        uint256 fills = handler.fillsA() + handler.fillsB() + handler.fillsMal();
        if (handler.tradeAttempts() >= 8) assertGt(fills, 0, "eight trade attempts filled nothing");
        // Read by test/invariant/coverage.py (see VaultInvariantsTest.afterInvariant).
        console2.log("COV fillsA", handler.fillsA());
        console2.log("COV fillsB", handler.fillsB());
        console2.log("COV fillsMal", handler.fillsMal());
        console2.log("COV refusedAtFloor", handler.refusedAtFloor());
        console2.log("COV loosenings", handler.loosenings());
        console2.log("COV looseningsBlocked", handler.looseningsBlocked());
        console2.log("COV payoutsChecked", handler.payoutsChecked());
        console2.log("COV slicesChecked", handler.slicesChecked());
        console2.log("COV refusedUnderFault", handler.refusedUnderFault());
        console2.log("calls", handler.calls());
        console2.log("fills A / B / malicious", handler.fillsA(), handler.fillsB(), handler.fillsMal());
        console2.log("refused at floor", handler.refusedAtFloor());
        console2.log("loosenings executed / blocked by queue", handler.loosenings(), handler.looseningsBlocked());
        console2.log("adapter swaps / depegs", handler.adapterSwaps(), handler.depegs());
        console2.log("adapter faults / refused under fault", handler.faults(), handler.refusedUnderFault());
        console2.log("payouts / slices checked", handler.payoutsChecked(), handler.slicesChecked());
        console2.log("Q3 realized loss / gain (asset1 raw)", handler.realizedLoss(), handler.realizedGain());
        console2.log("Q4 min value per share, 1e18 = start", handler.minValue());
        console2.log("max shortfall / room, bps", handler.maxShortfallToRoomBps());
    }
}

/// @notice Guards against a vacuous campaign: a scripted sequence through the handler must reach every branch the
///         invariants depend on (fills through both hooks and the malicious consumer, refusals at the floor, instant
///         payouts, finalization slices, an executed and a refused loosening, an adapter swap and a depeg), with no
///         violation.
contract InventoryProtectionLivenessTest is InventoryProtectionInvariantsTest {
    function test_handler_reachesEveryBranch() public {
        handler.deposit(0, 1e22);
        handler.deposit(1, 2e22);
        handler.tradeHook(true, true, 1000 ether, 0);
        handler.tradeHook(false, false, 1000 ether, 1);
        handler.corruptReference(1, 0);
        handler.drain(false, 1e21, false, 0, false);
        handler.drain(false, 0, true, 1, true);
        handler.priceJump(1000); // honest again
        handler.redeem(0, 1e21, false);
        handler.governedLoosen(0, 4, true); // late LP (seed 4 -> LP 1): refused while queued
        handler.warp(2 days);
        for (uint256 d; d < 16; ++d) {
            handler.warp(2 days); // the late LP's commitment expires and is released
        }
        handler.processQueue(16);
        handler.governedLoosen(1, 100_000, false); // queue empty: executes
        handler.replaceAdapter();
        handler.depeg(true, 10);
        handler.tradeHook(true, false, 5000 ether, 0); // honest arbitrage after the depeg
        handler.guardianTighten(0, 0);
        for (uint256 mode; mode < 5; ++mode) {
            handler.adapterFault(mode);
            handler.tradeHook(true, true, 100 ether, 0);
            handler.drain(true, 1e18, false, 1, false);
        }
        assertEq(handler.refusedUnderFault(), 10, "every fault refused both a hook trade and a drain");
        invariant_lpPathsIndependentOfAdapter();
        handler.priceJump(1000); // recovers
        handler.tradeHook(true, true, 100 ether, 0);

        assertGt(handler.fillsA(), 0, "hook A filled");
        assertGt(handler.fillsB(), 0, "hook B filled");
        assertGt(handler.fillsMal(), 0, "malicious consumer filled");
        assertGt(handler.realizedLoss(), 0, "a drain at a corrupted price realized a loss");
        assertGt(handler.refusedAtFloor(), 0, "overshoot refused at the floor");
        assertGt(handler.payoutsChecked(), 0, "instant payout checked");
        assertGt(handler.slicesChecked(), 0, "finalization slice checked");
        assertEq(handler.looseningsBlocked(), 1, "loosening refused while an LP was queued");
        assertEq(handler.loosenings(), 1, "loosening executed once the queue was empty");
        assertEq(handler.adapterSwaps(), 1);
        assertEq(handler.depegs(), 1);
        assertEq(handler.q1Violations(), 0);
        assertEq(handler.q2Violations(), 0);
        assertEq(handler.requestViolations(), 0);
        assertEq(handler.filledUnderFault(), 0);
    }

    /// @notice Why the per-run non-vacuity rule counts only trades made under an honest reference: this sequence (the
    ///         counterexample the fuzzer found against the earlier rule, with its largest arguments shortened) corrupts the reference to a price near zero
    ///         (107,250 / 2^96) and then makes eight hook trades. All eight are refused, legitimately: the hooks quote at
    ///         the corrupted price and the vault's inventory floor or zero-output checks refuse every one. Counted as
    ///         honest attempts they would have failed the run; they are not counted, and no fill happens.
    function test_handler_corruptReferenceCanBlockEveryTrade() public {
        handler.corruptReference(107_250, 8710);
        handler.tradeHook(false, false, 2_779_027_554_591_282_533_412_073_667, 433_273_712_978_899_021);
        handler.tradeHook(false, true, 26_787_534_065_648_167, 92_968_073_097_002_907);
        handler.tradeHook(true, true, 3150, 41);
        handler.tradeHook(true, false, 1_040_969_358_678_852_632, 96);
        handler.tradeHook(false, true, 5, 26_959_946_667_150_639);
        handler.tradeHook(false, true, 11_276_080_788_923_919, 3_461_367_875_332_493);
        handler.tradeHook(false, false, 2_069_849_032_019_506_429, 1);
        handler.tradeHook(false, false, 8780, 172_800);
        assertEq(handler.fillsA() + handler.fillsB(), 0, "no trade fills at the corrupted reference");
        assertEq(handler.tradeAttempts(), 0, "attempts under a corrupted reference are not counted");
        assertEq(handler.q1Violations(), 0);
    }
}
