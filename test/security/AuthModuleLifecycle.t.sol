// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {CuratorAuthorization} from "../../src/CuratorAuthorization.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {ICuratorAuthorization} from "../../src/interfaces/ICuratorAuthorization.sol";
import {AuthTestBase} from "../utils/AuthTestBase.sol";
import {MaliciousAuthModule} from "../utils/MaliciousAuthModule.sol";

/// @notice Installing, disabling, retiring and replacing the authorization module, and what a compromised module can
///         and cannot do. Runs on the production builds (`VaultTestBase`).
/// @dev The properties: only the owner installs; the guardian can only disable; a module that leaves office is
///      retired for good; disabling or replacing the module changes nothing but the creation of new allocations
///      (swaps, cancellation, release, every LP path and every risk record keep working unchanged); signatures die
///      with their module; the vault calls a module only once, read-only, to check its `vault()` at installation;
///      and a module that forges `reserveFor` calls is still bound by every vault-side check.
contract AuthModuleLifecycleTest is AuthTestBase {
    ISharedCommitmentVault.RiskScope internal constant HOOK = ISharedCommitmentVault.RiskScope.Hook;
    ISharedCommitmentVault.RiskScope internal constant CURATOR = ISharedCommitmentVault.RiskScope.Curator;
    ISharedCommitmentVault.RiskScope internal constant VAULT = ISharedCommitmentVault.RiskScope.Vault;

    // ------------------------------------------------------------------
    // Roles
    // ------------------------------------------------------------------

    function test_ML_onlyOwnerInstalls_guardianOnlyDisables() public {
        CuratorAuthorization m2 = _deployAuth(vault);
        vm.prank(attacker);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setAuthModule(address(m2));
        vm.prank(attacker);
        vm.expectRevert(ISharedCommitmentVault.NotOwner.selector);
        vault.setAuthModule(address(0));
        vm.prank(guardian);
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setAuthModule(address(m2));

        vm.expectEmit(address(vault));
        emit ISharedCommitmentVault.AuthModuleSet(address(auth), address(0), guardian);
        vm.prank(guardian);
        vault.setAuthModule(address(0));
        assertEq(vault.authModule(), address(0));
        vm.prank(guardian);
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setAuthModule(address(m2)); // still cannot enable anything

        vm.expectEmit(address(vault));
        emit ISharedCommitmentVault.AuthModuleSet(address(0), address(m2), owner);
        vm.prank(owner);
        vault.setAuthModule(address(m2));
        assertEq(vault.authModule(), address(m2));
    }

    /// @notice A module that was replaced or disabled is retired: it can never be installed again, by anyone, so its
    ///         unused signatures and its nonce state can never regain authority. Its bitmap is left as it was.
    function test_ML_retiredModuleNeverReinstalled() public {
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(signer, keyA, c1, 1000 ether);
        _signAndActivate(a, keyA);
        CuratorAuthorization m2 = _deployAuth(vault);
        CuratorAuthorization m3 = _deployAuth(vault);

        vm.startPrank(owner);
        vault.setAuthModule(address(m2));
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.AuthModuleRetired.selector, address(auth)));
        vault.setAuthModule(address(auth));
        vm.stopPrank();

        vm.prank(guardian);
        vault.setAuthModule(address(0)); // disabling retires m2 too
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.AuthModuleRetired.selector, address(m2)));
        vault.setAuthModule(address(m2));
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.AuthModuleRetired.selector, address(auth)));
        vault.setAuthModule(address(auth));
        vault.setAuthModule(address(m3));
        // Installing the installed module again would retire it first, so it is refused and nothing changes.
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.AuthModuleRetired.selector, address(m3)));
        vault.setAuthModule(address(m3));
        assertEq(vault.authModule(), address(m3));
        vm.stopPrank();
        vm.prank(relayer);
        m3.activate(_authzSigned(m3), keyA, _lastSig);
        vm.startPrank(owner);
        vault.setAuthModule(address(0));
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.AuthModuleRetired.selector, address(m3)));
        vault.setAuthModule(address(m3));
        vm.stopPrank();
        assertTrue(auth.isNonceUsed(signer, a.nonce), "the retired module's bitmap is untouched");
    }

    // ------------------------------------------------------------------
    // Disable
    // ------------------------------------------------------------------

    /// @notice After the guardian disables the module, signed and direct activations both fail (spending no nonce),
    ///         while swaps on existing allocations, cancellation, release, and every LP path keep working, and no risk
    ///         or curator record changes because of the disable.
    function test_ML_disableStopsOnlyNewActivations() public {
        uint256 idA = _signAndActivate(_authz(signer, keyA, c1, 50_000 ether), keyA);
        uint256 idB = _allocate(keyB, c0, 50_000 ether);
        uint256 idC = _allocate(keyA, c1, 10_000 ether);
        _swap(keyA, true, 1000 ether, idA);
        // A queued redemption, so queue processing and claims have something to do.
        uint256 lock = _allocate(keyA, c1, uint128(vault.admissibleCapacity(c1)));
        (,,, uint256 req) = _redeem(lp0, 100_000 ether, true);
        assertGt(req, 0, "queued");

        bytes32 recordsBefore = _riskRecords();
        bytes32 curatorsBefore = keccak256(abi.encode(vault.getCurator(signer), vault.getCurator(curator)));
        vm.prank(guardian);
        vault.setAuthModule(address(0));
        assertEq(_riskRecords(), recordsBefore, "risk records untouched by the disable");
        assertEq(keccak256(abi.encode(vault.getCurator(signer), vault.getCurator(curator))), curatorsBefore);

        ICuratorAuthorization.AllocationAuthorization memory a = _authz(signer, keyA, c1, 1000 ether);
        bytes memory sig = _sign(signerKey, a);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NotAuthModule.selector, address(auth)));
        _activate(a, keyA, sig);
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyA, c1, 1000 ether);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NotAuthModule.selector, address(auth)));
        auth.activateDirect(r);
        assertFalse(auth.isNonceUsed(signer, a.nonce));
        assertFalse(auth.isNonceUsed(curator, r.nonce));

        _swap(keyA, true, 1000 ether, idA);
        _swap(keyB, false, 1000 ether, idB);
        vm.prank(curator);
        vault.cancelAllocation(idC);
        vm.prank(guardian);
        vault.release(lock);
        vault.processQueue(10);
        vm.prank(lp0);
        vault.claim(req);
        _depositShares(makeAddr("lateLp"), 1000 ether);
        _redeem(makeAddr("lateLp"), 500 ether, false);
        vm.warp(block.timestamp + 2 days);
        vault.release(idB); // expired: anyone
        _assertAccountingConsistent();
        _assertEquations();
    }

    // ------------------------------------------------------------------
    // Replacement
    // ------------------------------------------------------------------

    /// @notice After replacement the old module's signatures are dead everywhere: the old module still verifies them
    ///         but the vault rejects its call (spending nothing), and the new module rejects them because its domain
    ///         has a different verifying contract. Re-signed for the new module they work. Allocations created through
    ///         the old module, and the flow usage they caused, are untouched.
    function test_ML_replacementInvalidatesOldSignatures() public {
        uint256 id = _signAndActivate(_authz(signer, keyA, c1, 50_000 ether), keyA);
        _swap(keyA, true, 1000 ether, id);
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(signer, keyA, c1, 1000 ether);
        bytes memory oldSig = _sign(signerKey, a);
        bytes32 recordsBefore = _riskRecords();
        ISharedCommitmentVault.Allocation memory before = vault.getAllocation(id);

        CuratorAuthorization m2 = _deployAuth(vault);
        vm.prank(owner);
        vault.setAuthModule(address(m2));
        assertEq(_riskRecords(), recordsBefore, "flow usage and limits survive the replacement");
        assertEq(keccak256(abi.encode(vault.getAllocation(id))), keccak256(abi.encode(before)));

        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NotAuthModule.selector, address(auth)));
        _activate(a, keyA, oldSig);
        assertFalse(auth.isNonceUsed(signer, a.nonce));
        vm.prank(relayer);
        vm.expectRevert(ICuratorAuthorization.InvalidSignature.selector);
        m2.activate(a, keyA, oldSig);

        bytes memory newSig = _signWith(m2, signerKey, a);
        vm.prank(relayer);
        uint256 id2 = m2.activate(a, keyA, newSig);
        assertEq(vault.getAllocation(id2).curator, signer);
        _swap(keyA, true, 1000 ether, id); // the old module's allocation is still consumable
        vm.prank(signer);
        vault.cancelAllocation(id); // and cancellable
    }

    /// @notice A module built for another vault cannot be installed here (its `vault()` names the other vault). Even
    ///         if it could, it would gain nothing: it only ever calls its own vault, which rejects it, and it refuses
    ///         instructions naming this vault.
    function test_ML_moduleForAnotherVaultRefused() public {
        SharedCommitmentVault v2 = new SharedCommitmentVault(manager, owner, c0, c1);
        CuratorAuthorization foreign = _deployAuth(v2);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InvalidAuthModule.selector, address(foreign)));
        vault.setAuthModule(address(foreign));
        assertEq(vault.authModule(), address(auth), "the installed module is unchanged");
        uint256 nextId = vault.nextAllocationId();

        ISharedCommitmentVault.AllocationRequest memory r = _request(keyA, c1, 1000 ether);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NotAuthModule.selector, address(foreign)));
        foreign.activateDirect(r); // reverts in v2, where nothing is installed
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(signer, keyA, c1, 1000 ether);
        bytes memory sig = _signWith(foreign, signerKey, a);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ICuratorAuthorization.WrongVault.selector, address(vault)));
        foreign.activate(a, keyA, sig);
        assertEq(vault.nextAllocationId(), nextId, "no allocation in this vault");
    }

    /// @notice A vault with no module installed creates no allocation at all.
    function test_ML_noModuleFailsClosed() public {
        SharedCommitmentVault v2 = new SharedCommitmentVault(manager, owner, c0, c1);
        assertEq(v2.authModule(), address(0));
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyA, c1, 1);
        address[3] memory callers = [owner, curator, address(auth)];
        for (uint256 i; i < 3; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NotAuthModule.selector, callers[i]));
            v2.reserveFor(r, curator, 0);
        }
    }

    /// @notice The vault calls a module exactly once: a read-only `vault()` call when the owner installs it. It never
    ///         calls the installed or the retired module on deposits, redemptions, queue processing, claims, swaps,
    ///         cancellation, release, configuration, or when a module is retired. The two expectations on `m2` together
    ///         say "one call in total, and that call is `vault()`".
    function test_ML_vaultCallsModuleOnlyAtInstall() public {
        uint256 id = _allocate(keyA, c1, 50_000 ether);
        CuratorAuthorization m2 = _deployAuth(vault);
        vm.expectCall(address(auth), bytes(""), 0);
        vm.expectCall(address(m2), bytes(""), 1);
        vm.expectCall(address(m2), abi.encodeWithSignature("vault()"), 1);
        _swap(keyA, true, 1000 ether, id);
        _depositShares(makeAddr("lpX"), 1000 ether);
        (,,, uint256 req) = _redeem(makeAddr("lpX"), 500 ether, true);
        vault.processQueue(5);
        if (req != 0) {
            vm.prank(makeAddr("lpX"));
            vault.claim(req);
        }
        vm.prank(curator);
        vault.cancelAllocation(id);
        vm.startPrank(owner);
        vault.setRiskLimit(VAULT, address(0), c1, 1 ether, 5000);
        vault.setAuthModule(address(m2));
        vault.setAuthModule(address(0));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // A compromised module
    // ------------------------------------------------------------------

    /// @notice A malicious module installed by mistake forges `reserveFor` calls with no signature. Every vault-side
    ///         check still applies, so it can only do what a registered, unrestricted curator could do within its own
    ///         ceiling and the vault's limits. It cannot consume, cancel or release allocations, change limits, or
    ///         touch assets. The guardian disables it and emergency-releases what it created.
    function test_ML_compromisedModuleBoundedByVault() public {
        MaliciousAuthModule mal = new MaliciousAuthModule(ISharedCommitmentVault(address(vault)));
        vm.prank(owner);
        vault.setAuthModule(address(mal));
        uint32 gen = vault.getCurator(curator).generation;

        // Identity and state checks.
        _forgeReverts(
            mal,
            _request(keyA, c1, 1000 ether),
            attacker,
            0,
            _e1(ISharedCommitmentVault.CuratorNotRegistered.selector, attacker)
        );
        _forgeReverts(
            mal,
            _request(keyA, c1, 1000 ether),
            curator,
            gen + 1,
            abi.encodeWithSelector(ISharedCommitmentVault.StaleGeneration.selector, curator, gen + 1, gen)
        );
        vm.prank(guardian);
        vault.freezeCurator(signer);
        _forgeReverts(
            mal,
            _request(keyA, c1, 1000 ether),
            signer,
            vault.getCurator(signer).generation,
            abi.encodeWithSelector(
                ISharedCommitmentVault.CuratorRestricted.selector,
                signer,
                ISharedCommitmentVault.CuratorRestriction.Frozen
            )
        );

        // Financial checks.
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyA, c1, uint128(VAULT_FUNDING) + 1);
        _forgeReverts(
            mal,
            r,
            curator,
            gen,
            abi.encodeWithSelector(
                ISharedCommitmentVault.CuratorCeilingExceeded.selector, VAULT_FUNDING + 1, VAULT_FUNDING
            )
        );
        r = _request(keyA, c1, 1000 ether);
        r.minInPerOutX96 = PRICE_1_1_X96 - 1;
        _forgeReverts(
            mal,
            r,
            curator,
            gen,
            abi.encodeWithSelector(
                ISharedCommitmentVault.FloorBelowVaultMinimum.selector, PRICE_1_1_X96 - 1, PRICE_1_1_X96
            )
        );
        r = _request(keyA, c1, 1000 ether);
        r.consumer = attacker;
        _forgeReverts(mal, r, curator, gen, _e1(ISharedCommitmentVault.ConsumerNotRegistered.selector, attacker));
        r = _request(keyA, c1, 1000 ether);
        r.consumer = address(hookB);
        _forgeReverts(
            mal,
            r,
            curator,
            gen,
            abi.encodeWithSelector(ISharedCommitmentVault.ConsumerMismatch.selector, address(hookB), address(hookA))
        );
        r = _request(keyA, c1, 0);
        _forgeReverts(mal, r, curator, gen, abi.encodeWithSelector(ISharedCommitmentVault.ZeroAmount.selector));
        r = _request(keyA, c1, 1000 ether);
        r.deadline = uint64(block.timestamp - 1);
        _forgeReverts(
            mal, r, curator, gen, abi.encodeWithSelector(ISharedCommitmentVault.InstructionExpired.selector, r.deadline)
        );
        r = _request(keyA, c1, 1000 ether);
        (r.deadline, r.expiry) = (uint64(block.timestamp), uint64(block.timestamp)); // the module would refuse this
        _forgeReverts(mal, r, curator, gen, abi.encodeWithSelector(ISharedCommitmentVault.InvalidExpiry.selector));
        r = _request(keyA, c1, 1000 ether);
        r.expiry = uint64(block.timestamp + 31 days);
        _forgeReverts(
            mal,
            r,
            curator,
            gen,
            abi.encodeWithSelector(ISharedCommitmentVault.HorizonExceeded.selector, r.expiry, block.timestamp + 30 days)
        );
        vm.prank(owner);
        vault.setRiskLimit(HOOK, address(hookA), c1, MAX_FLOW_CAP, 100); // 1% of eligible backing
        r = _request(keyA, c1, 20_000 ether);
        uint256 hookLimit = lens.eligibleBacking(vault, c1) / 100;
        _forgeReverts(
            mal,
            r,
            curator,
            gen,
            abi.encodeWithSelector(
                ISharedCommitmentVault.ExposureCapExceeded.selector, HOOK, address(hookA), c1, 20_000 ether, hookLimit
            )
        );
        vm.prank(owner);
        vault.setRiskLimit(HOOK, address(hookA), c1, MAX_FLOW_CAP, 10_000);
        vm.prank(owner);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        r = _request(keyA, c1, uint128(vault.admissibleCapacity(c1)) + 1);
        _forgeReverts(
            mal,
            r,
            curator,
            gen,
            abi.encodeWithSelector(ISharedCommitmentVault.InsufficientBacking.selector, r.maxOut, r.maxOut - 1)
        );

        // What it can do: reserve within a real curator's limits. Nothing beyond that.
        uint256 forged = mal.forge(_request(keyA, c1, 1000 ether), curator, gen);
        bytes[5] memory calls = [
            abi.encodeCall(vault.exchange, (keyA, true, forged, 1000 ether, 1000 ether)),
            abi.encodeCall(vault.cancelAllocation, (forged)),
            abi.encodeCall(vault.release, (forged)),
            abi.encodeCall(vault.setRiskLimit, (VAULT, address(0), c1, MAX_FLOW_CAP, 10_000)),
            abi.encodeCall(vault.unfreezeCurator, (signer))
        ];
        bytes[5] memory errs = [
            _e1(ISharedCommitmentVault.ConsumerNotRegistered.selector, address(mal)),
            abi.encodeWithSelector(ISharedCommitmentVault.NotAllocationCurator.selector, forged, address(mal)),
            abi.encodeWithSelector(
                ISharedCommitmentVault.AllocationNotExpired.selector, forged, vault.getAllocation(forged).expiry
            ),
            abi.encodeWithSelector(ISharedCommitmentVault.NotOwner.selector),
            abi.encodeWithSelector(ISharedCommitmentVault.NotOwner.selector)
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.expectRevert(errs[i]);
            mal.exec(address(vault), calls[i]);
        }
        assertEq(_claims(address(mal), c0) + _claims(address(mal), c1), 0, "the module holds no claims");

        vm.prank(guardian);
        vault.setAuthModule(address(0));
        vm.prank(guardian);
        vault.release(forged);
        assertTrue(vault.getAllocation(forged).released);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.NotAuthModule.selector, address(mal)));
        mal.forge(_request(keyA, c1, 1000 ether), curator, gen);
        _assertEquations();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    bytes internal _lastSig;

    /// @dev A fresh instruction by `signer` signed for module `m`; the signature is left in `_lastSig`.
    function _authzSigned(CuratorAuthorization m)
        internal
        returns (ICuratorAuthorization.AllocationAuthorization memory a)
    {
        a = _authz(signer, keyA, c1, 1000 ether);
        _lastSig = _signWith(m, signerKey, a);
    }

    function _forgeReverts(
        MaliciousAuthModule mal,
        ISharedCommitmentVault.AllocationRequest memory r,
        address c,
        uint32 gen,
        bytes memory err
    ) internal {
        vm.expectRevert(err);
        mal.forge(r, c, gen);
    }

    function _e1(bytes4 sel, address a) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(sel, a);
    }

    /// @dev Hash of every risk record the fixture configures, in both assets.
    function _riskRecords() internal view returns (bytes32 h) {
        address[5] memory accounts = [address(hookA), address(hookB), curator, signer, address(0)];
        ISharedCommitmentVault.RiskScope[5] memory scopes = [HOOK, HOOK, CURATOR, CURATOR, VAULT];
        Currency[2] memory cs = [c0, c1];
        for (uint256 i; i < 5; ++i) {
            for (uint256 j; j < 2; ++j) {
                h = keccak256(abi.encode(h, vault.getRiskLimit(scopes[i], accounts[i], cs[j])));
            }
        }
    }
}
