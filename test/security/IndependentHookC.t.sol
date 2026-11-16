// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {IMarketRiskAdapter} from "../../src/interfaces/IMarketRiskAdapter.sol";
import {BatchSwapRouter} from "../utils/BatchSwapRouter.sol";
import {IndependentHookC} from "../utils/IndependentHookC.sol";
import {MaliciousConsumerHook} from "../utils/MaliciousConsumerHook.sol";
import {MockRiskAdapter} from "../utils/MockRiskAdapter.sol";
import {IndependentHookCIntegrationTest} from "../integration/IndependentHookC.t.sol";

/// @notice Adversarial operations against the independently compiled hook, real PoolManager, bonded vault and escrow.
/// @dev Inherits the three positive integration tests so every negative path shares their mined-hook fixture. The
///      rollback fingerprint includes claims, ERC-20 balances, shares, the allocation, risk usage and both escrows'
///      ledgers; a failed callback must leave all of them unchanged.
contract IndependentHookCSecurityTest is IndependentHookCIntegrationTest {
    /// @notice The manager reaches C's permissioned callback and refuses native pool liquidity, so a later
    ///         swap cannot bypass the vault by executing against a separately funded native curve.
    function test_nativeLiquidityAdd_rejected() public {
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(manager);
        _expectHookRevert(
            address(hookC),
            IHooks.beforeAddLiquidity.selector,
            abi.encodeWithSelector(IndependentHookC.NativeLiquidityDisabled.selector)
        );
        lpRouter.modifyLiquidity(keyC, ModifyLiquidityParams(-200, 200, 1 ether, 0), "");
        assertEq(_claims(address(hookC), c0), 0);
        assertEq(_claims(address(hookC), c1), 0);
        _assertAccountingConsistent();
    }

    function _fingerprint(uint256 id) internal view returns (bytes32) {
        bytes32 vaultState = keccak256(
            abi.encode(
                lens.getAllocation(vault, id),
                lens.backing(vault, c0),
                lens.backing(vault, c1),
                lens.reserved(vault, c0),
                lens.reserved(vault, c1),
                lens.totalShares(vault)
            )
        );
        bytes32 assets = keccak256(
            abi.encode(
                _claims(address(vault), c0),
                _claims(address(vault), c1),
                _claims(address(hookC), c0),
                _claims(address(hookC), c1),
                token0.balanceOf(address(manager)),
                token1.balanceOf(address(manager)),
                token0.balanceOf(trader),
                token1.balanceOf(trader)
            )
        );
        bytes32 bond = keccak256(abi.encode(escrow.getBond(id), escrow.getLedger(c0), escrow.getLedger(c1)));
        bytes32 flow = keccak256(
            abi.encode(
                lens.getRiskLimit(vault, ISharedCommitmentVault.RiskScope.Hook, address(hookC), c1),
                lens.getRiskLimit(vault, ISharedCommitmentVault.RiskScope.Curator, curator, c1),
                lens.getRiskLimit(vault, ISharedCommitmentVault.RiskScope.Vault, address(0), c1)
            )
        );
        return keccak256(abi.encode(vaultState, assets, bond, flow));
    }

    function _reject(PoolKey memory key, bool zeroForOne, int256 specified, bytes memory data, uint256 id) internal {
        bytes32 beforeState = _fingerprint(id);
        vm.expectRevert();
        _swapRaw(key, zeroForOne, specified, data);
        assertEq(_fingerprint(id), beforeState, "rejection changed vault, manager, hook or escrow state");
        _assertEscrowIdentity();
    }

    /// @notice Callback authority and malformed input are rejected before claims can move. The tiny quote rounds
    ///         down to zero, and the trader minimum is checked before the vault sees the fill.
    function test_callbackBoundsAndTraderMinimum_rollback() public {
        _registerDirect();
        uint256 id = _allocate(keyC, c1, 1000 ether);
        vm.expectRevert(IndependentHookC.NotManager.selector);
        hookC.beforeSwap(
            trader,
            keyC,
            SwapParams({zeroForOne: true, amountSpecified: -int256(100 ether), sqrtPriceLimitX96: 0}),
            abi.encode(id, 0)
        );
        _reject(keyC, true, 100 ether, abi.encode(id, 0), id); // exact output
        _reject(keyC, true, -int256(100 ether), abi.encode(id), id); // no explicit trader minimum
        _reject(keyC, true, -int256(1), abi.encode(id, 0), id); // floor(0.999) = 0
        _reject(keyC, true, -int256(100 ether), abi.encode(id, 100 ether), id);
        _reject(keyC, true, -int256(uint256(uint128(type(int128).max)) + 1), abi.encode(id, 0), id);
    }

    /// @notice Pool and direction are bound to the allocation. At expiry - 1 second the allocation is still live;
    ///         at expiry it cannot be consumed, with no sweeper or keeper call required.
    function test_poolDirectionAndExactExpiry() public {
        _registerDirect();
        uint64 expiry = _hourAligned(vm.getBlockTimestamp() + 2 hours);
        uint256 id = _allocateUntil(keyC, c1, 1000 ether, expiry);
        _reject(keyC, false, -int256(100 ether), abi.encode(id, 0), id);
        PoolKey memory other = PoolKey(c0, c1, 3000, 60, IHooks(address(hookC)));
        manager.initialize(other, SQRT_PRICE_1_1);
        vm.prank(hookOwner);
        hookC.setPolicy(other, 1000, true);
        _reject(other, true, -int256(100 ether), abi.encode(id, 0), id);
        vm.warp(expiry - 1);
        _swapC(100 ether, id, 99 ether);
        assertEq(lens.getAllocation(vault, id).consumed, 99.9 ether);
        vm.warp(expiry);
        _reject(keyC, true, -int256(100 ether), abi.encode(id, 0), id);
    }

    /// @notice Hook deregistration, a direction halt, freeze and revocation stop an existing allocation. Curator
    ///         deregistration does not: G05 intentionally preserves existing allocations until close or expiry.
    function test_registrationAndCuratorRestrictions() public {
        _registerDirect();
        uint256 id = _allocate(keyC, c1, 1000 ether);
        vm.prank(owner);
        vault.setConsumer(address(hookC), false);
        _reject(keyC, true, -int256(100 ether), abi.encode(id, 0), id);
        vm.prank(owner);
        vault.setConsumer(address(hookC), true);
        vm.prank(owner);
        vault.setSellHalted(c1, true);
        _reject(keyC, true, -int256(100 ether), abi.encode(id, 0), id);
        vm.prank(owner);
        vault.setSellHalted(c1, false);
        vm.prank(owner);
        vault.freezeCurator(curator);
        _reject(keyC, true, -int256(100 ether), abi.encode(id, 0), id);
        vm.prank(owner);
        vault.unfreezeCurator(curator);
        vm.prank(owner);
        vault.setCurator(curator, false);
        _swapC(100 ether, id, 99 ether);
        assertEq(lens.getAllocation(vault, id).consumed, 99.9 ether);
        vm.prank(owner);
        vault.revokeCurator(curator);
        _reject(keyC, true, -int256(100 ether), abi.encode(id, 0), id);
    }

    /// @notice A quote that exceeds quota or is too generous for the curator's signed floor cannot move claims.
    ///         Disabling this hook's quote also leaves the reservation intact.
    function test_quotaCuratorFloorAndQuoteFailure() public {
        _registerDirect();
        uint256 id = _allocate(keyC, c1, 100 ether);
        _reject(keyC, true, -int256(101 ether), abi.encode(id, 0), id);
        vm.prank(hookOwner);
        hookC.setPolicy(keyC, 1000, false);
        _reject(keyC, true, -int256(100 ether), abi.encode(id, 0), id);
        vm.prank(hookOwner);
        hookC.setPolicy(keyC, 1000, true);

        ISharedCommitmentVault.AllocationRequest memory strict = _request(keyC, c1, 1000 ether);
        strict.minInPerOutX96 = uint160(FixedPoint96.Q96 * 101 / 100);
        strict.deadline = uint64(vm.getBlockTimestamp());
        vm.prank(curator);
        uint256 strictId = bonded.activateDirectBonded(strict, RHO);
        _reject(keyC, true, -int256(100 ether), abi.encode(strictId, 0), strictId);
    }

    /// @notice A missing router payment and a later failed step in one unlock roll back all earlier fills too.
    function test_routerPaymentAndSameUnlockContention_rollback() public {
        _registerDirect();
        uint256 idA = _allocate(keyA, c1, 100 ether);
        uint256 idC = _allocate(keyC, c1, 100 ether);
        BatchSwapRouter.Step[] memory steps = new BatchSwapRouter.Step[](2);
        steps[0] = BatchSwapRouter.Step(keyA, true, 100 ether, abi.encode(idA));
        steps[1] = BatchSwapRouter.Step(keyC, true, 101 ether, abi.encode(idC, 0));
        uint256[] memory mins = new uint256[](2);
        bytes32 aBefore = _fingerprint(idA);
        bytes32 cBefore = _fingerprint(idC);
        vm.prank(trader);
        vm.expectRevert();
        batchRouter.run(steps, mins, BatchSwapRouter.Mode.Settle);
        assertEq(_fingerprint(idA), aBefore);
        assertEq(_fingerprint(idC), cBefore);

        steps = new BatchSwapRouter.Step[](1);
        steps[0] = BatchSwapRouter.Step(keyC, true, 100 ether, abi.encode(idC, 0));
        vm.prank(trader);
        vm.expectRevert();
        batchRouter.run(steps, mins, BatchSwapRouter.Mode.SkipInputPayment);
        assertEq(_fingerprint(idC), cBefore);
    }

    /// @notice Each of the hook, curator and vault gross-flow windows independently rejects the same C fill. The
    ///         failed swap must not advance any flow record or move escrow claims.
    function test_eachFlowScope_refusesWithoutStateChange() public {
        _registerDirect();
        uint256 id = _allocate(keyC, c1, 1000 ether);
        ISharedCommitmentVault.RiskScope[3] memory scopes = [
            ISharedCommitmentVault.RiskScope.Hook,
            ISharedCommitmentVault.RiskScope.Curator,
            ISharedCommitmentVault.RiskScope.Vault
        ];
        address[3] memory accounts = [address(hookC), curator, address(0)];
        for (uint256 i; i < 3; ++i) {
            uint256 snap = vm.snapshotState();
            vm.prank(owner);
            vault.setRiskLimit(scopes[i], accounts[i], c1, 50 ether, 10_000);
            _reject(keyC, true, -int256(100 ether), abi.encode(id, 0), id);
            vm.revertToState(snap);
        }
    }

    /// @notice An already bonded allocation can later become unfillable when the owner tightens the inventory
    ///         floor or installs a dynamic reference floor. The hook's independent quote never overrides the vault.
    function test_inventoryAndDynamicFloors_refuseWithoutStateChange() public {
        _registerDirect();
        uint256 id = _allocate(keyC, c1, 1000 ether);
        uint256 snap = vm.snapshotState();
        vm.prank(owner);
        vault.setInventoryBounds(0, 1e18, 1_000_000, 0);
        _reject(keyC, true, -int256(100 ether), abi.encode(id, 0), id);
        vm.revertToState(snap);

        MockRiskAdapter adapter = new MockRiskAdapter(address(token0), address(token1), 18, 18, keccak256("hookC"));
        adapter.set(FixedPoint96.Q96, 0, type(uint256).max);
        vm.startPrank(owner);
        vault.setInventoryBounds(1e18, 1e18, 1_000_000, 1_000_000);
        vault.setRiskBounds(5000, 20_000);
        vault.setRiskAdapter(IMarketRiskAdapter(address(adapter)));
        vm.stopPrank();
        _reject(keyC, true, -int256(100 ether), abi.encode(id, 0), id);
    }

    /// @notice This test-only storage transition recreates the preconfiguration state after admission so the fill
    ///         path's unconfigured-direction check is exercised through Hook C. No owner method clears a live floor.
    function test_unconfiguredDirection_failsClosed() public {
        _registerDirect();
        uint256 id = _allocate(keyC, c1, 1000 ether);
        bytes32 policySlot = keccak256(abi.encode(Currency.unwrap(c1), uint256(10)));
        vm.store(address(vault), policySlot, bytes32(0));
        _reject(keyC, true, -int256(100 ether), abi.encode(id, 0), id);
    }

    /// @notice A fourth, registered but malicious hook shares Hook C's reserve. It cannot pull unrelated vault
    ///         claims, omit input funding, exceed quota or lie to the PoolManager about output. The deliberately
    ///         incorrect output delta lets the vault fill first, then makes the whole unlock revert atomically.
    function test_registeredMaliciousHook_cannotSpendVaultClaimsOrMisaccount() public {
        _registerDirect();
        uint256 idC = _allocate(keyC, c1, 100 ether);
        address malAddr =
            address(uint160(0xC04D << 140) | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        deployCodeTo("MaliciousConsumerHook.sol:MaliciousConsumerHook", abi.encode(manager, vault), malAddr);
        MaliciousConsumerHook mal = MaliciousConsumerHook(malAddr);
        PoolKey memory keyM = PoolKey(c0, c1, 3000, 60, IHooks(malAddr));
        manager.initialize(keyM, SQRT_PRICE_1_1);
        vm.prank(owner);
        vault.setConsumer(malAddr, true);
        _openLimitsAsOwner(ISharedCommitmentVault.RiskScope.Hook, malAddr);
        uint256 idM = _allocate(keyM, c1, 100 ether);
        assertFalse(manager.isOperator(address(vault), malAddr));

        MaliciousConsumerHook.Attack[6] memory modes = [
            MaliciousConsumerHook.Attack.SkipInputFunding,
            MaliciousConsumerHook.Attack.BurnVaultClaims,
            MaliciousConsumerHook.Attack.TransferFromVault,
            MaliciousConsumerHook.Attack.OverQuota,
            MaliciousConsumerHook.Attack.BelowFloor,
            MaliciousConsumerHook.Attack.LieAboutOutput
        ];
        for (uint256 i; i < modes.length; ++i) {
            uint256 snap = vm.snapshotState();
            uint256 requested = modes[i] == MaliciousConsumerHook.Attack.OverQuota ? 101 ether : 100 ether;
            mal.configure(modes[i], idM, requested);
            bytes32 beforeM = _fingerprint(idM);
            bytes32 beforeC = _fingerprint(idC);
            vm.expectRevert();
            _swapRaw(keyM, true, -int256(100 ether), abi.encode(idM));
            assertEq(_fingerprint(idM), beforeM);
            assertEq(_fingerprint(idC), beforeC);
            assertEq(_claims(malAddr, c0), 0);
            assertEq(_claims(malAddr, c1), 0);
            vm.revertToState(snap);
        }
    }
}
