// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {ICuratorAuthorization} from "../../src/interfaces/ICuratorAuthorization.sol";
import {IBenchVault, IBenchHookA, IBenchHookB} from "./IBench.sol";
import {ProductionArtifacts} from "../utils/ProductionArtifacts.sol";
import {Mock1271Wallet} from "../utils/Mock1271Wallet.sol";

/// @title Production-artifact gas and size benchmark
/// @notice Measures size and gas on the bytecode that would be deployed, not on copies compiled for tests.
/// @dev Why this file avoids importing `src/SharedCommitmentVault.sol`. The vault may be compiled under its own
///      optimizer profile (`compilation_restrictions` in foundry.toml). solc compiles a file together with
///      everything it imports, so any test file that imports the vault is compiled, with its whole import graph
///      (PoolManager, hooks, routers), under the vault's profile. `deployCode("X.sol:X")` in such a file also resolves
///      to the artifact of that profile. Gas measured there would include a PoolManager and hooks built with the
///      vault's settings, which is not what runs on-chain.
///
///      This file imports only interfaces and v4-core, so it compiles under the default profile:
///        - PoolManager is `new PoolManager`, built with the default profile (optimizer_runs 44,444,444, via-IR),
///          the same settings pinned v4-core uses in its own foundry.toml;
///        - the hooks come from `deployCodeTo("HookX.sol:HookX")`, which resolves to their default-profile artifact;
///        - the vault comes from `vm.getCode("SharedCommitmentVault.sol:SharedCommitmentVault")`. When the vault has
///          its own profile there is exactly one vault artifact and it is the production one.
///      `test/bench/run.sh` checks the optimizer settings recorded in those artifacts and prints the results.
///
///      Scenarios mirror `test/utils/VaultTestBase.sol` (same amounts, prices and pool parameters) so the numbers
///      can be compared with `test/gas/*`. Each benchmark logs one `BENCH <label>: <gas>` line. Gas is the
///      gasleft() difference around one external call. Run with `--isolate` so each call is its own transaction and
///      storage starts cold, as it would on-chain; without `--isolate` the numbers are lower and not comparable.
contract ProductionArtifactGasTest is Test {
    uint160 internal constant HOOK_FLAGS =
        Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 internal constant PRICE_1_1_X96 = uint160(FixedPoint96.Q96);
    uint256 internal constant VAULT_FUNDING = 1_000_000 ether;
    uint256 internal constant T0 = 1_700_000_000;

    string internal constant VAULT_ARTIFACT = "SharedCommitmentVault.sol:SharedCommitmentVault";
    string internal constant HOOK_A_ARTIFACT = "HookA_DynamicFee.sol:HookA_DynamicFee";
    string internal constant HOOK_B_ARTIFACT = "HookB_BoundedImpact.sol:HookB_BoundedImpact";
    string internal constant LENS_ARTIFACT = "VaultLens.sol:VaultLens";

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    MockERC20 internal token0;
    MockERC20 internal token1;
    Currency internal c0;
    Currency internal c1;
    IBenchVault internal vault;
    ICuratorAuthorization internal auth;
    address internal hookA;
    address internal hookB;
    PoolKey internal keyA;
    PoolKey internal keyB;

    address internal owner = makeAddr("vaultOwner");
    address internal hookOwner = makeAddr("hookOwner");
    address internal curator = makeAddr("curator");
    address internal trader = makeAddr("trader");
    address internal lp0 = makeAddr("lp0");
    address internal lpA = makeAddr("lpA");
    uint256 internal nextNonce;

    function setUp() public {
        vm.warp(T0);
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);

        MockERC20 ta = new MockERC20("Stable A", "STA", 18);
        MockERC20 tb = new MockERC20("Stable B", "STB", 18);
        (token0, token1) = address(ta) < address(tb) ? (ta, tb) : (tb, ta);
        c0 = Currency.wrap(address(token0));
        c1 = Currency.wrap(address(token1));

        vault = IBenchVault(deployCode(VAULT_ARTIFACT, abi.encode(manager, owner, c0, c1)));
        auth = ICuratorAuthorization(deployCode(ProductionArtifacts.authModule(), abi.encode(vault)));
        hookA = _deployHook(HOOK_A_ARTIFACT, 0xA11CE);
        hookB = _deployHook(HOOK_B_ARTIFACT, 0xB0B);

        keyA = PoolKey(c0, c1, 3000, 60, IHooks(hookA));
        keyB = PoolKey(c0, c1, 500, 10, IHooks(hookB));
        manager.initialize(keyA, SQRT_PRICE_1_1);
        manager.initialize(keyB, SQRT_PRICE_1_1);

        vm.startPrank(hookOwner);
        IBenchHookA(hookA).configurePool(keyA, PRICE_1_1_X96, 500, 5000, 10_000 ether, 10_000 ether, 1 hours);
        IBenchHookB(hookB).configurePool(keyB, PRICE_1_1_X96, 1_000_000 ether, 20_000, 1 hours);
        vm.stopPrank();

        vm.startPrank(owner);
        vault.setAuthModule(address(auth));
        vault.setConsumer(hookA, true);
        vault.setConsumer(hookB, true);
        vault.setCurator(curator, true);
        vault.setSellFloor(c0, PRICE_1_1_X96);
        vault.setSellFloor(c1, PRICE_1_1_X96);
        vault.setCuratorCeiling(curator, c0, type(uint256).max);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        _openLimits(ISharedCommitmentVault.RiskScope.Vault, address(0));
        _openLimits(ISharedCommitmentVault.RiskScope.Hook, hookA);
        _openLimits(ISharedCommitmentVault.RiskScope.Hook, hookB);
        _openLimits(ISharedCommitmentVault.RiskScope.Curator, curator);
        vm.stopPrank();

        _approveAndFund(owner, address(vault), VAULT_FUNDING);
        vm.prank(owner);
        vault.initialDeposit(VAULT_FUNDING, VAULT_FUNDING, lp0);

        _approveAndFund(trader, address(swapRouter), 10_000_000 ether);
        _approveAndFund(lpA, address(vault), 10_000_000 ether);
    }

    // ------------------------------------------------------------------
    // Sizes and deployment
    // ------------------------------------------------------------------

    /// @notice Ties the deployed contracts to the artifacts `run.sh` inspects, and logs their sizes. Immutables do
    ///         not change code length, so equal lengths show the deployed code came from that artifact's build.
    function test_bench_sizes() public {
        address lens = deployCode(LENS_ARTIFACT);
        _logSize("SharedCommitmentVault", address(vault), VAULT_ARTIFACT);
        _logSize("HookA_DynamicFee", hookA, HOOK_A_ARTIFACT);
        _logSize("HookB_BoundedImpact", hookB, HOOK_B_ARTIFACT);
        _logSize("VaultLens", lens, LENS_ARTIFACT);
        _logSize("CuratorAuthorization", address(auth), ProductionArtifacts.authModule());
        console2.log("BENCH runtime PoolManager (default profile):", address(manager).code.length);
    }

    /// @notice CREATE gas for the vault's init code with constructor arguments: 32,000 + init-code word cost +
    ///         constructor execution + 200 gas per runtime byte. A deployment transaction also pays 21,000 and the
    ///         calldata cost of the init code, which is logged separately (16 gas per non-zero byte, 4 per zero byte).
    function test_bench_deployVault() public {
        bytes memory initCode = abi.encodePacked(vm.getCode(VAULT_ARTIFACT), abi.encode(manager, owner, c0, c1));
        address deployed;
        uint256 g = gasleft();
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        uint256 used = g - gasleft();
        require(deployed != address(0), "deploy failed");
        console2.log("BENCH deploy vault (CREATE):", used);
        console2.log("BENCH deploy vault init-code calldata:", _calldataGas(initCode));
        console2.log("BENCH deploy vault init-code bytes:", initCode.length);
    }

    /// @notice CREATE gas for VaultLens, which has no constructor arguments. Same accounting as the vault above.
    function test_bench_deployLens() public {
        bytes memory initCode = vm.getCode(LENS_ARTIFACT);
        address deployed;
        uint256 g = gasleft();
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        uint256 used = g - gasleft();
        require(deployed != address(0), "deploy failed");
        console2.log("BENCH deploy lens (CREATE):", used);
        console2.log("BENCH deploy lens init-code calldata:", _calldataGas(initCode));
    }

    // ------------------------------------------------------------------
    // LP paths
    // ------------------------------------------------------------------

    function test_bench_initialDeposit() public {
        IBenchVault v = IBenchVault(deployCode(VAULT_ARTIFACT, abi.encode(manager, owner, c0, c1)));
        _approveAndFund(owner, address(v), 1000 ether);
        vm.prank(owner);
        uint256 g = gasleft();
        v.initialDeposit(1000 ether, 1000 ether, lpA);
        console2.log("BENCH initialDeposit:", g - gasleft());
    }

    function test_bench_deposit_newLp() public {
        vm.prank(lpA);
        uint256 g = gasleft();
        vault.deposit(1000 ether, type(uint256).max, type(uint256).max, lpA);
        console2.log("BENCH deposit (new LP):", g - gasleft());
    }

    function test_bench_redeem_instant() public {
        vm.prank(lp0);
        uint256 g = gasleft();
        vault.redeem(1000 ether, 0, 0, lp0, false);
        console2.log("BENCH redeem instant:", g - gasleft());
    }

    function test_bench_redeem_queued() public {
        _allocate(curator, keyA, c1, uint128(VAULT_FUNDING)); // no free asset1 left, so the redemption queues
        vm.prank(lp0);
        uint256 g = gasleft();
        vault.redeem(1000 ether, 0, 0, lp0, true);
        console2.log("BENCH redeem queued:", g - gasleft());
    }

    function test_bench_processQueue_one() public {
        uint256 id = _allocate(curator, keyA, c1, uint128(VAULT_FUNDING));
        vm.prank(lp0);
        vault.redeem(1000 ether, 0, 0, lp0, true);
        vm.prank(owner);
        vault.release(id);
        uint256 g = gasleft();
        vault.processQueue(1);
        console2.log("BENCH processQueue(1):", g - gasleft());
    }

    function test_bench_claim() public {
        uint256 id = _allocate(curator, keyA, c1, uint128(VAULT_FUNDING));
        vm.prank(lp0);
        (,,, uint256 requestId) = vault.redeem(1000 ether, 0, 0, lp0, true);
        vm.prank(owner);
        vault.release(id);
        vault.processQueue(1);
        vm.prank(lp0);
        uint256 g = gasleft();
        vault.claim(requestId);
        console2.log("BENCH claim:", g - gasleft());
    }

    // ------------------------------------------------------------------
    // Allocation and swap paths
    // ------------------------------------------------------------------

    /// @notice First allocation in the vault: every aggregate slot it touches goes from zero to non-zero.
    function test_bench_allocate_first() public {
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, 100_000 ether);
        vm.prank(curator);
        uint256 g = gasleft();
        auth.activateDirect(req);
        console2.log("BENCH allocate (first in vault):", g - gasleft());
    }

    /// @notice Steady state: Q_a and the id counter are already non-zero; a curator that has not allocated before
    ///         still pays zero-to-non-zero writes for its own reserved total and nonce. This is the case the
    ///         Phase 1B-2A activation measurements used.
    function test_bench_allocate_steady() public {
        _allocate(curator, keyA, c1, 100_000 ether);
        address curator2 = makeAddr("curator2");
        vm.startPrank(owner);
        vault.setCurator(curator2, true);
        vault.setCuratorCeiling(curator2, c1, type(uint256).max);
        _openLimits(ISharedCommitmentVault.RiskScope.Curator, curator2);
        vm.stopPrank();
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyA, c1, 100_000 ether);
        vm.prank(curator2);
        uint256 g = gasleft();
        auth.activateDirect(req);
        console2.log("BENCH allocate (steady state, new curator):", g - gasleft());
    }

    /// @notice Signed activation by an EOA curator that has not allocated before, submitted by a relayer, in the same
    ///         storage state as `test_bench_allocate_steady`. The difference to that benchmark is the signature path:
    ///         calldata, EIP-712 hashing and ecrecover.
    function test_bench_activate_signedEoa() public {
        _allocate(curator, keyA, c1, 100_000 ether);
        (address curator2, uint256 key2) = makeAddrAndKey("curator2");
        _registerFresh(curator2);
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(curator2, keyA, c1, 100_000 ether);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key2, auth.hashAuthorization(a));
        bytes memory sig = abi.encodePacked(r, s, v);
        vm.prank(makeAddr("relayer"));
        uint256 g = gasleft();
        auth.activate(a, keyA, sig);
        console2.log("BENCH activate signed (EOA, steady state, new curator):", g - gasleft());
    }

    /// @notice Same as the EOA case, with an ERC-1271 wallet curator that approves the digest from storage (a cold
    ///         account, a cold slot read and the call overhead).
    function test_bench_activate_signed1271() public {
        _allocate(curator, keyA, c1, 100_000 ether);
        Mock1271Wallet w = new Mock1271Wallet();
        _registerFresh(address(w));
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(address(w), keyA, c1, 100_000 ether);
        w.approve(auth.hashAuthorization(a), true);
        vm.prank(makeAddr("relayer"));
        uint256 g = gasleft();
        auth.activate(a, keyA, "");
        console2.log("BENCH activate signed (ERC-1271, steady state, new curator):", g - gasleft());
    }

    /// @notice First invalidation in a word (zero to non-zero) and a second bit in the same word.
    function test_bench_invalidateNonces() public {
        vm.prank(curator);
        uint256 g = gasleft();
        auth.invalidateNonces(0, 1);
        console2.log("BENCH invalidateNonces (new word):", g - gasleft());
        vm.prank(curator);
        g = gasleft();
        auth.invalidateNonces(0, 2);
        console2.log("BENCH invalidateNonces (same word):", g - gasleft());
    }

    /// @notice Owner replaces the module (the old one retires); the guardian disables it.
    function test_bench_setAuthModule() public {
        address m2 = deployCode(ProductionArtifacts.authModule(), abi.encode(vault));
        vm.prank(owner);
        uint256 g = gasleft();
        vault.setAuthModule(m2);
        console2.log("BENCH setAuthModule (replace):", g - gasleft());
        address guardian = makeAddr("guardian");
        vm.prank(owner);
        vault.setGuardian(guardian);
        vm.prank(guardian);
        g = gasleft();
        vault.setAuthModule(address(0));
        console2.log("BENCH setAuthModule (guardian disable):", g - gasleft());
    }

    /// @notice CREATE gas for the module (constructor argument: the vault).
    function test_bench_deployAuthModule() public {
        bytes memory initCode = abi.encodePacked(vm.getCode(ProductionArtifacts.authModule()), abi.encode(vault));
        address deployed;
        uint256 g = gasleft();
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        uint256 used = g - gasleft();
        require(deployed != address(0), "deploy failed");
        console2.log("BENCH deploy auth module (CREATE):", used);
        console2.log("BENCH deploy auth module init-code calldata:", _calldataGas(initCode));
    }

    function test_bench_release_early() public {
        uint256 id = _allocate(curator, keyA, c1, 100_000 ether);
        vm.prank(owner);
        uint256 g = gasleft();
        vault.release(id);
        console2.log("BENCH release (owner, before expiry):", g - gasleft());
    }

    // ------------------------------------------------------------------
    // Curator lifecycle
    // ------------------------------------------------------------------

    /// @notice Owner freezes a curator that holds one live allocation. One storage write, independent of how many
    ///         allocations the curator has.
    function test_bench_freezeCurator() public {
        _allocate(curator, keyA, c1, 100_000 ether);
        vm.prank(owner);
        uint256 g = gasleft();
        vault.freezeCurator(curator);
        console2.log("BENCH freezeCurator:", g - gasleft());
    }

    function test_bench_unfreezeCurator() public {
        _allocate(curator, keyA, c1, 100_000 ether);
        vm.prank(owner);
        vault.freezeCurator(curator);
        vm.prank(owner);
        uint256 g = gasleft();
        vault.unfreezeCurator(curator);
        console2.log("BENCH unfreezeCurator:", g - gasleft());
    }

    /// @notice Revocation of a curator with ten live allocations: the cost does not depend on that number.
    function test_bench_revokeCurator() public {
        for (uint256 i; i < 10; ++i) {
            _allocate(curator, keyA, c1, 1000 ether);
        }
        vm.prank(owner);
        uint256 g = gasleft();
        vault.revokeCurator(curator);
        console2.log("BENCH revokeCurator (10 live allocations):", g - gasleft());
    }

    /// @notice Permissionless cleanup of one partially consumed allocation of a revoked curator, by a stranger.
    function test_bench_release_revokedCleanup() public {
        uint256 id = _allocate(curator, keyA, c1, 100_000 ether);
        _swap(keyA, true, -1000 ether, abi.encode(id));
        vm.prank(owner);
        vault.revokeCurator(curator);
        vm.prank(trader);
        uint256 g = gasleft();
        vault.release(id);
        console2.log("BENCH release (revoked curator, stranger, per allocation):", g - gasleft());
    }

    /// @notice The curator cancels its own partially consumed allocation.
    function test_bench_cancelAllocation() public {
        uint256 id = _allocate(curator, keyA, c1, 100_000 ether);
        _swap(keyA, true, -1000 ether, abi.encode(id));
        vm.prank(curator);
        uint256 g = gasleft();
        vault.cancelAllocation(id);
        console2.log("BENCH cancelAllocation (after partial consumption):", g - gasleft());
    }

    /// @notice Router + PoolManager + HookA + vault `exchange`, 1,000 tokens exact input, asset0 -> asset1.
    function test_bench_swap_hookA() public {
        uint256 id = _allocate(curator, keyA, c1, 100_000 ether);
        uint256 g = gasleft();
        _swap(keyA, true, -1000 ether, abi.encode(id));
        console2.log("BENCH swap hookA (router+PM+hook+vault):", g - gasleft());
    }

    /// @notice Second HookA swap in the same flow window: the three flow records already hold this window's usage,
    ///         so each update is a non-zero to non-zero write with no window change. With --isolate every call is
    ///         its own transaction, so the slots are cold again, as for a later swap on-chain.
    function test_bench_swap_hookA_sameWindow() public {
        uint256 id = _allocate(curator, keyA, c1, 100_000 ether);
        _swap(keyA, true, -1000 ether, abi.encode(id));
        uint256 g = gasleft();
        _swap(keyA, true, -1000 ether, abi.encode(id));
        console2.log("BENCH swap hookA, same flow window:", g - gasleft());
    }

    /// @notice First HookA swap after the flow window rolled over: the stored usage belongs to an earlier window,
    ///         so each record restarts from this swap's output (same storage cost as any other update).
    function test_bench_swap_hookA_newWindow() public {
        uint256 id = _allocate(curator, keyA, c1, 100_000 ether);
        _swap(keyA, true, -1000 ether, abi.encode(id));
        vm.warp((block.timestamp / 1 days + 1) * 1 days); // first second of the next window, before expiry
        uint256 g = gasleft();
        _swap(keyA, true, -1000 ether, abi.encode(id));
        console2.log("BENCH swap hookA, first in a new flow window:", g - gasleft());
    }

    /// @notice Configuring a record for the first time (both slots zero to non-zero), and changing one that is
    ///         already configured.
    function test_bench_setRiskLimit() public {
        address fresh = makeAddr("freshCurator");
        vm.prank(owner);
        uint256 g = gasleft();
        vault.setRiskLimit(ISharedCommitmentVault.RiskScope.Curator, fresh, c1, 500_000 ether, 5000);
        console2.log("BENCH setRiskLimit (configure new record):", g - gasleft());
        vm.prank(owner);
        g = gasleft();
        vault.setRiskLimit(ISharedCommitmentVault.RiskScope.Curator, fresh, c1, 400_000 ether, 4000);
        console2.log("BENCH setRiskLimit (change configured record):", g - gasleft());
    }

    /// @notice Router + PoolManager + HookB + vault `exchange`, 1,000 tokens exact input, asset1 -> asset0.
    function test_bench_swap_hookB() public {
        uint256 id = _allocate(curator, keyB, c0, 100_000 ether);
        uint256 g = gasleft();
        _swap(keyB, false, -1000 ether, abi.encode(id));
        console2.log("BENCH swap hookB (router+PM+hook+vault):", g - gasleft());
    }

    // ------------------------------------------------------------------
    // Cumulative pricing: directions, steady state, splitting, failures, quotes
    // ------------------------------------------------------------------

    /// @notice HookA selling asset1 and HookB selling asset0: the other direction of each hook's first swap.
    function test_bench_swap_otherDirections() public {
        uint256 idA = _allocate(curator, keyA, c0, 100_000 ether);
        uint256 idB = _allocate(curator, keyB, c1, 100_000 ether);
        uint256 g = gasleft();
        _swap(keyA, false, -1000 ether, abi.encode(idA));
        console2.log("BENCH swap hookA asset1 -> asset0 (first in direction):", g - gasleft());
        g = gasleft();
        _swap(keyB, true, -1000 ether, abi.encode(idB));
        console2.log("BENCH swap hookB asset0 -> asset1 (first on pool):", g - gasleft());
    }

    /// @notice Second swap in the same direction one minute later: the pricing slot already holds a non-zero state and
    ///         decay is applied (non-zero to non-zero write), as for most swaps on a live pool.
    function test_bench_swap_steadyState() public {
        uint256 idA = _allocate(curator, keyA, c1, 100_000 ether);
        uint256 idB = _allocate(curator, keyB, c0, 100_000 ether);
        _swap(keyA, true, -1000 ether, abi.encode(idA));
        _swap(keyB, false, -1000 ether, abi.encode(idB));
        vm.warp(vm.getBlockTimestamp() + 60);
        uint256 g = gasleft();
        _swap(keyA, true, -1000 ether, abi.encode(idA));
        console2.log("BENCH swap hookA, second in direction after 60 s:", g - gasleft());
        g = gasleft();
        _swap(keyB, false, -1000 ether, abi.encode(idB));
        console2.log("BENCH swap hookB, second on pool after 60 s:", g - gasleft());
    }

    /// @notice What a splitter pays: one swap of 1,000 against ten separate swaps of 100 (each its own transaction
    ///         under --isolate). The pricing gives the split no discount, so all of the difference is overhead.
    function test_bench_split_tenPieces() public {
        for (uint256 h; h < 2; ++h) {
            PoolKey memory key = h == 0 ? keyA : keyB;
            uint256 id = _allocate(curator, key, c1, 100_000 ether);
            uint256 snap = vm.snapshotState();
            uint256 g = gasleft();
            _swap(key, true, -1000 ether, abi.encode(id));
            uint256 one = g - gasleft();
            vm.revertToState(snap);
            g = gasleft();
            for (uint256 i; i < 10; ++i) {
                _swap(key, true, -100 ether, abi.encode(id));
            }
            uint256 ten = g - gasleft();
            console2.log(h == 0 ? "BENCH split hookA, 1 x 1,000:" : "BENCH split hookB, 1 x 1,000:", one);
            console2.log(h == 0 ? "BENCH split hookA, 10 x 100:" : "BENCH split hookB, 10 x 100:", ten);
        }
    }

    /// @notice Gas burned by refused swaps, measured to the revert: Hook B's cap (refused in the hook before any
    ///         vault call), the hookData minimum (refused after pricing, before minting), and the vault floor
    ///         (refused inside `exchange`, after the hook has minted the input claims).
    function test_bench_failureCosts() public {
        uint256 idB = _allocate(curator, keyB, c1, 100_000 ether);
        uint256 idA = _allocate(curator, keyA, c1, 100_000 ether);
        uint256 g = gasleft();
        try this.swapExternal(keyB, true, -20_000 ether, abi.encode(idB)) {} catch {}
        console2.log("BENCH failed swap: hookB cap:", g - gasleft());
        g = gasleft();
        try this.swapExternal(keyA, true, -1000 ether, abi.encode(idA, uint256(1000 ether))) {} catch {}
        console2.log("BENCH failed swap: hookData minimum:", g - gasleft());
        vm.prank(hookOwner);
        IBenchHookA(hookA).configurePool(keyA, PRICE_1_1_X96 * 2, 500, 5000, 10_000 ether, 10_000 ether, 1 hours);
        g = gasleft();
        try this.swapExternal(keyA, true, -1000 ether, abi.encode(idA)) {} catch {}
        console2.log("BENCH failed swap: vault floor:", g - gasleft());
    }

    /// @notice The hooks' quote views (what a router calls to set a minimum output).
    function test_bench_quotes() public {
        uint256 g = gasleft();
        IBenchHookA(hookA).quote(keyA, true, 1000 ether);
        console2.log("BENCH quote hookA:", g - gasleft());
        g = gasleft();
        IBenchHookB(hookB).quote(keyB, true, 1000 ether);
        console2.log("BENCH quote hookB (asset0 in, inverse):", g - gasleft());
        g = gasleft();
        IBenchHookB(hookB).quote(keyB, false, 1000 ether);
        console2.log("BENCH quote hookB (asset1 in):", g - gasleft());
    }

    /// @dev External so that a refused swap can be measured with try/catch.
    function swapExternal(PoolKey memory key, bool zeroForOne, int256 amountSpecified, bytes memory hookData) external {
        _swap(key, zeroForOne, amountSpecified, hookData);
    }

    /// @notice Reference with no vault code at all: same router and amount on a hookless concentrated-liquidity
    ///         pool. Any change in this number between two runs comes from the PoolManager or router build, not
    ///         from the vault, which makes it a control for the swap benchmarks above.
    function test_bench_swap_nativeV4() public {
        PoolKey memory plain = PoolKey(c0, c1, 3000, 60, IHooks(address(0)));
        manager.initialize(plain, SQRT_PRICE_1_1);
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(manager);
        token0.mint(address(this), 10_000_000 ether);
        token1.mint(address(this), 10_000_000 ether);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(plain, ModifyLiquidityParams(-6000, 6000, 1_000_000 ether, 0), "");
        uint256 g = gasleft();
        _swap(plain, true, -1000 ether, "");
        console2.log("BENCH swap native v4 (router+PM):", g - gasleft());
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _deployHook(string memory artifact, uint256 salt) internal returns (address hook) {
        hook = address(uint160(salt << 140) | HOOK_FLAGS);
        deployCodeTo(artifact, abi.encode(manager, vault, hookOwner), hook);
    }

    function _approveAndFund(address who, address spender, uint256 amount) internal {
        token0.mint(who, amount);
        token1.mint(who, amount);
        vm.startPrank(who);
        token0.approve(spender, type(uint256).max);
        token1.approve(spender, type(uint256).max);
        vm.stopPrank();
    }

    function _request(PoolKey memory key, Currency out, uint128 maxOut)
        internal
        returns (ISharedCommitmentVault.AllocationRequest memory req)
    {
        req = ISharedCommitmentVault.AllocationRequest({
            consumer: address(key.hooks),
            key: key,
            currencyOut: out,
            maxOut: maxOut,
            minInPerOutX96: PRICE_1_1_X96,
            expiry: uint64(block.timestamp + 1 days),
            nonce: nextNonce++,
            deadline: uint64(block.timestamp + 1 hours)
        });
    }

    function _allocate(address who, PoolKey memory key, Currency out, uint128 maxOut) internal returns (uint256) {
        ISharedCommitmentVault.AllocationRequest memory req = _request(key, out, maxOut);
        vm.prank(who);
        return auth.activateDirect(req);
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, bytes memory hookData) internal {
        vm.prank(trader);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    function _logSize(string memory name, address deployed, string memory artifact) internal view {
        uint256 runtime = deployed.code.length;
        assertEq(
            runtime, vm.getDeployedCode(artifact).length, string.concat(name, ": deployed code is not the artifact")
        );
        console2.log(string.concat("BENCH runtime ", name, ":"), runtime);
        console2.log(string.concat("BENCH initcode ", name, ":"), vm.getCode(artifact).length);
    }

    /// @dev EIP-2028 calldata cost: 16 gas per non-zero byte, 4 per zero byte.
    function _calldataGas(bytes memory data) internal pure returns (uint256 gas) {
        for (uint256 i; i < data.length; ++i) {
            gas += data[i] == 0 ? 4 : 16;
        }
    }

    /// @dev Configures `account` at `scope` in both assets with the widest limits (largest flow cap, 100% exposure).
    ///      Caller must already be pranking as the owner.
    function _registerFresh(address c) internal {
        vm.startPrank(owner);
        vault.setCurator(c, true);
        vault.setCuratorCeiling(c, c1, type(uint256).max);
        _openLimits(ISharedCommitmentVault.RiskScope.Curator, c);
        vm.stopPrank();
    }

    function _authz(address cur, PoolKey memory key, Currency out, uint128 maxOut)
        internal
        returns (ICuratorAuthorization.AllocationAuthorization memory)
    {
        return ICuratorAuthorization.AllocationAuthorization({
            curator: cur,
            generation: vault.getCurator(cur).generation,
            vault: address(vault),
            poolId: key.toId(),
            hook: address(key.hooks),
            currencyIn: out == key.currency1 ? key.currency0 : key.currency1,
            currencyOut: out,
            zeroForOne: out == key.currency1,
            maxOut: maxOut,
            minInPerOutX96: PRICE_1_1_X96,
            expiry: uint64(block.timestamp + 1 days),
            validAfter: uint64(block.timestamp),
            deadline: uint64(block.timestamp + 1 hours),
            nonce: nextNonce++
        });
    }

    function _openLimits(ISharedCommitmentVault.RiskScope scope, address account) internal {
        vault.setRiskLimit(scope, account, c0, type(uint104).max, 10_000);
        vault.setRiskLimit(scope, account, c1, type(uint104).max, 10_000);
    }
}
