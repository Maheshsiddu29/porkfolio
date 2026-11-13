// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title ReservationBondModel
/// @notice TEST-ONLY reference model of the reservation-bond accounting proposed in
///         docs/architecture/FUTURE_CAPITAL_AND_YIELD_ACCOUNTING.md §2. Nothing here is implemented in `src/`, holds
///         tokens, or is meant to be deployed. It exists so the proposed equations can be checked with exact integers
///         before any production design is chosen.
/// @dev One vault, one sold asset `a` (whose reservations are modelled) and one fee asset `f`, which the proposal
///      requires to be one of the pair's two assets. The model keeps three ledgers apart:
///        vault ledger    netSold = N_a and reserved = Q_a of the sold asset; lpFees = fees moved into N_f;
///        escrow ledger   escrow = everything posted as bonds and not yet moved to the vault: unearned bond
///                        collateral, protocol fees not yet claimed, and refunds not yet claimed;
///        share ledger    `shares` and the LP-owned fee-asset balance `lpNet`, used only by the attribution tests.
///      Admission reads only the vault ledger, so a bond can never be counted as backing (§2.6 of the design note).
///
///      Fee rule. A reservation of A raw units created at t_c, expiring at t_1, at rate rho (fee raw units per
///      reserved raw unit per second, WAD) accrues on its unused remainder r(t) only:
///          I(t) = integral of r(u) du over [t_c, min(t, t_1, t_close)]    (raw unit-seconds, exact integer)
///      Fees earned so far: floor(I * rho / WAD). Final charge at settlement: ceil(max(I, I_min) * rho / WAD), where
///      I_min = A * min(T_min, t_1 - t_c) is the minimum charge. Bond posted at creation: ceil(A * (t_1 - t_c) * rho /
///      WAD), the largest possible charge, so the refund bond - charge is never negative.
///      Split. The protocol's cumulative part is floor(charged so far * pi / 10,000); the LPs get the rest. Both are
///      computed on cumulative totals, so the result does not depend on how many checkpoints happened.
contract ReservationBondModel {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    /// @param payer Posted the bond; the only address refunds are credited to.
    /// @param amount A, raw units of the sold asset.
    /// @param remaining r, unused reserved units; zero once closed.
    /// @param created t_c, seconds; accrual starts here because Q rises here.
    /// @param expiry t_1, seconds; accrual never runs past it, however late the release.
    /// @param lastAccrual Time up to which `unitSeconds` is computed.
    /// @param closed Remaining capacity returned (consumed, released or expired and released).
    /// @param settled Final charge and refund computed; terminal.
    /// @param rateWad rho, fee raw units per reserved raw unit per second, scaled by 1e18.
    /// @param unitSeconds I, raw unit-seconds accrued so far.
    /// @param minUnitSeconds I_min.
    /// @param bond Fee asset escrowed at creation.
    /// @param realized Fee already moved out of the bond (LP part plus protocol part).
    /// @param protocolRealized The protocol's part of `realized`.
    struct Reservation {
        address payer;
        uint128 amount;
        uint128 remaining;
        uint64 created;
        uint64 expiry;
        uint64 lastAccrual;
        bool closed;
        bool settled;
        uint256 rateWad;
        uint256 unitSeconds;
        uint256 minUnitSeconds;
        uint256 bond;
        uint256 realized;
        uint256 protocolRealized;
    }

    error InsufficientBacking(uint256 amount, uint256 admissible);
    error NotPayer();
    error NotExpired();
    error Closed();
    error AlreadySettled();
    error QuotaExceeded();
    error Expired();

    uint256 public immutable protocolBps;
    uint256 public immutable minDuration;

    uint256 public netSold;
    uint256 public reserved;
    uint256 public lpFees;
    uint256 public escrow;
    uint256 public protocolFees;
    uint256 public bondsPosted;
    mapping(address => uint256) public refundOwed;
    Reservation[] internal _r;

    uint256 public shares;
    uint256 public lpNet;

    constructor(uint256 netSold_, uint256 protocolBps_, uint256 minDuration_) {
        netSold = netSold_;
        protocolBps = protocolBps_;
        minDuration = minDuration_;
    }

    function get(uint256 id) external view returns (Reservation memory) {
        return _r[id];
    }

    function count() external view returns (uint256) {
        return _r.length;
    }

    /// @notice Largest admissible reservation: N_a - Q_a. The escrow is not read.
    function admissible() public view returns (uint256) {
        return netSold > reserved ? netSold - reserved : 0;
    }

    /// @notice Bond for a reservation created now: the largest possible charge.
    function bondFor(uint256 amount, uint256 duration, uint256 rateWad) public pure returns (uint256) {
        return FullMath.mulDivRoundingUp(amount * duration, rateWad, WAD);
    }

    function create(address payer, uint128 amount, uint64 expiry, uint256 rateWad, uint64 now_)
        external
        returns (uint256 id)
    {
        uint256 adm = admissible();
        if (amount > adm) revert InsufficientBacking(amount, adm);
        uint256 duration = expiry - now_;
        uint256 bond = bondFor(amount, duration, rateWad);
        uint256 minDur = minDuration < duration ? minDuration : duration;
        reserved += amount;
        escrow += bond;
        bondsPosted += bond;
        id = _r.length;
        _r.push(
            Reservation({
                payer: payer,
                amount: amount,
                remaining: amount,
                created: now_,
                expiry: expiry,
                lastAccrual: now_,
                closed: false,
                settled: false,
                rateWad: rateWad,
                unitSeconds: 0,
                minUnitSeconds: uint256(amount) * minDur,
                bond: bond,
                realized: 0,
                protocolRealized: 0
            })
        );
    }

    /// @dev I += r * (t - lastAccrual), with t clipped to the expiry. A closed reservation has r = 0.
    function _accrue(Reservation storage r, uint64 now_) internal {
        uint64 t = now_ < r.expiry ? now_ : r.expiry;
        if (t > r.lastAccrual) {
            r.unitSeconds += uint256(r.remaining) * (t - r.lastAccrual);
            r.lastAccrual = t;
        }
    }

    /// @notice A hook sells `x` units under reservation `id`. Lowers r, Q_a and N_a together, as `exchange` does.
    function consume(uint256 id, uint128 x, uint64 now_) external {
        Reservation storage r = _r[id];
        if (r.closed) revert Closed();
        if (now_ >= r.expiry) revert Expired();
        if (x > r.remaining) revert QuotaExceeded();
        _accrue(r, now_);
        r.remaining -= x;
        reserved -= x;
        netSold -= x;
        if (r.remaining == 0) r.closed = true;
    }

    /// @notice Return the unused remainder. Early: only the payer. After expiry: anyone.
    function release(uint256 id, address caller, uint64 now_) public {
        Reservation storage r = _r[id];
        if (r.closed) revert Closed();
        if (now_ < r.expiry && caller != r.payer) revert NotPayer();
        _accrue(r, now_);
        reserved -= r.remaining;
        r.remaining = 0;
        r.closed = true;
    }

    /// @notice Return `x` of the unused remainder before expiry, keeping the rest reserved. Only the payer. Accrual on the
    ///         returned units stops now; the remainder keeps accruing.
    function releasePartial(uint256 id, uint128 x, address caller, uint64 now_) external {
        Reservation storage r = _r[id];
        if (r.closed) revert Closed();
        if (caller != r.payer) revert NotPayer();
        if (now_ >= r.expiry) revert Expired();
        if (x > r.remaining) revert QuotaExceeded();
        _accrue(r, now_);
        r.remaining -= x;
        reserved -= x;
        if (r.remaining == 0) r.closed = true;
    }

    /// @dev Moves fee from escrow to the vault and the protocol bucket so that the cumulative charge equals `target`.
    function _realizeTo(Reservation storage r, uint256 target) internal {
        if (target <= r.realized) return;
        uint256 step = target - r.realized;
        uint256 protocolCum = target * protocolBps / BPS;
        uint256 protocolStep = protocolCum - r.protocolRealized;
        uint256 lpStep = step - protocolStep;
        r.realized = target;
        r.protocolRealized = protocolCum;
        protocolFees += protocolStep; // stays in escrow until claimed
        escrow -= lpStep; // leaves escrow, enters the vault
        lpFees += lpStep;
        lpNet += lpStep;
    }

    /// @notice Permissionless: move fees earned so far into the vault. Rounds down.
    function checkpoint(uint256 id, uint64 now_) public {
        Reservation storage r = _r[id];
        if (r.settled) revert AlreadySettled();
        _accrue(r, now_);
        _realizeTo(r, FullMath.mulDiv(r.unitSeconds, r.rateWad, WAD));
    }

    /// @notice Final charge and refund. Permissionless once closed or expired; the refund is credited to the payer,
    ///         never to the caller, and is claimed separately so a payer that cannot receive cannot block settlement.
    function settle(uint256 id, uint64 now_) external {
        Reservation storage r = _r[id];
        if (r.settled) revert AlreadySettled();
        if (!r.closed) {
            if (now_ < r.expiry) revert NotExpired();
            release(id, address(0), now_);
        }
        _accrue(r, now_);
        uint256 billable = r.unitSeconds > r.minUnitSeconds ? r.unitSeconds : r.minUnitSeconds;
        uint256 charge = FullMath.mulDivRoundingUp(billable, r.rateWad, WAD);
        _realizeTo(r, charge);
        r.settled = true;
        refundOwed[r.payer] += r.bond - r.realized;
    }

    function claimRefund(address payer) external returns (uint256 amount) {
        amount = refundOwed[payer];
        refundOwed[payer] = 0;
        escrow -= amount;
    }

    function claimProtocol() external returns (uint256 amount) {
        amount = protocolFees;
        protocolFees = 0;
        escrow -= amount;
    }

    // ------------------------------------------------------------------
    // Share attribution (fee asset only)
    // ------------------------------------------------------------------

    function seedShares(uint256 shares_, uint256 lpNet_) external {
        shares = shares_;
        lpNet = lpNet_;
    }

    /// @notice Deposit at ceil(s * lpNet / S), as the vault prices deposits.
    function deposit(uint256 s) external returns (uint256 paid) {
        paid = FullMath.mulDivRoundingUp(s, lpNet, shares);
        lpNet += paid;
        shares += s;
    }

    /// @notice Redeem at floor(s * lpNet / S), as the vault prices redemptions.
    function redeem(uint256 s) external returns (uint256 got) {
        got = FullMath.mulDiv(s, lpNet, shares);
        lpNet -= got;
        shares -= s;
    }
}
