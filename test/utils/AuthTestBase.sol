// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {ICuratorAuthorization} from "../../src/interfaces/ICuratorAuthorization.sol";
import {CuratorAuthorization} from "../../src/CuratorAuthorization.sol";
import {VaultTestBase} from "./VaultTestBase.sol";
import {Mock1271Wallet} from "./Mock1271Wallet.sol";

/// @notice Shared fixture for the authorization tests: the production fixture plus an EOA curator with a known key,
///         a contract-wallet curator, and helpers that build, sign and submit `AllocationAuthorization`s.
abstract contract AuthTestBase is VaultTestBase {
    address internal signer; // EOA curator whose private key the tests hold
    uint256 internal signerKey;
    address internal relayer = makeAddr("relayer"); // submits signed instructions; has no role anywhere
    address internal guardian = makeAddr("guardian");
    Mock1271Wallet internal wallet; // ERC-1271 curator

    function setUp() public virtual override {
        super.setUp();
        (signer, signerKey) = makeAddrAndKey("signerCurator");
        wallet = new Mock1271Wallet();
        vm.startPrank(owner);
        vault.setGuardian(guardian);
        _registerCurator(signer);
        _registerCurator(address(wallet));
        vm.stopPrank();
    }

    /// @dev Registers `c` with ceilings of VAULT_FUNDING in both assets and open curator-scope limits. Caller must be
    ///      pranking as the owner.
    function _registerCurator(address c) internal {
        vault.setCurator(c, true);
        vault.setCuratorCeiling(c, c0, VAULT_FUNDING);
        vault.setCuratorCeiling(c, c1, VAULT_FUNDING);
        _openLimits(ISharedCommitmentVault.RiskScope.Curator, c);
    }

    /// @dev An instruction by `cur` for `maxOut` of `out` on `key`, valid now for one hour, allocation lifetime one day,
    ///      at the vault floor, under the curator's current generation, for this fixture's vault.
    function _authz(address cur, PoolKey memory key, Currency out, uint128 maxOut)
        internal
        returns (ICuratorAuthorization.AllocationAuthorization memory a)
    {
        bool outIs1 = out == key.currency1;
        uint256 now_ = vm.getBlockTimestamp(); // not block.timestamp: via-IR may reuse a read from before vm.warp
        a = ICuratorAuthorization.AllocationAuthorization({
            curator: cur,
            generation: vault.getCurator(cur).generation,
            vault: address(vault),
            poolId: key.toId(),
            hook: address(key.hooks),
            currencyIn: outIs1 ? key.currency0 : key.currency1,
            currencyOut: out,
            zeroForOne: outIs1,
            maxOut: maxOut,
            minInPerOutX96: PRICE_1_1_X96,
            expiry: uint64(now_ + 1 days),
            validAfter: uint64(now_),
            deadline: uint64(now_ + 1 hours),
            nonce: nextNonce++
        });
    }

    /// @dev 65-byte ECDSA signature (r, s, v) by `pk` over the module's digest of `a`.
    function _sign(uint256 pk, ICuratorAuthorization.AllocationAuthorization memory a)
        internal
        view
        returns (bytes memory)
    {
        return _signWith(auth, pk, a);
    }

    function _signWith(CuratorAuthorization m, uint256 pk, ICuratorAuthorization.AllocationAuthorization memory a)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, m.hashAuthorization(a));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Submits `a` through the module as `relayer`.
    function _activate(ICuratorAuthorization.AllocationAuthorization memory a, PoolKey memory key, bytes memory sig)
        internal
        returns (uint256)
    {
        vm.prank(relayer);
        return auth.activate(a, key, sig);
    }

    /// @dev Signs `a` by `signer` and submits it as `relayer`.
    function _signAndActivate(ICuratorAuthorization.AllocationAuthorization memory a, PoolKey memory key)
        internal
        returns (uint256)
    {
        return _activate(a, key, _sign(signerKey, a));
    }

    /// @dev Expects the next call to revert with `err` from the module (no arguments).
    function _expectModuleError(bytes4 err) internal {
        vm.expectRevert(abi.encodeWithSelector(err));
    }

    /// @dev Direct-path request equivalent to `a` (same hook, key, currency, amount, floor, expiry, nonce, deadline).
    function _toRequest(ICuratorAuthorization.AllocationAuthorization memory a, PoolKey memory key)
        internal
        pure
        returns (ISharedCommitmentVault.AllocationRequest memory)
    {
        return ISharedCommitmentVault.AllocationRequest({
            consumer: a.hook,
            key: key,
            currencyOut: a.currencyOut,
            maxOut: a.maxOut,
            minInPerOutX96: a.minInPerOutX96,
            expiry: a.expiry,
            nonce: a.nonce,
            deadline: a.deadline
        });
    }
}
