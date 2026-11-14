"""G05 size probe: apply candidate V2 changes to a SCRATCH COPY of SharedCommitmentVault.sol, for measurement only.

Not production code and not a design to apply as is: the edits are the smallest code that exercises each candidate
change so that its runtime size can be measured. docs/architecture/G05_V2_ARCHITECTURE.md section 8 lists the results.

Usage (never on the repository's own src/):
    1. copy src/, foundry.toml and remappings.txt into a scratch directory and symlink lib/ into it;
    2. copy test/model/ExpiryRing.sol to <scratch>/src/ExpiryRing.sol (flag C imports it);
    3. for flag X, delete the getAllocation declaration from <scratch>/src/interfaces/ISharedCommitmentVault.sol;
    4. python3 g05-vault-size-probe.py <scratch>/src/SharedCommitmentVault.sol FLAGS
    5. (cd <scratch> && forge build --sizes src/SharedCommitmentVault.sol)

Flags (combine freely, e.g. ACFXT):
    A  room-aware admission: Q + q <= N - L in reserveFor (R-15)
    B  fee entry, first draft: unlock-based realizeFees + restructured deposit lock (superseded by F)
    C  bucketed expiry ring (1 h buckets, K = 720, 32-step sweeps) with a liveReserved view
    S  one internal sweep of both assets for the two LP paths (made no difference)
    V  drop the liveReserved view
    F  fee entry, lean: escrow-only realizeFee pulling ERC-6909 claims, deposit calls escrow.realize()
    E  ring held in a separate ledger contract the vault calls (instead of C)
    G  degenerate ring (K = 1): zero Q once every reservation of the asset has expired (instead of C)
    X  getters behind one extsload(bytes32); keeps what hooks, the governor, scripts and the auth module call
    T  C-1 per-asset backing (TVL) cap checked in deposit
"""
import sys, re
path, flags = sys.argv[1], sys.argv[2]
s = open(path).read()

def rep(old, new, count=1):
    global s
    assert s.count(old) >= 1, ("missing", old[:80])
    s = s.replace(old, new, count)

if 'A' in flags:  # room-aware admission (R-15 / B1)
    rep("""        _checkExposure(RiskScope.Hook, consumer, out, hookReserved[consumer][out], maxOut, eligible);""",
        """        _checkRoom(out, maxOut);
        _checkExposure(RiskScope.Hook, consumer, out, hookReserved[consumer][out], maxOut, eligible);""")
    rep("""    /// @dev a - b, or 0 if b > a.""", """    function _checkRoom(Currency out, uint256 maxOut) internal view {
        uint256 i = out == asset1 ? 1 : 0;
        uint256 target = inventoryTargetPerShare[i];
        if (target != 0) {
            uint256 room = _sub0(
                _netAssets(out), VaultRiskBoundary.inventoryFloor(totalShares, target, inventoryTolerancePips[i])
            );
            uint256 q = reserved[out];
            if (q + maxOut > room) revert InsufficientBacking(maxOut, _sub0(room, q));
        }
    }

    /// @dev a - b, or 0 if b > a.""")

if 'B' in flags:  # fee escrow: realize entry + deposit checkpoint + setter
    rep("""    uint24[2] public inventoryTolerancePips;""", """    uint24[2] public inventoryTolerancePips;
    address public feeEscrow;
    error NotFeeEscrow();
    event FeeEscrowSet(address escrow, address by);
    event FeesRealized(uint256 amount0, uint256 amount1);""")
    rep("""    function deposit(uint256 shares, uint256 maxAmount0, uint256 maxAmount1, address receiver)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amount0, uint256 amount1)
    {""", """    function deposit(uint256 shares, uint256 maxAmount0, uint256 maxAmount1, address receiver)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        address escrow = feeEscrow;
        if (escrow != address(0)) IFeeEscrowV2(escrow).realize();
        _enterLock();
        if (paused) revert Paused();""")
    rep("""        _unlock(CallbackAction.Deposit, msg.sender, amount0, amount1);
        emit Deposited(msg.sender, receiver, shares, amount0, amount1);
    }""", """        _unlock(CallbackAction.Deposit, msg.sender, amount0, amount1);
        emit Deposited(msg.sender, receiver, shares, amount0, amount1);
        _exitLock();
    }

    function setFeeEscrow(address escrow) external {
        _authorize(escrow == address(0));
        feeEscrow = escrow;
        emit FeeEscrowSet(escrow, msg.sender);
    }

    function realizeFees(uint256 amount0, uint256 amount1) external nonReentrant {
        if (msg.sender != feeEscrow) revert NotFeeEscrow();
        if (amount0 > MAX_AMOUNT - backing[asset0] || amount1 > MAX_AMOUNT - backing[asset1]) revert AmountTooLarge();
        backing[asset0] += amount0;
        backing[asset1] += amount1;
        _unlock(CallbackAction.Deposit, msg.sender, amount0, amount1);
        emit FeesRealized(amount0, amount1);
    }""")
    rep("""contract SharedCommitmentVault is""", """interface IFeeEscrowV2 {
    function realize() external;
}

contract SharedCommitmentVault is""")

if 'C' in flags:  # bucketed expiry ring
    rep("""import {VaultRiskBoundary} from "./risk/VaultRiskBoundary.sol";""",
        """import {VaultRiskBoundary} from "./risk/VaultRiskBoundary.sol";
import {ExpiryRing} from "./ExpiryRing.sol";""")
    rep("""    uint24[2] public inventoryTolerancePips;""", """    uint24[2] public inventoryTolerancePips;
    uint256 internal constant _BUCKET = 1 hours;
    uint256 internal constant _RING = 720;
    uint256 internal constant _SWEEP_STEPS = 32;
    mapping(Currency currency => ExpiryRing.Ring) internal _expiry;""")
    rep("""        emit OwnershipTransferred(address(0), owner_);
    }""", """        emit OwnershipTransferred(address(0), owner_);
        uint40 b = uint40(block.timestamp / _BUCKET);
        _expiry[asset0_].swept = b;
        _expiry[asset1_].swept = b;
    }

    function _sweep(Currency a) internal {
        reserved[a] = ExpiryRing.sweep(_expiry[a], reserved[a], block.timestamp / _BUCKET, _SWEEP_STEPS, _RING);
    }

    function liveReserved(Currency a) external view returns (uint256) {
        return ExpiryRing.live(_expiry[a], reserved[a], block.timestamp / _BUCKET, _RING);
    }""")
    rep("""        if (expiry <= block.timestamp) revert InvalidExpiry();""",
        """        if (expiry <= block.timestamp || expiry % _BUCKET != 0) revert InvalidExpiry();""")
    rep("""        uint256 eligible = _eligibleBacking(out);
        uint256 admissible = _admissible(out, eligible);""", """        _sweep(out);
        uint256 eligible = _eligibleBacking(out);
        uint256 admissible = _admissible(out, eligible);""")
    rep("""        reserved[out] += maxOut;
        curatorReserved[curator][out] += maxOut;""", """        reserved[out] = ExpiryRing.add(_expiry[out], reserved[out], expiry / _BUCKET, maxOut, _RING);
        curatorReserved[curator][out] += maxOut;""")
    rep("""        reserved[cout] -= amountOut;""",
        """        reserved[cout] = ExpiryRing.remove(_expiry[cout], reserved[cout], a.expiry / _BUCKET, amountOut, _RING);""")
    rep("""        reserved[out] -= unused;""",
        """        reserved[out] = ExpiryRing.remove(_expiry[out], reserved[out], a.expiry / _BUCKET, unused, _RING);""")
    rep("""        if (pendingShares != 0) _processQueue(INLINE_QUEUE_STEPS);""",
        """        _sweep(asset0);
        _sweep(asset1);
        if (pendingShares != 0) _processQueue(INLINE_QUEUE_STEPS);""")
    rep("""    function processQueue(uint256 maxSteps) external nonReentrant returns (uint256 sharesFinalized) {
        return _processQueue(maxSteps);""", """    function processQueue(uint256 maxSteps) external nonReentrant returns (uint256 sharesFinalized) {
        _sweep(asset0);
        _sweep(asset1);
        return _processQueue(maxSteps);""")

open(path, 'w').write(s)

s = open(path).read()
if 'F' in flags:  # lean fee entry: claim pull, escrow-only, lock-free; deposit calls escrow inside its lock
    rep("""    uint24[2] public inventoryTolerancePips;""", """    uint24[2] public inventoryTolerancePips;
    address public feeEscrow;""")
    rep("""        uint256 supply = totalShares;
        if (supply == 0) revert NotInitialized();
        if (receiver == address(0)) revert ZeroAddress();""", """        address escrow = feeEscrow;
        if (escrow != address(0)) IFeeEscrowV2(escrow).realize();
        uint256 supply = totalShares;
        if (supply == 0) revert NotInitialized();
        if (receiver == address(0)) revert ZeroAddress();""")
    rep("""    /// @dev a - b, or 0 if b > a.""", """    function setFeeEscrow(address escrow) external {
        _authorize(false);
        feeEscrow = escrow;
    }

    function realizeFee(Currency currency, uint256 amount) external {
        if (msg.sender != feeEscrow) revert NotOwner();
        uint256 b = backing[_otherAsset(_otherAsset(currency))];
        if (amount > MAX_AMOUNT - b) revert AmountTooLarge();
        backing[currency] = b + amount;
        poolManager.transferFrom(msg.sender, address(this), currency.toId(), amount);
    }

    /// @dev a - b, or 0 if b > a.""")
    rep("""contract SharedCommitmentVault is""", """interface IFeeEscrowV2 {
    function realize() external;
}

contract SharedCommitmentVault is""")
if 'S' in flags:  # one internal sweep of both assets for the two LP paths
    s = s.replace("""        _sweep(asset0);
        _sweep(asset1);""", """        _sweepBoth();""")
    rep("""    function liveReserved(Currency a) external view returns (uint256) {""", """    function _sweepBoth() internal {
        _sweep(asset0);
        _sweep(asset1);
    }

    function liveReserved(Currency a) external view returns (uint256) {""")
if 'V' in flags:  # drop the liveReserved view (lens would need ring getters instead)
    a = s.index("    function liveReserved(Currency a)")
    b = s.index("    }\n", a) + 6
    s = s[:a] + s[b:]
open(path, 'w').write(s)

s = open(path).read()
if 'E' in flags:  # ring in a separate immutable ledger the vault calls
    rep("""    uint24[2] public inventoryTolerancePips;""", """    uint24[2] public inventoryTolerancePips;
    IExpiryLedgerV2 public immutable expiryLedger;""")
    rep("""        emit OwnershipTransferred(address(0), owner_);
    }""", """        emit OwnershipTransferred(address(0), owner_);
        expiryLedger = IExpiryLedgerV2(address(uint160(uint256(keccak256(abi.encode(asset0_))))));
    }

    function _sweep(Currency a) internal {
        reserved[a] = expiryLedger.sweep(a, reserved[a]);
    }""")
    rep("""        if (expiry <= block.timestamp) revert InvalidExpiry();""",
        """        if (expiry <= block.timestamp || expiry % 3600 != 0) revert InvalidExpiry();""")
    rep("""        uint256 eligible = _eligibleBacking(out);
        uint256 admissible = _admissible(out, eligible);""", """        _sweep(out);
        uint256 eligible = _eligibleBacking(out);
        uint256 admissible = _admissible(out, eligible);""")
    rep("""        reserved[out] += maxOut;
        curatorReserved[curator][out] += maxOut;""", """        reserved[out] = expiryLedger.add(out, reserved[out], expiry, maxOut);
        curatorReserved[curator][out] += maxOut;""")
    rep("""        reserved[cout] -= amountOut;""",
        """        reserved[cout] = expiryLedger.remove(cout, reserved[cout], a.expiry, amountOut);""")
    rep("""        reserved[out] -= unused;""",
        """        reserved[out] = expiryLedger.remove(out, reserved[out], a.expiry, unused);""")
    rep("""        if (pendingShares != 0) _processQueue(INLINE_QUEUE_STEPS);""",
        """        _sweep(asset0);
        _sweep(asset1);
        if (pendingShares != 0) _processQueue(INLINE_QUEUE_STEPS);""")
    rep("""    function processQueue(uint256 maxSteps) external nonReentrant returns (uint256 sharesFinalized) {
        return _processQueue(maxSteps);""", """    function processQueue(uint256 maxSteps) external nonReentrant returns (uint256 sharesFinalized) {
        _sweep(asset0);
        _sweep(asset1);
        return _processQueue(maxSteps);""")
    rep("""contract SharedCommitmentVault is""", """interface IExpiryLedgerV2 {
    function sweep(Currency a, uint256 total) external returns (uint256);
    function add(Currency a, uint256 total, uint64 expiry, uint256 amount) external returns (uint256);
    function remove(Currency a, uint256 total, uint64 expiry, uint256 amount) external returns (uint256);
}

contract SharedCommitmentVault is""")
open(path, 'w').write(s)

s = open(path).read()
if 'G' in flags:  # degenerate ring (K = 1): zero Q once every reservation of the asset has expired
    rep("""    uint24[2] public inventoryTolerancePips;""", """    uint24[2] public inventoryTolerancePips;
    struct Flush { uint64 maxExpiry; uint64 flushedAt; }
    mapping(Currency currency => Flush) internal _flush;""")
    rep("""    /// @dev a - b, or 0 if b > a.""", """    function _flushExpired(Currency a) internal {
        Flush storage f = _flush[a];
        if (block.timestamp >= f.maxExpiry && reserved[a] != 0) {
            reserved[a] = 0;
            f.flushedAt = uint64(block.timestamp);
        }
    }

    /// @dev a - b, or 0 if b > a.""")
    rep("""        uint256 eligible = _eligibleBacking(out);
        uint256 admissible = _admissible(out, eligible);""", """        _flushExpired(out);
        uint256 eligible = _eligibleBacking(out);
        uint256 admissible = _admissible(out, eligible);""")
    rep("""        reserved[out] += maxOut;
        curatorReserved[curator][out] += maxOut;""", """        reserved[out] += maxOut;
        if (expiry > _flush[out].maxExpiry) _flush[out].maxExpiry = expiry;
        curatorReserved[curator][out] += maxOut;""")
    rep("""        reserved[out] -= unused;""", """        if (a.expiry > _flush[out].flushedAt) reserved[out] -= unused;""")
    rep("""        if (pendingShares != 0) _processQueue(INLINE_QUEUE_STEPS);""",
        """        _flushExpired(asset0);
        _flushExpired(asset1);
        if (pendingShares != 0) _processQueue(INLINE_QUEUE_STEPS);""")
    rep("""    function processQueue(uint256 maxSteps) external nonReentrant returns (uint256 sharesFinalized) {
        return _processQueue(maxSteps);""", """    function processQueue(uint256 maxSteps) external nonReentrant returns (uint256 sharesFinalized) {
        _flushExpired(asset0);
        _flushExpired(asset1);
        return _processQueue(maxSteps);""")
open(path, 'w').write(s)

s = open(path).read()
if 'X' in flags:  # getters behind one extsload; keep what hooks, the governor, scripts and the auth module call
    keep = {'owner', 'guardian', 'pendingShares', 'isConsumer', 'poolManager', 'asset0', 'asset1', 'paused',
            'authModule', 'pendingOwner', 'MAX_AMOUNT', 'MAX_HORIZON', 'MIN_SHARES', 'INLINE_QUEUE_STEPS', 'FLOW_WINDOW'}
    def fix(m):
        name = m.group(2)
        return m.group(0) if name in keep else m.group(1) + ' internal ' + name
    s = re.sub(r'(\b(?:mapping\([^;]*\)|uint256\[2\]|uint24\[2\]|uint256|uint24|IMarketRiskAdapter|address|bool))\s+public\s+(?:immutable\s+|constant\s+)?(\w+)',
               lambda m: m.group(0) if m.group(2) in keep or 'constant' in m.group(0) or 'immutable' in m.group(0) else m.group(1) + ' internal ' + m.group(2), s)
    s = s.replace('contract SharedCommitmentVault is ISharedCommitmentVault, IVaultState, IUnlockCallback {',
                  'contract SharedCommitmentVault is ISharedCommitmentVault, IUnlockCallback {')
    s = s.replace('/// @inheritdoc IVaultState', '///')
    for fn in ['function getAllocation(', 'function getRiskLimit(', 'function getRequest(', 'function admissibleCapacity(']:
        a = s.index('    ' + fn)
        # back up to the start of its doc comment block
        a2 = s.rfind('\n\n', 0, a) + 2
        b = s.index('\n    }\n', a) + 7
        s = s[:a2] + s[b:]
    s = s.replace("""    /// @dev a - b, or 0 if b > a.""", """    function extsload(bytes32 slot) external view returns (bytes32 value) {
        assembly ("memory-safe") {
            value := sload(slot)
        }
    }

    /// @dev a - b, or 0 if b > a.""")
open(path, 'w').write(s)

s = open(path).read()
if 'T' in flags:  # C-1: per-asset backing cap checked in deposit and initialDeposit
    anchor = "    uint24[2] public inventoryTolerancePips;" if "    uint24[2] public inventoryTolerancePips;" in s else "    uint24[2] internal inventoryTolerancePips;"
    rep(anchor, anchor + """
    mapping(Currency currency => uint256) internal _backingCap;""")
    rep("""        if (amount0 > maxAmount0 || amount1 > maxAmount1) revert SlippageExceeded();""",
        """        if (amount0 > maxAmount0 || amount1 > maxAmount1) revert SlippageExceeded();
        _checkCap(asset0, amount0);
        _checkCap(asset1, amount1);""")
    rep("""    /// @dev a - b, or 0 if b > a.""", """    function _checkCap(Currency c, uint256 amount) internal view {
        if (backing[c] + amount > _backingCap[c]) revert AmountTooLarge();
    }

    function setBackingCap(Currency c, uint256 cap) external {
        _otherAsset(c);
        _authorize(cap <= _backingCap[c]);
        _backingCap[c] = cap;
    }

    /// @dev a - b, or 0 if b > a.""")
open(path, 'w').write(s)
