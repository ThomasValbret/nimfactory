#!/usr/bin/env bash
# Resume regression: diamond wait/cap1 (10/10), durable start, false-completed legacy.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="${HOME}/.nimble/bin:/root/.nimble/bin:${PATH}"
PIN_SDK="${NIMAGENT_PIN:-bf22665ece77d7149dbe61df959a6024bf6b26f3}"
SDK_SHA="$(git -C vendor/NimAgentLibrary rev-parse HEAD)"
[ "$SDK_SHA" = "$PIN_SDK" ] || { echo "SDK mismatch" >&2; exit 2; }

PATHS=(--path:src --path:vendor/NimAgentLibrary/src)
mkdir -p build/m1-resume3 docs/qa/m1_resume3_green
nim c --hints:off --warnings:off --threads:on --nimcache:build/nimcache-cli \
  -o:build/nimfactory_cli "${PATHS[@]}" src/nimfactory_cli.nim
CLI=./build/nimfactory_cli
GRAPH=recipes/m1_diamond.json
INPUT=tests/fixtures/m1/input.json
ORACLE=tests/fixtures/m1/oracle_outputs.json

echo "=== diamond wait/cap1 checkpoints 1-5 seq+conc ===" >&2
fail=0
for mode_args in "sequential" "concurrent --max-concurrency 2"; do
  mode_tag=$(echo "$mode_args" | awk '{print $1}')
  for n in 1 2 3 4 5; do
    store=build/m1-resume3/${mode_tag}-ckpt${n}.sqlite
    rm -f "$store"; rm -rf "${store}.spill"
    set +e
    $CLI run --graph "$GRAPH" --store "$store" --run-id "d-${mode_tag}-${n}" \
      --mode $mode_args --pipe-policy wait --pipe-capacity 1 \
      --checkpoint-after "$n" --input "$INPUT" \
      > "build/m1-resume3/${mode_tag}-intr-${n}.jsonl"
    ec1=$?
    $CLI resume --graph "$GRAPH" --store "$store" --run-id "d-${mode_tag}-${n}" \
      --mode $mode_args --pipe-policy wait --pipe-capacity 1 \
      > "build/m1-resume3/${mode_tag}-res-${n}.jsonl"
    ec2=$?
    set -e
    $CLI inspect --store "$store" --run-id "d-${mode_tag}-${n}" \
      > "build/m1-resume3/${mode_tag}-insp-${n}.jsonl"
    $CLI resume --graph "$GRAPH" --store "$store" --run-id "d-${mode_tag}-${n}" \
      --mode $mode_args --pipe-policy wait --pipe-capacity 1 \
      > "build/m1-resume3/${mode_tag}-res2-${n}.jsonl"
    python3 - <<PY
import json, sys
mode, n = "${mode_tag}", ${n}
cont_want = json.load(open("tests/fixtures/m1/oracle_outputs.json"))["expected_result"]["branch_order"]
res=json.load(open(f"build/m1-resume3/{mode}-res-{n}.jsonl"))
res2=json.load(open(f"build/m1-resume3/{mode}-res2-{n}.jsonl"))
insp=json.load(open(f"build/m1-resume3/{mode}-insp-{n}.jsonl"))["run"]
assert ${ec1}==5 and ${ec2}==0, (${ec1},${ec2})
assert res["status"]=="completed"
br=[i["branch"] for i in res["outputs"]["result"]["items"]]
assert br==cont_want, br
assert res["outputs"]==insp["state"]["outputs"]==res2["outputs"]
print(f"ok {mode} ckpt={n}")
PY
  done
done

echo "=== durable start crash (beginGraphRun boundary) ===" >&2
nim c -r --hints:off --warnings:off --threads:on --nimcache:build/nc-r3 \
  -o:build/test_resume_saturation_start_legacy "${PATHS[@]}" \
  tests/f5/test_resume_saturation_start_legacy.nim \
  | tee docs/qa/m1_resume3_green/unit.log

echo "=== false-completed legacy DBs ===" >&2
for label in two join; do
  g=recipes/m1_two_inputs.json
  [ "$label" = join ] && g=recipes/m1_two_inputs_join.json
  store=docs/qa/m1_resume3_red/legacy_dbs/${label}_false.sqlite
  set +e
  $CLI resume --graph "$g" --store "$store" --run-id "false-$label" --mode sequential \
    > "build/m1-resume3/false-${label}.jsonl" 2> "build/m1-resume3/false-${label}.err"
  ec=$?
  set -e
  [ "$ec" -ne 0 ] || { echo "expected non-zero for false-$label" >&2; exit 5; }
  grep -q "false completed" "build/m1-resume3/false-${label}.err" \
    "build/m1-resume3/false-${label}.jsonl" && echo "false_${label}_diag_ok" \
    || { echo "missing false completed diagnostic" >&2; cat build/m1-resume3/false-${label}.*; exit 5; }
done

cp build/m1-resume3/*.jsonl docs/qa/m1_resume3_green/ 2>/dev/null || true
echo "M1_RESUME3_REGRESSION_OK"
echo "m1_resume3_regression: ok sdk=${SDK_SHA}"
