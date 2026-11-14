// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {IMarketRiskAdapter} from "../interfaces/IMarketRiskAdapter.sol";
import {ReferenceBracket} from "./ReferenceBracket.sol";

/// @title PriceRiskAdapter
/// @notice Read-only reference for one currency pair: the mid and uncertainty that every live push feed agrees on, or
///         a refusal. Meant to be read by the pricing hooks and, if the owner approves the dynamic-floor proposal, by
///         the vault, in the same transaction and from the same feeds.
/// @dev Configuration is fixed at deployment: feeds, thresholds, staleness limits, the sequencer feed and the number of
///      sources required. There is no owner and no setter. Changing anything means deploying a new adapter and
///      pointing its consumers at it, which is where any delay or review belongs.
///
///      Sources. Each source prices the pair from two USD legs (currency0/USD and currency1/USD) of one provider. A
///      source is live when both legs answered a positive price, no later than now, within their staleness limits.
///      Each live source contributes the bracket `ReferenceBracket.pairBracket` computes; the reference is the centre
///      of the intersection and the uncertainty its multiplicative half-width (`ReferenceBracket.midAndUncertainty`). A leg that answers zero, a negative price, a future
///      timestamp, or reverts, makes the whole read revert with `FeedUnusable` (fail closed). A leg that is only older
///      than its limit makes its source not live; if fewer than `minSources` sources are live the read reverts.
///
///      Fresh tier (optional, per source). A push leg's threshold is how far the market may move before the provider
///      pushes, so it is wide (RedStone ETH/USD: 0.5%). If someone pushes the provider's signed packages much more
///      often, for example a third-party relayer every minute, a leg younger than `freshMaxAge` can only lag the market
///      by what the market moves in that time, and the source may use the narrower `freshDeviation` for that leg.
///      Each leg picks its tier from its own age: younger than `freshMaxAge` uses `freshDeviation`, otherwise up to
///      `maxAge` uses `deviation`, otherwise the source is not live. So a relayer outage widens the band back to the
///      provider's own threshold after `freshMaxAge` seconds; it never halts reads that the push tier would allow.
///      The narrow value is an assumption about market movement over `freshMaxAge`, not a provider guarantee; the
///      vault's inventory floor bounds what a wrong assumption can cost. `freshMaxAge = 0` disables the tier.
///      Whoever submits the packages cannot change the price (the provider's contract verifies its signers and
///      rejects older timestamps); it can only choose when to submit, within the provider's own rules.
///
///      Sequencer. On an L2 a feed can look fresh while the sequencer has been down. If a sequencer uptime feed is
///      configured, the read reverts while it reports down (answer 1) and for `sequencerGrace` seconds after it came
///      back up.
///
///      Trust and calls. The adapter trusts the configured feeds for their answers and nothing else. It makes only
///      `staticcall`s, so neither a feed nor the adapter can change state or re-enter a caller. A feed can still make
///      a read revert or consume gas; consumers must treat a revert as "no reference" and refuse to trade.
///
///      Not handled: pull oracles (their update data comes with the transaction), round history and realized
///      volatility (RedStone's feeds expose no history), and depeg policy beyond what the brackets show.
contract PriceRiskAdapter is IMarketRiskAdapter {
    uint256 internal constant PIPS = 1_000_000;

    /// @notice One provider's two legs and their error bounds.
    /// @param leg0 currency0/USD feed.
    /// @param leg1 currency1/USD feed.
    /// @param deviation0 Leg 0 deviation threshold plus a latency margin, pips. Below 1e6.
    /// @param deviation1 Leg 1 deviation threshold plus a latency margin, pips. Below 1e6.
    /// @param maxAge0 Leg 0 staleness limit (its heartbeat plus a grace), seconds.
    /// @param maxAge1 Leg 1 staleness limit, seconds.
    /// @param freshMaxAge Age below which a leg uses its fresh deviation, seconds; below both `maxAge`s. Zero: no
    ///        fresh tier (both fresh deviations must then be zero).
    /// @param freshDeviation0 Leg 0 deviation while fresh, pips; at most `deviation0`.
    /// @param freshDeviation1 Leg 1 deviation while fresh, pips; at most `deviation1`.
    struct Source {
        IAggregatorV3 leg0;
        IAggregatorV3 leg1;
        uint256 deviation0;
        uint256 deviation1;
        uint256 maxAge0;
        uint256 maxAge1;
        uint256 freshMaxAge;
        uint256 freshDeviation0;
        uint256 freshDeviation1;
    }

    // Sources are held in immutables (code), not storage: a read costs no SLOAD for configuration that never changes.
    IAggregatorV3 internal immutable _s0leg0;
    IAggregatorV3 internal immutable _s0leg1;
    uint256 internal immutable _s0dev0;
    uint256 internal immutable _s0dev1;
    uint256 internal immutable _s0age0;
    uint256 internal immutable _s0age1;
    uint256 internal immutable _s0fresh;
    uint256 internal immutable _s0fdev0;
    uint256 internal immutable _s0fdev1;
    IAggregatorV3 internal immutable _s1leg0;
    IAggregatorV3 internal immutable _s1leg1;
    uint256 internal immutable _s1dev0;
    uint256 internal immutable _s1dev1;
    uint256 internal immutable _s1age0;
    uint256 internal immutable _s1age1;
    uint256 internal immutable _s1fresh;
    uint256 internal immutable _s1fdev0;
    uint256 internal immutable _s1fdev1;
    /// @notice Decimal shift from the first source's answers to raw currency1 per raw currency0.
    int256 public immutable shift0;
    /// @notice Decimal shift for the second source.
    int256 public immutable shift1;
    /// @notice L2 sequencer uptime feed, or address(0) for none.
    IAggregatorV3 public immutable sequencerFeed;
    /// @notice Seconds after the sequencer comes back up during which reads still revert.
    uint256 public immutable sequencerGrace;
    /// @notice Live sources required. 1 or 2.
    uint256 public immutable minSources;
    /// @dev The priced pair, in PoolKey order, and its token decimals.
    address internal immutable _currency0;
    address internal immutable _currency1;
    uint8 internal immutable _decimals0;
    uint8 internal immutable _decimals1;
    /// @inheritdoc IMarketRiskAdapter
    bytes32 public immutable override configVersion;

    /// @notice Configuration rejected at deployment.
    error InvalidConfig();
    /// @notice A leg reverted or returned an unusable answer (zero, negative, above 2^128, or a future timestamp).
    /// @param feed The leg.
    error FeedUnusable(address feed);
    /// @notice The sequencer is down, or came back up less than `sequencerGrace` seconds ago.
    error SequencerUnavailable();

    /// @dev Reads each leg's decimals once and derives the decimal shifts. Reverts with `InvalidConfig` if a feed is
    ///      zero, a threshold is not below 1e6, a staleness limit is zero, `minSources` is not 1 or 2, a shift is
    ///      larger than 30 decimal places in either direction, or a fresh tier is not strictly shorter and no wider
    ///      than the push tier (or has deviations set while disabled).
    /// @param s0 First source.
    /// @param s1 Second source.
    /// @param currency0_ Lower-address token of the pair. Non-zero and below `currency1_`.
    /// @param currency1_ Higher-address token of the pair.
    /// @param decimals0 Token decimals of currency0.
    /// @param decimals1 Token decimals of currency1.
    /// @param sequencerFeed_ Sequencer uptime feed, or address(0).
    /// @param sequencerGrace_ Grace after a sequencer restart, seconds.
    /// @param minSources_ Live sources required.
    constructor(
        Source memory s0,
        Source memory s1,
        address currency0_,
        address currency1_,
        uint8 decimals0,
        uint8 decimals1,
        IAggregatorV3 sequencerFeed_,
        uint256 sequencerGrace_,
        uint256 minSources_
    ) {
        if (minSources_ == 0 || minSources_ > 2 || currency0_ == address(0) || currency0_ >= currency1_) {
            revert InvalidConfig();
        }
        shift0 = _shift(s0, decimals0, decimals1);
        shift1 = _shift(s1, decimals0, decimals1);
        (_s0leg0, _s0leg1, _s0dev0, _s0dev1, _s0age0, _s0age1) =
        (s0.leg0, s0.leg1, s0.deviation0, s0.deviation1, s0.maxAge0, s0.maxAge1);
        (_s0fresh, _s0fdev0, _s0fdev1) = (s0.freshMaxAge, s0.freshDeviation0, s0.freshDeviation1);
        (_s1leg0, _s1leg1, _s1dev0, _s1dev1, _s1age0, _s1age1) =
        (s1.leg0, s1.leg1, s1.deviation0, s1.deviation1, s1.maxAge0, s1.maxAge1);
        (_s1fresh, _s1fdev0, _s1fdev1) = (s1.freshMaxAge, s1.freshDeviation0, s1.freshDeviation1);
        sequencerFeed = sequencerFeed_;
        sequencerGrace = sequencerGrace_;
        minSources = minSources_;
        (_currency0, _currency1, _decimals0, _decimals1) = (currency0_, currency1_, decimals0, decimals1);
        configVersion = keccak256(
            abi.encode(
                block.chainid,
                s0,
                s1,
                currency0_,
                currency1_,
                decimals0,
                decimals1,
                sequencerFeed_,
                sequencerGrace_,
                minSources_
            )
        );
    }

    /// @inheritdoc IMarketRiskAdapter
    function pair() external view override returns (address, address, uint8, uint8) {
        return (_currency0, _currency1, _decimals0, _decimals1);
    }

    /// @inheritdoc IMarketRiskAdapter
    /// @dev Reverts with `SequencerUnavailable`, `FeedUnusable`, `ReferenceBracket.InsufficientSources` or
    ///      `ReferenceBracket.ReferenceDivergence`. Never returns a stored or default price. Gas: five feed reads when
    ///      a sequencer feed is set (measured on a Unichain mainnet fork in test/fork/UnichainOracles.t.sol).
    /// @return r The reading.
    function currentReference() external view override returns (Reading memory r) {
        if (address(sequencerFeed) != address(0)) {
            (, int256 status, uint256 since,) = _read(sequencerFeed, true);
            if (status != 0 || block.timestamp < since + sequencerGrace) revert SequencerUnavailable();
        }
        uint256 low;
        uint256 high = type(uint256).max;
        r.validUntil = type(uint256).max;
        (bool live0, uint256 l0, uint256 h0, uint256 v0) =
            _source(_s0leg0, _s0leg1, [_s0dev0, _s0dev1, _s0age0, _s0age1, _s0fresh, _s0fdev0, _s0fdev1], shift0);
        (bool live1, uint256 l1, uint256 h1, uint256 v1) =
            _source(_s1leg0, _s1leg1, [_s1dev0, _s1dev1, _s1age0, _s1age1, _s1fresh, _s1fdev0, _s1fdev1], shift1);
        if (live0) {
            (low, high, r.validUntil) = (l0, h0, v0);
            ++r.liveSources;
        }
        if (live1) {
            if (l1 > low) low = l1;
            if (h1 < high) high = h1;
            if (v1 < r.validUntil) r.validUntil = v1;
            ++r.liveSources;
        }
        if (r.liveSources < minSources) revert ReferenceBracket.InsufficientSources(r.liveSources, minSources);
        (r.priceX96, r.uncertaintyPips) = ReferenceBracket.midAndUncertainty(low, high);
    }

    /// @notice The configured sources.
    /// @return s0 First source.
    /// @return s1 Second source.
    function sources() external view returns (Source memory s0, Source memory s1) {
        return (_source0(), _source1());
    }

    function _source0() internal view returns (Source memory) {
        return Source(_s0leg0, _s0leg1, _s0dev0, _s0dev1, _s0age0, _s0age1, _s0fresh, _s0fdev0, _s0fdev1);
    }

    function _source1() internal view returns (Source memory) {
        return Source(_s1leg0, _s1leg1, _s1dev0, _s1dev1, _s1age0, _s1age1, _s1fresh, _s1fdev0, _s1fdev1);
    }

    /// @dev One source: both legs read; each leg's tier from its own age (see "Fresh tier"); live if both legs are
    ///      within a tier; bracket if live. `validUntil` is the earliest time a leg leaves the tier it was read in.
    ///      Takes the source's immutables as arguments rather than a `Source` struct, so a read builds no memory copy
    ///      of the configuration (the struct form is kept for the `sources()` getter).
    /// @param cfg [deviation0, deviation1, maxAge0, maxAge1, freshMaxAge, freshDeviation0, freshDeviation1].
    function _source(IAggregatorV3 leg0, IAggregatorV3 leg1, uint256[7] memory cfg, int256 shift)
        internal
        view
        returns (bool live, uint256 low, uint256 high, uint256 validUntil)
    {
        (, int256 a0,, uint256 t0) = _read(leg0, false);
        (, int256 a1,, uint256 t1) = _read(leg1, false);
        (uint256 d0, uint256 until0) = _tier(t0, cfg[0], cfg[2], cfg[4], cfg[5]);
        (uint256 d1, uint256 until1) = _tier(t1, cfg[1], cfg[3], cfg[4], cfg[6]);
        validUntil = until0 < until1 ? until0 : until1;
        if (block.timestamp > validUntil) return (false, 0, 0, validUntil);
        live = true;
        // a0, a1 in (0, 2^128) checked by _read.
        // forge-lint: disable-next-line(unsafe-typecast)
        (low, high) = ReferenceBracket.pairBracket(uint256(a0), uint256(a1), d0, d1, shift);
    }

    /// @dev The deviation a leg updated at `updatedAt` is read with, and until when: the fresh tier while
    ///      `now <= updatedAt + freshMaxAge` (if enabled), otherwise the push tier until `updatedAt + maxAge`.
    ///      Example (RedStone ETH/USD, push 0.51% / 6.5 h, fresh 0.15% / 120 s): a leg pushed 90 s ago is bracketed at
    ///      +-0.15% until 30 s from now; at 121 s it is bracketed at +-0.51%; after 6.5 h the source is not live.
    function _tier(uint256 updatedAt, uint256 deviation, uint256 maxAge, uint256 freshMaxAge, uint256 freshDeviation)
        internal
        view
        returns (uint256, uint256)
    {
        if (freshMaxAge != 0 && block.timestamp <= updatedAt + freshMaxAge) {
            return (freshDeviation, updatedAt + freshMaxAge);
        }
        return (deviation, updatedAt + maxAge);
    }

    /// @dev `latestRoundData` through a staticcall that copies at most 160 bytes back, so a feed cannot force a large
    ///      return-data copy. The 4-byte calldata is written at the free-memory pointer and overwritten by the answer;
    ///      the pointer is not advanced because nothing else is allocated before the words are read. Price legs
    ///      (`isStatus = false`) must answer in (0, 2^128) with `updatedAt <= now`; the sequencer feed
    ///      (`isStatus = true`) must answer 0 or 1. Anything else reverts with `FeedUnusable`.
    function _read(IAggregatorV3 feed, bool isStatus)
        internal
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt)
    {
        bool ok;
        uint256 rid;
        bytes4 selector = IAggregatorV3.latestRoundData.selector;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            ok := staticcall(gas(), feed, ptr, 4, ptr, 160)
            if lt(returndatasize(), 160) { ok := 0 }
            rid := mload(ptr)
            answer := mload(add(ptr, 0x20))
            startedAt := mload(add(ptr, 0x40))
            updatedAt := mload(add(ptr, 0x60))
        }
        if (!ok || rid > type(uint80).max) revert FeedUnusable(address(feed));
        // forge-lint: disable-next-line(unsafe-typecast) checked above.
        roundId = uint80(rid);
        if (isStatus) {
            if (answer != 0 && answer != 1) revert FeedUnusable(address(feed));
        } else if (answer <= 0 || answer >= int256(1 << 128) || updatedAt > block.timestamp || updatedAt == 0) {
            revert FeedUnusable(address(feed));
        }
    }

    /// @dev Validates one source and returns its decimal shift `(feed decimals 1 + token decimals 1) - (feed decimals 0 +
    ///      token decimals 0)`.
    function _shift(Source memory s, uint8 decimals0, uint8 decimals1) private view returns (int256 e) {
        if (
            address(s.leg0) == address(0) || address(s.leg1) == address(0) || s.deviation0 >= PIPS
                || s.deviation1 >= PIPS || s.maxAge0 == 0 || s.maxAge1 == 0
        ) revert InvalidConfig();
        if (s.freshMaxAge == 0) {
            if (s.freshDeviation0 != 0 || s.freshDeviation1 != 0) revert InvalidConfig();
        } else if (
            s.freshMaxAge >= s.maxAge0 || s.freshMaxAge >= s.maxAge1 || s.freshDeviation0 > s.deviation0
                || s.freshDeviation1 > s.deviation1
        ) {
            revert InvalidConfig();
        }
        // Each sum is below 2 * 255: the casts are safe.
        uint256 up = uint256(s.leg1.decimals()) + decimals1;
        uint256 down = uint256(s.leg0.decimals()) + decimals0;
        // forge-lint: disable-next-line(unsafe-typecast)
        e = int256(up) - int256(down);
        if (e > ReferenceBracket.MAX_DECIMAL_SHIFT || e < -ReferenceBracket.MAX_DECIMAL_SHIFT) revert InvalidConfig();
    }
}
