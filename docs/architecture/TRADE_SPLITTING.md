# Porkfolio — Trade Splitting in Hook A and Hook B (Analysis)

**Status: ANALYSIS OF THE PRICING BEFORE PHASE 1B-3.** Sections 1–6 describe the per-swap formulas that Phase 1B-3
replaced and keep their measured numbers as the "before" record. Section 8 gives the "after". No pricing formula is
changed by this document. Labels follow
`PHASE1B_PRICE_POLICY.md`: SOURCE (read from code), OBSERVED (measured by a test through the real PoolManager),
MODEL (exact integer model of the code, cross-checked against OBSERVED values), PROPOSAL.

Evidence: `test/integration/TradeSplitting.t.sol` (characterization tests: one swap versus n swaps inside one
PoolManager unlock, from the same state snapshot). Every OBSERVED number below is asserted exactly in that file and
matches the MODEL to the wei.

## 1. Summary

| Question | Hook A (`HookA_DynamicFee`) | Hook B (`HookB_BoundedImpact`) |
|---|---|---|
| Does splitting lower the total cost? | **Yes**, by up to half of the utilisation-dependent fee. The base fee cannot be avoided. | **Yes, almost entirely.** The impact paid falls roughly as 1/n; the floor is about 1 pip per piece from rounding. |
| Is the bound per swap or aggregate? | No size bound. The fee schedule is applied per swap. | **Per swap.** `maxImpactPips` limits one swap. The only aggregate limit is the allocation's quota in the vault. |
| Intentional? | Documented as a known property in the hook NatSpec (SOURCE). No design document states it as a goal. | Same. The NatSpec says "the cap limits the size of a single trade, not total flow". `REQUIREMENTS.md` asks for "a bounded impact/spread policy" without saying per swap or aggregate. |
| Can it take the vault below its floor? | **No.** Every piece goes through `exchange`, which enforces `max(f_v, f_c)` on the exact amounts. | **No**, same reason. |
| Main effect | LP fee revenue is lower than single-trade quotes suggest. | The impact charge and the cap give LPs almost no protection against flow that splits. What remains is the vault floor and the quota. |

## 2. Formulas (SOURCE)

Pip = 10^-6. `gross` = input converted at the hook's fixed reference price, rounded down. `consumed` is the
allocation's recorded **net** output; `maxOut` its quota.

```
Hook A   u    = min(1e6, ceil((consumed + gross) · 1e6 / maxOut))        post-trade utilisation
         fee  = base + ceil((max − base) · u / 1e6)
         out  = floor(gross · (1e6 − fee) / 1e6)

Hook B   R    = maxOut − consumed                                         remaining capacity
         imp  = ceil(gross · k / R)            revert ImpactBoundExceeded if imp > maxImpactPips
         out  = floor(gross · (1e6 − imp) / 1e6)
```

Neither hook keeps any state of its own. The price depends only on the allocation's `consumed`, which only increases.

## 3. Why splitting helps

**Hook A.** One trade of size G pays the post-trade utilisation `(c + G)/M` on all of G. Split into n pieces, piece i
pays roughly `(c + iG/n)/M`. Ignoring rounding, and treating consumed as gross, the utilisation-dependent part of the
fee is

```
single:    Δ · G · (c + G) / M
n pieces:  Δ · G · (c + G·(n+1)/(2n)) / M          Δ = max − base, in fractional units
saving:    Δ · G² · (n − 1) / (2nM)          →  Δ · G² / (2M) as n → ∞
```

As n grows, the fee tends to the integral of the linear schedule, which is the average of the pre-trade and
post-trade utilisation. A single trade pays the post-trade value, which is above that average.

**Hook B.** One trade pays `k · G / R` on all of G, so its cost is about `k · G² / R`. With n pieces, each one pays about
`k · (G/n) / R_i`, and the total is about `k · G² / (n · R)` while G is much smaller than R. The cost falls roughly as
1/n. The `ceil` puts a floor of 1 pip under each piece's impact, so the total cannot fall below about 1 pip of G.

## 4. Numerical examples

Fixture: 1:1 reference price (gross = input), quota `maxOut` = 10,000 tokens (18 decimals), nothing consumed, vault
and curator floors 1:1. Cost is input minus output. Gas is in §5.

### 4.1 Hook A: base 500 pips, max 5,000 pips; 8,000 tokens in

| Pieces | Output | Cost | Effective fee | Source |
|---|---|---|---|---|
| 1 | 7,967.2 | 32.8 | 4,100 pips | OBSERVED |
| 2 | 7,974.416 | 25.584 | 3,198 pips | OBSERVED |
| 8 | 7,979.82 | 20.18 | 2,522.5 pips | OBSERVED |
| 100 | 7,981.47672 | 18.52328 | 2,315.4 pips | MODEL |
| 1,000 | 7,981.606056 | 18.393944 | 2,299.2 pips | MODEL |

Splitting into 8 swaps saves 12.62 tokens (38%). The limit is about 14.4 tokens (44%), which is half of the 28.8-token
utilisation component. The 4.0-token base fee is paid in every case. At full quota (9,950 in), 10 pieces save 20.09
of 49.53 (MODEL).

### 4.2 Hook B: impact at full quota k = 10,000 pips (1%), cap 20,000 pips (2%)

| Total in | Pieces | Output | Cost | Source |
|---|---|---|---|---|
| 1,000 | 1 | 999 | 1.0 | OBSERVED |
| 1,000 | 10 | 999.8946 | 0.1054 | OBSERVED |
| 1,000 | 1,000 | 999.998001 | 0.001999 | MODEL |
| 5,000 | 1 | 4,975 | 25.0 | MODEL |
| 5,000 | 10 | 4,996.655 | 3.345 | MODEL |
| 5,000 | 1,000 | 4,999.962735 | 0.037265 | MODEL |

With k ≤ cap, as here, the cap never binds inside the remaining capacity (SOURCE, hook NatSpec).

### 4.3 Hook B cap bypass: k = 50,000 pips (5%), cap 10,000 pips (1%); 5,000 in

| Pieces | Result | Source |
|---|---|---|
| 1 | reverts `ImpactBoundExceeded(25,000, 10,000)` | OBSERVED |
| 2, 3 | revert (12,500 and 12,444 pips on the first piece) | MODEL |
| 5 | **executes**: output 4,967.778, pieces at 5,000 → 8,301 pips, all under the cap | OBSERVED |
| 100 | executes: output 4,998.27105 (cost 1.73) | MODEL |

A trade that the cap refuses executes in full as five swaps in the same transaction. The cap is a per-swap size limit.
It does not bound the aggregate impact or the aggregate size.

## 5. Cost of splitting (OBSERVED, test environment)

`test_TS_gasPerExtraPiece` logs, for Hook B through `BatchSwapRouter` in one unlock:

- 1 swap: 192,663 gas;
- 10 swaps: 1,213,127 gas;
- about 113,000 gas per extra piece.

These are in-test `gasleft()` differences. They include the test router's own per-swap delta assertions and are not
`--isolate` measurements. Splitting pays when the saving exceeds the extra gas times the gas price. In §4.2, splitting
1,000 tokens into 10 pieces saves 0.89 tokens for about 1.0M extra gas. Whether that is profitable depends on the
token's value and the chain's gas price. This analysis does not model either.

## 6. Exploit and economic consequences

1. **Fee and impact avoidance (both hooks).** A router or searcher that always splits pays less than a trader who
   does not. Hook A's charge drops by up to half its utilisation component. Hook B's charge drops to about 1 pip. LPs
   collect less than single-trade quotes imply. This is a revenue shortfall, not a solvency issue: every piece still
   meets the vault floor, and backing moves by exactly the amounts traded (asserted by `_assertAccountingConsistent`
   in each test).
2. **Hook B with a stale reference price.** Both hooks price off a fixed `priceX96` set by `hookOwner`. If the market
   moves away from it, the impact charge is Hook B's only spread above the vault floor, and splitting removes almost
   all of it. One transaction can therefore buy the allocation's whole remaining quota at about the reference price.
   The LP loss is still bounded by `remaining × (M − F_eff)⁺` (`PHASE1B_PRICE_POLICY.md` §8.1), but in practice Hook B
   adds almost nothing to that bound.
3. **Cap bypass (Hook B, k > cap).** A pool configured to refuse large single trades accepts the same flow split
   (§4.3). Anyone relying on the cap as a per-transaction or per-block limit is mistaken.
4. **Ordering, not sandwiching.** `consumed` only increases, and capacity sold in one direction never returns to the
   same allocation. So no trade can make a later trade cheaper, and the classic sandwich round trip does not exist
   here. Earlier trades get better prices than later ones. Someone can front-run to consume capacity ahead of a
   victim: under Hook A this raises the victim's fee, under Hook B it can push the victim over the cap. The front-runner
   pays a real trade at or above the floor to do it.
5. **Allocation shopping.** The swapper chooses the allocation id. When several allocations serve the same hook and
   pool, the least-used one prices best. This is another form of the same effect.

## 7. How this should be tested

**Now (added, passing).** `TradeSplitting.t.sol` pins the current behaviour with exact values:

- `test_TS_hookA_splitPaysLessFee`: 1 vs 2 vs 8 pieces;
- `test_TS_hookB_splitAvoidsImpact`: 1 vs 10 pieces;
- `test_TS_hookB_capIsPerSwap_splitBypassesIt`: one swap reverts, five swaps execute;
- `test_TS_gasPerExtraPiece`: logs gas.

Each run starts from the same `vm.snapshotState()`, and the split runs happen inside one unlock. Because neither hook
has time-dependent state (only the allocation's `expiry`), splitting across blocks gives the same prices as splitting
inside one transaction. The one-transaction case is the strongest form of the attack.

**When the formulas are redesigned (PROPOSAL, not implemented).** Turn the characterization tests into properties:

- *Split invariance.* For random G and n, `|out(G) − Σ out(G/n)| ≤ n · ε`, where ε is the per-swap rounding bound of
  the new formula. Today this property fails, by design of the current formulas.
- *Aggregate bound (Hook B).* For any sequence of swaps against one allocation, the total output at a given cumulative
  input is the same as for one swap of that input, and the cap applies to the cumulative quantity it is meant to limit.
- *Ordering.* Any interleaving of two traders' swaps gives the same combined output.
- Keep the existing per-piece floor and accounting checks.

Candidate directions, for the human pricing decision only:

- Hook A could charge the integral of its linear schedule from `consumed` to `consumed + gross`. That makes the fee
  additive over pieces.
- Hook B could price along a curve of cumulative `consumed`, so that impact depends on position rather than trade size,
  and could express its cap as a bound on cumulative consumption.

Both directions change pricing semantics and are deliberately not done here.

## 8. After Phase 1B-3 (cumulative pricing)

Both hooks now price from per-pool state in hook storage (`PHASE1B3_REPORT.md`, `CUMULATIVE_PRICING_SPEC.md`). The
characterisation tests in `TradeSplitting.t.sol` were inverted on the same fixture:

| Scenario | Before (OBSERVED, §4) | After (OBSERVED) |
|---|---|---|
| Hook A, 8,000 in, 1 / 2 / 8 swaps | 7,967.2 / 7,974.416 / 7,979.82 out | **7,981.6** in every case (fee 18.4) |
| Hook B, 1,000 in, 1 / 10 swaps | 999 / 999.8946 out | **999.000999…** in both cases |
| Hook B cap binding (5% at full quota vs 1% cap / depth 200,000 with a 1% cap), 5,000 in | 1 swap reverts, 5 swaps execute | 1, 5, 10 and 100 swaps in one transaction all revert; as separate transactions the pieces stop at the cap (19 of 100 pieces of 50) |

- At a 1:1 reference every conversion is exact, so the split receives exactly the single trade's output. At other
  prices a split of Hook A into n pieces receives at most n − 1 raw units less (one rounding per conversion; reached
  at the price 2^96 − 1, `testFuzz_HAP_splitVersusSingle`). A split of Hook B selling currency1 is exact; selling
  currency0 it loses at most the exact-input remainders of the pieces.
- Allocation shopping (§6.5) is gone: the price does not depend on the allocation or curator
  (`test_HBP_allocationAndCuratorDoNotAffectPrice`, `test_HAP_freshAllocationDoesNotResetFee`).
- Still not prevented by pricing: splitting across different hooks (`test_ADV_crossHookSplit_boundedByVaultFlowLimit`);
  the vault's flow limits bound it. Waiting for decay is the intended way for prices to recover, and is bounded by
  the decay rate.
