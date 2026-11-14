// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {IVaultState} from "../../src/interfaces/IVaultState.sol";
import {CumulativePricing} from "../../src/hooks/CumulativePricing.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {VaultStateReader} from "../../src/libraries/VaultStateReader.sol";

using VaultStateReader for SharedCommitmentVault;
using VaultStateReader for IVaultState;

/// @notice Reads the vault state a pricing rule based on real inventory would need, and reports the gas it costs.
/// @dev Research instrument only. The reads are the vault's stored values through `extsload`, decoded by
///      `VaultStateReader` (two storage words per asset and one for S); nothing here changes the vault.
contract VaultInventoryReader {
    /// @return gasUsed Gas of the reads alone (between the two `gasleft` calls).
    /// @return n0 backing(c0) - claimableAssets(c0).
    /// @return n1 backing(c1) - claimableAssets(c1).
    /// @return shares totalShares().
    function read(IVaultState vault, Currency c0, Currency c1)
        external
        view
        returns (uint256 gasUsed, uint256 n0, uint256 n1, uint256 shares)
    {
        uint256 g = gasleft();
        n0 = vault.backing(c0) - vault.claimableAssets(c0);
        n1 = vault.backing(c1) - vault.claimableAssets(c1);
        shares = vault.totalShares();
        gasUsed = g - gasleft();
    }
}

/// @notice Root cause of Hook B's reverse-trade refusals, reproduced on the production artifacts (real PoolManager,
///         production Hook B and vault). Every expected number is the Python model's (`simulations/mm/rootcause.py`,
///         part 1), to the wei.
/// @dev Fixture: depth 1,000,000 tokens, 2% cap, 1 h decay, reference 1:1, vault floors 1:1. These tests document
///      existing behaviour; they do not test a fix.
contract HookBRootCauseTest is VaultTestBase {
    uint128 internal constant BIG = 400_000 ether;
    uint256 internal constant SALE_IN = 5000 ether;
    uint256 internal constant SALE_OUT = 4_975_124_378_109_452_736_318; // currency1 out, = position x
    uint256 internal constant REVERSE_IN = 1000 ether;
    uint256 internal constant REVERSE_QUOTE = 1_009_010_944_001_278_714_891; // currency0 the curve would pay

    /// @dev Reads the timestamp through the cheatcode: under via-IR a function may reuse an earlier
    ///      `block.timestamp` read after a warp.
    function _wait(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
    }

    function _out(BalanceDelta d, bool zeroForOne) internal pure returns (uint256) {
        return uint256(int256(zeroForOne ? d.amount1() : d.amount0()));
    }

    /// @dev An allocation with an explicit curator floor (the shared helper always uses 1:1).
    function _allocateWithFloor(PoolKey memory key, Currency out, uint128 maxOut, uint160 floorX96)
        internal
        returns (uint256 id)
    {
        ISharedCommitmentVault.AllocationRequest memory req = _request(key, out, maxOut);
        req.minInPerOutX96 = floorX96;
        vm.prank(curator);
        id = auth.activateDirect(req);
    }

    /// @notice Mechanism: after the vault sells currency1, the curve's buy-back price is above the reference (one curve,
    ///         no spread, mid moved by the position). The 1:1 pivot floor refuses it. The quoted price is 1.00901
    ///         currency0 per currency1: against a market at the reference this would be a 0.9% arbitrage paid by LPs,
    ///         so the floor is refusing a loss, not a profitable trade.
    function test_RC_reverseIsQuotedAboveReferenceAndRefused() public {
        uint256 id01 = _allocate(keyB, c1, BIG);
        uint256 id10 = _allocate(keyB, c0, BIG);
        assertEq(_out(_swap(keyB, true, SALE_IN, id01), true), SALE_OUT);
        assertEq(hookB.positionOf(keyB), int256(SALE_OUT));
        assertEq(hookB.quote(keyB, false, REVERSE_IN), REVERSE_QUOTE);
        // PriceBelowFloor(amountIn, requiredIn); at the 1:1 floor requiredIn = ceil(out * 2^96 / 2^96) = out.
        _expectSwapRevert(
            address(hookB),
            abi.encodeWithSelector(ISharedCommitmentVault.PriceBelowFloor.selector, REVERSE_IN, REVERSE_QUOTE)
        );
        _swap(keyB, false, REVERSE_IN, id10);
    }

    /// @notice Decay, not inventory, lets the reverse through: 1,635 s after the sale the same reverse is still
    ///         refused, at 1,636 s it passes (model: position 497.73 currency1 then). Nothing about the vault's
    ///         holdings changed in between.
    function test_RC_reversePassesOnlyAfterDecay() public {
        uint256 id01 = _allocate(keyB, c1, BIG);
        uint256 id10 = _allocate(keyB, c0, BIG);
        _swap(keyB, true, SALE_IN, id01);
        uint256 b1 = vault.backing(c1);
        _wait(1635);
        assertGt(hookB.quote(keyB, false, REVERSE_IN), REVERSE_IN, "still above the floor at 1,635 s");
        _wait(1);
        assertEq(hookB.positionOf(keyB), int256(497_730_019_731_444_340_417));
        assertEq(hookB.quote(keyB, false, REVERSE_IN), 999_995_710_052_713_804_931);
        _swap(keyB, false, REVERSE_IN, id10);
        assertEq(vault.backing(c1), b1 + REVERSE_IN, "only the trade itself moved inventory");
    }

    /// @notice Decay restores the price but not the inventory: after a full window the next identical sale is priced
    ///         exactly as the first, although the vault now holds 2 x 4,975 fewer currency1. The pricing state measures
    ///         recent flow, not the vault's exposure.
    function test_RC_decayRestoresPriceNotInventory() public {
        uint256 id01 = _allocate(keyB, c1, BIG);
        uint256 b1 = vault.backing(c1);
        _swap(keyB, true, SALE_IN, id01);
        _wait(B_WINDOW);
        assertEq(hookB.positionOf(keyB), 0);
        assertEq(_out(_swap(keyB, true, SALE_IN, id01), true), SALE_OUT, "second sale priced as if flat");
        assertEq(vault.backing(c1), b1 - 2 * SALE_OUT);
    }

    /// @notice Moving the floor pivot only moves the refusal to the other side. With the pivot at 0.99 (owner raises
    ///         F_sell1 to ceil(2^192 / F_sell0) and lowers F_sell0, the loosest D14 pair) and an allocation whose
    ///         curator floor matches, the reverse leg passes, and an ordinary forward sale near the reference is now
    ///         refused: D14 floors are a single pivot, so a mid that moves with the position can trade on only one side
    ///         of it.
    function test_RC_movingThePivotMovesTheRefusal() public {
        uint256 id01 = _allocate(keyB, c1, BIG);
        _swap(keyB, true, SALE_IN, id01);

        uint160 f0 = uint160(FixedPoint96.Q96 * 99 / 100);
        uint160 f1 = uint160(FullMath.mulDivRoundingUp(FixedPoint96.Q96, FixedPoint96.Q96, f0));
        vm.startPrank(owner);
        vault.setSellFloor(c1, f1); // raise first: keeps the pair consistent at every step
        vault.setSellFloor(c0, f0);
        vm.stopPrank();

        uint256 id10 = _allocateWithFloor(keyB, c0, BIG, f0);
        _swap(keyB, false, REVERSE_IN, id10); // the reverse now passes

        uint256 id01b = _allocateWithFloor(keyB, c1, BIG, f1);
        uint256 quoted = hookB.quote(keyB, true, 1000 ether);
        uint256 requiredIn = FullMath.mulDivRoundingUp(quoted, f1, FixedPoint96.Q96);
        _expectSwapRevert(
            address(hookB),
            abi.encodeWithSelector(ISharedCommitmentVault.PriceBelowFloor.selector, 1000 ether, requiredIn)
        );
        _swap(keyB, true, 1000 ether, id01b);
    }

    /// @notice A separate cause that looks the same to a router: the reverse direction needs its own allocation. Using
    ///         the currency1-selling allocation for a currency1-buying swap is refused by the vault's direction check,
    ///         whatever the price.
    function test_RC_reverseNeedsAnAllocationInItsDirection() public {
        uint256 id01 = _allocate(keyB, c1, BIG);
        _swap(keyB, true, SALE_IN, id01);
        _wait(B_WINDOW);
        _expectSwapRevert(address(hookB), abi.encodeWithSelector(ISharedCommitmentVault.DirectionMismatch.selector));
        _swap(keyB, false, REVERSE_IN, id01);
    }

    /// @notice Gas of the vault reads an inventory-based rule needs (N_0, N_1, S: five storage words), cold and warm.
    ///         Logged for the feasibility estimate; asserts only an upper bound so that a regression is visible.
    function test_RC_gas_vaultInventoryReads() public {
        VaultInventoryReader r = new VaultInventoryReader();
        vm.cool(address(vault));
        (uint256 cold, uint256 n0, uint256 n1, uint256 s) = r.read(IVaultState(address(vault)), c0, c1);
        (uint256 warm,,,) = r.read(IVaultState(address(vault)), c0, c1);
        emit log_named_uint("vault inventory reads, cold (gas)", cold);
        emit log_named_uint("vault inventory reads, warm (gas)", warm);
        assertEq(n0, VAULT_FUNDING);
        assertEq(n1, VAULT_FUNDING);
        assertGt(s, 0);
        // 17,445 cold through `extsload` (five storage words); the bound only catches a large regression.
        assertLt(cold, 25_000);
        assertLt(warm, cold);
    }

    /// @notice Gas of the curve arithmetic an inventory-based rule would reuse from `CumulativePricing`, at the depth the
    ///         calibrated configuration derives (about 1.58 * 10^26 raw for a 1,000,000-token vault, 15% cap, 20 bps):
    ///         one cost evaluation, one exact-input inversion and one cap computation (sqrt plus correction). The
    ///         straddle cap needs two cap-like computations per swap. Logged for the feasibility estimate only.
    function test_RC_gas_curveMath() public {
        uint256 v = 158_001_289_277_201_521_479_000_000;
        uint256 p = FixedPoint96.Q96;
        int256 x = 50_000 ether;
        uint256 g = gasleft();
        int256 c = CumulativePricing.positionCost(x, v, p);
        uint256 gCost = g - gasleft();
        g = gasleft();
        int256 x2 = CumulativePricing.positionForCost(c + 1000 ether, v, p);
        uint256 gInv = g - gasleft();
        g = gasleft();
        uint256 cap = CumulativePricing.maxPosition(v, 1900);
        uint256 gCap = g - gasleft();
        emit log_named_uint("positionCost (gas)", gCost);
        emit log_named_uint("positionForCost (gas)", gInv);
        emit log_named_uint("maxPosition (gas)", gCap);
        assertGt(x2, x);
        assertGt(cap, 0);
    }
}
