// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {SharedCommitmentVault} from "../../src/SharedCommitmentVault.sol";
import {BondEscrow} from "../../src/BondEscrow.sol";
import {CommitmentAuthorizer} from "../../src/CommitmentAuthorizer.sol";
import {ICommitmentAuthorizer} from "../../src/interfaces/ICommitmentAuthorizer.sol";
import {ICuratorAuthorization} from "../../src/interfaces/ICuratorAuthorization.sol";
import {ISharedCommitmentVault} from "../../src/interfaces/ISharedCommitmentVault.sol";
import {IBondEscrow} from "../../src/interfaces/IBondEscrow.sol";
import {IVaultState} from "../../src/interfaces/IVaultState.sol";
import {AuthTestBase} from "./AuthTestBase.sol";
import {ProductionArtifacts} from "./ProductionArtifacts.sol";
import {ScriptedHook} from "./ScriptedHook.sol";

/// @notice Fixture for the bond tests: the production fixture with a `BondEscrow` installed as the vault's fee escrow
///         and a `CommitmentAuthorizer` installed as its authorization module, both deployed from their production
///         artifacts. Every `_allocate` is a bonded direct activation paid by the curator. A third consumer, the
///         test-only `ScriptedHook` on pool `keyS`, fills 1:1 at the 1:1 floor, so a swap of x consumes exactly x.
/// @dev Defaults: rho = 1e9 on both assets (about 3.15% a year), T_min = 1 hour, protocol share 10%. The unbonded module
///      `auth` from the base fixture is retired by the installation.
abstract contract BondTestBase is AuthTestBase {
    uint256 internal constant RHO = 1e9;
    uint256 internal constant T_MIN = 1 hours;
    uint256 internal constant PROTOCOL_BPS = 1000;
    uint256 internal constant PAYER_FUNDS = 1e30;

    BondEscrow internal escrow;
    CommitmentAuthorizer internal bonded;
    address internal payer = makeAddr("payer");
    address internal protocol = makeAddr("protocolRecipient");
    ScriptedHook internal hookS;
    PoolKey internal keyS;

    function setUp() public virtual override {
        super.setUp();
        address h = address(uint160(0x5C1 << 140) | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        deployCodeTo("ScriptedHook.sol:ScriptedHook", abi.encode(manager, vault), h);
        hookS = ScriptedHook(h);
        keyS = PoolKey(c0, c1, 3000, 60, IHooks(h));
        manager.initialize(keyS, SQRT_PRICE_1_1);
        vm.prank(owner);
        vault.setConsumer(h, true);
        _openLimitsAsOwner(ISharedCommitmentVault.RiskScope.Hook, h);

        escrow = _deployEscrow(vault, RHO, RHO, T_MIN, PROTOCOL_BPS, protocol);
        bonded = _deployBonded(vault, escrow);
        vm.startPrank(owner);
        vault.setFeeEscrow(address(escrow));
        vault.setAuthModule(address(bonded));
        vm.stopPrank();
        _fundPayer(curator);
        _fundPayer(payer);
        _fundPayer(signer);
    }

    function _deployEscrow(
        SharedCommitmentVault v,
        uint256 rate0,
        uint256 rate1,
        uint256 minDuration,
        uint256 protocolBps,
        address recipient
    ) internal returns (BondEscrow) {
        return BondEscrow(
            deployCode(
                ProductionArtifacts.escrow(),
                abi.encode(IVaultState(address(v)), rate0, rate1, minDuration, protocolBps, recipient)
            )
        );
    }

    function _deployBonded(SharedCommitmentVault v, BondEscrow e) internal returns (CommitmentAuthorizer) {
        return CommitmentAuthorizer(
            deployCode(
                ProductionArtifacts.commitmentAuthorizer(), abi.encode(IVaultState(address(v)), IBondEscrow(address(e)))
            )
        );
    }

    /// @dev Mints both tokens to `p` and approves the escrow, which pulls bonds.
    function _fundPayer(address p) internal {
        token0.mint(p, PAYER_FUNDS);
        token1.mint(p, PAYER_FUNDS);
        vm.startPrank(p);
        token0.approve(address(escrow), type(uint256).max);
        token1.approve(address(escrow), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Bonded direct activation by the curator (curator = payer), accepting any rate.
    function _allocate(PoolKey memory key, Currency out, uint128 maxOut) internal virtual override returns (uint256) {
        return _allocateUntil(key, out, maxOut, _hourAligned(vm.getBlockTimestamp() + 1 days));
    }

    function _allocateUntil(PoolKey memory key, Currency out, uint128 maxOut, uint64 expiry)
        internal
        returns (uint256 id)
    {
        ISharedCommitmentVault.AllocationRequest memory req = _request(key, out, maxOut);
        req.expiry = expiry;
        req.deadline = uint64(vm.getBlockTimestamp());
        vm.prank(curator);
        id = bonded.activateDirectBonded(req, type(uint256).max);
    }

    /// @dev A bonded instruction by `cur` naming `who` as payer and `maxRate`.
    function _bondedAuthz(address cur, PoolKey memory key, Currency out, uint128 maxOut, address who, uint256 maxRate)
        internal
        returns (ICommitmentAuthorizer.BondedAuthorization memory b)
    {
        ICuratorAuthorization.AllocationAuthorization memory a = _authz(cur, key, out, maxOut);
        b = ICommitmentAuthorizer.BondedAuthorization({allocation: a, payer: who, maxRate: maxRate});
    }

    function _signBonded(uint256 pk, ICommitmentAuthorizer.BondedAuthorization memory b)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, bonded.hashBondedAuthorization(b));
        return abi.encodePacked(r, s, v);
    }

    /// @dev The escrow's accounted claims of `c`: open bonds + settled charges - realized + refunds owed + protocol
    ///      owed (the left side of the escrow identity).
    function _escrowHeld(Currency c) internal view returns (uint256) {
        IBondEscrow.Ledger memory l = escrow.getLedger(c);
        return l.openBonds + l.settledCharges - l.realized + l.refundsOwed + l.protocolOwed;
    }

    /// @dev The escrow identity of both assets: accounted claims equal the real claim balance (no donations in these
    ///      tests), realized - settled <= floor(accrued / 1e18) <= open bonds, and the aggregate rate equals the sum of
    ///      the unapplied ring drops (each open, unexpired bond contributes remaining * rho to both).
    function _assertEscrowIdentity() internal view {
        Currency[2] memory cs = [c0, c1];
        for (uint256 i; i < 2; ++i) {
            IBondEscrow.Ledger memory l = escrow.getLedger(cs[i]);
            assertEq(_escrowHeld(cs[i]), _claims(address(escrow), cs[i]), "escrow held != claims");
            assertLe(l.realized, l.settledCharges + l.accrued / 1e18, "realized beyond earned");
            assertLe(l.accrued / 1e18, l.openBonds, "earned beyond open bonds");
            uint256 applied = l.last / 1 hours;
            uint256 sum;
            for (uint256 k; k < 720; ++k) {
                IBondEscrow.RateDrop memory d = escrow.getRateDrop(cs[i], k);
                if (d.bucket > applied) sum += d.amount;
            }
            assertEq(sum, l.rate, "rate != sum of unapplied drops");
        }
    }
}
