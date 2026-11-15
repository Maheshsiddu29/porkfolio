// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IBondEscrow} from "../../src/interfaces/IBondEscrow.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultStateReader} from "../../src/libraries/VaultStateReader.sol";
import {BondTestBase} from "../utils/BondTestBase.sol";

/// @notice Random real-vault actions with independent totals for bonds posted and claims paid. Every entry point
///         either succeeds or is skipped by an explicit state precondition; an unexpected revert fails the campaign.
contract BondEscrowHandler is BondTestBase {
    uint256[] internal ids;
    uint256 public bondsPosted;
    uint256 public fills;
    uint256 public lateSyncs;
    uint256 public settlements;
    uint256 public realizations;
    uint256 public refundsClaimed;
    uint256 public depositsRealized;
    uint256 public postedAmount;
    uint256 public lpPaid;
    uint256 public refundPaid;
    uint256 public protocolPaid;

    function count() external view returns (uint256) {
        return ids.length;
    }

    function idAt(uint256 i) external view returns (uint256) {
        return ids[i];
    }

    function escrowClaims(Currency c) external view returns (uint256) {
        return _claims(address(escrow), c);
    }

    function vaultClaims(Currency c) external view returns (uint256) {
        return _claims(address(vault), c);
    }

    function backing(Currency c) external view returns (uint256) {
        return lens.backing(vault, c);
    }

    function reserved(Currency c) external view returns (uint256) {
        return lens.reserved(vault, c);
    }

    function claimable(Currency c) external view returns (uint256) {
        return lens.claimableAssets(vault, c);
    }

    function bond(uint256 id) external view returns (IBondEscrow.Bond memory) {
        return escrow.getBond(id);
    }

    function ledger(Currency c) external view returns (IBondEscrow.Ledger memory) {
        return escrow.getLedger(c);
    }

    function asset(uint256 i) external view returns (Currency) {
        return i == 0 ? c0 : c1;
    }

    function post(uint256 x) external {
        if (ids.length >= 12) return;
        uint256 now_ = vm.getBlockTimestamp();
        uint64 expiry = uint64(uint256(_hourAligned(now_)) + (1 + (x % 72)) * 1 hours);
        uint128 amount = uint128((1 + ((x >> 16) % 1000)) * 1 ether);
        ISharedCommitmentVault.AllocationRequest memory req = ISharedCommitmentVault.AllocationRequest({
            consumer: address(keyS.hooks),
            key: keyS,
            currencyOut: c1,
            maxOut: amount,
            minInPerOutX96: PRICE_1_1_X96,
            expiry: expiry,
            nonce: nextNonce++,
            deadline: uint64(now_)
        });
        vm.prank(curator);
        uint256 id = bonded.activateDirectBonded(req, RHO);
        ids.push(id);
        postedAmount += escrow.getBond(id).bond;
        ++bondsPosted;
    }

    function swapOne(uint256 id, uint256 amount) external {
        require(msg.sender == address(this));
        _swap(keyS, true, amount, id);
    }

    function fill(uint256 x) external {
        if (ids.length == 0) return;
        for (uint256 k; k < ids.length; ++k) {
            uint256 id = ids[(x % ids.length + k) % ids.length];
            IBondEscrow.Bond memory j = escrow.getBond(id);
            if (j.settled || j.closed || vm.getBlockTimestamp() >= j.expiry) continue;
            uint256 consumed = lens.getAllocation(vault, id).consumed;
            if (consumed == j.amount) continue;
            uint256 amount = 1 + ((x >> 16) % 100 ether);
            if (amount > j.amount - consumed) amount = j.amount - consumed;
            try this.swapOne(id, amount) {
                ++fills;
            } catch {} // Fill-time floor, risk limit or hook refusal does not change the bond.
            return;
        }
    }

    function sync(uint256 x) external {
        if (ids.length == 0) return;
        for (uint256 k; k < ids.length; ++k) {
            uint256 id = ids[(x % ids.length + k) % ids.length];
            IBondEscrow.Bond memory j = escrow.getBond(id);
            if (j.settled) continue;
            if (lens.getAllocation(vault, id).consumed > j.synced) {
                if (vm.getBlockTimestamp() > j.last) ++lateSyncs;
                escrow.sync(id);
                return;
            }
        }
        uint256 fallbackId = ids[x % ids.length];
        if (!escrow.getBond(fallbackId).settled) escrow.sync(fallbackId);
    }

    function cancel(uint256 x) external {
        if (ids.length == 0) return;
        for (uint256 k; k < ids.length; ++k) {
            uint256 id = ids[(x % ids.length + k) % ids.length];
            if (lens.getAllocation(vault, id).released) continue;
            vm.prank(curator);
            vault.cancelAllocation(id);
            if ((x & 1) == 0) escrow.sync(id);
            return;
        }
    }

    function settle(uint256 x) external {
        if (ids.length == 0) return;
        for (uint256 k; k < ids.length; ++k) {
            uint256 id = ids[(x % ids.length + k) % ids.length];
            IBondEscrow.Bond memory j = escrow.getBond(id);
            if (j.settled || (!lens.getAllocation(vault, id).released && vm.getBlockTimestamp() < j.expiry)) continue;
            escrow.settle(id);
            ++settlements;
            return;
        }
    }

    function realize(uint256) external {
        uint256 before = lens.backing(vault, c1);
        escrow.realize(type(uint256).max);
        uint256 delta = lens.backing(vault, c1) - before;
        lpPaid += delta;
        if (delta != 0) ++realizations;
    }

    function deposit(uint256 x) external {
        uint256 before = lens.backing(vault, c1);
        uint256 shares = (1 + x % 100) * 1 ether;
        // Deposits fail closed when a live aggregate is more than 32 hourly buckets behind; anyone can catch up.
        if (ids.length != 0 && vm.getBlockTimestamp() > escrow.getLedger(c1).last + 31 hours) return;
        (, uint256 paid1) = _depositShares(lp0, shares);
        uint256 fee = lens.backing(vault, c1) - before - paid1;
        lpPaid += fee;
        if (fee != 0) ++depositsRealized;
    }

    function redeem(uint256 x) external {
        uint256 available = lens.sharesOf(vault, lp0);
        if (available <= 1 ether) return;
        uint256 shares = (1 + x % 100) * 1 ether;
        if (shares > available / 10) shares = available / 10;
        _redeem(lp0, shares, true);
    }

    function claimRefund(uint256) external {
        if (escrow.refundOf(curator, c1) == 0) return;
        vm.prank(curator);
        (, uint256 amount1) = escrow.claimRefund(curator);
        refundPaid += amount1;
        ++refundsClaimed;
    }

    function claimProtocol(uint256) external {
        if (escrow.getLedger(c1).protocolOwed == 0) return;
        vm.prank(protocol);
        (, uint256 amount1) = escrow.claimProtocol(protocol);
        protocolPaid += amount1;
    }

    function warp(uint256 x) external {
        vm.warp(vm.getBlockTimestamp() + 1 + x % 24 hours);
    }

    /// @dev A fill followed by a delayed sync gives the campaign a reachable overcharge path even when independent
    ///      random calls happen to cancel or settle a bond before selecting it for sync.
    function fillThenLateSync(uint256 x) external {
        for (uint256 k; k < ids.length; ++k) {
            uint256 id = ids[(x % ids.length + k) % ids.length];
            IBondEscrow.Bond memory j = escrow.getBond(id);
            if (j.settled || j.closed || vm.getBlockTimestamp() + 1 hours >= j.expiry) continue;
            uint256 consumed = lens.getAllocation(vault, id).consumed;
            if (consumed == j.amount) continue;
            try this.swapOne(id, 1) {
                ++fills;
                vm.warp(vm.getBlockTimestamp() + 1 hours);
                escrow.sync(id);
                ++lateSyncs;
            } catch {}
            return;
        }
    }

    /// @dev Closing and settling in one action exercises the refund liability before an unrelated warp can consume
    ///      the whole prepaid term; the payout still needs a separate claim action.
    function earlyCloseAndSettle(uint256 x) external {
        for (uint256 k; k < ids.length; ++k) {
            uint256 id = ids[(x % ids.length + k) % ids.length];
            IBondEscrow.Bond memory j = escrow.getBond(id);
            if (j.settled || lens.getAllocation(vault, id).released || vm.getBlockTimestamp() >= j.expiry) continue;
            vm.prank(curator);
            vault.cancelAllocation(id);
            escrow.settle(id);
            ++settlements;
            return;
        }
    }
}

/// @notice Stateful financial properties on the real PoolManager: escrow claims cover every liability, aggregate
///         accrued rho-seconds equal the sum of unsettled bonds, bond charges never exceed collateral, and the vault's
///         accounted backing and reservations remain physically backed through fees, fills, deposits and exits.
contract BondEscrowInvariantsTest is Test {
    BondEscrowHandler internal handler;

    function setUp() public {
        handler = new BondEscrowHandler();
        handler.setUp();
        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = BondEscrowHandler.post.selector;
        selectors[1] = BondEscrowHandler.fill.selector;
        selectors[2] = BondEscrowHandler.sync.selector;
        selectors[3] = BondEscrowHandler.cancel.selector;
        selectors[4] = BondEscrowHandler.settle.selector;
        selectors[5] = BondEscrowHandler.realize.selector;
        selectors[6] = BondEscrowHandler.deposit.selector;
        selectors[7] = BondEscrowHandler.redeem.selector;
        selectors[8] = BondEscrowHandler.claimRefund.selector;
        selectors[9] = BondEscrowHandler.claimProtocol.selector;
        selectors[10] = BondEscrowHandler.warp.selector;
        selectors[11] = BondEscrowHandler.fillThenLateSync.selector;
        selectors[12] = BondEscrowHandler.earlyCloseAndSettle.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Reconstructs the aggregate at its stored timestamp from each unsettled bond. This does not use the
    ///      escrow's rate-drop ring, so missing or double-applied expiry drops are detected.
    function invariant_escrowConservationAndAggregate() public view {
        Currency c0 = handler.asset(0);
        Currency c1 = handler.asset(1);
        IBondEscrow.Ledger memory l = handler.ledger(c1);
        uint256 sumAccrued;
        uint256 sumRate;
        uint256 sumOpen;
        for (uint256 i; i < handler.count(); ++i) {
            IBondEscrow.Bond memory j = handler.bond(handler.idAt(i));
            assertLe(j.charge, j.bond, "charge exceeds prepaid bond");
            if (j.settled) continue;
            uint256 t = l.last < j.expiry ? l.last : j.expiry;
            sumAccrued += j.accrued + (t > j.last ? uint256(j.remaining) * j.rate * (t - j.last) : 0);
            if (l.last < j.expiry && !j.closed) sumRate += uint256(j.remaining) * j.rate;
            sumOpen += j.bond;
        }
        assertEq(l.accrued, sumAccrued, "aggregate differs from sum of bonds");
        assertEq(l.rate, sumRate, "aggregate rate differs from open bonds");
        assertEq(l.openBonds, sumOpen, "open bond liability");
        uint256 held = l.openBonds + l.settledCharges - l.realized + l.refundsOwed + l.protocolOwed;
        assertEq(handler.escrowClaims(c1), held, "escrow claim liability");
        assertEq(handler.escrowClaims(c0), 0, "asset0 bond unexpectedly held");
        assertEq(handler.postedAmount(), handler.lpPaid() + handler.refundPaid() + handler.protocolPaid() + held);
        assertLe(handler.backing(c0), handler.vaultClaims(c0));
        assertLe(handler.backing(c1), handler.vaultClaims(c1));
        assertLe(handler.reserved(c0) + handler.claimable(c0), handler.backing(c0));
        assertLe(handler.reserved(c1) + handler.claimable(c1), handler.backing(c1));
    }

    /// @notice A concrete sequence reaches a fill observed after time passes, an early close, settlement, fee
    ///         realization, a refund claim and a deposit that checkpoints fees. This guards against a campaign whose
    ///         handler keeps choosing actions that return before touching the contracts.
    function test_handlerProgress() public {
        handler.post(1);
        handler.fill(0);
        handler.warp(1 hours);
        handler.sync(0);
        handler.cancel(0);
        handler.settle(0);
        handler.realize(0);
        handler.claimRefund(0);
        handler.post(2);
        handler.warp(1 hours);
        handler.deposit(1);
        assertGt(handler.bondsPosted(), 0);
        assertGt(handler.fills(), 0);
        assertGt(handler.lateSyncs(), 0);
        assertGt(handler.settlements(), 0);
        assertGt(handler.realizations(), 0);
        assertGt(handler.refundsClaimed(), 0);
        assertGt(handler.depositsRealized(), 0);
        invariant_escrowConservationAndAggregate();
    }

    function afterInvariant() public view {
        console2.log("COV bondsPosted", handler.bondsPosted());
        console2.log("COV fills", handler.fills());
        console2.log("COV lateSyncs", handler.lateSyncs());
        console2.log("COV settlements", handler.settlements());
        console2.log("COV realizations", handler.realizations());
        console2.log("COV refundsClaimed", handler.refundsClaimed());
        console2.log("COV depositsRealized", handler.depositsRealized());
    }
}
