// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ISharedCommitmentVault} from "../interfaces/ISharedCommitmentVault.sol";
import {IVaultState} from "../interfaces/IVaultState.sol";
import {IMarketRiskAdapter} from "../interfaces/IMarketRiskAdapter.sol";

/// @title VaultStateReader
/// @notice Decodes `SharedCommitmentVault`'s stored accounting from raw storage words read with the vault's
///         `extsload(slot)`. `VaultLens` serves these reads as external functions; scripts and other contracts can
///         call this library directly, without a deployed lens.
/// @dev The slot numbers and packed offsets below mirror the vault's storage layout, which is fixed by the
///      declaration order of its state variables. `test/unit/VaultStorageLayout.t.sol` pins every one of them
///      against the compiled vault, so a layout change in the vault fails that test instead of making these reads
///      silently wrong.
///
///      Solidity's layout rules used here: the value of `mapping[k]` declared at slot p lives at
///      keccak256(abi.encode(k, p)), with value-type keys (address, Currency, uint256, bytes32) ABI-encoded as one
///      left-padded word; a nested mapping applies the rule twice, outer key first; a struct occupies consecutive
///      slots from its base slot, with members smaller than 32 bytes packed into one slot from the low-order end in
///      declaration order; a fixed-size array starts at its declared slot, one element per slot for 32-byte types
///      and packed from the low-order end for smaller ones.
///
///      Trust model. Every function reads whatever storage the `vault` argument holds at these slot numbers. Pointed
///      at a contract other than the vault, the results are meaningless. Nothing here writes state.
library VaultStateReader {
    // Storage slots of the vault's state variables. Slots 0-4, 15, 22 and 23 hold values the vault serves itself
    // (`owner`, `paused`, `pendingOwner`, `guardian`, `isConsumer`, curator records, `pendingShares`, `authModule`,
    // retired modules) and are not decoded here.

    /// @dev `curatorCeiling`: mapping(address curator => mapping(Currency => uint256)).
    uint256 internal constant CURATOR_CEILING_SLOT = 5;
    /// @dev `curatorReserved`: mapping(address curator => mapping(Currency => uint256)).
    uint256 internal constant CURATOR_RESERVED_SLOT = 6;
    /// @dev `backing` (B_a): mapping(Currency => uint256).
    uint256 internal constant BACKING_SLOT = 7;
    /// @dev `reserved` (Q_a): mapping(Currency => uint256).
    uint256 internal constant RESERVED_SLOT = 8;
    /// @dev `bufferFloor` (R_a): mapping(Currency => uint256).
    uint256 internal constant BUFFER_FLOOR_SLOT = 9;
    /// @dev `sellPolicy`: mapping(Currency => SellPolicy); one slot per entry, `minInPerOutX96` in bits 0-159,
    ///      `halted` in byte 20.
    uint256 internal constant SELL_POLICY_SLOT = 10;
    /// @dev `claimableAssets` (W_a): mapping(Currency => uint256).
    uint256 internal constant CLAIMABLE_ASSETS_SLOT = 11;
    /// @dev `_allocations`: mapping(uint256 => Allocation); seven slots per entry, see `getAllocation`.
    uint256 internal constant ALLOCATIONS_SLOT = 12;
    /// @dev `nextAllocationId`: uint256.
    uint256 internal constant NEXT_ALLOCATION_ID_SLOT = 13;
    /// @dev `totalShares` (S): uint256.
    uint256 internal constant TOTAL_SHARES_SLOT = 14;
    /// @dev `sharesOf`: mapping(address => uint256).
    uint256 internal constant SHARES_OF_SLOT = 16;
    /// @dev `_requests`: mapping(uint256 => WithdrawalRequest); four slots per entry, see `getRequest`.
    uint256 internal constant REQUESTS_SLOT = 17;
    /// @dev `nextRequestId`: uint256.
    uint256 internal constant NEXT_REQUEST_ID_SLOT = 18;
    /// @dev `queueHead`: uint256.
    uint256 internal constant QUEUE_HEAD_SLOT = 19;
    /// @dev `hookReserved`: mapping(address consumer => mapping(Currency => uint256)).
    uint256 internal constant HOOK_RESERVED_SLOT = 20;
    /// @dev `_riskLimits`: mapping(bytes32 => RiskLimit), keyed by keccak256(abi.encode(scope, account, currency));
    ///      two slots per entry, see `getRiskLimit`.
    uint256 internal constant RISK_LIMITS_SLOT = 21;
    /// @dev `riskAdapter` in bits 0-159, `riskEdgePips` (uint24) in bytes 20-22, `maxUncertaintyPips` (uint24) in
    ///      bytes 23-25.
    uint256 internal constant RISK_PARAMS_SLOT = 24;
    /// @dev `inventoryTargetPerShare`: uint256[2] in slots 25 and 26.
    uint256 internal constant INVENTORY_TARGET_SLOT = 25;
    /// @dev `inventoryTolerancePips`: uint24[2] packed in slot 27, element i in bytes 3i to 3i + 2.
    uint256 internal constant INVENTORY_TOLERANCE_SLOT = 27;

    // The narrowing casts below extract packed fields from a storage word: truncating to the field's width (after
    // shifting it to bit 0) is the decoding, exactly as the compiler's own getter does.
    // forge-lint: disable-start(unsafe-typecast)

    /// @dev B_a, raw units of `currency`; 0 for a currency outside the pair.
    function backing(IVaultState vault, Currency currency) internal view returns (uint256) {
        return uint256(vault.extsload(_mapSlot(Currency.unwrap(currency), BACKING_SLOT)));
    }

    /// @dev Q_a, raw units of `currency`.
    function reserved(IVaultState vault, Currency currency) internal view returns (uint256) {
        return uint256(vault.extsload(_mapSlot(Currency.unwrap(currency), RESERVED_SLOT)));
    }

    /// @dev R_a, raw units of `currency`.
    function bufferFloor(IVaultState vault, Currency currency) internal view returns (uint256) {
        return uint256(vault.extsload(_mapSlot(Currency.unwrap(currency), BUFFER_FLOOR_SLOT)));
    }

    /// @dev W_a, raw units of `currency`.
    function claimableAssets(IVaultState vault, Currency currency) internal view returns (uint256) {
        return uint256(vault.extsload(_mapSlot(Currency.unwrap(currency), CLAIMABLE_ASSETS_SLOT)));
    }

    /// @dev Vault floor (Q64.96 raw input per raw output; 0 = never opened) and halt flag for selling `currencyOut`.
    function sellPolicy(IVaultState vault, Currency currencyOut)
        internal
        view
        returns (uint160 minInPerOutX96, bool halted)
    {
        uint256 w = uint256(vault.extsload(_mapSlot(Currency.unwrap(currencyOut), SELL_POLICY_SLOT)));
        minInPerOutX96 = uint160(w);
        halted = (w >> 160) & 0xff != 0;
    }

    /// @dev Curator ceiling in `currency`, raw units.
    function curatorCeiling(IVaultState vault, address curator, Currency currency) internal view returns (uint256) {
        return uint256(vault.extsload(_nestedSlot(curator, currency, CURATOR_CEILING_SLOT)));
    }

    /// @dev Unused capacity held by a curator's unreleased allocations in `currency`, raw units.
    function curatorReserved(IVaultState vault, address curator, Currency currency) internal view returns (uint256) {
        return uint256(vault.extsload(_nestedSlot(curator, currency, CURATOR_RESERVED_SLOT)));
    }

    /// @dev Unused capacity held by a hook's unreleased allocations in `currency`, raw units.
    function hookReserved(IVaultState vault, address consumer, Currency currency) internal view returns (uint256) {
        return uint256(vault.extsload(_nestedSlot(consumer, currency, HOOK_RESERVED_SLOT)));
    }

    /// @dev S, shares.
    function totalShares(IVaultState vault) internal view returns (uint256) {
        return uint256(vault.extsload(bytes32(TOTAL_SHARES_SLOT)));
    }

    /// @dev Free (not escrowed) shares of `account`.
    function sharesOf(IVaultState vault, address account) internal view returns (uint256) {
        return uint256(vault.extsload(_mapSlot(account, SHARES_OF_SLOT)));
    }

    /// @dev Id the next allocation will receive.
    function nextAllocationId(IVaultState vault) internal view returns (uint256) {
        return uint256(vault.extsload(bytes32(NEXT_ALLOCATION_ID_SLOT)));
    }

    /// @dev Id the next queued redemption will receive.
    function nextRequestId(IVaultState vault) internal view returns (uint256) {
        return uint256(vault.extsload(bytes32(NEXT_REQUEST_ID_SLOT)));
    }

    /// @dev Lowest request id that may still hold pending shares.
    function queueHead(IVaultState vault) internal view returns (uint256) {
        return uint256(vault.extsload(bytes32(QUEUE_HEAD_SLOT)));
    }

    /// @dev Installed market-risk adapter; zero in static mode.
    function riskAdapter(IVaultState vault) internal view returns (IMarketRiskAdapter) {
        return IMarketRiskAdapter(address(uint160(uint256(vault.extsload(bytes32(RISK_PARAMS_SLOT))))));
    }

    /// @dev Vault edge e, pips.
    function riskEdgePips(IVaultState vault) internal view returns (uint24) {
        return uint24(uint256(vault.extsload(bytes32(RISK_PARAMS_SLOT))) >> 160);
    }

    /// @dev Largest accepted adapter uncertainty, pips.
    function maxUncertaintyPips(IVaultState vault) internal view returns (uint24) {
        return uint24(uint256(vault.extsload(bytes32(RISK_PARAMS_SLOT))) >> 184);
    }

    /// @dev tau of asset `index` (0 or 1), raw units per share scaled by 1e18. Reverts with Solidity's
    ///      out-of-bounds panic (0x32) for `index` > 1, as a public array getter does.
    function inventoryTargetPerShare(IVaultState vault, uint256 index) internal view returns (uint256) {
        uint256[2] memory slots = [INVENTORY_TARGET_SLOT, INVENTORY_TARGET_SLOT + 1];
        return uint256(vault.extsload(bytes32(slots[index])));
    }

    /// @dev kappa of asset `index` (0 or 1), pips of the target. Reverts with Solidity's out-of-bounds panic (0x32)
    ///      for `index` > 1, as a public array getter does.
    function inventoryTolerancePips(IVaultState vault, uint256 index) internal view returns (uint24) {
        uint256[2] memory shifts = [uint256(0), 24];
        return uint24(uint256(vault.extsload(bytes32(INVENTORY_TOLERANCE_SLOT))) >> shifts[index]);
    }

    /// @dev Allocation record; all-zero for an unknown id. From the entry's base slot
    ///      b = keccak256(abi.encode(allocationId, 12)): b `curator`; b+1 `consumer` (bits 0-159), `expiry` (uint64,
    ///      bytes 20-27), `released` (byte 28); b+2 `poolId`; b+3 `currencyIn`; b+4 `currencyOut`; b+5 `maxOut`
    ///      (low 128 bits), `consumed` (high 128 bits); b+6 `minInPerOutX96` (bits 0-159).
    function getAllocation(IVaultState vault, uint256 allocationId)
        internal
        view
        returns (ISharedCommitmentVault.Allocation memory a)
    {
        uint256 b = uint256(_mapSlot(bytes32(allocationId), ALLOCATIONS_SLOT));
        a.curator = address(uint160(uint256(vault.extsload(bytes32(b)))));
        uint256 w = uint256(vault.extsload(bytes32(b + 1)));
        a.consumer = address(uint160(w));
        a.expiry = uint64(w >> 160);
        a.released = (w >> 224) & 0xff != 0;
        a.poolId = PoolId.wrap(vault.extsload(bytes32(b + 2)));
        a.currencyIn = Currency.wrap(address(uint160(uint256(vault.extsload(bytes32(b + 3))))));
        a.currencyOut = Currency.wrap(address(uint160(uint256(vault.extsload(bytes32(b + 4))))));
        w = uint256(vault.extsload(bytes32(b + 5)));
        a.maxOut = uint128(w);
        a.consumed = uint128(w >> 128);
        a.minInPerOutX96 = uint160(uint256(vault.extsload(bytes32(b + 6))));
    }

    /// @dev Withdrawal request record; all-zero for an unknown id. From the entry's base slot
    ///      b = keccak256(abi.encode(requestId, 17)): b `lp` (bits 0-159), `canceled` (byte 20); b+1 `receiver`;
    ///      b+2 `sharesRequested` (low 128 bits), `sharesPending` (high 128 bits); b+3 `claimable0` (low 128 bits),
    ///      `claimable1` (high 128 bits).
    function getRequest(IVaultState vault, uint256 requestId)
        internal
        view
        returns (ISharedCommitmentVault.WithdrawalRequest memory r)
    {
        uint256 b = uint256(_mapSlot(bytes32(requestId), REQUESTS_SLOT));
        uint256 w = uint256(vault.extsload(bytes32(b)));
        r.lp = address(uint160(w));
        r.canceled = (w >> 160) & 0xff != 0;
        r.receiver = address(uint160(uint256(vault.extsload(bytes32(b + 1)))));
        w = uint256(vault.extsload(bytes32(b + 2)));
        r.sharesRequested = uint128(w);
        r.sharesPending = uint128(w >> 128);
        w = uint256(vault.extsload(bytes32(b + 3)));
        r.claimable0 = uint128(w);
        r.claimable1 = uint128(w >> 128);
    }

    /// @dev Risk-limit record of one scope in one asset; all-zero if never configured. `flowUsed` belongs to window
    ///      `epoch` and is not reset in storage when the window ends. From the entry's base slot
    ///      b = keccak256(abi.encode(keccak256(abi.encode(scope, account, currency)), 21)): b `configured` (byte 0),
    ///      `epoch` (uint40, bytes 1-5), `flowCap` (uint104, bytes 6-18), `flowUsed` (uint104, bytes 19-31);
    ///      b+1 `maxReservedBps` (uint16, bytes 0-1).
    function getRiskLimit(IVaultState vault, ISharedCommitmentVault.RiskScope scope, address account, Currency currency)
        internal
        view
        returns (ISharedCommitmentVault.RiskLimit memory l)
    {
        uint256 b = uint256(_mapSlot(keccak256(abi.encode(scope, account, currency)), RISK_LIMITS_SLOT));
        uint256 w = uint256(vault.extsload(bytes32(b)));
        l.configured = w & 0xff != 0;
        l.epoch = uint40(w >> 8);
        l.flowCap = uint104(w >> 48);
        l.flowUsed = uint104(w >> 152);
        l.maxReservedBps = uint16(uint256(vault.extsload(bytes32(b + 1))));
    }

    // forge-lint: disable-end(unsafe-typecast)

    /// @dev Slot of `mapping[key]` for a mapping declared at `slot`.
    function _mapSlot(bytes32 key, uint256 slot) private pure returns (bytes32) {
        return keccak256(abi.encode(key, slot));
    }

    /// @dev Address-keyed overload of `_mapSlot`; an address key is encoded as the same left-padded word.
    function _mapSlot(address key, uint256 slot) private pure returns (bytes32) {
        return keccak256(abi.encode(key, slot));
    }

    /// @dev Slot of `mapping[outer][currency]` for a nested mapping declared at `slot`: the outer key is hashed with
    ///      the declared slot, the inner key with the result.
    function _nestedSlot(address outer, Currency currency, uint256 slot) private pure returns (bytes32) {
        return keccak256(abi.encode(currency, _mapSlot(outer, slot)));
    }
}
