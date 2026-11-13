// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

import {SharedCommitmentVault} from "../src/SharedCommitmentVault.sol";
import {ISharedCommitmentVault} from "../src/interfaces/ISharedCommitmentVault.sol";
import {VaultGovernor} from "../src/governance/VaultGovernor.sol";

/// @title CheckQueuedConflicts
/// @notice Read-only check to run after every guardian action and before the admin executes a queued change: lists
///         every change still queued on the governor and says whether it would loosen the vault's current state.
///         Queued calls carry absolute values, so a change queued before a guardian tightening can undo it after its
///         own delay; the governor does not detect this, the guardian (or admin) must cancel such a change.
/// @dev The direction test is the vault's own: each queued vault call is simulated from the guardian's address on a
///      state snapshot that is then discarded. The vault lets the guardian make a change only if the change reduces
///      risk against the current state (`_authorize`), so
///        Tightens   the guardian could make it now: it cannot undo anything;
///        Loosens    `GuardianCannotIncreaseRisk`: it loosens the current state; cancel it or re-approve it explicitly;
///        OwnerOnly  `NotOwner`: an owner-only call (unfreeze, guardian or ownership change); review it;
///        Reverts    any other revert, which the owner's call would hit too, since the vault validates arguments
///                   before it checks the caller;
///        Hook       a hook call: hooks are priced inside the vault's limits, so it cannot undo a vault tightening;
///        NotQueued  executed, canceled or never queued.
///      The verdict holds for the state at the simulated block only. Run it again right before `execute`.
///      `run` reads `Queued` events from the RPC (`eth_getLogs`), so it also finds variants of a call that differ only
///      in ignored trailing bytes; it reverts if any queued change loosens or is owner-only, after printing all of them.
///      Nothing is broadcast.
contract CheckQueuedConflicts is Script {
    enum Verdict {
        NotQueued,
        Tightens,
        Loosens,
        OwnerOnly,
        Reverts,
        Hook
    }

    /// @notice Environment: GOVERNOR, and optionally FROM_BLOCK (the governor's deployment block; default 0).
    function run() external {
        VaultGovernor gov = VaultGovernor(vm.envAddress("GOVERNOR"));
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = VaultGovernor.Queued.selector;
        Vm.EthGetLogs[] memory logs =
            vm.eth_getLogs(vm.envOr("FROM_BLOCK", uint256(0)), block.number, address(gov), topics);
        address[] memory targets = new address[](logs.length);
        bytes[] memory calls = new bytes[](logs.length);
        for (uint256 i; i < logs.length; ++i) {
            targets[i] = address(uint160(uint256(logs[i].topics[2])));
            (, calls[i]) = abi.decode(logs[i].data, (uint256, bytes));
        }
        uint256 flagged = report(gov, targets, calls);
        require(flagged == 0, "CheckQueuedConflicts: queued changes loosen the current state; cancel or re-approve");
        console2.log("NO QUEUED CHANGE LOOSENS THE CURRENT STATE");
    }

    /// @notice Classifies and prints each queued change. A change queued twice appears twice in `Queued` events but
    ///         is reported once per event; only changes still queued count.
    /// @return flagged Number of changes classified `Loosens` or `OwnerOnly`.
    function report(VaultGovernor gov, address[] memory targets, bytes[] memory calls)
        public
        returns (uint256 flagged)
    {
        for (uint256 i; i < targets.length; ++i) {
            Verdict verdict = classify(gov, targets[i], calls[i]);
            if (verdict == Verdict.NotQueued) continue;
            if (verdict == Verdict.Loosens || verdict == Verdict.OwnerOnly) ++flagged;
            console2.log("queued change", i, targets[i], uint256(verdict));
            console2.logBytes(calls[i]);
        }
    }

    /// @notice Verdict for one change, against the current state. Leaves no state behind.
    /// @dev Requires a guardian: with none, the simulated caller would be address(0), which the vault never sees.
    function classify(VaultGovernor gov, address target, bytes memory data) public returns (Verdict) {
        if (gov.eta(gov.operationId(target, data)) == 0) return Verdict.NotQueued;
        address vault = gov.vault();
        if (target != vault) return Verdict.Hook;
        address guardian = SharedCommitmentVault(vault).guardian();
        require(guardian != address(0), "CheckQueuedConflicts: no guardian");
        uint256 snapshot = vm.snapshotState();
        vm.prank(guardian);
        (bool ok, bytes memory ret) = vault.call(data);
        vm.revertToState(snapshot);
        if (ok) return Verdict.Tightens;
        bytes4 reason = ret.length >= 4 ? bytes4(ret) : bytes4(0);
        if (reason == ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector) return Verdict.Loosens;
        if (reason == ISharedCommitmentVault.NotOwner.selector) return Verdict.OwnerOnly;
        return Verdict.Reverts;
    }
}
