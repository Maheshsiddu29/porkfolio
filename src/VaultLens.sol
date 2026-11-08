// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {ISharedCommitmentVault} from "./interfaces/ISharedCommitmentVault.sol";
import {IVaultState} from "./interfaces/IVaultState.sol";

/// @title VaultLens
/// @notice Read-only helpers for `SharedCommitmentVault`: deposit and redemption previews, the status of a queued
///         request, and the derived quantities N_a, F_a, D_a, deliverable shares and an allocation's effective
///         price floor.
/// @dev These views are kept out of the vault to leave room in its bytecode under the EIP-170 limit. That is safe
///      because none of them is needed as an external function by the vault itself: the vault keeps its own
///      internal copy of every formula it enforces.
///
///      Trust model. The lens has no storage, no constructor, no owner and no ERC-6909 claims or approvals. Every
///      function takes the vault as an argument and only calls the view getters declared in `IVaultState`, which
///      read stored values directly. The vault never calls the lens, so the lens is not on any deposit, swap,
///      allocation or redemption path, and a bug here cannot change what the vault accepts or pays. A wrong result
///      can mislead a caller, for example into a slippage bound that makes their own transaction revert. Results
///      are only as trustworthy as the `vault` argument: pointing the lens at another contract returns whatever
///      that contract reports.
///
///      Each function repeats the vault's internal formula and rounding exactly, so that its result equals what
///      the vault would compute in the same block. `test/unit/VaultLens.t.sol` checks that equality against the
///      vault's actual behaviour.
contract VaultLens {
    /// @notice N_a = B_a - W_a: assets owned by outstanding shares, including committed capacity Q_a.
    /// @dev Same as the vault's `_netAssets`. The subtraction cannot underflow while the vault maintains
    ///      W_a <= B_a.
    /// @param vault Vault to read.
    /// @param currency asset0 or asset1. Any other currency returns 0.
    /// @return Raw units of `currency`.
    function netAssets(IVaultState vault, Currency currency) public view returns (uint256) {
        return vault.backing(currency) - vault.claimableAssets(currency);
    }

    /// @notice F_a = B_a - W_a - Q_a: inventory that can be paid out now without breaking a live commitment or
    ///         touching assets owed to finalized requests.
    /// @dev Cannot underflow while the vault maintains Q_a + W_a <= B_a.
    /// @param vault Vault to read.
    /// @param currency asset0 or asset1. Any other currency returns 0.
    /// @return Raw units of `currency`.
    function freeInventory(IVaultState vault, Currency currency) external view returns (uint256) {
        return netAssets(vault, currency) - vault.reserved(currency);
    }

    /// @notice D_a = ceil(P * N_a / S): what the pending queue would be owed in `currency` if it were finalized now.
    /// @dev Same as the vault's `_pendingDemand`, which `admissibleCapacity` and `allocate` use. Rounded up so the
    ///      capacity protected for the queue is never less than its exact pro-rata share. Example: P = 300,
    ///      S = 1,000 and N_a = 1,001 give ceil(300.3) = 301. P > 0 implies S >= P > 0, so the division is safe.
    /// @param vault Vault to read.
    /// @param currency Asset to evaluate.
    /// @return Raw units of `currency`, or 0 when nothing is pending.
    function pendingDemand(IVaultState vault, Currency currency) external view returns (uint256) {
        uint256 p = vault.pendingShares();
        if (p == 0) return 0;
        return FullMath.mulDivRoundingUp(p, netAssets(vault, currency), vault.totalShares());
    }

    /// @notice Largest number of shares whose in-kind basket free inventory could pay right now.
    /// @dev Same as the vault's `_deliverableShares`: min over both assets of floor(F_a * S / N_a), skipping an asset
    ///      with N_a = 0, and type(uint256).max if both are zero. Example: S = 2,000, N0 = 1,000 with Q0 = 400, and
    ///      N1 = 500 with Q1 = 0 give min(1,200, 2,000) = 1,200. This ignores queue priority: `redeem` pays
    ///      instantly only when nothing is pending, so while P > 0 an instant exit is not possible whatever this
    ///      returns.
    /// @param vault Vault to read.
    /// @return cap Share count, or 0 before the vault is initialized.
    function deliverableShares(IVaultState vault) external view returns (uint256 cap) {
        uint256 supply = vault.totalShares();
        if (supply == 0) return 0;
        cap = type(uint256).max;
        Currency a0 = vault.asset0();
        uint256 n0 = netAssets(vault, a0);
        if (n0 != 0) cap = FullMath.mulDiv(n0 - vault.reserved(a0), supply, n0);
        Currency a1 = vault.asset1();
        uint256 n1 = netAssets(vault, a1);
        if (n1 != 0) {
            uint256 c1 = FullMath.mulDiv(n1 - vault.reserved(a1), supply, n1);
            if (c1 < cap) cap = c1;
        }
    }

    /// @notice Amounts `deposit` would charge for `shares` in the current state: ceil(shares * N_a / S) per asset.
    /// @dev Same formula and rounding as the vault's `deposit`. Example: S = 1,000, N0 = 2,000 and N1 = 501 price
    ///      10 shares at 20 of asset0 and ceil(5.01) = 6 of asset1. Reverts with `NotInitialized` before the first
    ///      deposit and with `NoAssets` if both N_a are zero, as `deposit` does. A trade between this call and the
    ///      deposit can change the price, so pass the result as `maxAmount0/1` with whatever tolerance you accept.
    /// @param vault Vault to read.
    /// @param shares Shares to price.
    /// @return amount0 Raw asset0 required.
    /// @return amount1 Raw asset1 required.
    function previewDeposit(IVaultState vault, uint256 shares)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 supply = vault.totalShares();
        if (supply == 0) revert ISharedCommitmentVault.NotInitialized();
        uint256 n0 = netAssets(vault, vault.asset0());
        uint256 n1 = netAssets(vault, vault.asset1());
        if (n0 == 0 && n1 == 0) revert ISharedCommitmentVault.NoAssets();
        amount0 = FullMath.mulDivRoundingUp(shares, n0, supply);
        amount1 = FullMath.mulDivRoundingUp(shares, n1, supply);
    }

    /// @notice In-kind basket of `shares` in the current state: floor(shares * N_a / S) per asset.
    /// @dev Same formula and rounding as the vault's `_entitlement`, which instant redemptions and queue
    ///      finalization use. This is what the shares are worth, not what `redeem` can pay now; free inventory and
    ///      the queue decide that (see `deliverableShares`). Returns (0, 0) before initialization.
    /// @param vault Vault to read.
    /// @param shares Shares to value.
    /// @return amount0 Raw asset0.
    /// @return amount1 Raw asset1.
    function previewRedeem(IVaultState vault, uint256 shares) external view returns (uint256 amount0, uint256 amount1) {
        uint256 supply = vault.totalShares();
        if (supply == 0) return (0, 0);
        amount0 = FullMath.mulDiv(shares, netAssets(vault, vault.asset0()), supply);
        amount1 = FullMath.mulDiv(shares, netAssets(vault, vault.asset1()), supply);
    }

    /// @notice Floor that `exchange` would apply to this allocation right now: max(live vault floor, curator floor).
    /// @dev Same as the vault's `_effectiveFloor`. Reverts in the same policy cases as `exchange`: with
    ///      `PriceFloorNotConfigured` if the direction was never opened (also for an unknown id, whose stored
    ///      currency is address(0)) and with `DirectionHalted` while the direction is halted. It does not check
    ///      that the allocation is live; `getAllocation` shows `released` and `expiry`.
    /// @param vault Vault to read.
    /// @param allocationId Allocation to inspect.
    /// @return Effective floor, Q64.96 raw input per raw output.
    function effectiveFloorX96(IVaultState vault, uint256 allocationId) external view returns (uint256) {
        ISharedCommitmentVault.Allocation memory a = vault.getAllocation(allocationId);
        (uint160 vaultFloor, bool halted) = vault.sellPolicy(a.currencyOut);
        if (vaultFloor == 0) revert ISharedCommitmentVault.PriceFloorNotConfigured(a.currencyOut);
        if (halted) revert ISharedCommitmentVault.DirectionHalted(a.currencyOut);
        return a.minInPerOutX96 > vaultFloor ? a.minInPerOutX96 : vaultFloor;
    }

    /// @notice Lifecycle state of a withdrawal request, derived from its stored amounts.
    /// @dev Pending has priority: a partially finalized request with claimable assets is still Pending. A request
    ///      canceled after a partial finalization reports Claimable until it is claimed, then Canceled.
    /// @param vault Vault to read.
    /// @param requestId Request to inspect.
    /// @return The request's current status.
    function requestStatus(IVaultState vault, uint256 requestId)
        external
        view
        returns (ISharedCommitmentVault.RequestStatus)
    {
        ISharedCommitmentVault.WithdrawalRequest memory r = vault.getRequest(requestId);
        if (r.lp == address(0)) return ISharedCommitmentVault.RequestStatus.None;
        if (r.sharesPending != 0) return ISharedCommitmentVault.RequestStatus.Pending;
        if (r.claimable0 != 0 || r.claimable1 != 0) return ISharedCommitmentVault.RequestStatus.Claimable;
        return
            r.canceled ? ISharedCommitmentVault.RequestStatus.Canceled : ISharedCommitmentVault.RequestStatus.Completed;
    }
}
