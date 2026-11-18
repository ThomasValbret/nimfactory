#!/usr/bin/env bash
# Global Wave A (+ A.1) test runner. Exit non-zero on first failure.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="${HOME}/.nimble/bin:/root/.nimble/bin:${PATH}"

if [ ! -d vendor/NimAgentLibrary/src ]; then
  ./scripts/fetch_sdk.sh
fi
SDK_SHA="$(git -C vendor/NimAgentLibrary rev-parse HEAD)"
NIM_VER="$(nim --version | head -1)"
echo "nimfactory=$(git rev-parse HEAD 2>/dev/null || echo dirty)"
echo "nimagent=${SDK_SHA}"
echo "${NIM_VER}"

PATHS=(--path:src --path:vendor/NimAgentLibrary/src)
CACHE_ROOT="${NIMCACHE_ROOT:-$ROOT/build/nimcache-wavea}"
mkdir -p "$CACHE_ROOT" build/logs

TESTS=(
  tests/f0/test_contracts.nim
  tests/f0/test_message_roundtrip.nim
  tests/f0/test_fixture_consumers.nim
  tests/f0/test_validation_strict.nim
  tests/f1/test_artifacts.nim
  tests/f3/test_journal.nim
  tests/f4/test_graph.nim
  tests/f14/test_budget.nim
  tests/f17/test_qualification_smoke.nim
)

# Optional A.1 probes if present
for extra in tests/f17/test_a1_component_probes.nim tests/f1/test_a1_snapshots.nim \
             tests/f3/test_a1_epoch.nim tests/f4/test_a1_structure.nim \
             tests/f14/test_a1_authority.nim; do
  if [ -f "$extra" ]; then
    TESTS+=("$extra")
  fi
done

ok=0
for t in "${TESTS[@]}"; do
  name="$(basename "$t" .nim)"
  echo "=== RUN $t ==="
  nim c -r --hints:off --warnings:off \
    --nimcache:"$CACHE_ROOT/$name" \
    -o:"build/$name" \
    "${PATHS[@]}" \
    "$t" | tee "build/logs/${name}.log"
  ok=$((ok+1))
done

echo "WAVE_A_TESTS_OK count=${ok} sdk=${SDK_SHA}"
