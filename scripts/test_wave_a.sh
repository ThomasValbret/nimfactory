#!/usr/bin/env bash
# Global Wave A (+ A.1) test runner. Exit non-zero on first failure.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="${HOME}/.nimble/bin:/root/.nimble/bin:${PATH}"

PIN_SDK="${NIMAGENT_PIN:-bf22665ece77d7149dbe61df959a6024bf6b26f3}"

if [ ! -d vendor/NimAgentLibrary/src ]; then
  ./scripts/fetch_sdk.sh
fi
SDK_SHA="$(git -C vendor/NimAgentLibrary rev-parse HEAD)"
if [ "$SDK_SHA" != "$PIN_SDK" ]; then
  echo "SDK SHA mismatch: got ${SDK_SHA} expected ${PIN_SDK}" >&2
  echo "Run: NIMAGENT_PIN=${PIN_SDK} ./scripts/fetch_sdk.sh" >&2
  exit 2
fi

NIM_VER="$(nim --version | head -1)"
echo "nimfactory=$(git rev-parse HEAD 2>/dev/null || echo dirty)"
echo "nimagent=${SDK_SHA}"
echo "nimagent_pin_verified=yes"
echo "${NIM_VER}"

PATHS=(--path:src --path:vendor/NimAgentLibrary/src)
CACHE_ROOT="${NIMCACHE_ROOT:-$ROOT/build/nimcache-wavea}"
mkdir -p "$CACHE_ROOT" build/logs

TESTS=(
  tests/f0/test_contracts.nim
  tests/f0/test_message_roundtrip.nim
  tests/f0/test_fixture_consumers.nim
  tests/f0/test_validation_strict.nim
  tests/f0/test_a1_r5.nim
  tests/f1/test_artifacts.nim
  tests/f3/test_journal.nim
  tests/f4/test_graph.nim
  tests/f14/test_budget.nim
  tests/f17/test_qualification_smoke.nim
)

for extra in tests/f17/test_a1_component_probes.nim; do
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

# Independent A.1 probe (must be green after remediation)
if [ -f docs/qa/a1_independent_probe.nim ]; then
  echo "=== RUN docs/qa/a1_independent_probe.nim ==="
  nim c --hints:off --warnings:off \
    --nimcache:"$CACHE_ROOT/a1_probe" \
    --out:build/a1-review-probe \
    "${PATHS[@]}" \
    docs/qa/a1_independent_probe.nim
  ./build/a1-review-probe | tee build/logs/a1_independent_probe.jsonl
  ok=$((ok+1))
fi

echo "WAVE_A_TESTS_OK count=${ok} sdk=${SDK_SHA} pin_verified=yes"
