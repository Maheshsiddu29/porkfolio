// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {VaultStateReader} from "../../src/libraries/VaultStateReader.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {MaliciousConsumerHook} from "../utils/MaliciousConsumerHook.sol";
import {ExpiryRingModel} from "../model/ExpiryRingModel.sol";

using VaultStateReader for SharedCommitmentVault;

/// @notice Differential test of the vault's expiry ring against the G05 reference model (`test/model/ExpiryRing.sol`
///         inside `ExpiryRingModel`, which also keeps a naive ledger scanning every reservation).
/// @dev Random schedules run on the real vault, real PoolManager and authorization module: reservations in random
///      buckets of either asset, exact fills through a test hook, early cancellations and releases after expiry,
///      permissionless sweeps (`processQueue(0)`), instant redemptions (which sweep both assets) and time jumps of up
///      to twice the horizon. Each successful vault operation is replayed on one model per asset with the same ring
///      parameters (1 h buckets, 720 slots, 32-step sweeps): `reserveFor` = model `reserve` (sweep, then add),
///      `exchange` = `consume`, `release`/`cancelAllocation` = `close`, a redemption or `processQueue` = `readerSweep`
///      on both models. After every step, per asset:
///        - the vault's stored Q_a equals the model's total (same sweeps, same evictions, same partial removals);
///        - the lens's `liveReserved` equals the model's view and the naive live sum (Q^live, exact);
///        - Q^live <= Q_a <= Q^lazy;
///        - the ring header (swept, maxBucket) equals the model's once the vault has swept that asset.
///      The two implementations share no code: the vault's ring is written in the vault, the model's is the G05 test
///      library. Agreement on every step means the vault's subtractions, evictions and shortcut happen exactly where
///      the reference puts them.
contract ExpiryRingDifferentialTest is VaultTestBase {
    uint160 internal constant SWAP_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
    uint256 internal constant H = 1 hours;
    uint256 internal constant STEPS = 80;

    MaliciousConsumerHook internal mal;
    PoolKey internal keyM;
    ExpiryRingModel[2] internal models;

    struct Res {
        uint256 vaultId;
        uint256 asset; // 0: c0, 1: c1
        uint256 modelId;
    }

    Res[] internal res;

    /// @dev Operation counts over one schedule, to show the schedules are not vacuous.
    struct Counts {
        uint256 reserves;
        uint256 fills;
        uint256 closesLive;
        uint256 closesExpired;
        uint256 sweeps;
        uint256 redeems;
        uint256 evictions;
    }

    function setUp() public override {
        super.setUp();
        address m = address(uint160(0xBAD9 << 140) | SWAP_FLAGS);
        deployCodeTo("MaliciousConsumerHook.sol:MaliciousConsumerHook", abi.encode(manager, vault), m);
        mal = MaliciousConsumerHook(m);
        keyM = PoolKey(c0, c1, 3000, 60, IHooks(m));
        manager.initialize(keyM, SQRT_PRICE_1_1);
        vm.startPrank(owner);
        vault.setConsumer(m, true);
        _openLimits(ISharedCommitmentVault.RiskScope.Hook, m);
        vault.setCuratorCeiling(curator, c0, type(uint256).max);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        vm.stopPrank();
        models[0] = new ExpiryRingModel(H, 720, 32);
        models[1] = new ExpiryRingModel(H, 720, 32);
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _cur(uint256 i) internal view returns (Currency) {
        return i == 0 ? c0 : c1;
    }

    function _sweepModels() internal {
        models[0].readerSweep();
        models[1].readerSweep();
    }

    function _compare(uint256 i) internal view {
        Currency c = _cur(i);
        ExpiryRingModel m = models[i];
        assertEq(vault.reserved(c), m.total(), "stored Q == model total");
        uint256 live = m.refLive();
        assertEq(m.liveTotal(), live, "model view == naive live sum");
        assertEq(lens.liveReserved(vault, c), live, "lens liveReserved == naive live sum");
        assertLe(live, vault.reserved(c), "Q >= live");
        assertLe(vault.reserved(c), m.refUnreleased(), "Q <= lazy");
        (uint64 sw, uint64 mb) = lens.expiryRing(vault, c);
        if (sw != 0) {
            assertEq(sw, m.swept(), "swept");
            assertEq(mb, m.maxBucket(), "maxBucket");
        }
    }

    /// @dev One random step; successful operations are added to `n`. With `heavy`, no sweeping call runs except a
    ///      reservation's own (kinds 5, 6 and 9 become warps of up to 4 days) and two reservations in three reuse an earlier
    ///      slot, so the ring falls more than 32 buckets behind and writes land on ended, unswept buckets: evictions.
    function _step(uint256 r, Counts memory n, bool heavy) internal {
        uint256 kind = r % 10;
        if (heavy && (kind == 5 || kind == 6 || kind == 9)) kind = 8; // no sweeps; no 60-day jumps (those end every
        // recorded bucket, and the next sweep then takes the O(1) branch instead of evicting)
        uint256 i = (r >> 8) & 1;
        Currency c = _cur(i);
        if (kind <= 2) {
            // Reserve 1 .. 20,000 in a random bucket within the horizon.
            uint256 amount = 1 + (r >> 16) % 20_000 ether;
            uint256 bucket = _now() / H + 1 + (r >> 128) % 720;
            // One reservation in three reuses the slot of an earlier one (its bucket + 720) when that is within the
            // horizon, so that slot reuse and eviction are reached often, not by chance.
            if ((heavy ? (r >> 200) % 3 != 0 : (r >> 200) % 3 == 0) && res.length != 0) {
                uint256 reuse = vault.getAllocation(res[(r >> 210) % res.length].vaultId).expiry / H + 720;
                if (reuse > _now() / H && reuse <= _now() / H + 720) bucket = reuse;
            }
            if (amount > vault.admissibleCapacity(c)) return;
            ISharedCommitmentVault.AllocationRequest memory q = _request(keyM, c, uint128(amount));
            (q.expiry, q.deadline) = (uint64(bucket * H), uint64(_now()));
            (uint64 tag,) = lens.expiryBucket(vault, c, bucket % 720);
            vm.prank(curator);
            uint256 id = auth.activateDirect(q);
            uint256 mid = models[i].reserve(uint128(amount), q.expiry);
            res.push(Res(id, i, mid));
            n.reserves++;
            // An eviction: the slot held another bucket that the reservation's own sweep did not reach (still above
            // `swept` afterwards), exactly the branch of the vault's `_addToBucket` that subtracts it.
            (uint64 swAfter,) = lens.expiryRing(vault, c);
            if (tag != 0 && tag != bucket && tag > swAfter) n.evictions++;
        } else if (kind == 3 && res.length != 0) {
            // Fill part of a live allocation, exactly, at 1:1: the first live one from a random starting index.
            uint256 start = (r >> 16) % res.length;
            Res memory a;
            ISharedCommitmentVault.Allocation memory al;
            uint256 left;
            for (uint256 k; k < res.length; ++k) {
                a = res[(start + k) % res.length];
                al = vault.getAllocation(a.vaultId);
                left = al.maxOut - al.consumed;
                if (!al.released && _now() < al.expiry && left != 0) break;
                left = 0;
            }
            if (left == 0) return;
            uint256 x = 1 + (r >> 64) % left;
            mal.configure(MaliciousConsumerHook.Attack.ExactAmounts, a.vaultId, x);
            _swapRaw(keyM, a.asset == 1, -int256(x), "");
            models[a.asset].consume(a.modelId, uint128(x));
            n.fills++;
        } else if (kind == 4 && res.length != 0) {
            // Close: release after expiry (anyone), or the curator's cancellation before it.
            Res memory a = res[(r >> 16) % res.length];
            ISharedCommitmentVault.Allocation memory al = vault.getAllocation(a.vaultId);
            if (al.released) return;
            if (_now() >= al.expiry) {
                vault.release(a.vaultId);
                n.closesExpired++;
            } else {
                vm.prank(curator);
                vault.cancelAllocation(a.vaultId);
                n.closesLive++;
            }
            models[a.asset].close(a.modelId);
        } else if (kind == 5) {
            vault.processQueue(0);
            _sweepModels();
            n.sweeps++;
        } else if (kind == 6) {
            // A small instant redemption, which sweeps both assets first.
            uint256 s = 1 ether + (r >> 16) % 100 ether;
            if (s > lens.deliverableShares(vault)) return;
            _redeem(lp0, s, false);
            _sweepModels();
            n.redeems++;
        } else {
            // Time: mostly hours, sometimes days, rarely up to twice the horizon (60 days).
            uint256 t = r >> 16;
            uint256 dt = kind == 7 ? t % (12 * H) : kind == 8 ? t % (4 days) : t % (60 days);
            vm.warp(_now() + dt);
        }
    }

    /// @notice 80-step random schedules: the vault agrees with the model and the naive ledger after every step.
    /// forge-config: default.fuzz.runs = 256
    /// forge-config: ci.fuzz.runs = 1000
    function testFuzz_vaultRingMatchesModel(uint256 seed, bool heavy) public {
        Counts memory n;
        for (uint256 step; step < STEPS; ++step) {
            _step(uint256(keccak256(abi.encode(seed, step))), n, heavy);
            _compare(0);
            _compare(1);
        }
        assertGt(n.reserves, 0, "reserved something");
    }

    /// @notice The schedules reach every operation, including evictions and both kinds of close, over a fixed set of
    ///         seeds (alternately ordinary and eviction-heavy). Guards against a generator that silently stops
    ///         exercising a path.
    function test_schedulesReachEveryOperation() public {
        Counts memory total;
        uint256 snap = vm.snapshotState();
        for (uint256 seed; seed < 24; ++seed) {
            Counts memory n;
            for (uint256 step; step < STEPS; ++step) {
                _step(uint256(keccak256(abi.encode(seed, step))), n, seed % 2 == 1);
            }
            _compare(0);
            _compare(1);
            total.reserves += n.reserves;
            total.fills += n.fills;
            total.closesLive += n.closesLive;
            total.closesExpired += n.closesExpired;
            total.sweeps += n.sweeps;
            total.redeems += n.redeems;
            total.evictions += n.evictions;
            vm.revertToState(snap);
            delete res;
        }
        emit log_named_uint("reserves", total.reserves);
        emit log_named_uint("fills", total.fills);
        emit log_named_uint("cancellations (live)", total.closesLive);
        emit log_named_uint("releases (expired)", total.closesExpired);
        emit log_named_uint("processQueue(0) sweeps", total.sweeps);
        emit log_named_uint("instant redemptions", total.redeems);
        emit log_named_uint("evictions", total.evictions);
        assertGt(total.reserves, 0);
        assertGt(total.fills, 0);
        assertGt(total.closesLive, 0);
        assertGt(total.closesExpired, 0);
        assertGt(total.sweeps, 0);
        assertGt(total.redeems, 0);
        assertGt(total.evictions, 0);
    }
}
