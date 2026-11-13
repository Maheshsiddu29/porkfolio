// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {ERC4626} from "solmate/src/mixins/ERC4626.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title MockYieldVault
/// @notice TEST-ONLY generic ERC-4626 strategy (solmate mixin, no virtual-share offset). Tests make it gain (mint
///         assets to it), lose (burn its assets), pause, cap the assets it can return now, and charge a withdrawal fee.
contract MockYieldVault is ERC4626 {
    bool public paused;
    uint256 public feeBps;
    /// @dev Assets the strategy can return at once; the rest is deployed where it cannot be recalled immediately.
    uint256 public liquidity = type(uint256).max;

    constructor(ERC20 asset_) ERC4626(asset_, "Mock yield vault", "mYV") {}

    function totalAssets() public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function setFeeBps(uint256 feeBps_) external {
        feeBps = feeBps_;
    }

    function setLiquidity(uint256 liquidity_) external {
        liquidity = liquidity_;
    }

    /// @dev Assets after the withdrawal fee. The fee stays in the strategy, for its remaining holders.
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        uint256 a = convertToAssets(shares);
        return a - a * feeBps / 10_000;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        if (paused) return 0;
        uint256 balance = balanceOf[owner];
        if (liquidity >= totalAssets()) return balance;
        uint256 capped = convertToShares(liquidity);
        return capped < balance ? capped : balance;
    }

    function maxDeposit(address) public view override returns (uint256) {
        return paused ? 0 : type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        return paused ? 0 : type(uint256).max;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        require(!paused, "PAUSED");
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        require(!paused, "PAUSED");
        return super.mint(shares, receiver);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        require(!paused, "PAUSED");
        require(convertToAssets(shares) <= liquidity, "ILLIQUID");
        return super.redeem(shares, receiver, owner);
    }

    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert("UNUSED");
    }
}

/// @title InKindYieldLedger
/// @notice TEST-ONLY model of one asset's ledger under the recommended idle-yield design (FUTURE_CAPITAL_AND_YIELD_
///         ACCOUNTING.md §3, design Y1): external ERC-4626 shares are part of every LP share's basket and are paid out
///         in kind. No valuation of the external position is ever needed.
/// @dev The ledger's own token balance stands for physical ERC-6909 backing B. Notation as in the vault, plus:
///        Z   external shares owned by the LP shares (internal count; shares sent here directly are not counted);
///        K   liquidity buffer kept physical for instant exits;
///        N   = B - W, physical net assets.
///      Reservations (Q) and the buffer (R) are admitted against physical N only, so no commitment relies on the
///      external position. Deployment leaves Q, R, the queue's claim D and K physical.
contract InKindYieldLedger {
    uint256 internal constant BPS = 10_000;

    MockERC20 public immutable asset;
    MockYieldVault public immutable ext;

    uint256 public B;
    uint256 public W;
    uint256 public Q;
    uint256 public R;
    uint256 public K;
    uint256 public Z;
    uint256 public S;
    uint256 public P;

    error ExceedsDeployable(uint256 amount, uint256 deployable);
    error ExceedsAdmissible(uint256 amount, uint256 admissible);
    error ValueCheckFailed(uint256 redeemable, uint256 deposited);
    error RecallBelowMinimum(uint256 assets, uint256 minimum);
    error NotDeliverable();

    constructor(MockERC20 asset_, MockYieldVault ext_, uint256 bufferFloor, uint256 liquidityBuffer) {
        asset = asset_;
        ext = ext_;
        R = bufferFloor;
        K = liquidityBuffer;
        asset_.approve(address(ext_), type(uint256).max);
    }

    function _sub0(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    function net() public view returns (uint256) {
        return B - W;
    }

    /// @notice D = ceil(P * N / S) on the physical part. The queue's external part is paid in kind and needs no
    ///         physical inventory.
    function pendingDemand() public view returns (uint256) {
        return P == 0 ? 0 : FullMath.mulDivRoundingUp(P, net(), S);
    }

    /// @notice New reservations: max(0, N - Q - R - D) on physical assets only.
    function admissible() public view returns (uint256) {
        return _sub0(_sub0(_sub0(net(), Q), R), pendingDemand());
    }

    /// @notice Physical assets that may move to the strategy: max(0, N - Q - R - D - K).
    function deployable() public view returns (uint256) {
        return _sub0(admissible(), K);
    }

    function seed(uint256 amount, address from) external {
        asset.transferFrom(from, address(this), amount);
        B = amount;
        S = amount;
    }

    function reserve(uint256 q) external {
        uint256 adm = admissible();
        if (q > adm) revert ExceedsAdmissible(q, adm);
        Q += q;
    }

    function queueShares(uint256 s) external {
        P += s;
    }

    /// @notice Move `x` physical assets into the strategy. Refuses if what the new shares redeem for right away is
    ///         below x * (1 - maxLossBps): this catches an inflated share price (donation attack) and entry fees.
    function deploy(uint256 x, uint256 maxLossBps) external returns (uint256 z) {
        uint256 d = deployable();
        if (x > d) revert ExceedsDeployable(x, d);
        z = ext.deposit(x, address(this));
        uint256 redeemable = ext.previewRedeem(z);
        if (redeemable * BPS < x * (BPS - maxLossBps)) revert ValueCheckFailed(redeemable, x);
        B -= x;
        Z += z;
    }

    /// @notice Best-effort return of `z` external shares to physical. Any shortfall against their pre-fee value is a
    ///         realized loss shared by every share through N.
    function recall(uint256 z, uint256 minAssets) external returns (uint256 assets) {
        assets = ext.redeem(z, address(this), address(this));
        if (assets < minAssets) revert RecallBelowMinimum(assets, minAssets);
        Z -= z;
        B += assets;
    }

    /// @notice Buy `s` shares: ceil(s * N / S) physical, plus ceil(s * Z / S) external shares minted by the strategy
    ///         at the depositor's expense (`previewMint` rounds up, against the depositor).
    function deposit(uint256 s, address from) external returns (uint256 physical, uint256 forExternal) {
        physical = FullMath.mulDivRoundingUp(s, net(), S);
        uint256 z = FullMath.mulDivRoundingUp(s, Z, S);
        asset.transferFrom(from, address(this), physical);
        if (z != 0) {
            forExternal = ext.previewMint(z);
            asset.transferFrom(from, address(this), forExternal);
            ext.mint(z, address(this));
        }
        B += physical;
        Z += z;
        S += s;
    }

    /// @notice Redeem `s` shares instantly: floor(s * N / S) physical, which free inventory must cover, and
    ///         floor(s * Z / S) external shares transferred in kind. The strategy's liquidity is never read.
    function redeem(uint256 s, address to) external returns (uint256 physical, uint256 z) {
        physical = FullMath.mulDiv(s, net(), S);
        if (physical > net() - Q) revert NotDeliverable();
        z = FullMath.mulDiv(s, Z, S);
        B -= physical;
        Z -= z;
        S -= s;
        asset.transfer(to, physical);
        ext.transfer(to, z);
    }
}

/// @title BookValueLedger
/// @notice TEST-ONLY model of the alternative design (Y2): the external position is carried at a book value C and
///         exits are paid in physical assets at floor(s * (B + C) / S). Used only to show what goes wrong when C is
///         stale: a loss in the strategy is not seen until someone calls `poke`.
contract BookValueLedger {
    MockERC20 public immutable asset;
    MockYieldVault public immutable ext;
    uint256 public B;
    uint256 public Z;
    uint256 public C;
    uint256 public S;

    constructor(MockERC20 asset_, MockYieldVault ext_) {
        asset = asset_;
        ext = ext_;
        asset_.approve(address(ext_), type(uint256).max);
    }

    function seed(uint256 amount, address from) external {
        asset.transferFrom(from, address(this), amount);
        B = amount;
        S = amount;
    }

    function deploy(uint256 x) external {
        Z += ext.deposit(x, address(this));
        B -= x;
        C += x;
    }

    /// @notice Impairment: lower C to what the shares redeem for now. Never raises it.
    function poke() external {
        uint256 v = ext.previewRedeem(Z);
        if (v < C) C = v;
    }

    function redeem(uint256 s, address to) external returns (uint256 paid) {
        paid = FullMath.mulDiv(s, B + C, S);
        require(paid <= B, "ILLIQUID");
        B -= paid;
        S -= s;
        asset.transfer(to, paid);
    }
}
