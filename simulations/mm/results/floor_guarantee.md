# Inventory-floor guarantee: stateful adversarial search (SYNTHETIC, exact integers)

random sequences: 300 x 400 steps; payouts checked: 40526; price vectors per payout: 6
T1 violations (per-share holding fell below min(previous, floor)): 0
T2 breaches (paid < guaranteed basket - 2 units): 0
largest rounding deficit against an LP (guaranteed - paid): 1.900 raw units of the dearer asset
worst shortfall / T2 bound (bounds > 1,000 units), random: 1.000891; hill-climbed: 1.000000
worst shortfall / entry value, random (kappa 5%): 0.1329  <- exceeds kappa: T3 is false

Counterexamples to stronger claims (kappa 5%):
  fee accrual then drain: value lost 0.0576 of the post-fee value (> 0.05)
  skewed composition: 0.0952 of the asset0 holding extractable (> 0.05)
  owner loosens tau immediately: 1.0000 of the reserve extractable
  static mode without the inventory floor: 0.5000 extractable
  queued LP during a delayed loosening: queued 1000000000 shares; finalized at 0 asset0 + 1000000000 asset1 (entry about 1000000000 of each)

Per kappa (SYNTHETIC; p = (1, 1) except the random-search column, which takes the worst of 6 price vectors):

| kappa | bound at target (of value) | first one-sided drain | 20 drain-and-refill cycles (cumulative) | worst shortfall / entry value, random search |
|---|---|---|---|---|
| 1% | 0.010 | 0.0050 | 0.0100 | 0.0239 |
| 2% | 0.020 | 0.0100 | 0.0200 | 0.0551 |
| 5% | 0.050 | 0.0250 | 0.0500 | 0.1118 |
| 10% | 0.100 | 0.0500 | 0.1000 | 0.2099 |
| 15% | 0.150 | 0.0750 | 0.1500 | 0.4098 |

(3.3 s)
