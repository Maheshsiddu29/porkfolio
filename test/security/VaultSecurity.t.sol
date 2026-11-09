// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {stdError} from "forge-std/StdError.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {ICuratorAuthorization} from "../../src/interfaces/ICuratorAuthorization.sol";
import {BaseCompatibleHook} from "../../src/hooks/BaseCompatibleHook.sol";
import {HookA_DynamicFee} from "../../src/hooks/HookA_DynamicFee.sol";
import {HookB_BoundedImpact} from "../../src/hooks/HookB_BoundedImpact.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {BatchSwapRouter} from "../utils/BatchSwapRouter.sol";
import {MaliciousConsumerHook} from "../utils/MaliciousConsumerHook.sol";

/// @notice Negative-path and adversarial tests. Every swap goes through the real PoolManager.
contract VaultSecurityTest is VaultTestBase {
    uint128 internal constant QUOTA = 10_000 ether;

    // ==================================================================
    // Consumer authorisation
    // ==================================================================

    function test_unregisteredHook_cannotBeAllocatedTo() public {
        (HookA_DynamicFee hookC, PoolKey memory keyC) = _deployUnregisteredHookA();
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyC, c1, QUOTA);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.ConsumerNotRegistered.selector, address(hookC)));
        auth.activateDirect(req);
    }

    function test_revokedHook_cannotConsume() public {
        uint256 id = _allocate(keyA, c1, QUOTA);
        vm.prank(owner);
        vault.setConsumer(address(hookA), false);

        _expectSwapRevert(
            address(hookA),
            abi.encodeWithSelector(ISharedCommitmentVault.ConsumerNotRegistered.selector, address(hookA))
        );
        _swap(keyA, true, 1 ether, id);
    }

    /// @notice A registered hook cannot spend another hook's allocation.
    function test_hookB_cannotUseHookA_allocation() public {
        uint256 idA = _allocate(keyA, c1, QUOTA);
        _expectSwapRevert(
            address(hookB),
            abi.encodeWithSelector(ISharedCommitmentVault.ConsumerMismatch.selector, address(hookA), address(hookB))
        );
        _swap(keyB, true, 1 ether, idA);
    }

    function test_eoa_cannotCallExchange() public {
        uint256 id = _allocate(keyA, c1, QUOTA);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.ConsumerNotRegistered.selector, attacker));
        vault.exchange(keyA, true, id, 1 ether, 1 ether);
    }

    /// @notice A registered hook calling exchange directly with a key whose `hooks` is another address.
    function test_registeredHook_cannotPassForeignKey() public {
        uint256 id = _allocate(keyA, c1, QUOTA);
        vm.prank(address(hookA));
        vm.expectRevert(
            abi.encodeWithSelector(ISharedCommitmentVault.ConsumerMismatch.selector, address(hookA), address(hookB))
        );
        vault.exchange(keyB, true, id, 1 ether, 1 ether);
    }

    /// @notice No blanket ERC-6909 rights over vault claims are ever granted.
    function test_noOperatorOrAllowanceOverVaultClaims() public view {
        address[3] memory hooks = [address(hookA), address(hookB), address(swapRouter)];
        for (uint256 i; i < hooks.length; ++i) {
            assertFalse(manager.isOperator(address(vault), hooks[i]));
            assertEq(manager.allowance(address(vault), hooks[i], c0.toId()), 0);
            assertEq(manager.allowance(address(vault), hooks[i], c1.toId()), 0);
        }
        // The only operator relationship is hook -> vault (vault may pull the hook's own transient input claims).
        assertTrue(manager.isOperator(address(hookA), address(vault)));
    }

    // ==================================================================
    // Pool / currency / direction binding
    // ==================================================================

    function test_wrongPool_sameHook_reverts() public {
        PoolKey memory keyA2 = PoolKey(c0, c1, 10_000, 200, IHooks(address(hookA)));
        manager.initialize(keyA2, SQRT_PRICE_1_1);
        vm.prank(hookOwner);
        hookA.configurePool(keyA2, PRICE_1_1_X96, 500, 5000);

        uint256 id = _allocate(keyA, c1, QUOTA);
        _expectSwapRevert(address(hookA), abi.encodeWithSelector(ISharedCommitmentVault.PoolMismatch.selector));
        _swap(keyA2, true, 1 ether, id);
    }

    function test_wrongDirection_reverts() public {
        uint256 id = _allocate(keyA, c1, QUOTA); // pays out token1 => only zeroForOne
        _expectSwapRevert(address(hookA), abi.encodeWithSelector(ISharedCommitmentVault.DirectionMismatch.selector));
        _swap(keyA, false, 1 ether, id);
    }

    function test_allocate_currencyNotInPool_reverts() public {
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, QUOTA);
        req.currencyOut = Currency.wrap(address(0xdead));
        vm.prank(curator);
        vm.expectRevert(ISharedCommitmentVault.InvalidCurrency.selector);
        auth.activateDirect(req);
    }

    function test_allocate_consumerKeyMismatch_reverts() public {
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, QUOTA);
        req.consumer = address(hookB);
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(ISharedCommitmentVault.ConsumerMismatch.selector, address(hookB), address(hookA))
        );
        auth.activateDirect(req);
    }

    function test_unknownAllocation_reverts() public {
        _expectSwapRevert(
            address(hookA), abi.encodeWithSelector(ISharedCommitmentVault.UnknownAllocation.selector, 999)
        );
        _swap(keyA, true, 1 ether, 999);
    }

    // ==================================================================
    // Quotas, ceilings and backing
    // ==================================================================

    function test_quotaExhaustion() public {
        uint256 id = _allocate(keyA, c1, 1000 ether);
        _swap(keyA, true, 900 ether, id);
        uint256 remaining = 1000 ether - vault.getAllocation(id).consumed;
        uint256 out = hookA.quote(keyA, true, 200 ether, id);
        assertGt(out, remaining);

        _expectSwapRevert(
            address(hookA), abi.encodeWithSelector(ISharedCommitmentVault.QuotaExceeded.selector, out, remaining)
        );
        _swap(keyA, true, 200 ether, id);

        // A smaller swap that fits the remaining quota still succeeds.
        _swap(keyA, true, 50 ether, id);
        _assertAccountingConsistent();
    }

    function test_curatorCeiling_enforced() public {
        vm.prank(owner);
        vault.setCuratorCeiling(curator, c1, 5000 ether);
        _allocate(keyA, c1, 4000 ether);

        ISharedCommitmentVault.AllocationRequest memory req = _request(keyB, c1, 1001 ether);
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(ISharedCommitmentVault.CuratorCeilingExceeded.selector, 1001 ether, 1000 ether)
        );
        auth.activateDirect(req);
    }

    function test_unauthorisedCurator_hasZeroCeiling() public {
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, 1);
        // An unregistered address is rejected before any ceiling is consulted...
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.CuratorNotRegistered.selector, attacker));
        auth.activateDirect(req);
        // ...and registration alone grants no capacity: the ceiling is still zero.
        vm.prank(owner);
        vault.setCurator(attacker, true);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.CuratorCeilingExceeded.selector, 1, 0));
        auth.activateDirect(req);
    }

    function test_insufficientBacking_singleAndAggregate() public {
        // Single allocation above total backing.
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, uint128(VAULT_FUNDING + 1));
        vm.prank(owner);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.InsufficientBacking.selector, VAULT_FUNDING + 1, VAULT_FUNDING
            )
        );
        auth.activateDirect(req);

        // Aggregate: Q + newQ + R + D must not exceed N (here D = 0 and N = backing).
        vm.prank(owner);
        vault.setBufferFloor(c1, 200_000 ether);
        _allocate(keyA, c1, 500_000 ether);
        req = _request(keyB, c1, 300_000 ether + 1);
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.InsufficientBacking.selector, 300_000 ether + 1, 300_000 ether
            )
        );
        auth.activateDirect(req);
        _allocate(keyB, c1, 300_000 ether); // exactly at the bound succeeds
        assertEq(vault.reserved(c1) + vault.bufferFloor(c1), vault.backing(c1));
    }

    function test_maxOut_aboveInt128_reverts() public {
        vm.prank(owner);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, type(uint128).max);
        vm.prank(curator);
        vm.expectRevert(ISharedCommitmentVault.AmountTooLarge.selector);
        auth.activateDirect(req);
    }

    function test_priceFloor_enforced() public {
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, QUOTA);
        req.minInPerOutX96 = uint160(FixedPoint96.Q96 * 101 / 100); // demand >= 1.01 in per out
        vm.prank(curator);
        uint256 id = auth.activateDirect(req);

        uint256 out = hookA.quote(keyA, true, 100 ether, id);
        uint256 requiredIn = (out * req.minInPerOutX96 + FixedPoint96.Q96 - 1) / FixedPoint96.Q96;
        _expectSwapRevert(
            address(hookA),
            abi.encodeWithSelector(ISharedCommitmentVault.PriceBelowFloor.selector, 100 ether, requiredIn)
        );
        _swap(keyA, true, 100 ether, id);
    }

    // ==================================================================
    // Expiry, deadlines, horizon, replay
    // ==================================================================

    function test_expiry_boundary() public {
        uint256 id = _allocate(keyA, c1, QUOTA);
        uint64 expiry = vault.getAllocation(id).expiry;

        vm.warp(expiry - 1);
        _swap(keyA, true, 1 ether, id); // last valid second

        vm.warp(expiry);
        _expectSwapRevert(
            address(hookA), abi.encodeWithSelector(ISharedCommitmentVault.AllocationExpired.selector, id, expiry)
        );
        _swap(keyA, true, 1 ether, id);
    }

    function test_instructionDeadline() public {
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, QUOTA);
        vm.warp(req.deadline + 1);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InstructionExpired.selector, req.deadline));
        auth.activateDirect(req);
    }

    function test_horizonAndPastExpiry() public {
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, QUOTA);
        req.expiry = uint64(block.timestamp + 30 days + 1);
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.HorizonExceeded.selector, req.expiry, block.timestamp + 30 days
            )
        );
        auth.activateDirect(req);

        req.expiry = type(uint64).max;
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.HorizonExceeded.selector, req.expiry, block.timestamp + 30 days
            )
        );
        auth.activateDirect(req);

        // An expiry that is not in the future is caught by the module first, because it is not after the deadline
        // (which the vault requires to be now or later). The vault's own InvalidExpiry check is still reached by a
        // module that skips this rule: test_ML_compromisedModuleBoundedByVault.
        req.expiry = uint64(block.timestamp);
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(ICuratorAuthorization.ExpiryNotAfterDeadline.selector, req.expiry, req.deadline)
        );
        auth.activateDirect(req);

        req.expiry = uint64(block.timestamp + 30 days); // exactly at horizon is allowed
        vm.prank(curator);
        auth.activateDirect(req);
    }

    function test_replay_sameNonce_reverts_evenAfterRelease() public {
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, QUOTA);
        vm.prank(curator);
        uint256 id = auth.activateDirect(req);

        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ICuratorAuthorization.NonceAlreadyUsed.selector, curator, req.nonce));
        auth.activateDirect(req);

        vm.warp(req.expiry);
        vault.release(id);
        req.expiry = uint64(block.timestamp + 1 days);
        req.deadline = uint64(block.timestamp + 1 hours);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ICuratorAuthorization.NonceAlreadyUsed.selector, curator, req.nonce));
        auth.activateDirect(req);
    }

    function test_nonce_isCuratorScoped() public {
        address curator2 = makeAddr("curator2");
        vm.startPrank(owner);
        vault.setCurator(curator2, true);
        vault.setCuratorCeiling(curator2, c1, QUOTA);
        _openLimits(ISharedCommitmentVault.RiskScope.Curator, curator2);
        vm.stopPrank();
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, QUOTA);
        vm.prank(curator);
        auth.activateDirect(req);
        vm.prank(curator2);
        auth.activateDirect(req); // same nonce, different curator: independent
    }

    /// @notice Lazy expiry: time passing changes nothing on-chain; capacity returns only on `release`.
    function test_lazyRelease() public {
        uint256 id = _allocate(keyA, c1, QUOTA);
        _swap(keyA, true, 1000 ether, id);
        uint256 unused = QUOTA - vault.getAllocation(id).consumed;
        uint64 expiry = vault.getAllocation(id).expiry;

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.AllocationNotExpired.selector, id, expiry));
        vault.release(id);

        vm.warp(expiry + 365 days);
        assertEq(vault.reserved(c1), unused, "expiry must not release capacity by itself");

        vm.prank(attacker); // permissionless after expiry
        vault.release(id);
        assertEq(vault.reserved(c1), 0);
        assertEq(vault.curatorReserved(curator, c1), 0);

        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.AllocationAlreadyReleased.selector, id));
        vault.release(id);
    }

    function test_ownerEmergencyRelease_blocksFurtherConsumption() public {
        uint256 id = _allocate(keyA, c1, QUOTA);
        vm.prank(owner);
        vault.release(id);
        _expectSwapRevert(
            address(hookA), abi.encodeWithSelector(ISharedCommitmentVault.AllocationAlreadyReleased.selector, id)
        );
        _swap(keyA, true, 1 ether, id);
    }

    function test_pause_blocksAllocationAndConsumption_notWithdrawal() public {
        uint256 id = _allocate(keyA, c1, QUOTA);
        vm.prank(owner);
        vault.setPaused(true);

        _expectSwapRevert(address(hookA), abi.encodeWithSelector(ISharedCommitmentVault.Paused.selector));
        _swap(keyA, true, 1 ether, id);

        ISharedCommitmentVault.AllocationRequest memory req = _request(keyB, c1, QUOTA);
        vm.prank(curator);
        vm.expectRevert(ISharedCommitmentVault.Paused.selector);
        auth.activateDirect(req);

        // The owner has no asset path; LP redemption stays available while paused.
        (uint256 instant,,,) = _redeem(lp0, 1 ether, false);
        assertEq(instant, 1 ether);
    }

    // ==================================================================
    // Swap-shape validation
    // ==================================================================

    function test_exactOutput_unsupported() public {
        uint256 id = _allocate(keyA, c1, QUOTA);
        _expectSwapRevert(address(hookA), abi.encodeWithSelector(BaseCompatibleHook.ExactOutputNotSupported.selector));
        _swapRaw(keyA, true, int256(1 ether), abi.encode(id));
    }

    /// @notice A zero-amount swap never reaches the hook: the pinned PoolManager rejects it first with its own
    ///         `SwapAmountCannotBeZero`, and `beforeSwap` is not called. If a caller with PoolManager authority did
    ///         pass zero, the hook reports `ZeroInput`, not `ExactOutputNotSupported`, because a zero swap is not
    ///         an exact-output swap.
    function test_zeroAmountSwap_rejectedBeforeAndInsideHook() public {
        uint256 id = _allocate(keyA, c1, QUOTA);
        vm.expectCall(address(hookA), abi.encodePacked(IHooks.beforeSwap.selector), 0);
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        _swapRaw(keyA, true, 0, abi.encode(id));

        // Direct calls go to hookB so the zero-call expectation above stays about hookA and the PoolManager path.
        vm.prank(address(manager));
        vm.expectRevert(BaseCompatibleHook.ZeroInput.selector);
        hookB.beforeSwap(trader, keyB, _params(true, 0), abi.encode(id));

        vm.prank(address(manager));
        vm.expectRevert(BaseCompatibleHook.ExactOutputNotSupported.selector);
        hookB.beforeSwap(trader, keyB, _params(true, 1), abi.encode(id));
    }

    /// @notice Every hook constructor argument is immutable. A zero PoolManager, vault or owner would leave a hook
    ///         that can never be called, never fill a swap, or never be configured. The check runs before the
    ///         address-permission check, so the revert names the real problem even at an unmined address.
    function test_hookConstructor_rejectsZeroAddresses() public {
        vm.expectRevert(BaseCompatibleHook.ZeroAddress.selector);
        new HookA_DynamicFee(IPoolManager(address(0)), vault, hookOwner);
        vm.expectRevert(BaseCompatibleHook.ZeroAddress.selector);
        new HookA_DynamicFee(manager, ISharedCommitmentVault(address(0)), hookOwner);
        vm.expectRevert(BaseCompatibleHook.ZeroAddress.selector);
        new HookA_DynamicFee(manager, vault, address(0));
        vm.expectRevert(BaseCompatibleHook.ZeroAddress.selector);
        new HookB_BoundedImpact(IPoolManager(address(0)), vault, hookOwner);
        vm.expectRevert(BaseCompatibleHook.ZeroAddress.selector);
        new HookB_BoundedImpact(manager, ISharedCommitmentVault(address(0)), hookOwner);
        vm.expectRevert(BaseCompatibleHook.ZeroAddress.selector);
        new HookB_BoundedImpact(manager, vault, address(0));

        // Control: non-zero arguments get past the zero check and fail only on the unmined address.
        vm.expectPartialRevert(Hooks.HookAddressNotValid.selector);
        new HookA_DynamicFee(manager, vault, hookOwner);
    }

    function test_invalidHookData() public {
        _expectSwapRevert(address(hookA), abi.encodeWithSelector(BaseCompatibleHook.InvalidHookData.selector));
        _swapRaw(keyA, true, -1 ether, "");

        _expectSwapRevert(address(hookA), abi.encodeWithSelector(BaseCompatibleHook.InvalidHookData.selector));
        _swapRaw(keyA, true, -1 ether, abi.encode(uint256(1), uint256(2)));
    }

    function test_amountBounds_int128() public {
        uint256 id = _allocate(keyA, c1, QUOTA);
        _expectSwapRevert(address(hookA), abi.encodeWithSelector(BaseCompatibleHook.AmountTooLarge.selector));
        _swapRaw(keyA, true, type(int256).min, abi.encode(id));

        _expectSwapRevert(address(hookA), abi.encodeWithSelector(BaseCompatibleHook.AmountTooLarge.selector));
        _swapRaw(keyA, true, -int256(uint256(uint128(type(int128).max))) - 1, abi.encode(id));
    }

    function test_dustInput_zeroOutput_reverts() public {
        uint256 id = _allocate(keyA, c1, QUOTA);
        _expectSwapRevert(address(hookA), abi.encodeWithSelector(BaseCompatibleHook.ZeroOutput.selector));
        _swap(keyA, true, 1, id); // 1 wei * (1 - fee) rounds down to 0
    }

    function test_hookB_impactBound() public {
        uint256 id = _allocate(keyB, c1, 1000 ether);
        // impact = 10_000 * 2001/1000 pips = 20_010 > max 20_000
        _expectSwapRevert(
            address(hookB), abi.encodeWithSelector(HookB_BoundedImpact.ImpactBoundExceeded.selector, 20_010, 20_000)
        );
        _swap(keyB, true, 2001 ether, id);
    }

    function test_hookCallbacks_onlyPoolManager() public {
        vm.prank(attacker);
        vm.expectRevert(BaseCompatibleHook.NotPoolManager.selector);
        hookA.beforeSwap(attacker, keyA, _params(true, -1 ether), abi.encode(uint256(1)));
    }

    // ==================================================================
    // Settlement integrity
    // ==================================================================

    /// @notice A router that does not pay the input leaves a negative delta; PoolManager.unlock reverts with
    ///         CurrencyNotSettled and every vault/hook effect from inside the swap is rolled back.
    function test_incorrectSettlement_rollsBackVault() public {
        uint256 id = _allocate(keyA, c1, QUOTA);
        uint256 b0 = vault.backing(c0);
        uint256 b1 = vault.backing(c1);

        BatchSwapRouter.Step[] memory steps = new BatchSwapRouter.Step[](1);
        steps[0] = BatchSwapRouter.Step(keyA, true, 1000 ether, abi.encode(id));
        vm.prank(trader);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        batchRouter.run(steps, new uint256[](0), BatchSwapRouter.Mode.SkipInputPayment);

        assertEq(vault.backing(c0), b0);
        assertEq(vault.backing(c1), b1);
        assertEq(vault.getAllocation(id).consumed, 0);
        _assertAccountingConsistent();
    }

    /// @notice A well-formed payload in the vault's current encoding (action, account, amount0, amount1) that would
    ///         pay the whole backing to the attacker if it ran. The sender check rejects it before decoding, and
    ///         nothing moves. The Deposit form (pulling an LP's approved tokens) is covered in ShareSecurity.
    function test_unlockCallback_onlyPoolManager() public {
        uint256 b0 = vault.backing(c0);
        uint256 b1 = vault.backing(c1);
        bytes memory payload = abi.encode(SharedCommitmentVault.CallbackAction.Withdraw, attacker, b0, b1);
        (SharedCommitmentVault.CallbackAction action, address account, uint256 a0, uint256 a1) =
            abi.decode(payload, (SharedCommitmentVault.CallbackAction, address, uint256, uint256));
        assertEq(uint8(action), uint8(SharedCommitmentVault.CallbackAction.Withdraw));
        assertEq(account, attacker);
        assertEq(a0, b0);
        assertEq(a1, b1);

        vm.prank(attacker);
        vm.expectRevert(ISharedCommitmentVault.NotPoolManager.selector);
        vault.unlockCallback(payload);

        assertEq(vault.backing(c0), b0);
        assertEq(vault.backing(c1), b1);
        assertEq(token0.balanceOf(attacker), 0);
        assertEq(token1.balanceOf(attacker), 0);
        _assertAccountingConsistent();
    }

    // ==================================================================
    // Compromised *registered* hook: what the vault still guarantees
    //
    // The owner has whitelisted the hook, so registration checks do not help. Each attack must still fail on
    // something the hook cannot control: ERC-6909 balances and allowances on the real PoolManager (the vault
    // never granted the hook any authority over its claims), the allocation's quota, or the price floor. Every
    // test then checks that the vault's backing and real claim balances are exactly as before.
    // ==================================================================

    function test_maliciousHook_cannotTakeOutputWithoutFundingInput() public {
        (MaliciousConsumerHook m, PoolKey memory keyM, uint256 id) = _setupMalicious();
        m.configure(MaliciousConsumerHook.Attack.SkipInputFunding, id, 100 ether);
        _expectSwapRevert(address(m), stdError.arithmeticError); // ERC-6909 balance underflow on pull
        _swapRaw(keyM, true, -100 ether, "");
        _assertMaliciousHadNoEffect(id);
    }

    function test_maliciousHook_cannotBurnVaultClaims() public {
        (MaliciousConsumerHook m, PoolKey memory keyM, uint256 id) = _setupMalicious();
        m.configure(MaliciousConsumerHook.Attack.BurnVaultClaims, id, 100 ether);
        _expectSwapRevert(address(m), stdError.arithmeticError); // allowance underflow in _burnFrom
        _swapRaw(keyM, true, -100 ether, "");
        _assertMaliciousHadNoEffect(id);
    }

    function test_maliciousHook_cannotTransferFromVault() public {
        (MaliciousConsumerHook m, PoolKey memory keyM, uint256 id) = _setupMalicious();
        m.configure(MaliciousConsumerHook.Attack.TransferFromVault, id, 100 ether);
        _expectSwapRevert(address(m), stdError.arithmeticError); // allowance underflow in transferFrom
        _swapRaw(keyM, true, -100 ether, "");
        _assertMaliciousHadNoEffect(id);
    }

    function test_maliciousHook_cannotExceedQuota() public {
        (MaliciousConsumerHook m, PoolKey memory keyM, uint256 id) = _setupMalicious();
        m.configure(MaliciousConsumerHook.Attack.OverQuota, id, 1000 ether + 1);
        _expectSwapRevert(
            address(m),
            abi.encodeWithSelector(ISharedCommitmentVault.QuotaExceeded.selector, 1000 ether + 1, 1000 ether)
        );
        _swapRaw(keyM, true, -2000 ether, "");
        _assertMaliciousHadNoEffect(id);
    }

    function test_maliciousHook_cannotBuyBelowFloor() public {
        (MaliciousConsumerHook m, PoolKey memory keyM, uint256 id) = _setupMalicious();
        m.configure(MaliciousConsumerHook.Attack.BelowFloor, id, 100 ether);
        uint256 requiredIn =
            (100 ether * uint256(vault.getAllocation(id).minInPerOutX96) + FixedPoint96.Q96 - 1) / FixedPoint96.Q96;
        _expectSwapRevert(
            address(m), abi.encodeWithSelector(ISharedCommitmentVault.PriceBelowFloor.selector, 1, requiredIn)
        );
        _swapRaw(keyM, true, -100 ether, "");
        _assertMaliciousHadNoEffect(id);
    }

    // ==================================================================
    // Helpers
    // ==================================================================

    function _params(bool zeroForOne, int256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function _deployUnregisteredHookA() internal returns (HookA_DynamicFee hookC, PoolKey memory keyC) {
        hookC = HookA_DynamicFee(_deployHook("HookA_DynamicFee.sol:HookA_DynamicFee", 0xC0C));
        keyC = PoolKey(c0, c1, 3000, 60, IHooks(address(hookC)));
        manager.initialize(keyC, SQRT_PRICE_1_1);
        vm.prank(hookOwner);
        hookC.configurePool(keyC, PRICE_1_1_X96, 500, 5000);
    }

    function _setupMalicious() internal returns (MaliciousConsumerHook m, PoolKey memory keyM, uint256 id) {
        address addr = address(uint160(0xBAD << 140) | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        deployCodeTo("MaliciousConsumerHook.sol:MaliciousConsumerHook", abi.encode(manager, vault), addr);
        m = MaliciousConsumerHook(addr);
        keyM = PoolKey(c0, c1, 3000, 60, IHooks(addr));
        manager.initialize(keyM, SQRT_PRICE_1_1);
        vm.prank(owner);
        vault.setConsumer(addr, true); // the owner whitelisted it: worst case
        _openLimitsAsOwner(ISharedCommitmentVault.RiskScope.Hook, addr);
        id = _allocate(keyM, c1, 1000 ether);
    }

    function _assertMaliciousHadNoEffect(uint256 id) internal view {
        assertEq(vault.getAllocation(id).consumed, 0);
        assertEq(vault.backing(c0), VAULT_FUNDING);
        assertEq(vault.backing(c1), VAULT_FUNDING);
        assertEq(_claims(address(vault), c0), VAULT_FUNDING);
        assertEq(_claims(address(vault), c1), VAULT_FUNDING);
    }
}
