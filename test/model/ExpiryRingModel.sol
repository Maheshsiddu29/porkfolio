// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ExpiryRing} from "./ExpiryRing.sol";

/// @title ExpiryRingModel (test-only)
/// @notice One asset's reserved capacity with bucketed, keeper-free expiry (`ExpiryRing`), next to a naive reference
///         ledger that scans every reservation. Used to check the ring against the reference and to measure its gas.
/// @dev PROPOSED design (docs/architecture/G05_V2_ARCHITECTURE.md §3.5). This contract holds no assets and is not a
///      vault. `total` plays the role of the vault's Q_a; `reserve`, `consume`, `close` and `readerSweep` play the
///      roles of `reserveFor`, `exchange`, `_close` and the sweep an LP exit would run.
contract ExpiryRingModel {
    using ExpiryRing for ExpiryRing.Ring;

    error BadExpiry();
    error Closed();
    error Expired();
    error Quota();

    struct Reservation {
        uint64 expiry;
        uint128 remaining;
        bool closed;
    }

    uint256 public immutable WIDTH;
    uint256 public immutable K;
    uint256 public immutable STEPS;

    ExpiryRing.Ring internal _ring;
    /// @notice Q: sum of every bucket not yet subtracted. Never below the live sum (`refLive`).
    uint256 public total;
    Reservation[] internal _res;

    /// @param width Bucket width, seconds.
    /// @param k Ring size; MAX_HORIZON = width * k.
    /// @param steps Largest number of buckets one sweep walks (every path).
    constructor(uint256 width, uint256 k, uint256 steps) {
        WIDTH = width;
        K = k;
        STEPS = steps;
        // The ring must start at the deployment bucket: starting at 0 would make the first walk cover every bucket
        // since 1970.
        _ring.swept = uint40(block.timestamp / width);
    }

    function nowBucket() public view returns (uint256) {
        return block.timestamp / WIDTH;
    }

    function swept() external view returns (uint256) {
        return _ring.swept;
    }

    function maxBucket() external view returns (uint256) {
        return _ring.maxBucket;
    }

    function count() external view returns (uint256) {
        return _res.length;
    }

    function get(uint256 id) external view returns (Reservation memory) {
        return _res[id];
    }

    /// @notice Writer path: capped sweep, then add (a collision with an expired, unswept bucket is handled by `add`).
    function reserve(uint128 amount, uint64 expiry) external returns (uint256 id) {
        _checkExpiry(expiry);
        total = _ring.sweep(total, nowBucket(), STEPS, K);
        total = _ring.add(total, expiry / WIDTH, amount, K);
        id = _res.length;
        _res.push(Reservation(expiry, amount, false));
    }

    /// @notice Writer path without the sweep, to exercise the eviction branch of `add`. Not a proposed vault path.
    function reserveWithoutSweep(uint128 amount, uint64 expiry) external returns (uint256 id) {
        _checkExpiry(expiry);
        total = _ring.add(total, expiry / WIDTH, amount, K);
        id = _res.length;
        _res.push(Reservation(expiry, amount, false));
    }

    function consume(uint256 id, uint128 x) external {
        Reservation storage r = _res[id];
        if (r.closed) revert Closed();
        if (block.timestamp >= r.expiry) revert Expired();
        if (x > r.remaining) revert Quota();
        r.remaining -= x;
        total = _ring.remove(total, r.expiry / WIDTH, x, K);
    }

    function close(uint256 id) external {
        Reservation storage r = _res[id];
        if (r.closed) revert Closed();
        r.closed = true;
        total = _ring.remove(total, r.expiry / WIDTH, r.remaining, K);
    }

    /// @notice Reader path (an LP exit): sweep at most STEPS buckets.
    function readerSweep() external {
        total = _ring.sweep(total, nowBucket(), STEPS, K);
    }

    /// @notice Q with every expired bucket removed, without writing.
    function liveTotal() external view returns (uint256) {
        return _ring.live(total, nowBucket(), K);
    }

    /// @notice Reference: unused capacity of reservations that are open and not expired.
    function refLive() external view returns (uint256 sum) {
        for (uint256 i; i < _res.length; ++i) {
            Reservation storage r = _res[i];
            if (!r.closed && block.timestamp < r.expiry) sum += r.remaining;
        }
    }

    /// @notice Reference: unused capacity of every open reservation, expired or not (today's lazy Q).
    function refUnreleased() external view returns (uint256 sum) {
        for (uint256 i; i < _res.length; ++i) {
            if (!_res[i].closed) sum += _res[i].remaining;
        }
    }

    function _checkExpiry(uint64 expiry) internal view {
        if (expiry % WIDTH != 0 || expiry <= block.timestamp || expiry > block.timestamp + WIDTH * K) {
            revert BadExpiry();
        }
    }
}

/// @title ExpiryRingGasHarness (test-only)
/// @notice The ring operations alone, without the reference ledger, so that their gas can be measured. `plainAdd`
///         is today's cost of the same step (one running total, no ring) for comparison.
contract ExpiryRingGasHarness {
    using ExpiryRing for ExpiryRing.Ring;

    uint256 public immutable WIDTH;
    uint256 public immutable K;
    uint256 public immutable STEPS;

    ExpiryRing.Ring internal _ring;
    uint256 public total;

    constructor(uint256 width, uint256 k, uint256 steps) {
        WIDTH = width;
        K = k;
        STEPS = steps;
        _ring.swept = uint40(block.timestamp / width);
    }

    /// @notice Writer: capped sweep, then add to the expiry's bucket.
    function reserve(uint256 amount, uint256 expiry) external {
        total = _ring.sweep(total, block.timestamp / WIDTH, STEPS, K);
        total = _ring.add(total, expiry / WIDTH, amount, K);
    }

    /// @notice Consumption or release of `x` from the reservation expiring at `expiry`.
    function remove(uint256 expiry, uint256 x) external {
        total = _ring.remove(total, expiry / WIDTH, x, K);
    }

    /// @notice Reader sweep (an LP exit), at most STEPS buckets.
    function readerSweep() external {
        total = _ring.sweep(total, block.timestamp / WIDTH, STEPS, K);
    }

    /// @notice Today's equivalent of `reserve` or `remove`: one running total and nothing else.
    function plainAdd(uint256 amount) external {
        total += amount;
    }
}
