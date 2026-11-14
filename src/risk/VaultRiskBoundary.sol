// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

/// @title VaultRiskBoundary
/// @notice The checks a vault applies to every fill when an oracle risk adapter is installed: a validity bound on the
///         reference's uncertainty, a directional floor outside the reference band, and a floor on how much of each
///         asset the vault may hold after paying it out. Pure functions; the vault supplies its own state.
/// @dev Three rules, in the order the vault applies them:
///
///      1. Uncertainty circuit breaker. A reference whose uncertainty `u` exceeds the vault's `maxUncertainty` is
///         refused (`checkUncertainty`). The adapter already refuses stale, contradictory and sequencer-down data;
///         this bound is the vault's own, set by the owner and lowered by the guardian, independent of the adapter's
///         configuration.
///
///      2. Directional floor (`dynamicFloors`). With reference mid `P` (raw currency1 per raw currency0, Q64.96),
///         uncertainty `u` and edge `e` (pips), the vault sells asset1 only for at least
///         `F1 = ceil(ceil(2^192 / P) * (1e6 + u + e) / 1e6)` raw asset0 per raw asset1 (Q64.96), and sells asset0
///         only for at least `F0 = ceil(P * (1e6 + u + e) / 1e6)` raw asset1 per raw asset0. The adapter's `u` covers
///         every allowed price `p` multiplicatively, `P / (1 + u) <= p <= P (1 + u)` (`IMarketRiskAdapter`), so
///         `F0 >= P (1 + u) + e P >= max p + e P` and `F1 >= (1 / P)(1 + u) + e / P >= 1 / min p + e / P`: the vault
///         never trades at a price any live source allows to be at or past the market, plus `e` of the mid, in
///         either direction. (A `u` measured from the mid alone covers only the first: G04 finding F-1.)
///         `F0 * F1 >= 2^192 (1 + (u + e) / 1e6)^2`:
///         at every reference the pair satisfies the directional-consistency rule by construction, with no price set
///         by anyone.
///
///      3. Inventory floor (`inventoryFloor`, `checkInventory`). For each asset, governance sets a target `tau_a`
///         (raw units per share, WAD) and a tolerance `kappa_a` (pips). A fill that pays out `out` of asset `a` must
///         leave `N_a - out >= L_a = ceil(S * tau_a * (1e6 - kappa_a) / (1e18 * 1e6))`, where `N_a` is the vault's net
///         holding (backing minus claimable) and `S` its share supply. Inflows are never limited. The rule uses no
///         price. It is what bounds a loss when every price input is wrong at once: after any sequence of fills,
///         whatever the adapter or the hooks report, the vault holds at least `min(N_a before, L_a)` of each asset,
///         so the value LPs can lose through trading is at most `sum_a (N_a - L_a) * p_a` at the true prices
///         `p_a`. In-kind LP deposits and redemptions scale `N_a`, `S` and `L_a` together and are not affected.
///
///      Not handled here: the timelocked choice of adapter, flow caps (already per epoch in the vault), and the
///      adapter's own validation (staleness, divergence, sequencer).
library VaultRiskBoundary {
    uint256 internal constant PIPS = 1_000_000;
    uint256 internal constant WAD = 1e18;

    /// @notice The reference's uncertainty is above the vault's bound.
    /// @param uncertainty Uncertainty reported, pips.
    /// @param maxUncertainty Vault bound, pips.
    error UncertaintyTooHigh(uint256 uncertainty, uint256 maxUncertainty);
    /// @notice The fill would leave the vault holding less of an asset than its inventory floor.
    /// @param holdingAfter `N_a - out`, raw units.
    /// @param floor_ `L_a`, raw units.
    error InventoryFloorBreached(uint256 holdingAfter, uint256 floor_);

    /// @notice Reverts with `UncertaintyTooHigh` if `uncertainty > maxUncertainty`.
    /// @param uncertainty Reference uncertainty, pips.
    /// @param maxUncertainty Vault bound, pips.
    function checkUncertainty(uint256 uncertainty, uint256 maxUncertainty) internal pure {
        if (uncertainty > maxUncertainty) revert UncertaintyTooHigh(uncertainty, maxUncertainty);
    }

    /// @notice The directional floor for one direction only: `dynamicFloors(...)` floor0 when the vault sells asset0,
    ///         floor1 when it sells asset1, computed with the same steps and the same rounding.
    /// @dev A fill pays out one asset, so the vault needs one floor. Skipping the other saves its 512-bit division
    ///      (`ceil(2^192 / P)` is only needed when selling asset1). `test/risk/VaultRiskBoundary.t.sol` checks equality
    ///      with `dynamicFloors` for random inputs.
    /// @param priceX96 Reference mid, Q64.96. Non-zero.
    /// @param uncertainty Reference uncertainty, pips.
    /// @param edge Vault edge beyond the band, pips.
    /// @param sellAsset1 True when the vault pays out asset1.
    /// @return Minimum raw input per raw output, Q64.96.
    function dynamicFloor(uint256 priceX96, uint256 uncertainty, uint256 edge, bool sellAsset1)
        internal
        pure
        returns (uint256)
    {
        uint256 p = sellAsset1 ? FullMath.mulDivRoundingUp(FixedPoint96.Q96, FixedPoint96.Q96, priceX96) : priceX96;
        return FullMath.mulDivRoundingUp(p, PIPS + uncertainty + edge, PIPS);
    }

    /// @notice Directional floors outside the reference band.
    /// @dev See rule 2. Each step rounds up, so the floors are never below the exact band. The vault checks a fill as
    ///      `amountIn >= ceil(amountOut * floor / 2^96)` with the floor for the asset it pays out. Overflow: `P < 2^160`
    ///      and `widen < 2^21`; `ceil(2^192 / P) <= 2^192`; FullMath keeps every product in 512 bits and both
    ///      results are below `2^214`.
    ///
    ///      Example: `P = 2^96` (1:1), `u` = 4,532 pips, `e` = 0: `F0 = F1 = ceil(2^96 * 1.004532)`; selling 1,000 of
    ///      either asset needs at least 1,004.532, rounded up to 1,005 raw units in.
    /// @param priceX96 Reference mid, Q64.96. Non-zero.
    /// @param uncertainty Reference uncertainty, pips.
    /// @param edge Vault edge beyond the band, pips. Must stay strictly below every hook's own edge (a hook keeping
    ///        only the same edge would be left with the floor's rounding as its whole margin).
    /// @return floor0 Minimum raw asset1 in per raw asset0 out, Q64.96.
    /// @return floor1 Minimum raw asset0 in per raw asset1 out, Q64.96.
    function dynamicFloors(uint256 priceX96, uint256 uncertainty, uint256 edge)
        internal
        pure
        returns (uint256 floor0, uint256 floor1)
    {
        uint256 widen = PIPS + uncertainty + edge;
        floor0 = FullMath.mulDivRoundingUp(priceX96, widen, PIPS);
        floor1 = FullMath.mulDivRoundingUp(
            FullMath.mulDivRoundingUp(FixedPoint96.Q96, FixedPoint96.Q96, priceX96), widen, PIPS
        );
    }

    /// @notice `L_a`: the least the vault may hold of an asset after paying it out.
    /// @dev `ceil(shares * target * (1e6 - tolerance) / (1e18 * 1e6))`, rounded up so the floor is never below the
    ///      exact value. Overflow: `shares < 2^127`, `target` a governance value (checked multiplication), the
    ///      product with `(1e6 - tolerance) < 2^20` held by FullMath.
    ///
    ///      Example: 1,000,000 shares, target 1 WAD per share (1,000,000 units), tolerance 150,000 pips (15%):
    ///      `L` = 850,000 units.
    /// @param shares Vault share supply `S`.
    /// @param targetPerShare `tau_a`, raw units per share, WAD.
    /// @param tolerance `kappa_a`, pips. At most 1e6.
    /// @return The floor, raw units.
    function inventoryFloor(uint256 shares, uint256 targetPerShare, uint256 tolerance) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(shares * targetPerShare, PIPS - tolerance, WAD * PIPS);
    }

    /// @notice Reverts with `InventoryFloorBreached` unless `holding - amountOut >= floor_`.
    /// @dev Applied only to the asset the vault pays out. A holding already below the floor (after a parameter change)
    ///      can still receive inflows but cannot pay out more of that asset.
    /// @param holding `N_a` before the fill, raw units.
    /// @param amountOut Raw units of the asset paid out.
    /// @param floor_ `L_a`, raw units.
    function checkInventory(uint256 holding, uint256 amountOut, uint256 floor_) internal pure {
        uint256 after_ = holding > amountOut ? holding - amountOut : 0;
        if (after_ < floor_) revert InventoryFloorBreached(after_, floor_);
    }
}
