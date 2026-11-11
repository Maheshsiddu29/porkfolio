# Proposed production changes (NOT applied)

Each file here is an exact change to production contracts, kept for review. None is applied to `src/`, none is
approved, and each was compiled and tested only in a scratch copy outside the repository. `git apply --check <file>`
confirms a patch still applies to the current tree; it does not apply it.

| Patch | Status | Description |
|---|---|---|
| `oracle-risk-boundary.patch` | **current proposal** (Phase 1B-4.2) | Vault-side oracle risk boundary: time-locked `IMarketRiskAdapter`, uncertainty breaker, dynamic floor outside the reference band, price-free inventory floor. In adapter mode the static vault floor is not consulted; no static band. Includes the prototype test `test/proto/OracleRiskBoundaryProto.t.sol`. Measured: 25,269 B at 2,000 runs (over EIP-170), 22,424 B at 200 runs. See `docs/architecture/PHASE1B4_2_REPORT.md`. |
| `vault-dynamic-floor.patch` | **superseded, rejected by the owner** (Phase 1B-4.1) | Dynamic floor with a ±25% static outer band. Kept as evidence only. |
