# Schedule: competition-first, November 2026

UHI11 publicly announced calendar: Hookathon Nov 16 to Dec 3, Demo Day Dec 11. Source: https://atrium.academy/sponsors. The user's master blueprint is titled '50-Day Milestones', but shipping all those activities by the actual Hookathon deadline is not credible without aggressive de-scoping.

| Window | Gate | Required demo/evidence |
|--------|------|------------------------|
| Nov 4-8 | Phase 0 / feasibility | Real-v4 ERC-6909 custody and `beforeSwapReturnDelta` tests; two-hook integration or transparent blocker |
| Nov 9-15 | Core | Per-currency cap and isolation, bounded consumption, replay/order adversarial scenarios |
| Nov 16-22 | Curator controls | Signed bounded curator intent, expiry and nonce logic; security tests and invariants |
| Nov 23-28 | Evidence | Quantified gas tests, constrained simulator comparisons, minimal TypeScript signing/inspection only if useful |
| Nov 29-Dec 3 | Submission | Reliable local/testnet demo, security/known-limits sheet, architecture diagram, README, short video and complete submission |
| Dec 4-11 | Demo day preparation | Demo rehearsals and evidence, no risky feature expansion |

## Explicitly post-hackathon unless already secure and proven

- Production mainnet deployment, ERC-4626 integration, full 3-tier economics, reputation, strategy migration, research-paper publication, broad factory UI.

Stop at every gate for user review. If Phase 0 cannot prove safe cross-hook funding, prioritize an honest simpler scoped mechanism over a fake demonstration.
