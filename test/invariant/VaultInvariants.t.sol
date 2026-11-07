// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @notice Random action sequences against the real PoolManager. Each action may revert; the
///         invariants below must hold after every step regardless.
contract VaultHandler is Test {
    SharedCommitmentVault internal vault;
    IPoolManager internal manager;
    PoolSwapTest internal router;
    PoolKey internal keyA;
    PoolKey internal keyB;
    Currency internal c0;
    Currency internal c1;
    address internal owner;
    address internal curator;
    address internal trader;

    uint256[] public allocationIds;
    uint256 internal nonce = 1_000_000;

    /// Ghost ledger: backing implied by deposits - withdrawals + inputs received - outputs paid.
    mapping(Currency => uint256) public ghostBacking;
    uint256 public swapsOk;
    uint256 public allocationsOk;
    uint256 public releasesOk;

    constructor(
        SharedCommitmentVault vault_,
        IPoolManager manager_,
        PoolSwapTest router_,
        PoolKey memory keyA_,
        PoolKey memory keyB_,
        address owner_,
        address curator_,
        address trader_
    ) {
        vault = vault_;
        manager = manager_;
        router = router_;
        keyA = keyA_;
        keyB = keyB_;
        c0 = keyA_.currency0;
        c1 = keyA_.currency1;
        owner = owner_;
        curator = curator_;
        trader = trader_;
        ghostBacking[c0] = vault_.backing(c0);
        ghostBacking[c1] = vault_.backing(c1);
    }

    function allocationCount() external view returns (uint256) {
        return allocationIds.length;
    }

    function allocate(uint256 seed, uint256 maxOut, uint256 lifetime) external {
        PoolKey memory key = seed % 2 == 0 ? keyA : keyB;
        Currency out = (seed >> 1) % 2 == 0 ? c0 : c1;
        maxOut = bound(maxOut, 1 ether, 300_000 ether);
        lifetime = bound(lifetime, 1, 30 days);
        ISharedCommitmentVault.AllocationRequest memory req = ISharedCommitmentVault.AllocationRequest({
            consumer: address(key.hooks),
            key: key,
            currencyOut: out,
            // forge-lint: disable-next-line(unsafe-typecast)
            maxOut: uint128(maxOut),
            minInPerOutX96: uint160(FixedPoint96.Q96 * 98 / 100),
            expiry: uint64(block.timestamp + lifetime),
            nonce: nonce++,
            deadline: uint64(block.timestamp)
        });
        vm.prank(curator);
        try vault.allocate(req) returns (uint256 id) {
            allocationIds.push(id);
            allocationsOk++;
        } catch {}
    }

    function swap(uint256 idSeed, uint256 amountIn) external {
        if (allocationIds.length == 0) return;
        uint256 id = allocationIds[idSeed % allocationIds.length];
        ISharedCommitmentVault.Allocation memory a = vault.getAllocation(id);
        PoolKey memory key = a.consumer == address(keyA.hooks) ? keyA : keyB;
        bool zeroForOne = a.currencyOut == c1;
        amountIn = bound(amountIn, 1e9, 50_000 ether);

        MockERC20(Currency.unwrap(zeroForOne ? c0 : c1)).mint(trader, amountIn);
        vm.prank(trader);
        try router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(id)
        ) returns (
            BalanceDelta d
        ) {
            int128 outDelta = zeroForOne ? d.amount1() : d.amount0();
            ghostBacking[zeroForOne ? c0 : c1] += amountIn;
            // forge-lint: disable-next-line(unsafe-typecast)
            ghostBacking[a.currencyOut] -= uint256(int256(outDelta));
            swapsOk++;
        } catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 3 days));
    }

    function release(uint256 idSeed, bool asOwner) external {
        if (allocationIds.length == 0) return;
        uint256 id = allocationIds[idSeed % allocationIds.length];
        vm.prank(asOwner ? owner : address(0xBEEF));
        try vault.release(id) {
            releasesOk++;
        } catch {}
    }

    function deposit(bool zero, uint256 amount) external {
        Currency c = zero ? c0 : c1;
        amount = bound(amount, 1, 100_000 ether);
        MockERC20(Currency.unwrap(c)).mint(owner, amount);
        vm.startPrank(owner);
        MockERC20(Currency.unwrap(c)).approve(address(vault), amount);
        vault.deposit(c, amount);
        vm.stopPrank();
        ghostBacking[c] += amount;
    }

    function withdraw(bool zero, uint256 amount) external {
        Currency c = zero ? c0 : c1;
        uint256 free = vault.freeBacking(c);
        if (free == 0) return;
        amount = bound(amount, 1, free);
        vm.prank(owner);
        vault.withdraw(c, amount, owner);
        ghostBacking[c] -= amount;
    }
}

contract VaultInvariantsTest is VaultTestBase {
    VaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new VaultHandler(vault, manager, swapRouter, keyA, keyB, owner, curator, trader);
        vm.prank(owner);
        vault.setBufferFloor(c0, 50_000 ether);
        vm.prank(trader);
        token0.approve(address(swapRouter), type(uint256).max);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = VaultHandler.allocate.selector;
        selectors[1] = VaultHandler.swap.selector;
        selectors[2] = VaultHandler.warp.selector;
        selectors[3] = VaultHandler.release.selector;
        selectors[4] = VaultHandler.deposit.selector;
        selectors[5] = VaultHandler.withdraw.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// C_a == vault's actual ERC-6909 balance (no phantom or missing claims).
    function invariant_backingEqualsRealClaims() public view {
        assertEq(vault.backing(c0), _claims(address(vault), c0));
        assertEq(vault.backing(c1), _claims(address(vault), c1));
    }

    /// C_a matches an independent ledger of deposits, withdrawals, inputs received and outputs paid.
    function invariant_ghostLedgerConservation() public view {
        assertEq(vault.backing(c0), handler.ghostBacking(c0));
        assertEq(vault.backing(c1), handler.ghostBacking(c1));
    }

    /// ΣQ_a == Σ over unreleased allocations of (maxOut - consumed), and ΣQ_a <= C_a.
    function invariant_reservedIsExactAndBacked() public view {
        uint256 sum0;
        uint256 sum1;
        uint256 n = handler.allocationCount();
        for (uint256 i; i < n; ++i) {
            ISharedCommitmentVault.Allocation memory a = vault.getAllocation(handler.allocationIds(i));
            assertLe(a.consumed, a.maxOut, "consumed > maxOut");
            if (a.released) continue;
            if (a.currencyOut == c0) sum0 += a.maxOut - a.consumed;
            else sum1 += a.maxOut - a.consumed;
        }
        assertEq(vault.reserved(c0), sum0, "reserved0");
        assertEq(vault.reserved(c1), sum1, "reserved1");
        assertEq(vault.curatorReserved(curator, c0), sum0, "curatorReserved0");
        assertEq(vault.curatorReserved(curator, c1), sum1, "curatorReserved1");
        assertLe(vault.reserved(c0), vault.backing(c0));
        assertLe(vault.reserved(c1), vault.backing(c1));
    }

    /// Hooks never retain claims; no operator rights over the vault; PoolManager holds the ERC-20 behind them.
    function invariant_custodyAndSolvency() public view {
        _assertAccountingConsistent();
    }

    /// @dev Logged (not asserted) per run; only the final run's log is printed by forge.
    function afterInvariant() public view {
        console2.log(
            "run allocations/swaps/releases:", handler.allocationsOk(), handler.swapsOk(), handler.releasesOk()
        );
    }

    /// @notice Guards against a vacuous campaign: a fixed handler sequence must actually allocate, swap
    ///         (both hooks), release and withdraw through the real PoolManager.
    function test_handler_makesProgress() public {
        handler.allocate(0, 10_000 ether, 1 days); // hookA, out token0
        handler.allocate(3, 10_000 ether, 1 days); // hookB, out token1
        handler.swap(0, 100 ether);
        handler.swap(1, 100 ether);
        assertEq(handler.allocationsOk(), 2);
        assertEq(handler.swapsOk(), 2);
        handler.warp(2 days);
        handler.release(0, false);
        assertEq(handler.releasesOk(), 1);
        handler.withdraw(true, 1 ether);
        invariant_backingEqualsRealClaims();
        invariant_ghostLedgerConservation();
        invariant_reservedIsExactAndBacked();
        invariant_custodyAndSolvency();
    }
}
