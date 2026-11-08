#!/usr/bin/env bash
# Production-artifact size and gas benchmark. See test/bench/README.md.
#
# Rebuilds from scratch, prints the optimizer settings recorded in each production artifact, checks them against the
# resolved foundry config, prints sizes, EIP-170 margins and init-code hashes, then runs the gas benchmark with
# --isolate. Writes nothing except forge's own out/ and cache/ directories.
#
# Exit status is non-zero if a production artifact was compiled with unexpected settings, if the vault has more than
# one artifact, or if any production contract exceeds the EIP-170 runtime limit. A margin below the project target
# (2,048 bytes) is reported as BELOW_TARGET but does not fail the run.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
command -v jq >/dev/null || { echo "run.sh: jq is required" >&2; exit 2; }
command -v cast >/dev/null || { echo "run.sh: cast is required" >&2; exit 2; }

EIP170=24576
TARGET_MARGIN=2048
VAULT_SRC="src/SharedCommitmentVault.sol"
fail=0

dirty=""
git diff --quiet HEAD -- || dirty=" (uncommitted changes)"
echo "commit:   $(git rev-parse --short HEAD)${dirty}"
echo "forge:    $(forge --version | head -1)"

config="$(forge config --json)"
default_runs="$(jq -r '.optimizer_runs' <<<"$config")"
vault_runs="$(jq -r --arg p "$VAULT_SRC" \
  '[.compilation_restrictions[]? | select(.paths == $p) | .optimizer_runs // empty] | first // empty' <<<"$config")"
[ -n "$vault_runs" ] || vault_runs="$default_runs"
echo "config:   default optimizer_runs=$default_runs, vault optimizer_runs=$vault_runs, via_ir=$(jq -r .via_ir <<<"$config")"
echo

forge build --force >/dev/null 2>&1 || { forge build; exit 1; }

# artifact_row <artifact json> <expected runs or "-">
artifact_row() {
  local f="$1" expect="$2"
  local runs via evm bh init runtime hash margin flag
  runs="$(jq -r '.metadata.settings.optimizer.runs' "$f")"
  via="$(jq -r '.metadata.settings.viaIR' "$f")"
  evm="$(jq -r '.metadata.settings.evmVersion' "$f")"
  bh="$(jq -r '.metadata.settings.metadata.bytecodeHash // "ipfs"' "$f")"
  init=$(( ($(jq -r '.bytecode.object' "$f" | wc -c) - 3) / 2 ))
  runtime=$(( ($(jq -r '.deployedBytecode.object' "$f" | wc -c) - 3) / 2 ))
  hash="$(cast keccak "$(jq -r '.bytecode.object' "$f")")"
  margin=$(( EIP170 - runtime ))
  flag="ok"
  [ "$expect" = "-" ] && flag="(not checked)"
  if [ "$expect" != "-" ] && [ "$runs" != "$expect" ]; then flag="WRONG_RUNS(expected $expect)"; fail=1; fi
  if [ "$expect" != "-" ] && [ "$margin" -lt 0 ]; then flag="OVER_EIP170"; fail=1;
  elif [ "$expect" != "-" ] && [ "$margin" -lt "$TARGET_MARGIN" ] && [ "$flag" = "ok" ]; then flag="BELOW_TARGET"; fi
  printf '%-50s runs=%-9s viaIR=%-5s evm=%-7s hash=%-5s runtime=%-6s init=%-6s margin=%-6s %s\n' \
    "${f#out/}" "$runs" "$via" "$evm" "$bh" "$runtime" "$init" "$margin" "$flag"
  printf '%-50s init-code keccak256 (no constructor args) %s\n' "" "$hash"
}

echo "== Artifacts (production build = the one with the expected runs)"
vault_artifacts=(out/SharedCommitmentVault.sol/*.json)
if [ "${#vault_artifacts[@]}" -ne 1 ]; then
  echo "FAIL: expected exactly one SharedCommitmentVault artifact, found ${#vault_artifacts[@]}"; fail=1
fi
for f in "${vault_artifacts[@]}"; do artifact_row "$f" "$vault_runs"; done

for c in HookA_DynamicFee HookB_BoundedImpact VaultLens; do
  [ -d "out/$c.sol" ] || continue
  found=0
  for f in out/"$c".sol/*.json; do
    runs="$(jq -r '.metadata.settings.optimizer.runs' "$f")"
    if [ "$runs" = "$default_runs" ]; then artifact_row "$f" "$default_runs"; found=1; else artifact_row "$f" "-"; fi
  done
  if [ "$found" -ne 1 ]; then echo "FAIL: no $c artifact built with the default profile"; fail=1; fi
done
echo "-- PoolManager: upstream v4-core, deployed by Uniswap, not by this project. Listed to show which build the tests use."
for f in out/PoolManager.sol/*.json; do artifact_row "$f" "-"; done
echo "(\"not checked\" rows are builds that are never deployed by this project)"
echo

echo "== Gas (forge test --isolate, gasleft() around one external call)"
if bench="$(forge test --match-path test/bench/ProductionArtifactGas.t.sol --isolate -vv 2>&1)"; then
  grep -E "BENCH" <<<"$bench" | sed -E 's/^ *BENCH //'
else
  grep -E "FAIL|Error" <<<"$bench"; echo "FAIL: benchmark tests failed"; fail=1
fi

exit "$fail"
