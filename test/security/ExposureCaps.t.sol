// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {AuthModeHook} from "../utils/AuthModeHook.sol";

/// @notice Exposure caps: unused reserved capacity per hook, per curator and vault-wide, as basis points of eligible
///         backing E_a = N_a - D_a, checked when an allocation is created.
/// @dev The rule under test, for each scope with held capacity `held` and cap `bps`:
///          accept  iff  (held + maxOut) * 10,000 <= bps * E_a,   i.e.  held + maxOut <= floor(bps * E_a / 10,000)
///      `_limit` recomputes the right-hand side independently. Caps are amounts of one asset only; nothing here
///      converts between the two assets, and nothing here bounds the price at which capacity is later sold.
contract ExposureCapsTest is VaultTestBase {
    ISharedCommitmentVault.RiskScope internal constant HOOK = ISharedCommitmentVault.RiskScope.Hook;
    ISharedCommitmentVault.RiskScope internal constant CURATOR = ISharedCommitmentVault.RiskScope.Curator;
    ISharedCommitmentVault.RiskScope internal constant VAULT = ISharedCommitmentVault.RiskScope.Vault;

    address internal guardian = makeAddr("guardian");
    address internal curator2 = makeAddr("curator2");
    address internal e1;
    address internal e2;
    PoolKey internal keyE1;
    PoolKey internal keyE2;

    function setUp() public override {
        super.setUp();
        uint160 flags = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        e1 = address(uint160(0x0E1 << 140) | flags);
        e2 = address(uint160(0x0E2 << 140) | flags);
        deployCodeTo("AuthModeHook.sol:AuthModeHook", abi.encode(manager, vault, AuthModeHook.Mode.Operator), e1);
        deployCodeTo("AuthModeHook.sol:AuthModeHook", abi.encode(manager, vault, AuthModeHook.Mode.Operator), e2);
        keyE1 = PoolKey(c0, c1, 3000, 60, IHooks(e1));
        keyE2 = PoolKey(c0, c1, 3000, 60, IHooks(e2));
        manager.initialize(keyE1, SQRT_PRICE_1_1);
        manager.initialize(keyE2, SQRT_PRICE_1_1);
        vm.startPrank(owner);
        vault.setGuardian(guardian);
        vault.setConsumer(e1, true);
        vault.setConsumer(e2, true);
        vault.setCurator(curator2, true);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        vault.setCuratorCeiling(curator2, c1, type(uint256).max);
        _openLimits(HOOK, e1);
        _openLimits(HOOK, e2);
        _openLimits(CURATOR, curator2);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Boundary
    // ------------------------------------------------------------------

    function test_EX_atCap_andOneAbove() public {
        _setBps(VAULT, address(0), 2500); // E = 1,000,000 ether: limit 250,000 ether
        assertEq(lens.eligibleBacking(vault, c1), VAULT_FUNDING);
        _allocReverts(curator, keyE1, 250_000 ether + 1, VAULT, address(0), 250_000 ether);
        _alloc(curator, keyE1, 250_000 ether);
        _allocReverts(curator, keyE1, 1, VAULT, address(0), 0);
        assertEq(lens.exposureAvailable(vault, VAULT, address(0), c1), 0);
    }

    /// @notice The cap rounds down: with E = 1,000,000 ether + 7 and 25%, the exact limit is 250,000 ether + 1.75,
    ///         so 250,000 ether + 1 is accepted and 250,000 ether + 2 is not.
    function test_EX_roundsDown() public {
        _depositShares(makeAddr("lp7"), 7); // basket is 1:1 per share here: N1 rises by 7
        assertEq(lens.eligibleBacking(vault, c1), VAULT_FUNDING + 7);
        _setBps(VAULT, address(0), 2500);
        assertEq(_limit(2500, c1), 250_000 ether + 1);
        _allocReverts(curator, keyE1, 250_000 ether + 2, VAULT, address(0), 250_000 ether + 1);
        _alloc(curator, keyE1, 250_000 ether + 1);
    }

    /// @notice Each scope is checked separately: a curator cap across its hooks, a hook cap across its curators, and
    ///         the vault cap across both.
    function test_EX_multipleCuratorsAndHooks() public {
        _setBps(CURATOR, curator, 3000);
        _setBps(HOOK, e1, 4000);
        _setBps(VAULT, address(0), 5000);
        _alloc(curator, keyE1, 300_000 ether);
        _allocReverts(curator, keyE2, 1, CURATOR, curator, 0);
        _alloc(curator2, keyE1, 100_000 ether);
        _allocReverts(curator2, keyE1, 1, HOOK, e1, 0);
        _alloc(curator2, keyE2, 100_000 ether);
        _allocReverts(curator2, keyE2, 1, VAULT, address(0), 0);
        assertEq(vault.hookReserved(e1, c1), 400_000 ether);
        assertEq(vault.hookReserved(e2, c1), 100_000 ether);
        assertEq(vault.curatorReserved(curator, c1), 300_000 ether);
        assertEq(vault.curatorReserved(curator2, c1), 200_000 ether);
        assertEq(vault.reserved(c1), 500_000 ether);
    }

    // ------------------------------------------------------------------
    // Backing moves
    // ------------------------------------------------------------------

    /// @notice A deposit raises E and the cap with it; an instant redemption lowers both. Existing allocations
    ///         that now exceed the cap stay intact and consumable; only new ones are refused.
    function test_EX_backingChanges_depositsAndWithdrawals() public {
        _setBps(VAULT, address(0), 1000); // 10%
        uint256 a = _alloc(curator, keyE1, 100_000 ether);
        _allocReverts(curator, keyE1, 1, VAULT, address(0), 0);

        address lp = makeAddr("lpBig");
        _depositShares(lp, 1_000_000 ether); // E doubles
        assertEq(lens.exposureAvailable(vault, VAULT, address(0), c1), 100_000 ether);
        _alloc(curator, keyE1, 100_000 ether);

        _redeem(lp, 1_000_000 ether, false); // instant: E back to 1,000,000 ether, Q stays 200,000 ether
        assertEq(lens.eligibleBacking(vault, c1), VAULT_FUNDING);
        assertEq(vault.reserved(c1), 200_000 ether, "existing commitments untouched");
        _allocReverts(curator, keyE1, 1, VAULT, address(0), 0);
        _swapE(keyE1, a, 50_000 ether); // still consumable although over the cap
        assertEq(vault.getAllocation(a).consumed, 50_000 ether);
        _assertEquations();
    }

    /// @notice Queued redemptions are LP liabilities: D_a leaves eligible backing at once, before finalization, and
    ///         the vault's own `allocate` (not only the lens) applies the smaller cap. All of asset0 is committed
    ///         first, so the redemption queues entirely and N1 does not move; only D1 changes. With N1 = 1,000,000
    ///         ether and D1 about 200,000 ether, 50% of E1 is about 400,000 ether, while 50% of N1 would be 500,000.
    function test_EX_pendingDemandReducesEligibleBacking() public {
        ISharedCommitmentVault.AllocationRequest memory all0 =
            _request(keyE1, c0, uint128(vault.admissibleCapacity(c0)));
        vm.prank(curator);
        uint256 lock0 = auth.activateDirect(all0);
        (uint256 instant,,, uint256 req) = _redeem(lp0, 200_000 ether, true);
        assertEq(instant, 0, "asset0 fully committed: everything queues");
        assertGt(req, 0);
        uint256 d = lens.pendingDemand(vault, c1);
        assertGt(d, 0);
        assertEq(lens.netAssets(vault, c1), VAULT_FUNDING, "N1 unchanged by queueing");
        assertEq(lens.eligibleBacking(vault, c1), VAULT_FUNDING - d);

        _setBps(VAULT, address(0), 5000);
        uint256 limit = _limit(5000, c1);
        assertEq(limit, (VAULT_FUNDING - d) * 5000 / 10_000);
        assertLt(limit, VAULT_FUNDING / 2, "queue demand lowered the cap");
        assertEq(lens.exposureAvailable(vault, VAULT, address(0), c1), limit);
        _allocReverts(curator, keyE1, uint128(limit + 1), VAULT, address(0), limit);
        _alloc(curator, keyE1, uint128(limit));

        // Cancelling the request removes the demand and restores the cap computed from N1 alone.
        vm.prank(lp0);
        vault.cancelRequest(req);
        assertEq(lens.exposureAvailable(vault, VAULT, address(0), c1), VAULT_FUNDING / 2 - limit);
        vm.prank(curator);
        vault.cancelAllocation(lock0);
    }

    // ------------------------------------------------------------------
    // Consumption and closes
    // ------------------------------------------------------------------

    /// @notice Exposure counts unused capacity only: consumption lowers it, so room comes back; cancellation and
    ///         revoked cleanup return the rest. The flow records, which count what was paid, are not affected by any
    ///         close.
    function test_EX_partialConsumptionAndCloses() public {
        _setBps(HOOK, e1, 2000); // 200,000 ether
        uint256 a = _alloc(curator, keyE1, 200_000 ether);
        _allocReverts(curator2, keyE1, 1, HOOK, e1, 0);
        _swapE(keyE1, a, 60_000 ether);
        assertEq(vault.hookReserved(e1, c1), 140_000 ether);
        // The input received raised N0 only; c1 backing fell by the output, and so did E1 and the cap.
        uint256 room = _sub0(_limit(2000, c1), 140_000 ether);
        assertEq(lens.exposureAvailable(vault, HOOK, e1, c1), room);
        uint256 b = _alloc(curator2, keyE1, uint128(room));
        uint256 flowBefore = lens.flowUsed(vault, HOOK, e1, c1);

        vm.prank(curator);
        vault.cancelAllocation(a);
        assertEq(vault.hookReserved(e1, c1), room);
        vm.prank(guardian);
        vault.revokeCurator(curator2);
        vm.prank(makeAddr("stranger"));
        vault.release(b);
        assertEq(vault.hookReserved(e1, c1), 0);
        assertEq(vault.curatorReserved(curator2, c1), 0);
        assertEq(lens.flowUsed(vault, HOOK, e1, c1), flowBefore, "closes refund no flow");
        _alloc(curator, keyE1, uint128(_limit(2000, c1)));
        _assertEquations();
    }

    /// @notice Deregistration, re-registration, generation bumps and a freeze cycle change neither the held
    ///         capacity nor the caps; the curator is held to the same cap afterwards.
    function test_EX_reRegistrationAndGenerations() public {
        _setBps(CURATOR, curator, 1000);
        _alloc(curator, keyE1, 100_000 ether);
        vm.startPrank(owner);
        vault.setCurator(curator, false);
        vault.setCurator(curator, true);
        vault.freezeCurator(curator);
        vault.unfreezeCurator(curator);
        vm.stopPrank();
        vm.prank(curator);
        vault.bumpGeneration();
        assertEq(vault.curatorReserved(curator, c1), 100_000 ether);
        assertEq(vault.getRiskLimit(CURATOR, curator, c1).maxReservedBps, 1000);
        _allocReverts(curator, keyE1, 1, CURATOR, curator, 0);
    }

    /// @notice Guardian tightening below what is already held: the existing allocation stays reserved and
    ///         consumable, new ones are refused, and the guardian cannot loosen again.
    function test_EX_guardianTightening() public {
        uint256 a = _alloc(curator, keyE1, 300_000 ether);
        vm.prank(guardian);
        vault.setRiskLimit(CURATOR, curator, c1, type(uint104).max, 1000);
        assertEq(vault.curatorReserved(curator, c1), 300_000 ether);
        _allocReverts(curator, keyE2, 1, CURATOR, curator, 0);
        _swapE(keyE1, a, 10_000 ether);
        vm.prank(guardian);
        vm.expectRevert(ISharedCommitmentVault.GuardianCannotIncreaseRisk.selector);
        vault.setRiskLimit(CURATOR, curator, c1, type(uint104).max, 1001);
        // Other scopes and other curators are unaffected.
        _alloc(curator2, keyE2, 100_000 ether);
    }

    // ------------------------------------------------------------------
    // Extremes
    // ------------------------------------------------------------------

    /// @notice bps = 0 admits nothing; with one asset sold down to zero, E = 0 and nothing can be reserved (the
    ///         admission rule refuses first).
    function test_EX_zeroBpsAndZeroBacking() public {
        _setBps(HOOK, e2, 0);
        _allocReverts(curator, keyE2, 1, HOOK, e2, 0);

        uint256 all = vault.admissibleCapacity(c1);
        uint256 id = _alloc(curator, keyE1, uint128(all));
        _swapE(keyE1, id, all);
        assertEq(lens.netAssets(vault, c1), 0);
        assertEq(lens.eligibleBacking(vault, c1), 0);
        assertEq(lens.exposureAvailable(vault, VAULT, address(0), c1), 0);
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyE1, c1, 1);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ISharedCommitmentVault.InsufficientBacking.selector, 1, 0));
        auth.activateDirect(req);
    }

    /// @notice Random caps and backing sizes, up to 2^120 raw units: the vault accepts exactly the amounts the
    ///         independent formula floor(bps * E / 10,000) - held allows, for all three scopes, without overflow.
    function testFuzz_EX_boundaryMatchesFormula(uint256 extra, uint16 bpsV, uint16 bpsC, uint16 bpsH, uint256 first)
        public
    {
        extra = bound(extra, 0, 2 ** 120);
        if (extra != 0) _depositShares(makeAddr("lpF"), extra);
        vm.prank(owner);
        vault.setCuratorCeiling(curator, c1, type(uint256).max);
        bpsV = uint16(bound(bpsV, 0, 10_000));
        bpsC = uint16(bound(bpsC, 0, 10_000));
        bpsH = uint16(bound(bpsH, 0, 10_000));
        _setBps(VAULT, address(0), bpsV);
        _setBps(CURATOR, curator, bpsC);
        _setBps(HOOK, e1, bpsH);

        // A first allocation by curator2 on e2 makes Q_a non-zero, so held differs between scopes.
        uint256 roomV = _limit(bpsV, c1);
        first = bound(first, 0, roomV);
        if (first != 0) {
            _setBps(CURATOR, curator2, 10_000);
            _alloc(curator2, keyE2, uint128(first));
        }

        uint256 room = _min(
            _sub0(_limit(bpsV, c1), vault.reserved(c1)),
            _min(_sub0(_limit(bpsC, c1), vault.curatorReserved(curator, c1)), _sub0(_limit(bpsH, c1), 0))
        );
        room = _min(room, vault.admissibleCapacity(c1));
        if (room != 0) _alloc(curator, keyE1, uint128(room));
        // One more unit is refused, by an exposure cap or by the admission rule, whichever binds.
        ISharedCommitmentVault.AllocationRequest memory req = _request(keyE1, c1, 1);
        vm.prank(curator);
        try auth.activateDirect(req) {
            assertTrue(false, "one unit above the binding limit was accepted");
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            assertTrue(
                sel == ISharedCommitmentVault.ExposureCapExceeded.selector
                    || sel == ISharedCommitmentVault.InsufficientBacking.selector,
                "unexpected refusal"
            );
        }
        _assertEquations();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _setBps(ISharedCommitmentVault.RiskScope scope, address account, uint16 bps) internal {
        vm.prank(owner);
        vault.setRiskLimit(scope, account, c1, type(uint104).max, bps);
    }

    /// @dev Independent reference: floor(bps * (N - D) / 10,000), with D = ceil(P * N / S) read from raw state.
    function _limit(uint256 bps, Currency c) internal view returns (uint256) {
        uint256 n = vault.backing(c) - vault.claimableAssets(c);
        uint256 p = vault.pendingShares();
        uint256 d = p == 0 ? 0 : FullMath.mulDivRoundingUp(p, n, vault.totalShares());
        return bps * (n - d) / 10_000;
    }

    function _alloc(address who, PoolKey memory key, uint128 maxOut) internal returns (uint256) {
        ISharedCommitmentVault.AllocationRequest memory req = _request(key, c1, maxOut);
        vm.prank(who);
        return auth.activateDirect(req);
    }

    function _allocReverts(
        address who,
        PoolKey memory key,
        uint128 maxOut,
        ISharedCommitmentVault.RiskScope scope,
        address account,
        uint256 available
    ) internal {
        ISharedCommitmentVault.AllocationRequest memory req = _request(key, c1, maxOut);
        vm.prank(who);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISharedCommitmentVault.ExposureCapExceeded.selector, scope, account, c1, maxOut, available
            )
        );
        auth.activateDirect(req);
    }

    function _swapE(PoolKey memory key, uint256 id, uint256 amount) internal {
        _swapRaw(key, true, -int256(amount), abi.encode(id));
    }

    function _sub0(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
