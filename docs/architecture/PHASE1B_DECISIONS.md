# Porkfolio — Phase 1B Architecture Decision Record (D1–D14)

**Status:** approved by the project owner at the start of Phase 1B-1, with amendments to D3, D12 and D14. This record
is authoritative where it differs from the Phase 1B-0 specifications (`PHASE1B_PRICE_POLICY.md`,
`PHASE1B_CURATOR_AUTH.md`, `PHASE1B_THREATS_AND_PLAN.md`).

| ID | Decision | Approved | Phase |
|---|---|---|---|
| D1 | Static, governance-configured minimum per direction (Design A). No oracle. | as recommended | 1B-1 |
| D2 | Guardian role with risk-reducing powers only | as recommended | 1B-1 |
| D3 | No internal timelock on owner floor changes; guardian is tighten-only | **amended** (below) | 1B-1 |
| D4 | Allocation rejected when the curator floor is below the vault floor; `max` also applied at exchange | as recommended | 1B-1 |
| D5 | Curator cancellation takes effect immediately | as recommended | 1B-2 |
| D6 | Keep the direct (non-signature) allocation path; it passes the same vault risk checks | as recommended | 1B-1 (risk checks), 1B-2 (shared struct) |
| D7 | Unordered nonce bitmap with bulk invalidation | as recommended | 1B-2 |
| D8 | No `submitter` field in the signed message | as recommended | 1B-2 |
| D9 | Hooks do not pre-check the vault floor in `beforeSwap`; the vault is authoritative | as recommended | 1B-1 |
| D10 | Two-step ownership transfer | as recommended | 1B-1 |
| D11 | EIP-712 domain `"Porkfolio Vault"`, version `"1"` | as recommended | 1B-2 |
| D12 | Contract-size levers | **amended** (below) | all |
| D13 | Rewrite tests that drained the vault at floor 0 with configured non-zero floors; keep zero-asset and dust coverage | as recommended | 1B-1 |
| D14 | Directional floor consistency | **amended and reversed** (below) | 1B-1 |

## D3 (amended): governance

- **Owner.** The owner may set and loosen floors with no internal timelock in this prototype.
- **Guardian.** The guardian is strictly tighten-only:
  - raise a floor or halt a direction;
  - pause;
  - deregister a hook or a curator;
  - lower a ceiling;
  - raise a buffer floor;
  - emergency-release an allocation.

  It can never loosen, resume, unpause, register, raise a ceiling, or name a new owner or guardian.
- **Before any real-value deployment:** a separate review of multisig and timelock governance and of emergency
  authority is **required**. This prototype's owner model is not approved for real value.

## D12 (amended): contract size

- **No hand-written crypto to save bytes.** Established cryptographic components (OZ `EIP712`, `ECDSA`,
  `SignatureChecker`) are not replaced with hand-written signature or domain code merely to save bytes.
- **Levers, in this order:**
  1. compiler and optimizer settings (for example, a vault-specific `optimizer_runs`);
  2. safe modularization of non-security-critical code (such as views or pure helpers).
- **A contract split requires architectural review** before it is implemented.

## D14 (amended and reversed): directional consistency

**Erratum.** Phase 1B-0 recommended *not* enforcing a consistency check, and described the condition as
`F(a0)·F(a1) ≤ 2^192` (a "non-empty band"). That was wrong. The condition that matters for LP safety points the
**other way**, and it must be enforced.

**Statement.** Let `F_AB` be the vault floor when it sells B (raw A in per raw B out) and `F_BA` the floor when it sells A
(raw B in per raw A out), both in Q64.96. Whenever both are configured (non-zero), the vault requires

```
F_AB × F_BA ≥ 2^192          (i.e. (F_AB/2^96)·(F_BA/2^96) ≥ 1)
```

**Why.** A trader starts with `x` of A and trades at the floor in both directions:

- selling `x` A to the vault yields at most `x·2^96/F_AB` of B;
- selling that B back yields at most `x·2^192/(F_AB·F_BA)` of A.

The round trip is profitable exactly when `F_AB·F_BA < 2^192`. Equivalently, `2^96/F_BA` is the most A the vault will pay
per B (its worst bid), and `F_AB/2^96` is the least A it will accept per B (its worst ask). The condition says that the
vault's worst bid never exceeds its worst ask.

**Stronger property (proof).** If the condition holds, pick any `k` with `2^96/F_BA ≤ k ≤ F_AB/2^96`; such a `k` exists
exactly when `F_AB·F_BA ≥ 2^192`. Define the valuation `V_k = A + k·B`. Then:

- **Vault sells B** (`o` of B out, `i` of A in): `i ≥ o·F_AB/2^96 ≥ k·o`, so `ΔV_k = i − k·o ≥ 0`.
- **Vault sells A** (`o` of A out, `i` of B in): `i ≥ o·F_BA/2^96 ≥ o/k`, so `ΔV_k = −o + k·i ≥ 0`.

Every trade that passes the floors leaves `V_k` non-decreasing. So **no sequence of trades**, of any length, in any order,
through any hooks or allocations, can leave the vault with less of both assets. Effective floors are
`max(f_v, f_c) ≥ f_v`, so curator floors only strengthen this. The argument holds at a fixed configuration, and each
trade is checked against the floors live at its own execution.

**Exact on-chain comparison.** `F_AB·F_BA` can reach `2^320`, so it must never be computed in 256 bits. The vault checks

```
F_AB ≥ FullMath.mulDivRoundingUp(2^96, 2^96, F_BA)
```

- **Exact.** For an integer `F_AB`: `F_AB·F_BA ≥ 2^192 ⇔ F_AB ≥ 2^192/F_BA ⇔ F_AB ≥ ⌈2^192/F_BA⌉`.
- **No overflow.** `FullMath` (pinned v4-core) uses a 512-bit intermediate. The result is at most `2^192`, because
  `F_BA ≥ 1`, so it fits in 256 bits. The denominator is never 0, because the check runs only when the opposite floor is
  configured.
- **When it runs.** The check runs on every floor change, by owner or guardian, whenever the opposite direction is
  configured. Raising a floor can only increase the product, so guardian tightening always passes.

**Consequences.**

- **A lower bound on any floor.** Because floors are `uint160` (`< 2^160`), once both directions are configured each
  floor is at least `⌈2^192/(2^160 − 1)⌉ = 2^32 + 1`, a raw ratio of about `2.3·10^-10`. The ratio of the two floors is
  therefore bounded, and no direction can be configured near zero while the other is open.
- **Spec error in the old example.** The Phase 1B-0 worked example (`PHASE1B_PRICE_POLICY.md` §2.3, 2,850 / 3,150 USDC
  per WETH) is a **crossed** configuration, with a product of about 0.905. D14 rejects it. A valid pair around 3,000 is,
  for example:
  - sell WETH at ≥ 2,850 USDC per WETH: `F = 225800263165653362142`;
  - sell USDC at ≥ 1/2,850 WETH per USDC: `F = 27799355268162925471418929942456140351`.

  The product is ≥ `2^192` because both values were rounded up.
- **One pivot price.** The pair of vault floors fixes a pivot interval `[2^96/F_BA, F_AB/2^96]` of the price of B in
  A. With equality, it is a single price.
  - A hook can trade in both directions only when its bid is at most the lower end and its ask at least the upper end,
    i.e. its spread straddles the pivot interval.
  - When the market drifts so that a hook's quotes no longer straddle it, the direction that would be unfavourable to
    the vault relative to the pivot stops executing (revert). The favourable direction continues.
- **Not an unacceptable restriction.** This is the intended behaviour of a non-crossing static floor, so the check is
  implemented rather than replaced by an alternative. The cost is liveness of one direction under price drift, never LP
  value.

**What this still does not give:** a fair-market-price guarantee (unchanged from `PHASE1B_PRICE_POLICY.md` §9).
