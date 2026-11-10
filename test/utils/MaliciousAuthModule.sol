// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISharedCommitmentVault, AUTH_MODULE_ID} from "../../src/interfaces/ISharedCommitmentVault.sol";

/// @title MaliciousAuthModule — TEST ONLY.
/// @notice Models a compromised authorization module: once installed, it calls `reserveFor` with whatever curator,
///         generation and request the attacker chooses, with no signature, and may also try any other vault call.
///         Used to show that the vault's own checks bound what a module can do.
/// @dev It gives both answers the vault's installation check asks for (`authModuleId()` and `vault()`), as any
///      malicious module can, so the check accepts it. That is the limit of an interface check.
contract MaliciousAuthModule {
    ISharedCommitmentVault public immutable vault;

    constructor(ISharedCommitmentVault vault_) {
        vault = vault_;
    }

    function authModuleId() external pure returns (bytes32) {
        return AUTH_MODULE_ID;
    }

    function forge(ISharedCommitmentVault.AllocationRequest calldata req, address curator, uint32 generation)
        external
        returns (uint256)
    {
        return vault.reserveFor(req, curator, generation);
    }

    function exec(address to, bytes calldata data) external returns (bytes memory ret) {
        bool ok;
        (ok, ret) = to.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
