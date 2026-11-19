#!/usr/bin/env bash
# CLI regression: diamond pipe wait/reject/spill with external hang bound.
# Fails (exit 124 path → non-zero) if a wait run freezes past TIMEOUT_SECS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="${HOME}/.nimble/bin:/root/.nimble/bin:${PATH}"

PIN_SDK="${NIMAGENT_PIN:-bf22665ece77d7149dbe61df959a6024bf6b26f3}"
SDK_SHA="$(git -C vendor/NimAgentLibrary rev-parse HEAD)"
if [ "$SDK_SHA" != "$PIN_SDK" ]; then
  echo "SDK SHA mismatch: got ${SDK_SHA} expected ${PIN_SDK}" >&2
  exit 2
fi

PATHS=(--path:src --path:vendor/NimAgentLibrary/src)
mkdir -p build/m1-pipe build/logs docs/qa
nim c --hints:off --warnings:off --threads:on --nimcache:build/nimcache-cli \
  -o:build/nimfactory_cli "${PATHS[@]}" src/nimfactory_cli.nim

CLI=./build/nimfactory_cli
GRAPH=recipes/m1_diamond.json
INPUT=tests/fixtures/m1/input.json
TIMEOUT_SECS="${PIPE_HANG_TIMEOUT_SECS:-8}"

run_bounded() {
  # Prints LABEL_EXIT=<code> on stderr; echoes code on stdout for capture.
  # Never returns non-zero except via explicit exit on hang (keeps set -e safe).
  local label="$1"; shift
  local out="$1"; shift
  local ec=0
  timeout "${TIMEOUT_SECS}s" "$CLI" "$@" >"$out" || ec=$?
  if [ "$ec" -eq 124 ]; then
    echo "HANG: ${label} exceeded ${TIMEOUT_SECS}s" >&2
    exit 124
  fi
  echo "${label}_exit=${ec}" >&2
  echo "$ec"
}

echo "=== wait capacity 1 sequential ===" >&2
STORE=build/m1-pipe/wait-seq.sqlite
rm -f "$STORE"; rm -rf "${STORE}.spill"
ec="$(run_bounded wait_seq build/logs/m1_pipe_wait_seq.jsonl \
  run --graph "$GRAPH" --store "$STORE" --run-id pipe-wait-seq \
  --mode sequential --pipe-capacity 1 --pipe-policy wait --input "$INPUT")"
[ "$ec" -eq 0 ] || { echo "wait_seq expected 0 got $ec" >&2; exit 5; }
python3 - <<'PY'
import json
r=json.load(open("build/logs/m1_pipe_wait_seq.jsonl"))
assert r["status"]=="completed", r
assert [i["branch"] for i in r["outputs"]["result"]["items"]]==["left","right"]
print("wait_seq_ok")
PY

echo "=== wait capacity 1 concurrent ===" >&2
STORE=build/m1-pipe/wait-conc.sqlite
rm -f "$STORE"; rm -rf "${STORE}.spill"
ec="$(run_bounded wait_conc build/logs/m1_pipe_wait_conc.jsonl \
  run --graph "$GRAPH" --store "$STORE" --run-id pipe-wait-conc \
  --mode concurrent --max-concurrency 2 --pipe-capacity 1 --pipe-policy wait \
  --input "$INPUT")"
[ "$ec" -eq 0 ] || { echo "wait_conc expected 0 got $ec" >&2; exit 5; }
python3 - <<'PY'
import json
r=json.load(open("build/logs/m1_pipe_wait_conc.jsonl"))
assert r["status"]=="completed", r
assert [i["branch"] for i in r["outputs"]["result"]["items"]]==["left","right"]
print("wait_conc_ok")
PY

echo "=== reject capacity 1 ===" >&2
STORE=build/m1-pipe/reject.sqlite
rm -f "$STORE"; rm -rf "${STORE}.spill"
rej_ec="$(run_bounded reject build/logs/m1_pipe_reject.jsonl \
  run --graph "$GRAPH" --store "$STORE" --run-id pipe-reject \
  --mode sequential --pipe-capacity 1 --pipe-policy reject --input "$INPUT")"
# Saturation reject must surface as CLI ExitFailed == 4 (not hang 124, not success).
if [ "$rej_ec" -ne 4 ]; then
  echo "reject expected exact exit 4, got ${rej_ec}" >&2
  cat build/logs/m1_pipe_reject.jsonl >&2 || true
  exit 5
fi
echo "reject_ok exit=${rej_ec}" >&2

echo "=== spill capacity 1 ===" >&2
STORE=build/m1-pipe/spill.sqlite
rm -f "$STORE"; rm -rf "${STORE}.spill"
ec="$(run_bounded spill build/logs/m1_pipe_spill.jsonl \
  run --graph "$GRAPH" --store "$STORE" --run-id pipe-spill \
  --mode sequential --pipe-capacity 1 --pipe-policy spill --input "$INPUT")"
[ "$ec" -eq 0 ] || { echo "spill expected 0 got $ec" >&2; exit 5; }
python3 - <<'PY'
import json
r=json.load(open("build/logs/m1_pipe_spill.jsonl"))
assert r["status"]=="completed", r
assert r["pipe_stats"]["spilled"] >= 1, r["pipe_stats"]
assert [i["branch"] for i in r["outputs"]["result"]["items"]]==["left","right"]
print("spill_ok")
PY

cp build/logs/m1_pipe_wait_seq.jsonl docs/qa/m1_pipe_wait_seq.jsonl
cp build/logs/m1_pipe_wait_conc.jsonl docs/qa/m1_pipe_wait_conc.jsonl
cp build/logs/m1_pipe_reject.jsonl docs/qa/m1_pipe_reject.jsonl
cp build/logs/m1_pipe_spill.jsonl docs/qa/m1_pipe_spill.jsonl

echo "M1_PIPE_BACKPRESSURE_CLI_OK"
echo "m1_pipe_backpressure_cli: ok sdk=${SDK_SHA}"
