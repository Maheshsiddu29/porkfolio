// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {BondEscrow} from "../../src/BondEscrow.sol";
import {CommitmentAuthorizer} from "../../src/CommitmentAuthorizer.sol";
import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {BaseCompatibleHook} from "../../src/hooks/BaseCompatibleHook.sol";
import {VaultGovernor} from "../../src/governance/VaultGovernor.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {IMarketRiskAdapter} from "../../src/interfaces/IMarketRiskAdapter.sol";
import {VaultStateReader} from "../../src/libraries/VaultStateReader.sol";
import {MockRiskAdapter} from "../utils/MockRiskAdapter.sol";
import {BondTestBase} from "../utils/BondTestBase.sol";

using VaultStateReader for SharedCommitmentVault;

/// @dev One curator-LP coalition. It posts its own bond, then redeems the capital it deposited; the honest LP's
///      request can queue behind the reservation. A rotation deposits fresh capital, closes and settles the previous
///      bond, posts a new one and queues the fresh shares in one transaction.
contract BondQueueGriefer {
    using VaultStateReader for SharedCommitmentVault;

    SharedCommitmentVault internal immutable vault;
    CommitmentAuthorizer internal immutable auth;
    BondEscrow internal immutable escrow;
    PoolKey internal key;
    Currency internal out;
    uint256 internal nonce;
    uint256[] internal live;
    uint256[] internal requests;

    uint256 public totalBond;
    uint256 public totalCharge;
    uint256 public totalRefund;
    uint256 public selfRebate;

    constructor(
        SharedCommitmentVault vault_,
        CommitmentAuthorizer auth_,
        BondEscrow escrow_,
        PoolKey memory key_,
        Currency out_
    ) {
        vault = vault_;
        auth = auth_;
        escrow = escrow_;
        key = key_;
        out = out_;
        MockERC20(Currency.unwrap(out_)).approve(address(escrow_), type(uint256).max);
        MockERC20(Currency.unwrap(key_.currency0)).approve(address(vault_), type(uint256).max);
        MockERC20(Currency.unwrap(key_.currency1)).approve(address(vault_), type(uint256).max);
    }

    function lastAllocation() external view returns (uint256) {
        return live[live.length - 1];
    }

    function lastRequest() external view returns (uint256) {
        return requests[requests.length - 1];
    }

    function coalitionShares() public view returns (uint256 s) {
        s = vault.sharesOf(address(this));
        for (uint256 i; i < requests.length; ++i) {
            s += vault.getRequest(requests[i]).sharesPending;
        }
    }

    function commitAll(uint256 horizon) public returns (uint256 id) {
        uint256 amount = vault.admissibleCapacity(out);
        uint256 ceiling = vault.curatorCeiling(address(this), out) - vault.curatorReserved(address(this), out);
        if (amount > ceiling) amount = ceiling;
        require(amount > 0 && amount <= type(uint128).max, "no admissible bond");
        ISharedCommitmentVault.AllocationRequest memory req = ISharedCommitmentVault.AllocationRequest({
            consumer: address(key.hooks),
            key: key,
            currencyOut: out,
            maxOut: uint128(amount),
            minInPerOutX96: uint160(FixedPoint96.Q96),
            expiry: uint64((block.timestamp + horizon) / 1 hours * 1 hours),
            nonce: nonce++,
            deadline: uint64(block.timestamp)
        });
        id = auth.activateDirectBonded(req, type(uint256).max);
        live.push(id);
        totalBond += escrow.getBond(id).bond;
    }

    function _close() internal {
        for (uint256 i; i < live.length; ++i) {
            uint256 id = live[i];
            if (!vault.getAllocation(id).released) vault.cancelAllocation(id);
            escrow.sync(id);
            (uint256 charge, uint256 refund) = escrow.settle(id);
            totalCharge += charge;
            totalRefund += refund;
        }
        delete live;
    }

    function closeAndSettle() external {
        _close();
    }

    function depositCapital(uint256 shares) external {
        vault.deposit(shares, type(uint256).max, type(uint256).max, address(this));
    }

    function queueCapital(uint256 shares) external returns (uint256 rid) {
        (,,, rid) = vault.redeem(shares, 0, 0, address(this), true);
        require(rid != 0, "capital exit was not queued");
        requests.push(rid);
    }

    function rotateWithCapital(uint256 horizon, uint256 shares) external returns (uint256 rid) {
        (uint256 lpFee,) = escrow.unrealized(out);
        selfRebate += FullMath.mulDiv(lpFee, coalitionShares(), vault.totalShares());
        // Eight-day rotations leave the bounded deposit checkpoint more than 32 buckets behind. Anyone can catch
        // it up first; doing so also makes the old LP shares receive the earned fee before the fresh deposit.
        escrow.realize(type(uint256).max);
        vault.deposit(shares, type(uint256).max, type(uint256).max, address(this));
        _close();
        commitAll(horizon);
        (,,, rid) = vault.redeem(shares, 0, 0, address(this), true);
        require(rid != 0, "capital exit was not queued");
        requests.push(rid);
    }
}

/// @notice F-8 on the real vault and PoolManager: fresh capital still permits a curator-LP coalition to queue honest
///         shares behind bonded capacity. The test measures bond collateral versus actual charge, refund, fee rebate
///         through the coalition's own shares and queue delay at three rates and three terms, then rotates across a
///         governor's long delay and checks guardian recovery.
contract BondEconomicGriefingTest is BondTestBase {
    uint256 internal constant SEED = VAULT_FUNDING;
    uint256 internal constant CAPITAL = 10 * SEED;
    uint256 internal constant CEILING = SEED / 5;
    address internal admin = makeAddr("bondAdmin");
    BondQueueGriefer internal griefer;
    uint256 internal tau;

    function setUp() public override {
        super.setUp();
        tau = FullMath.mulDiv(lens.backing(vault, c0), 1e18, lens.totalShares(vault));
        griefer = new BondQueueGriefer(vault, bonded, escrow, keyA, c0);
        token0.mint(address(griefer), 100 * SEED);
        token1.mint(address(griefer), 100 * SEED);
        MockRiskAdapter adapter = new MockRiskAdapter(address(token0), address(token1), 18, 18, keccak256("bond-f8"));
        adapter.set(FixedPoint96.Q96, 1000, type(uint256).max);
        vm.startPrank(owner);
        vault.setCurator(address(griefer), true);
        vault.setCuratorCeiling(address(griefer), c0, CEILING);
        vault.setBufferFloor(c0, SEED / 10);
        vault.setBufferFloor(c1, SEED / 10);
        vault.setInventoryBounds(tau, tau, 10_000, 10_000);
        vault.setRiskBounds(100, 20_000);
        vault.setRiskAdapter(IMarketRiskAdapter(address(adapter)));
        ISharedCommitmentVault.RiskScope[3] memory scopes = [
            ISharedCommitmentVault.RiskScope.Vault,
            ISharedCommitmentVault.RiskScope.Hook,
            ISharedCommitmentVault.RiskScope.Curator
        ];
        address[3] memory accounts = [address(0), address(hookA), address(griefer)];
        for (uint256 i; i < 3; ++i) {
            vault.setRiskLimit(scopes[i], accounts[i], c0, 400_000 ether, 5000);
            vault.setRiskLimit(scopes[i], accounts[i], c1, 400_000 ether, 5000);
        }
        vm.stopPrank();
        BaseCompatibleHook.CoreParams memory p = BaseCompatibleHook.CoreParams({
            depthPerShare: 10e18,
            depthMax: uint128(2 ** 95 - 1),
            baseSpreadPips: 3000,
            minEdgePips: 200,
            maxSpreadPips: 40_000,
            maxDeviationPips: 10_000
        });
        vm.prank(hookOwner);
        hookA.configureCore(keyA, p);
        vm.prank(owner);
        vault.setGuardian(guardian);
        _redeem(lp0, 950_000 ether, true);
        assertEq(lens.backing(vault, c0), 50_000 ether);
    }

    /// @notice Each row deposits 10 million units of transient capital, withholds more than the honest 50,000 units,
    ///         then cancels halfway through its term. The posted bond is collateral, not economic loss: the charge is
    ///         the actual cost, reduced further by fees accruing to the coalition's queued shares. A zero rate charges
    ///         nothing. No universal anti-griefing bound follows from these fixtures.
    function test_f8_rateAndTermMatrix() public {
        uint256[3] memory rates = [uint256(0), uint256(1e9), uint256(1e12)];
        uint256[3] memory terms = [uint256(1 hours), uint256(1 days), uint256(9 days)];
        for (uint256 i; i < rates.length; ++i) {
            for (uint256 k; k < terms.length; ++k) {
                uint256 snap = vm.snapshotState();
                vm.prank(owner);
                escrow.setRate(c0, rates[i]);
                uint256 beforeTime = vm.getBlockTimestamp();
                uint256 gasBefore = gasleft();
                uint256 rid = griefer.rotateWithCapital(terms[k], CAPITAL);
                uint256 gasUsed = gasBefore - gasleft();
                uint256 id = griefer.lastAllocation();
                uint256 q = lens.reserved(vault, c0);
                assertGt(q, 50_000 ether, "honest backing can be withheld");
                assertGt(vault.getRequest(rid).sharesPending, 0);
                uint256 postedBond = escrow.getBond(id).bond;
                assertEq(postedBond, griefer.totalBond());
                uint256 elapsed = terms[k] / 2;
                if (elapsed == 0) elapsed = 1;
                vm.warp(beforeTime + elapsed);
                griefer.closeAndSettle();
                uint256 charge = griefer.totalCharge();
                uint256 refund = griefer.totalRefund();
                assertEq(postedBond, charge + refund);
                (uint256 lpFee,) = escrow.unrealized(c0);
                uint256 selfRebate = FullMath.mulDiv(lpFee, griefer.coalitionShares(), lens.totalShares(vault));
                escrow.realize(type(uint256).max);
                assertLe(selfRebate, charge);
                vault.processQueue(10);
                assertEq(vault.getRequest(rid).sharesPending, 0, "cancellation unblocks the queue");
                console2.log("F8 rate term capital", rates[i], terms[k], CAPITAL);
                console2.log("F8 Q bond charge", q, postedBond, charge);
                console2.log("F8 refund rebate delay", refund, selfRebate, elapsed);
                console2.log("F8 gas", gasUsed);
                vm.revertToState(snap);
            }
        }
    }

    /// @notice A partial fill does not make the whole bond free. The escrow sees 1,000 units consumed only at the
    ///         two-hour sync, so it charges on all reserved units for those two hours and on the smaller remainder
    ///         until cancellation at twelve hours. The one-hour late sync adds exactly consumed * rho * one hour to
    ///         the counterfactual immediate-sync fee, before raw-unit rounding.
    function test_f8_partialFill_lateSyncStillChargesForWithheldRemainder() public {
        vm.prank(owner);
        escrow.setRate(c0, 1e9);
        uint256 start = vm.getBlockTimestamp();
        griefer.depositCapital(CAPITAL);
        uint256 id = griefer.commitAll(1 days);
        uint256 amount = escrow.getBond(id).amount;
        vm.warp(start + 1 hours);
        _swap(keyA, false, 1000 ether, id);
        uint256 consumed = lens.getAllocation(vault, id).consumed;
        assertGt(consumed, 0);
        assertLt(consumed, amount);
        uint256 rid = griefer.queueCapital(CAPITAL);
        assertGt(vault.getRequest(rid).sharesPending, 0);

        vm.warp(start + 2 hours);
        escrow.sync(id);
        assertEq(escrow.getBond(id).remaining, amount - consumed);
        vm.warp(start + 12 hours);
        griefer.closeAndSettle();
        uint256 raw = (amount * 2 hours + (amount - consumed) * 10 hours) * 1e9;
        uint256 expected = (raw + 1e18 - 1) / 1e18;
        assertEq(griefer.totalCharge(), expected);
        assertEq(griefer.totalBond(), griefer.totalCharge() + griefer.totalRefund());
        uint256 immediateRaw = (amount * 1 hours + (amount - consumed) * 11 hours) * 1e9;
        uint256 immediateCharge = (immediateRaw + 1e18 - 1) / 1e18;
        uint256 lateExtra = consumed * 1 hours * 1e9 / 1e18;
        assertGe(expected - immediateCharge, lateExtra);
        assertLe(expected - immediateCharge, lateExtra + 1); // ceiling both totals can add one raw unit
        console2.log("F8 partial fill consumed charge late-sync extra", consumed, expected, lateExtra);
        escrow.realize(type(uint256).max);
        vault.processQueue(10);
        assertEq(vault.getRequest(rid).sharesPending, 0);
    }

    /// @notice Four nine-day bonds rotated eight days apart keep a fresh-capital queue pending through the 32-day
    ///         governance delay. A guardian buffer lever stops the next bond; after old bonds expire, a queue sweep
    ///         lets the long-delay change execute. Bond fees make the attack costly at rho > 0, but most LP fees can
    ///         return to coalition shares, so they do not make the queue attack impossible.
    function test_f8_rotationsBlockLongChange_guardianAndExpiryRecover() public {
        vm.prank(owner);
        escrow.setRate(c0, 1e9);
        VaultGovernor gov = new VaultGovernor(address(vault), admin, 3 days, 32 days, 7 days);
        vm.prank(owner);
        vault.transferOwnership(address(gov));
        vm.prank(admin);
        gov.acceptVaultOwnership();
        bytes memory change = abi.encodeCall(vault.setInventoryBounds, (tau, tau, 20_000, 20_000));
        vm.prank(admin);
        (, uint256 eta) = gov.queue(address(vault), change);

        uint256 rid = griefer.rotateWithCapital(9 days, CAPITAL);
        uint256 honestQueuedAt = vm.getBlockTimestamp();
        (,,, uint256 honestRid) = _redeem(lp0, 1000 ether, true);
        assertGt(honestRid, 0, "honest LP queued");
        uint256 honestDelay;
        for (uint256 k; k < 3; ++k) {
            vm.warp(vm.getBlockTimestamp() + 8 days);
            uint256 next = griefer.rotateWithCapital(9 days, CAPITAL);
            assertEq(vault.getRequest(rid).sharesPending, 0, "prior queue entry finalized");
            if (k == 0) {
                assertEq(vault.getRequest(honestRid).sharesPending, 0, "honest LP finalized");
                honestDelay = vm.getBlockTimestamp() - honestQueuedAt;
            }
            rid = next;
        }
        vm.warp(eta);
        uint256 pending = vault.pendingShares();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultGovernor.PendingWithdrawals.selector, pending));
        gov.execute(address(vault), change);
        assertGt(vault.pendingShares(), 0);

        vm.prank(guardian);
        vault.setBufferFloor(c0, type(uint256).max);
        vm.prank(admin);
        gov.cancel(address(vault), change);
        vm.prank(admin);
        (, uint256 eta2) = gov.queue(address(vault), change);
        vm.warp(eta + 8 days);
        vm.expectRevert();
        griefer.rotateWithCapital(9 days, CAPITAL);
        vm.warp(eta2);
        vault.processQueue(256);
        vm.prank(admin);
        gov.execute(address(vault), change);
        assertEq(vault.pendingShares(), 0);
        console2.log(
            "F8 rotations bond charge refund", griefer.totalBond(), griefer.totalCharge(), griefer.totalRefund()
        );
        console2.log("F8 self-rebate", griefer.selfRebate());
        console2.log("F8 honest LP queue delay seconds", honestDelay);
    }
}
