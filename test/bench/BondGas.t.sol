// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {ICommitmentAuthorizer} from "../../src/interfaces/ICommitmentAuthorizer.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {BondTestBase} from "../utils/BondTestBase.sol";

/// @notice Gas rows for the production BondEscrow and CommitmentAuthorizer builds, measured around external calls
///         against the real PoolManager. `test/bench/run.sh` executes these with `--isolate` and reports the rows.
contract BondGasTest is BondTestBase {
    function setUp() public override {
        super.setUp();
        vm.warp(_hourAligned(vm.getBlockTimestamp()) + 1 hours);
    }

    function _request1d() internal returns (ISharedCommitmentVault.AllocationRequest memory r) {
        r = _request(keyS, c1, 10_000 ether);
        r.deadline = uint64(vm.getBlockTimestamp());
    }

    function _posted() internal returns (uint256) {
        return _allocateUntil(keyS, c1, 10_000 ether, uint64(vm.getBlockTimestamp() + 10 days));
    }

    function test_bench_sizes() public view {
        console2.log("BENCH runtime BondEscrow:", address(escrow).code.length);
        console2.log("BENCH runtime CommitmentAuthorizer:", address(bonded).code.length);
    }

    function test_bench_bondedDirect_firstAndRepeat() public {
        ISharedCommitmentVault.AllocationRequest memory r = _request1d();
        vm.prank(curator);
        uint256 g = gasleft();
        bonded.activateDirectBonded(r, RHO);
        console2.log("BENCH bonded direct activation, first bond:", g - gasleft());
        r = _request1d();
        vm.prank(curator);
        g = gasleft();
        bonded.activateDirectBonded(r, RHO);
        console2.log("BENCH bonded direct activation, same bucket:", g - gasleft());
    }

    function test_bench_bondedSignedEoa() public {
        ICommitmentAuthorizer.BondedAuthorization memory b = _bondedAuthz(signer, keyA, c1, 10_000 ether, payer, RHO);
        b.allocation.deadline = uint64(vm.getBlockTimestamp());
        bytes memory sig = _signBonded(signerKey, b);
        vm.prank(payer);
        uint256 g = gasleft();
        bonded.activateBonded(b, keyA, sig);
        console2.log("BENCH bonded signed EOA activation:", g - gasleft());
    }

    function test_bench_bondedSigned1271() public {
        ICommitmentAuthorizer.BondedAuthorization memory b =
            _bondedAuthz(address(wallet), keyB, c1, 10_000 ether, payer, RHO);
        b.allocation.deadline = uint64(vm.getBlockTimestamp());
        wallet.approve(bonded.hashBondedAuthorization(b), true);
        vm.prank(payer);
        uint256 g = gasleft();
        bonded.activateBonded(b, keyB, "");
        console2.log("BENCH bonded signed ERC-1271 activation:", g - gasleft());
    }

    function test_bench_syncFillAndSettleEarly() public {
        uint256 id = _posted();
        _swap(keyS, true, 1000 ether, id);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        uint256 g = gasleft();
        escrow.sync(id);
        console2.log("BENCH bond sync after fill:", g - gasleft());
        vm.prank(curator);
        vault.cancelAllocation(id);
        g = gasleft();
        escrow.settle(id);
        console2.log("BENCH bond settle early close:", g - gasleft());
    }

    function test_bench_settleExpiry() public {
        uint256 id = _allocateUntil(keyS, c1, 10_000 ether, uint64(vm.getBlockTimestamp() + 1 hours));
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        uint256 g = gasleft();
        escrow.settle(id);
        console2.log("BENCH bond settle at expiry:", g - gasleft());
    }

    function test_bench_claimRefund() public {
        uint256 id = _posted();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(curator);
        vault.cancelAllocation(id);
        escrow.settle(id);
        vm.prank(curator);
        uint256 g = gasleft();
        escrow.claimRefund(curator);
        console2.log("BENCH bond claim refund:", g - gasleft());
    }

    function test_bench_claimProtocol() public {
        _posted();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        escrow.realize(type(uint256).max);
        vm.prank(protocol);
        uint256 g = gasleft();
        escrow.claimProtocol(protocol);
        console2.log("BENCH bond claim protocol:", g - gasleft());
    }

    function test_bench_realizeNoFee_earnedAndWalk() public {
        uint256 g = gasleft();
        escrow.realize();
        console2.log("BENCH bond realize no earned fee:", g - gasleft());
        _posted();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        g = gasleft();
        escrow.realize();
        console2.log("BENCH bond realize one hour earned:", g - gasleft());
        vm.warp(vm.getBlockTimestamp() + 33 hours);
        g = gasleft();
        escrow.realize(32);
        console2.log("BENCH bond realize 32 bucket walk:", g - gasleft());
    }

    function test_bench_depositNoFeeAndEarned() public {
        uint256 shares = 100 ether;
        (uint256 amount0, uint256 amount1) = lens.previewDeposit(vault, shares);
        _fundLp(lp0, amount0, amount1);
        vm.prank(lp0);
        uint256 g = gasleft();
        vault.deposit(shares, amount0, amount1, lp0);
        console2.log("BENCH deposit with escrow, no earned fee:", g - gasleft());

        _posted();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        (amount0, amount1) = lens.previewDeposit(vault, shares);
        _fundLp(lp0, amount0, amount1);
        vm.prank(lp0);
        g = gasleft();
        vault.deposit(shares, amount0, amount1, lp0);
        console2.log("BENCH deposit with escrow, earned fee:", g - gasleft());
    }

    function test_bench_redeem_andSwaps() public {
        uint256 g = gasleft();
        _redeem(lp0, 100 ether, false);
        console2.log("BENCH redeem with escrow installed:", g - gasleft());
        uint256 a = _allocate(keyA, c1, 10_000 ether);
        g = gasleft();
        _swap(keyA, true, 1000 ether, a);
        console2.log("BENCH swap Hook A with escrow installed:", g - gasleft());
        uint256 b = _allocate(keyB, c1, 10_000 ether);
        g = gasleft();
        _swap(keyB, true, 1000 ether, b);
        console2.log("BENCH swap Hook B with escrow installed:", g - gasleft());
    }
}
