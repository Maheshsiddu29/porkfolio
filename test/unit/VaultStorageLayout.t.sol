// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {VaultGetterHarness} from "../utils/VaultGetterHarness.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {VaultStateReader} from "../../src/libraries/VaultStateReader.sol";

/// @notice Pins the vault's storage layout, which `VaultLens` decodes through `extsload`.
/// @dev Every slot number and packed offset below is a literal written from `forge inspect
///      src/SharedCommitmentVault.sol:SharedCommitmentVault storageLayout`, independently of the constants in
///      `src/libraries/VaultStateReader.sol`. The fixture's vault is `VaultGetterHarness`, whose test-only getters
///      read each internal state variable by name. Three kinds of check:
///      1. after real state transitions, the raw word at each literal slot (`vm.load`) decodes to the value the
///         by-name getter returns: this pins the slot and offset of every variable the lens reads;
///      2. a fuzzed word written into each packed slot (`vm.store`) decodes identically through the lens and the
///         by-name getter: masks and shifts are exact for every field at full width, and no field bleeds into its
///         neighbour;
///      3. `extsload` returns the raw word of any slot.
///      A layout change in the vault (reordering, retyping, inserting a variable) fails check 1 even if the library
///      were changed to match, so the change cannot reach the lens unnoticed.
contract VaultStorageLayoutTest is VaultTestBase {
    // Literal slots (declaration order of SharedCommitmentVault).
    uint256 internal constant S_CURATOR_CEILING = 5;
    uint256 internal constant S_CURATOR_RESERVED = 6;
    uint256 internal constant S_BACKING = 7;
    uint256 internal constant S_RESERVED = 8;
    uint256 internal constant S_BUFFER_FLOOR = 9;
    uint256 internal constant S_SELL_POLICY = 10;
    uint256 internal constant S_CLAIMABLE = 11;
    uint256 internal constant S_ALLOCATIONS = 12;
    uint256 internal constant S_NEXT_ALLOCATION_ID = 13;
    uint256 internal constant S_TOTAL_SHARES = 14;
    uint256 internal constant S_PENDING_SHARES = 15;
    uint256 internal constant S_SHARES_OF = 16;
    uint256 internal constant S_REQUESTS = 17;
    uint256 internal constant S_NEXT_REQUEST_ID = 18;
    uint256 internal constant S_QUEUE_HEAD = 19;
    uint256 internal constant S_HOOK_RESERVED = 20;
    uint256 internal constant S_RISK_LIMITS = 21;
    uint256 internal constant S_RISK_PARAMS = 24;
    uint256 internal constant S_INVENTORY_TARGET = 25;
    uint256 internal constant S_INVENTORY_TOLERANCE = 27;
    // _expiryRings: mapping(Currency => ExpiryRing). Entry base h = keccak256(abi.encode(currency, 28)); word h packs
    // swept (uint64, bits 0-63) and maxBucket (uint64, bits 64-127); ring slot i is keccak256(abi.encode(i, h + 1)),
    // packing bucket (uint64, bits 0-63) and amount (uint128, bits 64-191).
    uint256 internal constant S_EXPIRY_RINGS = 28;

    address internal lp1 = makeAddr("lp1");
    address internal lp2 = makeAddr("lp2");
    uint256 internal allocationId;
    uint256 internal finalizedRequestId; // fully finalized: claimable amounts, nothing pending
    uint256 internal pendingRequestId; // queued: shares pending

    VaultGetterHarness internal ref; // the fixture's vault, with by-name reference getters

    function _newVault() internal override returns (SharedCommitmentVault) {
        ref = new VaultGetterHarness(manager, owner, c0, c1);
        return ref;
    }

    /// @dev Puts a non-zero value into every variable the lens reads, through the vault's own functions: an
    ///      allocation partly consumed by a real swap, a queued and partly finalized redemption, a buffer floor,
    ///      risk and inventory bounds, and a tightened risk limit.
    function setUp() public override {
        super.setUp();
        vm.startPrank(owner);
        vault.setCuratorCeiling(curator, c0, 10 * VAULT_FUNDING);
        vault.setCuratorCeiling(curator, c1, 10 * VAULT_FUNDING);
        vm.stopPrank();
        allocationId = _allocate(keyA, c1, 50_000 ether);
        _swap(keyA, true, 1000 ether, allocationId);

        // Two queued redemptions: reserving most of asset1 makes each one queue; cancelling the first blocking
        // allocation lets the queue finalize the first request, then a second request queues behind a new one.
        _depositShares(lp1, 100_000 ether);
        _depositShares(lp2, 100_000 ether);
        uint256 blocking = _allocate(keyB, c1, uint128(lens.freeInventory(vault, c1) - 1 ether));
        (,,, finalizedRequestId) = _redeem(lp1, 100_000 ether, true);
        vm.prank(curator);
        vault.cancelAllocation(blocking);
        vault.processQueue(1);
        _allocate(keyB, c1, uint128(lens.freeInventory(vault, c1) - 1 ether));
        (,,, pendingRequestId) = _redeem(lp2, 100_000 ether, true);

        vm.startPrank(owner);
        vault.setBufferFloor(c0, 7 ether);
        vault.setRiskBounds(123, 4567);
        vault.setInventoryBounds(3e17, 5e17, 250_000, 400_000);
        vault.setRiskLimit(ISharedCommitmentVault.RiskScope.Hook, address(hookA), c1, 1e30, 9000);
        vm.stopPrank();
    }

    function _load(uint256 slot) internal view returns (uint256) {
        return uint256(vm.load(address(vault), bytes32(slot)));
    }

    function _map(bytes32 key, uint256 slot) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(key, slot)));
    }

    function _map(address key, uint256 slot) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(key, slot)));
    }

    function _nested(address outer, Currency c, uint256 slot) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(c, _map(outer, slot))));
    }

    function _riskBase(ISharedCommitmentVault.RiskScope scope, address account, Currency c)
        internal
        pure
        returns (uint256)
    {
        return _map(keccak256(abi.encode(scope, account, c)), S_RISK_LIMITS);
    }

    // ------------------------------------------------------------------
    // By-name readers: the reference for what each slot means.
    // ------------------------------------------------------------------

    function _oldAllocation(uint256 id) internal view returns (ISharedCommitmentVault.Allocation memory) {
        return ref.oldGetAllocation(id);
    }

    function _oldRequest(uint256 id) internal view returns (ISharedCommitmentVault.WithdrawalRequest memory) {
        return ref.oldGetRequest(id);
    }

    function _oldRiskLimit(ISharedCommitmentVault.RiskScope s, address a, Currency c)
        internal
        view
        returns (ISharedCommitmentVault.RiskLimit memory)
    {
        return ref.oldGetRiskLimit(s, a, c);
    }

    function _oldSellPolicy(Currency c) internal view returns (uint160 f, bool h) {
        return ref.oldSellPolicy(c);
    }

    // ------------------------------------------------------------------
    // 1. Slots after real transitions
    // ------------------------------------------------------------------

    /// @notice Each literal slot holds the value the by-name getter reports, for every variable the lens decodes.
    function test_layout_slotsHoldGetterValues() public view {
        Currency[2] memory cs = [c0, c1];
        for (uint256 i; i < 2; ++i) {
            Currency c = cs[i];
            bytes32 k = bytes32(uint256(uint160(Currency.unwrap(c))));
            assertEq(_load(_map(k, S_BACKING)), ref.oldBacking(c), "backing");
            assertEq(_load(_map(k, S_RESERVED)), ref.oldReserved(c), "reserved");
            assertEq(_load(_map(k, S_BUFFER_FLOOR)), ref.oldBufferFloor(c), "bufferFloor");
            assertEq(_load(_map(k, S_CLAIMABLE)), ref.oldClaimableAssets(c), "claimableAssets");
            uint256 sp = _load(_map(k, S_SELL_POLICY));
            (uint160 f, bool h) = _oldSellPolicy(c);
            assertEq(uint160(sp), f, "sellPolicy.minInPerOutX96");
            assertEq((sp >> 160) & 0xff != 0, h, "sellPolicy.halted");
            assertEq(_load(_nested(curator, c, S_CURATOR_CEILING)), ref.oldCuratorCeiling(curator, c), "ceiling");
            assertEq(_load(_nested(curator, c, S_CURATOR_RESERVED)), ref.oldCuratorReserved(curator, c), "cur res");
            assertEq(_load(_nested(address(hookA), c, S_HOOK_RESERVED)), ref.oldHookReserved(address(hookA), c), "hk");
            assertEq(_load(_nested(address(hookB), c, S_HOOK_RESERVED)), ref.oldHookReserved(address(hookB), c), "hk");
        }
        // Non-zero where it matters, so the equalities above are not 0 == 0.
        assertGt(ref.oldReserved(c1), 0);
        assertGt(ref.oldClaimableAssets(c1), 0);
        assertGt(ref.oldClaimableAssets(c0), 0);
        assertGt(ref.oldBufferFloor(c0), 0);
        assertGt(ref.oldCuratorReserved(curator, c1), 0);
        assertGt(ref.oldHookReserved(address(hookB), c1), 0);

        assertEq(_load(S_NEXT_ALLOCATION_ID), ref.oldNextAllocationId(), "nextAllocationId");
        assertEq(_load(S_TOTAL_SHARES), ref.oldTotalShares(), "totalShares");
        assertEq(_load(S_PENDING_SHARES), vault.pendingShares(), "pendingShares");
        assertGt(vault.pendingShares(), 0);
        assertEq(_load(_map(lp0, S_SHARES_OF)), ref.oldSharesOf(lp0), "sharesOf");
        assertEq(_load(S_NEXT_REQUEST_ID), ref.oldNextRequestId(), "nextRequestId");
        assertEq(_load(S_QUEUE_HEAD), ref.oldQueueHead(), "queueHead");

        uint256 rp = _load(S_RISK_PARAMS);
        assertEq(address(uint160(rp)), address(ref.oldRiskAdapter()), "riskAdapter");
        assertEq(uint24(rp >> 160), ref.oldRiskEdgePips(), "riskEdgePips");
        assertEq(uint24(rp >> 184), ref.oldMaxUncertaintyPips(), "maxUncertaintyPips");
        assertEq(ref.oldRiskEdgePips(), 123);
        assertEq(ref.oldMaxUncertaintyPips(), 4567);
        assertEq(_load(S_INVENTORY_TARGET), ref.oldInventoryTargetPerShare(0), "target0");
        assertEq(_load(S_INVENTORY_TARGET + 1), ref.oldInventoryTargetPerShare(1), "target1");
        uint256 tol = _load(S_INVENTORY_TOLERANCE);
        assertEq(uint24(tol), ref.oldInventoryTolerancePips(0), "tolerance0");
        assertEq(uint24(tol >> 24), ref.oldInventoryTolerancePips(1), "tolerance1");
        assertEq(ref.oldInventoryTolerancePips(1), 400_000);

        _checkAllocationSlots(allocationId);
        _checkRequestSlots(finalizedRequestId);
        _checkRequestSlots(pendingRequestId);
        assertGt(_oldRequest(finalizedRequestId).claimable1, 0);
        assertGt(_oldRequest(pendingRequestId).sharesPending, 0);
        _checkRiskLimitSlots(ISharedCommitmentVault.RiskScope.Hook, address(hookA), c1);
        _checkRiskLimitSlots(ISharedCommitmentVault.RiskScope.Vault, address(0), c0);
    }

    function _checkAllocationSlots(uint256 id) internal view {
        ISharedCommitmentVault.Allocation memory a = _oldAllocation(id);
        uint256 b = _map(bytes32(id), S_ALLOCATIONS);
        assertEq(address(uint160(_load(b))), a.curator, "alloc.curator");
        uint256 w = _load(b + 1);
        assertEq(address(uint160(w)), a.consumer, "alloc.consumer");
        assertEq(uint64(w >> 160), a.expiry, "alloc.expiry");
        assertEq((w >> 224) & 0xff != 0, a.released, "alloc.released");
        assertEq(bytes32(_load(b + 2)), PoolId.unwrap(a.poolId), "alloc.poolId");
        assertEq(address(uint160(_load(b + 3))), Currency.unwrap(a.currencyIn), "alloc.currencyIn");
        assertEq(address(uint160(_load(b + 4))), Currency.unwrap(a.currencyOut), "alloc.currencyOut");
        w = _load(b + 5);
        assertEq(uint128(w), a.maxOut, "alloc.maxOut");
        assertEq(uint128(w >> 128), a.consumed, "alloc.consumed");
        assertEq(uint160(_load(b + 6)), a.minInPerOutX96, "alloc.minInPerOutX96");
        assertGt(a.consumed, 0);
        assertGt(a.expiry, 0);
    }

    function _checkRequestSlots(uint256 id) internal view {
        ISharedCommitmentVault.WithdrawalRequest memory r = _oldRequest(id);
        uint256 b = _map(bytes32(id), S_REQUESTS);
        uint256 w = _load(b);
        assertEq(address(uint160(w)), r.lp, "req.lp");
        assertEq((w >> 160) & 0xff != 0, r.canceled, "req.canceled");
        assertEq(address(uint160(_load(b + 1))), r.receiver, "req.receiver");
        w = _load(b + 2);
        assertEq(uint128(w), r.sharesRequested, "req.sharesRequested");
        assertEq(uint128(w >> 128), r.sharesPending, "req.sharesPending");
        w = _load(b + 3);
        assertEq(uint128(w), r.claimable0, "req.claimable0");
        assertEq(uint128(w >> 128), r.claimable1, "req.claimable1");
        assertEq(r.lp == lp1 || r.lp == lp2, true, "req.lp is a fixture LP");
    }

    function _checkRiskLimitSlots(ISharedCommitmentVault.RiskScope s, address account, Currency c) internal view {
        ISharedCommitmentVault.RiskLimit memory l = _oldRiskLimit(s, account, c);
        uint256 b = _riskBase(s, account, c);
        uint256 w = _load(b);
        assertEq(w & 0xff != 0, l.configured, "risk.configured");
        assertEq(uint40(w >> 8), l.epoch, "risk.epoch");
        assertEq(uint104(w >> 48), l.flowCap, "risk.flowCap");
        assertEq(uint104(w >> 152), l.flowUsed, "risk.flowUsed");
        assertEq(uint16(_load(b + 1)), l.maxReservedBps, "risk.maxReservedBps");
        assertTrue(l.configured);
    }

    // ------------------------------------------------------------------
    // 2. Packed words at full width
    // ------------------------------------------------------------------

    /// @notice Any word written into a packed slot decodes the same through the lens as through the by-name
    ///         getter. Covers every packed struct and variable at every bit, including values no transition can
    ///         produce (dirty high bits, boolean bytes other than 0 and 1).
    function testFuzz_layout_packedWordsDecodeLikeGetters(bytes32 w0, bytes32 w1) public {
        address v = address(vault);
        bytes32 k1 = bytes32(uint256(uint160(Currency.unwrap(c1))));

        vm.store(v, bytes32(_map(k1, S_SELL_POLICY)), w0);
        (uint160 f, bool h) = lens.sellPolicy(vault, c1);
        (uint160 oldF, bool oldH) = _oldSellPolicy(c1);
        assertEq(f, oldF, "sellPolicy.minInPerOutX96");
        assertEq(h, oldH, "sellPolicy.halted");

        vm.store(v, bytes32(S_RISK_PARAMS), w0);
        assertEq(address(lens.riskAdapter(vault)), address(ref.oldRiskAdapter()), "riskAdapter");
        assertEq(lens.riskEdgePips(vault), ref.oldRiskEdgePips(), "riskEdgePips");
        assertEq(lens.maxUncertaintyPips(vault), ref.oldMaxUncertaintyPips(), "maxUncertaintyPips");

        vm.store(v, bytes32(S_INVENTORY_TOLERANCE), w0);
        assertEq(lens.inventoryTolerancePips(vault, 0), ref.oldInventoryTolerancePips(0), "tolerance0");
        assertEq(lens.inventoryTolerancePips(vault, 1), ref.oldInventoryTolerancePips(1), "tolerance1");

        uint256 b = _map(bytes32(allocationId), S_ALLOCATIONS);
        for (uint256 i; i < 7; ++i) {
            vm.store(v, bytes32(b + i), i % 2 == 0 ? w0 : w1);
        }
        assertEq(abi.encode(lens.getAllocation(vault, allocationId)), abi.encode(_oldAllocation(allocationId)), "a");

        b = _map(bytes32(pendingRequestId), S_REQUESTS);
        for (uint256 i; i < 4; ++i) {
            vm.store(v, bytes32(b + i), i % 2 == 0 ? w0 : w1);
        }
        assertEq(
            abi.encode(lens.getRequest(vault, pendingRequestId)), abi.encode(_oldRequest(pendingRequestId)), "request"
        );

        b = _riskBase(ISharedCommitmentVault.RiskScope.Curator, curator, c0);
        vm.store(v, bytes32(b), w0);
        vm.store(v, bytes32(b + 1), w1);
        assertEq(
            abi.encode(lens.getRiskLimit(vault, ISharedCommitmentVault.RiskScope.Curator, curator, c0)),
            abi.encode(_oldRiskLimit(ISharedCommitmentVault.RiskScope.Curator, curator, c0)),
            "riskLimit"
        );
    }

    // ------------------------------------------------------------------
    // Expiry ring (slot 28)
    // ------------------------------------------------------------------

    function _ringBase(Currency c) internal pure returns (uint256) {
        return _map(bytes32(uint256(uint160(Currency.unwrap(c)))), S_EXPIRY_RINGS);
    }

    function _ringSlot(Currency c, uint256 index) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(index, _ringBase(c) + 1)));
    }

    /// @dev Raw words at the literal ring slots of `c` decode, with the literal offsets, to what the by-name getters
    ///      and the lens report, for the header and for slot `index`.
    function _checkRingSlots(Currency c, uint256 index) internal view {
        uint256 h = _load(_ringBase(c));
        (uint64 sw, uint64 mb) = ref.oldExpiryRing(c);
        assertEq(uint64(h), sw, "header bits 0-63: swept");
        assertEq(uint64(h >> 64), mb, "header bits 64-127: maxBucket");
        assertEq(h >> 128, 0, "header: nothing above bit 127");
        (uint64 lsw, uint64 lmb) = lens.expiryRing(vault, c);
        assertEq(lsw, sw, "lens swept");
        assertEq(lmb, mb, "lens maxBucket");
        uint256 w = _load(_ringSlot(c, index));
        (uint64 tag, uint128 amount) = ref.oldExpiryBucket(c, index);
        assertEq(uint64(w), tag, "slot bits 0-63: bucket");
        assertEq(uint128(w >> 64), amount, "slot bits 64-191: amount");
        assertEq(w >> 192, 0, "slot: nothing above bit 191");
        (uint64 ltag, uint128 lamount) = lens.expiryBucket(vault, c, index);
        assertEq(ltag, tag, "lens bucket");
        assertEq(lamount, amount, "lens amount");
    }

    /// @notice The ring's literal slots hold what the transitions wrote: populated slots with non-zero tags and
    ///         amounts, a header whose maxBucket is the far end of the horizon, and a slot reused 720 buckets later
    ///         (wrap-around), retagged with the newer bucket. Existing slots 5-27 are pinned above, so the ring is the
    ///         only addition to the layout.
    function test_layout_expiryRing_populatedAndWrapped() public {
        // setUp left allocations on asset1 expiring one day after T0 (rounded down to the hour).
        uint64 b1 = uint64(ref.oldGetAllocation(allocationId).expiry / 1 hours);
        _checkRingSlots(c1, b1 % 720);
        (uint64 tag1, uint128 amount1) = lens.expiryBucket(vault, c1, b1 % 720);
        assertEq(tag1, b1, "populated tag");
        assertGt(amount1, 0, "populated amount");

        // Asset0: one bucket a day out, then the same slot index 720 buckets later.
        uint256 id = _allocate(keyA, c0, 1000 ether);
        uint64 b0 = uint64(ref.oldGetAllocation(id).expiry / 1 hours);
        _checkRingSlots(c0, b0 % 720);
        (, uint64 mb) = lens.expiryRing(vault, c0);
        assertEq(mb, b0, "maxBucket");

        vm.warp(uint256(b0) * 1 hours + 1); // b0 has just ended; b0 + 720 is now exactly within MAX_HORIZON
        ISharedCommitmentVault.AllocationRequest memory r = _request(keyA, c0, 2000 ether);
        r.expiry = uint64(uint256(b0 + 720) * 1 hours);
        r.deadline = uint64(block.timestamp);
        vm.prank(curator);
        auth.activateDirect(r);
        (uint64 tagW, uint128 amountW) = lens.expiryBucket(vault, c0, b0 % 720);
        assertEq(tagW, b0 + 720, "slot retagged with the newer bucket");
        assertEq(amountW, 2000 ether, "the expired bucket's amount is not carried over");
        (uint64 sw, uint64 mbW) = lens.expiryRing(vault, c0);
        assertEq(sw, b0, "the sweep before the write reached the ended bucket");
        assertEq(mbW, b0 + 720, "maxBucket moved to the far end");
        _checkRingSlots(c0, b0 % 720);
    }

    /// @notice Any word written into the ring header or a ring slot decodes the same through the lens as through the
    ///         by-name getters, at every bit.
    function testFuzz_layout_ringWordsDecodeLikeGetters(bytes32 w0, bytes32 w1, uint256 index) public {
        index = bound(index, 0, 719);
        vm.store(address(vault), bytes32(_ringBase(c0)), w0);
        vm.store(address(vault), bytes32(_ringSlot(c0, index)), w1);
        (uint64 sw, uint64 mb) = lens.expiryRing(vault, c0);
        (uint64 oldSw, uint64 oldMb) = ref.oldExpiryRing(c0);
        assertEq(sw, oldSw, "swept");
        assertEq(mb, oldMb, "maxBucket");
        (uint64 tag, uint128 amount) = lens.expiryBucket(vault, c0, index);
        (uint64 oldTag, uint128 oldAmount) = ref.oldExpiryBucket(c0, index);
        assertEq(tag, oldTag, "bucket");
        assertEq(amount, oldAmount, "amount");
    }

    /// @notice The reader's ring constants are the vault's: slot 28, one-hour buckets, 720 slots (MAX_HORIZON / 1 h),
    ///         32 buckets per sweep. The bucket width and slot count are also what the vault enforces (an expiry one
    ///         second off an hour boundary is refused; the horizon is exactly 720 buckets).
    function test_layout_readerRingConstants() public view {
        assertEq(VaultStateReader.EXPIRY_RINGS_SLOT, S_EXPIRY_RINGS);
        assertEq(VaultStateReader.EXPIRY_BUCKET, 1 hours);
        assertEq(VaultStateReader.EXPIRY_SLOTS, 720);
        assertEq(VaultStateReader.EXPIRY_SLOTS * VaultStateReader.EXPIRY_BUCKET, vault.MAX_HORIZON());
        assertEq(VaultStateReader.SWEEP_STEPS, 32);
    }

    /// @notice Out-of-range array indices revert with the same panic as a public array getter.
    function test_layout_arrayIndexOutOfRangePanics() public {
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x32));
        lens.inventoryTargetPerShare(vault, 2);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x32));
        lens.inventoryTolerancePips(vault, 2);
    }

    // ------------------------------------------------------------------
    // 3. extsload
    // ------------------------------------------------------------------

    /// @notice `extsload` returns the raw persistent word of any slot, with no access control.
    function testFuzz_extsload_returnsRawWord(bytes32 slot, bytes32 word, address caller) public {
        vm.store(address(vault), slot, word);
        vm.prank(caller);
        assertEq(vault.extsload(slot), word);
    }
}
