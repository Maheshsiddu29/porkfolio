// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {VaultGovernor} from "../../src/governance/VaultGovernor.sol";
import {ICommitmentAuthorizer} from "../../src/interfaces/ICommitmentAuthorizer.sol";
import {IBondEscrow} from "../../src/interfaces/IBondEscrow.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {IVaultState} from "../../src/interfaces/IVaultState.sol";
import {BatchSwapRouter} from "../utils/BatchSwapRouter.sol";
import {BondTestBase} from "../utils/BondTestBase.sol";
import {IndependentHookC} from "../utils/IndependentHookC.sol";

/// @notice Real PoolManager integration of a separately authored, test-only hook with the two established hooks.
///         All three consume one vault's ERC-6909 backing through their own bonded allocations.
contract IndependentHookCIntegrationTest is BondTestBase {
    IndependentHookC internal hookC;
    PoolKey internal keyC;
    address internal admin = makeAddr("hookCAdmin");

    function setUp() public override {
        super.setUp();
        uint160 flags = Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        bytes memory args = abi.encode(manager, IVaultState(address(vault)), hookOwner);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), flags, type(IndependentHookC).creationCode, args);
        hookC = new IndependentHookC{salt: salt}(manager, IVaultState(address(vault)), hookOwner);
        assertEq(address(hookC), expected, "CREATE2 address must carry the mined permissions");
        keyC = PoolKey(c0, c1, 10_000, 200, IHooks(address(hookC)));
        manager.initialize(keyC, SQRT_PRICE_1_1);
        vm.prank(hookOwner);
        hookC.setPolicy(keyC, 1000, true); // 1:1 raw-unit reference less 0.1%
        _openLimitsAsOwner(ISharedCommitmentVault.RiskScope.Hook, address(hookC));
        assertTrue(manager.isOperator(address(hookC), address(vault)));
        assertFalse(manager.isOperator(address(vault), address(hookC)));
    }

    /// @dev Governance waits DELAY before registering a third consumer. The old two registrations remain in place.
    function _registerGoverned() internal {
        VaultGovernor gov = new VaultGovernor(address(vault), admin, 3 days, 32 days, 7 days);
        vm.prank(owner);
        vault.transferOwnership(address(gov));
        vm.prank(admin);
        gov.acceptVaultOwnership();
        bytes memory data = abi.encodeCall(vault.setConsumer, (address(hookC), true));
        vm.prank(admin);
        (, uint256 eta) = gov.queue(address(vault), data);
        vm.warp(eta - 1);
        vm.prank(admin);
        vm.expectRevert();
        gov.execute(address(vault), data);
        vm.warp(eta);
        vm.prank(admin);
        gov.execute(address(vault), data);
        assertTrue(vault.isConsumer(address(hookC)));
    }

    function _registerDirect() internal {
        vm.prank(owner);
        vault.setConsumer(address(hookC), true);
    }

    function _swapC(uint256 input, uint256 allocationId, uint256 minimum) internal returns (BalanceDelta) {
        return _swapRaw(keyC, true, -int256(input), abi.encode(allocationId, minimum));
    }

    /// @notice Three independently priced pools use the same physical reserve in one block. The sums are checked
    ///         against actual PoolManager claims and ERC-20 settlement, not only vault getters. Neither a hook nor
    ///         the vault grants the hook authority over the vault's claims.
    function test_threePools_oneBlock_bondedSharedReserve() public {
        _registerGoverned();
        uint256 idA = _allocate(keyA, c1, 1000 ether);
        uint256 idB = _allocate(keyB, c1, 1000 ether);
        uint256 idC = _allocate(keyC, c1, 1000 ether);
        uint256 blockBefore = block.number;
        uint256 b0 = lens.backing(vault, c0);
        uint256 b1 = lens.backing(vault, c1);
        uint256 q1 = lens.reserved(vault, c1);
        uint256 shares = lens.totalShares(vault);
        uint256 pm0 = token0.balanceOf(address(manager));
        uint256 pm1 = token1.balanceOf(address(manager));

        BalanceDelta da = _swap(keyA, true, 100 ether, idA);
        BalanceDelta db = _swap(keyB, true, 100 ether, idB);
        BalanceDelta dc = _swapC(100 ether, idC, 99 ether);
        uint256 oa = uint256(int256(da.amount1()));
        uint256 ob = uint256(int256(db.amount1()));
        uint256 oc = uint256(int256(dc.amount1()));
        assertEq(oc, 99.9 ether);
        assertEq(block.number, blockBefore);
        assertEq(lens.backing(vault, c0), b0 + 300 ether);
        assertEq(lens.backing(vault, c1), b1 - oa - ob - oc);
        assertEq(lens.reserved(vault, c1), q1 - oa - ob - oc);
        assertEq(lens.getAllocation(vault, idA).consumed, oa);
        assertEq(lens.getAllocation(vault, idB).consumed, ob);
        assertEq(lens.getAllocation(vault, idC).consumed, oc);
        assertEq(lens.totalShares(vault), shares);
        assertEq(token0.balanceOf(address(manager)), pm0 + 300 ether);
        assertEq(token1.balanceOf(address(manager)), pm1 - oa - ob - oc);
        assertEq(_claims(address(vault), c0), lens.backing(vault, c0));
        assertEq(_claims(address(vault), c1), lens.backing(vault, c1));
        _assertNoHookClaims();
        _assertEscrowIdentity();
        _assertEquations();
    }

    /// @notice One unlock executes all three swaps and requires every hook and vault currency delta to be zero
    ///         after each step. The router settles the trader's input and output before the next step.
    function test_threePools_oneUnlock_reconcilesEveryDelta() public {
        _registerDirect();
        uint256 idA = _allocate(keyA, c1, 1000 ether);
        uint256 idB = _allocate(keyB, c1, 1000 ether);
        uint256 idC = _allocate(keyC, c1, 1000 ether);
        BatchSwapRouter.Step[] memory steps = new BatchSwapRouter.Step[](3);
        steps[0] = BatchSwapRouter.Step(keyA, true, 100 ether, abi.encode(idA));
        steps[1] = BatchSwapRouter.Step(keyB, true, 100 ether, abi.encode(idB));
        steps[2] = BatchSwapRouter.Step(keyC, true, 100 ether, abi.encode(idC, 99 ether));
        uint256[] memory mins = new uint256[](3);
        mins[2] = 99 ether;
        vm.prank(trader);
        BalanceDelta[] memory ds = batchRouter.run(steps, mins, BatchSwapRouter.Mode.Settle);
        uint256 total =
            uint256(int256(ds[0].amount1())) + uint256(int256(ds[1].amount1())) + uint256(int256(ds[2].amount1()));
        assertEq(ds.length, 3);
        assertEq(batchRouter.lastNonzeroDeltaCount(), 0);
        assertEq(lens.backing(vault, c0), VAULT_FUNDING + 300 ether);
        assertEq(lens.backing(vault, c1), VAULT_FUNDING - total);
        assertEq(lens.reserved(vault, c1), 3000 ether - total);
        _assertNoHookClaims();
        _assertEscrowIdentity();
        _assertEquations();
    }

    /// @notice The authorization is per hook and pool, even though all three pools use the same asset pair.
    ///         A rejected C swap cannot consume A's allocation or leave input claims behind.
    function test_crossHookAllocation_refusedAtomically() public {
        _registerDirect();
        uint256 idA = _allocate(keyA, c1, 1000 ether);
        uint256 before0 = _claims(address(vault), c0);
        uint256 before1 = _claims(address(vault), c1);
        uint256 beforeQ = lens.reserved(vault, c1);
        vm.expectRevert();
        _swapC(100 ether, idA, 0);
        assertEq(lens.getAllocation(vault, idA).consumed, 0);
        assertEq(lens.reserved(vault, c1), beforeQ);
        assertEq(_claims(address(vault), c0), before0);
        assertEq(_claims(address(vault), c1), before1);
        _assertNoHookClaims();
        _assertEscrowIdentity();
    }

    /// @notice A signed curator intent names a separate payer and rate cap. Hook C consumes part of the bonded
    ///         reservation, but the escrow sees it only on sync. A one-hour late sync charges the payer for the
    ///         consumed portion during that extra hour. Cancellation, settlement, LP realization and refund claim
    ///         conserve raw-asset claims without treating the posted bond as LP backing.
    function test_signedPayer_hookC_lifecycleAndLateSync() public {
        _registerDirect();
        ICommitmentAuthorizer.BondedAuthorization memory intent = _bondedAuthz(signer, keyC, c1, 1000 ether, payer, RHO);
        bytes memory signature = _signBonded(signerKey, intent);
        uint256 backingBefore = lens.backing(vault, c1);
        vm.prank(payer);
        uint256 id = bonded.activateBonded(intent, keyC, signature);
        IBondEscrow.Bond memory posted = escrow.getBond(id);
        assertEq(posted.payer, payer);
        assertEq(posted.rate, RHO);
        assertEq(posted.amount, 1000 ether);
        assertEq(lens.backing(vault, c1), backingBefore, "bond is not LP backing");
        assertEq(_claims(address(escrow), c1), posted.bond);
        vm.expectRevert(abi.encodeWithSelector(IBondEscrow.NotSettleable.selector, id));
        escrow.settle(id);

        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 1 hours);
        vm.prank(hookOwner);
        hookC.setPolicy(keyC, 1000, false);
        bytes32 failedBond = keccak256(abi.encode(escrow.getBond(id)));
        uint256 failedQ = lens.reserved(vault, c1);
        vm.expectRevert();
        _swapC(100 ether, id, 0);
        assertEq(keccak256(abi.encode(escrow.getBond(id))), failedBond);
        assertEq(lens.reserved(vault, c1), failedQ);
        vm.prank(hookOwner);
        hookC.setPolicy(keyC, 1000, true);
        _swapC(100 ether, id, 99 ether);
        assertEq(lens.getAllocation(vault, id).consumed, 99.9 ether);
        assertEq(escrow.getBond(id).synced, 0, "swap did not call escrow sync");
        assertEq(lens.reserved(vault, c1), 1000 ether - 99.9 ether);

        vm.warp(start + 2 hours);
        escrow.sync(id);
        assertEq(escrow.getBond(id).remaining, 1000 ether - 99.9 ether);
        vm.prank(signer);
        vault.cancelAllocation(id);
        escrow.sync(id);
        (uint256 charge, uint256 refund) = escrow.settle(id);
        uint256 expectedCharge = (1000 ether * RHO * 2 hours + 1e18 - 1) / 1e18;
        uint256 immediateCharge = ((1000 ether + (1000 ether - 99.9 ether)) * RHO * 1 hours + 1e18 - 1) / 1e18;
        assertEq(charge, expectedCharge);
        assertEq(charge - immediateCharge, 99.9 ether * RHO * 1 hours / 1e18);
        assertEq(charge + refund, posted.bond);

        uint256 beforeRealize = lens.backing(vault, c1);
        escrow.realize(type(uint256).max);
        IBondEscrow.Ledger memory ledger = escrow.getLedger(c1);
        uint256 protocolPart = charge * PROTOCOL_BPS / 10_000;
        assertEq(ledger.protocolOwed, protocolPart);
        assertEq(lens.backing(vault, c1), beforeRealize + charge - protocolPart);
        address payee = makeAddr("hookCRefundPayee");
        vm.prank(payer);
        (, uint256 refundPaid) = escrow.claimRefund(payee);
        vm.prank(protocol);
        (, uint256 protocolPaid) = escrow.claimProtocol(payee);
        assertEq(refundPaid, refund);
        assertEq(protocolPaid, protocolPart);
        assertEq(token1.balanceOf(payee), refund + protocolPart);
        assertEq(_claims(address(escrow), c1), 0);
        _assertEscrowIdentity();
        _assertEquations();
    }

    function _assertNoHookClaims() internal view {
        Currency[2] memory cs = [c0, c1];
        for (uint256 i; i < 2; ++i) {
            assertEq(_claims(address(hookA), cs[i]), 0);
            assertEq(_claims(address(hookB), cs[i]), 0);
            assertEq(_claims(address(hookC), cs[i]), 0);
        }
    }
}
