// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {AuthModeHook} from "../utils/AuthModeHook.sol";
import {ClaimDonor} from "../utils/ClaimDonor.sol";

/// @notice Random action sequences against the real PoolManager: curator allocations, swaps through three hooks
///         (HookA, HookB, a 1:1 test hook that can drain an asset to zero), time, releases, ERC-6909 donations,
///         multi-LP deposits, instant/queued redemptions (with inline queue processing), queue processing,
///         cancellations and claims. Each action may revert; the invariants must hold after every step, and each
///         successful action is checked against the ACTUAL balance movements it caused.
/// @dev How the checks work. The fuzzer calls handler functions in random order with random arguments. Each
///      action wraps its vault call in try/catch: a revert is a legitimate outcome (for example a swap below the
///      floor), so the campaign runs with fail_on_revert = false. Properties that can only be judged at the moment
///      of an action (did this deposit lower N_a / S? did this swap move claims below the floor?) are checked inside
///      the handler and recorded as sticky violation flags. The invariant functions then assert those flags are
///      still false, together with properties of the current state.
///
///      Ghost variables are an independent record of what SHOULD be true, built only from what each action
///      returned or measurably moved. Comparing them with the vault's own storage catches bugs where the vault's
///      bookkeeping and its real token movements drift apart.
contract VaultHandler is Test {
    struct Snap {
        uint256 b0;
        uint256 b1;
        uint256 pm0;
        uint256 pm1;
        uint256 w0;
        uint256 w1;
        uint256 n0;
        uint256 n1;
        uint256 s;
    }

    SharedCommitmentVault internal vault;
    IPoolManager internal manager;
    PoolSwapTest internal router;
    ClaimDonor internal donor;
    PoolKey internal keyA;
    PoolKey internal keyB;
    PoolKey internal keyE;
    Currency internal c0;
    Currency internal c1;
    address internal curator;
    address internal trader;
    address internal owner;

    address[] public lps;
    uint256[] public allocationIds;
    uint256 internal nonce = 1_000_000;

    /// Ghost ledger: backing implied by deposits - payouts + swap inputs received - swap outputs paid. Built from
    /// return values and measured swap deltas, never from `vault.backing`, so it is an independent check of B_a.
    mapping(Currency => uint256) public ghostBacking;
    /// ERC-6909 claims sent straight to the vault (never part of B_a).
    mapping(Currency => uint256) public ghostDonated;
    /// Per request: assets ever finalized and assets ever paid by claim. claimed + still claimable must equal
    /// finalized, so a request paid twice, or paid more than was finalized for it, is detected.
    mapping(uint256 => uint256[2]) internal ghostFinalized;
    mapping(uint256 => uint256[2]) internal ghostClaimed;
    mapping(uint256 => uint256) public ghostFinalizedShares;

    /// Violation flags, asserted by the invariant contract.
    bool public perShareDecreased; // a non-trade op lowered N_a / S
    bool public balanceMismatch; // an ERC-20 or ERC-6909 movement differed from the accounting change
    bool public claimableTouched; // W_a changed in an action that is not finalization or claim
    bool public admissionViolated; // an allocation larger than the admissible capacity succeeded
    bool public priceViolated; // INV-P1: a successful swap moved claims below max(vault floor, curator floor)
    bool public guardianLoosened; // INV-R1: a guardian call lowered a floor or buffer, or resumed a direction
    bool public capacityReverted; // admissibleCapacity reverted (e.g. Q + R + D overflowing 256 bits)

    address public guardian;
    uint256 public floorChangesOk;
    uint256 public bufferChangesOk;
    uint256 public haltsOk;
    uint256 public guardianRefusals;

    uint256 public swapsOk;
    uint256 public allocationsOk;
    uint256 public releasesOk;
    uint256 public depositsOk;
    uint256 public instantOk;
    uint256 public queuedOk;
    uint256 public finalizedOk;
    uint256 public claimsOk;
    uint256 public cancelsOk;
    uint256 public donationsOk;
    uint256 public drainsOk;
    uint256 public zeroAssetStatesSeen;

    constructor(
        SharedCommitmentVault vault_,
        IPoolManager manager_,
        PoolSwapTest router_,
        PoolKey[3] memory keys,
        address owner_,
        address curator_,
        address trader_,
        address[] memory lps_
    ) {
        vault = vault_;
        manager = manager_;
        router = router_;
        donor = new ClaimDonor(manager_);
        keyA = keys[0];
        keyB = keys[1];
        keyE = keys[2];
        c0 = keys[0].currency0;
        c1 = keys[0].currency1;
        owner = owner_;
        curator = curator_;
        trader = trader_;
        lps = lps_;
        ghostBacking[c0] = vault_.backing(c0);
        ghostBacking[c1] = vault_.backing(c1);
        for (uint256 i; i < lps_.length; ++i) {
            vm.startPrank(lps_[i]);
            MockERC20(Currency.unwrap(c0)).approve(address(vault_), type(uint256).max);
            MockERC20(Currency.unwrap(c1)).approve(address(vault_), type(uint256).max);
            vm.stopPrank();
        }
        MockERC20(Currency.unwrap(c0)).approve(address(donor), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(donor), type(uint256).max);
    }

    /// @dev Called once by the invariant contract's setUp (not a fuzz target).
    function setGuardian(address guardian_) external {
        guardian = guardian_;
    }

    function allocationCount() external view returns (uint256) {
        return allocationIds.length;
    }

    function lpCount() external view returns (uint256) {
        return lps.length;
    }

    function finalized(uint256 id) external view returns (uint256[2] memory) {
        return ghostFinalized[id];
    }

    function claimed(uint256 id) external view returns (uint256[2] memory) {
        return ghostClaimed[id];
    }

    // ------------------------------------------------------------------
    // Curator / trader / third-party actions
    // ------------------------------------------------------------------

    function allocate(uint256 seed, uint256 maxOut, uint256 lifetime) external {
        PoolKey memory key = seed % 2 == 0 ? keyA : keyB;
        Currency out = (seed >> 1) % 2 == 0 ? c0 : c1;
        _allocate(key, out, bound(maxOut, 1 ether, 1_500_000 ether), bound(lifetime, 1, 30 days));
    }

    function swap(uint256 idSeed, uint256 amountIn) external {
        if (allocationIds.length == 0) return;
        uint256 id = allocationIds[idSeed % allocationIds.length];
        ISharedCommitmentVault.Allocation memory a = vault.getAllocation(id);
        PoolKey memory key = a.consumer == address(keyA.hooks) ? keyA : a.consumer == address(keyB.hooks) ? keyB : keyE;
        _swap(key, a.currencyOut == c1, bound(amountIn, 1e9, 150_000 ether), id);
    }

    /// @notice Sell every admissible unit of one asset through the 1:1 hook: reaches N_a == 0 whenever nothing
    ///         is reserved, buffered or pending in that asset. Zero-asset states are where division-by-zero and
    ///         rounding bugs hide, and random swaps alone would almost never reach them. (setUp gives token0 a
    ///         buffer floor, so only token1 can actually reach zero.)
    function drain(uint256 seed) external {
        Currency out = seed % 2 == 0 ? c0 : c1;
        uint256 q = vault.admissibleCapacity(out);
        if (q == 0) return;
        uint256 id = _allocate(keyE, out, q, 1 days);
        if (id == 0) return;
        if (_swap(keyE, out == c1, q, id)) drainsOk++;
        if (vault.netAssets(c0) == 0 || vault.netAssets(c1) == 0) zeroAssetStatesSeen++;
    }

    // ------------------------------------------------------------------
    // Risk-policy actions: floors, halts and the guardian's tighten-only rule
    // ------------------------------------------------------------------

    /// @notice Guardian raises one floor by 0.01%-2%. Must always succeed (raising keeps D14) and never lower it.
    function guardianTighten(bool sellOne, uint256 bps) external {
        Currency out = sellOne ? c1 : c0;
        (uint160 f,) = vault.sellPolicy(out);
        uint256 next = uint256(f) + uint256(f) * bound(bps, 1, 200) / 10_000;
        if (next > type(uint160).max) return;
        vm.prank(guardian);
        // forge-lint: disable-next-line(unsafe-typecast)
        try vault.setSellFloor(out, uint160(next)) {
            floorChangesOk++;
        } catch {}
        (uint160 g,) = vault.sellPolicy(out);
        if (g < f) guardianLoosened = true;
    }

    /// @notice Guardian ATTEMPTS to lower a floor or resume a direction: must always be refused.
    function guardianTryLoosen(bool sellOne, uint256 bps) external {
        Currency out = sellOne ? c1 : c0;
        (uint160 f, bool h) = vault.sellPolicy(out);
        uint256 lower = uint256(f) - uint256(f) * bound(bps, 1, 5000) / 10_000;
        vm.startPrank(guardian);
        // forge-lint: disable-next-line(unsafe-typecast)
        try vault.setSellFloor(out, uint160(lower)) {
            if (lower < f) guardianLoosened = true;
        } catch {
            guardianRefusals++;
        }
        if (h) {
            try vault.setSellHalted(out, false) {
                guardianLoosened = true;
            } catch {
                guardianRefusals++;
            }
        }
        vm.stopPrank();
    }

    function guardianHalt(bool sellOne) external {
        vm.prank(guardian);
        vault.setSellHalted(sellOne ? c1 : c0, true);
        haltsOk++;
    }

    function ownerResume(bool sellOne) external {
        vm.prank(owner);
        vault.setSellHalted(sellOne ? c1 : c0, false);
    }

    /// @notice Owner lowers one floor towards the D14 boundary ceil(2^192 / opposite floor), possibly below 1:1.
    function ownerLoosen(bool sellOne, uint256 bps) external {
        Currency out = sellOne ? c1 : c0;
        (uint160 f,) = vault.sellPolicy(out);
        (uint160 opp,) = vault.sellPolicy(sellOne ? c0 : c1);
        uint256 boundary = FullMath.mulDivRoundingUp(FixedPoint96.Q96, FixedPoint96.Q96, opp);
        uint256 lower = uint256(f) - uint256(f) * bound(bps, 1, 2000) / 10_000;
        if (lower < boundary) lower = boundary;
        vm.prank(owner);
        // forge-lint: disable-next-line(unsafe-typecast)
        try vault.setSellFloor(out, uint160(lower)) {
            floorChangesOk++;
        } catch {}
    }

    /// @notice Owner or guardian sets a buffer floor R_a. Half of guardian calls choose a value at the 256-bit
    ///         overflow boundary of Q_a + R_a + D_a (the guardian's "stop new allocations in this asset" action);
    ///         owner calls always choose an ordinary value and so can lower R_a again.
    /// @dev The huge value is R = type(uint256).max - offset with offset in [0, Q + D], so Q + R + D overflows for
    ///      every offset below Q + D and equals type(uint256).max exactly at offset == Q + D. A uniform draw near
    ///      type(uint256).max would almost never land in that window, which is only Q + D wide. `admissibleCapacity`
    ///      must keep returning (0 here) for both assets, `invariant_equationsFromRawSources` checks its value, and
    ///      the guardian may only raise R_a. Only the guardian goes huge so that the blocked state does not persist
    ///      for most of a run and starve the allocation and swap actions. asset0 keeps R_0 >= 50,000 so the setUp
    ///      property "token0 can never be fully drained" still holds.
    function setBuffer(bool sellOne, uint256 value, bool huge, bool asGuardian) external {
        Currency c = sellOne ? c1 : c0;
        value = huge && asGuardian
            ? type(uint256).max - bound(value, 0, vault.reserved(c) + vault.pendingDemand(c))
            : bound(value, sellOne ? 0 : 50_000 ether, 300_000 ether);
        uint256 before = vault.bufferFloor(c);
        vm.prank(asGuardian ? guardian : owner);
        try vault.setBufferFloor(c, value) {
            bufferChangesOk++;
            if (asGuardian && value < before) guardianLoosened = true;
        } catch {
            if (asGuardian) guardianRefusals++;
        }
        try vault.admissibleCapacity(c0) {}
        catch {
            capacityReverted = true;
        }
        try vault.admissibleCapacity(c1) {}
        catch {
            capacityReverted = true;
        }
    }

    function donate(bool zero, uint256 amount) external {
        Currency c = zero ? c0 : c1;
        amount = bound(amount, 1, 10_000 ether);
        MockERC20(Currency.unwrap(c)).mint(address(this), amount);
        Snap memory p = _take();
        donor.donate(c, amount, address(vault));
        ghostDonated[c] += amount;
        donationsOk++;
        // Backing must not move; the real balance moves by exactly the donation.
        Snap memory q = _take();
        if (q.b0 != p.b0 || q.b1 != p.b1) balanceMismatch = true;
        if (q.pm0 - p.pm0 != (zero ? amount : 0) || q.pm1 - p.pm1 != (zero ? 0 : amount)) balanceMismatch = true;
        _checkWUnchanged(p);
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 3 days));
    }

    function release(uint256 idSeed, bool asOwner) external {
        if (allocationIds.length == 0) return;
        uint256 id = allocationIds[idSeed % allocationIds.length];
        Snap memory p = _take();
        vm.prank(asOwner ? owner : address(0xBEEF));
        try vault.release(id) {
            releasesOk++;
            _checkBalancesFollowBacking(p);
            _checkWUnchanged(p);
            if (vault.backing(c0) != p.b0 || vault.backing(c1) != p.b1) balanceMismatch = true;
        } catch {}
    }

    // ------------------------------------------------------------------
    // LP actions
    // ------------------------------------------------------------------

    function deposit(uint256 lpSeed, uint256 shares) external {
        address lp = lps[lpSeed % lps.length];
        shares = bound(shares, 1, 200_000 ether);
        (uint256 a0, uint256 a1) = vault.previewDeposit(shares);
        MockERC20(Currency.unwrap(c0)).mint(lp, a0);
        MockERC20(Currency.unwrap(c1)).mint(lp, a1);
        uint256 e0 = _erc20(c0, lp);
        uint256 e1 = _erc20(c1, lp);
        Snap memory p = _take();
        vm.prank(lp);
        try vault.deposit(shares, a0, a1, lp) returns (uint256 x0, uint256 x1) {
            ghostBacking[c0] += x0;
            ghostBacking[c1] += x1;
            depositsOk++;
            if (e0 - _erc20(c0, lp) != x0 || e1 - _erc20(c1, lp) != x1) balanceMismatch = true;
            if (vault.backing(c0) - p.b0 != x0 || vault.backing(c1) - p.b1 != x1) balanceMismatch = true;
            _checkBalancesFollowBacking(p);
            _checkWUnchanged(p);
            _checkMonotonic(p);
        } catch {}
    }

    function redeem(uint256 lpSeed, uint256 shares, bool queueRemainder) external {
        address lp = lps[lpSeed % lps.length];
        uint256 bal = vault.sharesOf(lp);
        if (bal == 0) return;
        // Mostly material redemptions (>= 10% of the LP's balance), occasionally dust-sized ones.
        shares = shares % 8 == 0 ? bound(shares, 1, bal) : bound(shares, bal / 10 + 1, bal);
        (uint256 head, uint256 end, uint256[] memory pend, uint256[2][] memory cl) = _queueSnapshot();
        uint256 e0 = _erc20(c0, lp);
        uint256 e1 = _erc20(c1, lp);
        Snap memory p = _take();
        vm.prank(lp);
        try vault.redeem(shares, 0, 0, lp, queueRemainder) returns (
            uint256 instant, uint256 a0, uint256 a1, uint256 requestId
        ) {
            ghostBacking[c0] -= a0;
            ghostBacking[c1] -= a1;
            if (instant != 0) instantOk++;
            if (requestId != 0) queuedOk++;
            // Inline queue processing may have finalized earlier requests: record them.
            _recordFinalizations(head, end, pend, cl);
            if (_erc20(c0, lp) - e0 != a0 || _erc20(c1, lp) - e1 != a1) balanceMismatch = true;
            if (p.b0 - vault.backing(c0) != a0 || p.b1 - vault.backing(c1) != a1) balanceMismatch = true;
            _checkBalancesFollowBacking(p);
            _checkMonotonic(p);
        } catch {}
    }

    function process(uint256 steps) external {
        steps = bound(steps, 1, 5);
        (uint256 head, uint256 end, uint256[] memory pend, uint256[2][] memory cl) = _queueSnapshot();
        Snap memory p = _take();
        uint256 done = vault.processQueue(steps);
        _recordFinalizations(head, end, pend, cl);
        if (done != 0) finalizedOk++;
        if (vault.backing(c0) != p.b0 || vault.backing(c1) != p.b1) balanceMismatch = true;
        _checkBalancesFollowBacking(p);
        _checkMonotonic(p);
    }

    function cancel(uint256 idSeed) external {
        uint256 end = vault.nextRequestId();
        if (end == 1) return;
        uint256 id = 1 + idSeed % (end - 1);
        address lp = vault.getRequest(id).lp;
        Snap memory p = _take();
        vm.prank(lp);
        try vault.cancelRequest(id) {
            cancelsOk++;
            if (vault.backing(c0) != p.b0 || vault.backing(c1) != p.b1) balanceMismatch = true;
            _checkWUnchanged(p);
            _checkMonotonic(p);
        } catch {}
    }

    function claim(uint256 idSeed) external {
        uint256 end = vault.nextRequestId();
        if (end == 1) return;
        uint256 id = 1 + idSeed % (end - 1);
        ISharedCommitmentVault.WithdrawalRequest memory r = vault.getRequest(id);
        uint256 e0 = _erc20(c0, r.receiver);
        uint256 e1 = _erc20(c1, r.receiver);
        Snap memory p = _take();
        vm.prank(r.lp);
        try vault.claim(id) returns (uint256 a0, uint256 a1) {
            ghostClaimed[id][0] += a0;
            ghostClaimed[id][1] += a1;
            ghostBacking[c0] -= a0;
            ghostBacking[c1] -= a1;
            claimsOk++;
            if (_erc20(c0, r.receiver) - e0 != a0 || _erc20(c1, r.receiver) - e1 != a1) balanceMismatch = true;
            if (p.b0 - vault.backing(c0) != a0 || p.b1 - vault.backing(c1) != a1) balanceMismatch = true;
            if (p.w0 - vault.claimableAssets(c0) != a0 || p.w1 - vault.claimableAssets(c1) != a1) {
                balanceMismatch = true;
            }
            _checkBalancesFollowBacking(p);
            _checkMonotonic(p);
        } catch {}
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _allocate(PoolKey memory key, Currency out, uint256 maxOut, uint256 lifetime)
        internal
        returns (uint256 id)
    {
        ISharedCommitmentVault.AllocationRequest memory req =
            ISharedCommitmentVault.AllocationRequest({
                consumer: address(key.hooks),
                key: key,
                currencyOut: out,
                // forge-lint: disable-next-line(unsafe-typecast)
                maxOut: uint128(maxOut),
                minInPerOutX96: _curatorFloor(out), // must be >= the live vault floor or allocate reverts
                expiry: uint64(block.timestamp + lifetime),
                nonce: nonce++,
                deadline: uint64(block.timestamp)
            });
        uint256 admissible = vault.admissibleCapacity(out);
        Snap memory p = _take();
        vm.prank(curator);
        try vault.allocate(req) returns (uint256 newId) {
            id = newId;
            allocationIds.push(id);
            allocationsOk++;
            if (maxOut > admissible) admissionViolated = true;
            if (vault.backing(c0) != p.b0 || vault.backing(c1) != p.b1) balanceMismatch = true;
            _checkWUnchanged(p);
        } catch {}
    }

    /// @dev Curator floor used by the handler: 1:1, or the live vault floor if that is stricter.
    function _curatorFloor(Currency out) internal view returns (uint160) {
        (uint160 f,) = vault.sellPolicy(out);
        return f > uint160(FixedPoint96.Q96) ? f : uint160(FixedPoint96.Q96);
    }

    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn, uint256 id) internal returns (bool ok) {
        MockERC20(Currency.unwrap(zeroForOne ? c0 : c1)).mint(trader, amountIn);
        Currency cout = zeroForOne ? c1 : c0;
        uint256 feff;
        try vault.effectiveFloorX96(id) returns (uint256 f) {
            feff = f;
        } catch {}
        Snap memory p = _take();
        vm.prank(trader);
        try router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(id)
        ) returns (
            BalanceDelta d
        ) {
            int128 outDelta = zeroForOne ? d.amount1() : d.amount0();
            ghostBacking[zeroForOne ? c0 : c1] += amountIn;
            // forge-lint: disable-next-line(unsafe-typecast)
            ghostBacking[cout] -= uint256(int256(outDelta));
            swapsOk++;
            ok = true;
            _checkEffectiveFloor(p, zeroForOne, feff);
            _checkBalancesFollowBacking(p);
            _checkWUnchanged(p);
        } catch {}
    }

    /// @dev INV-P1 on MEASURED ERC-6909 deltas: dIn * 2^96 >= dOut * F_eff, compared in 512 bits. Measuring the
    ///      vault's real claim balances (not the amounts the hook or vault reported) means a bug that moved
    ///      different amounts than it checked would still be caught. The effective floor is read before the swap,
    ///      because that is the floor the vault applied.
    function _checkEffectiveFloor(Snap memory p, bool zeroForOne, uint256 feff) internal {
        Snap memory q = _take();
        (uint256 dIn, uint256 dOut) = zeroForOne ? (q.pm0 - p.pm0, p.pm1 - q.pm1) : (q.pm1 - p.pm1, p.pm0 - q.pm0);
        if (feff == 0) {
            priceViolated = true; // a swap succeeded although the floor view reverted (unconfigured or halted)
            return;
        }
        (uint256 h1, uint256 l1) = _mul512(dIn, FixedPoint96.Q96);
        (uint256 h2, uint256 l2) = _mul512(dOut, feff);
        if (h1 < h2 || (h1 == h2 && l1 < l2)) priceViolated = true;
    }

    /// @dev Full 512-bit product a * b as (hi, lo). lo is the product mod 2^256; mm is the product mod 2^256 - 1;
    ///      their difference (with a borrow) recovers the high word. Independent of FullMath, which the vault uses.
    function _mul512(uint256 a, uint256 b) internal pure returns (uint256 hi, uint256 lo) {
        unchecked {
            uint256 mm = mulmod(a, b, type(uint256).max);
            lo = a * b;
            hi = mm - lo - (mm < lo ? 1 : 0);
        }
    }

    /// @dev Records pending shares and claimables of every request from the head onward, so that
    ///      `_recordFinalizations` can attribute what an inline or explicit queue step finalized.
    function _queueSnapshot()
        internal
        view
        returns (uint256 head, uint256 end, uint256[] memory pend, uint256[2][] memory cl)
    {
        head = vault.queueHead();
        end = vault.nextRequestId();
        pend = new uint256[](end - head);
        cl = new uint256[2][](end - head);
        for (uint256 id = head; id < end; ++id) {
            ISharedCommitmentVault.WithdrawalRequest memory r = vault.getRequest(id);
            pend[id - head] = r.sharesPending;
            cl[id - head] = [uint256(r.claimable0), uint256(r.claimable1)];
        }
    }

    function _recordFinalizations(uint256 head, uint256 end, uint256[] memory pend, uint256[2][] memory cl) internal {
        for (uint256 id = head; id < end; ++id) {
            // Only called around redeem/processQueue, which never cancel: any pending decrease is a finalization.
            ISharedCommitmentVault.WithdrawalRequest memory r = vault.getRequest(id);
            ghostFinalizedShares[id] += pend[id - head] - r.sharesPending;
            ghostFinalized[id][0] += r.claimable0 - cl[id - head][0];
            ghostFinalized[id][1] += r.claimable1 - cl[id - head][1];
        }
    }

    function _take() internal view returns (Snap memory p) {
        p.b0 = vault.backing(c0);
        p.b1 = vault.backing(c1);
        p.pm0 = manager.balanceOf(address(vault), c0.toId());
        p.pm1 = manager.balanceOf(address(vault), c1.toId());
        p.w0 = vault.claimableAssets(c0);
        p.w1 = vault.claimableAssets(c1);
        p.n0 = vault.netAssets(c0);
        p.n1 = vault.netAssets(c1);
        p.s = vault.totalShares();
    }

    function _erc20(Currency c, address who) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c)).balanceOf(who);
    }

    /// The vault's real ERC-6909 balance changes by exactly the change in B_a.
    function _checkBalancesFollowBacking(Snap memory p) internal {
        if (
            int256(manager.balanceOf(address(vault), c0.toId())) - int256(p.pm0)
                    != int256(vault.backing(c0)) - int256(p.b0)
                || int256(manager.balanceOf(address(vault), c1.toId())) - int256(p.pm1)
                    != int256(vault.backing(c1)) - int256(p.b1)
        ) balanceMismatch = true;
    }

    function _checkWUnchanged(Snap memory p) internal {
        if (vault.claimableAssets(c0) != p.w0 || vault.claimableAssets(c1) != p.w1) claimableTouched = true;
    }

    /// N'_a / S' >= N_a / S  <=>  N'_a * S >= N_a * S'  (products < 2^254, no overflow). Called only after
    /// non-trade LP actions: deposits round up and redemptions round down precisely so that this never fails.
    /// Trades are excluded because they legitimately change the per-share basket in both assets.
    function _checkMonotonic(Snap memory p) internal {
        uint256 s2 = vault.totalShares();
        if (vault.netAssets(c0) * p.s < p.n0 * s2 || vault.netAssets(c1) * p.s < p.n1 * s2) perShareDecreased = true;
    }
}

contract VaultInvariantsTest is VaultTestBase {
    VaultHandler internal handler;
    PoolKey internal keyE;
    address internal guardianAddr = makeAddr("guardian");

    function setUp() public override {
        super.setUp();
        address e = address(uint160(0x0E1 << 140) | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        deployCodeTo("AuthModeHook.sol:AuthModeHook", abi.encode(manager, vault, AuthModeHook.Mode.Operator), e);
        keyE = PoolKey(c0, c1, 3000, 60, IHooks(e));
        manager.initialize(keyE, SQRT_PRICE_1_1);

        address[] memory lps = new address[](4);
        lps[0] = lp0;
        lps[1] = makeAddr("lpA");
        lps[2] = makeAddr("lpB");
        lps[3] = makeAddr("lpC");
        // Comparable LP sizes so that every LP's redemptions are material.
        for (uint256 i = 1; i < 4; ++i) {
            _depositShares(lps[i], 300_000 ether);
        }
        handler = new VaultHandler(vault, manager, swapRouter, [keyA, keyB, keyE], owner, curator, trader, lps);
        vm.startPrank(owner);
        vault.setConsumer(e, true);
        vault.setBufferFloor(c0, 50_000 ether); // token0 can never be fully drained; token1 can
        vault.setCuratorCeiling(curator, c0, type(uint256).max);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        vault.setGuardian(guardianAddr);
        vm.stopPrank();
        handler.setGuardian(guardianAddr);

        bytes4[] memory selectors = new bytes4[](18);
        selectors[0] = VaultHandler.allocate.selector;
        selectors[1] = VaultHandler.swap.selector;
        selectors[2] = VaultHandler.warp.selector;
        selectors[3] = VaultHandler.release.selector;
        selectors[4] = VaultHandler.deposit.selector;
        selectors[5] = VaultHandler.redeem.selector;
        selectors[6] = VaultHandler.process.selector;
        selectors[7] = VaultHandler.cancel.selector;
        selectors[8] = VaultHandler.claim.selector;
        selectors[9] = VaultHandler.redeem.selector; // redemption weighted x2
        selectors[10] = VaultHandler.donate.selector;
        selectors[11] = VaultHandler.drain.selector;
        selectors[12] = VaultHandler.guardianTighten.selector;
        selectors[13] = VaultHandler.guardianTryLoosen.selector;
        selectors[14] = VaultHandler.guardianHalt.selector;
        selectors[15] = VaultHandler.ownerResume.selector;
        selectors[16] = VaultHandler.ownerLoosen.selector;
        selectors[17] = VaultHandler.setBuffer.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// Real ERC-6909 balance == B_a + donations (no phantom or missing claims; donations never counted).
    function invariant_backingEqualsRealClaims() public view {
        assertEq(vault.backing(c0) + handler.ghostDonated(c0), _claims(address(vault), c0));
        assertEq(vault.backing(c1) + handler.ghostDonated(c1), _claims(address(vault), c1));
    }

    /// B_a matches an independent ledger of deposits, payouts, inputs received and outputs paid.
    function invariant_ghostLedgerConservation() public view {
        assertEq(vault.backing(c0), handler.ghostBacking(c0));
        assertEq(vault.backing(c1), handler.ghostBacking(c1));
    }

    /// Q_a == Σ over unreleased allocations of (maxOut - consumed), and Q_a + W_a <= B_a.
    function invariant_reservedIsExactAndBacked() public view {
        uint256 sum0;
        uint256 sum1;
        uint256 n = handler.allocationCount();
        for (uint256 i; i < n; ++i) {
            ISharedCommitmentVault.Allocation memory a = vault.getAllocation(handler.allocationIds(i));
            assertLe(a.consumed, a.maxOut, "consumed > maxOut");
            if (a.released) continue;
            if (a.currencyOut == c0) sum0 += a.maxOut - a.consumed;
            else sum1 += a.maxOut - a.consumed;
        }
        assertEq(vault.reserved(c0), sum0, "reserved0");
        assertEq(vault.reserved(c1), sum1, "reserved1");
        assertEq(vault.curatorReserved(curator, c0), sum0, "curatorReserved0");
        assertEq(vault.curatorReserved(curator, c1), sum1, "curatorReserved1");
        assertLe(vault.reserved(c0) + vault.claimableAssets(c0), vault.backing(c0));
        assertLe(vault.reserved(c1) + vault.claimableAssets(c1), vault.backing(c1));
    }

    /// Hooks never retain claims; no operator rights over the vault; PoolManager holds the ERC-20 behind them.
    function invariant_custodyAndSolvency() public view {
        _assertAccountingConsistentWith(handler.ghostDonated(c0), handler.ghostDonated(c1));
    }

    /// S == Σ sharesOf + P (nothing minted or burned out of thin air), P == Σ pending, W == Σ claimable.
    function invariant_sharesAndQueueConserved() public view {
        uint256 held = vault.sharesOf(address(0));
        for (uint256 i; i < handler.lpCount(); ++i) {
            held += vault.sharesOf(handler.lps(i));
        }
        assertEq(vault.totalShares(), held + vault.pendingShares(), "S != held + pending");
        assertGe(vault.totalShares(), vault.MIN_SHARES());

        uint256 p;
        uint256 w0;
        uint256 w1;
        uint256 end = vault.nextRequestId();
        for (uint256 id = 1; id < end; ++id) {
            ISharedCommitmentVault.WithdrawalRequest memory r = vault.getRequest(id);
            p += r.sharesPending;
            w0 += r.claimable0;
            w1 += r.claimable1;
            assertLe(r.sharesPending, r.sharesRequested);
            if (id < vault.queueHead()) assertEq(r.sharesPending, 0, "pending behind head");
        }
        assertEq(vault.pendingShares(), p, "P != sum pending");
        assertEq(vault.claimableAssets(c0), w0, "W0 != sum claimable");
        assertEq(vault.claimableAssets(c1), w1, "W1 != sum claimable");
    }

    /// No request is paid more than was finalized for it: claimed + claimable == finalized (no double claim).
    function invariant_noDoubleClaim() public view {
        uint256 end = vault.nextRequestId();
        for (uint256 id = 1; id < end; ++id) {
            ISharedCommitmentVault.WithdrawalRequest memory r = vault.getRequest(id);
            uint256[2] memory f = handler.finalized(id);
            uint256[2] memory c = handler.claimed(id);
            assertEq(c[0] + r.claimable0, f[0], "asset0 claimed + claimable != finalized");
            assertEq(c[1] + r.claimable1, f[1], "asset1 claimed + claimable != finalized");
        }
    }

    /// Strict FIFO: while request i still has pending shares, no later request has had any share finalized.
    function invariant_fifoOrdering() public view {
        uint256 end = vault.nextRequestId();
        uint256 firstPending = end;
        for (uint256 id = 1; id < end; ++id) {
            if (vault.getRequest(id).sharesPending != 0) {
                firstPending = id;
                break;
            }
        }
        for (uint256 id = firstPending + 1; id < end; ++id) {
            assertEq(handler.ghostFinalizedShares(id), 0, "later request finalized before earlier pending one");
        }
    }

    /// Deposits, redemptions, finalization, cancellation and claims never reduce N_a / S for remaining shares.
    function invariant_noDilutionByLpOperations() public view {
        assertFalse(handler.perShareDecreased(), "per-share basket decreased");
    }

    /// N = B - W, F = N - Q, D = ceil(P N / S), admission = N - Q - R - D, all recomputed from raw
    /// PoolManager balances, request storage and allocation storage; and N0 + N1 > 0 while shares exist.
    function invariant_equationsFromRawSources() public view {
        _assertEquationsWith(handler.ghostDonated(c0), handler.ghostDonated(c1));
    }

    /// Every successful action moved real ERC-20 / ERC-6909 balances by exactly its accounting change;
    /// W_a changed only through finalization or claims; no allocation exceeded the admissible capacity; and
    /// admissibleCapacity never reverted, including with a buffer floor near type(uint256).max.
    function invariant_actualBalanceMovementsMatchAccounting() public view {
        assertFalse(handler.balanceMismatch(), "balance movement != accounting change");
        assertFalse(handler.claimableTouched(), "claimable assets changed outside finalize/claim");
        assertFalse(handler.admissionViolated(), "allocation exceeded admissible capacity");
        assertFalse(handler.capacityReverted(), "admissibleCapacity reverted");
    }

    /// INV-P1: every successful swap met max(live vault floor, curator floor) on measured claim deltas.
    function invariant_everyExchangeMeetsEffectiveFloor() public view {
        assertFalse(handler.priceViolated(), "a swap executed below the effective floor");
    }

    /// Directional consistency: F0 * F1 >= 2^192 at all times (no profitable round trip at the floors). The handler
    /// moves floors as close to that boundary as it can, so this checks the vault never let a change cross it.
    function invariant_directionalFloorsConsistent() public view {
        (uint160 f0,) = vault.sellPolicy(c0);
        (uint160 f1,) = vault.sellPolicy(c1);
        assertGt(f0, 0);
        assertGt(f1, 0);
        assertGe(f0, FullMath.mulDivRoundingUp(FixedPoint96.Q96, FixedPoint96.Q96, f1), "crossed floors");
    }

    /// INV-R1: no guardian call ever lowered a floor or resumed a halted direction.
    function invariant_guardianOnlyTightens() public view {
        assertFalse(handler.guardianLoosened(), "guardian loosened a risk limit");
    }

    /// @dev Logged (not asserted) per run; only the final run's log is printed by forge.
    function afterInvariant() public view {
        console2.log("alloc/swap/release:", handler.allocationsOk(), handler.swapsOk(), handler.releasesOk());
        console2.log("deposit/instant/queued:", handler.depositsOk(), handler.instantOk(), handler.queuedOk());
        console2.log("finalize/claim/cancel:", handler.finalizedOk(), handler.claimsOk(), handler.cancelsOk());
        console2.log(
            "donate/drain/zeroAssetStates:", handler.donationsOk(), handler.drainsOk(), handler.zeroAssetStatesSeen()
        );
        console2.log(
            "floorChanges/halts/guardianRefusals:",
            handler.floorChangesOk(),
            handler.haltsOk(),
            handler.guardianRefusals()
        );
        console2.log("bufferChanges:", handler.bufferChangesOk());
    }

    /// @notice Guards against a vacuous campaign: a fixed handler sequence must actually exercise every path,
    ///         including a zero-asset state and a donation, through the real PoolManager.
    function test_handler_makesProgress() public {
        handler.allocate(0, 10_000 ether, 1 days); // hookA, out token0
        handler.allocate(3, 10_000 ether, 1 days); // hookB, out token1
        handler.swap(0, 100 ether);
        handler.swap(1, 100 ether);
        assertEq(handler.allocationsOk(), 2);
        assertEq(handler.swapsOk(), 2);
        handler.deposit(1, 50_000 ether);
        assertEq(handler.depositsOk(), 1);
        handler.redeem(1, 7, false);
        assertEq(handler.instantOk(), 1);
        handler.donate(true, 5 ether);
        assertEq(handler.donationsOk(), 1);

        // Reserve most token1 so that large redemptions must queue.
        handler.allocate(3, 1_500_000 ether, 1 days);
        assertEq(handler.allocationsOk(), 3);
        handler.redeem(0, vault.sharesOf(lp0), true); // partially instant, remainder queued as request 1
        handler.redeem(2, vault.sharesOf(handler.lps(2)), true); // queue non-empty: fully queued, request 2
        assertEq(handler.queuedOk(), 2);
        handler.cancel(1); // id = 1 + 1 % 2 = request 2
        assertEq(handler.cancelsOk(), 1);
        handler.warp(2 days);
        for (uint256 i; i < 3; ++i) {
            handler.release(i, false);
        }
        handler.process(5);
        assertEq(handler.finalizedOk(), 1);
        handler.claim(0); // request 1
        assertEq(handler.claimsOk(), 1);

        handler.drain(1); // sell all admissible token1 at 1:1
        assertEq(handler.drainsOk(), 1);
        assertEq(vault.netAssets(c1), 0, "zero-asset state reached");
        handler.deposit(3, 1000 ether); // deposits into a depleted asset
        handler.redeem(3, 1000 ether, true);

        invariant_backingEqualsRealClaims();
        invariant_ghostLedgerConservation();
        invariant_reservedIsExactAndBacked();
        invariant_custodyAndSolvency();
        invariant_sharesAndQueueConserved();
        invariant_noDoubleClaim();
        invariant_fifoOrdering();
        invariant_noDilutionByLpOperations();
        invariant_equationsFromRawSources();
        invariant_actualBalanceMovementsMatchAccounting();

        // Price-policy actions: each path is exercised and the policy invariants hold.
        handler.allocate(3, 10_000 ether, 1 days); // fresh hookB allocation, token1 out
        uint256 swapsBefore = handler.swapsOk();
        handler.guardianTighten(true, 200); // token1 floor +2%: above HookB's 1:1-minus-impact quote
        handler.swap(handler.allocationCount() - 1, 100 ether);
        assertEq(handler.swapsOk(), swapsBefore, "swap below the tightened floor must fail");
        handler.guardianTryLoosen(true, 100);
        handler.guardianHalt(false);
        handler.guardianTryLoosen(false, 100); // includes a resume attempt
        assertEq(handler.guardianRefusals(), 3);
        handler.ownerResume(false);
        handler.ownerLoosen(true, 2000); // back towards 1:1 (bounded by D14)
        assertEq(handler.floorChangesOk(), 2);
        assertEq(handler.haltsOk(), 1);
        invariant_everyExchangeMeetsEffectiveFloor();
        invariant_directionalFloorsConsistent();
        invariant_guardianOnlyTightens();
    }
}
