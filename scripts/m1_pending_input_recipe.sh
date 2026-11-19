#!/usr/bin/env bash
# Reception: two-input + join graphs survive checkpoint-after 1 without input re-feed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="${HOME}/.nimble/bin:/root/.nimble/bin:${PATH}"
PIN_SDK="${NIMAGENT_PIN:-bf22665ece77d7149dbe61df959a6024bf6b26f3}"
SDK_SHA="$(git -C vendor/NimAgentLibrary rev-parse HEAD)"
[ "$SDK_SHA" = "$PIN_SDK" ] || { echo "SDK mismatch $SDK_SHA" >&2; exit 2; }

PATHS=(--path:src --path:vendor/NimAgentLibrary/src)
mkdir -p build/m1-pending docs/qa/m1_pending_input_green
nim c --hints:off --warnings:off --threads:on --nimcache:build/nimcache-cli \
  -o:build/nimfactory_cli "${PATHS[@]}" src/nimfactory_cli.nim
CLI=./build/nimfactory_cli
INPUT=tests/fixtures/m1/two_inputs.json

run_pair() {
  local label="$1" graph="$2" expect_py="$3"
  echo "=== $label validate ===" >&2
  "$CLI" validate --graph "$graph" | tee "build/m1-pending/${label}_validate.jsonl"
  echo "=== $label continuous ===" >&2
  local cont="build/m1-pending/${label}_cont.sqlite"
  rm -f "$cont"; rm -rf "${cont}.spill"
  "$CLI" run --graph "$graph" --store "$cont" --run-id "${label}-cont" \
    --mode sequential --input "$INPUT" | tee "build/m1-pending/${label}_cont.jsonl"
  echo "=== $label checkpoint ===" >&2
  local brk="build/m1-pending/${label}_brk.sqlite"
  rm -f "$brk"; rm -rf "${brk}.spill"
  set +e
  "$CLI" run --graph "$graph" --store "$brk" --run-id "${label}-brk" \
    --mode sequential --checkpoint-after 1 --input "$INPUT" \
    > "build/m1-pending/${label}_intr.jsonl"
  local ec=$?
  set -e
  [ "$ec" -eq 5 ] || { echo "expected interrupt 5 got $ec" >&2; exit 4; }
  echo "=== $label resume ===" >&2
  "$CLI" resume --graph "$graph" --store "$brk" --run-id "${label}-brk" \
    --mode sequential | tee "build/m1-pending/${label}_resume.jsonl"
  "$CLI" inspect --store "$brk" --run-id "${label}-brk" \
    | tee "build/m1-pending/${label}_inspect.jsonl" >/dev/null
  "$CLI" resume --graph "$graph" --store "$brk" --run-id "${label}-brk" \
    --mode sequential | tee "build/m1-pending/${label}_resume2.jsonl" >/dev/null
  LABEL="$label" python3 -c "$expect_py"
}

TWO_PY='
import json, os
label=os.environ["LABEL"]
cont=json.load(open(f"build/m1-pending/{label}_cont.jsonl"))
res=json.load(open(f"build/m1-pending/{label}_resume.jsonl"))
res2=json.load(open(f"build/m1-pending/{label}_resume2.jsonl"))
insp=json.load(open(f"build/m1-pending/{label}_inspect.jsonl"))["run"]
assert cont["outputs"]=={"one":{"v":"alpha"},"two":{"v":"beta"}}
assert res["outputs"]==cont["outputs"]==res2["outputs"]
assert res["status"]=="completed" and insp["state"]["phase"]=="completed"
assert insp["state"]["outputs"]==cont["outputs"]
assert "first:main" in res["skipped_validated"]
acts=insp["activations"]
assert acts["first:main"]["invocation_validated"] is True
assert acts["second:main"]["invocation_validated"] is True
print(f"{label}_ok")
'

JOIN_PY='
import json, os
label=os.environ["LABEL"]
cont=json.load(open(f"build/m1-pending/{label}_cont.jsonl"))
res=json.load(open(f"build/m1-pending/{label}_resume.jsonl"))
res2=json.load(open(f"build/m1-pending/{label}_resume2.jsonl"))
insp=json.load(open(f"build/m1-pending/{label}_inspect.jsonl"))["run"]
assert cont["outputs"]["result"]["count"]==2
assert res["outputs"]==cont["outputs"]==res2["outputs"]
assert res["status"]=="completed"
assert insp["state"]["outputs"]==cont["outputs"]
assert "first:main" in res["skipped_validated"]
assert insp["activations"]["second:main"]["invocation_validated"] is True
assert insp["activations"]["join:main"]["invocation_validated"] is True
print(f"{label}_ok")
'

run_pair two recipes/m1_two_inputs.json "$TWO_PY"
run_pair join recipes/m1_two_inputs_join.json "$JOIN_PY"

cp build/m1-pending/*.jsonl docs/qa/m1_pending_input_green/
echo "M1_PENDING_INPUT_RECIPE_OK"
echo "m1_pending_input_recipe: ok sdk=${SDK_SHA}"
