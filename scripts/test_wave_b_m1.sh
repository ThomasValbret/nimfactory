#!/usr/bin/env bash
# Wave B M1 reception: F5/F16/F17 tests + CLI resume recipe.
# Does not replace scripts/test_wave_a.sh (A.1 remains mandatory separately).
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
  exit 2
fi

echo "nimfactory=$(git rev-parse HEAD)"
echo "nimagent=${SDK_SHA}"
echo "nimagent_pin_verified=yes"
echo "base_expected=ae331bd57f7db6cbfdde8d02a74e6b819be7e872"

PATHS=(--path:src --path:vendor/NimAgentLibrary/src)
CACHE=build/nimcache-waveb
mkdir -p "$CACHE" build/logs docs/qa

TESTS=(
  tests/f5/test_executor.nim
  tests/f16/test_cli.nim
  tests/f17/test_m1_resume_recipe.nim
)

ok=0
for t in "${TESTS[@]}"; do
  [ -f "$t" ] || { echo "MISSING $t" >&2; exit 3; }
  name="$(basename "$t" .nim)"
  echo "=== RUN $t ==="
  nim c -r --hints:off --warnings:off \
    --nimcache:"$CACHE/$name" -o:"build/$name" \
    "${PATHS[@]}" "$t" | tee "build/logs/${name}.log"
  ok=$((ok+1))
done

echo "=== RUN scripts/m1_resume_recipe.sh ==="
chmod +x scripts/m1_resume_recipe.sh
./scripts/m1_resume_recipe.sh | tee docs/qa/m1_resume_recipe.log
ok=$((ok+1))

echo "=== RUN scripts/m1_pipe_backpressure_cli.sh ==="
chmod +x scripts/m1_pipe_backpressure_cli.sh
./scripts/m1_pipe_backpressure_cli.sh | tee docs/qa/m1_pipe_backpressure_cli.log
ok=$((ok+1))

echo "WAVE_B_M1_OK count=${ok} sdk=${SDK_SHA} pin_verified=yes"
