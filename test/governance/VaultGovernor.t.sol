// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {IMarketRiskAdapter} from "../../src/interfaces/IMarketRiskAdapter.sol";
import {VaultGovernor} from "../../src/governance/VaultGovernor.sol";
import {BaseCompatibleHook} from "../../src/hooks/BaseCompatibleHook.sol";
import {HookA_DynamicFee} from "../../src/hooks/HookA_DynamicFee.sol";
import {HookB_BoundedImpact} from "../../src/hooks/HookB_BoundedImpact.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {MockRiskAdapter} from "../utils/MockRiskAdapter.sol";
import {ProductionArtifacts} from "../utils/ProductionArtifacts.sol";
import {VaultStateReader} from "../../src/libraries/VaultStateReader.sol";

using VaultStateReader for SharedCommitmentVault;

/// @dev Claims to be a hook of the governed vault owned by the governor, and tries to re-enter the governor when called.
contract ReenteringFakeHook {
    address public immutable hookOwner;
    address public immutable vault;
    bytes public lastError;

    constructor(address governor, address vault_) {
        hookOwner = governor;
        vault = vault_;
    }

    function poke() external {
        // A target executed by the governor sees msg.sender == governor, but every governor entry point that matters
        // checks for `admin`, so these re-entries fail.
        (bool ok, bytes memory err) = msg.sender.call(abi.encodeCall(VaultGovernor.queue, (vault, hex"00000000")));
        require(!ok, "queue re-entry succeeded");
        lastError = err;
        (ok,) = msg.sender.call(abi.encodeCall(VaultGovernor.acceptVaultOwnership, ()));
        require(!ok, "accept re-entry succeeded");
    }
}

/// @notice The governor as owner of the vault and of both hooks. Every call waits its delay, runs once inside its window,
///         goes only to the target it was queued for, and can be canceled by the admin or the guardian (never the
///         guardian's own replacement). The guardian keeps its immediate, risk-reducing powers on the vault. A
///         LONG_DELAY change cannot apply while any LP is waiting in the withdrawal queue.
contract VaultGovernorTest is VaultTestBase {
    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    VaultGovernor internal gov;
    HookA_DynamicFee internal govHookA;
    HookB_BoundedImpact internal govHookB;
    PoolKey internal govKeyA;
    PoolKey internal govKeyB;
    uint256 internal tau;
    address internal v;

    function setUp() public override {
        super.setUp();
        v = address(vault);
        tau = FullMath.mulDiv(vault.backing(c0), 1e18, vault.totalShares());
        gov = new VaultGovernor(v, admin, 3 days, 32 days, 7 days);

        // Hooks whose immutable hookOwner is the governor (the production deployment).
        govHookA = HookA_DynamicFee(_hookAddress(0xA2));
        govHookB = HookB_BoundedImpact(_hookAddress(0xB2));
        deployCodeTo(ProductionArtifacts.HOOK_A, abi.encode(manager, vault, gov), address(govHookA));
        deployCodeTo(ProductionArtifacts.HOOK_B, abi.encode(manager, vault, gov), address(govHookB));
        govKeyA = PoolKey(c0, c1, 3000, 60, IHooks(address(govHookA)));
        govKeyB = PoolKey(c0, c1, 500, 10, IHooks(address(govHookB)));

        vm.startPrank(owner);
        vault.setGuardian(guardian);
        vault.setInventoryBounds(tau, tau, 50_000, 50_000);
        vault.setRiskBounds(100, 5000);
        vault.transferOwnership(address(gov));
        vm.stopPrank();
        vm.prank(admin);
        gov.acceptVaultOwnership();
    }

    function _queue(address target, bytes memory data) internal returns (uint256 eta) {
        vm.prank(admin);
        (, eta) = gov.queue(target, data);
    }

    function _execute(address target, bytes memory data) internal {
        vm.prank(admin);
        gov.execute(target, data);
    }

    /// @dev Computed locally: calling `gov.operationId` would consume a pending `vm.prank`.
    function _id(address target, bytes memory data) internal pure returns (bytes32) {
        return keccak256(abi.encode(target, data));
    }

    function test_operationId_bindsTargetAndCalldata() public view {
        bytes memory data = abi.encodeCall(vault.setPaused, (true));
        assertEq(gov.operationId(v, data), _id(v, data));
        assertTrue(gov.operationId(v, data) != gov.operationId(address(govHookA), data));
    }

    // ------------------------------------------------------------------ handover and construction

    function test_handover_governorOwnsVaultAndHooks() public {
        assertEq(vault.owner(), address(gov));
        assertEq(vault.pendingOwner(), address(0));
        assertEq(govHookA.hookOwner(), address(gov));
        assertEq(govHookB.hookOwner(), address(gov));
        vm.prank(owner);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setRiskBounds(0, 5000);
        vm.prank(attacker);
        vm.expectRevert(VaultGovernor.NotAdmin.selector);
        gov.acceptVaultOwnership();
    }

    function test_constructor_rejectsBadDelays() public {
        vm.expectRevert(VaultGovernor.ZeroAddress.selector);
        new VaultGovernor(address(0), admin, 1, 1, 1);
        vm.expectRevert(VaultGovernor.InvalidDelays.selector);
        new VaultGovernor(v, admin, 0, 1, 1);
        vm.expectRevert(VaultGovernor.InvalidDelays.selector);
        new VaultGovernor(v, admin, 2 days, 1 days, 1);
        vm.expectRevert(VaultGovernor.InvalidDelays.selector);
        new VaultGovernor(v, admin, 1, 1, 0);
        vm.expectRevert(VaultGovernor.InvalidDelays.selector);
        new VaultGovernor(v, admin, 1, 366 days, 1);
        VaultGovernor g = new VaultGovernor(v, admin, 10 minutes, 1 hours, 1 days); // a labelled testnet setting
        assertEq(g.DELAY(), 10 minutes);
        assertEq(g.LONG_DELAY(), 1 hours);
        assertEq(g.GRACE(), 1 days);
    }

    // ------------------------------------------------------------------ delay classes and target binding

    /// @notice The long delay applies exactly to the vault's floor setter and ownership transfer; the selectors the
    ///         governor spells out are the vault's. Every hook call is DELAY.
    function test_delayClasses_matchVaultSelectors() public view {
        assertEq(gov.delayFor(v, abi.encodeCall(vault.setInventoryBounds, (0, 0, 0, 0))), 32 days);
        assertEq(gov.delayFor(v, abi.encodeCall(vault.transferOwnership, (address(1)))), 32 days);
        assertEq(gov.delayFor(v, abi.encodeCall(vault.setRiskAdapter, (IMarketRiskAdapter(address(0))))), 3 days);
        assertEq(gov.delayFor(v, abi.encodeCall(vault.setRiskBounds, (0, 0))), 3 days);
        assertEq(gov.delayFor(v, abi.encodeCall(vault.setPaused, (false))), 3 days);
        assertEq(gov.delayFor(v, abi.encodeCall(vault.setGuardian, (address(0)))), 3 days);
        assertEq(gov.delayFor(v, abi.encodeCall(vault.setAuthModule, (address(0)))), 3 days);
        BaseCompatibleHook.CoreParams memory p;
        assertEq(gov.delayFor(address(govHookA), abi.encodeCall(govHookA.configureCore, (govKeyA, p))), 3 days);
        assertEq(gov.delayFor(address(govHookB), abi.encodeCall(govHookB.configureStrategy, (govKeyB, 0, 1))), 3 days);
    }

    /// @notice Only the vault and hooks of this vault owned by this governor can be targeted: not an EOA, not an
    ///         unrelated contract, not a hook owned by someone else, not this governor's hook built for another vault.
    function test_targets_onlyVaultAndOwnHooks() public {
        bytes memory data = abi.encodeWithSignature("anything()");
        address[] memory bad = new address[](5);
        bad[0] = attacker; // no code
        bad[1] = address(token0); // unrelated contract
        bad[2] = address(hookA); // a hook of this vault owned by `hookOwner`, not the governor
        bad[3] = address(gov); // itself
        SharedCommitmentVault other = new SharedCommitmentVault(manager, owner, c0, c1);
        bad[4] = _hookAddress(0xC3);
        deployCodeTo(ProductionArtifacts.HOOK_B, abi.encode(manager, other, gov), bad[4]);
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(admin);
            vm.expectRevert(abi.encodeWithSelector(VaultGovernor.InvalidTarget.selector, bad[i]));
            gov.queue(bad[i], data);
        }
    }

    /// @notice An executor cannot substitute anything: other arguments, another selector or another target are all
    ///         different ids, so `execute` finds nothing queued.
    function test_execute_cannotSubstituteCalldataOrTarget() public {
        bytes memory queued = abi.encodeCall(vault.setRiskBounds, (100, 6000));
        uint256 eta = _queue(v, queued);
        vm.warp(eta);
        bytes memory otherArgs = abi.encodeCall(vault.setRiskBounds, (0, 900_000));
        bytes memory otherSelector = abi.encodeCall(vault.setPaused, (false));
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.NotQueued.selector, _id(v, otherArgs)));
        gov.execute(v, otherArgs);
        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.NotQueued.selector, _id(v, otherSelector)));
        gov.execute(v, otherSelector);
        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.NotQueued.selector, _id(address(govHookB), queued)));
        gov.execute(address(govHookB), queued);
        gov.execute(v, queued);
        vm.stopPrank();
        assertEq(vault.maxUncertaintyPips(), 6000);
    }

    /// @notice Not before eta, once inside [eta, eta + GRACE], never twice: replaying the same calldata needs a new
    ///         queue and a new delay. Every step leaves an event naming the id, and Queued carries target and calldata.
    function test_delay_window_replay_andEvents() public {
        bytes memory data = abi.encodeCall(vault.setRiskBounds, (0, 9000)); // loosens both
        bytes32 id = _id(v, data);
        vm.expectEmit(address(gov));
        emit VaultGovernor.Queued(id, v, vm.getBlockTimestamp() + 3 days, data);
        uint256 eta = _queue(v, data);

        vm.warp(eta - 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.NotExecutable.selector, id, eta));
        gov.execute(v, data);

        vm.warp(eta);
        vm.expectEmit(address(gov));
        emit VaultGovernor.Executed(id, v);
        _execute(v, data);
        assertEq(vault.maxUncertaintyPips(), 9000);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.NotQueued.selector, id));
        gov.execute(v, data);

        uint256 eta2 = _queue(v, data); // re-arming is a fresh, public delay
        assertEq(eta2, vm.getBlockTimestamp() + 3 days);
    }

    function test_expiry_afterGrace() public {
        bytes memory data = abi.encodeCall(vault.setRiskBounds, (0, 5000));
        uint256 eta = _queue(v, data);
        vm.warp(eta + 7 days + 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.NotExecutable.selector, _id(v, data), eta));
        gov.execute(v, data);
        vm.prank(admin);
        gov.cancel(v, data);
        assertEq(gov.eta(_id(v, data)), 0);
    }

    function test_longDelay_forFloorChange() public {
        bytes memory data = abi.encodeCall(vault.setInventoryBounds, (tau, tau, 100_000, 100_000));
        uint256 eta = _queue(v, data);
        assertEq(eta, T0 + 32 days);
        vm.warp(T0 + 3 days);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.NotExecutable.selector, _id(v, data), eta));
        gov.execute(v, data);
        vm.warp(eta);
        _execute(v, data);
        assertEq(vault.inventoryTolerancePips(0), 100_000);
    }

    // ------------------------------------------------------------------ cancellation

    /// @notice Admin and guardian may cancel, including hook changes; the guardian may not cancel its own
    ///         replacement; nobody else may cancel.
    function test_cancel_roles() public {
        bytes memory loosen = abi.encodeCall(vault.setRiskBounds, (0, 9000));
        bytes memory replaceGuardian = abi.encodeCall(vault.setGuardian, (makeAddr("newGuardian")));
        bytes memory hookChange = abi.encodeCall(govHookB.configureStrategy, (govKeyB, 0, 999_999));
        _queue(v, loosen);
        _queue(v, replaceGuardian);
        _queue(address(govHookB), hookChange);

        vm.prank(attacker);
        vm.expectRevert(VaultGovernor.NotAllowedToCancel.selector);
        gov.cancel(v, loosen);

        vm.prank(guardian);
        vm.expectRevert(VaultGovernor.NotAllowedToCancel.selector);
        gov.cancel(v, replaceGuardian);

        vm.expectEmit(address(gov));
        emit VaultGovernor.Canceled(_id(v, loosen), guardian);
        vm.prank(guardian);
        gov.cancel(v, loosen);
        vm.prank(guardian);
        gov.cancel(address(govHookB), hookChange);

        vm.prank(admin);
        gov.cancel(v, replaceGuardian);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.NotQueued.selector, _id(v, loosen)));
        gov.cancel(v, loosen);
    }

    /// @notice A compromised admin (scheduler) cannot loosen anything before its delay, cannot stop the guardian
    ///         cancelling, and replacing the guardian (non-cancellable) still leaves every loosening its full delay
    ///         from its own queue time. The guardian's tightening stays immediate throughout.
    function test_compromisedScheduler_cannotShortenAnyDelay() public {
        uint256 t0 = T0; // setUp warped here; block.timestamp is re-read after vm.warp under via-IR
        bytes memory floorOff = abi.encodeCall(vault.setInventoryBounds, (0, 0, 1e6, 1e6));
        bytes memory takeGuardian = abi.encodeCall(vault.setGuardian, (admin));
        uint256 floorEta = _queue(v, floorOff);
        uint256 guardianEta = _queue(v, takeGuardian);

        vm.prank(guardian);
        gov.cancel(v, floorOff); // the honest guardian cancels the loosening
        vm.prank(guardian);
        vault.setInventoryBounds(tau, tau, 10_000, 10_000); // and tightens at once

        vm.warp(guardianEta);
        _execute(v, takeGuardian); // the guardian could not stop its own replacement
        assertEq(vault.guardian(), admin);

        uint256 eta2 = _queue(v, floorOff); // re-armed: a fresh LONG_DELAY from now, not from t0
        assertEq(eta2, t0 + 3 days + 32 days);
        assertGt(eta2, floorEta);
        vm.warp(eta2 - 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.NotExecutable.selector, _id(v, floorOff), eta2));
        gov.execute(v, floorOff);
    }

    /// @notice Known limitation, not a bypass: the vault ignores trailing calldata, so the same effect can be queued under
    ///         two ids. Each still waits its full delay and each can be canceled; monitors must decode, not compare ids.
    function test_trailingBytes_areSeparateIds_eachDelayedAndCancellable() public {
        bytes memory data = abi.encodeCall(vault.setRiskBounds, (0, 7000));
        bytes memory padded = bytes.concat(data, bytes32(0));
        uint256 e1 = _queue(v, data);
        uint256 e2 = _queue(v, padded);
        assertTrue(_id(v, data) != _id(v, padded));
        assertEq(e1, e2);
        vm.prank(guardian);
        gov.cancel(v, data);
        vm.prank(guardian);
        gov.cancel(v, padded);
        vm.warp(e1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.NotQueued.selector, _id(v, padded)));
        gov.execute(v, padded);
    }

    // ------------------------------------------------------------------ execution failures and re-entry

    /// @notice A change the vault rejects fails at execution with the vault's own error and stays queued, so it can be
    ///         inspected and canceled.
    function test_incorrectConfiguration_revertsAndStaysQueued() public {
        MockRiskAdapter swapped = new MockRiskAdapter(address(token1), address(token0), 18, 18, bytes32(0));
        bytes memory data = abi.encodeCall(vault.setRiskAdapter, (IMarketRiskAdapter(address(swapped))));
        uint256 eta = _queue(v, data);
        vm.warp(eta);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InvalidRiskAdapter.selector, address(swapped)));
        gov.execute(v, data);
        assertEq(gov.eta(_id(v, data)), eta, "still queued");
    }

    function test_onlyAdmin_queuesAndExecutes_noDuplicates() public {
        bytes memory data = abi.encodeCall(vault.setPaused, (false));
        vm.prank(attacker);
        vm.expectRevert(VaultGovernor.NotAdmin.selector);
        gov.queue(v, data);
        _queue(v, data);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.AlreadyQueued.selector, _id(v, data)));
        gov.queue(v, data);
        vm.warp(T0 + 3 days);
        vm.prank(attacker);
        vm.expectRevert(VaultGovernor.NotAdmin.selector);
        gov.execute(v, data);
        vm.prank(guardian);
        vm.expectRevert(VaultGovernor.NotAdmin.selector);
        gov.execute(v, data);
        vm.prank(admin);
        vm.expectRevert(VaultGovernor.InvalidCall.selector);
        gov.queue(v, hex"aa");
    }

    /// @notice A target that passes the hook check (it says it is a hook of this vault owned by the governor) gains
    ///         nothing: when executed it cannot queue, execute or accept ownership through the governor.
    function test_maliciousTarget_cannotReenterGovernor() public {
        ReenteringFakeHook fake = new ReenteringFakeHook(address(gov), v);
        bytes memory data = abi.encodeCall(fake.poke, ());
        uint256 eta = _queue(address(fake), data);
        vm.warp(eta);
        _execute(address(fake), data);
        assertEq(bytes4(fake.lastError()), VaultGovernor.NotAdmin.selector);
        assertEq(vault.owner(), address(gov));
    }

    // ------------------------------------------------------------------ hooks under the governor

    /// @notice Hook pricing is governed: the admin cannot configure a hook directly, a queued change applies only after
    ///         DELAY, and the guardian can cancel it. With the hook live in shared-core mode the new strategy applies to
    ///         the next swap.
    function test_hookParameters_waitDelay() public {
        BaseCompatibleHook.CoreParams memory p = BaseCompatibleHook.CoreParams({
            depthPerShare: 10e18,
            depthMax: uint128(2 ** 95 - 1),
            baseSpreadPips: 3000,
            minEdgePips: 200,
            maxSpreadPips: 40_000,
            maxDeviationPips: 50_000
        });
        vm.prank(admin);
        vm.expectRevert(BaseCompatibleHook.NotHookOwner.selector);
        govHookB.configureCore(govKeyB, p);
        vm.prank(hookOwner);
        vm.expectRevert(BaseCompatibleHook.NotHookOwner.selector);
        govHookB.configureCore(govKeyB, p);

        bytes memory core = abi.encodeCall(govHookB.configureCore, (govKeyB, p));
        bytes memory strat = abi.encodeCall(govHookB.configureStrategy, (govKeyB, 1000, 20_000));
        uint256 eta = _queue(address(govHookB), core);
        _queue(address(govHookB), strat);
        vm.warp(eta - 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.NotExecutable.selector, _id(address(govHookB), core), eta));
        gov.execute(address(govHookB), core);
        vm.warp(eta);
        _execute(address(govHookB), core);
        _execute(address(govHookB), strat);
        (uint24 markup, uint24 bound) = govHookB.strategy(govKeyB.toId());
        assertEq(markup, 1000);
        assertEq(bound, 20_000);
    }

    /// @notice The guardian's emergency tightening on the vault is immediate while the governor owns it, and in
    ///         shared-core mode it reaches the governed hooks with no hook change: the hooks clamp their deviation cap
    ///         to the vault's kappa and their edge to the vault's edge + 1.
    function test_guardianTightening_isImmediate() public {
        vm.startPrank(guardian);
        vault.setSellHalted(c0, true);
        vault.setRiskBounds(200, 4000);
        vault.setInventoryBounds(tau, tau, 10_000, 10_000);
        vault.setPaused(true);
        vault.setConsumer(address(govHookA), false);
        vm.stopPrank();
        assertTrue(vault.paused());
        assertEq(vault.inventoryTolerancePips(1), 10_000);
        assertEq(vault.riskEdgePips(), 200);
    }

    // ------------------------------------------------------------------ ownership

    /// @notice Ownership can leave the governor only after LONG_DELAY, only with no LP queued, and only to the
    ///         nominee, which must then accept.
    function test_ownershipEscape_waitsLongDelayAndQueue() public {
        address next = makeAddr("nextOwner");
        bytes memory data = abi.encodeCall(vault.transferOwnership, (next));
        uint256 eta = _queue(v, data);
        assertEq(eta, T0 + 32 days);
        vm.prank(next);
        vm.expectRevert(ISharedCommitmentVault.NotPendingOwner.selector);
        vault.acceptOwnership();

        vm.warp(T0 + 10 days);
        (,,, uint256 rid) = _redeemQueuedBehindCommitment(); // held until 40 days after queuing the transfer
        vm.warp(eta);
        uint256 pending = vault.pendingShares();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.PendingWithdrawals.selector, pending));
        gov.execute(v, data);

        vm.prank(guardian);
        vault.release(_allocations[0]); // emergency release, immediate
        vault.processQueue(10);
        assertEq(vault.getRequest(rid).sharesPending, 0);
        _execute(v, data);
        vm.prank(next);
        vault.acceptOwnership();
        assertEq(vault.owner(), next);
    }

    // ------------------------------------------------------------------ queued LPs and the floor (Task 2)

    uint256[] internal _allocations;

    /// @dev A curator commits almost all of asset0 for the full horizon, then lp0 redeems half its shares; the part
    ///      that cannot be paid now is queued behind the commitment.
    function _redeemQueuedBehindCommitment()
        internal
        returns (uint256 instantShares, uint256 a0, uint256 a1, uint256 rid)
    {
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyA, c0, uint128(vault.backing(c0) * 99 / 100));
        r.expiry = uint64(vm.getBlockTimestamp() + vault.MAX_HORIZON());
        vm.prank(curator);
        _allocations.push(auth.activateDirect(r));
        (instantShares, a0, a1, rid) = _redeem(lp0, vault.sharesOf(lp0) / 2, true);
        assertGt(rid, 0, "queued");
    }

    /// @dev Warps to each commitment's expiry if it is still in the future, lets anyone release it, then processes.
    function _releaseAllAndProcess() internal {
        for (uint256 i; i < _allocations.length; ++i) {
            uint256 expiry = vault.getAllocation(_allocations[i]).expiry;
            if (vm.getBlockTimestamp() < expiry) vm.warp(expiry);
            vault.release(_allocations[i]);
        }
        delete _allocations;
        vault.processQueue(10);
    }

    /// @notice An LP who queues early in the notice period is finalized under the old floor even without the queue
    ///         check: every commitment that can block it expires before LONG_DELAY ends (MAX_HORIZON < LONG_DELAY).
    function test_queuedLp_earlyInNotice_finalizedBeforeLoosening() public {
        bytes memory loosen = abi.encodeCall(vault.setInventoryBounds, (0, 0, 50_000, 50_000));
        uint256 t0 = T0;
        uint256 eta = _queue(v, loosen);
        (,,, uint256 rid) = _redeemQueuedBehindCommitment();

        vm.warp(t0 + 3 days); // where a DELAY-class change would already apply
        vault.processQueue(10);
        assertGt(vault.getRequest(rid).sharesPending, 0, "still queued at +3 days");

        _releaseAllAndProcess(); // t0 + MAX_HORIZON
        assertEq(vault.getRequest(rid).sharesPending, 0, "finalized before the change can apply");
        assertLt(vm.getBlockTimestamp(), eta);
        vm.warp(eta);
        _execute(v, loosen);
        assertEq(vault.inventoryTargetPerShare(0), 0);
    }

    /// @notice The adversarial case the delay alone does not cover. A commitment created late in the notice period
    ///         holds an LP who queues after it past eta; without the queue check the looser floor would apply to the
    ///         LP's still-queued shares. The governor refuses until the LP is finalized, then executes within GRACE.
    function test_queuedLp_lateInNotice_blocksLooseningUntilFinalized() public {
        bytes memory loosen = abi.encodeCall(vault.setInventoryBounds, (0, 0, 50_000, 50_000));
        uint256 t0 = T0;
        uint256 eta = _queue(v, loosen);
        vm.warp(t0 + 5 days);
        (,,, uint256 rid) = _redeemQueuedBehindCommitment(); // commitment lasts until t0 + 35 days

        vm.warp(eta); // t0 + 32 days: the delay has passed but the LP is still queued
        vault.processQueue(10);
        uint256 pending = vault.getRequest(rid).sharesPending;
        assertGt(pending, 0, "LP still queued at eta: a delay alone would expose it");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.PendingWithdrawals.selector, pending));
        gov.execute(v, loosen);

        _releaseAllAndProcess(); // t0 + 35 days
        assertEq(vault.getRequest(rid).sharesPending, 0);
        uint256 finalized0 = vault.getRequest(rid).claimable0;
        assertLe(vm.getBlockTimestamp(), eta + 7 days, "still inside GRACE");
        _execute(v, loosen);
        assertEq(vault.getRequest(rid).claimable0, finalized0, "a finalized claim never sees the new floor");
    }

    /// @notice Pauses, halts and frozen curators do not stop queue processing, so they cannot hold an LP past a
    ///         loosening; the guardian's emergency release is the immediate way to unblock a queue held by a commitment.
    function test_queuedLp_pauseHaltFreezeDoNotBlockExit_guardianReleaseUnblocks() public {
        bytes memory loosen = abi.encodeCall(vault.setInventoryBounds, (0, 0, 50_000, 50_000));
        uint256 eta = _queue(v, loosen);
        vm.warp(T0 + 5 days);
        (,,, uint256 rid) = _redeemQueuedBehindCommitment();
        vm.startPrank(guardian);
        vault.setPaused(true);
        vault.setSellHalted(c0, true);
        vault.setSellHalted(c1, true);
        vault.freezeCurator(curator);
        vault.release(_allocations[0]); // emergency release, immediate
        vm.stopPrank();
        delete _allocations;
        vault.processQueue(10);
        assertEq(vault.getRequest(rid).sharesPending, 0, "exits work while paused, halted and frozen");
        vm.prank(lp0);
        vault.claim(rid);
        vm.warp(eta);
        _execute(v, loosen);
    }

    /// @notice The queue check applies only to LONG_DELAY changes: ordinary changes execute with LPs queued (they do
    ///         not lower the inventory floor those LPs rely on).
    function test_queueCheck_onlyForLongDelay() public {
        bytes memory ordinary = abi.encodeCall(vault.setRiskBounds, (0, 9000));
        uint256 eta = _queue(v, ordinary);
        (,,, uint256 rid) = _redeemQueuedBehindCommitment();
        vm.warp(eta);
        _execute(v, ordinary);
        assertGt(vault.getRequest(rid).sharesPending, 0);
    }
}
