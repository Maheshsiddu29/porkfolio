#!/usr/bin/env bash
# Production-build security suite. See test/bench/README.md.
#
# Rebuilds from scratch (so out/ holds the production artifacts of every contract), then:
#   0. size gate on the production artifacts: the vault keeps at least 2,048 bytes under EIP-170 (24,576), every
#      other production contract fits EIP-170, and every init code fits EIP-3860 (49,152);
#   1. ProductionBuilds.t.sol: the shared functional fixture deploys the production builds, checked against each
#      artifact's recorded compiler settings and masked runtime-code hash, and their sizes against the same limits;
#   2. ProductionArtifactSecurity.t.sol: security scenarios against contracts deployed from artifact files by path,
#      with the masked runtime hashes logged;
#   3. the complete suite, whose VaultTestBase-derived tests (unit, integration, security, fuzz, invariants) run
#      on those same production builds.
# Uses FOUNDRY_PROFILE=ci (10,000 fuzz runs) unless FOUNDRY_PROFILE is already set. Writes nothing except forge's
# own out/ and cache/ directories. Exit status is non-zero if any step fails.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
command -v jq >/dev/null || { echo "security.sh: jq is required" >&2; exit 2; }
export FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-ci}"

echo "commit:  $(git rev-parse --short HEAD)$(git diff --quiet HEAD -- || echo ' (uncommitted changes)')"
echo "forge:   $(forge --version | head -1)"
echo "profile: $FOUNDRY_PROFILE"

forge build --force >/dev/null 2>&1 || { forge build; exit 1; }

# size <artifact json> <bytecode|deployedBytecode>: bytes of the object (hex digits / 2, without "0x").
size() { echo $(( ($(jq -r ".$2.object" "$1" | wc -c) - 3) / 2 )); }
gate=0
for c in SharedCommitmentVault HookA_DynamicFee HookB_BoundedImpact VaultLens CuratorAuthorization; do
  f="out/$c.sol/$c.json"
  [ -f "$f" ] || { echo "size gate: missing production artifact $f"; gate=1; continue; }
  runtime="$(size "$f" deployedBytecode)"
  init="$(size "$f" bytecode)"
  need=0
  [ "$c" = SharedCommitmentVault ] && need=2048
  margin=$(( 24576 - runtime ))
  status=ok
  if [ "$margin" -lt "$need" ] || [ "$init" -gt 49152 ]; then status=FAIL; gate=1; fi
  printf 'size gate: %-22s runtime=%-6s margin=%-6s (need >= %s) init=%-6s %s\n' \
    "$c" "$runtime" "$margin" "$need" "$init" "$status"
done
[ "$gate" -eq 0 ] || { echo "size gate failed"; exit 1; }

forge test --match-path test/unit/ProductionBuilds.t.sol -vv
forge test --match-path test/bench/ProductionArtifactSecurity.t.sol -vv
forge test
