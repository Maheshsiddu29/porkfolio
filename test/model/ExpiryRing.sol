// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ExpiryRing (test-only reference; PROPOSED, not in src/)
/// @notice Keeper-free expiry of reserved capacity for one asset, using a fixed ring of K time buckets.
/// @dev Specification: docs/architecture/G05_V2_ARCHITECTURE.md §3.5. Nothing in `src/` uses this library.
///
///      Time is cut into buckets of WIDTH seconds; bucket b ends at b * WIDTH. A reservation's expiry must be a bucket
///      end, so it belongs to bucket b = expiry / WIDTH and is live while now < b * WIDTH. With
///      c = floor(now / WIDTH), bucket b is expired exactly when b <= c.
///
///      The owner of the ring keeps one running total (the vault's Q_a) equal to the sum of the amounts of every
///      bucket that has not been subtracted yet. Bucket b lives in slot b % K, tagged with b, so a slot reused after
///      wrap-around is never mistaken for an older bucket. `swept` is the last bucket whose expiry has been
///      recognized: every bucket <= swept has been subtracted from the total.
///
///      Sizing. A new expiry satisfies c < b <= c + H with H = MAX_HORIZON / WIDTH, so at most H buckets are live at
///      once and K = H slots suffice. If a slot is found holding another tag b' when bucket b is written, then
///      b' <= b - K <= c: the older bucket is expired, never live (proof in the design note §3.5).
///
///      Who sweeps. Every path that needs the total (admission, LP exits) sweeps at most a fixed number of buckets
///      first. A capped sweep leaves the total too high, never too low, so admission and LP exits computed from it
///      are conservative. A write that finds an expired bucket still counted in its slot subtracts it (`add`), so
///      writes never need a full sweep. If c >= maxBucket every bucket ever written has expired and the total is
///      zero, in O(1).
library ExpiryRing {
    struct Slot {
        uint40 bucket;
        uint128 amount;
    }

    struct Ring {
        /// @dev Every bucket <= swept has been subtracted from the owner's total.
        uint40 swept;
        /// @dev Largest bucket ever written.
        uint40 maxBucket;
        mapping(uint256 index => Slot) slots;
    }

    /// @dev Recognizes the expiry of buckets swept + 1 .. min(nowBucket, swept + maxSteps) and returns the new total.
    ///      O(1) when nothing has expired or when everything ever written has expired; otherwise one slot read per
    ///      bucket walked, whether or not the bucket held anything.
    function sweep(Ring storage r, uint256 total, uint256 nowBucket, uint256 maxSteps, uint256 k)
        internal
        returns (uint256)
    {
        uint256 s = r.swept;
        if (nowBucket <= s) return total;
        if (nowBucket >= r.maxBucket) {
            // forge-lint: disable-next-line(unsafe-typecast) bucket numbers are timestamps / WIDTH < 2^40.
            r.swept = uint40(nowBucket);
            return 0;
        }
        uint256 end = nowBucket - s > maxSteps ? s + maxSteps : nowBucket;
        for (uint256 b = s + 1; b <= end; ++b) {
            Slot storage slot = r.slots[b % k];
            if (slot.bucket == b) total -= slot.amount;
        }
        // forge-lint: disable-next-line(unsafe-typecast) end <= nowBucket < 2^40.
        r.swept = uint40(end);
        return total;
    }

    /// @dev Adds `amount` to bucket `bucket` and returns the new total. Precondition: c < bucket <= c + k.
    function add(Ring storage r, uint256 total, uint256 bucket, uint256 amount, uint256 k) internal returns (uint256) {
        Slot storage slot = r.slots[bucket % k];
        uint256 tag = slot.bucket;
        if (tag == bucket) {
            // forge-lint: disable-next-line(unsafe-typecast) bucket sums are bounded by the total (< 2^127).
            slot.amount += uint128(amount);
        } else {
            // An older bucket in this slot is expired (see the library notes). Subtract it if no sweep has.
            if (tag > r.swept) total -= slot.amount;
            // forge-lint: disable-next-line(unsafe-typecast) see above.
            slot.bucket = uint40(bucket);
            // forge-lint: disable-next-line(unsafe-typecast) see above.
            slot.amount = uint128(amount);
        }
        // forge-lint: disable-next-line(unsafe-typecast) see above.
        if (bucket > r.maxBucket) r.maxBucket = uint40(bucket);
        return total + amount;
    }

    /// @dev Removes `amount` from bucket `bucket` (consumption or release) and returns the new total. A bucket that
    ///      has already been subtracted, by a sweep or by eviction from its slot, is left alone: its capacity is
    ///      already out of the total.
    function remove(Ring storage r, uint256 total, uint256 bucket, uint256 amount, uint256 k)
        internal
        returns (uint256)
    {
        if (bucket <= r.swept) return total;
        Slot storage slot = r.slots[bucket % k];
        if (slot.bucket != bucket) return total;
        // forge-lint: disable-next-line(unsafe-typecast) amount <= slot.amount.
        slot.amount -= uint128(amount);
        return total - amount;
    }

    /// @dev Total minus every expired bucket not yet subtracted, without writing. One slot read per bucket between
    ///      `swept` and now (a view; sweeps keep that gap small in practice).
    function live(Ring storage r, uint256 total, uint256 nowBucket, uint256 k) internal view returns (uint256) {
        uint256 s = r.swept;
        if (nowBucket <= s) return total;
        if (nowBucket >= r.maxBucket) return 0;
        for (uint256 b = s + 1; b <= nowBucket; ++b) {
            Slot storage slot = r.slots[b % k];
            if (slot.bucket == b) total -= slot.amount;
        }
        return total;
    }
}
