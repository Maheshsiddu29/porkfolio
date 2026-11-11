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

(2.1 s)
