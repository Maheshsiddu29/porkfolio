#!/usr/bin/env bash
# Deep adversarial / release suite. Not run by CI. See docs/security/G01_BASELINE.md §3.
#
# Three suites, one compiler configuration:
#   fast  `forge test`                       default profile: fuzz 1,000; invariants 64 x 64
#   CI    `test/bench/security.sh`           ci profile:      fuzz 10,000; invariants 128 x 128; size gate;
#                                                              production-build tests (what .github/workflows runs)
#   deep  `test/deep.sh` (this script)       deep profile:    everything below
#
# Steps (exit status is non-zero if any gated step fails):
#   1. formatting;
#   2. test/bench/security.sh under the deep profile: forced rebuild, size gate, production-build tests and the complete
#      suite with fuzz 10,000 and invariants 1,000 runs x depth 256 (seed 0x5eed);
#   3. the three invariant campaigns again under further seeds (DEEP_SEEDS, 256 x 128 each);
#   4. the non-vacuity gate, test/invariant/coverage.py (64 single-run campaigns per campaign, depth 128);
#   5. Python conformance tests (simulations/);
#   6. Unichain fork tests, only when UNICHAIN_RPC_URL is set (read-only; UNICHAIN_FORK_BLOCK defaults to the block the
#      published gas figures were measured at). Skipped, and reported as skipped, otherwise;
#   7. Slither, when installed: printed for review, not gated (every finding is triaged by hand).
#
# Deploys nothing, broadcasts nothing, signs nothing. Writes only forge's out/ and cache/ directories.
# A failing invariant sequence is persisted by forge in cache/invariant/failures and replayed first on the next run;
# delete that directory only after the failure has been understood.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
export FOUNDRY_PROFILE=deep
DEEP_SEEDS="${DEEP_SEEDS:-0x1 0x2 0x3}"
CAMPAIGNS='^(VaultInvariantsTest|OracleRiskInvariantsTest|InventoryProtectionInvariantsTest)$'

echo "commit:  $(git rev-parse --short HEAD)$(git diff --quiet HEAD -- || echo ' (uncommitted changes)')"
echo "forge:   $(forge --version | head -1)"
echo "profile: $FOUNDRY_PROFILE; extra seeds: $DEEP_SEEDS"

echo "== 1. formatting"
forge fmt --check

echo "== 2. production builds, size gate and the complete suite (deep profile)"
test/bench/security.sh

echo "== 3. invariant campaigns under further seeds (256 runs x depth 128)"
for seed in $DEEP_SEEDS; do
  echo "-- seed $seed"
  FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-contract "$CAMPAIGNS" --fuzz-seed "$seed"
done

echo "== 4. non-vacuity gate"
python3 test/invariant/coverage.py

echo "== 5. Python conformance"
python3 -m unittest discover -s simulations/mm
python3 -m unittest discover -s simulations/pricing

echo "== 6. Unichain fork tests"
if [ -n "${UNICHAIN_RPC_URL:-}" ]; then
  UNICHAIN_FORK_BLOCK="${UNICHAIN_FORK_BLOCK:-63689000}" forge test --match-path "test/fork/*" --isolate -vv
else
  echo "SKIPPED: UNICHAIN_RPC_URL is not set (8 fork tests not run)"
fi

echo "== 7. static analysis (not gated)"
if command -v slither >/dev/null; then
  slither . --filter-paths "lib/|test/|script/" --exclude-dependencies 2>&1 | tail -3 || true
else
  echo "SKIPPED: slither is not installed"
fi

echo "deep.sh: all gated steps passed"
