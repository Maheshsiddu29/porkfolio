// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultGovernor} from "../../src/governance/VaultGovernor.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {ProductionArtifacts} from "../utils/ProductionArtifacts.sol";
import {CheckQueuedConflicts} from "../../script/CheckQueuedConflicts.s.sol";

/// @dev Passes the governor's target check at queue time; its code is replaced before execution in one test.
contract FakeHook {
    address public immutable hookOwner;
    address public immutable vault;

    constructor(address governor, address vault_) {
        hookOwner = governor;
        vault = vault_;
    }

    function poke() external {}
}

/// @dev The code placed at the fake hook's address after the change was queued. When the governor calls it, it tries
///      every use of the governor's identity it can think of and reverts if any of them works.
contract HostileTarget {
    SharedCommitmentVault internal immutable vault;
    VaultGovernor internal immutable gov;
    address internal immutable thief;

    constructor(SharedCommitmentVault vault_, VaultGovernor gov_, address thief_) {
        (vault, gov, thief) = (vault_, gov_, thief_);
    }

    function poke() external {
        bytes[6] memory vaultCalls = [
            abi.encodeCall(vault.transferOwnership, (thief)),
            abi.encodeCall(vault.setGuardian, (thief)),
            abi.encodeCall(vault.setInventoryBounds, (0, 0, 1e6, 1e6)),
            abi.encodeCall(vault.setPaused, (false)),
            abi.encodeCall(vault.setConsumer, (thief, true)),
            abi.encodeCall(vault.acceptOwnership, ())
        ];
        for (uint256 i; i < vaultCalls.length; ++i) {
            (bool ok,) = address(vault).call(vaultCalls[i]);
            require(!ok, "vault call succeeded");
        }
        bytes memory any = abi.encodeCall(vault.setPaused, (false));
        bytes[4] memory govCalls = [
            abi.encodeCall(gov.queue, (address(vault), any)),
            abi.encodeCall(gov.execute, (address(vault), any)),
            abi.encodeCall(gov.cancel, (address(vault), any)),
            abi.encodeCall(gov.acceptVaultOwnership, ())
        ];
        for (uint256 i; i < govCalls.length; ++i) {
            (bool ok,) = address(gov).call(govCalls[i]);
            require(!ok, "governor call succeeded");
        }
    }
}

/// @notice Operation integrity of `VaultGovernor` beyond `VaultGovernor.t.sol`: the delay class of every vault
///         function, why the class follows the selector and not the direction of a change, targets whose code changes
///         after queuing, guardian rotation, ownership hand-over and nomination retraction.
contract GovernorIntegrityTest is VaultTestBase {
    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    VaultGovernor internal gov;
    uint256 internal tau;
    address internal v;

    function setUp() public override {
        super.setUp();
        v = address(vault);
        tau = FullMath.mulDiv(vault.backing(c0), 1e18, vault.totalShares());
        gov = new VaultGovernor(v, admin, 3 days, 32 days, 7 days);
        vm.startPrank(owner);
        vault.setGuardian(guardian);
        vault.setInventoryBounds(tau, tau, 50_000, 50_000);
        vault.setRiskBounds(100, 5000);
        vault.setCuratorCeiling(curator, c0, type(uint256).max);
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

    /// @dev An honest curator commits all free asset0 until `expiry`; lp0 then queues half its shares behind it.
    function _queueLpBehindCommitment(uint256 expiry) internal returns (uint256 rid) {
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyA, c0, uint128(vault.admissibleCapacity(c0)));
        r.expiry = uint64(expiry);
        vm.prank(curator);
        auth.activateDirect(r);
        (,,, rid) = _redeem(lp0, vault.sharesOf(lp0) / 2, true);
        assertGt(vault.getRequest(rid).sharesPending, 0);
    }

    // =================================================================== delay classes

    /// @notice Every function of the deployed vault, read from the production artifact, gets exactly the delay class
    ///         the governor documents: LONG_DELAY for `setInventoryBounds` and for `transferOwnership` to a non-zero
    ///         nominee, DELAY for everything else. Arguments are filled with a non-zero pattern. The list of vault
    ///         functions is pinned: a function added to or removed from the vault fails this test, so that its delay
    ///         class is reviewed before the change is accepted.
    function test_delayClass_everyVaultFunction() public view {
        string[] memory sigs = vm.parseJsonKeys(vm.readFile(ProductionArtifacts.VAULT), ".methodIdentifiers");
        bytes memory joined;
        for (uint256 i; i < sigs.length; ++i) {
            joined = bytes.concat(joined, bytes(sigs[i]), ",");
            bytes32 h = keccak256(bytes(sigs[i]));
            bytes memory data = bytes.concat(bytes4(h), bytes32(uint256(1)), bytes32(uint256(1)), bytes32(uint256(1)));
            bool long = h == keccak256("setInventoryBounds(uint256,uint256,uint24,uint24)")
                || h == keccak256("transferOwnership(address)");
            assertEq(gov.delayFor(v, data), long ? 32 days : 3 days, sigs[i]);
        }
        assertEq(sigs.length, 70, "vault ABI changed: review VaultGovernor's delay classes");
        assertEq(
            keccak256(joined),
            0xa9b10ccd4d4dcaf9148f87aa8aba6316f897a65ca858edb08221d3ae3dea52b5,
            "vault ABI changed: review VaultGovernor's delay classes"
        );
    }

    /// @notice Why the class follows the selector and not the direction of the change. A `setInventoryBounds` that
    ///         tightens when queued (tolerance 5% -> 4%) can loosen by the time it executes, because the guardian
    ///         tightened further in between (to 2%). Classified at queue time as a tightening it would have run after
    ///         DELAY with LPs queued; classified by selector it waits LONG_DELAY and is refused while an LP is queued.
    ///         Immediate tightening stays available through the guardian.
    function test_delayClass_directionAtQueueTimeIsNotDirectionAtExecution() public {
        bytes memory tighten = abi.encodeCall(vault.setInventoryBounds, (tau, tau, 40_000, 40_000));
        uint256 eta = _queue(v, tighten);
        assertEq(eta, vm.getBlockTimestamp() + 32 days);
        vm.prank(guardian);
        vault.setInventoryBounds(tau, tau, 20_000, 20_000); // immediate
        vm.warp(eta - 1 days);
        _queueLpBehindCommitment(eta + 10 days);
        vm.warp(eta);
        bytes memory refusal = abi.encodeWithSelector(VaultGovernor.PendingWithdrawals.selector, vault.pendingShares());
        vm.prank(admin);
        vm.expectRevert(refusal);
        gov.execute(v, tighten);
        assertEq(vault.inventoryTolerancePips(0), 20_000, "the queued value would loosen from here");
    }

    /// @notice Limitation: queued calls carry absolute values, so an older queued call can undo a later guardian
    ///         tightening after only its own delay. Here an edge raise queued at 150 pips executes after the guardian
    ///         raised the edge to 300, taking it back to 150. The guardian prevents this by cancelling queued calls
    ///         that conflict with its tightening, which the second half shows.
    function test_olderQueuedValue_undoesGuardianTightening_unlessCanceled() public {
        bytes memory raise = abi.encodeCall(vault.setRiskBounds, (150, 5000));
        uint256 eta = _queue(v, raise);
        vm.prank(guardian);
        vault.setRiskBounds(300, 5000);
        uint256 snap = vm.snapshotState();
        vm.warp(eta);
        _execute(v, raise);
        assertEq(vault.riskEdgePips(), 150, "the guardian's tightening was undone");

        vm.revertToState(snap);
        vm.prank(guardian);
        gov.cancel(v, raise);
        vm.warp(eta);
        bytes32 id = gov.operationId(v, raise);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.NotQueued.selector, id));
        gov.execute(v, raise);
        assertEq(vault.riskEdgePips(), 300);
    }

    /// @notice Explicit cancellation is the design's answer to C6, and its failure mode is a missed id. Calldata with
    ///         trailing bytes the vault ignores is a different operation with the same effect: the guardian cancels the
    ///         canonical edge raise after tightening, the padded copy stays queued and undoes the tightening anyway.
    ///         The conflict check reads every queued call and simulates it from the guardian's address, so it flags
    ///         the copy (it loosens the current state) without decoding anything.
    function test_guardianCancellation_missesAPaddedCopy_conflictCheckFindsIt() public {
        CheckQueuedConflicts check = new CheckQueuedConflicts();
        bytes memory raise = abi.encodeCall(vault.setRiskBounds, (150, 5000));
        bytes memory padded = bytes.concat(raise, bytes1(0));
        uint256 eta = _queue(v, raise);
        _queue(v, padded);
        assertEq(uint8(check.classify(gov, v, padded)), uint8(CheckQueuedConflicts.Verdict.Tightens), "100 -> 150");

        vm.startPrank(guardian);
        vault.setRiskBounds(300, 5000);
        gov.cancel(v, raise);
        vm.stopPrank();
        assertEq(uint8(check.classify(gov, v, raise)), uint8(CheckQueuedConflicts.Verdict.NotQueued));
        assertEq(uint8(check.classify(gov, v, padded)), uint8(CheckQueuedConflicts.Verdict.Loosens), "300 -> 150");
        assertEq(vault.riskEdgePips(), 300, "the check leaves no state behind");

        uint256 snap = vm.snapshotState();
        vm.warp(eta);
        _execute(v, padded);
        assertEq(vault.riskEdgePips(), 150, "the missed copy undid the tightening");
        vm.revertToState(snap);
        vm.prank(guardian);
        gov.cancel(v, padded);
        assertEq(uint8(check.classify(gov, v, padded)), uint8(CheckQueuedConflicts.Verdict.NotQueued));
    }

    /// @notice The check's verdicts after an emergency (pause, curator freeze, edge raise), for each kind of queued
    ///         change: an unpause and an older edge value loosen the current state, an unfreeze is owner-only, a
    ///         further tightening and a hook call cannot undo anything. `report` counts the first three.
    function test_conflictCheck_verdictsAfterGuardianEmergency() public {
        CheckQueuedConflicts check = new CheckQueuedConflicts();
        address[] memory targets = new address[](5);
        bytes[] memory calls = new bytes[](5);
        (targets[0], calls[0]) = (v, abi.encodeCall(vault.setPaused, (false)));
        (targets[1], calls[1]) = (v, abi.encodeCall(vault.setRiskBounds, (150, 5000)));
        (targets[2], calls[2]) = (v, abi.encodeCall(vault.unfreezeCurator, (curator)));
        (targets[3], calls[3]) = (v, abi.encodeCall(vault.setRiskBounds, (400, 5000)));
        (targets[4], calls[4]) = (address(hookA), abi.encodeWithSignature("hookOwner()"));
        for (uint256 i; i < 4; ++i) {
            _queue(targets[i], calls[i]);
        }
        // The fixture's hooks are owned by the test owner, not this governor, so `queue` would refuse the hook call;
        // its `eta` entry (mapping at slot 0) is written directly. The verdict depends only on the target.
        vm.store(
            address(gov), keccak256(abi.encode(gov.operationId(targets[4], calls[4]), uint256(0))), bytes32(uint256(1))
        );

        vm.startPrank(guardian);
        vault.setPaused(true);
        vault.freezeCurator(curator);
        vault.setRiskBounds(300, 5000);
        vm.stopPrank();

        CheckQueuedConflicts.Verdict[5] memory expected = [
            CheckQueuedConflicts.Verdict.Loosens,
            CheckQueuedConflicts.Verdict.Loosens,
            CheckQueuedConflicts.Verdict.OwnerOnly,
            CheckQueuedConflicts.Verdict.Tightens,
            CheckQueuedConflicts.Verdict.Hook
        ];
        for (uint256 i; i < 5; ++i) {
            assertEq(uint8(check.classify(gov, targets[i], calls[i])), uint8(expected[i]));
        }
        assertEq(check.report(gov, targets, calls), 3);
        assertTrue(vault.paused());
        assertEq(vault.riskEdgePips(), 300);
    }

    /// @notice A hook change is DELAY and is not held by queued LPs. It cannot reach the vault's limits: a queued LP
    ///         keeps the inventory floor, which only a LONG_DELAY change can lower.
    function test_hookChange_isNotHeldByQueuedLps() public {
        address hook = _hookAddress(0xA7);
        deployCodeTo(ProductionArtifacts.HOOK_A, abi.encode(manager, vault, gov), hook);
        bytes memory configure = abi.encodeWithSignature(
            "configurePool((address,address,uint24,int24,address),uint160,uint24,uint24,uint128,uint128,uint32)",
            PoolKey(c0, c1, 3000, 60, IHooks(hook)),
            PRICE_1_1_X96,
            uint24(600),
            A_MAX_FEE,
            A_SCALE,
            A_SCALE,
            A_WINDOW
        );
        uint256 eta = _queue(hook, configure);
        assertEq(eta, vm.getBlockTimestamp() + 3 days);
        _queueLpBehindCommitment(eta + 10 days);
        vm.warp(eta);
        _execute(hook, configure);
        assertGt(vault.pendingShares(), 0);
        assertEq(vault.inventoryTolerancePips(0), 50_000, "the floor the queued LP relies on is unchanged");
    }

    // =================================================================== targets

    /// @notice The target check runs at queue time only. A target whose code is replaced afterwards (possible for an
    ///         address created and self-destructed in one transaction and redeployed later, or for a proxy) is still
    ///         called, and gains nothing: the governor's authority is usable only by the governor's own calls, and the
    ///         replaced code cannot make the governor call anything. Every attempt below reverts inside the target; the
    ///         call itself succeeds and the vault and the governor are unchanged. Replacing the code with nothing also
    ///         "succeeds" (a call to an account without code) and emits `Executed`: monitors must decode the target.
    function test_targetCodeReplacedAfterQueue_gainsNothing() public {
        FakeHook fake = new FakeHook(address(gov), v);
        bytes memory poke = abi.encodeCall(fake.poke, ());
        bytes memory other = abi.encodeCall(vault.setPaused, (false));
        uint256 eta = _queue(address(fake), poke);
        _queue(v, other);

        vm.etch(address(fake), address(new HostileTarget(vault, gov, attacker)).code);
        vm.warp(eta);
        _execute(address(fake), poke);
        assertEq(vault.owner(), address(gov));
        assertEq(vault.guardian(), guardian);
        assertEq(vault.pendingOwner(), address(0));
        assertEq(gov.eta(gov.operationId(v, other)), eta, "other queued changes untouched");

        vm.etch(address(fake), address(new FakeHook(address(gov), v)).code);
        _queue(address(fake), poke);
        vm.etch(address(fake), "");
        vm.warp(eta + 3 days);
        vm.expectEmit(address(gov));
        emit VaultGovernor.Executed(gov.operationId(address(fake), poke), address(fake));
        _execute(address(fake), poke);
    }

    // =================================================================== guardian rotation

    /// @notice The right to cancel follows the vault's live guardian. After a replacement executes, the old guardian can
    ///         cancel nothing and the new one can cancel everything except its own replacement. With the guardian removed
    ///         only the admin cancels.
    function test_guardianReplacement_movesTheCancelRight() public {
        address next = makeAddr("nextGuardian");
        bytes memory a = abi.encodeCall(vault.setRiskBounds, (0, 9000));
        bytes memory replace = abi.encodeCall(vault.setGuardian, (next));
        uint256 eta = _queue(v, replace);
        _queue(v, a);
        vm.warp(eta);
        _execute(v, replace);

        vm.prank(guardian);
        vm.expectRevert(VaultGovernor.NotAllowedToCancel.selector);
        gov.cancel(v, a);
        bytes memory replaceAgain = abi.encodeCall(vault.setGuardian, (address(0)));
        _queue(v, replaceAgain);
        vm.prank(next);
        vm.expectRevert(VaultGovernor.NotAllowedToCancel.selector);
        gov.cancel(v, replaceAgain);
        vm.prank(next);
        gov.cancel(v, a);

        vm.warp(eta + 3 days);
        _execute(v, replaceAgain);
        _queue(v, a);
        for (uint256 i; i < 2; ++i) {
            vm.prank(i == 0 ? next : guardian);
            vm.expectRevert(VaultGovernor.NotAllowedToCancel.selector);
            gov.cancel(v, a);
        }
        vm.prank(admin);
        gov.cancel(v, a);
    }

    // =================================================================== ownership

    /// @notice Moving the vault to a second governor keeps every protection: the hand-over waits LONG_DELAY with the
    ///         queue empty, the new governor's admin accepts at once, the new governor refuses its own LONG_DELAY
    ///         changes while an LP is queued, and a change still queued on the old governor can no longer apply.
    function test_migrationToSecondGovernor_keepsTheQueueCheck() public {
        address admin2 = makeAddr("admin2");
        VaultGovernor gov2 = new VaultGovernor(v, admin2, 3 days, 32 days, 7 days);
        bytes memory handOver = abi.encodeCall(vault.transferOwnership, (address(gov2)));
        uint256 eta = _queue(v, handOver);
        vm.warp(eta - 1 days);
        bytes memory stale = abi.encodeCall(vault.setRiskBounds, (0, 9000));
        uint256 etaStale = _queue(v, stale);
        vm.warp(eta);
        _execute(v, handOver);
        vm.prank(admin2);
        gov2.acceptVaultOwnership();
        assertEq(vault.owner(), address(gov2));
        vm.warp(etaStale);
        vm.prank(admin);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        gov.execute(v, stale);

        bytes memory loosen = abi.encodeCall(vault.setInventoryBounds, (tau, tau, 100_000, 100_000));
        vm.prank(admin2);
        (, uint256 eta2) = gov2.queue(v, loosen);
        vm.warp(eta2 - 1 days);
        _queueLpBehindCommitment(eta2 + 10 days);
        vm.warp(eta2);
        bytes memory refusal = abi.encodeWithSelector(VaultGovernor.PendingWithdrawals.selector, vault.pendingShares());
        vm.prank(admin2);
        vm.expectRevert(refusal);
        gov2.execute(v, loosen);
    }

    /// @notice Limitation: the queue check binds when the nomination executes, not when the nominee accepts. An LP who
    ///         queues after the nomination executed is not protected from a nominee that is not itself a timelock: it
    ///         accepts at any later time and can loosen the floor at once while that LP is queued. The nomination was
    ///         public for LONG_DELAY and `pendingOwner` is readable, so this is notice, not protection. Release rule:
    ///         nominate only a reviewed governor and accept in the same transaction.
    function test_nomineeAcceptingLate_isNotHeldByLaterQueuedLps() public {
        address next = makeAddr("next");
        bytes memory nominate = abi.encodeCall(vault.transferOwnership, (next));
        uint256 eta = _queue(v, nominate);
        vm.warp(eta);
        _execute(v, nominate);

        vm.warp(eta + 20 days);
        _queueLpBehindCommitment(eta + 40 days);
        vm.startPrank(next);
        vault.acceptOwnership();
        vault.setInventoryBounds(0, 0, 1e6, 1e6);
        vm.stopPrank();
        assertGt(vault.pendingShares(), 0);
        assertEq(vault.inventoryTargetPerShare(0), 0, "the queued LP's floor is gone");
    }

    /// @notice Retracting a nomination (`transferOwnership(address(0))`) only removes a right, so it waits DELAY and is
    ///         not held by queued LPs. Before this rule it was classified with ownership transfers: it waited LONG_DELAY
    ///         and was refused while any LP was queued, so a nominee the admin wanted to retract could accept for at
    ///         least LONG_DELAY, and for as long as the queue could be kept non-empty. Here the retraction executes
    ///         after DELAY with an LP queued behind a commitment, and the nominee can no longer accept.
    function test_nominationRetraction_waitsDelay_notHeldByQueuedLps() public {
        address next = makeAddr("next");
        bytes memory nominate = abi.encodeCall(vault.transferOwnership, (next));
        uint256 eta = _queue(v, nominate);
        vm.warp(eta);
        _execute(v, nominate);
        assertEq(vault.pendingOwner(), next);

        bytes memory retract = abi.encodeCall(vault.transferOwnership, (address(0)));
        assertEq(gov.delayFor(v, retract), 3 days);
        uint256 eta2 = _queue(v, retract);
        vm.warp(eta2 - 1 days);
        _queueLpBehindCommitment(eta2 + 10 days);
        vm.warp(eta2);
        _execute(v, retract);
        assertGt(vault.pendingShares(), 0, "executed with an LP queued");
        assertEq(vault.pendingOwner(), address(0));
        vm.prank(next);
        vm.expectRevert(ISharedCommitmentVault.NotPendingOwner.selector);
        vault.acceptOwnership();
        assertEq(vault.owner(), address(gov));
    }

    /// @notice Only a clean zero argument word is a retraction. A word with non-zero upper bits, or calldata too short to
    ///         hold the argument, stays LONG_DELAY, and the vault's ABI decoder rejects both, so neither can nominate
    ///         anyone after the short delay. Bytes after a zero word are ignored by the vault: still a retraction.
    function test_nominationRetraction_onlyACleanZeroWord() public {
        bytes4 sel = vault.transferOwnership.selector;
        bytes memory dirty = bytes.concat(sel, bytes32(uint256(1) << 160));
        bytes memory short = bytes.concat(sel, bytes31(0));
        bytes memory padded = bytes.concat(sel, bytes32(0), bytes32(uint256(uint160(attacker))));
        assertEq(gov.delayFor(v, dirty), 32 days);
        assertEq(gov.delayFor(v, short), 32 days);
        assertEq(gov.delayFor(v, padded), 3 days);

        vm.startPrank(address(gov));
        (bool ok,) = v.call(dirty);
        assertFalse(ok, "dirty address word accepted");
        (ok,) = v.call(short);
        assertFalse(ok, "short calldata accepted");
        (ok,) = v.call(padded);
        assertTrue(ok);
        vm.stopPrank();
        assertEq(vault.pendingOwner(), address(0));
    }

    /// @notice A retraction must not open a path around the queue check for a real transfer: the transfer it would
    ///         clear still needed LONG_DELAY and an empty queue, and queuing a retraction and a transfer together gives
    ///         the transfer no shorter delay.
    function test_nominationRetraction_doesNotShortenATransfer() public {
        address next = makeAddr("next");
        bytes memory nominate = abi.encodeCall(vault.transferOwnership, (next));
        bytes memory retract = abi.encodeCall(vault.transferOwnership, (address(0)));
        uint256 etaRetract = _queue(v, retract);
        uint256 etaNominate = _queue(v, nominate);
        assertEq(etaNominate - etaRetract, 29 days);
        vm.warp(etaRetract);
        _execute(v, retract);
        bytes32 id = gov.operationId(v, nominate);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.NotExecutable.selector, id, etaNominate));
        gov.execute(v, nominate);
    }

    /// @notice The four-step sequence (nomination executed, LP queues, nominee accepts late, new owner skips the old
    ///         governor's timelock) needs a nominee that is not a timelock. With a reviewed governor as nominee the
    ///         late acceptance changes nothing for the queued LP: the new admin cannot call the vault, and a floor
    ///         change through the new governor waits LONG_DELAY and is refused while the LP is queued.
    function test_reviewedGovernorNominee_acceptingLate_keepsTheTimelock() public {
        address admin2 = makeAddr("admin2");
        VaultGovernor gov2 = new VaultGovernor(v, admin2, 3 days, 32 days, 7 days);
        bytes memory nominate = abi.encodeCall(vault.transferOwnership, (address(gov2)));
        uint256 eta = _queue(v, nominate);
        vm.warp(eta);
        _execute(v, nominate);
        vm.warp(eta + 20 days);
        _queueLpBehindCommitment(eta + 40 days);
        vm.prank(admin2);
        gov2.acceptVaultOwnership();
        assertEq(vault.owner(), address(gov2));

        bytes memory loosen = abi.encodeCall(vault.setInventoryBounds, (0, 0, 1e6, 1e6));
        vm.prank(admin2);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        v.call(loosen);
        vm.prank(admin2);
        (, uint256 eta2) = gov2.queue(v, loosen);
        assertEq(eta2, vm.getBlockTimestamp() + 32 days);
        vm.warp(eta2);
        bytes memory refusal = abi.encodeWithSelector(VaultGovernor.PendingWithdrawals.selector, vault.pendingShares());
        vm.prank(admin2);
        vm.expectRevert(refusal);
        gov2.execute(v, loosen);
    }

    /// @notice Once a nomination has executed, nothing on-chain stops the nominee from accepting before a retraction
    ///         executes. The retraction waits DELAY; the guardian has no ownership power and cannot cancel what already
    ///         executed. The nominee accepts one second before the retraction's eta, and the retraction then fails
    ///         because the governor no longer owns the vault. The only protection is to leave no window: nominate only
    ///         a reviewed governor and accept in the transaction that executes the nomination.
    function test_pendingNominee_canAcceptDuringRetractionDelay() public {
        address next = makeAddr("next");
        bytes memory nominate = abi.encodeCall(vault.transferOwnership, (next));
        bytes memory retract = abi.encodeCall(vault.transferOwnership, (address(0)));
        uint256 eta = _queue(v, nominate);
        vm.warp(eta);
        _execute(v, nominate);
        uint256 eta2 = _queue(v, retract);
        assertEq(eta2, eta + 3 days);

        vm.startPrank(guardian);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.transferOwnership(address(0));
        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.NotQueued.selector, gov.operationId(v, nominate)));
        gov.cancel(v, nominate);
        vm.stopPrank();

        vm.warp(eta2 - 1);
        vm.prank(next);
        vault.acceptOwnership();
        assertEq(vault.owner(), next);
        vm.warp(eta2);
        vm.prank(admin);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        gov.execute(v, retract);
    }
}
