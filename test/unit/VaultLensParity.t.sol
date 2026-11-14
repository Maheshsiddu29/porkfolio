// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @notice Differential test of `VaultLens`'s storage decoding against the vault's own getters.
/// @dev A fuzzed sequence of real operations (deposits, queued redemptions, queue processing, claims, request
///      cancellation, allocations, swaps through Hook A and Hook B on the real PoolManager, curator cancellation,
///      expiry release, and owner changes to floors, limits and bounds) runs against the production vault. After
///      every operation each value the lens reads through `extsload` must equal the vault getter of the same name,
///      for both assets and a currency outside the pair, every account and scope the sequence touches, and every
///      allocation and request id up to the next one (the unused next id must decode as all-zero). Operations that
///      the vault refuses in the state the fuzzer reached are skipped: the point is the variety of reachable states,
///      not the operations themselves, which other suites test.
contract VaultLensParityTest is VaultTestBase {
    /// @dev Operation kinds, steps per sequence, and sequences in the non-vacuity test.
    uint256 internal constant OPS = 12;
    uint256 internal constant STEPS = 14;
    uint256 internal constant SEEDS = 64;

    address internal lp1 = makeAddr("lp1");
    uint256[] internal requestIds;
    mapping(uint256 requestId => address lp) internal requester;

    function setUp() public override {
        super.setUp();
        _deepenHookB();
        vm.startPrank(owner);
        vault.setCuratorCeiling(curator, c0, 10 * VAULT_FUNDING);
        vault.setCuratorCeiling(curator, c1, 10 * VAULT_FUNDING);
        vm.stopPrank();
    }

    /// forge-config: default.fuzz.runs = 256
    /// forge-config: ci.fuzz.runs = 1000
    function testFuzz_lensMatchesGetters(uint256 seed) public {
        _runSequence(seed, true);
    }

    /// @notice Non-vacuity of the sequence above: over a fixed set of seeds the operation generator makes every
    ///         operation kind change vault state at least once (a queued redemption, a queue step that finalizes
    ///         shares, a claim, a cancelled request, a swap, and so on), so the fuzz test's parity checks run on the
    ///         states those operations produce, not only on the fixture.
    /// @dev Measures the generator only, so it skips the parity checks (which cost most of the gas). The counts live
    ///      in memory: `revertToState` also reverts this test contract's storage.
    function test_sequence_reachesEveryOperation() public {
        uint256[OPS] memory count;
        uint256 snap = vm.snapshotState();
        for (uint256 seed; seed < SEEDS; ++seed) {
            bool[OPS] memory ok = _runSequence(seed, false);
            vm.revertToState(snap);
            for (uint256 op; op < OPS; ++op) {
                if (ok[op]) count[op] += 1;
            }
        }
        for (uint256 op; op < OPS; ++op) {
            assertGt(count[op], 0, string.concat("operation never succeeded: ", vm.toString(op)));
        }
    }

    // ------------------------------------------------------------------
    // Operations
    // ------------------------------------------------------------------

    /// @dev One sequence of an opening allocation plus STEPS operations; with `checkParity`, the full parity check
    ///      runs after each of them.
    function _runSequence(uint256 seed, bool checkParity) internal returns (bool[OPS] memory ok) {
        if (checkParity) _assertParity();
        // Every sequence opens with an allocation of 80-100% of the admissible capacity of one asset, so later
        // exits outgrow free inventory and queue.
        uint256 r0 = uint256(keccak256(abi.encode(seed, "open")));
        Currency out = r0 & 1 == 0 ? c0 : c1;
        uint256 cap = vault.admissibleCapacity(out);
        _allocate(r0 & 2 == 0 ? keyA : keyB, out, uint128(bound(r0 >> 2, cap * 8 / 10, cap)));
        if (checkParity) _assertParity();
        for (uint256 i; i < STEPS; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = r % OPS;
            if (_step(op, r >> 8)) ok[op] = true;
            if (checkParity) _assertParity();
        }
        delete requestIds;
    }

    /// @dev Runs one operation; returns true if the vault accepted it and it changed something.
    function _step(uint256 op, uint256 r) internal returns (bool ok) {
        if (op == 0) {
            _depositShares(lp1, bound(r, 1 ether, 500_000 ether));
            return true;
        } else if (op == 1) {
            // The seed LP holds most shares, so its exits are the ones that outgrow free inventory and queue.
            address lp = r & 1 == 0 ? lp0 : lp1;
            uint256 s = vault.sharesOf(lp);
            if (s == 0) return false;
            vm.prank(lp);
            try vault.redeem(bound(r >> 1, s / 2 + 1, s), 0, 0, lp, true) returns (
                uint256, uint256, uint256, uint256 id
            ) {
                if (id != 0) {
                    requestIds.push(id);
                    requester[id] = lp;
                }
                return id != 0;
            } catch {}
        } else if (op == 2) {
            try vault.processQueue(r % 4 + 1) returns (uint256 finalized) {
                return finalized != 0;
            } catch {}
        } else if (op == 3 || op == 4) {
            if (requestIds.length == 0) return false;
            uint256 id = requestIds[r % requestIds.length];
            vm.prank(requester[id]);
            if (op == 3) {
                try vault.claim(id) {
                    return true;
                } catch {}
            } else {
                try vault.cancelRequest(id) {
                    return true;
                } catch {}
            }
        } else if (op == 5) {
            PoolKey memory key = r & 1 == 0 ? keyA : keyB;
            Currency out = r & 2 == 0 ? c0 : c1;
            uint256 cap = vault.admissibleCapacity(out);
            if (cap < 2) return false;
            ISharedCommitmentVault.AllocationRequest memory req = _request(key, out, uint128(bound(r >> 2, 1, cap)));
            vm.prank(curator);
            try auth.activateDirect(req) {
                return true;
            } catch {}
        } else if (op == 6) {
            uint256 id = _lastLiveAllocation();
            if (id == 0) return false;
            ISharedCommitmentVault.Allocation memory a = vault.getAllocation(id);
            PoolKey memory key = a.consumer == address(hookA) ? keyA : keyB;
            // Selling currencyOut means the trader pays the other asset: zeroForOne when the vault sells asset1.
            return _trySwap(key, a.currencyOut == c1, bound(r, 1e15, 2000 ether), id);
        } else if (op == 7) {
            uint256 id = _lastAllocation();
            if (id == 0) return false;
            vm.prank(curator);
            try vault.cancelAllocation(id) {
                return true;
            } catch {}
        } else if (op == 8) {
            vm.warp(block.timestamp + bound(r, 1 hours, 2 days));
            uint256 id = _lastAllocation();
            if (id == 0) return false;
            try vault.release(id) {
                return true;
            } catch {}
        } else if (op == 9) {
            vm.prank(owner);
            try vault.setBufferFloor(r & 1 == 0 ? c0 : c1, bound(r >> 1, 0, 100_000 ether)) {
                return true;
            } catch {}
        } else if (op == 10) {
            address account = r & 1 == 0 ? address(hookA) : curator;
            ISharedCommitmentVault.RiskScope scope =
                r & 1 == 0 ? ISharedCommitmentVault.RiskScope.Hook : ISharedCommitmentVault.RiskScope.Curator;
            vm.prank(owner);
            try vault.setRiskLimit(
                scope, account, r & 2 == 0 ? c0 : c1, bound(r >> 2, 1, MAX_FLOW_CAP), uint16(bound(r >> 120, 1, 10_000))
            ) {
                return true;
            } catch {}
        } else {
            vm.startPrank(owner);
            try vault.setRiskBounds(uint24(bound(r, 0, 1e5)), uint24(bound(r >> 24, 0, 1e6))) {
                ok = true;
            } catch {}
            try vault.setInventoryBounds(bound(r >> 48, 0, 1e17), bound(r >> 100, 0, 1e17), 1e6, 1e6) {
                ok = true;
            } catch {}
            vm.stopPrank();
        }
    }

    function _lastAllocation() internal view returns (uint256) {
        return vault.nextAllocationId() - 1;
    }

    /// @dev Newest allocation that is neither closed nor expired; 0 if there is none.
    function _lastLiveAllocation() internal view returns (uint256 id) {
        for (id = _lastAllocation(); id != 0; --id) {
            ISharedCommitmentVault.Allocation memory a = vault.getAllocation(id);
            if (!a.released && block.timestamp < a.expiry && a.consumed < a.maxOut) return id;
        }
    }

    function _trySwap(PoolKey memory key, bool zeroForOne, uint256 amountIn, uint256 allocationId)
        internal
        returns (bool)
    {
        vm.prank(trader);
        try swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(allocationId)
        ) {
            return true;
        } catch {
            return false;
        }
    }

    // ------------------------------------------------------------------
    // Parity
    // ------------------------------------------------------------------

    function _assertParity() internal view {
        Currency[3] memory cs = [c0, c1, Currency.wrap(address(0xDEAD))];
        address[6] memory accounts = [curator, address(hookA), address(hookB), lp0, lp1, address(0)];

        assertEq(lens.totalShares(vault), vault.totalShares(), "totalShares");
        assertEq(lens.nextAllocationId(vault), vault.nextAllocationId(), "nextAllocationId");
        assertEq(lens.nextRequestId(vault), vault.nextRequestId(), "nextRequestId");
        assertEq(lens.queueHead(vault), vault.queueHead(), "queueHead");
        assertEq(address(lens.riskAdapter(vault)), address(vault.riskAdapter()), "riskAdapter");
        assertEq(lens.riskEdgePips(vault), vault.riskEdgePips(), "riskEdgePips");
        assertEq(lens.maxUncertaintyPips(vault), vault.maxUncertaintyPips(), "maxUncertaintyPips");
        for (uint256 i; i < 2; ++i) {
            assertEq(lens.inventoryTargetPerShare(vault, i), vault.inventoryTargetPerShare(i), "target");
            assertEq(lens.inventoryTolerancePips(vault, i), vault.inventoryTolerancePips(i), "tolerance");
        }

        for (uint256 i; i < 3; ++i) {
            Currency c = cs[i];
            assertEq(lens.backing(vault, c), vault.backing(c), "backing");
            assertEq(lens.reserved(vault, c), vault.reserved(c), "reserved");
            assertEq(lens.bufferFloor(vault, c), vault.bufferFloor(c), "bufferFloor");
            assertEq(lens.claimableAssets(vault, c), vault.claimableAssets(c), "claimableAssets");
            assertEq(lens.admissibleCapacity(vault, c), vault.admissibleCapacity(c), "admissibleCapacity");
            (uint160 f, bool h) = lens.sellPolicy(vault, c);
            (uint160 oldF, bool oldH) = vault.sellPolicy(c);
            assertEq(f, oldF, "sellPolicy.minInPerOutX96");
            assertEq(h, oldH, "sellPolicy.halted");
            for (uint256 j; j < 6; ++j) {
                address a = accounts[j];
                assertEq(lens.curatorCeiling(vault, a, c), vault.curatorCeiling(a, c), "curatorCeiling");
                assertEq(lens.curatorReserved(vault, a, c), vault.curatorReserved(a, c), "curatorReserved");
                assertEq(lens.hookReserved(vault, a, c), vault.hookReserved(a, c), "hookReserved");
                for (uint8 s; s < 3; ++s) {
                    ISharedCommitmentVault.RiskScope scope = ISharedCommitmentVault.RiskScope(s);
                    assertEq(
                        abi.encode(lens.getRiskLimit(vault, scope, a, c)),
                        abi.encode(vault.getRiskLimit(scope, a, c)),
                        "riskLimit"
                    );
                }
            }
        }
        for (uint256 j; j < 6; ++j) {
            assertEq(lens.sharesOf(vault, accounts[j]), vault.sharesOf(accounts[j]), "sharesOf");
        }

        uint256 n = vault.nextAllocationId();
        for (uint256 id; id <= n; ++id) {
            assertEq(abi.encode(lens.getAllocation(vault, id)), abi.encode(vault.getAllocation(id)), "allocation");
        }
        n = vault.nextRequestId();
        for (uint256 id; id <= n; ++id) {
            assertEq(abi.encode(lens.getRequest(vault, id)), abi.encode(vault.getRequest(id)), "request");
        }
    }

    /// @notice `admissibleCapacity` in the lens keeps the vault's overflow-safe chain: with R_a at
    ///         type(uint256).max (the guardian's way to stop new allocations) and a non-empty queue (D_a > 0) both
    ///         return 0, and with a large but finite R_a both return the same positive or zero value.
    function test_admissibleCapacity_maxBufferAndQueue() public {
        _depositShares(lp1, 100_000 ether);
        // Reserve almost all of asset0, so the redemption queues on asset0 while asset1 keeps admissible room.
        _allocate(keyB, c0, uint128(vault.admissibleCapacity(c0) - 10 ether));
        vm.prank(lp1);
        vault.redeem(100_000 ether, 0, 0, lp1, true);
        assertGt(vault.pendingShares(), 0);
        assertEq(lens.admissibleCapacity(vault, c0), vault.admissibleCapacity(c0));
        assertEq(lens.admissibleCapacity(vault, c1), vault.admissibleCapacity(c1));

        vm.startPrank(owner);
        vault.setBufferFloor(c0, type(uint256).max);
        vault.setBufferFloor(c1, 5 ether);
        vm.stopPrank();
        assertEq(vault.admissibleCapacity(c0), 0);
        assertEq(lens.admissibleCapacity(vault, c0), 0);
        assertEq(lens.admissibleCapacity(vault, c1), vault.admissibleCapacity(c1));
        assertGt(lens.admissibleCapacity(vault, c1), 0);
    }
}
