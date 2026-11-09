#!/usr/bin/env bash
# Production-build security suite. See test/bench/README.md.
#
# Rebuilds from scratch (so out/ holds the production artifacts of every contract), then runs:
#   1. ProductionBuilds.t.sol: the shared functional fixture deploys the production builds, checked against each
#      artifact's recorded compiler settings and masked runtime-code hash;
#   2. ProductionArtifactSecurity.t.sol: security scenarios against contracts deployed from artifact files by path,
#      with the masked runtime hashes logged;
#   3. the complete suite, whose VaultTestBase-derived tests (unit, integration, security, fuzz, invariants) run
#      on those same production builds.
# Uses FOUNDRY_PROFILE=ci (10,000 fuzz runs) unless FOUNDRY_PROFILE is already set. Writes nothing except forge's
# own out/ and cache/ directories. Exit status is non-zero if any step fails.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
export FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-ci}"

echo "commit:  $(git rev-parse --short HEAD)$(git diff --quiet HEAD -- || echo ' (uncommitted changes)')"
echo "forge:   $(forge --version | head -1)"
echo "profile: $FOUNDRY_PROFILE"

forge build --force >/dev/null
forge test --match-path test/unit/ProductionBuilds.t.sol -vv
forge test --match-path test/bench/ProductionArtifactSecurity.t.sol -vv
forge test
