// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {ISharedCommitmentVault} from "./interfaces/ISharedCommitmentVault.sol";
import {IVaultState} from "./interfaces/IVaultState.sol";
import {IMarketRiskAdapter} from "./interfaces/IMarketRiskAdapter.sol";
import {VaultRiskBoundary} from "./risk/VaultRiskBoundary.sol";
import {VaultStateReader} from "./libraries/VaultStateReader.sol";

/// @title VaultLens
/// @notice Read-only helpers for `SharedCommitmentVault`: the vault's stored accounting (B_a, Q_a, W_a, S, floors,
///         limits, allocations, requests), deposit and redemption previews, the status of a queued request, the
///         derived quantities N_a, F_a, D_a, E_a, deliverable shares, admissible capacity and an allocation's
///         effective price floor, and the headroom left under each flow and exposure limit.
/// @dev These views are kept out of the vault to leave room in its bytecode under the EIP-170 limit. That is safe
///      because none of them is needed as an external function by the vault itself: the vault keeps its own
///      internal copy of every formula it enforces.
///
///      Storage reads. Stored values are read with the vault's `extsload(slot)`, which returns one raw 32-byte
///      storage word, and decoded by `VaultStateReader`, which holds the slot numbers and packed offsets of the
///      vault's storage layout. `test/unit/VaultStorageLayout.t.sol` pins them against the compiled vault, so a
///      layout change in the vault breaks that test instead of silently returning wrong values here.
///
///      Trust model. The lens has no storage, no constructor, no owner and no ERC-6909 claims or approvals. Every
///      function takes the vault as an argument and only calls view functions on it. The vault never calls the
///      lens, so the lens is not on any deposit, swap, allocation or redemption path, and a bug here cannot change
///      what the vault accepts or pays. A wrong result can mislead a caller, for example into a slippage bound that
///      makes their own transaction revert. Results are only as trustworthy as the `vault` argument: pointing the
///      lens at another contract returns whatever that contract's storage holds at the vault's slot numbers.
///
///      Each derived function repeats the vault's internal formula and rounding exactly, so that its result equals
///      what the vault would compute in the same block. `test/unit/VaultLens.t.sol` checks that equality against
///      the vault's actual behaviour.
contract VaultLens {
    // ==================================================================
    // Stored values
    // ==================================================================

    /// @notice B_a: ERC-6909 claims the vault has accounted for.
    /// @param vault Vault to read.
    /// @param currency Asset to read; any other currency returns 0.
    /// @return Raw units of `currency`.
    function backing(IVaultState vault, Currency currency) public view returns (uint256) {
        return VaultStateReader.backing(vault, currency);
    }

    /// @notice Q_a: unused capacity of all unreleased allocations selling `currency`.
    /// @param vault Vault to read.
    /// @param currency Asset to read; any other currency returns 0.
    /// @return Raw units of `currency`.
    function reserved(IVaultState vault, Currency currency) public view returns (uint256) {
        return VaultStateReader.reserved(vault, currency);
    }

    /// @notice R_a: inventory that new allocations must leave unreserved.
    /// @param vault Vault to read.
    /// @param currency Asset to read; any other currency returns 0.
    /// @return Raw units of `currency`.
    function bufferFloor(IVaultState vault, Currency currency) public view returns (uint256) {
        return VaultStateReader.bufferFloor(vault, currency);
    }

    /// @notice W_a: assets finalized for queued redemptions and not yet claimed.
    /// @param vault Vault to read.
    /// @param currency Asset to read; any other currency returns 0.
    /// @return Raw units of `currency`.
    function claimableAssets(IVaultState vault, Currency currency) public view returns (uint256) {
        return VaultStateReader.claimableAssets(vault, currency);
    }

    /// @notice Vault floor and halt flag for the direction that sells `currencyOut`.
    /// @param vault Vault to read.
    /// @param currencyOut Asset the vault sells in that direction.
    /// @return minInPerOutX96 Floor, Q64.96 raw input per raw output. Zero means the direction was never opened.
    /// @return halted True while the direction is halted.
    function sellPolicy(IVaultState vault, Currency currencyOut)
        public
        view
        returns (uint160 minInPerOutX96, bool halted)
    {
        return VaultStateReader.sellPolicy(vault, currencyOut);
    }

    /// @notice Most unused capacity a curator may hold across its unreleased allocations in `currency`.
    /// @param vault Vault to read.
    /// @param curator Curator to read.
    /// @param currency Asset to read.
    /// @return Raw units of `currency`; zero means the curator can allocate nothing in it.
    function curatorCeiling(IVaultState vault, address curator, Currency currency) public view returns (uint256) {
        return VaultStateReader.curatorCeiling(vault, curator, currency);
    }

    /// @notice Unused capacity currently held by a curator's unreleased allocations.
    /// @param vault Vault to read.
    /// @param curator Curator to read.
    /// @param currency Asset to read.
    /// @return Raw units of `currency`.
    function curatorReserved(IVaultState vault, address curator, Currency currency) public view returns (uint256) {
        return VaultStateReader.curatorReserved(vault, curator, currency);
    }

    /// @notice Unused capacity currently held by a hook's unreleased allocations.
    /// @param vault Vault to read.
    /// @param consumer Hook to read.
    /// @param currency Asset to read.
    /// @return Raw units of `currency`.
    function hookReserved(IVaultState vault, address consumer, Currency currency) public view returns (uint256) {
        return VaultStateReader.hookReserved(vault, consumer, currency);
    }

    /// @notice S: all outstanding shares, including queued shares and the MIN_SHARES held by address(0).
    /// @param vault Vault to read.
    /// @return Share count.
    function totalShares(IVaultState vault) public view returns (uint256) {
        return VaultStateReader.totalShares(vault);
    }

    /// @notice Free (not escrowed) shares of `account`.
    /// @param vault Vault to read.
    /// @param account Account to read.
    /// @return Share count.
    function sharesOf(IVaultState vault, address account) public view returns (uint256) {
        return VaultStateReader.sharesOf(vault, account);
    }

    /// @notice Id the next successful `reserveFor` will assign.
    /// @param vault Vault to read.
    /// @return Allocation id.
    function nextAllocationId(IVaultState vault) public view returns (uint256) {
        return VaultStateReader.nextAllocationId(vault);
    }

    /// @notice Id the next queued redemption will receive.
    /// @param vault Vault to read.
    /// @return Request id.
    function nextRequestId(IVaultState vault) public view returns (uint256) {
        return VaultStateReader.nextRequestId(vault);
    }

    /// @notice Lowest request id that may still hold pending shares; queue processing starts here.
    /// @param vault Vault to read.
    /// @return Request id.
    function queueHead(IVaultState vault) public view returns (uint256) {
        return VaultStateReader.queueHead(vault);
    }

    /// @notice Market-risk adapter the vault reads on every fill; zero in static mode.
    /// @param vault Vault to read.
    /// @return The installed adapter.
    function riskAdapter(IVaultState vault) public view returns (IMarketRiskAdapter) {
        return VaultStateReader.riskAdapter(vault);
    }

    /// @notice e: the vault's edge beyond the adapter's reference band.
    /// @param vault Vault to read.
    /// @return Pips.
    function riskEdgePips(IVaultState vault) public view returns (uint24) {
        return VaultStateReader.riskEdgePips(vault);
    }

    /// @notice Largest adapter uncertainty the vault accepts.
    /// @param vault Vault to read.
    /// @return Pips.
    function maxUncertaintyPips(IVaultState vault) public view returns (uint24) {
        return VaultStateReader.maxUncertaintyPips(vault);
    }

    /// @notice tau_a: inventory target per share of asset `index`.
    /// @dev Reverts with Solidity's out-of-bounds panic (0x32) for `index` > 1, as a public array getter does.
    /// @param vault Vault to read.
    /// @param index 0 for asset0, 1 for asset1.
    /// @return Raw units of the asset per share, scaled by 1e18. Zero: no inventory floor for that asset.
    function inventoryTargetPerShare(IVaultState vault, uint256 index) public view returns (uint256) {
        return VaultStateReader.inventoryTargetPerShare(vault, index);
    }

    /// @notice kappa_a: tolerance of asset `index` below its inventory target.
    /// @dev Reverts with Solidity's out-of-bounds panic (0x32) for `index` > 1, as a public array getter does.
    /// @param vault Vault to read.
    /// @param index 0 for asset0, 1 for asset1.
    /// @return Pips of the target.
    function inventoryTolerancePips(IVaultState vault, uint256 index) public view returns (uint24) {
        return VaultStateReader.inventoryTolerancePips(vault, index);
    }

    /// @notice Stored state of an allocation; an all-zero struct for an unknown id.
    /// @param vault Vault to read.
    /// @param allocationId Allocation to read.
    /// @return a The allocation record.
    function getAllocation(IVaultState vault, uint256 allocationId)
        public
        view
        returns (ISharedCommitmentVault.Allocation memory a)
    {
        return VaultStateReader.getAllocation(vault, allocationId);
    }

    /// @notice Stored state of a withdrawal request; an all-zero struct for an unknown id.
    /// @param vault Vault to read.
    /// @param requestId Request to read.
    /// @return r The request record.
    function getRequest(IVaultState vault, uint256 requestId)
        public
        view
        returns (ISharedCommitmentVault.WithdrawalRequest memory r)
    {
        return VaultStateReader.getRequest(vault, requestId);
    }

    /// @notice Stored risk limits and flow usage of one scope in one asset; all-zero if never configured.
    /// @dev `flowUsed` is the usage of window `epoch`; it is not reset in storage when a window ends (`flowUsed`
    ///      below applies the window rule).
    /// @param vault Vault to read.
    /// @param scope Hook, Curator or Vault.
    /// @param account The hook or curator; address(0) for the vault scope.
    /// @param currency The asset the limit applies to (the asset the vault sells).
    /// @return l The stored record.
    function getRiskLimit(IVaultState vault, ISharedCommitmentVault.RiskScope scope, address account, Currency currency)
        public
        view
        returns (ISharedCommitmentVault.RiskLimit memory l)
    {
        return VaultStateReader.getRiskLimit(vault, scope, account, currency);
    }

    // ==================================================================
    // Derived values
    // ==================================================================

    /// @notice N_a = B_a - W_a: assets owned by outstanding shares, including committed capacity Q_a.
    /// @dev Same as the vault's `_netAssets`. The subtraction cannot underflow while the vault maintains
    ///      W_a <= B_a.
    /// @param vault Vault to read.
    /// @param currency asset0 or asset1. Any other currency returns 0.
    /// @return Raw units of `currency`.
    function netAssets(IVaultState vault, Currency currency) public view returns (uint256) {
        return backing(vault, currency) - claimableAssets(vault, currency);
    }

    /// @notice F_a = B_a - W_a - Q_a: inventory that can be paid out now without breaking a live commitment or
    ///         touching assets owed to finalized requests.
    /// @dev Cannot underflow while the vault maintains Q_a + W_a <= B_a.
    /// @param vault Vault to read.
    /// @param currency asset0 or asset1. Any other currency returns 0.
    /// @return Raw units of `currency`.
    function freeInventory(IVaultState vault, Currency currency) external view returns (uint256) {
        return netAssets(vault, currency) - reserved(vault, currency);
    }

    /// @notice D_a = ceil(P * N_a / S): what the pending queue would be owed in `currency` if it were finalized now.
    /// @dev Same as the vault's `_pendingDemand`, which `reserveFor` uses. Rounded up so the capacity protected for
    ///      the queue is never less than its exact pro-rata share. Example: P = 300, S = 1,000 and N_a = 1,001 give
    ///      ceil(300.3) = 301. P > 0 implies S >= P > 0, so the division is safe.
    /// @param vault Vault to read.
    /// @param currency Asset to evaluate.
    /// @return Raw units of `currency`, or 0 when nothing is pending.
    function pendingDemand(IVaultState vault, Currency currency) public view returns (uint256) {
        uint256 p = vault.pendingShares();
        if (p == 0) return 0;
        return FullMath.mulDivRoundingUp(p, netAssets(vault, currency), totalShares(vault));
    }

    /// @notice Largest new allocation of `currency` the admission rule accepts right now: N_a - Q_a - R_a - D_a,
    ///         or 0 if that is negative.
    /// @dev Same as the vault's `_admissible(currency, _eligibleBacking(currency))`, the limit `reserveFor`
    ///      enforces. Example: N_a = 1,000, Q_a = 300, R_a = 100 and D_a = 150 give 450. This does not include the
    ///      curator's own ceiling or the exposure caps, which `reserveFor` checks separately.
    ///
    ///      Computed as max(0, max(0, E_a - Q_a) - R_a) with E_a = N_a - D_a (exact, since D_a <= N_a). Each term
    ///      is subtracted in turn with a floor at zero instead of summing Q_a + R_a + D_a first: R_a is an admin
    ///      input with no upper bound (the guardian may raise it to type(uint256).max to stop new allocations in
    ///      this asset), so the sum could overflow. Because every term is non-negative, the floored chain equals
    ///      max(0, N - D - Q - R) exactly: once an intermediate result reaches zero, the exact value is already
    ///      <= 0.
    /// @param vault Vault to read.
    /// @param currency Asset the allocation would sell.
    /// @return Raw units of `currency`.
    function admissibleCapacity(IVaultState vault, Currency currency) external view returns (uint256) {
        return _sub0(_sub0(eligibleBacking(vault, currency), reserved(vault, currency)), bufferFloor(vault, currency));
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
        uint256 supply = totalShares(vault);
        if (supply == 0) return 0;
        cap = type(uint256).max;
        Currency a0 = vault.asset0();
        uint256 n0 = netAssets(vault, a0);
        if (n0 != 0) cap = FullMath.mulDiv(n0 - reserved(vault, a0), supply, n0);
        Currency a1 = vault.asset1();
        uint256 n1 = netAssets(vault, a1);
        if (n1 != 0) {
            uint256 c1 = FullMath.mulDiv(n1 - reserved(vault, a1), supply, n1);
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
        uint256 supply = totalShares(vault);
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
        uint256 supply = totalShares(vault);
        if (supply == 0) return (0, 0);
        amount0 = FullMath.mulDiv(shares, netAssets(vault, vault.asset0()), supply);
        amount1 = FullMath.mulDiv(shares, netAssets(vault, vault.asset1()), supply);
    }

    /// @notice Price floor that `exchange` would apply to this allocation right now: max(stored vault floor, curator
    ///         floor, dynamic floor in adapter mode).
    /// @dev Same as the price part of the vault's `_floorForFill`. Reverts in the same policy cases as `exchange`:
    ///      `PriceFloorNotConfigured` in static mode if the direction was never opened (also for an unknown id, whose
    ///      stored currency is address(0)), `DirectionHalted` while the direction is halted, and in adapter mode
    ///      whatever the adapter reverts with, `InvalidReference` or `UncertaintyTooHigh`. It does not apply the
    ///      inventory floor, which depends on the fill size (see `inventoryRoom`), and does not check that the
    ///      allocation is live; `getAllocation` shows `released` and `expiry`.
    /// @param vault Vault to read.
    /// @param allocationId Allocation to inspect.
    /// @return floor Effective floor, Q64.96 raw input per raw output.
    function effectiveFloorX96(IVaultState vault, uint256 allocationId) external view returns (uint256 floor) {
        ISharedCommitmentVault.Allocation memory a = getAllocation(vault, allocationId);
        (uint160 vaultFloor, bool halted) = sellPolicy(vault, a.currencyOut);
        IMarketRiskAdapter adapter = riskAdapter(vault);
        if (vaultFloor == 0) {
            if (address(adapter) == address(0)) revert ISharedCommitmentVault.PriceFloorNotConfigured(a.currencyOut);
            vaultFloor = 1;
        }
        if (halted) revert ISharedCommitmentVault.DirectionHalted(a.currencyOut);
        floor = a.minInPerOutX96 > vaultFloor ? a.minInPerOutX96 : vaultFloor;
        if (address(adapter) != address(0)) {
            IMarketRiskAdapter.Reading memory r = adapter.currentReference();
            if (r.priceX96 == 0 || r.validUntil < block.timestamp) revert ISharedCommitmentVault.InvalidReference();
            VaultRiskBoundary.checkUncertainty(r.uncertaintyPips, maxUncertaintyPips(vault));
            (uint256 f0, uint256 f1) =
                VaultRiskBoundary.dynamicFloors(r.priceX96, r.uncertaintyPips, riskEdgePips(vault));
            uint256 dynamicFloor = a.currencyOut == vault.asset1() ? f1 : f0;
            if (dynamicFloor > floor) floor = dynamicFloor;
        }
    }

    /// @notice How much of `currency` fills may still pay out before the inventory floor binds: N_a - L_a, or 0.
    /// @dev L_a = ceil(S * tau_a * (1e6 - kappa_a) / (1e18 * 1e6)), the vault's own formula. Returns N_a when no target
    ///      is set for the asset (no inventory floor; in adapter mode the vault then refuses fills of it entirely).
    ///      Other limits (allocation quota, flow caps) may bind first.
    /// @param vault Vault to read.
    /// @param currency asset0 or asset1.
    /// @return Raw units of `currency`.
    function inventoryRoom(IVaultState vault, Currency currency) external view returns (uint256) {
        uint256 i = currency == vault.asset1() ? 1 : 0;
        uint256 n = netAssets(vault, currency);
        uint256 target = inventoryTargetPerShare(vault, i);
        if (target == 0) return n;
        uint256 floor_ = VaultRiskBoundary.inventoryFloor(totalShares(vault), target, inventoryTolerancePips(vault, i));
        return n > floor_ ? n - floor_ : 0;
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
        ISharedCommitmentVault.WithdrawalRequest memory r = getRequest(vault, requestId);
        if (r.lp == address(0)) return ISharedCommitmentVault.RequestStatus.None;
        if (r.sharesPending != 0) return ISharedCommitmentVault.RequestStatus.Pending;
        if (r.claimable0 != 0 || r.claimable1 != 0) return ISharedCommitmentVault.RequestStatus.Claimable;
        return
            r.canceled ? ISharedCommitmentVault.RequestStatus.Canceled : ISharedCommitmentVault.RequestStatus.Completed;
    }

    /// @notice E_a = N_a - D_a: the backing exposure caps are measured against. Excludes assets owed to finalized
    ///         requests (through N_a) and the queue's pro-rata claim D_a.
    /// @dev Same as the value `reserveFor` computes. D_a <= N_a, so this cannot underflow.
    /// @param vault Vault to read.
    /// @param currency Asset to evaluate.
    /// @return Raw units of `currency`.
    function eligibleBacking(IVaultState vault, Currency currency) public view returns (uint256) {
        return netAssets(vault, currency) - pendingDemand(vault, currency);
    }

    /// @notice Gross output already paid under one scope in the current flow window.
    /// @dev The stored usage counts only if it belongs to the current window, block.timestamp / FLOW_WINDOW;
    ///      usage stored for an earlier window is zero now. This is exactly the value `exchange` starts from.
    /// @param vault Vault to read.
    /// @param scope Hook, Curator or Vault.
    /// @param account The hook or curator; address(0) for the vault scope.
    /// @param currency Asset paid out.
    /// @return Raw units of `currency`.
    function flowUsed(IVaultState vault, ISharedCommitmentVault.RiskScope scope, address account, Currency currency)
        public
        view
        returns (uint256)
    {
        ISharedCommitmentVault.RiskLimit memory l = getRiskLimit(vault, scope, account, currency);
        return l.epoch == block.timestamp / vault.FLOW_WINDOW() ? l.flowUsed : 0;
    }

    /// @notice Most output one scope may still pay in the current window: max(0, flowCap - used), and 0 for an
    ///         unconfigured record (which `exchange` refuses outright).
    /// @dev A single `exchange` is limited by the minimum of this value over its hook, its curator and the vault.
    /// @param vault Vault to read.
    /// @param scope Hook, Curator or Vault.
    /// @param account The hook or curator; address(0) for the vault scope.
    /// @param currency Asset paid out.
    /// @return Raw units of `currency`.
    function flowAvailable(
        IVaultState vault,
        ISharedCommitmentVault.RiskScope scope,
        address account,
        Currency currency
    ) external view returns (uint256) {
        ISharedCommitmentVault.RiskLimit memory l = getRiskLimit(vault, scope, account, currency);
        if (!l.configured) return 0;
        uint256 used = flowUsed(vault, scope, account, currency);
        return l.flowCap > used ? l.flowCap - used : 0;
    }

    /// @notice Largest new allocation one scope's exposure cap accepts right now:
    ///         max(0, floor(maxReservedBps * E_a / 10,000) - held), and 0 for an unconfigured record.
    /// @dev `held` is hookReserved, curatorReserved or Q_a for the Hook, Curator and Vault scopes. `reserveFor` also
    ///      applies the admission rule, the curator ceiling and the other two scopes' caps.
    /// @param vault Vault to read.
    /// @param scope Hook, Curator or Vault.
    /// @param account The hook or curator; address(0) for the vault scope.
    /// @param currency Asset the allocation would sell.
    /// @return Raw units of `currency`.
    function exposureAvailable(
        IVaultState vault,
        ISharedCommitmentVault.RiskScope scope,
        address account,
        Currency currency
    ) external view returns (uint256) {
        ISharedCommitmentVault.RiskLimit memory l = getRiskLimit(vault, scope, account, currency);
        if (!l.configured) return 0;
        uint256 held = scope == ISharedCommitmentVault.RiskScope.Hook
            ? hookReserved(vault, account, currency)
            : scope == ISharedCommitmentVault.RiskScope.Curator
                ? curatorReserved(vault, account, currency)
                : reserved(vault, currency);
        uint256 limit = uint256(l.maxReservedBps) * eligibleBacking(vault, currency) / 10_000;
        return limit > held ? limit - held : 0;
    }

    // ==================================================================
    // Internal
    // ==================================================================

    /// @dev a - b, or 0 if b > a; the vault's `_sub0`.
    function _sub0(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }
}
