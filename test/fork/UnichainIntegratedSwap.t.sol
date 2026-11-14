// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {CuratorAuthorization} from "../../src/CuratorAuthorization.sol";
import {HookA_DynamicFee} from "../../src/hooks/HookA_DynamicFee.sol";
import {HookB_BoundedImpact} from "../../src/hooks/HookB_BoundedImpact.sol";
import {BaseCompatibleHook} from "../../src/hooks/BaseCompatibleHook.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {IVaultState} from "../../src/interfaces/IVaultState.sol";
import {IMarketRiskAdapter} from "../../src/interfaces/IMarketRiskAdapter.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {PriceRiskAdapter} from "../../src/oracle/PriceRiskAdapter.sol";
import {ProductionArtifacts} from "../utils/ProductionArtifacts.sol";
import {VaultStateReader} from "../../src/libraries/VaultStateReader.sol";

using VaultStateReader for SharedCommitmentVault;

/// @notice The integrated system on a read-only Unichain mainnet fork: the production builds of the vault, both hooks
///         and the authorization module on Unichain's own v4 PoolManager, priced by `PriceRiskAdapter` over the live
///         Chainlink and RedStone WETH/USDC feeds. Measures real swap gas (replacing the Phase 1B-4.2 estimate) and
///         checks that real-feed quotes clear the vault's own floor. Skipped without UNICHAIN_RPC_URL. Run with
///         `--isolate` for cold, per-transaction gas, as test/bench/ does.
/// @dev Balances come from `deal` on the local fork; nothing is broadcast.
contract UnichainIntegratedSwapForkTest is Test {
    address internal constant POOL_MANAGER = 0x1F98400000000000000000000000000000000004;
    address internal constant USDC = 0x078D782b760474a361dDA0AF3839290b0EF57AD6; // currency0 (lower address)
    address internal constant WETH = 0x4200000000000000000000000000000000000006; // currency1
    address internal constant CL_ETH_USD = 0xBcE70e194940a157f3A80566505a7E96f5238CCa;
    address internal constant CL_USDC_USD = 0xbd1cD1518eFB92a92100da62D4C488c810dFd75b;
    address internal constant CL_SEQUENCER = 0x495639D9914e7D270c5dCC641BfB1d807423F813;
    address internal constant RS_ETH = 0xe8D9FbC10e00ecc9f0694617075fDAF657a76FB2;
    address internal constant RS_USDC = 0xD15862FC3D5407A03B696548b6902D6464A69b8c;
    uint160 internal constant HOOK_FLAGS =
        Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG;

    bool internal live;
    IPoolManager internal manager;
    SharedCommitmentVault internal vault;
    CuratorAuthorization internal auth;
    HookA_DynamicFee internal hookA;
    HookB_BoundedImpact internal hookB;
    PriceRiskAdapter internal adapter;
    PoolSwapTest internal router;
    PoolKey internal keyA;
    PoolKey internal keyB;
    address internal owner = makeAddr("owner");
    address internal curator = makeAddr("curator");
    address internal trader = makeAddr("trader");
    uint256 internal nonce;

    function setUp() public {
        string memory rpc = vm.envOr("UNICHAIN_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        // UNICHAIN_FORK_BLOCK pins the fork so that gas measured before and after a change is comparable.
        uint256 forkBlock = vm.envOr("UNICHAIN_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        live = true;
        manager = IPoolManager(POOL_MANAGER);
        Currency c0 = Currency.wrap(USDC);
        Currency c1 = Currency.wrap(WETH);

        adapter = new PriceRiskAdapter(
            PriceRiskAdapter.Source(
                IAggregatorV3(CL_USDC_USD), IAggregatorV3(CL_ETH_USD), 3100, 5100, 88_200, 88_200, 0, 0, 0
            ),
            PriceRiskAdapter.Source(IAggregatorV3(RS_USDC), IAggregatorV3(RS_ETH), 5100, 5100, 12_600, 23_400, 0, 0, 0),
            USDC,
            WETH,
            6,
            18,
            IAggregatorV3(CL_SEQUENCER),
            3600,
            2
        );
        IMarketRiskAdapter.Reading memory r = adapter.currentReference();

        vault = SharedCommitmentVault(deployCode(ProductionArtifacts.VAULT, abi.encode(manager, owner, c0, c1)));
        auth =
            CuratorAuthorization(deployCode(ProductionArtifacts.authModule(), abi.encode(IVaultState(address(vault)))));
        address a = address(uint160(uint256(0xA11CE) << 140) | HOOK_FLAGS);
        address b = address(uint160(uint256(0xB0B) << 140) | HOOK_FLAGS);
        deployCodeTo(ProductionArtifacts.HOOK_A, abi.encode(manager, vault, owner), a);
        deployCodeTo(ProductionArtifacts.HOOK_B, abi.encode(manager, vault, owner), b);
        hookA = HookA_DynamicFee(a);
        hookB = HookB_BoundedImpact(b);
        keyA = PoolKey(c0, c1, 3000, 60, IHooks(a));
        keyB = PoolKey(c0, c1, 500, 10, IHooks(b));
        manager.initialize(keyA, TickMath.getSqrtPriceAtTick(200_040));
        manager.initialize(keyB, TickMath.getSqrtPriceAtTick(200_040));
        router = new PoolSwapTest(manager);

        // Seed 1,000,000 USDC and the WETH worth the same at the adapter's mid.
        uint256 usdc = 1_000_000e6;
        uint256 weth = FullMath.mulDiv(usdc, r.priceX96, 2 ** 96);
        deal(USDC, owner, usdc);
        deal(WETH, owner, weth);
        vm.startPrank(owner);
        IERC20(USDC).approve(address(vault), type(uint256).max);
        IERC20(WETH).approve(address(vault), type(uint256).max);
        vault.setAuthModule(address(auth));
        vault.setConsumer(a, true);
        vault.setConsumer(b, true);
        vault.setCurator(curator, true);
        vault.setCuratorCeiling(curator, c0, type(uint256).max);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        _open(ISharedCommitmentVault.RiskScope.Vault, address(0));
        _open(ISharedCommitmentVault.RiskScope.Hook, a);
        _open(ISharedCommitmentVault.RiskScope.Hook, b);
        _open(ISharedCommitmentVault.RiskScope.Curator, curator);
        vault.initialDeposit(usdc, weth, owner);
        uint256 s = vault.totalShares();
        uint256 tau0 = FullMath.mulDiv(usdc, 1e18, s);
        uint256 tau1 = FullMath.mulDiv(weth, 1e18, s);
        vault.setRiskBounds(100, 12_000); // edge 1 bp; accept up to 120 bps (measured band ~82 bps)
        vault.setInventoryBounds(tau0, tau1, 20_000, 20_000); // kappa 2%
        vault.setRiskAdapter(adapter);
        // Hook A static-mode price = the adapter's mid (used only in the static comparison below).
        hookA.configurePool(keyA, uint160(r.priceX96), 500, 5000, 10_000e6, 5 ether, 1 hours);
        BaseCompatibleHook.CoreParams memory p = BaseCompatibleHook.CoreParams({
            depthPerShare: uint128(tau1 * 10),
            depthMax: uint128(2 ** 95 - 1),
            baseSpreadPips: 3000,
            minEdgePips: 200,
            maxSpreadPips: 40_000,
            maxDeviationPips: 20_000
        });
        hookA.configureCore(keyA, p);
        hookB.configureCore(keyB, p);
        hookB.configureStrategy(keyB, 1000, 20_000);
        vm.stopPrank();

        deal(USDC, trader, 1_000_000e6);
        deal(WETH, trader, 1000 ether);
        vm.startPrank(trader);
        IERC20(USDC).approve(address(router), type(uint256).max);
        IERC20(WETH).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _open(ISharedCommitmentVault.RiskScope scope, address account) internal {
        vault.setRiskLimit(scope, account, Currency.wrap(USDC), type(uint104).max, 10_000);
        vault.setRiskLimit(scope, account, Currency.wrap(WETH), type(uint104).max, 10_000);
    }

    function _allocate(PoolKey memory key, bool zeroForOne) internal returns (uint256 id) {
        return _allocate(key, zeroForOne, 1);
    }

    /// @dev Reserves a tenth of the output asset's backing for `key` at curator floor `floor`.
    function _allocate(PoolKey memory key, bool zeroForOne, uint160 floor) internal returns (uint256 id) {
        Currency out = zeroForOne ? Currency.wrap(WETH) : Currency.wrap(USDC);
        ISharedCommitmentVault.AllocationRequest memory req = ISharedCommitmentVault.AllocationRequest({
            consumer: address(key.hooks),
            key: key,
            currencyOut: out,
            maxOut: uint128(vault.backing(out) / 10),
            minInPerOutX96: floor,
            expiry: uint64(block.timestamp + 1 days),
            nonce: nonce++,
            deadline: uint64(block.timestamp + 1 hours)
        });
        vm.prank(curator);
        id = auth.activateDirect(req);
    }

    function _swapGas(PoolKey memory key, bool zeroForOne, uint256 amountIn, uint256 id) internal returns (uint256 g) {
        vm.prank(trader);
        g = gasleft();
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(id)
        );
        g -= gasleft();
    }

    /// @notice Shared-core swaps on real feeds: both hooks, both directions. Each quote clears the vault's floor
    ///         (the swap succeeds) and lies outside the live band.
    function test_fork_sharedCoreSwapGas() public {
        if (!live) vm.skip(true);
        uint256 idB0 = _allocate(keyB, true);
        uint256 idB1 = _allocate(keyB, false);
        uint256 idA0 = _allocate(keyA, true);
        uint256 idA1 = _allocate(keyA, false);
        IMarketRiskAdapter.Reading memory r = adapter.currentReference();
        console2.log("adapter uncertainty, pips:", r.uncertaintyPips);
        console2.log("FORK swap hookB shared core, 1,000 USDC -> WETH:", _swapGas(keyB, true, 1000e6, idB0));
        console2.log("FORK swap hookB shared core, 0.5 WETH -> USDC:", _swapGas(keyB, false, 0.5 ether, idB1));
        console2.log("FORK swap hookA shared core, 1,000 USDC -> WETH:", _swapGas(keyA, true, 1000e6, idA0));
        console2.log("FORK swap hookA shared core, 0.5 WETH -> USDC:", _swapGas(keyA, false, 0.5 ether, idA1));
    }

    /// @notice The same Hook A swap in static mode on the same fork (adapter removed, a stored floor below the mid):
    ///         the like-for-like baseline for the shared-core cost.
    function test_fork_staticModeSwapGas() public {
        if (!live) vm.skip(true);
        IMarketRiskAdapter.Reading memory r = adapter.currentReference();
        vm.startPrank(owner);
        vault.setRiskAdapter(IMarketRiskAdapter(address(0)));
        // Only the measured direction (vault sells WETH) is opened, 2% below the mid; with one floor set there is no
        // directional pair to check, and the other direction stays closed, as static mode requires.
        vault.setSellFloor(
            Currency.wrap(WETH), uint160(FullMath.mulDiv(FullMath.mulDiv(2 ** 96, 2 ** 96, r.priceX96), 98, 100))
        );
        vm.stopPrank();
        (uint160 floor,) = vault.sellPolicy(Currency.wrap(WETH));
        uint256 id = _allocate(keyA, true, floor);
        console2.log("FORK swap hookA static mode, 1,000 USDC -> WETH:", _swapGas(keyA, true, 1000e6, id));
    }

    /// @notice Real-feed shared-core quotes, both hooks, both directions, priced beyond the band: the effective price
    ///         is worse for the trader than the mid by more than the live uncertainty.
    function test_fork_quotesBeyondBand() public {
        if (!live) vm.skip(true);
        IMarketRiskAdapter.Reading memory r = adapter.currentReference();
        uint256 midOut = FullMath.mulDiv(1000e6, r.priceX96, 2 ** 96); // WETH for 1,000 USDC at the mid
        uint256 qB = hookB.quote(keyB, true, 1000e6);
        uint256 qA = hookA.quote(keyA, true, 1000e6);
        assertLt(qB * 1e6, midOut * (1e6 - r.uncertaintyPips), "Hook B beyond the band");
        assertLt(qA * 1e6, midOut * (1e6 - r.uncertaintyPips), "Hook A beyond the band");
        console2.log("mid WETH out for 1,000 USDC:", midOut);
        console2.log("Hook B quote:", qB);
        console2.log("Hook A quote:", qA);
    }
}
