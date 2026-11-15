// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IBondEscrow} from "./interfaces/IBondEscrow.sol";
import {IVaultState} from "./interfaces/IVaultState.sol";
import {VaultStateReader} from "./libraries/VaultStateReader.sol";

/// @title BondEscrow
/// @notice Holds prepaid reservation bonds for one `SharedCommitmentVault`, charges each bond for the capacity it keeps
///         reserved over time, refunds the rest to its payer, and pays the LP part of the earned fees into the vault.
/// @dev
/// What a bond pays for. A reservation (vault allocation) withholds capacity from LP exits and from other
/// reservations for as long as it is open. Its bond is the largest charge it can incur, paid in advance in the reserved
/// asset: Y = ceil(A * (expiry - creation) * rho / 1e18), with A the allocation's maxOut and rho the rate fixed at
/// creation. The charge accrues on the unused remainder r (A minus the consumption the escrow has seen), from creation
/// until the earlier of the expiry and an observed close, and is at least A * min(T_min, expiry - creation) * rho. It
/// accrues whether or not the capacity can actually be sold: pauses, halts, freezes, oracle outages, flow caps and room
/// lost to LP exits do not stop it. The payer's remedy is an early close (the curator's `cancelAllocation`, or the
/// owner's or guardian's emergency `release` in the vault) followed by a sync. A bond is not insurance of execution.
///
/// Custody. Every amount here is an ERC-6909 claim on the PoolManager owned by this contract: bonds are pulled from the
/// payer as ERC-20 and minted to this contract as claims in `post`; refunds and protocol fees leave as ERC-20 through
/// `claimRefund` and `claimProtocol`; LP fees leave as claims, pulled by the vault in `realizeFee` against an allowance
/// of exactly that amount. Nothing else moves claims: there is no owner withdrawal, rescue, sweep, operator grant or
/// upgrade. Claims sent here directly are not counted anywhere and stay here.
///
/// Per asset, after every call (raw units, `Ledger` fields):
///   held = openBonds + settledCharges - realized + refundsOwed + protocolOwed <= PoolManager.balanceOf(this, asset)
///   realized - settledCharges <= floor(accrued / 1e18) <= openBonds
/// So the escrow always holds every refund and protocol fee owed plus the part of every open bond not yet earned.
///
/// Accrual. Each asset keeps an aggregate: `rate` = sum of r * rho over open bonds not yet past their expiry, and
/// `accrued` = sum of every unsettled bond's accrual, both advanced to `last`. Every expiry is an hour boundary, so the
/// rate can only fall at hour ends (besides syncs, which apply at the time of the call): a ring of 720 hourly slots holds,
/// for each upcoming hour, the rate that leaves the aggregate when that hour ends. `_walk` advances the aggregate hour end
/// by hour end, applying each drop at its end, so it stops accruing a bond at exactly the second the bond itself stops
/// (sum of per-bond accruals = aggregate, exactly). Each bond's own accrual is updated only when it is synced: the
/// escrow is not on the swap path and learns of consumption and closes only through `sync`, which anyone may call. A
/// fill synced late is charged x * rho * (sync time - fill time) more than one synced at once: the error is against the
/// payer and in favour of LPs, and the payer removes it by syncing.
///
/// Realization. `target = settledCharges + floor(accrued / 1e18)` is everything earned so far. `realize` moves
/// `target - realized` out of "earned": the protocol part floor(target * pi) - floor(realized * pi) (pi in basis
/// points, rounded down on cumulative totals) is credited to the protocol, the rest is paid into the vault with
/// `realizeFee`. A fee becomes LP property only then; before that it belongs to no LP and is in no share price. The
/// vault's `deposit` calls `realize()` first, so new shares never buy fees earned before them; LP exits never call the
/// escrow, so an LP that exits between realizations leaves its share of the unrealized fees to the remaining shares.
///
/// Roles. `post`: only the vault's authorization module, for the allocation it has just created. Parameter setters:
/// only the vault's owner (in production the `VaultGovernor`, which delays them). Refunds: the payer, to any non-zero
/// recipient it names. Protocol fees: the protocol recipient. `sync`, `settle` and `realize`: anyone. The guardian has
/// no power here. A rate, minimum charge duration and bond, once posted, never change.
///
/// Reentrancy. Posting, syncing, settlement, realization, claims and the protocol-fee change take a transaction-scoped
/// lock. The simple rate, duration and recipient setters only write their parameter after checking the vault owner.
/// External code runs in the pair ERC-20s (pulled in `post`, paid in claims), in the PoolManager, and in the vault
/// (`realizeFee`, `release`, reads); callbacks into locked escrow operations revert.
///
/// Not implemented: payer-initiated or partial early release, suspending accrual while fills are refused,
/// utilization-based pricing, letting a replaced escrow keep paying LPs (after the vault installs another escrow, this
/// one can still sync, settle and refund, but its realizations revert), any yield on held bonds.
contract BondEscrow is IBondEscrow, IUnlockCallback {
    using VaultStateReader for IVaultState;
    using SafeCast for uint256;

    /// @notice Scale of a rate: fee units per reserved unit per second times 1e18.
    uint256 public constant SCALE = 1e18;
    /// @notice Highest rate the owner can set: 1e18 = 100% of the reserved amount per second. Bounds every product:
    ///         A * rho < 2^187 and A * T * rho < 2^209 for A < 2^127 and T < 2^22 seconds.
    uint256 public constant MAX_RATE = 1e18;
    /// @notice Highest protocol share of earned fees, basis points (20%).
    uint256 public constant MAX_PROTOCOL_BPS = 2000;
    /// @notice Longest minimum charge duration the owner can set, seconds (the vault's MAX_HORIZON).
    uint256 public constant MAX_MIN_CHARGE_DURATION = 30 days;
    /// @notice Width of one accrual bucket, seconds; equal to the vault's expiry bucket, so every expiry ends a bucket.
    uint256 public constant BUCKET = 1 hours;
    /// @notice Rate-drop ring slots per asset: the vault's horizon in buckets.
    uint256 public constant SLOTS = 720;
    /// @notice Most buckets `realize()` (the vault's deposit path) walks per asset before giving up with `EscrowBehind`.
    uint256 public constant REALIZE_STEPS = 32;
    /// @dev Largest bond: the PoolManager's int128 limit, as the vault's MAX_AMOUNT.
    uint256 internal constant _MAX_AMOUNT = uint256(uint128(type(int128).max));
    uint256 internal constant _BPS = 10_000;
    /// @dev Transient slot of the reentrancy lock: keccak256("porkfolio.BondEscrow.reentrancyLock").
    bytes32 private constant _LOCK_SLOT = keccak256("porkfolio.BondEscrow.reentrancyLock");

    /// @notice The vault whose reservations this escrow bonds and whose LPs receive the fees.
    IVaultState public immutable vault;
    /// @notice The PoolManager holding every claim.
    IPoolManager public immutable poolManager;
    /// @dev The vault's pair, cached (immutable in the vault).
    Currency internal immutable _asset0;
    Currency internal immutable _asset1;

    /// @dev rho for new bonds, by asset index.
    uint256[2] internal _rates;
    /// @notice Minimum charge duration T_min for new bonds, seconds.
    uint256 public minChargeDuration;
    /// @notice Protocol share pi of earned fees, basis points.
    uint256 public protocolFeeBps;
    /// @notice Account allowed to claim protocol fees; zero: nobody (fees accumulate).
    address public protocolRecipient;

    /// @dev Bonds by vault allocation id; `created == 0` means none.
    mapping(uint256 allocationId => Bond) internal _bonds;
    /// @dev Aggregate per asset index.
    Ledger[2] internal _ledgers;
    /// @dev Rate-drop ring per asset index: slot bucket % SLOTS, tagged with the bucket.
    mapping(uint256 asset => mapping(uint256 index => RateDrop)) internal _drops;
    /// @dev Refunds owed, by payer and asset index.
    mapping(address payer => uint256[2]) internal _refunds;

    /// @dev Which leg `unlockCallback` runs.
    enum Action {
        Pull,
        Pay
    }

    modifier nonReentrant() {
        bytes32 slot = _LOCK_SLOT;
        bool locked;
        assembly ("memory-safe") {
            locked := tload(slot)
        }
        if (locked) revert ReentrantCall();
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    modifier onlyVaultOwner() {
        if (msg.sender != vault.owner()) revert NotOwner(msg.sender);
        _;
    }

    /// @param vault_ Vault served. Its PoolManager and pair are read once and fixed.
    /// @param rate0 rho for asset0, at most MAX_RATE.
    /// @param rate1 rho for asset1, at most MAX_RATE.
    /// @param minDuration T_min, seconds, at most MAX_MIN_CHARGE_DURATION.
    /// @param protocolBps pi, at most MAX_PROTOCOL_BPS.
    /// @param recipient Protocol fee recipient (zero allowed).
    constructor(
        IVaultState vault_,
        uint256 rate0,
        uint256 rate1,
        uint256 minDuration,
        uint256 protocolBps,
        address recipient
    ) {
        if (address(vault_) == address(0)) revert ZeroAddress();
        if (
            rate0 > MAX_RATE || rate1 > MAX_RATE || minDuration > MAX_MIN_CHARGE_DURATION
                || protocolBps > MAX_PROTOCOL_BPS
        ) revert InvalidParameter();
        vault = vault_;
        poolManager = vault_.poolManager();
        _asset0 = vault_.asset0();
        _asset1 = vault_.asset1();
        _rates = [rate0, rate1];
        minChargeDuration = minDuration;
        protocolFeeBps = protocolBps;
        protocolRecipient = recipient;
    }

    // ==================================================================
    // Bond lifecycle
    // ==================================================================

    /// @inheritdoc IBondEscrow
    /// @dev Only the vault's current authorization module, which calls it right after `reserveFor` in the same
    ///      transaction. Checks: this escrow is the vault's fee escrow (`EscrowNotInstalled`: a bond here could never pay
    ///      LPs); `allocationId` is the vault's newest allocation, exists, is unconsumed, unreleased and unexpired
    ///      (`AllocationNotFresh`); it has no bond yet (`AlreadyBonded`); the asset's current rate is at most `maxRate`
    ///      (`RateAboveMax`); the bond fits 2^127 - 1 (`BondTooLarge`).
    ///
    ///      Effects: the asset's aggregate is advanced to now (so the rate change below applies from this second),
    ///      the bond is stored with the current rho and T_min, the aggregate rate and the drop of the expiry's bucket rise
    ///      by A * rho, and `openBonds` by Y. Then Y is pulled: the PoolManager is unlocked, `payer`'s ERC-20 is
    ///      transferred into it (this escrow is the ERC-20 spender), the amount that arrived must equal Y, and Y claims
    ///      are minted to this escrow. With rho = 0 the bond is 0, nothing is pulled and nothing ever accrues. Any
    ///      failure reverts the activation as a whole.
    ///
    ///      Bond: Y = ceil(A * T * rho / 1e18), T = expiry - now <= 30 days. Rounded up, so Y covers the largest
    ///      possible charge. Example: A = 100,000e18, T = 10 days, rho = 1e9: Y = 86.4e18.
    function post(uint256 allocationId, address payer, uint256 maxRate) external nonReentrant returns (uint256 bond) {
        if (msg.sender != vault.authModule()) revert NotAuthModule(msg.sender);
        if (vault.feeEscrow() != address(this)) revert EscrowNotInstalled();
        (address consumer, uint64 expiry, bool released, Currency out, uint128 amount, uint128 consumed) =
            vault.allocationState(allocationId);
        if (
            allocationId + 1 != vault.nextAllocationId() || consumer == address(0) || released || consumed != 0
                || expiry <= block.timestamp
        ) revert AllocationNotFresh(allocationId);
        Bond storage j = _bonds[allocationId];
        if (j.created != 0) revert AlreadyBonded(allocationId);
        uint256 i = _index(out);
        uint256 rho = _rates[i];
        if (rho > maxRate) revert RateAboveMax(rho, maxRate);

        _advance(i, type(uint256).max);
        bond = FullMath.mulDivRoundingUp(uint256(amount) * (expiry - block.timestamp), rho, SCALE);
        if (bond > _MAX_AMOUNT) revert BondTooLarge(bond);

        // forge-lint: disable-start(unsafe-typecast) block.timestamp < 2^64; minChargeDuration <= 30 days;
        // rho <= MAX_RATE < 2^64; i < 2; bond <= _MAX_AMOUNT < 2^128.
        j.payer = payer;
        j.created = uint64(block.timestamp);
        j.minDuration = uint32(minChargeDuration);
        j.expiry = expiry;
        j.last = uint64(block.timestamp);
        j.rate = uint64(rho);
        j.asset = uint8(i);
        j.amount = amount;
        j.remaining = amount;
        j.bond = uint128(bond);
        // forge-lint: disable-end(unsafe-typecast)

        Ledger storage l = _ledgers[i];
        if (rho != 0) {
            uint256 add = uint256(amount) * rho;
            l.rate += add;
            uint256 b = expiry / BUCKET;
            RateDrop storage d = _drops[i][b % SLOTS];
            // A slot holding another tag holds a bucket that has ended; the aggregate is at now, so its drop has been
            // applied (or was zero and skipped). Same argument as the vault's expiry ring.
            if (d.bucket == b) {
                d.amount = (uint256(d.amount) + add).toUint192();
            } else {
                // forge-lint: disable-next-line(unsafe-typecast) b = expiry / 3600 with expiry a uint64.
                d.bucket = uint64(b);
                d.amount = add.toUint192();
            }
        }
        l.openBonds += bond;

        if (bond != 0) _unlock(Action.Pull, payer, i == 0 ? bond : 0, i == 0 ? 0 : bond);
        emit BondPosted(allocationId, payer, out, amount, rho, bond);
    }

    /// @inheritdoc IBondEscrow
    /// @dev Anyone. Reverts for an unknown or settled bond. See `_sync`.
    function sync(uint256 allocationId) external nonReentrant {
        _sync(allocationId);
    }

    /// @inheritdoc IBondEscrow
    /// @dev Anyone, once a sync (run here first) has seen the allocation released, or at or after its expiry
    ///      (`NotSettleable` otherwise). A second call reverts with `AlreadySettled`.
    ///
    ///      charge = ceil(max(accrued, A * min(T_min, expiry - created) * rho) / 1e18), refund = Y - charge.
    ///      charge <= Y: accrued <= A * (expiry - created) * rho because the remainder never exceeds A and accrual stops
    ///      at expiry, and the minimum term is at most the same product; Y is that product over 1e18 rounded up. Rounded
    ///      up, against the payer: less than one raw unit per bond. Example: A = 100,000e18 for 10 days at rho = 1e9,
    ///      30,000e18 consumed and synced on day 2, closed and synced on day 6: accrued = (100,000 * 2 + 70,000 * 4)
    ///      days * 1e9, charge = 41.472e18, refund = 86.4e18 - 41.472e18.
    ///
    ///      Effects: the bond's accrual leaves the aggregate and its charge enters `settledCharges` (target never falls,
    ///      because charge >= ceil(accrued / 1e18)); Y leaves `openBonds`; the refund is credited to the payer. If the
    ///      allocation is still unreleased in the vault (only possible at or after expiry), the escrow then releases it
    ///      there, which is permissionless after expiry and clears the curator's and hook's reserved totals.
    function settle(uint256 allocationId) external nonReentrant returns (uint256 charge, uint256 refund) {
        (Bond storage j, bool released) = _sync(allocationId);
        if (!j.closed && block.timestamp < j.expiry) revert NotSettleable(allocationId);
        uint256 duration = j.expiry - j.created;
        uint256 minDuration = j.minDuration < duration ? j.minDuration : duration;
        uint256 basis = uint256(j.amount) * minDuration * j.rate;
        if (j.accrued > basis) basis = j.accrued;
        charge = (basis + SCALE - 1) / SCALE;
        refund = j.bond - charge;

        // forge-lint: disable-next-line(unsafe-typecast) charge <= bond < 2^128.
        j.charge = uint128(charge);
        j.settled = true;
        uint256 i = j.asset;
        Ledger storage l = _ledgers[i];
        l.accrued -= j.accrued;
        l.settledCharges += charge;
        l.openBonds -= j.bond;
        l.refundsOwed += refund;
        _refunds[j.payer][i] += refund;
        emit BondSettled(allocationId, charge, refund);

        if (!released) IVaultRelease(address(vault)).release(allocationId);
    }

    /// @inheritdoc IBondEscrow
    /// @dev Anyone; the vault calls it at the start of every `deposit`. Walks at most REALIZE_STEPS buckets per asset
    ///      and reverts with `EscrowBehind` if either asset's aggregate does not reach now, so a deposit is never priced
    ///      on a stale realization; `realize(maxSteps)` catches up. See `_realize`.
    function realize() external nonReentrant {
        _realizeBoth(REALIZE_STEPS, true);
    }

    /// @inheritdoc IBondEscrow
    /// @dev Anyone. Realizes what is earned up to where each walk got, which is exact for that time.
    function realize(uint256 maxSteps) external nonReentrant returns (bool caughtUp) {
        return _realizeBoth(maxSteps, false);
    }

    /// @inheritdoc IBondEscrow
    /// @dev The caller's refunds in both assets are zeroed before the payout, then burned and sent as ERC-20 to `to`.
    ///      The payer chooses `to`, so a payer whose own address a token refuses can still be paid. Reverts with
    ///      `ZeroAddress` for `to` = 0 and `NothingToClaim` when nothing is owed. Unclaimed refunds stay owed forever.
    function claimRefund(address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (to == address(0)) revert ZeroAddress();
        uint256[2] storage owed = _refunds[msg.sender];
        amount0 = owed[0];
        amount1 = owed[1];
        if (amount0 == 0 && amount1 == 0) revert NothingToClaim();
        owed[0] = 0;
        owed[1] = 0;
        _ledgers[0].refundsOwed -= amount0;
        _ledgers[1].refundsOwed -= amount1;
        _unlock(Action.Pay, to, amount0, amount1);
        emit RefundClaimed(msg.sender, to, amount0, amount1);
    }

    /// @inheritdoc IBondEscrow
    /// @dev Only `protocolRecipient`. Pays everything credited so far in both assets to `to` (non-zero).
    function claimProtocol(address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (msg.sender != protocolRecipient) revert NotProtocolRecipient(msg.sender);
        if (to == address(0)) revert ZeroAddress();
        amount0 = _ledgers[0].protocolOwed;
        amount1 = _ledgers[1].protocolOwed;
        if (amount0 == 0 && amount1 == 0) revert NothingToClaim();
        _ledgers[0].protocolOwed = 0;
        _ledgers[1].protocolOwed = 0;
        _unlock(Action.Pay, to, amount0, amount1);
        emit ProtocolClaimed(to, amount0, amount1);
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Only the PoolManager, and only inside this escrow's own `unlock` (the PoolManager calls back its caller).
    ///      Pull: `account`'s ERC-20 into the PoolManager, then claims minted to this escrow; the amount that arrived
    ///      must equal the amount asked (fee-on-transfer and similar tokens fail closed). Pay: claims burned, ERC-20 sent
    ///      to `account`. Each leg leaves this escrow's PoolManager delta at zero.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (Action action, address account, uint256 amount0, uint256 amount1) =
            abi.decode(data, (Action, address, uint256, uint256));
        if (action == Action.Pull) {
            _pull(_asset0, account, amount0);
            _pull(_asset1, account, amount1);
        } else {
            _pay(_asset0, account, amount0);
            _pay(_asset1, account, amount1);
        }
        return "";
    }

    // ==================================================================
    // Parameters (the vault's owner only; they apply to bonds posted afterwards)
    // ==================================================================

    /// @notice Set rho for new bonds of `currency`.
    /// @dev Existing bonds keep the rate they were posted with. Curators bound it with the `maxRate` they sign.
    /// @param currency asset0 or asset1.
    /// @param newRate Fee units per reserved unit per second times 1e18; at most MAX_RATE. Zero: free reservations.
    function setRate(Currency currency, uint256 newRate) external onlyVaultOwner {
        if (newRate > MAX_RATE) revert InvalidParameter();
        _rates[_index(currency)] = newRate;
        emit RateSet(currency, newRate);
    }

    /// @notice Set T_min, the minimum charge duration of new bonds.
    /// @dev Existing bonds keep theirs. A bond shorter than T_min is charged for its whole duration at least.
    /// @param duration Seconds, at most MAX_MIN_CHARGE_DURATION.
    function setMinChargeDuration(uint256 duration) external onlyVaultOwner {
        if (duration > MAX_MIN_CHARGE_DURATION) revert InvalidParameter();
        minChargeDuration = duration;
        emit MinChargeDurationSet(duration);
    }

    /// @notice Set pi, the protocol share of fees realized from now on.
    /// @dev Realizes everything earned so far first, at the old share, so the change never applies to fees earned
    ///      before it (that call can revert if the escrow is no longer the vault's fee escrow and has LP fees to pay).
    /// @param bps Basis points, at most MAX_PROTOCOL_BPS.
    function setProtocolFee(uint256 bps) external nonReentrant onlyVaultOwner {
        if (bps > MAX_PROTOCOL_BPS) revert InvalidParameter();
        _realizeBoth(type(uint256).max, true);
        protocolFeeBps = bps;
        emit ProtocolFeeSet(bps);
    }

    /// @notice Set the account that may claim protocol fees (zero: nobody; they accumulate).
    /// @param recipient New recipient.
    function setProtocolRecipient(address recipient) external onlyVaultOwner {
        protocolRecipient = recipient;
        emit ProtocolRecipientSet(recipient);
    }

    // ==================================================================
    // Views
    // ==================================================================

    /// @notice The vault's current owner, the only account allowed to change this escrow's parameters.
    /// @dev Read live; `VaultGovernor` accepts this escrow as a target because it answers the governor here.
    function owner() external view returns (address) {
        return vault.owner();
    }

    /// @notice rho for new bonds of `currency`.
    function rate(Currency currency) external view returns (uint256) {
        return _rates[_index(currency)];
    }

    /// @notice The bond of `allocationId` as stored (all-zero if none). `accrued` is as of `last`.
    function getBond(uint256 allocationId) external view returns (Bond memory) {
        return _bonds[allocationId];
    }

    /// @notice The aggregate of `currency` as stored (`accrued` as of `last`).
    function getLedger(Currency currency) external view returns (Ledger memory) {
        return _ledgers[_index(currency)];
    }

    /// @notice Slot `index` of the rate-drop ring of `currency`.
    function getRateDrop(Currency currency, uint256 index) external view returns (RateDrop memory) {
        return _drops[_index(currency)][index % SLOTS];
    }

    /// @notice Refunds of `payer` in `currency` not yet claimed.
    function refundOf(address payer, Currency currency) external view returns (uint256) {
        return _refunds[payer][_index(currency)];
    }

    /// @inheritdoc IBondEscrow
    /// @dev Walks the ring like `realize` without writing; at most 720 buckets. Nothing on-chain calls it; `VaultLens`
    ///      uses `lpPart` to price deposits as `deposit` will (it realizes first).
    function unrealized(Currency currency) external view returns (uint256 lpPart, uint256 protocolPart) {
        uint256 i = _index(currency);
        Ledger storage l = _ledgers[i];
        (uint256 acc,,,) = _walk(i, l.last, l.rate, l.accrued, type(uint256).max);
        uint256 target = l.settledCharges + acc / SCALE;
        uint256 done = l.realized;
        uint256 bps = protocolFeeBps;
        protocolPart = target * bps / _BPS - done * bps / _BPS;
        lpPart = target - done - protocolPart;
    }

    // ==================================================================
    // Internal
    // ==================================================================

    /// @dev Brings bond `allocationId` up to date and returns it, with whether the vault has released its allocation.
    ///      1. The asset's aggregate is advanced to now (a rate change below must apply from now).
    ///      2. The bond accrues remaining * rho * (t - last) with t = min(now, expiry).
    ///      3. Consumption the escrow had not seen (vault `consumed` - `synced`) leaves the remainder; if the vault has
    ///         released the allocation, the whole remainder leaves and the bond is closed. While now < expiry, the
    ///         aggregate rate and the drop of the bond's bucket fall by the removed amount * rho; after expiry the drop
    ///         has already been applied. A closed bond's remainder is 0 and it accrues nothing more.
    ///      The bucket of an unexpired bond is still resident in its ring slot: its tag is above the current bucket,
    ///      and a slot is rewritten only for a bucket at least 720 later.
    function _sync(uint256 allocationId) internal returns (Bond storage j, bool released) {
        j = _bonds[allocationId];
        if (j.created == 0) revert UnknownBond(allocationId);
        if (j.settled) revert AlreadySettled(allocationId);
        uint256 i = j.asset;
        _advance(i, type(uint256).max);

        uint256 expiry = j.expiry;
        uint256 t = block.timestamp < expiry ? block.timestamp : expiry;
        uint256 rho = j.rate;
        if (t > j.last) {
            j.accrued += uint256(j.remaining) * rho * (t - j.last);
            // forge-lint: disable-next-line(unsafe-typecast) t <= expiry, a uint64.
            j.last = uint64(t);
        }

        if (j.closed) return (j, true); // closed means a sync saw the allocation released
        uint128 consumed;
        (,, released,,, consumed) = vault.allocationState(allocationId);
        uint256 removed = released ? j.remaining : consumed - j.synced;
        j.synced = consumed;
        if (released) j.closed = true;
        if (removed != 0) {
            // forge-lint: disable-next-line(unsafe-typecast) removed <= remaining, a uint128.
            j.remaining -= uint128(removed);
            if (block.timestamp < expiry && rho != 0) {
                uint256 drop = removed * rho;
                _ledgers[i].rate -= drop;
                RateDrop storage d = _drops[i][(expiry / BUCKET) % SLOTS];
                // forge-lint: disable-next-line(unsafe-typecast) drop <= d.amount < 2^192.
                d.amount -= uint192(drop);
            }
        }
        emit BondSynced(allocationId, consumed, j.remaining, j.closed);
    }

    /// @dev Advances both aggregates (at most `maxSteps` buckets each) and realizes each. With `strict`, an asset that
    ///      did not reach now reverts the call with `EscrowBehind`.
    function _realizeBoth(uint256 maxSteps, bool strict) internal returns (bool caughtUp) {
        caughtUp = true;
        for (uint256 i; i < 2; ++i) {
            if (!_advance(i, maxSteps)) {
                if (strict) revert EscrowBehind(_asset(i));
                caughtUp = false;
            }
            _realize(i);
        }
    }

    /// @dev Moves everything earned in asset `i` (up to the aggregate's `last`) out of "earned".
    ///          target    = settledCharges + floor(accrued / 1e18)
    ///          protocolD = floor(target * pi / 10,000) - floor(realized * pi / 10,000)
    ///          lpD       = target - realized - protocolD
    ///      `target` never decreases (settlement moves at least ceil(accrued_j / 1e18) into settledCharges while removing
    ///      accrued_j from the aggregate, and floor(x) <= floor(x - y) + ceil(y)), so target >= realized. Taking the
    ///      protocol share on cumulative totals makes the split independent of how often this runs: the protocol loses
    ///      less than one raw unit in total to rounding, LPs gain it. lpD is paid with an allowance of exactly lpD and the
    ///      vault's `realizeFee`, which pulls exactly that and consumes the allowance. Example: target 35.424e18,
    ///      realized 0, pi = 1,000: protocol 3.5424e18, LPs 31.8816e18.
    function _realize(uint256 i) internal {
        Ledger storage l = _ledgers[i];
        uint256 target = l.settledCharges + l.accrued / SCALE;
        uint256 done = l.realized;
        if (target == done) return;
        uint256 bps = protocolFeeBps;
        uint256 protocolPart = target * bps / _BPS - done * bps / _BPS;
        uint256 lpPart = target - done - protocolPart;
        l.realized = target;
        l.protocolOwed += protocolPart;
        Currency c = _asset(i);
        if (lpPart != 0) {
            poolManager.approve(address(vault), c.toId(), lpPart);
            vault.realizeFee(c, lpPart);
        }
        emit FeesRealized(c, lpPart, protocolPart);
    }

    /// @dev Advances the aggregate of asset `i` to now, or by `maxSteps` bucket ends if that comes first, and stores it.
    ///      Returns whether it reached now. See `_walk`.
    function _advance(uint256 i, uint256 maxSteps) internal returns (bool done) {
        Ledger storage l = _ledgers[i];
        if (l.last == block.timestamp) return true;
        uint256 acc;
        uint256 rt;
        uint256 last;
        (acc, rt, last, done) = _walk(i, l.last, l.rate, l.accrued, maxSteps);
        l.accrued = acc;
        l.rate = rt;
        // forge-lint: disable-next-line(unsafe-typecast) last <= block.timestamp < 2^64.
        l.last = uint64(last);
    }

    /// @dev The aggregate of asset `i` advanced from `last` towards now: between bucket ends it grows by rt * dt; at the
    ///      end of bucket b the drop tagged b leaves rt. Every expiry is a bucket end, so each bond's rate leaves exactly
    ///      at its expiry.
    ///
    ///      Shortcut: rt is the sum of the drops not yet applied (each bond contributes remaining * rho to both while it
    ///      is open and unexpired), so rt = 0 means every remaining drop is zero and nothing accrues until the next post;
    ///      the walk jumps to now. Bound: `post` leaves the aggregate at now and writes a bucket at most 720 ahead, so
    ///      after at most 720 bucket ends since the latest post every drop has been applied, rt is 0, and the walk ends.
    ///      `maxSteps` caps the bucket ends visited; `done` is false if it stopped at a bucket end before now.
    ///
    ///      Overflow: rt <= the sum of A * rho over open bonds; each term < 2^187, and acc grows by rt * dt; checked
    ///      arithmetic reverts rather than wraps.
    function _walk(uint256 i, uint256 last, uint256 rt, uint256 acc, uint256 maxSteps)
        internal
        view
        returns (uint256, uint256, uint256, bool done)
    {
        uint256 t = block.timestamp;
        if (t <= last) return (acc, rt, last, true);
        done = true;
        if (rt != 0) {
            uint256 b = last / BUCKET + 1;
            for (uint256 steps; b * BUCKET <= t; ++steps) {
                if (steps == maxSteps) {
                    done = false;
                    break;
                }
                uint256 end = b * BUCKET;
                acc += rt * (end - last);
                last = end;
                RateDrop storage d = _drops[i][b % SLOTS];
                if (d.bucket == b) rt -= d.amount;
                if (rt == 0) break;
                ++b;
            }
        }
        if (done) {
            acc += rt * (t - last);
            last = t;
        }
        return (acc, rt, last, done);
    }

    /// @dev Moves `amount` of ERC-20 from `payer` into the PoolManager and mints the same claims to this escrow
    ///      (sync, transfer, settle, mint: net delta zero). `settle` reports what arrived; anything else reverts.
    function _pull(Currency currency, address payer, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.sync(currency);
        SafeTransferLib.safeTransferFrom(ERC20(Currency.unwrap(currency)), payer, address(poolManager), amount);
        uint256 paid = poolManager.settle();
        if (paid != amount) revert SettlementMismatch(amount, paid);
        poolManager.mint(address(this), currency.toId(), amount);
    }

    /// @dev Burns `amount` of this escrow's claims and sends the same ERC-20 amount to `to` (net delta zero).
    function _pay(Currency currency, address to, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, to, amount);
    }

    function _unlock(Action action, address account, uint256 amount0, uint256 amount1) internal {
        poolManager.unlock(abi.encode(action, account, amount0, amount1));
    }

    /// @dev 0 for asset0, 1 for asset1; `InvalidCurrency` otherwise.
    function _index(Currency currency) internal view returns (uint256) {
        if (currency == _asset0) return 0;
        if (currency == _asset1) return 1;
        revert InvalidCurrency();
    }

    function _asset(uint256 i) internal view returns (Currency) {
        return i == 0 ? _asset0 : _asset1;
    }
}

/// @dev The vault's permissionless-after-expiry `release`, which `settle` calls; not part of `IVaultState`.
interface IVaultRelease {
    function release(uint256 allocationId) external;
}
