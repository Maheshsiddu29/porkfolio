# Integrating an external hook with Porkfolio

This guide describes the tested interface, not a permissionless listing process. A new hook needs vault-governance
registration, a configured PoolKey, risk limits and an authorized, bonded allocation before it can use shared
liquidity. [IndependentHookC](../test/utils/IndependentHookC.sol)
is a complete, independently compiled test example. Build it with
`forge build test/utils/IndependentHookC.sol`; its tests use the production vault and pinned v4 PoolManager.

## Address, pool and registration

The deployed address must encode the v4 permission flags for `beforeSwap` and `beforeSwapReturnDelta`. If every
swap intercepts the native curve, implement `beforeAddLiquidity` and set its bit to reject pool-native liquidity.
Hook C obtains a permission-correct address with the pinned `HookMiner` and CREATE2, then calls
`Hooks.validateHookPermissions` in its constructor. A random deployment address is not sufficient: the PoolManager
decides which callbacks to call from the address bits.

Initialize a PoolKey with the vault's ordered `asset0` and `asset1`, a valid fee and tick spacing, and this hook as
`key.hooks`. The PoolManager must match `vault.poolManager()`. The vault owner registers the hook with
`setConsumer(hook, true)` and configures Hook-scope limits for both output assets. A production owner is the
`VaultGovernor`, so these actions are queued and execute after its delay; its guardian can deregister immediately.
The hook owner separately configures the hook's own price policy. Registration does not create an allocation.

## Allocation and funding

The installed `CommitmentAuthorizer` creates a vault allocation and posts its bond in one transaction. A signed
intent identifies the curator, hook, PoolKey, direction, maximum output, curator price floor, hour-aligned expiry,
nonce, deadline, payer and maximum bond rate. Only the payer may submit that signed bonded intent and approve the
escrow for the reserved asset. Direct activation makes the curator the payer. The escrow's bond claims are separate
from LP backing; the hook never holds the bond. A reservation is consumed only while `now < expiry`, and each fill
lowers its own unused remainder. A successful fill does not automatically synchronize the escrow; anyone may call
`sync` later. Late synchronization can overcharge the payer. After cancellation or expiry, `settle` credits the
unused bond to the payer, and the payer claims it to a chosen recipient. Earned LP fees enter the vault through
escrow realization, which a deposit checkpoints before pricing new shares.

## Swap callback and settlement

For an exact-input swap of `X` raw input units quoted for `Y` raw output units, the tested sequence inside
`beforeSwap` is:

1. Verify `msg.sender` is the PoolManager, the PoolKey is this hook's configured pool, the input is positive and at
   most `2^127 − 1`, and the hook data is well formed. Hook C requires exactly
   `abi.encode(uint256 allocationId, uint256 minimumOutput)` (64 bytes).
2. Quote `Y`, round output conservatively, reject zero or more than `int128.max`, and enforce the trader's minimum.
3. Call `manager.mint(address(this), currencyIn.toId(), X)` to make temporary claims against the input the router
   will pay at unlock end.
4. Call `vault.exchange(key, zeroForOne, allocationId, X, Y)`. The vault checks registration, consumer/pool/direction
   binding, expiry, quota, curator restriction, live price floors, inventory room and gross flow limits. It pulls
   this hook's input claims first, then transfers `Y` output claims to it.
5. Call `manager.burn(address(this), currencyOut.toId(), Y)`. Return
   `BeforeSwapDelta(+int128(X), -int128(Y))` and zero fee override. The specified amount left for the pool curve is
   zero. The hook's temporary delta and claims are zero; the router owes `X` and receives `Y`. The PoolManager
   refuses the unlock unless every currency delta is settled. Any failure reverts the whole transaction.

The hook must grant the vault ERC-6909 operator rights over **the hook's own claims**, by calling
`manager.setOperator(address(vault), true)` as the hook. It must never receive operator rights over the vault's
claims. It cannot maintain a competing allocation or backing ledger. Hook C's fixed-spread policy is independent of
the supported hooks: `Y = floor(X · (1e6 − spreadPips) / 1e6)` for comparable raw token units. Other pricing policies
are possible, but the vault's execution floors remain authoritative. A floor is a minimum price, not an oracle
guarantee of fair market value. A registered malicious hook can sell its authorized quota at that minimum.

## Limits visible to integrators

A physically backed allocation guarantees exclusive accounting capacity and backing at admission. It does not
guarantee that every later trade executes: LP exits can shrink sellable inventory, and a pause, halt, frozen or
revoked curator, flow cap, changed risk limit, expired allocation, or failed oracle reading can refuse a fill. An oracle
outage does not stop bond accrual. The hook should surface a rejected trade to its user and must not promise
guaranteed output from an allocation alone. Curtailment and expiry leave no right to spend vault-owned claims.

The implementation and tests are in `test/utils/IndependentHookC.sol`, `test/integration/IndependentHookC.t.sol`
and `test/security/IndependentHookC.t.sol`. They are local test fixtures, not a supported production hook or an
audit of an external integration.
