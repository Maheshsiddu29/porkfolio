# Porkfolio — Choosing kappa (Phase 1B-4.3, Task 6)

**Status: SYNTHETIC evidence; no recommendation here is an approved deployment setting.** `kappa` is the vault's
inventory tolerance (`inventoryTolerancePips`). The hooks' deviation cap is clamped to it on-chain, so in every run
below the hook cap equals `kappa`.
- Sources: `simulate.py --phase143` (`results/phase143_kappa.md`, `.json`): 9 regimes plus 7 attack worlds, held-out
  seeds.
- `floor_guarantee.py` (`results/floor_guarantee.md`): exact-integer adversary.

## 1. Results

| kappa | fill (push-only / + fresh) | turnover per day (push / fresh) | max asset1 deviation | malicious adapter A4, worst seed (push / fresh) | common-mode +5% A3, worst (push / fresh) | bound at target | worst shortfall in the random search |
|---|---|---|---|---|---|---|---|
| 1% | 4.14% / 35.2% | 0.031 / 0.264 | 1.0% | −39 / −13 bps | +3 / +21 bps | 1% | 2.4% |
| 2% | 4.56% / 37.0% | 0.039 / 0.320 | 2.0% | −89 / −39 bps | +2 / +23 bps | 2% | 5.5% |
| 5% | 4.70% / 37.3% | 0.044 / 0.351 | 5.0% | −233 / −111 bps | −6 / +17 bps | 5% | 11.2% |
| 10% | 4.81% / 37.5% | 0.047 / 0.356 | 10.0% | −386 / −254 bps | −25 / +2 bps | 10% | 21.0% |
| 15% | 4.81% / 37.6% | 0.047 / 0.358 | 15.0% | −514 / −395 bps | −43 / −11 bps | 15% | 41.0% |

Further findings:
- **Withdrawal servicing.** 100% of LP exits are paid instantly at every `kappa`. By construction, LP paths never read
  the inventory floor (`OracleRiskBoundary.t.sol` checks this with a reverting adapter).
- **Repeated refills.** Drain asset0, let honest flow refill it with asset1, drain again, 20 times. The cumulative
  extraction is exactly `kappa` of value: the first drain takes `kappa/2`, and later drains are paid for by asset1's own
  room until it reaches its floor.
- **Exposure across both assets.** Each asset's holding stays within `kappa` below its target. The other side can rise
  by what the vault received.
- **Worst cumulative economic loss.**
  - The proven bound is `sum (h_a − l_a)^+ p_a` (`INVENTORY_FLOOR_GUARANTEE.md`): `kappa` of value at the target
    composition.
  - It is up to about 2.7× `kappa` once fees or skew lift holdings above target (last column; worst of six price
    vectors, including full depegs).
  - Re-centring `tau` on current holdings (raising it is immediate, owner or guardian) brings the bound back to
    `kappa`.

## 2. Reading

1. **`kappa` barely affects availability.**
   - Push-only fill moves from 4.1% to 4.8% across the whole range; it is set by the ±82 bps reference band, not by
     inventory room.
   - With a fresh source, fill moves from 35% to 38%.
   - Utilisation drops about 17% from 2% to 1%, and about 25% from 5% to 1%.
2. **Loss under a compromised adapter is close to linear in `kappa`.** It is the dominant cost of a larger `kappa`, and
   it is what the vault cannot price.
3. **Below about 10%, `kappa` sets the inventory exposure.** The 10% → 5% recovery metric records no episodes at all,
   because the cap stops deviation first.

## 3. Recommended ranges (decision R-4; not approved)

| Setting | Range | Reason |
|---|---|---|
| Mainnet, first limited-value launch | `kappa` 1–2%, hook caps equal | Worst-case loss under total oracle compromise ≈ 1–2% of value at target (≈ 2.4–5.5% with skew, re-centred by raising `tau`). Gives up < 0.6 pt of fill and about 17% of turnover relative to 5%. |
| Mainnet after evidence (monitoring, incident-free period) | up to 5% | Only if the extra utilisation is worth up to 2.5× the compromise loss. |
| Testnet experiments | 5–15% | Exercise the floor, the cap and recovery behaviour; collect data. Not a mainnet signal. |
| Never | above 15% without a new study | The modelled loss passes 500 bps of value. |

Operational rule from correction C4: when holdings drift above target (fees, skew), raise `tau` to the current holding
per share. Raising is immediate for the owner or guardian; lowering waits 32 days.
