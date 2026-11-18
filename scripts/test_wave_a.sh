#!/usr/bin/env bash
# Global Wave A (+ A.1 / A.1-R) test runner. Exit non-zero on first failure.
# All reception programs listed below are mandatory (missing file = failure).
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
  tests/f17/test_a1_component_probes.nim
)

PROBES=(
  docs/qa/a1_independent_probe.nim
  docs/qa/a1_frozen_previous_probe.nim
  docs/qa/a1r_boundary_probe.nim
)

missing=0
for t in "${TESTS[@]}" "${PROBES[@]}"; do
  if [ ! -f "$t" ]; then
    echo "MISSING required reception program: $t" >&2
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  exit 3
fi

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

run_probe() {
  local src="$1"
  local name="$2"
  local outbin="$3"
  echo "=== RUN $src ==="
  nim c --hints:off --warnings:off \
    --nimcache:"$CACHE_ROOT/$name" \
    --out:"$outbin" \
    "${PATHS[@]}" \
    "$src"
  "./$outbin" | tee "build/logs/${name}.jsonl"
  ok=$((ok+1))
}

run_probe docs/qa/a1_independent_probe.nim a1_independent_probe build/a1-review-probe
run_probe docs/qa/a1_frozen_previous_probe.nim a1_frozen_previous_probe build/a1-frozen-probe
run_probe docs/qa/a1r_boundary_probe.nim a1r_boundary_probe build/a1r-boundary-probe

echo "WAVE_A_TESTS_OK count=${ok} sdk=${SDK_SHA} pin_verified=yes"
