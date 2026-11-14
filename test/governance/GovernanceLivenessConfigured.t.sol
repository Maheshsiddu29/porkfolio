// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {IMarketRiskAdapter} from "../../src/interfaces/IMarketRiskAdapter.sol";
import {VaultGovernor} from "../../src/governance/VaultGovernor.sol";
import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {VaultStateReader} from "../../src/libraries/VaultStateReader.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {MockRiskAdapter} from "../utils/MockRiskAdapter.sol";
import {AdminBatch, QueueGriefer} from "../utils/GovernanceActors.sol";

using VaultStateReader for SharedCommitmentVault;

/// @notice G02 withdrawal and LONG_DELAY liveness with inventory targets configured, under the deployment defaults of
///         `script/DeploySystem.s.sol` (seed = the fixture's 1,000,000 of each asset): adapter mode, targets on both
///         assets at the seeded holding per share (tau = 1e18), kappa = 1%, buffer floor 10% of the seed, exposure caps
///         of 50% on every scope, curator ceilings of 20% of the seed, flow caps of 40% of the seed. The governor has
///         G02's delays (3 / 32 / 7 days). `GovernanceLiveness.t.sol` keeps the unfloored special case (static mode,
///         no target on the committed asset), which is the worst case one commitment can withhold.
///
///         A redemption of s shares is paid at once only up to the deliverable count floor((N_a - Q_a) * S / N_a) of
///         both assets, so it queues exactly when Q_a > N_a - s * N_a / S: when the live commitments of an asset exceed
///         the backing of the shares that are not being redeemed. These tests show what that requires once targets are
///         set:
///         - Right after any admission Q_a <= N_a - L_a, about kappa * N_a, so about (1 - kappa) of all shares can exit
///           at once. G02's constructions (one share queued behind a full commitment; a curator-LP rotating "commit
///           everything, queue one share") are refused, and a LONG_DELAY change executes while commitments are live.
///         - Q_a is at most the sum of the curator ceilings, so backing outside the redeeming coalition that is at least
///           that sum can never be held, whatever capital the coalition brings.
///         - Below that, a queue can still be held: holders of more than 1 - Q_a / N_a of the shares exit after the
///           admission (LP exits shrink the room, CE-2), and every rotation repeats this with fresh capital, about
///           Q_a / kappa deposited and redeemed in one transaction. The guardian's levers end it, and once every
///           commitment made before the lever has expired, the admin's batch finalizes the queue without any release.
contract GovernanceLivenessConfiguredTest is VaultTestBase {
    uint256 internal constant SEED = VAULT_FUNDING;
    uint24 internal constant KAPPA = 10_000; // 1%, DeploySystem's KAPPA_PIPS default
    uint256 internal constant BUFFER = SEED / 10;
    uint256 internal constant CEILING = SEED / 5;
    uint256 internal constant FLOW_CAP = SEED * 4 / 10;
    uint16 internal constant EXPOSURE_BPS = 5000;

    address internal signer = makeAddr("adminSigner");
    address internal guardian = makeAddr("guardian");
    address internal lpA = makeAddr("lpA");
    AdminBatch internal admin;
    VaultGovernor internal gov;
    QueueGriefer internal griefer; // a registered curator that is also an LP, as in G02
    uint256 internal tau;
    address internal v;
    bytes internal loosen; // LONG_DELAY: tolerance 1% -> 2% on both assets

    function setUp() public override {
        super.setUp();
        v = address(vault);
        tau = FullMath.mulDiv(vault.backing(c0), 1e18, vault.totalShares());
        assertEq(tau, 1e18, "the seed gives one raw unit of each asset per share");
        admin = new AdminBatch(signer);
        gov = new VaultGovernor(v, address(admin), 3 days, 32 days, 7 days);
        griefer = new QueueGriefer(vault, auth, keyA, c0);
        token0.mint(address(griefer), 100 * SEED);
        token1.mint(address(griefer), 100 * SEED);
        MockRiskAdapter adapter = new MockRiskAdapter(address(token0), address(token1), 18, 18, keccak256("deploy"));
        adapter.set(FixedPoint96.Q96, 1000, type(uint256).max);

        vm.startPrank(owner);
        vault.setGuardian(guardian);
        vault.setCurator(address(griefer), true);
        vault.setCuratorCeiling(curator, c0, CEILING);
        vault.setCuratorCeiling(curator, c1, CEILING);
        vault.setCuratorCeiling(address(griefer), c0, CEILING);
        _limits(ISharedCommitmentVault.RiskScope.Vault, address(0));
        _limits(ISharedCommitmentVault.RiskScope.Hook, address(hookA));
        _limits(ISharedCommitmentVault.RiskScope.Hook, address(hookB));
        _limits(ISharedCommitmentVault.RiskScope.Curator, curator);
        _limits(ISharedCommitmentVault.RiskScope.Curator, address(griefer));
        vault.setRiskBounds(100, 20_000);
        vault.setBufferFloor(c0, BUFFER);
        vault.setBufferFloor(c1, BUFFER);
        vault.setInventoryBounds(tau, tau, KAPPA, KAPPA);
        vault.setRiskAdapter(IMarketRiskAdapter(address(adapter)));
        vault.transferOwnership(address(gov));
        vm.stopPrank();
        _run1(address(gov), abi.encodeCall(gov.acceptVaultOwnership, ()));
        loosen = abi.encodeCall(vault.setInventoryBounds, (tau, tau, 2 * KAPPA, 2 * KAPPA));
    }

    // =================================================================== helpers

    function _limits(ISharedCommitmentVault.RiskScope scope, address account) internal {
        vault.setRiskLimit(scope, account, c0, FLOW_CAP, EXPOSURE_BPS);
        vault.setRiskLimit(scope, account, c1, FLOW_CAP, EXPOSURE_BPS);
    }

    function _run1(address target, bytes memory data) internal {
        AdminBatch.Call[] memory calls = new AdminBatch.Call[](1);
        calls[0] = AdminBatch.Call(target, data);
        vm.prank(signer);
        admin.run(calls);
    }

    function _queueGov(bytes memory data) internal returns (uint256 eta) {
        eta = vm.getBlockTimestamp() + gov.delayFor(v, data);
        _run1(address(gov), abi.encodeCall(gov.queue, (v, data)));
    }

    /// @dev The admin's batch with no release: process the queue (which sweeps both expiry rings first), execute.
    function _tryExecute(bytes memory data) internal returns (bool ok, bytes memory err) {
        AdminBatch.Call[] memory calls = new AdminBatch.Call[](2);
        calls[0] = AdminBatch.Call(v, abi.encodeCall(vault.processQueue, (256)));
        calls[1] = AdminBatch.Call(address(gov), abi.encodeCall(gov.execute, (v, data)));
        vm.prank(signer);
        try admin.run(calls) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
    }

    function _assertBlocked(bytes memory data) internal {
        (bool ok, bytes memory err) = _tryExecute(data);
        assertFalse(ok, "LONG_DELAY change executed");
        assertEq(bytes4(err), VaultGovernor.PendingWithdrawals.selector, "refused for another reason");
    }

    function _assertExecutes(bytes memory data) internal {
        (bool ok, bytes memory err) = _tryExecute(data);
        if (!ok) {
            emit log_named_bytes("revert", err);
            fail();
        }
        assertEq(vault.pendingShares(), 0);
    }

    /// @dev The honest fixture curator commits `amount` of asset0 for `horizon` seconds.
    function _commit(uint256 amount, uint256 horizon) internal returns (uint256 id) {
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyA, c0, uint128(amount));
        r.expiry = _hourAligned(vm.getBlockTimestamp() + horizon);
        vm.prank(curator);
        id = auth.activateDirect(r);
    }

    function _expectRefused(uint256 q, uint256 available) internal {
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyA, c0, uint128(q));
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientBacking.selector, q, available));
        auth.activateDirect(r);
    }

    // =================================================================== admission, exits, room

    /// @notice A reservation is admitted while every unit of it is sellable (Q = N - L exactly), LP exits then shrink
    ///         the room under it, and the room rule refuses every new reservation of that asset while Q exceeds the
    ///         smaller room. Exits are never refused. Admission returns at expiry with no release.
    ///
    ///         Numbers: lpA brings the vault to 10,000,000 of each asset; L = ceil(0.99 * S) gives a room of 100,000,
    ///         all of it committed. lpA's full exit lowers N by 9,000,000 but L only by 8,910,000, so the room falls to
    ///         10,000 under a reservation of 100,000 (90,000 of it now below the floor, CE-2).
    function test_configured_admittedWhileSellable_exitsShrinkRoom_admissionConstrained() public {
        _depositShares(lpA, 9 * SEED);
        uint256 room = lens.inventoryRoom(vault, c0);
        assertEq(room, 100_000 ether, "kappa * N at tau = holding per share");
        assertEq(vault.admissibleCapacity(c0), room, "the room binds, not the buffer or the caps");
        uint256 id = _commit(room, 30 days);
        assertEq(vault.reserved(c0), lens.inventoryRoom(vault, c0), "admitted while sellable: Q = N - L");
        assertGe(lens.deliverableShares(vault), 9 * SEED, "lpA's 90% stays deliverable");

        (uint256 instant,,, uint256 rid) = _redeem(lpA, 9 * SEED, true);
        assertEq(instant, 9 * SEED, "the exit is paid at once");
        assertEq(rid, 0);
        assertEq(lens.inventoryRoom(vault, c0), 10_000 ether, "room after the exit");
        assertEq(vault.reserved(c0), room, "the reservation is unchanged and now exceeds the room");

        assertEq(vault.admissibleCapacity(c0), 0, "no new asset0 reservation while Q exceeds the room");
        _expectRefused(1, 0);
        assertEq(vault.admissibleCapacity(c1), lens.inventoryRoom(vault, c1), "asset1 carries no commitment");
        (instant,,, rid) = _redeem(lp0, 500_000 ether, true);
        assertEq(rid, 0, "remaining LPs still exit at once: free asset0 is N - Q = 900,000");

        vm.warp(vault.getAllocation(id).expiry);
        assertEq(vault.admissibleCapacity(c0), lens.inventoryRoom(vault, c0), "expired capacity no longer counts");
        _commit(vault.admissibleCapacity(c0), 30 days);
        assertFalse(vault.getAllocation(id).released, "nothing was released");
    }

    // =================================================================== G02 constructions

    /// @notice G02's two blocking constructions fail under the configured policy, and a LONG_DELAY change executes at
    ///         eta while a commitment is live. (a) The curator-LP rotation (cancel, commit everything admissible,
    ///         queue one share, one transaction) reverts at its queue step: the share is paid at once. (b) One share
    ///         bought before a full commitment is also paid at once: the commitment is capped at the room, about 1% of
    ///         N, so about 99% of the shares stay deliverable.
    function test_configured_g02ConstructionsRefused_changeExecutesWhileCommitted() public {
        uint256 eta = _queueGov(loosen);
        _depositShares(attacker, 1);
        griefer.deposit(100);
        vm.warp(eta - 1 days);

        vm.expectRevert(bytes("not queued"));
        griefer.rotate(30 days, 1);

        uint256 id = _commit(vault.admissibleCapacity(c0), 30 days);
        assertEq(vault.reserved(c0), lens.inventoryRoom(vault, c0), "a full commitment: Q = N - L");
        assertGe(lens.deliverableShares(vault) * 100, vault.totalShares() * 98, "about 99% of shares deliverable");
        (uint256 instant,,, uint256 rid) = _redeem(attacker, 1, true);
        assertEq(instant, 1);
        assertEq(rid, 0, "one share is paid at once");

        vm.warp(eta);
        vm.expectRevert(bytes("not queued")); // front-running the admin in the same block does not help
        griefer.queue(1);
        assertGt(lens.liveReserved(vault, c0), 0, "the commitment is live at eta");
        _assertExecutes(loosen);
        assertFalse(vault.getAllocation(id).released);
        assertEq(vault.inventoryTolerancePips(0), 2 * KAPPA);
    }

    // =================================================================== the narrower property

    /// @notice Backing outside the redeeming coalition that is at least the sum of the curator ceilings can never be
    ///         held. The coalition deposits 99 times the vault (its room is then 1,000,000, so the ceilings bind), both
    ///         curators commit their whole ceiling (Q = 400,000 against honest backing 1,000,000), and the coalition's
    ///         redemption of everything it deposited is still paid at once, as is a later single share. The LONG_DELAY
    ///         change executes at eta with 400,000 committed.
    function test_configured_honestBackingAboveCeilings_cannotBeHeld() public {
        uint256 eta = _queueGov(loosen);
        _depositShares(attacker, 1);
        vm.warp(eta - 1 days);

        vm.expectRevert(bytes("not queued"));
        griefer.rotateWithCapital(30 days, 99 * SEED);

        griefer.deposit(99 * SEED);
        assertGe(vault.admissibleCapacity(c0), 2 * CEILING, "the room exceeds both ceilings");
        _commit(CEILING, 30 days);
        griefer.commitAll(30 days);
        assertEq(vault.reserved(c0), 2 * CEILING, "every curator ceiling used");
        (uint256 instant, uint256 rid) = griefer.redeem(99 * SEED);
        assertEq(instant, 99 * SEED, "the coalition's whole deposit leaves at once");
        assertEq(rid, 0);
        (instant,,, rid) = _redeem(attacker, 1, true);
        assertEq(rid, 0, "and a single share after it");

        vm.warp(eta);
        assertEq(lens.liveReserved(vault, c0), 2 * CEILING);
        _assertExecutes(loosen);
    }

    /// @notice The same over random coalition capital and commitment sizes: while the backing of the shares outside the
    ///         coalition is at least the sum of the ceilings, the coalition's full redemption and any later single
    ///         share are paid at once.
    function testFuzz_configured_noQueueWhileOutsideBackingCoversCeilings(
        uint256 capital,
        uint256 honestFrac,
        uint256 coalitionFrac
    ) public {
        capital = bound(capital, 1 ether, 99 * SEED); // the griefer holds 100 * SEED of each asset
        _depositShares(attacker, 1);
        griefer.deposit(capital);
        uint256 a = vault.admissibleCapacity(c0);
        uint256 honest = FullMath.mulDiv(a < CEILING ? a : CEILING, bound(honestFrac, 0, 100), 100);
        if (honest != 0) _commit(honest, 30 days);
        if (vault.admissibleCapacity(c0) != 0 && bound(coalitionFrac, 0, 1) == 1) griefer.commitAll(30 days);
        assertLe(vault.reserved(c0), 2 * CEILING);
        (uint256 instant, uint256 rid) = griefer.redeem(capital);
        assertEq(instant, capital, "coalition exit paid at once");
        assertEq(rid, 0);
        (,,, rid) = _redeem(attacker, 1, true);
        assertEq(rid, 0, "a single share paid at once");
    }

    /// @notice What is still possible below that bound, and how it ends. Honest LPs have left all but 50,000 of each
    ///         asset, less than one curator ceiling. The coalition (a curator that is also an LP) then holds the queue:
    ///         1. it deposits 10,000,000 (200 times the honest backing), commits the room of about 100,500 while it is
    ///            sellable, and redeems the deposit: about 50,500 of its own shares queue (CE-2: its exit shrank the
    ///            room under the commitment). An honest LP queues behind them.
    ///         2. Rotating without fresh capital fails: Q exceeds the room the exits left, and the buffer and the
    ///            queue's claim D take the rest.
    ///         3. Rotating with the same capital every 9 days succeeds: each rotation's redemption first finalizes the
    ///            older entries (the honest LP at the first rotation), then queues new ones, so pendingShares never
    ///            reaches zero and the change is refused at eta.
    ///         4. The guardian stops new commitments (buffer floor at the maximum) and the admin re-queues; further
    ///            rotations revert.
    ///         5. When every commitment made before the lever has expired, the admin's batch, which releases nothing,
    ///            sweeps the expired capacity out of Q_0, finalizes the queue and executes.
    function test_configured_heldOnlyWithFreshCapital_leverAndExpiryRecoverWithoutRelease() public {
        _redeem(lp0, 950_000 ether, true);
        uint256 honestBacking = vault.backing(c0);
        assertEq(honestBacking, 50_000 ether);
        uint256 eta = _queueGov(loosen);
        uint256 capital = 10 * SEED;

        uint256 rid = griefer.rotateWithCapital(30 days, capital);
        uint256 q = vault.reserved(c0);
        assertGt(q, honestBacking, "commitments exceed the backing outside the coalition");
        assertLe(q, CEILING);
        assertEq(lens.deliverableShares(vault), 0);
        console2.log("capital / committed / coalition shares queued:", capital, q, vault.getRequest(rid).sharesPending);
        (,,, uint256 honest) = _redeem(lp0, 1000 ether, true);
        assertGt(honest, 0, "an honest LP is queued too");

        assertEq(vault.admissibleCapacity(c0), 0, "no room and no first-term capacity left");
        vm.expectRevert();
        griefer.rotate(30 days, 1);

        for (uint256 k; k < 3; ++k) {
            vm.warp(vm.getBlockTimestamp() + 9 days);
            uint256 next = griefer.rotateWithCapital(30 days, capital);
            assertEq(vault.getRequest(rid).sharesPending, 0, "the previous entry was finalized by the rotation");
            if (k == 0) {
                assertEq(vault.getRequest(honest).sharesPending, 0, "honest LP finalized at the first rotation");
            }
            assertGt(vault.pendingShares(), 0);
            rid = next;
        }
        vm.warp(eta);
        _assertBlocked(loosen);

        vm.prank(guardian);
        vault.setBufferFloor(c0, type(uint256).max);
        _run1(address(gov), abi.encodeCall(gov.cancel, (v, loosen)));
        uint256 eta2 = _queueGov(loosen);
        uint256 lastId = griefer.liveAllocation();
        assertLe(vault.getAllocation(lastId).expiry, eta2, "a fresh LONG_DELAY outlasts every older commitment");
        vm.warp(eta + 9 days);
        vm.expectRevert();
        griefer.rotateWithCapital(30 days, capital);

        vm.warp(eta2);
        assertEq(lens.liveReserved(vault, c0), 0, "every commitment has expired");
        assertGt(vault.reserved(c0), 0, "stored Q still counts it until a sweep");
        _assertExecutes(loosen);
        assertEq(vault.reserved(c0), 0, "the batch's sweep recognized the expiry");
        assertEq(vault.getRequest(rid).sharesPending, 0, "the queue is finalized");
        assertFalse(vault.getAllocation(lastId).released, "recovered without a release");
        assertEq(vault.inventoryTolerancePips(0), 2 * KAPPA);
    }
}
