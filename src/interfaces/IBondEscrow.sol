// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title IBondEscrow
/// @notice Entry points, records, errors and events of `BondEscrow`, which holds prepaid reservation bonds, charges
///         them for capacity reserved over time, refunds the unused part, and pays the earned LP part into its vault.
/// @dev Units used throughout: amounts are raw units of the reserved asset (the fee asset is always the asset the
///      reservation sells); a rate `rho` is fee units per reserved unit per second, scaled by 1e18 (1e9 is about 3.15%
///      a year); "rho-seconds" are reserved units * rho * seconds, unscaled, so they are exact integers and a fee in
///      raw units is rho-seconds / 1e18.
interface IBondEscrow {
    /// @notice One bond, keyed by the vault allocation it pays for.
    /// @param payer Account that paid the bond; its refund is credited to it.
    /// @param created Unix time of posting (the allocation's creation).
    /// @param minDuration Minimum charge duration in force at posting, seconds. Fixed for this bond.
    /// @param expiry The allocation's expiry, Unix time, an hour boundary. Accrual never runs past it.
    /// @param last Time up to which `accrued` has been computed.
    /// @param rate rho, fixed at posting.
    /// @param asset 0 for asset0, 1 for asset1: the reserved asset, in which the bond is held.
    /// @param closed True once a sync has seen the vault release the allocation; accrual stopped then.
    /// @param settled True once settled; terminal.
    /// @param amount A: the allocation's maxOut, raw units.
    /// @param synced Consumption of the allocation the escrow has seen, raw units.
    /// @param remaining Remainder the bond accrues on: amount - synced while open, 0 once closed.
    /// @param bond Y: the prepaid bond, raw units.
    /// @param accrued Sum of remaining * rate * dt up to `last`, rho-seconds.
    /// @param charge Final charge, raw units; set at settlement.
    struct Bond {
        address payer;
        uint64 created;
        uint32 minDuration;
        uint64 expiry;
        uint64 last;
        uint64 rate;
        uint8 asset;
        bool closed;
        bool settled;
        uint128 amount;
        uint128 synced;
        uint128 remaining;
        uint128 bond;
        uint256 accrued;
        uint128 charge;
    }

    /// @notice Aggregate accounting of one asset.
    /// @param rate Sum of remaining * rho over open bonds whose expiry the aggregate has not passed.
    /// @param accrued Sum of `accrued` over unsettled bonds, extended to `last`, rho-seconds.
    /// @param last Time up to which `accrued` is computed.
    /// @param settledCharges Sum of the final charges of settled bonds, raw units.
    /// @param realized Fees moved out of "earned": LP part paid to the vault plus protocol part credited, raw units.
    /// @param protocolOwed Protocol fees credited and not yet claimed, raw units.
    /// @param refundsOwed Refunds credited to payers and not yet claimed, raw units.
    /// @param openBonds Sum of the bonds of unsettled bonds, raw units.
    struct Ledger {
        uint256 rate;
        uint256 accrued;
        uint64 last;
        uint256 settledCharges;
        uint256 realized;
        uint256 protocolOwed;
        uint256 refundsOwed;
        uint256 openBonds;
    }

    /// @notice One slot of an asset's rate-drop ring: the rate that leaves the aggregate when `bucket` ends.
    /// @param bucket Tag: the bucket (expiry / 1 hour) the drop belongs to.
    /// @param amount Sum of remaining * rho of open bonds expiring at the end of `bucket`.
    struct RateDrop {
        uint64 bucket;
        uint192 amount;
    }

    /// @notice The caller is not the vault's authorization module.
    error NotAuthModule(address caller);
    /// @notice The caller is not the vault's owner.
    error NotOwner(address caller);
    /// @notice The caller is not the protocol fee recipient.
    error NotProtocolRecipient(address caller);
    /// @notice The vault's fee escrow is not this contract, so a bond posted here could never pay LPs.
    error EscrowNotInstalled();
    /// @notice The allocation is not the vault's newest, or is already consumed, released or expired.
    error AllocationNotFresh(uint256 allocationId);
    /// @notice The allocation already has a bond.
    error AlreadyBonded(uint256 allocationId);
    /// @notice No bond exists for this allocation.
    error UnknownBond(uint256 allocationId);
    /// @notice The bond is already settled.
    error AlreadySettled(uint256 allocationId);
    /// @notice The bond can be settled only once its allocation is released (and a sync has seen it) or expired.
    error NotSettleable(uint256 allocationId);
    /// @notice The current rate for the asset is above the maximum the curator signed.
    error RateAboveMax(uint256 rate, uint256 maxRate);
    /// @notice The bond would exceed 2^127 - 1 raw units, the PoolManager's limit.
    error BondTooLarge(uint256 bond);
    /// @notice The aggregate accrual of `currency` could not reach the current time within the step limit.
    error EscrowBehind(Currency currency);
    /// @notice Nothing is owed to the caller.
    error NothingToClaim();
    /// @notice A zero address where one is not allowed.
    error ZeroAddress();
    /// @notice The currency is not one of the vault's pair.
    error InvalidCurrency();
    /// @notice A parameter is above its bound.
    error InvalidParameter();
    /// @notice An entry point was called while another one is executing.
    error ReentrantCall();
    /// @notice `unlockCallback` was not called by the PoolManager.
    error NotPoolManager();
    /// @notice The PoolManager received a different amount of ERC-20 than the bond.
    error SettlementMismatch(uint256 expected, uint256 paid);

    /// @notice A bond of `bond` was posted by `payer` for allocation `allocationId` of `amount` reserved at `rate`.
    event BondPosted(
        uint256 indexed allocationId,
        address indexed payer,
        Currency indexed currency,
        uint256 amount,
        uint256 rate,
        uint256 bond
    );
    /// @notice A sync saw `synced` consumed in total; the bond now accrues on `remaining`; `closed` if released.
    event BondSynced(uint256 indexed allocationId, uint256 synced, uint256 remaining, bool closed);
    /// @notice The bond was settled: `charge` earned, `refund` credited to its payer.
    event BondSettled(uint256 indexed allocationId, uint256 charge, uint256 refund);
    /// @notice Earned fees of `currency` were realized: `lpAmount` paid into the vault, `protocolAmount` credited.
    event FeesRealized(Currency indexed currency, uint256 lpAmount, uint256 protocolAmount);
    /// @notice `payer` claimed its refunds to `to`.
    event RefundClaimed(address indexed payer, address indexed to, uint256 amount0, uint256 amount1);
    /// @notice The protocol recipient claimed its fees to `to`.
    event ProtocolClaimed(address indexed to, uint256 amount0, uint256 amount1);
    /// @notice The rate for new bonds of `currency` changed.
    event RateSet(Currency indexed currency, uint256 rate);
    /// @notice The minimum charge duration for new bonds changed (seconds).
    event MinChargeDurationSet(uint256 duration);
    /// @notice The protocol share of earned fees changed (basis points).
    event ProtocolFeeSet(uint256 bps);
    /// @notice The protocol fee recipient changed.
    event ProtocolRecipientSet(address recipient);

    /// @notice Record and fund the bond of a reservation created in this transaction.
    /// @param allocationId The vault allocation just created.
    /// @param payer Account the bond is pulled from (ERC-20 allowance to this escrow) and refunded to.
    /// @param maxRate Highest rate the curator accepted, 1e18-scaled per second.
    /// @return bond Y, raw units of the reserved asset.
    function post(uint256 allocationId, address payer, uint256 maxRate) external returns (uint256 bond);

    /// @notice Bring a bond up to date with its allocation in the vault: accrue to now, then stop accruing on the
    ///         consumption and the close the escrow has not seen yet.
    function sync(uint256 allocationId) external;

    /// @notice Settle a bond whose allocation is closed or expired: final charge, refund credited to the payer.
    /// @return charge Raw units earned.
    /// @return refund Raw units credited to the payer.
    function settle(uint256 allocationId) external returns (uint256 charge, uint256 refund);

    /// @notice Realize every fee earned so far in both assets; reverts with `EscrowBehind` if the accrual cannot be
    ///         brought to now within the deposit-path step limit.
    function realize() external;

    /// @notice Advance the accrual of each asset by at most `maxSteps` hourly buckets and realize what is earned up to
    ///         there.
    /// @return caughtUp True if both assets reached the current time.
    function realize(uint256 maxSteps) external returns (bool caughtUp);

    /// @notice Pay the caller's refunds in both assets to `to`.
    function claimRefund(address to) external returns (uint256 amount0, uint256 amount1);

    /// @notice Pay the protocol fees of both assets to `to`. Protocol recipient only.
    function claimProtocol(address to) external returns (uint256 amount0, uint256 amount1);

    /// @notice Fees of `currency` earned and not yet realized, as of this block (U_a), split as `realize` would split
    ///         them now: `lpPart` would enter the vault's backing, `protocolPart` would be credited to the protocol.
    function unrealized(Currency currency) external view returns (uint256 lpPart, uint256 protocolPart);
}
