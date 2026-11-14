// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {VaultGetterHarness} from "../utils/VaultGetterHarness.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

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
