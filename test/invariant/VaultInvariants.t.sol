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
import {VaultLens} from "../../src/VaultLens.sol";
import {CuratorAuthorization} from "../../src/CuratorAuthorization.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {AuthModeHook} from "../utils/AuthModeHook.sol";
import {ClaimDonor} from "../utils/ClaimDonor.sol";

/// @notice Random action sequences against the real PoolManager: allocations by three curators, swaps through three
///         hooks (HookA, HookB, a 1:1 test hook that can drain an asset to zero), time, releases, curator
///         cancellations, curator registration, deregistration, freeze, unfreeze, revocation and generation bumps,
///         owner and guardian rotation, ERC-6909 donations, multi-LP deposits, instant/queued redemptions (with
///         inline queue processing), queue processing, request cancellations and claims. Each action may revert; the invariants must hold after every step, and each
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
    CuratorAuthorization internal auth;
    VaultLens internal lens = new VaultLens();
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

    // Curator lifecycle. curators[0] is never revoked by the handler, so the campaign keeps a curator that can
    // allocate; curators[1] and curators[2] can be revoked.
    address[] public curators;
    /// Highest generation observed per curator; the vault's value must never be below it (INV-C1).
    mapping(address => uint32) public ghostGeneration;
    /// Set once a curator is observed revoked; it must stay revoked and unregistered (INV-C2).
    mapping(address => bool) public ghostRevoked;
    /// Per allocation: closed by a handler action, and its `consumed` at that moment (INV-A3).
    mapping(uint256 => bool) public ghostClosed;
    mapping(uint256 => uint256) public ghostConsumedAtClose;
    bool public generationDecreased; // a curator's generation went down
    bool public restrictedConsumption; // INV-C4: a swap succeeded against a frozen or revoked curator's allocation
    bool public restrictedCreation; // an allocation was created by an unregistered, frozen or revoked curator
    bool public curatorActionMovedState; // INV-C5: a curator-state action changed assets, shares, queue or Q_a
    bool public closeMismatch; // a close released != maxOut - consumed, closed twice, or was made by a wrong caller
    bool public guardianRaisedAuthority; // the guardian registered or unfroze a curator
    uint256 public registrationsOk;
    uint256 public deregistrationsOk;
    uint256 public freezesOk;
    uint256 public unfreezesOk;
    uint256 public revokesOk;
    uint256 public bumpsOk;
    uint256 public allocationCancelsOk;
    uint256 public curatorRefusals;
    uint256 public restrictedSwapsRejected;
    uint256 public rotations;
    address[2] internal owners;
    address[2] internal guardians;

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

    /// @dev Called once by the invariant contract's setUp (not a fuzz target): the installed module.
    function setAuth(CuratorAuthorization auth_) external {
        auth = auth_;
    }

    /// @dev Called once by the invariant contract's setUp (not a fuzz target). `owner2` and `guardian2` are the
    ///      alternates that `rotateOwner` and `rotateGuardian` switch to and from.
    function setLifecycle(address[] calldata curators_, address owner2, address guardian2) external {
        curators = curators_;
        owners = [owner, owner2];
        guardians = [guardian, guardian2];
    }

    function curatorCount() external view returns (uint256) {
        return curators.length;
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
        address who = curators.length == 0 ? curator : curators[(seed >> 2) % curators.length];
        // Three in four calls use a curator that can currently allocate (if there is one), so that lifecycle
        // actions do not starve the swap paths; the rest keep trying arbitrary curators, restricted ones included.
        if (curators.length != 0 && (seed >> 4) % 4 != 0 && !_canAllocate(who)) {
            for (uint256 i; i < curators.length; ++i) {
                if (_canAllocate(curators[i])) {
                    who = curators[i];
                    break;
                }
            }
        }
        _allocate(who, key, out, bound(maxOut, 1 ether, 1_500_000 ether), bound(lifetime, 1, 30 days));
    }

    function _canAllocate(address c) internal view returns (bool) {
        ISharedCommitmentVault.CuratorRecord memory r = vault.getCurator(c);
        return r.registered && r.restriction == ISharedCommitmentVault.CuratorRestriction.None;
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
        uint256 id = _allocate(curator, keyE, out, q, 1 days);
        if (id == 0) return;
        if (_swap(keyE, out == c1, q, id)) drainsOk++;
        if (lens.netAssets(vault, c0) == 0 || lens.netAssets(vault, c1) == 0) zeroAssetStatesSeen++;
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
            ? type(uint256).max - bound(value, 0, vault.reserved(c) + lens.pendingDemand(vault, c))
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
        ISharedCommitmentVault.Allocation memory a = vault.getAllocation(id);
        bool revoked = vault.getCurator(a.curator).restriction == ISharedCommitmentVault.CuratorRestriction.Revoked;
        uint256 q = vault.reserved(a.currencyOut);
        uint256 cr = vault.curatorReserved(a.curator, a.currencyOut);
        Snap memory p = _take();
        vm.prank(asOwner ? owner : address(0xBEEF));
        try vault.release(id) {
            releasesOk++;
            // A stranger may only release an expired allocation or one of a revoked curator.
            if (!asOwner && block.timestamp < a.expiry && !revoked) closeMismatch = true;
            _recordClose(id, a, q, cr);
            _checkBalancesFollowBacking(p);
            _checkWUnchanged(p);
            if (vault.backing(c0) != p.b0 || vault.backing(c1) != p.b1) balanceMismatch = true;
        } catch {}
    }

    // ------------------------------------------------------------------
    // Curator lifecycle actions
    // ------------------------------------------------------------------

    /// @notice Owner registers a curator, or the guardian tries to (must always be refused).
    function curatorRegister(uint256 seed, bool asGuardian) external {
        address c = curators[seed % curators.length];
        bytes32 before = _lifecycleSnap();
        vm.prank(asGuardian ? guardian : owner);
        try vault.setCurator(c, true) {
            registrationsOk++;
            if (asGuardian) guardianRaisedAuthority = true;
        } catch {
            curatorRefusals++;
        }
        _afterCuratorAction(before);
    }

    function curatorDeregister(uint256 seed, bool asGuardian) external {
        address c = curators[seed % curators.length];
        bytes32 before = _lifecycleSnap();
        vm.prank(asGuardian ? guardian : owner);
        try vault.setCurator(c, false) {
            deregistrationsOk++;
        } catch {
            curatorRefusals++;
        }
        _afterCuratorAction(before);
    }

    function curatorFreeze(uint256 seed, bool asGuardian) external {
        address c = curators[seed % curators.length];
        bytes32 before = _lifecycleSnap();
        vm.prank(asGuardian ? guardian : owner);
        try vault.freezeCurator(c) {
            freezesOk++;
        } catch {
            curatorRefusals++;
        }
        _afterCuratorAction(before);
    }

    /// @notice Owner lifts a freeze, or the guardian tries to (must always be refused).
    function curatorUnfreeze(uint256 seed, bool asGuardian) external {
        address c = curators[seed % curators.length];
        bytes32 before = _lifecycleSnap();
        vm.prank(asGuardian ? guardian : owner);
        try vault.unfreezeCurator(c) {
            unfreezesOk++;
            if (asGuardian) guardianRaisedAuthority = true;
        } catch {
            curatorRefusals++;
        }
        _afterCuratorAction(before);
    }

    /// @notice Revokes curators[1] or curators[2] (never curators[0], so allocations stay possible).
    function curatorRevoke(uint256 seed, bool asGuardian) external {
        address c = curators[1 + seed % (curators.length - 1)];
        bytes32 before = _lifecycleSnap();
        vm.prank(asGuardian ? guardian : owner);
        try vault.revokeCurator(c) {
            revokesOk++;
        } catch {
            curatorRefusals++;
        }
        _afterCuratorAction(before);
    }

    function curatorBump(uint256 seed) external {
        address c = curators[seed % curators.length];
        bytes32 before = _lifecycleSnap();
        vm.prank(c);
        try vault.bumpGeneration() {
            bumpsOk++;
        } catch {
            curatorRefusals++;
        }
        _afterCuratorAction(before);
    }

    /// @notice The allocation's curator cancels it, or another curator tries to (must always be refused).
    function cancelAllocation(uint256 idSeed, bool byOther) external {
        if (allocationIds.length == 0) return;
        uint256 id = allocationIds[idSeed % allocationIds.length];
        ISharedCommitmentVault.Allocation memory a = vault.getAllocation(id);
        address caller = byOther ? (a.curator == curators[0] ? curators[1] : curators[0]) : a.curator;
        uint256 q = vault.reserved(a.currencyOut);
        uint256 cr = vault.curatorReserved(a.curator, a.currencyOut);
        Snap memory p = _take();
        vm.prank(caller);
        try vault.cancelAllocation(id) {
            allocationCancelsOk++;
            if (caller != a.curator) closeMismatch = true;
            _recordClose(id, a, q, cr);
            if (vault.backing(c0) != p.b0 || vault.backing(c1) != p.b1) balanceMismatch = true;
            _checkBalancesFollowBacking(p);
            _checkWUnchanged(p);
        } catch {}
    }

    /// @notice Two-step ownership transfer to the other owner address. Nothing about curators may change.
    function rotateOwner() external {
        address next = owner == owners[0] ? owners[1] : owners[0];
        bytes32 before = _lifecycleSnap();
        vm.prank(owner);
        vault.transferOwnership(next);
        vm.prank(next);
        vault.acceptOwnership();
        owner = next;
        rotations++;
        if (_lifecycleSnap() != before) curatorActionMovedState = true;
        _checkCuratorGhosts();
    }

    function rotateGuardian() external {
        address next = guardian == guardians[0] ? guardians[1] : guardians[0];
        bytes32 before = _lifecycleSnap();
        vm.prank(owner);
        vault.setGuardian(next);
        guardian = next;
        rotations++;
        if (_lifecycleSnap() != before) curatorActionMovedState = true;
        _checkCuratorGhosts();
    }

    // ------------------------------------------------------------------
    // LP actions
    // ------------------------------------------------------------------

    function deposit(uint256 lpSeed, uint256 shares) external {
        address lp = lps[lpSeed % lps.length];
        shares = bound(shares, 1, 200_000 ether);
        (uint256 a0, uint256 a1) = lens.previewDeposit(vault, shares);
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

    /// @dev Checks one successful close against the values read just before it: the allocation was not closed
    ///      before, and Q_out and the curator's reserved total fell by exactly maxOut - consumed.
    function _recordClose(uint256 id, ISharedCommitmentVault.Allocation memory a, uint256 q, uint256 cr) internal {
        if (ghostClosed[id] || a.released) closeMismatch = true;
        uint256 unused = a.maxOut - a.consumed;
        if (q - vault.reserved(a.currencyOut) != unused) closeMismatch = true;
        if (cr - vault.curatorReserved(a.curator, a.currencyOut) != unused) closeMismatch = true;
        if (!vault.getAllocation(id).released) closeMismatch = true;
        ghostClosed[id] = true;
        ghostConsumedAtClose[id] = a.consumed;
    }

    /// @dev Hash of everything a curator-state action must leave alone: real claim and ERC-20 balances, B_a, W_a,
    ///      Q_a, every curator's reserved totals, S, P, the queue head and the number of allocations and requests.
    function _lifecycleSnap() internal view returns (bytes32) {
        bytes memory reservedTotals;
        for (uint256 i; i < curators.length; ++i) {
            reservedTotals = abi.encode(
                reservedTotals, vault.curatorReserved(curators[i], c0), vault.curatorReserved(curators[i], c1)
            );
        }
        return keccak256(
            abi.encode(
                _take(),
                vault.reserved(c0),
                vault.reserved(c1),
                vault.pendingShares(),
                vault.queueHead(),
                vault.nextRequestId(),
                vault.nextAllocationId(),
                _erc20(c0, address(manager)),
                _erc20(c1, address(manager)),
                reservedTotals
            )
        );
    }

    function _afterCuratorAction(bytes32 before) internal {
        if (_lifecycleSnap() != before) curatorActionMovedState = true;
        _checkCuratorGhosts();
    }

    /// @dev INV-C1 and INV-C2 at the moment of each curator action, for every curator.
    function _checkCuratorGhosts() internal {
        for (uint256 i; i < curators.length; ++i) {
            address c = curators[i];
            ISharedCommitmentVault.CuratorRecord memory r = vault.getCurator(c);
            if (r.generation < ghostGeneration[c]) generationDecreased = true;
            ghostGeneration[c] = r.generation;
            if (ghostRevoked[c]) {
                if (r.restriction != ISharedCommitmentVault.CuratorRestriction.Revoked || r.registered) {
                    ghostRevoked[c] = false; // record the escape; the invariant reads `revokedEscaped`
                    revokedEscaped = true;
                }
            }
            if (r.restriction == ISharedCommitmentVault.CuratorRestriction.Revoked) ghostRevoked[c] = true;
        }
    }

    bool public revokedEscaped; // INV-C2: a revoked curator became unrevoked or registered

    // ------------------------------------------------------------------
    // Risk limits: flow ghosts, exposure, configuration
    // ------------------------------------------------------------------

    /// Ghost flow model, per record key(scope, account, currency): the window of the last successful swap that paid
    /// under it and the total MEASURED output (the vault's ERC-6909 balance drop) paid in that window. Built only from
    /// swaps the handler saw succeed, never from the vault's records, so `invariant_flowUsageMatchesGhost` catches any
    /// path other than a successful swap that changes usage (an LP operation, a close, a curator action, a
    /// configuration change, a reverted swap that left a write behind).
    mapping(bytes32 => uint256) internal ghostFlowWindow;
    mapping(bytes32 => uint256) internal ghostFlowUsed;
    bool public flowOverCap; // after a successful swap some record's usage was above its cap
    bool public exposureViolated; // after a successful allocate some scope held more than bps * E / 10,000
    bool public guardianLoosenedRisk; // the guardian raised a cap or bps, or configured a new record
    uint256 public flowRefusals;
    uint256 public riskSetsOk;
    uint256 public riskTightensOk;
    uint256 public riskRefusals;

    /// @dev The 14 records the campaign uses: 7 (scope, account) pairs times 2 assets. idx % 2 picks the asset.
    function riskRecord(uint256 idx)
        public
        view
        returns (ISharedCommitmentVault.RiskScope scope, address account, Currency currency)
    {
        idx %= 14;
        currency = idx % 2 == 0 ? c0 : c1;
        uint256 r = idx / 2;
        if (r == 0) return (ISharedCommitmentVault.RiskScope.Vault, address(0), currency);
        if (r <= 3) {
            address h = r == 1 ? address(keyA.hooks) : r == 2 ? address(keyB.hooks) : address(keyE.hooks);
            return (ISharedCommitmentVault.RiskScope.Hook, h, currency);
        }
        return (ISharedCommitmentVault.RiskScope.Curator, curators[r - 4], currency);
    }

    /// @dev Expected current-window usage of a record according to the ghost model.
    function ghostFlow(ISharedCommitmentVault.RiskScope scope, address account, Currency currency)
        public
        view
        returns (uint256)
    {
        bytes32 k = keccak256(abi.encode(scope, account, currency));
        return ghostFlowWindow[k] == vm.getBlockTimestamp() / vault.FLOW_WINDOW() ? ghostFlowUsed[k] : 0;
    }

    /// @notice Owner sets one record. One call in four sets small values so that limits actually bind; the rest
    ///         keep paths open enough for the other properties to be exercised.
    function riskOwnerSet(uint256 idx, uint256 cap, uint256 bps) external {
        (ISharedCommitmentVault.RiskScope scope, address account, Currency c) = riskRecord(idx);
        bool tight = (idx >> 8) % 4 == 0;
        cap = tight ? bound(cap, 0, 300_000 ether) : bound(cap, 300_000 ether, type(uint104).max);
        bps = tight ? bound(bps, 0, 5000) : bound(bps, 5000, 10_000);
        vm.prank(owner);
        // forge-lint: disable-next-line(unsafe-typecast)
        vault.setRiskLimit(scope, account, c, cap, uint16(bps));
        riskSetsOk++;
    }

    /// @notice Guardian lowers a configured record. Neither value may rise and usage may not change.
    function riskGuardianTighten(uint256 idx, uint256 capBps, uint256 bpsBps) external {
        (ISharedCommitmentVault.RiskScope scope, address account, Currency c) = riskRecord(idx);
        ISharedCommitmentVault.RiskLimit memory r = vault.getRiskLimit(scope, account, c);
        uint256 cap = uint256(r.flowCap) * bound(capBps, 5000, 10_000) / 10_000;
        uint256 bps = uint256(r.maxReservedBps) * bound(bpsBps, 5000, 10_000) / 10_000;
        vm.prank(guardian);
        // forge-lint: disable-next-line(unsafe-typecast)
        try vault.setRiskLimit(scope, account, c, cap, uint16(bps)) {
            riskTightensOk++;
        } catch {
            riskRefusals++;
        }
        ISharedCommitmentVault.RiskLimit memory q = vault.getRiskLimit(scope, account, c);
        if (q.flowCap > r.flowCap || q.maxReservedBps > r.maxReservedBps) guardianLoosenedRisk = true;
    }

    /// @notice Guardian ATTEMPTS to raise a cap or bps, or to configure a record that was never set: always refused.
    function riskGuardianTryLoosen(uint256 idx, bool fresh) external {
        (ISharedCommitmentVault.RiskScope scope, address account, Currency c) = riskRecord(idx);
        if (fresh) {
            scope = ISharedCommitmentVault.RiskScope.Hook;
            account = address(uint160(uint256(keccak256(abi.encode(idx)))) | 1);
        }
        ISharedCommitmentVault.RiskLimit memory r = vault.getRiskLimit(scope, account, c);
        bool raiseCap = r.flowCap < type(uint104).max && (idx % 2 == 0 || r.maxReservedBps == 10_000);
        uint256 cap = raiseCap ? uint256(r.flowCap) + 1 : r.flowCap;
        uint16 bps = !raiseCap && r.maxReservedBps < 10_000 ? r.maxReservedBps + 1 : r.maxReservedBps;
        if (r.configured && cap == r.flowCap && bps == r.maxReservedBps) return; // nothing to loosen
        vm.prank(guardian);
        try vault.setRiskLimit(scope, account, c, cap, bps) {
            guardianLoosenedRisk = true;
        } catch {
            riskRefusals++;
        }
    }

    /// @dev Adds a measured output to the ghost model of the three records the swap paid under, then compares each
    ///      with the vault and checks usage <= cap.
    function _recordFlow(address hook, address allocCurator, Currency cout, uint256 out) internal {
        uint256 w = vm.getBlockTimestamp() / vault.FLOW_WINDOW();
        ISharedCommitmentVault.RiskScope[3] memory scopes = [
            ISharedCommitmentVault.RiskScope.Hook,
            ISharedCommitmentVault.RiskScope.Curator,
            ISharedCommitmentVault.RiskScope.Vault
        ];
        address[3] memory accounts = [hook, allocCurator, address(0)];
        for (uint256 i; i < 3; ++i) {
            bytes32 k = keccak256(abi.encode(scopes[i], accounts[i], cout));
            if (ghostFlowWindow[k] != w) {
                ghostFlowWindow[k] = w;
                ghostFlowUsed[k] = 0;
            }
            ghostFlowUsed[k] += out;
            ISharedCommitmentVault.RiskLimit memory r = vault.getRiskLimit(scopes[i], accounts[i], cout);
            if (r.flowUsed > r.flowCap) flowOverCap = true;
        }
    }

    /// @dev Exposure after a successful allocate: for each scope, held * 10,000 <= bps * E_a. E_a is unchanged by
    ///      `allocate`, so reading it afterwards gives the value the vault used.
    function _checkExposure(address hook, address who, Currency out) internal {
        uint256 e = lens.eligibleBacking(vault, out);
        uint256[3] memory held = [vault.hookReserved(hook, out), vault.curatorReserved(who, out), vault.reserved(out)];
        ISharedCommitmentVault.RiskScope[3] memory scopes = [
            ISharedCommitmentVault.RiskScope.Hook,
            ISharedCommitmentVault.RiskScope.Curator,
            ISharedCommitmentVault.RiskScope.Vault
        ];
        address[3] memory accounts = [hook, who, address(0)];
        for (uint256 i; i < 3; ++i) {
            ISharedCommitmentVault.RiskLimit memory r = vault.getRiskLimit(scopes[i], accounts[i], out);
            if (!r.configured || held[i] * 10_000 > uint256(r.maxReservedBps) * e) exposureViolated = true;
        }
    }

    function _isFlowRefusal(bytes memory err) internal pure returns (bool) {
        // The PoolManager wraps the hook's revert; the vault's selector appears inside the wrapped reason.
        bytes4 sel = ISharedCommitmentVault.FlowLimitExceeded.selector;
        for (uint256 i; i + 4 <= err.length; ++i) {
            if (err[i] == sel[0] && err[i + 1] == sel[1] && err[i + 2] == sel[2] && err[i + 3] == sel[3]) return true;
        }
        return false;
    }

    function _claimsOf(Currency c) internal view returns (uint256) {
        return manager.balanceOf(address(vault), c.toId());
    }

    function _allocate(address who, PoolKey memory key, Currency out, uint256 maxOut, uint256 lifetime)
        internal
        returns (uint256 id)
    {
        ISharedCommitmentVault.AllocationRequest memory req = ISharedCommitmentVault.AllocationRequest({
            consumer: address(key.hooks),
            key: key,
            currencyOut: out,
            // forge-lint: disable-next-line(unsafe-typecast)
            maxOut: uint128(maxOut),
            minInPerOutX96: _curatorFloor(out), // must be >= the live vault floor or reserveFor reverts
            expiry: uint64(block.timestamp + lifetime),
            nonce: nonce++,
            deadline: uint64(block.timestamp)
        });
        uint256 admissible = vault.admissibleCapacity(out);
        ISharedCommitmentVault.CuratorRecord memory rec = vault.getCurator(who);
        Snap memory p = _take();
        vm.prank(who);
        try auth.activateDirect(req) returns (uint256 newId) {
            id = newId;
            allocationIds.push(id);
            allocationsOk++;
            if (!rec.registered || rec.restriction != ISharedCommitmentVault.CuratorRestriction.None) {
                restrictedCreation = true;
            }
            if (maxOut > admissible) admissionViolated = true;
            _checkExposure(address(key.hooks), who, out);
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
        address allocCurator = vault.getAllocation(id).curator;
        bool restricted = vault.getCurator(allocCurator).restriction != ISharedCommitmentVault.CuratorRestriction.None;
        Currency cout = zeroForOne ? c1 : c0;
        uint256 feff;
        try lens.effectiveFloorX96(vault, id) returns (uint256 f) {
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
            _recordFlow(
                address(key.hooks), allocCurator, cout, zeroForOne ? p.pm1 - _claimsOf(c1) : p.pm0 - _claimsOf(c0)
            );
            ghostBacking[zeroForOne ? c0 : c1] += amountIn;
            // forge-lint: disable-next-line(unsafe-typecast)
            ghostBacking[cout] -= uint256(int256(outDelta));
            swapsOk++;
            ok = true;
            if (restricted) restrictedConsumption = true;
            if (ghostClosed[id]) closeMismatch = true; // a closed allocation was consumed
            _checkEffectiveFloor(p, zeroForOne, feff);
            _checkBalancesFollowBacking(p);
            _checkWUnchanged(p);
        } catch (bytes memory err) {
            if (restricted) restrictedSwapsRejected++;
            if (_isFlowRefusal(err)) flowRefusals++;
        }
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
        p.n0 = lens.netAssets(vault, c0);
        p.n1 = lens.netAssets(vault, c1);
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
        if (lens.netAssets(vault, c0) * p.s < p.n0 * s2 || lens.netAssets(vault, c1) * p.s < p.n1 * s2) {
            perShareDecreased = true;
        }
    }
}

contract VaultInvariantsTest is VaultTestBase {
    VaultHandler internal handler;
    PoolKey internal keyE;
    address internal guardianAddr = makeAddr("guardian");
    address internal curator2 = makeAddr("curator2");
    address internal curator3 = makeAddr("curator3");

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
        vault.setCurator(curator2, true);
        vault.setCurator(curator3, true);
        _openLimits(ISharedCommitmentVault.RiskScope.Hook, e);
        _openLimits(ISharedCommitmentVault.RiskScope.Curator, curator2);
        _openLimits(ISharedCommitmentVault.RiskScope.Curator, curator3);
        vault.setCuratorCeiling(curator2, c0, type(uint256).max);
        vault.setCuratorCeiling(curator2, c1, type(uint256).max);
        vault.setCuratorCeiling(curator3, c0, 500_000 ether);
        vault.setCuratorCeiling(curator3, c1, 500_000 ether);
        vm.stopPrank();
        handler.setGuardian(guardianAddr);
        handler.setAuth(auth);
        address[] memory cs = new address[](3);
        cs[0] = curator;
        cs[1] = curator2;
        cs[2] = curator3;
        handler.setLifecycle(cs, makeAddr("owner2"), makeAddr("guardian2"));

        bytes4[] memory selectors = new bytes4[](31);
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
        selectors[18] = VaultHandler.allocate.selector; // allocation weighted x2: lifecycle actions block some
        selectors[19] = VaultHandler.curatorRegister.selector;
        selectors[20] = VaultHandler.curatorDeregister.selector;
        selectors[21] = VaultHandler.curatorFreeze.selector;
        selectors[22] = VaultHandler.curatorUnfreeze.selector;
        selectors[23] = VaultHandler.curatorRevoke.selector;
        selectors[24] = VaultHandler.curatorBump.selector;
        selectors[25] = VaultHandler.cancelAllocation.selector;
        selectors[26] = VaultHandler.rotateOwner.selector;
        selectors[27] = VaultHandler.rotateGuardian.selector;
        selectors[28] = VaultHandler.riskOwnerSet.selector;
        selectors[29] = VaultHandler.riskGuardianTighten.selector;
        selectors[30] = VaultHandler.riskGuardianTryLoosen.selector;
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

    /// Q_a == Σ over unreleased allocations of (maxOut - consumed), each curator's reserved total is the same sum
    /// over its own allocations (INV-A2), and Q_a + W_a <= B_a. Frozen and revoked curators' unreleased
    /// allocations are included: their capacity stays reserved until each one is closed.
    function invariant_reservedIsExactAndBacked() public view {
        uint256 sum0;
        uint256 sum1;
        uint256 nc = handler.curatorCount();
        uint256[2][] memory perCurator = new uint256[2][](nc);
        uint256 n = handler.allocationCount();
        for (uint256 i; i < n; ++i) {
            ISharedCommitmentVault.Allocation memory a = vault.getAllocation(handler.allocationIds(i));
            assertLe(a.consumed, a.maxOut, "consumed > maxOut");
            if (a.released) continue;
            uint256 unused = a.maxOut - a.consumed;
            uint256 k = a.currencyOut == c0 ? 0 : 1;
            if (k == 0) sum0 += unused;
            else sum1 += unused;
            for (uint256 j; j < nc; ++j) {
                if (handler.curators(j) == a.curator) perCurator[j][k] += unused;
            }
        }
        assertEq(vault.reserved(c0), sum0, "reserved0");
        assertEq(vault.reserved(c1), sum1, "reserved1");
        for (uint256 j; j < nc; ++j) {
            assertEq(vault.curatorReserved(handler.curators(j), c0), perCurator[j][0], "curatorReserved0");
            assertEq(vault.curatorReserved(handler.curators(j), c1), perCurator[j][1], "curatorReserved1");
        }
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

    /// VaultLens previews equal what the vault actually does in the current state. Each operation runs for real on
    /// a snapshot that is rolled back afterwards, so the campaign state is not changed:
    ///   - `deposit` charges exactly `previewDeposit`;
    ///   - with an empty queue, `redeem` pays min(balance, `deliverableShares`) instantly, and pays
    ///     `previewRedeem` of that slice (or queues everything, or reverts as dust, exactly when the model says so);
    ///   - with a non-empty queue, `processQueue(1)` finalizes min(head pending, `deliverableShares`) shares of the
    ///     head request for `previewRedeem` of them.
    /// A divergence would mean the lens repeats a formula or rounding of the vault incorrectly.
    function invariant_lensPreviewsMatchExecution() public {
        uint256 snap = vm.snapshotState();
        if (!vault.paused()) {
            address probe = makeAddr("lensProbe");
            uint256 shares = vault.totalShares() / 100 + 1;
            (uint256 p0, uint256 p1) = lens.previewDeposit(vault, shares);
            _fundLp(probe, p0, p1);
            vm.prank(probe);
            (uint256 a0, uint256 a1) = vault.deposit(shares, p0, p1, probe);
            assertEq(a0, p0, "deposit asset0 != previewDeposit");
            assertEq(a1, p1, "deposit asset1 != previewDeposit");
            vm.revertToState(snap);
            snap = vm.snapshotState();
        }
        if (vault.pendingShares() == 0) {
            _checkInstantRedeemMatchesLens();
        } else {
            _checkHeadFinalizationMatchesLens();
        }
        vm.revertToState(snap);
    }

    function _checkInstantRedeemMatchesLens() internal {
        uint256 bal = vault.sharesOf(lp0);
        if (bal == 0) return;
        uint256 d = lens.deliverableShares(vault);
        uint256 inst = bal < d ? bal : d;
        (uint256 e0, uint256 e1) = lens.previewRedeem(vault, inst);
        bool dust;
        if (inst != 0 && e0 == 0 && e1 == 0) {
            if (inst == bal) dust = true;
            else inst = 0;
        }
        if (!dust && inst < bal) {
            (uint256 r0, uint256 r1) = lens.previewRedeem(vault, bal - inst);
            dust = r0 == 0 && r1 == 0;
        }
        if (inst == 0) (e0, e1) = (0, 0);
        vm.prank(lp0);
        try vault.redeem(bal, 0, 0, lp0, true) returns (uint256 got, uint256 a0, uint256 a1, uint256) {
            assertFalse(dust, "redeem succeeded where the lens model predicts a dust revert");
            assertEq(got, inst, "instant shares != min(balance, deliverableShares)");
            assertEq(a0, e0, "instant asset0 != previewRedeem");
            assertEq(a1, e1, "instant asset1 != previewRedeem");
        } catch (bytes memory reason) {
            assertTrue(dust, "redeem reverted where the lens model predicts success");
            assertEq(bytes4(reason), ISharedCommitmentVault.DustRedemption.selector, "unexpected redeem revert");
        }
    }

    function _checkHeadFinalizationMatchesLens() internal {
        uint256 head = vault.queueHead();
        ISharedCommitmentVault.WithdrawalRequest memory r = vault.getRequest(head);
        if (r.sharesPending == 0) return; // processQueue(1) would only skip this entry
        uint256 d = lens.deliverableShares(vault);
        uint256 s = r.sharesPending < d ? r.sharesPending : d;
        (uint256 e0, uint256 e1) = lens.previewRedeem(vault, s);
        bool finalizes = s != 0 && !(e0 == 0 && e1 == 0 && s < r.sharesPending);
        assertEq(vault.processQueue(1), finalizes ? s : 0, "finalized shares != min(pending, deliverableShares)");
        ISharedCommitmentVault.WithdrawalRequest memory after_ = vault.getRequest(head);
        assertEq(after_.claimable0 - r.claimable0, finalizes ? e0 : 0, "finalized asset0 != previewRedeem");
        assertEq(after_.claimable1 - r.claimable1, finalizes ? e1 : 0, "finalized asset1 != previewRedeem");
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

    /// INV-C1: no curator's generation ever decreased, and each is at least the highest value the handler saw.
    function invariant_generationMonotonic() public view {
        assertFalse(handler.generationDecreased(), "generation decreased");
        for (uint256 i; i < handler.curatorCount(); ++i) {
            address c = handler.curators(i);
            assertGe(vault.getCurator(c).generation, handler.ghostGeneration(c), "generation below ghost");
        }
    }

    /// INV-C2: once revoked, a curator stays revoked and unregistered, across owner and guardian rotations.
    function invariant_revokedIsTerminal() public view {
        assertFalse(handler.revokedEscaped(), "revoked curator escaped");
        for (uint256 i; i < handler.curatorCount(); ++i) {
            address c = handler.curators(i);
            if (!handler.ghostRevoked(c)) continue;
            ISharedCommitmentVault.CuratorRecord memory r = vault.getCurator(c);
            assertEq(uint8(r.restriction), uint8(ISharedCommitmentVault.CuratorRestriction.Revoked));
            assertFalse(r.registered, "revoked curator registered");
        }
    }

    /// INV-C4: no swap succeeded against a frozen or revoked curator's allocation, and no allocation was created
    /// by a curator that was unregistered, frozen or revoked at that moment; the guardian never registered or
    /// unfroze a curator.
    function invariant_noConsumptionWhenFrozenOrRevoked() public view {
        assertFalse(handler.restrictedConsumption(), "consumed while frozen or revoked");
        assertFalse(handler.restrictedCreation(), "created while unregistered, frozen or revoked");
        assertFalse(handler.guardianRaisedAuthority(), "guardian raised a curator's authority");
    }

    /// INV-C5: registration, deregistration, freeze, unfreeze, revocation, generation bumps and owner or guardian
    /// rotation never changed assets, B_a, W_a, Q_a, any curator's reserved total, shares or the queue.
    function invariant_curatorActionsMoveNothing() public view {
        assertFalse(handler.curatorActionMovedState(), "a curator-state action moved accounting");
    }

    /// INV-A3: a closed allocation is terminal (still released, `consumed` unchanged since the close), every close
    /// released exactly maxOut - consumed exactly once by an allowed caller, and every released allocation was
    /// closed through an action the handler observed.
    function invariant_closedIsTerminal() public view {
        assertFalse(handler.closeMismatch(), "close accounting or authorization mismatch");
        uint256 n = handler.allocationCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.allocationIds(i);
            ISharedCommitmentVault.Allocation memory a = vault.getAllocation(id);
            assertEq(a.released, handler.ghostClosed(id), "released flag != observed close");
            if (a.released) assertEq(a.consumed, handler.ghostConsumedAtClose(id), "consumed changed after close");
        }
    }

    /// INV-F1: every flow record's current-window usage equals the ghost model built from measured swap outputs.
    /// Only a successful swap changes usage; a new window restarts it at zero.
    function invariant_flowUsageMatchesGhost() public view {
        for (uint256 i; i < 14; ++i) {
            (ISharedCommitmentVault.RiskScope scope, address account, Currency c) = handler.riskRecord(i);
            assertEq(lens.flowUsed(vault, scope, account, c), handler.ghostFlow(scope, account, c), "usage != ghost");
        }
        assertFalse(handler.flowOverCap(), "a successful swap left usage above its cap");
    }

    /// INV-F2: hierarchy. Every swap adds the same output to one hook, one curator and the vault, so in the current
    /// window, per asset, the hooks' usages and the curators' usages each sum to the vault's.
    function invariant_flowHierarchyConsistent() public view {
        Currency[2] memory cs = [c0, c1];
        address[3] memory hooks = [address(keyA.hooks), address(keyB.hooks), address(keyE.hooks)];
        for (uint256 k; k < 2; ++k) {
            uint256 total = lens.flowUsed(vault, ISharedCommitmentVault.RiskScope.Vault, address(0), cs[k]);
            uint256 byHook;
            uint256 byCurator;
            for (uint256 i; i < 3; ++i) {
                byHook += lens.flowUsed(vault, ISharedCommitmentVault.RiskScope.Hook, hooks[i], cs[k]);
                byCurator += lens.flowUsed(vault, ISharedCommitmentVault.RiskScope.Curator, handler.curators(i), cs[k]);
            }
            assertEq(byHook, total, "sum over hooks != vault");
            assertEq(byCurator, total, "sum over curators != vault");
        }
    }

    /// INV-E1: hookReserved is exact per hook and sums to Q_a; every successful allocation respected all three
    /// exposure caps at the moment it was made; the guardian never loosened a risk limit.
    function invariant_exposureAndHookReserved() public view {
        address[3] memory hooks = [address(keyA.hooks), address(keyB.hooks), address(keyE.hooks)];
        uint256[2][3] memory perHook;
        uint256 n = handler.allocationCount();
        for (uint256 i; i < n; ++i) {
            ISharedCommitmentVault.Allocation memory a = vault.getAllocation(handler.allocationIds(i));
            if (a.released) continue;
            for (uint256 j; j < 3; ++j) {
                if (a.consumer == hooks[j]) perHook[j][a.currencyOut == c0 ? 0 : 1] += a.maxOut - a.consumed;
            }
        }
        for (uint256 k; k < 2; ++k) {
            Currency c = k == 0 ? c0 : c1;
            uint256 sum;
            for (uint256 j; j < 3; ++j) {
                assertEq(vault.hookReserved(hooks[j], c), perHook[j][k], "hookReserved != sum of allocations");
                sum += perHook[j][k];
            }
            assertEq(sum, vault.reserved(c), "sum of hookReserved != Q");
        }
        assertFalse(handler.exposureViolated(), "allocation exceeded an exposure cap");
        assertFalse(handler.guardianLoosenedRisk(), "guardian loosened a risk limit");
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
        console2.log(
            "riskSets/riskTightens/riskRefusals:",
            handler.riskSetsOk(),
            handler.riskTightensOk(),
            handler.riskRefusals()
        );
        console2.log("flowRefusals:", handler.flowRefusals());
        console2.log(
            "register/deregister/freeze:", handler.registrationsOk(), handler.deregistrationsOk(), handler.freezesOk()
        );
        console2.log("unfreeze/revoke/bump:", handler.unfreezesOk(), handler.revokesOk(), handler.bumpsOk());
        console2.log(
            "allocCancels/restrictedSwapsRejected/rotations:",
            handler.allocationCancelsOk(),
            handler.restrictedSwapsRejected(),
            handler.rotations()
        );
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
        assertEq(lens.netAssets(vault, c1), 0, "zero-asset state reached");
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

    /// @notice Guards the curator-lifecycle actions against being vacuous: each one must succeed or be refused as
    ///         intended at least once, a frozen and a revoked curator's swaps must be rejected, and cleanup and
    ///         cancellation must close allocations.
    function test_handler_curatorLifecycleProgress() public {
        handler.allocate(0, 10_000 ether, 1 days); // curator0, hookA, token0 out (id index 0)
        handler.allocate(4, 10_000 ether, 1 days); // seed>>2 = 1: curator2, hookA, token0 out (index 1)
        handler.allocate(8, 10_000 ether, 1 days); // seed>>2 = 2: curator3, hookA, token0 out (index 2)
        handler.allocate(4, 10_000 ether, 1 days); // curator2 again (index 3)
        assertEq(handler.allocationsOk(), 4);
        handler.swap(1, 100 ether); // curator2's allocation: partial consumption

        handler.curatorFreeze(1, true); // guardian freezes curator2
        assertEq(handler.freezesOk(), 1);
        handler.swap(1, 100 ether);
        assertEq(handler.restrictedSwapsRejected(), 1, "frozen curator's swap rejected");
        handler.curatorUnfreeze(1, true); // guardian may not unfreeze
        assertEq(handler.unfreezesOk(), 0);
        handler.curatorRegister(1, true); // guardian may not register
        assertEq(handler.registrationsOk(), 0);
        handler.curatorUnfreeze(1, false); // owner may
        assertEq(handler.unfreezesOk(), 1);
        handler.swap(1, 100 ether);

        handler.curatorRevoke(1, true); // guardian revokes curators[1 + 1 % 2] = curator3
        assertEq(handler.revokesOk(), 1);
        handler.swap(2, 100 ether);
        assertEq(handler.restrictedSwapsRejected(), 2, "revoked curator's swap rejected");
        handler.release(2, false); // stranger cleans up the revoked curator's allocation
        assertEq(handler.releasesOk(), 1);
        handler.curatorRegister(2, false); // owner tries to re-register curator3: refused
        assertEq(handler.registrationsOk(), 0);

        handler.cancelAllocation(3, true); // another curator tries to cancel curator2's allocation: refused
        assertEq(handler.allocationCancelsOk(), 0);
        handler.cancelAllocation(3, false); // curator2 cancels its own
        assertEq(handler.allocationCancelsOk(), 1);
        handler.curatorDeregister(1, false);
        handler.curatorBump(0);
        assertEq(handler.deregistrationsOk(), 1);
        assertEq(handler.bumpsOk(), 1);
        handler.rotateOwner();
        handler.rotateGuardian();
        handler.curatorRegister(2, false); // the new owner cannot re-register the revoked curator either
        assertEq(handler.registrationsOk(), 0);
        handler.curatorRegister(1, false); // but can re-register the deregistered one
        assertEq(handler.registrationsOk(), 1);

        invariant_reservedIsExactAndBacked();
        invariant_generationMonotonic();
        invariant_revokedIsTerminal();
        invariant_noConsumptionWhenFrozenOrRevoked();
        invariant_curatorActionsMoveNothing();
        invariant_closedIsTerminal();
        invariant_equationsFromRawSources();
        invariant_actualBalanceMovementsMatchAccounting();
        invariant_backingEqualsRealClaims();
        invariant_ghostLedgerConservation();
    }

    /// @notice The risk-limit actions are not vacuous: a tight vault cap refuses a swap, the next window accepts it,
    ///         the guardian tightens but cannot loosen or configure, and every risk invariant holds along the way.
    function test_handler_riskLimitsProgress() public {
        handler.allocate(3, 100_000 ether, 10 days); // hookB, out token1, curators[0]
        handler.swap(0, 1000 ether);
        assertEq(handler.swapsOk(), 1);
        // Record 1 is (Vault, token1). idx >> 8 == 0 selects tight values: cap bound(1, 0, 300,000 ether) = 1.
        handler.riskOwnerSet(1, 1, 10_000);
        assertEq(vault.getRiskLimit(ISharedCommitmentVault.RiskScope.Vault, address(0), c1).flowCap, 1);
        handler.swap(0, 1000 ether);
        assertEq(handler.flowRefusals(), 1, "cap below the window's usage refuses the swap");
        handler.riskOwnerSet(267, 0, 10_000); // 267 % 14 == 1 (same record), 267 >> 8 == 1: wide, cap 300,000 ether
        handler.swap(0, 1000 ether);
        assertEq(handler.swapsOk(), 2);
        handler.riskGuardianTighten(1, 5000, 10_000);
        assertEq(handler.riskTightensOk(), 1);
        handler.riskGuardianTryLoosen(1, false);
        handler.riskGuardianTryLoosen(1, true);
        assertEq(handler.riskRefusals(), 2);
        handler.warp(1 days);
        handler.swap(0, 1000 ether);
        assertEq(handler.swapsOk(), 3);
        handler.release(0, true);
        invariant_flowUsageMatchesGhost();
        invariant_flowHierarchyConsistent();
        invariant_exposureAndHookReserved();
        invariant_reservedIsExactAndBacked();
    }
}
