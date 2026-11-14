// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title BondLedgerModel (test-only)
/// @notice Reference model of the PROPOSED V2 bond escrow (docs/architecture/G05_V2_ARCHITECTURE.md §4) for one
///         asset, which is both the reserved asset and the fee asset. It adds three things to `ReservationBondModel`:
///           1. aggregate accrual: the escrow realizes fees for all reservations at once, with the accrual rate
///              falling at each reservation's expiry bucket without a transaction;
///           2. lazy consumption: the escrow learns about consumption only when someone syncs a reservation, and
///              stops accrual on the consumed units from that moment, not from the moment of the fill;
///           3. LP attribution: `deposit` realizes before pricing; exits do not.
/// @dev Holds no tokens. Amounts are raw units; `rho` is fee units per reserved unit per second scaled by 1e18;
///      "rho-seconds" (I·rho) are kept unscaled, so they are exact integers. Every reservation's expiry is a bucket
///      end, so the aggregate rate and each reservation's own accrual stop at the same second.
contract BondLedgerModel {
    uint256 internal constant SCALE = 1e18;
    uint256 internal constant BPS = 10_000;

    error Misaligned();
    error NotClosable();
    error Settled();
    error Quota();

    struct Reservation {
        address payer;
        uint64 created;
        uint64 expiry;
        uint64 last; // accrual has been added up to here
        bool closed; // released before expiry
        bool settled;
        uint128 amount; // A
        uint128 synced; // consumption the escrow has seen
        uint128 vaultConsumed; // consumption that happened in the vault (the escrow cannot see this)
        uint128 r; // remainder the escrow accrues on: A - synced, or 0 once closed
        uint256 rho;
        uint256 bond;
        uint256 accrued; // sum of r * rho * dt, unscaled
        uint256 charge; // set at settlement
    }

    uint256 public immutable WIDTH;
    uint256 public immutable MIN_DURATION;
    uint256 public immutable PROTOCOL_BPS;

    Reservation[] internal _res;

    // Aggregate accrual.
    uint256 public rate; // sum of r * rho over reservations before their expiry
    mapping(uint256 bucket => uint256) public rateDrop; // falls out of `rate` at the bucket's end
    uint256 public aggLast;
    uint256 public aggAccrued; // sum of `accrued` over unsettled reservations, at aggLast

    // Money.
    uint256 public posted;
    uint256 public settledCharges;
    uint256 public realized; // LP part + protocol part moved out of "earned"
    uint256 public protocolCredited;
    uint256 public protocolPaid;
    uint256 public lpMoved; // fees paid into the vault's N
    mapping(address payer => uint256) public refundOwed;
    uint256 public refundsOwedTotal;
    uint256 public refundsPaid;

    // The vault side, reduced to one asset and the share supply.
    uint256 public vaultN;
    uint256 public shares;

    constructor(uint256 width, uint256 minDuration, uint256 protocolBps, uint256 seedN, uint256 seedShares) {
        WIDTH = width;
        MIN_DURATION = minDuration;
        PROTOCOL_BPS = protocolBps;
        aggLast = block.timestamp;
        vaultN = seedN;
        shares = seedShares;
    }

    function get(uint256 id) external view returns (Reservation memory) {
        return _res[id];
    }

    function count() external view returns (uint256) {
        return _res.length;
    }

    /// @notice Escrow balance: everything posted minus everything paid out.
    function escrow() public view returns (uint256) {
        return posted - lpMoved - refundsPaid - protocolPaid;
    }

    /// @notice Fees earned and not yet realized; they belong to no LP yet.
    function unrealized() external view returns (uint256) {
        return settledCharges + _aggAt(block.timestamp) / SCALE - realized;
    }

    /// @notice Reference for the aggregate: every unsettled reservation's own accrual, extended to now.
    function sumAccruedNow() external view returns (uint256 sum) {
        for (uint256 i; i < _res.length; ++i) {
            Reservation storage j = _res[i];
            if (j.settled) continue;
            uint256 t = block.timestamp < j.expiry ? block.timestamp : j.expiry;
            sum += j.accrued + (t > j.last ? uint256(j.r) * j.rho * (t - j.last) : 0);
        }
    }

    /// @notice Aggregate accrual extended to now, without writing.
    function aggNow() external view returns (uint256) {
        return _aggAt(block.timestamp);
    }

    /// @notice Sum of the bonds of unsettled reservations.
    function unsettledBonds() external view returns (uint256 sum) {
        for (uint256 i; i < _res.length; ++i) {
            if (!_res[i].settled) sum += _res[i].bond;
        }
    }

    // ------------------------------------------------------------------
    // Escrow operations
    // ------------------------------------------------------------------

    /// @notice Creation: the bond is the largest possible charge, prepaid. Called with the vault's admission.
    function create(address payer, uint128 amount, uint64 expiry, uint256 rho) external returns (uint256 id) {
        if (expiry % WIDTH != 0 || expiry <= block.timestamp) revert Misaligned();
        _accrueAgg();
        uint256 bond = FullMath.mulDivRoundingUp(uint256(amount) * (expiry - block.timestamp), rho, SCALE);
        posted += bond;
        rate += uint256(amount) * rho;
        rateDrop[expiry / WIDTH] += uint256(amount) * rho;
        id = _res.length;
        _res.push(
            Reservation({
                payer: payer,
                created: uint64(block.timestamp),
                expiry: expiry,
                last: uint64(block.timestamp),
                closed: false,
                settled: false,
                amount: amount,
                synced: 0,
                vaultConsumed: 0,
                r: amount,
                rho: rho,
                bond: bond,
                accrued: 0,
                charge: 0
            })
        );
    }

    /// @notice A fill in the vault. The escrow is not told.
    function vaultConsume(uint256 id, uint128 x) external {
        Reservation storage j = _res[id];
        if (j.closed || block.timestamp >= j.expiry || j.vaultConsumed + x > j.amount) revert Quota();
        j.vaultConsumed += x;
    }

    /// @notice Anyone: the escrow reads the vault's consumption and stops accrual on new consumption now.
    function sync(uint256 id) public {
        Reservation storage j = _res[id];
        if (j.settled) revert Settled();
        _accrueAgg();
        _accrue(j);
        uint128 newly = j.vaultConsumed - j.synced;
        if (newly == 0 || j.closed) {
            j.synced = j.vaultConsumed;
            return;
        }
        j.synced = j.vaultConsumed;
        j.r -= newly;
        if (block.timestamp < j.expiry) {
            rate -= uint256(newly) * j.rho;
            rateDrop[j.expiry / WIDTH] -= uint256(newly) * j.rho;
        }
    }

    /// @notice The curator cancelled in the vault and someone observed it (sync): accrual stops now.
    function close(uint256 id) external {
        Reservation storage j = _res[id];
        if (j.closed || j.settled) revert NotClosable();
        sync(id);
        if (block.timestamp < j.expiry) {
            rate -= uint256(j.r) * j.rho;
            rateDrop[j.expiry / WIDTH] -= uint256(j.r) * j.rho;
        }
        j.r = 0;
        j.closed = true;
    }

    /// @notice Anyone, once closed or expired: final charge, refund credited to the payer.
    function settle(uint256 id) external {
        Reservation storage j = _res[id];
        if (j.settled) revert Settled();
        if (!j.closed && block.timestamp < j.expiry) revert NotClosable();
        sync(id);
        uint256 duration = j.expiry - j.created;
        uint256 minRhoSeconds = uint256(j.amount) * (MIN_DURATION < duration ? MIN_DURATION : duration) * j.rho;
        uint256 basis = j.accrued > minRhoSeconds ? j.accrued : minRhoSeconds;
        uint256 charge = (basis + SCALE - 1) / SCALE;
        j.charge = charge;
        j.settled = true;
        aggAccrued -= j.accrued;
        settledCharges += charge;
        refundOwed[j.payer] += j.bond - charge;
        refundsOwedTotal += j.bond - charge;
    }

    /// @notice Anyone: move every fee earned so far out of "unrealized". The LP part enters the vault's N, the protocol
    ///         part becomes claimable. Both are taken on cumulative totals, so the split does not depend on how often
    ///         this runs.
    function realize() public {
        _accrueAgg();
        uint256 target = settledCharges + aggAccrued / SCALE;
        if (target <= realized) return;
        uint256 protocolDelta = target * PROTOCOL_BPS / BPS - realized * PROTOCOL_BPS / BPS;
        uint256 lpDelta = target - realized - protocolDelta;
        realized = target;
        protocolCredited += protocolDelta;
        lpMoved += lpDelta;
        vaultN += lpDelta;
    }

    function claimRefund(address payer) external returns (uint256 amount) {
        amount = refundOwed[payer];
        refundOwed[payer] = 0;
        refundsOwedTotal -= amount;
        refundsPaid += amount;
    }

    function claimProtocol() external returns (uint256 amount) {
        amount = protocolCredited - protocolPaid;
        protocolPaid += amount;
    }

    // ------------------------------------------------------------------
    // Vault side
    // ------------------------------------------------------------------

    /// @notice Deposit realizes first (fails closed in the proposal if realization fails), then prices at N / S.
    function deposit(uint256 s) external returns (uint256 paid) {
        realize();
        paid = FullMath.mulDivRoundingUp(s, vaultN, shares);
        vaultN += paid;
        shares += s;
    }

    /// @notice Exits never call the escrow; they take floor(s * N / S) of what has been realized.
    function redeem(uint256 s) external returns (uint256 got) {
        got = FullMath.mulDiv(s, vaultN, shares);
        vaultN -= got;
        shares -= s;
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _accrue(Reservation storage j) internal {
        uint256 t = block.timestamp < j.expiry ? block.timestamp : j.expiry;
        if (t > j.last) {
            j.accrued += uint256(j.r) * j.rho * (t - j.last);
            j.last = uint64(t);
        }
    }

    /// @dev Walks bucket ends between aggLast and now; the model walks every bucket (no ring is needed to check the
    ///      accounting; the ring only bounds the walk).
    function _accrueAgg() internal {
        uint256 t = block.timestamp;
        uint256 last = aggLast;
        if (t <= last) return;
        uint256 acc = aggAccrued;
        uint256 rt = rate;
        for (uint256 b = last / WIDTH + 1; b * WIDTH <= t; ++b) {
            acc += rt * (b * WIDTH - last);
            last = b * WIDTH;
            rt -= rateDrop[b];
        }
        acc += rt * (t - last);
        aggAccrued = acc;
        rate = rt;
        aggLast = t;
    }

    function _aggAt(uint256 t) internal view returns (uint256 acc) {
        uint256 last = aggLast;
        acc = aggAccrued;
        uint256 rt = rate;
        if (t <= last) return acc;
        for (uint256 b = last / WIDTH + 1; b * WIDTH <= t; ++b) {
            acc += rt * (b * WIDTH - last);
            last = b * WIDTH;
            rt -= rateDrop[b];
        }
        acc += rt * (t - last);
    }
}
