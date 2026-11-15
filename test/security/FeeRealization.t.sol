// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {BondEscrow} from "../../src/BondEscrow.sol";
import {CommitmentAuthorizer} from "../../src/CommitmentAuthorizer.sol";
import {CuratorAuthorization} from "../../src/CuratorAuthorization.sol";
import {ICommitmentAuthorizer} from "../../src/interfaces/ICommitmentAuthorizer.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {IBondEscrow} from "../../src/interfaces/IBondEscrow.sol";
import {VaultStateReader} from "../../src/libraries/VaultStateReader.sol";
import {BondTestBase} from "../utils/BondTestBase.sol";

using VaultStateReader for SharedCommitmentVault;

/// @dev Answers `vault()` like an escrow (so `setFeeEscrow` accepts it) and reverts in `realize`: a broken escrow.
contract BrokenEscrow {
    address public immutable vault;

    constructor(address vault_) {
        vault = vault_;
    }

    function realize() external pure {
        revert("escrow broken");
    }
}

/// @notice The fee entry of the vault on the production builds: who may call `realizeFee`, that `deposit` realizes
///         before pricing (no just-in-time capture), what an LP exiting before a realization gives up (quantified),
///         that a broken or lagging escrow stops deposits and nothing else, escrow replacement with open bonds (the
///         stranded amount, quantified, and the procedure that avoids it), and conservation with several hooks and
///         curators bonding the same asset.
contract FeeRealizationTest is BondTestBase {
    uint128 internal constant A = 100_000 ether;
    uint256 internal t0;

    function setUp() public override {
        super.setUp();
        t0 = _hourAligned(vm.getBlockTimestamp()) + 1 hours;
        vm.warp(t0);
    }

    function _alloc10d() internal returns (uint256) {
        return _allocateUntil(keyS, c1, A, uint64(t0 + 10 days));
    }

    // ------------------------------------------------------------------
    // Access to realizeFee and its bounds
    // ------------------------------------------------------------------

    /// @notice Only the installed escrow can add fees to backing (V-20): not the owner, the guardian, a hook, the
    ///         authorization module or anyone else; with no escrow installed, nobody, not even the former escrow.
    function test_realizeFee_onlyInstalledEscrow() public {
        address[5] memory callers = [owner, guardian, attacker, address(hookA), address(bonded)];
        for (uint256 k; k < callers.length; ++k) {
            vm.prank(callers[k]);
            vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NotFeeEscrow.selector, callers[k]));
            vault.realizeFee(c1, 1);
        }
        vm.prank(owner);
        vault.setFeeEscrow(address(0));
        vm.prank(address(escrow));
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NotFeeEscrow.selector, address(escrow)));
        vault.realizeFee(c1, 1);
    }

    /// @notice `realizeFee` validates the currency, needs the escrow's allowance (it pulls; nothing is trusted), and
    ///         refuses to take B_a above MAX_AMOUNT: at B = MAX_AMOUNT - 5, 6 is refused and 5 accepted.
    function test_realizeFee_boundsAndPull() public {
        _alloc10d(); // the escrow now holds 86.4 claims of asset1
        vm.startPrank(address(escrow));
        vm.expectRevert(ISharedCommitmentVault.InvalidCurrency.selector);
        vault.realizeFee(Currency.wrap(address(0xdead)), 1);
        vm.expectRevert(); // PoolManager: no allowance
        vault.realizeFee(c1, 1);
        manager.approve(address(vault), c1.toId(), 6);
        bytes32 slot = keccak256(abi.encode(c1, uint256(7)));
        uint256 max = vault.MAX_AMOUNT();
        vm.store(address(vault), slot, bytes32(max - 5));
        vm.expectRevert(ISharedCommitmentVault.AmountTooLarge.selector);
        vault.realizeFee(c1, 6);
        vault.realizeFee(c1, 5);
        vm.stopPrank();
        assertEq(lens.backing(vault, c1), max);
        assertEq(manager.allowance(address(escrow), address(vault), c1.toId()), 1);
    }

    // ------------------------------------------------------------------
    // Attribution
    // ------------------------------------------------------------------

    /// @notice Just-in-time deposit: one day of fees (8.64, LP part 7.776) is realized before the newcomer is priced,
    ///         so doubling the supply and exiting at once returns what was paid, less at most one raw unit per asset.
    ///         Without the checkpoint the newcomer would have taken half of 7.776. The lens preview includes the fees,
    ///         so a deposit bounded by it succeeds.
    function test_jitDeposit_buysNoPastFees() public {
        _alloc10d();
        vm.warp(t0 + 1 days);
        address jit = makeAddr("jit");
        uint256 s = lens.totalShares(vault);
        (uint256 p0, uint256 p1) = _depositShares(jit, s);
        assertEq(escrow.getLedger(c1).realized, 8.64 ether, "realized before pricing");
        (, uint256 g0, uint256 g1,) = _redeem(jit, s, false);
        assertLe(g0, p0);
        assertLe(g1, p1);
        assertLe(p0 - g0, 1);
        assertLe(p1 - g1, 1);
    }

    /// @notice An LP holding half the shares that exits before a realization forfeits exactly its pro-rata part of
    ///         the unrealized LP fees (7.776 * 1/2 = 3.888, up to one raw unit of rounding) to the shares that stay;
    ///         realizing first (anyone may) pays it that part. Quantifies G05 CE-G5-4 on the real contracts.
    function test_exitBeforeRealization_forfeitsProRata() public {
        address lpX = makeAddr("lpX");
        uint256 s = lens.totalShares(vault);
        _depositShares(lpX, s);
        _alloc10d();
        vm.warp(t0 + 1 days);
        (uint256 u,) = escrow.unrealized(c1);
        assertEq(u, 7.776 ether);

        uint256 snap = vm.snapshotState();
        (,, uint256 exitNoRealize,) = _redeem(lpX, s, false);
        uint256 n1 = lens.netAssets(vault, c1);
        escrow.realize();
        assertEq(lens.netAssets(vault, c1) - n1, u, "the remaining shares received all of it");

        vm.revertToState(snap);
        escrow.realize();
        (,, uint256 exitRealized,) = _redeem(lpX, s, false);
        uint256 forfeited = exitRealized - exitNoRealize;
        uint256 expected = FullMath.mulDiv(u, s, 2 * s);
        assertApproxEqAbs(forfeited, expected, 1, "pro-rata part of U");
        emit log_named_decimal_uint("forfeited by exiting before realization (asset1)", forfeited, 18);
    }

    // ------------------------------------------------------------------
    // Failure of the escrow
    // ------------------------------------------------------------------

    /// @notice A broken escrow stops deposits (fail closed, D-2) and nothing else: instant and queued redemption,
    ///         queue processing, request cancellation, claims, swaps, admissions through another module, release and
    ///         cancellation all work (V-9). Unsetting the escrow (owner) restores deposits.
    function test_brokenEscrow_onlyDepositsStop() public {
        BrokenEscrow broken = new BrokenEscrow(address(vault));
        CuratorAuthorization plain = _installAuth(vault);
        vm.prank(owner);
        vault.setFeeEscrow(address(broken));

        _fundLp(lp0, 1 ether, 1 ether);
        vm.prank(lp0);
        vm.expectRevert(bytes("escrow broken"));
        vault.deposit(1 ether, type(uint256).max, type(uint256).max, lp0);

        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, 900_000 ether);
        req.deadline = uint64(t0);
        vm.prank(curator);
        uint256 id = plain.activateDirect(req);
        _swap(keyA, true, 1000 ether, id);
        (uint256 instant,,, uint256 rid) = _redeem(lp0, lens.sharesOf(vault, lp0) / 2, true);
        assertGt(instant, 0, "instant part paid");
        assertGt(rid, 0, "remainder queued");
        vm.prank(curator);
        vault.cancelAllocation(id);
        vault.processQueue(10);
        vm.prank(lp0);
        vault.claim(rid);
        (,,, uint256 rid2) = _redeem(lp0, 1 ether, true);
        if (rid2 != 0) {
            vm.prank(lp0);
            vault.cancelRequest(rid2);
        }
        _assertAccountingConsistent();

        vm.prank(owner);
        vault.setFeeEscrow(address(0));
        _depositShares(lp0, 1 ether);
    }

    /// @notice An escrow more than 32 hours behind with an open rate makes deposits revert with `EscrowBehind`
    ///         instead of pricing on a stale realization; exits are unaffected; three permissionless
    ///         `realize(32)` calls catch up the 72 buckets and deposits resume.
    function test_escrowBehind_depositsRevert_catchUpRestores() public {
        _alloc10d();
        vm.warp(t0 + 3 days);
        _fundLp(lp0, 1 ether, 1 ether);
        vm.prank(lp0);
        vm.expectRevert(abi.encodeWithSelector(IBondEscrow.EscrowBehind.selector, c1));
        vault.deposit(1 ether, type(uint256).max, type(uint256).max, lp0);
        _redeem(lp0, 1 ether, false);
        assertFalse(escrow.realize(32));
        assertFalse(escrow.realize(32));
        assertTrue(escrow.realize(32));
        _depositShares(lp0, 1 ether);
        assertEq(escrow.getLedger(c1).realized, 25.92 ether);
    }

    // ------------------------------------------------------------------
    // Escrow replacement
    // ------------------------------------------------------------------

    /// @notice Replacing the escrow while a bond is open (G05 V2-7, CE-G5-7). The old escrow still syncs, settles
    ///         (releasing the expired allocation in the vault) and refunds, but can no longer realize: the 8 days of
    ///         fees earned after the replacement (69.12, of which 62.208 for LPs) stay in it. The new escrow and module
    ///         serve new reservations and deposits. With the procedure (stop activations, let bonds expire, settle,
    ///         realize, then replace) nothing is stranded.
    function test_escrowReplacement_openBondsStrandLpPart_procedureAvoidsIt() public {
        uint256 id = _alloc10d();
        vm.warp(t0 + 2 days);
        escrow.realize(type(uint256).max);
        uint256 snap = vm.snapshotState();

        BondEscrow e2 = _deployEscrow(vault, RHO, RHO, T_MIN, PROTOCOL_BPS, protocol);
        CommitmentAuthorizer m2 = _deployBonded(vault, e2);
        vm.startPrank(owner);
        vault.setFeeEscrow(address(e2));
        vault.setAuthModule(address(m2));
        vm.stopPrank();
        vm.warp(t0 + 10 days);
        (uint256 charge, uint256 refund) = escrow.settle(id);
        assertEq(charge, 86.4 ether);
        assertEq(refund, 0);
        assertTrue(lens.getAllocation(vault, id).released);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NotFeeEscrow.selector, address(escrow)));
        escrow.realize(type(uint256).max);
        (uint256 strandedLp, uint256 strandedProtocol) = escrow.unrealized(c1);
        assertEq(strandedLp + strandedProtocol, 69.12 ether);
        assertEq(strandedLp, 62.208 ether);
        emit log_named_decimal_uint("LP fees stranded in the replaced escrow", strandedLp, 18);
        _depositShares(lp0, 1 ether); // deposits realize through the new escrow
        token1.mint(curator, 1e30);
        vm.prank(curator);
        token1.approve(address(e2), type(uint256).max);
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyS, c1, A);
        req.deadline = uint64(vm.getBlockTimestamp());
        vm.prank(curator);
        uint256 id2 = m2.activateDirectBonded(req, RHO);
        assertGt(e2.getBond(id2).bond, 0);

        vm.revertToState(snap);
        vm.prank(guardian);
        vault.setAuthModule(address(0)); // stop activations
        vm.warp(t0 + 10 days);
        escrow.settle(id);
        escrow.realize(type(uint256).max);
        e2 = _deployEscrow(vault, RHO, RHO, T_MIN, PROTOCOL_BPS, protocol); // the snapshot predates the first e2
        vm.prank(owner);
        vault.setFeeEscrow(address(e2));
        (strandedLp, strandedProtocol) = escrow.unrealized(c1);
        assertEq(strandedLp + strandedProtocol, 0, "nothing stranded");
        assertEq(escrow.getLedger(c1).realized, 86.4 ether);
    }

    /// @notice `setFeeEscrow`: owner only (the guardian cannot, even to unset), and a non-zero address must answer
    ///         `vault()` with this vault: an EOA, a contract without the getter and an escrow of another vault are
    ///         refused.
    function test_setFeeEscrow_authorizationAndInstallCheck() public {
        vm.prank(guardian);
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setFeeEscrow(address(0));
        vm.prank(attacker);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setFeeEscrow(address(escrow));
        SharedCommitmentVault other = new SharedCommitmentVault(manager, owner, c0, c1);
        address[3] memory bad = [attacker, address(token0), address(_deployEscrow(other, 0, 0, 0, 0, address(0)))];
        for (uint256 k; k < 3; ++k) {
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InvalidFeeEscrow.selector, bad[k]));
            vault.setFeeEscrow(bad[k]);
        }
        vm.expectEmit(address(vault));
        emit ISharedCommitmentVault.FeeEscrowSet(address(escrow), address(0));
        vm.prank(owner);
        vault.setFeeEscrow(address(0));
        assertEq(lens.feeEscrow(vault), address(0));
    }

    // ------------------------------------------------------------------
    // Several hooks and curators on one asset
    // ------------------------------------------------------------------

    /// @notice Three curators (EOA-signed with a separate payer, ERC-1271 wallet, direct) bond reservations of asset1
    ///         for three hooks (A, B and the 1:1 hook). Fills, late syncs, an early cancellation and expiry later,
    ///         every bond is settled, every fee realized and claimed: the bonds split exactly into LP fees (all in B_1),
    ///         protocol fees and refunds, the escrow holds nothing, and the vault's claims equal its backing.
    function test_sharedAsset_threeHooksThreeCurators_conserve() public {
        uint256 b1Before = lens.backing(vault, c1);
        uint256[3] memory ids;
        ICommitmentAuthorizer.BondedAuthorization memory b = _bondedAuthz(signer, keyA, c1, 50_000 ether, payer, RHO);
        bytes memory sig = _signBonded(signerKey, b);
        vm.prank(payer);
        ids[0] = bonded.activateBonded(b, keyA, sig);
        ICommitmentAuthorizer.BondedAuthorization memory w =
            _bondedAuthz(address(wallet), keyB, c1, 40_000 ether, payer, RHO);
        wallet.approve(bonded.hashBondedAuthorization(w), true);
        vm.prank(payer);
        ids[1] = bonded.activateBonded(w, keyB, "");
        ids[2] = _allocateUntil(keyS, c1, 30_000 ether, uint64(t0 + 1 days));
        assertEq(escrow.getLedger(c1).rate, 120_000 ether * RHO);

        vm.warp(t0 + 3 hours);
        _swap(keyA, true, 1000 ether, ids[0]);
        _swap(keyB, true, 2000 ether, ids[1]);
        _swap(keyS, true, 3000 ether, ids[2]);
        escrow.sync(ids[2]); // the others sync late
        vm.warp(t0 + 6 hours);
        vm.prank(address(wallet));
        vault.cancelAllocation(ids[1]);
        escrow.sync(ids[1]); // observed at once; allocation ids[0] is never synced before settlement
        escrow.realize();
        vm.warp(t0 + 2 days);
        uint256 bonds;
        uint256 refunds;
        uint256 lpFromBacking;
        for (uint256 k; k < 3; ++k) {
            bonds += escrow.getBond(ids[k]).bond;
            (, uint256 r) = escrow.settle(ids[k]);
            refunds += r;
        }
        escrow.realize();
        vm.prank(payer);
        escrow.claimRefund(payer);
        vm.prank(curator);
        escrow.claimRefund(curator);
        vm.prank(protocol);
        (, uint256 protocolPaid) = escrow.claimProtocol(protocol);

        IBondEscrow.Ledger memory l = escrow.getLedger(c1);
        uint256 consumed;
        for (uint256 k; k < 3; ++k) {
            consumed += lens.getAllocation(vault, ids[k]).consumed;
        }
        uint256 inputs = lens.backing(vault, c0) - VAULT_FUNDING; // 1:1-ish fills: asset0 received
        lpFromBacking = lens.backing(vault, c1) + consumed - b1Before;
        assertEq(l.realized, l.settledCharges, "everything earned is realized");
        assertEq(lpFromBacking + protocolPaid, l.realized, "LP fees in B_1 + protocol fees = charges");
        assertEq(bonds, l.settledCharges + refunds, "bonds = charges + refunds");
        assertEq(
            2 * PAYER_FUNDS - token1.balanceOf(payer) - token1.balanceOf(curator), l.settledCharges, "payers' net cost"
        );
        assertEq(_claims(address(escrow), c1), 0, "escrow holds nothing");
        assertGt(inputs, 0);
        _assertEscrowIdentity();
        _assertAccountingConsistent();
    }
}
