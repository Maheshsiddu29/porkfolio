// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {CuratorAuthorization} from "../../src/CuratorAuthorization.sol";
import {VaultStateReader} from "../../src/libraries/VaultStateReader.sol";

using VaultStateReader for SharedCommitmentVault;

/// @dev Stand-in for the governor's admin multisig: runs a list of calls in one transaction and reverts with the first
///      failure's revert data. Release, `processQueue` and `execute` in one batch is the procedure the governor's
///      documentation prescribes for a LONG_DELAY change.
contract AdminBatch {
    struct Call {
        address target;
        bytes data;
    }

    address internal immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function run(Call[] calldata calls) external {
        require(msg.sender == signer, "not signer");
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = calls[i].target.call(calls[i].data);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }
}

/// @dev One party that is both a registered curator (direct path of the authorization module) and an LP. `rotate`
///      cancels its commitments, commits every admissible unit again and queues a few shares, all in one transaction,
///      so there is no block in which its newest request is covered by free inventory.
contract QueueGriefer {
    SharedCommitmentVault internal immutable vault;
    CuratorAuthorization internal immutable auth;
    Currency internal immutable out;
    PoolKey internal key;
    uint256 internal nonce;
    uint256[] internal live;

    constructor(SharedCommitmentVault vault_, CuratorAuthorization auth_, PoolKey memory key_, Currency out_) {
        (vault, auth, key, out) = (vault_, auth_, key_, out_);
        MockERC20(Currency.unwrap(key_.currency0)).approve(address(vault_), type(uint256).max);
        MockERC20(Currency.unwrap(key_.currency1)).approve(address(vault_), type(uint256).max);
    }

    function deposit(uint256 shares) external {
        vault.deposit(shares, type(uint256).max, type(uint256).max, address(this));
    }

    function liveAllocation() external view returns (uint256) {
        return live.length == 0 ? 0 : live[live.length - 1];
    }

    /// @dev Commits every unit of `out` the admission rule allows right now, for `horizon` seconds.
    function commitAll(uint256 horizon) public returns (uint256 id) {
        ISharedCommitmentVault.AllocationRequest memory r = ISharedCommitmentVault.AllocationRequest({
            consumer: address(key.hooks),
            key: key,
            currencyOut: out,
            maxOut: uint128(vault.admissibleCapacity(out)),
            minInPerOutX96: uint160(FixedPoint96.Q96),
            expiry: uint64(block.timestamp + horizon),
            nonce: nonce++,
            deadline: uint64(block.timestamp)
        });
        id = auth.activateDirect(r);
        live.push(id);
    }

    function queue(uint256 shares) public returns (uint256 rid) {
        (,,, rid) = vault.redeem(shares, 0, 0, address(this), true);
        require(rid != 0, "not queued");
    }

    function rotate(uint256 horizon, uint256 shares) external returns (uint256 rid) {
        for (uint256 i; i < live.length; ++i) {
            if (!vault.getAllocation(live[i]).released) vault.cancelAllocation(live[i]); // skip expired-and-released
        }
        delete live;
        commitAll(horizon);
        rid = queue(shares);
    }
}
