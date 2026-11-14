// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {SharedCommitmentVault} from "../src/SharedCommitmentVault.sol";
import {ISharedCommitmentVault} from "../src/interfaces/ISharedCommitmentVault.sol";
import {ICuratorAuthorization} from "../src/interfaces/ICuratorAuthorization.sol";
import {CuratorAuthorization} from "../src/CuratorAuthorization.sol";
import {VaultGovernor} from "../src/governance/VaultGovernor.sol";
import {DeploySystem} from "./DeploySystem.s.sol";
import {VaultStateReader} from "../src/libraries/VaultStateReader.sol";

using VaultStateReader for SharedCommitmentVault;

/// @title Rehearse
/// @notice Stage 3 of the Unichain Sepolia rehearsal: the life cycle on the deployed system, one role per stage. TEST
///         tokens only. Each stage broadcasts with the key of its role, read from the environment at run time (ephemeral
///         test keys only; never a key holding value):
///           router      DEPLOYER_KEY  deploys a PoolSwapTest router (labelled test router)
///           lp          LP_KEY        deposits, then redeems part instantly
///           activate    CURATOR_KEY   signs an EIP-712 allocation for Hook A (submitted by TRADER_KEY) and activates
///                                     one for Hook B directly
///           swap        TRADER_KEY    swaps through both hooks against ALLOCATION_A / ALLOCATION_B
///           exit        LP_KEY        redeems with queueing, processes the queue, claims what was finalized
///           emergency   GUARDIAN_KEY  pauses, halts a direction, freezes the curator; then GOV_ADMIN_KEY queues the
///                                     three recoveries and a loosening, and the guardian cancels the loosening
///           recover     GOV_ADMIN_KEY executes the three recoveries after DELAY
///         Usage: `forge script script/Rehearse.s.sol --sig "run(string)" <stage> --rpc-url $SEPOLIA_RPC [--broadcast]`.
///         Without `--broadcast` forge only simulates. Broadcasting needs explicit owner approval.
contract Rehearse is Script {
    DeploySystem internal ds;

    function run(string memory stage) external {
        if (block.chainid != 1301 && block.chainid != 31_337) revert("Rehearse: Sepolia or local only");
        ds = new DeploySystem();
        DeploySystem.Deployment memory d = ds.deploymentFromEnv();
        bytes32 s = keccak256(bytes(stage));
        if (s == keccak256("router")) return _router();
        if (s == keccak256("lp")) return _lp(d);
        if (s == keccak256("activate")) return _activate(d);
        if (s == keccak256("swap")) return _swapBoth(d);
        if (s == keccak256("exit")) return _exit(d);
        if (s == keccak256("emergency")) return _emergency(d);
        if (s == keccak256("recover")) return _recover(d);
        revert("Rehearse: unknown stage");
    }

    // ------------------------------------------------------------------ stages

    function _router() internal {
        vm.startBroadcast(vm.envUint("DEPLOYER_KEY"));
        PoolSwapTest r = new PoolSwapTest(IPoolManager(vm.envAddress("POOL_MANAGER")));
        vm.stopBroadcast();
        console2.log("TEST router", address(r));
    }

    function _lp(DeploySystem.Deployment memory d) internal {
        SharedCommitmentVault v = SharedCommitmentVault(d.vault);
        uint256 key = vm.envUint("LP_KEY");
        address lp = vm.addr(key);
        uint256 shares = v.totalShares() / 10;
        vm.startBroadcast(key);
        MockERC20(d.token0).mint(lp, 1e30);
        MockERC20(d.token1).mint(lp, 1e30);
        MockERC20(d.token0).approve(d.vault, type(uint256).max);
        MockERC20(d.token1).approve(d.vault, type(uint256).max);
        v.deposit(shares, type(uint256).max, type(uint256).max, lp);
        (uint256 inst,,,) = v.redeem(shares / 4, 0, 0, lp, false);
        vm.stopBroadcast();
        console2.log("LP deposited / redeemed instantly (shares)", shares, inst);
    }

    function _activate(DeploySystem.Deployment memory d) internal {
        uint256 curatorKey = vm.envUint("CURATOR_KEY");
        address curatorAddr = vm.addr(curatorKey);
        SharedCommitmentVault v = SharedCommitmentVault(d.vault);
        PoolKey memory kA = ds.keyA(d);
        ICuratorAuthorization.AllocationAuthorization memory a = ICuratorAuthorization.AllocationAuthorization({
            curator: curatorAddr,
            generation: v.getCurator(curatorAddr).generation,
            vault: d.vault,
            poolId: kA.toId(),
            hook: d.hookA,
            currencyIn: Currency.wrap(d.token0),
            currencyOut: Currency.wrap(d.token1),
            zeroForOne: true,
            maxOut: uint128(v.backing(Currency.wrap(d.token1)) / 50),
            minInPerOutX96: 1,
            expiry: uint64(block.timestamp + 1 days),
            validAfter: uint64(block.timestamp),
            deadline: uint64(block.timestamp + 1 hours),
            nonce: uint256(keccak256(abi.encode("rehearsal-signed", block.timestamp)))
        });
        (uint8 sv, bytes32 r, bytes32 s) = vm.sign(curatorKey, CuratorAuthorization(d.auth).hashAuthorization(a));
        vm.startBroadcast(vm.envUint("TRADER_KEY")); // anyone may submit a curator's signed instruction
        uint256 idA = CuratorAuthorization(d.auth).activate(a, kA, abi.encodePacked(r, s, sv));
        vm.stopBroadcast();

        ISharedCommitmentVault.AllocationRequest memory req = ISharedCommitmentVault.AllocationRequest({
            consumer: d.hookB,
            key: ds.keyB(d),
            currencyOut: Currency.wrap(d.token1),
            maxOut: uint128(v.backing(Currency.wrap(d.token1)) / 50),
            minInPerOutX96: 1,
            expiry: uint64(block.timestamp + 1 days),
            nonce: uint256(keccak256(abi.encode("rehearsal-direct", block.timestamp))),
            deadline: uint64(block.timestamp + 1 hours)
        });
        vm.startBroadcast(curatorKey);
        uint256 idB = CuratorAuthorization(d.auth).activateDirect(req);
        vm.stopBroadcast();
        console2.log("ALLOCATION_A (signed) / ALLOCATION_B (direct)", idA, idB);
    }

    function _swapBoth(DeploySystem.Deployment memory d) internal {
        uint256 key = vm.envUint("TRADER_KEY");
        PoolSwapTest router = PoolSwapTest(vm.envAddress("ROUTER"));
        vm.startBroadcast(key);
        MockERC20(d.token0).mint(vm.addr(key), 1e24);
        MockERC20(d.token0).approve(address(router), type(uint256).max);
        uint256 outA = _swap(router, ds.keyA(d), 100 ether, vm.envUint("ALLOCATION_A"));
        uint256 outB = _swap(router, ds.keyB(d), 100 ether, vm.envUint("ALLOCATION_B"));
        vm.stopBroadcast();
        require(outA != 0 && outB != 0, "Rehearse: a swap paid nothing");
        console2.log("swap outputs for 100 TEST token0: hook A / hook B", outA, outB);
    }

    function _swap(PoolSwapTest router, PoolKey memory key, uint256 amountIn, uint256 allocationId)
        internal
        returns (uint256)
    {
        BalanceDelta delta = router.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(allocationId)
        );
        return uint256(int256(delta.amount1()));
    }

    function _exit(DeploySystem.Deployment memory d) internal {
        SharedCommitmentVault v = SharedCommitmentVault(d.vault);
        uint256 key = vm.envUint("LP_KEY");
        address lp = vm.addr(key);
        vm.startBroadcast(key);
        (uint256 inst,,, uint256 rid) = v.redeem(v.sharesOf(lp), 0, 0, lp, true);
        if (rid != 0) {
            v.processQueue(8);
            ISharedCommitmentVault.WithdrawalRequest memory w = v.getRequest(rid);
            if (w.claimable0 != 0 || w.claimable1 != 0) v.claim(rid);
        }
        vm.stopBroadcast();
        console2.log("LP exit: instant shares / request id", inst, rid);
    }

    /// @dev The guardian acts immediately; the admin can only queue the way back.
    function _emergency(DeploySystem.Deployment memory d) internal {
        SharedCommitmentVault v = SharedCommitmentVault(d.vault);
        address curatorAddr = vm.envAddress("CURATOR");
        vm.startBroadcast(vm.envUint("GUARDIAN_KEY"));
        v.setPaused(true);
        v.setSellHalted(v.asset1(), true);
        v.freezeCurator(curatorAddr);
        vm.stopBroadcast();

        bytes[] memory back = recoveryCalls(v, curatorAddr);
        bytes memory loosen = abi.encodeCall(v.setRiskBounds, (0, v.maxUncertaintyPips()));
        vm.startBroadcast(vm.envUint("GOV_ADMIN_KEY"));
        for (uint256 i; i < back.length; ++i) {
            VaultGovernor(d.governor).queue(d.vault, back[i]);
        }
        VaultGovernor(d.governor).queue(d.vault, loosen);
        vm.stopBroadcast();
        vm.startBroadcast(vm.envUint("GUARDIAN_KEY"));
        VaultGovernor(d.governor).cancel(d.vault, loosen);
        vm.stopBroadcast();
        console2.log("emergency applied; recoveries queued; loosening canceled by the guardian");
    }

    function _recover(DeploySystem.Deployment memory d) internal {
        SharedCommitmentVault v = SharedCommitmentVault(d.vault);
        bytes[] memory back = recoveryCalls(v, vm.envAddress("CURATOR"));
        vm.startBroadcast(vm.envUint("GOV_ADMIN_KEY"));
        for (uint256 i; i < back.length; ++i) {
            VaultGovernor(d.governor).execute(d.vault, back[i]);
        }
        vm.stopBroadcast();
        console2.log("recoveries executed through the governor");
    }

    /// @notice The owner calls that undo the guardian's emergency stage (each waits DELAY).
    function recoveryCalls(SharedCommitmentVault v, address curatorAddr) public view returns (bytes[] memory c) {
        c = new bytes[](3);
        c[0] = abi.encodeCall(v.setPaused, (false));
        c[1] = abi.encodeCall(v.setSellHalted, (v.asset1(), false));
        c[2] = abi.encodeCall(v.unfreezeCurator, (curatorAddr));
    }
}
