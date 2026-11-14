// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {IMarketRiskAdapter} from "../../src/interfaces/IMarketRiskAdapter.sol";
import {PriceRiskAdapter} from "../../src/oracle/PriceRiskAdapter.sol";
import {BaseCompatibleHook} from "../../src/hooks/BaseCompatibleHook.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {MockAggregator} from "../utils/MockAggregator.sol";
import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {VaultStateReader} from "../../src/libraries/VaultStateReader.sol";

using VaultStateReader for SharedCommitmentVault;

/// @notice An optional third-party relayer for the second provider, end to end: the real vault, both production hooks
///         and the PoolManager priced by `PriceRiskAdapter` with a fresh tier on the relayed source. The relayer is
///         modelled as "someone pushes the provider's packages": it holds no role in the vault, the hooks or the
///         adapter, and trading never waits for it. What its pushes change is the width of the band, and only while
///         they keep coming.
contract RelayerOutageTest is VaultTestBase {
    MockAggregator internal cl0;
    MockAggregator internal cl1;
    MockAggregator internal rs0;
    MockAggregator internal rs1;
    PriceRiskAdapter internal adapter;
    uint256 internal tau;

    function setUp() public override {
        super.setUp();
        (cl0, cl1, rs0, rs1) =
        (new MockAggregator(8), new MockAggregator(8), new MockAggregator(8), new MockAggregator(8));
        _pushAll(T0);
        adapter = new PriceRiskAdapter(
            PriceRiskAdapter.Source(cl0, cl1, 3100, 5100, 88_200, 88_200, 0, 0, 0),
            PriceRiskAdapter.Source(rs0, rs1, 5100, 5100, 12_600, 23_400, 120, 1500, 1500),
            address(token0),
            address(token1),
            18,
            18,
            IAggregatorV3(address(0)),
            0,
            2
        );
        tau = FullMath.mulDiv(vault.backing(c0), 1e18, vault.totalShares());
        vm.startPrank(owner);
        vault.setRiskBounds(100, 20_000);
        vault.setInventoryBounds(tau, tau, 20_000, 20_000);
        vault.setRiskAdapter(adapter);
        vault.setSellFloor(c0, 0);
        vault.setSellFloor(c1, 0);
        vm.stopPrank();
        BaseCompatibleHook.CoreParams memory p = BaseCompatibleHook.CoreParams({
            depthPerShare: 10e18,
            depthMax: uint128(2 ** 95 - 1),
            baseSpreadPips: 1000,
            minEdgePips: 200,
            maxSpreadPips: 40_000,
            maxDeviationPips: 20_000
        });
        vm.startPrank(hookOwner);
        hookA.configureCore(keyA, p);
        hookB.configureCore(keyB, p);
        hookB.configureStrategy(keyB, 1000, 20_000);
        vm.stopPrank();
    }

    function _pushAll(uint256 at) internal {
        cl0.set(1e8, at);
        cl1.set(1e8, at);
        _relay(at);
    }

    /// @dev What a relayer does: post the provider's latest signed price for both legs.
    function _relay(uint256 at) internal {
        rs0.set(1e8, at);
        rs1.set(1e8, at);
    }

    function _trySwap(PoolKey memory key, uint256 amountIn) internal returns (bool ok, uint256 out) {
        uint256 id = _allocate(key, c1, uint128(amountIn * 2));
        try this.swapExternal(key, amountIn, id) returns (uint256 o) {
            (ok, out) = (true, o);
        } catch {}
    }

    function swapExternal(PoolKey memory key, uint256 amountIn, uint256 id) external returns (uint256) {
        BalanceDelta d = _swap(key, true, amountIn, id);
        return uint256(int256(d.amount1()));
    }

    /// @dev 200-token trades, all selling the vault's currency1, stay well inside the shared inventory cap (about
    ///      4,000 tokens at this depth), so every refusal below is the reference's, not the cap's.
    function test_relayerOutage_widensThenHaltsOnlyWithTheProvider_recoversByItself() public {
        uint256 t = T0 + 600;
        vm.warp(t);
        _relay(t - 30); // relayer running: legs 30 s old
        uint256 uFresh = adapter.currentReference().uncertaintyPips;
        (bool okA, uint256 freshA) = _trySwap(keyA, 200 ether);
        (bool okB, uint256 freshB) = _trySwap(keyB, 200 ether);
        assertTrue(okA && okB, "both hooks fill while fresh");

        vm.warp(t - 30 + 121); // relayer stops: past the fresh tier
        uint256 uPush = adapter.currentReference().uncertaintyPips;
        assertGt(uPush, 2 * uFresh, "band widens");
        (okA,) = _trySwap(keyA, 200 ether);
        (bool okB2, uint256 pushB) = _trySwap(keyB, 200 ether);
        assertTrue(okA && okB2, "still filling on the push band: the relayer is not needed to trade");
        assertLt(pushB, freshB, "worse quote for the trader without fresh prices");
        console2.log("uncertainty pips: fresh / push", uFresh, uPush);
        console2.log("Hook B output for 200 in: fresh / push", freshB, pushB);

        vm.warp(t - 30 + 12_601); // the provider's own push heartbeat (12,600 s) has lapsed as well
        (okA,) = _trySwap(keyA, 200 ether);
        (okB,) = _trySwap(keyB, 200 ether);
        assertFalse(okA || okB, "two-source mode refuses with one source dark");
        (uint256 inst,,,) = _redeem(lp0, 1e21, false); // LP exits never read the adapter
        assertEq(inst, 1e21);
        _depositShares(makeAddr("lateLp"), 1e21);

        _relay(vm.getBlockTimestamp()); // anyone pushes again; no governance action
        (okA,) = _trySwap(keyA, 200 ether);
        (okB,) = _trySwap(keyB, 200 ether);
        assertTrue(okA && okB, "trading resumes by itself");
        assertEq(address(vault.riskAdapter()), address(adapter));
        console2.log("Hook A output for 200 in (fresh)", freshA);
    }
}
