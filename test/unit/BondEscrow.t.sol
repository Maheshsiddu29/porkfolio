// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {BondEscrow} from "../../src/BondEscrow.sol";
import {CommitmentAuthorizer} from "../../src/CommitmentAuthorizer.sol";
import {CuratorAuthorization} from "../../src/CuratorAuthorization.sol";
import {IBondEscrow} from "../../src/interfaces/IBondEscrow.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {IVaultState} from "../../src/interfaces/IVaultState.sol";
import {VaultStateReader} from "../../src/libraries/VaultStateReader.sol";
import {BondTestBase} from "../utils/BondTestBase.sol";

using VaultStateReader for SharedCommitmentVault;

/// @notice `BondEscrow` on the real vault, PoolManager and bonded authorization module (production builds): posting,
///         lazy synchronization, settlement, minimum charge, refunds, protocol fees, parameters and bounds. Amounts
///         follow G05's worked example D (A = 100,000 for 10 days at rho = 1e9: bond 86.4) where possible, so every
///         expected value below is an exact literal.
contract BondEscrowTest is BondTestBase {
    uint128 internal constant A = 100_000 ether;
    uint256 internal t0; // an hour boundary: durations below are whole hours

    function setUp() public override {
        super.setUp();
        t0 = _hourAligned(vm.getBlockTimestamp()) + 1 hours;
        vm.warp(t0);
    }

    function _alloc10d() internal returns (uint256) {
        return _allocateUntil(keyS, c1, A, uint64(t0 + 10 days));
    }

    function _fill(uint256 id, uint256 x) internal {
        _swap(keyS, true, x, id);
    }

    function _cancelAndSync(uint256 id) internal {
        vm.prank(curator);
        vault.cancelAllocation(id);
        escrow.sync(id);
    }

    // ------------------------------------------------------------------
    // Posting
    // ------------------------------------------------------------------

    /// @notice The bond is the largest possible charge, prepaid in the reserved asset: 100,000 * 10 days * 1e-9 =
    ///         86.4, pulled from the payer and held as escrow claims. It is not backing: B, N and the admission limit
    ///         move only by the reservation itself (V-13).
    function test_post_bondIsPrepaidMaximumCharge_notBacking() public {
        uint256 paidBefore = token1.balanceOf(curator);
        uint256 admissibleBefore = lens.admissibleCapacity(vault, c1);
        uint256 id = _alloc10d();

        IBondEscrow.Bond memory b = escrow.getBond(id);
        assertEq(b.bond, 86.4 ether);
        assertEq(paidBefore - token1.balanceOf(curator), 86.4 ether, "pulled from the payer");
        assertEq(_claims(address(escrow), c1), 86.4 ether, "held as claims by the escrow");
        assertEq(b.payer, curator);
        assertEq(b.rate, RHO);
        assertEq(b.minDuration, T_MIN);
        assertEq(b.created, t0);
        assertEq(b.expiry, t0 + 10 days);
        assertEq(b.amount, A);
        assertEq(b.remaining, A);
        assertEq(b.asset, 1);

        IBondEscrow.Ledger memory l = escrow.getLedger(c1);
        assertEq(l.openBonds, 86.4 ether);
        assertEq(l.rate, uint256(A) * RHO);
        IBondEscrow.RateDrop memory d = escrow.getRateDrop(c1, ((t0 + 10 days) / 1 hours) % 720);
        assertEq(d.bucket, (t0 + 10 days) / 1 hours);
        assertEq(d.amount, uint256(A) * RHO);

        assertEq(lens.backing(vault, c1), VAULT_FUNDING, "bond is not backing");
        assertEq(lens.admissibleCapacity(vault, c1), admissibleBefore - A, "only the reservation itself counts");
        _assertEscrowIdentity();
        _assertAccountingConsistent();
    }

    /// @notice Rounded up: 7 raw units for an hour at 1e-9 is 2.52e-5 of a unit, charged as 1.
    function test_post_bondRoundsUp() public {
        uint256 id = _allocateUntil(keyS, c1, 7, uint64(t0 + 1 hours));
        assertEq(escrow.getBond(id).bond, 1);
    }

    /// @notice Zero rate: the reservation is still recorded (one bond per allocation) but nothing is pulled and nothing
    ///         ever accrues; settlement charges and refunds zero.
    function test_post_zeroRate_recordedNothingPulled() public {
        vm.prank(owner);
        escrow.setRate(c1, 0);
        uint256 before = token1.balanceOf(curator);
        uint256 id = _alloc10d();
        assertEq(token1.balanceOf(curator), before);
        assertEq(escrow.getBond(id).created, t0, "recorded");
        assertEq(escrow.getLedger(c1).rate, 0);
        vm.warp(t0 + 10 days);
        (uint256 charge, uint256 refund) = escrow.settle(id);
        assertEq(charge, 0);
        assertEq(refund, 0);
        vm.prank(address(bonded));
        vm.expectRevert(abi.encodeWithSelector(IBondEscrow.AllocationNotFresh.selector, id));
        escrow.post(id, curator, 0);
    }

    /// @notice A rate above the signed maximum reverts the whole activation: no allocation, no nonce bit, no reserved
    ///         capacity, no bond, no token moved.
    function test_post_rateAboveMax_rollsBackEverything() public {
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyS, c1, A);
        req.deadline = uint64(t0);
        uint256 nextId = vault.nextAllocationId();
        uint256 q = lens.reserved(vault, c1);
        uint256 bal = token1.balanceOf(curator);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IBondEscrow.RateAboveMax.selector, RHO, RHO - 1));
        bonded.activateDirectBonded(req, RHO - 1);
        assertEq(vault.nextAllocationId(), nextId);
        assertFalse(bonded.isNonceUsed(curator, req.nonce));
        assertEq(lens.reserved(vault, c1), q);
        assertEq(token1.balanceOf(curator), bal);
        assertEq(escrow.getLedger(c1).openBonds, 0);
        vm.prank(curator);
        bonded.activateDirectBonded(req, RHO); // the same request at the exact rate succeeds
    }

    /// @notice A short allowance reverts the activation as a whole (the bond pull fails inside the PoolManager unlock).
    function test_post_shortAllowance_rollsBackEverything() public {
        vm.prank(curator);
        token1.approve(address(escrow), 86.4 ether - 1);
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyS, c1, A);
        req.expiry = uint64(t0 + 10 days);
        req.deadline = uint64(t0);
        uint256 nextId = vault.nextAllocationId();
        vm.prank(curator);
        vm.expectRevert();
        bonded.activateDirectBonded(req, RHO);
        assertEq(vault.nextAllocationId(), nextId);
        assertFalse(bonded.isNonceUsed(curator, req.nonce));
        assertEq(lens.reserved(vault, c1), 0);
    }

    /// @notice `post` is the module's alone, only for the vault's newest allocation, only while it is untouched, once.
    function test_post_callerAndFreshness() public {
        uint256 id = _alloc10d();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IBondEscrow.NotAuthModule.selector, attacker));
        escrow.post(id, attacker, RHO);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IBondEscrow.NotAuthModule.selector, owner));
        escrow.post(id, owner, RHO);
        vm.startPrank(address(bonded));
        vm.expectRevert(abi.encodeWithSelector(IBondEscrow.AlreadyBonded.selector, id));
        escrow.post(id, curator, RHO);
        vm.expectRevert(abi.encodeWithSelector(IBondEscrow.AllocationNotFresh.selector, id - 1));
        escrow.post(id - 1, curator, RHO);
        vm.expectRevert(abi.encodeWithSelector(IBondEscrow.AllocationNotFresh.selector, id + 1));
        escrow.post(id + 1, curator, RHO);
        vm.stopPrank();

        // Unbonded allocations made through another module (installed by the owner) cannot be bonded once they are
        // consumed, released or expired.
        CuratorAuthorization plain = _installAuth(vault);
        uint256[3] memory ids;
        for (uint256 k; k < 3; ++k) {
            ISharedCommitmentVault.AllocationRequest memory req = _request(keyS, c1, 1000 ether);
            req.deadline = uint64(vm.getBlockTimestamp());
            vm.prank(curator);
            ids[k] = plain.activateDirect(req);
            if (k == 0) _fill(ids[k], 1 ether);
            if (k == 1) {
                vm.prank(curator);
                vault.cancelAllocation(ids[k]);
            }
            if (k == 2) vm.warp(vm.getBlockTimestamp() + 2 days);
            vm.prank(address(plain));
            vm.expectRevert(abi.encodeWithSelector(IBondEscrow.AllocationNotFresh.selector, ids[k]));
            escrow.post(ids[k], curator, RHO);
        }
    }

    /// @notice A bond in an escrow the vault does not use could never pay LPs, so posting is refused.
    function test_post_refusedWhenNotTheVaultsEscrow() public {
        BondEscrow other = _deployEscrow(vault, RHO, RHO, T_MIN, 0, protocol);
        vm.prank(owner);
        vault.setFeeEscrow(address(other));
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyS, c1, A);
        req.deadline = uint64(t0);
        vm.prank(curator);
        vm.expectRevert(IBondEscrow.EscrowNotInstalled.selector);
        bonded.activateDirectBonded(req, RHO);
    }

    /// @notice The bond must fit the PoolManager's int128 range. With a reserve of 2^125 raw units, a reservation of
    ///         2^124 for an hour at MAX_RATE would need a bond of 2^124 * 3,600 > 2^127: refused, nothing changes. At
    ///         rho = 1 the same reservation bonds ceil(2^124 * 3,600 / 1e18), and the aggregate products stay exact.
    function test_post_extremeAmounts() public {
        uint256 big = 1 << 125;
        _depositShares(lp0, lens.totalShares(vault) * (big / VAULT_FUNDING));
        vm.startPrank(owner);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        escrow.setRate(c1, escrow.MAX_RATE());
        vm.stopPrank();
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyS, c1, uint128(1 << 124));
        req.expiry = uint64(t0 + 1 hours);
        req.deadline = uint64(t0);
        _fundPayer(curator);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IBondEscrow.BondTooLarge.selector, uint256(1 << 124) * 3600));
        bonded.activateDirectBonded(req, type(uint256).max);

        vm.prank(owner);
        escrow.setRate(c1, 1);
        vm.prank(curator);
        uint256 id = bonded.activateDirectBonded(req, type(uint256).max);
        uint256 expected = (uint256(1 << 124) * 3600 + 1e18 - 1) / 1e18;
        assertEq(escrow.getBond(id).bond, expected);
        vm.warp(t0 + 1 hours);
        (uint256 charge,) = escrow.settle(id);
        assertEq(charge, expected, "full hour, no consumption: the whole bond");
        _assertEscrowIdentity();
    }

    // ------------------------------------------------------------------
    // Synchronization and settlement
    // ------------------------------------------------------------------

    /// @notice G05 example D on the real contracts. A fill of 30,000 on day 2 synced at once lowers the fee-bearing
    ///         remainder to 70,000; a realization on day 5 moves 35.424 out of "earned" (10% protocol); a cancel synced on
    ///         day 6 stops accrual; settlement charges 41.472 and refunds 44.928; at the end LPs received 37.3248 into
    ///         B_1 and the protocol 4.1472, exactly the per-reservation charge split.
    function test_exampleD_exactAmounts() public {
        uint256 id = _alloc10d();
        vm.warp(t0 + 2 days);
        _fill(id, 30_000 ether);
        escrow.sync(id);
        IBondEscrow.Bond memory b = escrow.getBond(id);
        assertEq(b.remaining, 70_000 ether, "partial consumption lowers the fee-bearing capacity");
        assertEq(b.accrued, uint256(A) * RHO * 2 days);
        assertEq(escrow.getLedger(c1).rate, 70_000 ether * RHO);

        vm.warp(t0 + 5 days);
        uint256 backing = lens.backing(vault, c1);
        // 72 hours since the last aggregate update: more than `realize()`'s 32-bucket cap, so catch up explicitly.
        vm.expectRevert(abi.encodeWithSelector(IBondEscrow.EscrowBehind.selector, c1));
        escrow.realize();
        assertTrue(escrow.realize(type(uint256).max));
        assertEq(escrow.getLedger(c1).realized, 35.424 ether);
        assertEq(lens.backing(vault, c1) - backing, 31.8816 ether, "LP part into B_1");
        assertEq(escrow.getLedger(c1).protocolOwed, 3.5424 ether);

        vm.warp(t0 + 6 days);
        _cancelAndSync(id);
        (uint256 charge, uint256 refund) = escrow.settle(id);
        assertEq(charge, 41.472 ether);
        assertEq(refund, 86.4 ether - 41.472 ether);
        escrow.realize();
        assertEq(lens.backing(vault, c1) - backing, 37.3248 ether);
        assertEq(escrow.getLedger(c1).protocolOwed, 4.1472 ether);
        assertEq(escrow.refundOf(curator, c1), 44.928 ether);
        _assertEscrowIdentity();
        _assertAccountingConsistent();
    }

    /// @notice Late synchronization: the same 30,000 fill synced one day late costs exactly 30,000 * 1 day * 1e-9 =
    ///         2.592 more, paid by the payer and earned by LPs. The payer removes it by syncing in the fill's block.
    function test_lateSync_overchargeIsExact() public {
        uint256 prompt = _alloc10d();
        uint256 late = _alloc10d();
        vm.warp(t0 + 2 days);
        _fill(prompt, 30_000 ether);
        _fill(late, 30_000 ether);
        escrow.sync(prompt);
        vm.warp(t0 + 3 days);
        escrow.sync(late);
        vm.warp(t0 + 10 days);
        (uint256 c1Prompt,) = escrow.settle(prompt);
        (uint256 c1Late,) = escrow.settle(late);
        assertEq(c1Prompt, 65.664 ether);
        assertEq(c1Late - c1Prompt, 2.592 ether);
    }

    /// @notice A cancel nobody syncs is charged until the next sync. Settled after expiry, the bond is charged in
    ///         full (86.4); cancelled and synced in the same block on day 2, it is charged 17.28.
    function test_cancel_unsyncedChargedToSettlement_syncedStopsAtOnce() public {
        uint256 lazy = _alloc10d();
        uint256 eager = _alloc10d();
        vm.warp(t0 + 2 days);
        vm.prank(curator);
        vault.cancelAllocation(lazy);
        _cancelAndSync(eager);
        vm.warp(t0 + 10 days);
        (uint256 cLazy, uint256 rLazy) = escrow.settle(lazy);
        (uint256 cEager, uint256 rEager) = escrow.settle(eager);
        assertEq(cLazy, 86.4 ether);
        assertEq(rLazy, 0);
        assertEq(cEager, 17.28 ether);
        assertEq(rEager, 86.4 ether - 17.28 ether);
    }

    /// @notice Same-block activation and cancellation: no time has passed, so the minimum charge applies:
    ///         100,000 * 1 hour * 1e-9 = 0.36. Settled in the same block.
    function test_sameBlockActivationAndCancellation_minimumCharge() public {
        uint256 id = _alloc10d();
        _cancelAndSync(id);
        (uint256 charge, uint256 refund) = escrow.settle(id);
        assertEq(charge, 0.36 ether);
        assertEq(refund, 86.4 ether - 0.36 ether);
    }

    /// @notice T_min longer than the reservation: the minimum is the whole duration, so the bond is charged in full.
    function test_minChargeLongerThanDuration_chargesWholeDuration() public {
        vm.prank(owner);
        escrow.setMinChargeDuration(2 hours);
        uint256 id = _allocateUntil(keyS, c1, A, uint64(t0 + 1 hours)); // one bucket
        _cancelAndSync(id);
        (uint256 charge, uint256 refund) = escrow.settle(id);
        assertEq(charge, 0.36 ether);
        assertEq(refund, 0);
    }

    /// @notice A bond's rate and minimum charge duration never change after posting (V-16): later governance changes
    ///         apply only to new bonds.
    function test_termsFixedAtCreation() public {
        uint256 id = _alloc10d();
        vm.startPrank(owner);
        escrow.setRate(c1, 2 * RHO);
        escrow.setMinChargeDuration(0);
        vm.stopPrank();
        _cancelAndSync(id);
        (uint256 charge,) = escrow.settle(id);
        assertEq(escrow.getBond(id).rate, RHO);
        assertEq(charge, 0.36 ether, "old T_min");
        uint256 id2 = _alloc10d();
        assertEq(escrow.getBond(id2).rate, 2 * RHO);
        assertEq(escrow.getBond(id2).bond, 172.8 ether);
    }

    /// @notice Expiry boundary: not settleable one second before expiry, settleable at it; settlement releases the
    ///         expired allocation in the vault (scope totals cleared); a second settle and any later sync revert.
    function test_settle_expiryBoundary_releasesOnce() public {
        uint256 id = _alloc10d();
        vm.warp(t0 + 10 days - 1);
        vm.expectRevert(abi.encodeWithSelector(IBondEscrow.NotSettleable.selector, id));
        escrow.settle(id);
        vm.warp(t0 + 10 days);
        (uint256 charge, uint256 refund) = escrow.settle(id);
        assertEq(charge, 86.4 ether, "unused for the whole term");
        assertEq(refund, 0);
        assertTrue(lens.getAllocation(vault, id).released, "settle released the expired allocation");
        assertEq(lens.curatorReserved(vault, curator, c1), 0);
        vm.expectRevert(abi.encodeWithSelector(IBondEscrow.AlreadySettled.selector, id));
        escrow.settle(id);
        vm.expectRevert(abi.encodeWithSelector(IBondEscrow.AlreadySettled.selector, id));
        escrow.sync(id);
        vm.expectRevert(abi.encodeWithSelector(IBondEscrow.UnknownBond.selector, id + 1));
        escrow.sync(id + 1);
    }

    /// @notice A fill synced only after expiry is charged until expiry, never beyond: accrual is clipped at the
    ///         expiry second, in the bond and in the aggregate.
    function test_syncAfterExpiry_clippedAtExpiry() public {
        uint256 id = _alloc10d();
        vm.warp(t0 + 2 days);
        _fill(id, 30_000 ether);
        vm.warp(t0 + 40 days);
        escrow.sync(id);
        assertEq(escrow.getBond(id).accrued, uint256(A) * RHO * 10 days);
        assertEq(escrow.getBond(id).remaining, 70_000 ether);
        assertEq(escrow.getLedger(c1).rate, 0, "the drop left the aggregate at expiry");
        (uint256 charge,) = escrow.settle(id);
        assertEq(charge, 86.4 ether);
        _assertEscrowIdentity();
    }

    /// @notice Settlement of a closed, unexpired bond leaves the vault alone (the allocation is already released).
    function test_settle_closedBeforeExpiry_noSecondRelease() public {
        uint256 id = _alloc10d();
        vm.warp(t0 + 3 days);
        _cancelAndSync(id);
        escrow.settle(id);
        assertEq(escrow.getBond(id).charge, 25.92 ether);
    }

    // ------------------------------------------------------------------
    // Realization
    // ------------------------------------------------------------------

    /// @notice Realization raises B_1 and the vault's claims by exactly the LP part, mints no shares, consumes the
    ///         escrow's allowance, and runs again with nothing to move.
    function test_realize_raisesBackingOnly() public {
        _alloc10d();
        vm.warp(t0 + 1 days);
        uint256 shares = lens.totalShares(vault);
        uint256 b = lens.backing(vault, c1);
        uint256 claims = _claims(address(vault), c1);
        escrow.realize();
        uint256 earned = 8.64 ether;
        uint256 lpPart = earned - earned * PROTOCOL_BPS / 10_000;
        assertEq(lens.backing(vault, c1) - b, lpPart);
        assertEq(_claims(address(vault), c1) - claims, lpPart);
        assertEq(lens.totalShares(vault), shares, "no shares minted");
        assertEq(manager.allowance(address(escrow), address(vault), c1.toId()), 0, "allowance consumed");
        escrow.realize();
        assertEq(lens.backing(vault, c1) - b, lpPart, "nothing more");
        _assertEscrowIdentity();
        _assertAccountingConsistent();
    }

    /// @notice The protocol share is bounded by the immutable 20%; at 0 everything goes to LPs, at 20% a fifth is
    ///         credited; a change realizes first, so it never reaches fees earned before it.
    function test_protocolShare_boundsAndChange() public {
        vm.prank(owner);
        vm.expectRevert(IBondEscrow.InvalidParameter.selector);
        escrow.setProtocolFee(2001);
        _alloc10d();
        vm.warp(t0 + 1 days);
        vm.prank(owner);
        escrow.setProtocolFee(2000); // realizes day 1 at 10% first
        assertEq(escrow.getLedger(c1).protocolOwed, 0.864 ether);
        vm.warp(t0 + 2 days);
        escrow.realize();
        assertEq(escrow.getLedger(c1).protocolOwed, 0.864 ether + 1.728 ether, "day 2 at 20%");
        vm.prank(owner);
        escrow.setProtocolFee(0);
        vm.warp(t0 + 3 days);
        uint256 b = lens.backing(vault, c1);
        escrow.realize();
        assertEq(lens.backing(vault, c1) - b, 8.64 ether, "day 3 entirely to LPs");
        assertEq(escrow.getLedger(c1).protocolOwed, 2.592 ether);
    }

    // ------------------------------------------------------------------
    // Claims
    // ------------------------------------------------------------------

    /// @notice Refunds go to a recipient the payer names (zero refused), once; protocol fees only to the recipient's
    ///         chosen address; claimed amounts leave the escrow's accounted claims exactly.
    function test_claims_recipientsAndOnce() public {
        uint256 id = _alloc10d();
        vm.warp(t0 + 1 days);
        _cancelAndSync(id);
        escrow.settle(id);
        escrow.realize();
        address payee = makeAddr("payee");
        vm.startPrank(curator);
        vm.expectRevert(IBondEscrow.ZeroAddress.selector);
        escrow.claimRefund(address(0));
        (, uint256 r1) = escrow.claimRefund(payee);
        vm.expectRevert(IBondEscrow.NothingToClaim.selector);
        escrow.claimRefund(payee);
        vm.stopPrank();
        assertEq(r1, 86.4 ether - 8.64 ether);
        assertEq(token1.balanceOf(payee), r1);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IBondEscrow.NotProtocolRecipient.selector, attacker));
        escrow.claimProtocol(attacker);
        vm.prank(attacker);
        vm.expectRevert(IBondEscrow.NothingToClaim.selector);
        escrow.claimRefund(attacker);
        vm.startPrank(protocol);
        vm.expectRevert(IBondEscrow.ZeroAddress.selector);
        escrow.claimProtocol(address(0));
        (, uint256 p1) = escrow.claimProtocol(payee);
        vm.expectRevert(IBondEscrow.NothingToClaim.selector);
        escrow.claimProtocol(payee);
        vm.stopPrank();
        assertEq(p1, 0.864 ether);
        assertEq(_claims(address(escrow), c1), 0, "everything paid out");
        _assertEscrowIdentity();
    }

    // ------------------------------------------------------------------
    // Parameters
    // ------------------------------------------------------------------

    /// @notice Only the vault's owner sets parameters, within bounds; the guardian and anyone else cannot; the owner
    ///         is read live from the vault.
    function test_setters_onlyVaultOwner_bounded() public {
        address[2] memory others = [guardian, attacker];
        for (uint256 k; k < 2; ++k) {
            vm.startPrank(others[k]);
            vm.expectRevert(abi.encodeWithSelector(IBondEscrow.NotOwner.selector, others[k]));
            escrow.setRate(c1, 1);
            vm.expectRevert(abi.encodeWithSelector(IBondEscrow.NotOwner.selector, others[k]));
            escrow.setMinChargeDuration(1);
            vm.expectRevert(abi.encodeWithSelector(IBondEscrow.NotOwner.selector, others[k]));
            escrow.setProtocolFee(1);
            vm.expectRevert(abi.encodeWithSelector(IBondEscrow.NotOwner.selector, others[k]));
            escrow.setProtocolRecipient(others[k]);
            vm.stopPrank();
        }
        vm.startPrank(owner);
        vm.expectRevert(IBondEscrow.InvalidParameter.selector);
        escrow.setRate(c1, 1e18 + 1);
        vm.expectRevert(IBondEscrow.InvalidCurrency.selector);
        escrow.setRate(Currency.wrap(address(0xdead)), 1);
        vm.expectRevert(IBondEscrow.InvalidParameter.selector);
        escrow.setMinChargeDuration(30 days + 1);
        escrow.setRate(c0, 1e18);
        escrow.setMinChargeDuration(30 days);
        escrow.setProtocolFee(2000);
        escrow.setProtocolRecipient(address(0));
        vm.stopPrank();
        assertEq(escrow.rate(c0), 1e18);
        assertEq(escrow.owner(), owner);
        vm.prank(owner);
        vault.transferOwnership(attacker);
        vm.prank(attacker);
        vault.acceptOwnership();
        assertEq(escrow.owner(), attacker, "read live");
    }

    /// @notice Constructor bounds and the pair it caches.
    function test_constructor_bounds() public {
        IVaultState v = IVaultState(address(vault));
        vm.expectRevert(IBondEscrow.InvalidParameter.selector);
        new BondEscrow(v, 1e18 + 1, 0, 0, 0, address(0));
        vm.expectRevert(IBondEscrow.InvalidParameter.selector);
        new BondEscrow(v, 0, 0, 30 days + 1, 0, address(0));
        vm.expectRevert(IBondEscrow.InvalidParameter.selector);
        new BondEscrow(v, 0, 0, 0, 2001, address(0));
        vm.expectRevert(IBondEscrow.ZeroAddress.selector);
        new BondEscrow(IVaultState(address(0)), 0, 0, 0, 0, address(0));
        assertEq(address(escrow.vault()), address(vault));
        assertEq(address(escrow.poolManager()), address(manager));
    }

    // ------------------------------------------------------------------
    // Mixed decimals
    // ------------------------------------------------------------------

    /// @notice A 6-decimal / 18-decimal pair: the fee asset is the reserved asset and rho is a pure rate, so 1,000 USD
    ///         (1e9 raw) and 1 ETH (1e18 raw) reserved for 10 days at 1e-9 per second bond 864,000 raw USD (0.864 USD)
    ///         and 8.64e14 raw ETH (0.000864 ETH); after expiry the LP parts enter each asset's backing exactly.
    function test_mixedDecimals_6and18() public {
        MockERC20 usd = new MockERC20("USD6", "USD6", 6);
        MockERC20 eth = new MockERC20("ETH18", "ETH18", 18);
        (MockERC20 ta, MockERC20 tb) = address(usd) < address(eth) ? (usd, eth) : (eth, usd);
        Currency ca = Currency.wrap(address(ta));
        Currency cb = Currency.wrap(address(tb));
        SharedCommitmentVault v = new SharedCommitmentVault(manager, owner, ca, cb);
        BondEscrow e = _deployEscrow(v, RHO, RHO, T_MIN, 0, protocol);
        CommitmentAuthorizer m = _deployBonded(v, e);
        address consumer = makeAddr("consumer");
        PoolKey memory key = PoolKey(ca, cb, 3000, 60, IHooks(consumer));
        uint256 seedA = ta == usd ? 3_000_000e6 : 1000 ether;
        uint256 seedB = tb == usd ? 3_000_000e6 : 1000 ether;
        ta.mint(owner, seedA);
        tb.mint(owner, seedB);
        vm.startPrank(owner);
        ta.approve(address(v), type(uint256).max);
        tb.approve(address(v), type(uint256).max);
        v.initialDeposit(seedA, seedB, owner);
        v.setAuthModule(address(m));
        v.setFeeEscrow(address(e));
        v.setConsumer(consumer, true);
        v.setCurator(curator, true);
        v.setSellFloor(ca, PRICE_1_1_X96);
        v.setSellFloor(cb, uint160(PRICE_1_1_X96));
        Currency[2] memory cs = [ca, cb];
        for (uint256 k; k < 2; ++k) {
            v.setCuratorCeiling(curator, cs[k], type(uint256).max);
            v.setRiskLimit(ISharedCommitmentVault.RiskScope.Vault, address(0), cs[k], 1e30, 10_000);
            v.setRiskLimit(ISharedCommitmentVault.RiskScope.Hook, consumer, cs[k], 1e30, 10_000);
            v.setRiskLimit(ISharedCommitmentVault.RiskScope.Curator, curator, cs[k], 1e30, 10_000);
        }
        vm.stopPrank();
        ta.mint(curator, 1e30);
        tb.mint(curator, 1e30);
        vm.startPrank(curator);
        ta.approve(address(e), type(uint256).max);
        tb.approve(address(e), type(uint256).max);
        uint256[2] memory amounts = [uint256(ta == usd ? 1000e6 : 1 ether), tb == usd ? 1000e6 : 1 ether];
        uint256[2] memory ids;
        for (uint256 k; k < 2; ++k) {
            ISharedCommitmentVault.AllocationRequest memory req = ISharedCommitmentVault.AllocationRequest({
                consumer: consumer,
                key: key,
                currencyOut: cs[k],
                maxOut: uint128(amounts[k]),
                minInPerOutX96: PRICE_1_1_X96,
                expiry: uint64(t0 + 10 days),
                nonce: 1000 + k,
                deadline: uint64(t0)
            });
            ids[k] = m.activateDirectBonded(req, RHO);
            assertEq(e.getBond(ids[k]).bond, amounts[k] * 864_000 / 1e9, "bond = amount * 10 days * 1e-9");
        }
        vm.stopPrank();
        vm.warp(t0 + 10 days);
        uint256[2] memory before = [
            VaultStateReader.backing(IVaultState(address(v)), ca), VaultStateReader.backing(IVaultState(address(v)), cb)
        ];
        for (uint256 k; k < 2; ++k) {
            e.settle(ids[k]);
        }
        e.realize();
        for (uint256 k; k < 2; ++k) {
            assertEq(
                VaultStateReader.backing(IVaultState(address(v)), cs[k]) - before[k],
                amounts[k] * 864_000 / 1e9,
                "LP part of each asset, in its own units"
            );
        }
    }
}
