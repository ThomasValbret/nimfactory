#!/usr/bin/env bash
# M1 reception recipe: continuous vs interrupt+resume across two processes.
# No provider keys. Requires Nim 2.4+ and pinned NimAgent via vendor/.
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

PATHS=(--path:src --path:vendor/NimAgentLibrary/src)
mkdir -p build/m1-recipe build/logs docs/qa
nim c --hints:off --warnings:off --nimcache:build/nimcache-cli \
  -o:build/nimfactory_cli "${PATHS[@]}" src/nimfactory_cli.nim

GRAPH=recipes/m1_diamond.json
INPUT=tests/fixtures/m1/input.json
ORACLE=tests/fixtures/m1/oracle_outputs.json
STORE_CONT=build/m1-recipe/continuous.sqlite
STORE_BRK=build/m1-recipe/broken.sqlite
rm -f "$STORE_CONT" "$STORE_BRK"
rm -rf "${STORE_CONT}.spill" "${STORE_BRK}.spill"

CLI=./build/nimfactory_cli

echo "=== validate ===" >&2
"$CLI" validate --graph "$GRAPH" | tee build/logs/m1_validate.jsonl

echo "=== continuous sequential ===" >&2
"$CLI" run --graph "$GRAPH" --store "$STORE_CONT" --run-id m1-cont-seq \
  --mode sequential --input "$INPUT" | tee build/logs/m1_cont_seq.jsonl

echo "=== continuous concurrent ===" >&2
STORE_CONC=build/m1-recipe/concurrent.sqlite
rm -f "$STORE_CONC"; rm -rf "${STORE_CONC}.spill"
"$CLI" run --graph "$GRAPH" --store "$STORE_CONC" --run-id m1-cont-conc \
  --mode concurrent --max-concurrency 2 --input "$INPUT" | tee build/logs/m1_cont_conc.jsonl

echo "=== interrupt process 1 (checkpoint-after 1) ===" >&2
set +e
"$CLI" run --graph "$GRAPH" --store "$STORE_BRK" --run-id m1-resume \
  --mode sequential --checkpoint-after 1 --input "$INPUT" \
  > build/logs/m1_interrupt.jsonl
INT_EXIT=$?
set -e
echo "interrupt_exit=${INT_EXIT}" >&2
# ExitInterrupted=5 (see cli.nim: Nim clamps codes >127 to 127 on this host).
if [ "$INT_EXIT" -ne 5 ]; then
  echo "expected exit 5 after checkpoint, got ${INT_EXIT}" >&2
  cat build/logs/m1_interrupt.jsonl >&2 || true
  exit 4
fi
python3 - <<'PY'
import json
intr=json.load(open("build/logs/m1_interrupt.jsonl"))
assert intr.get("status")=="interrupted", intr
print("interrupt_status_ok")
PY

echo "=== resume process 2 ===" >&2
"$CLI" resume --graph "$GRAPH" --store "$STORE_BRK" --run-id m1-resume \
  --mode sequential | tee build/logs/m1_resume.jsonl

echo "=== inspect journal ===" >&2
"$CLI" inspect --store "$STORE_BRK" --run-id m1-resume \
  | tee build/logs/m1_inspect.jsonl >/dev/null

python3 - <<'PY'
import json, sys
oracle = json.load(open("tests/fixtures/m1/oracle_outputs.json"))
want_order = oracle["expected_result"]["branch_order"]
want_count = oracle["expected_result"]["count"]

def branches(path):
    r = json.load(open(path))
    items = r.get("outputs", {}).get("result", {}).get("items", [])
    return [i.get("branch") for i in items], r

seq_b, seq = branches("build/logs/m1_cont_seq.jsonl")
conc_b, conc = branches("build/logs/m1_cont_conc.jsonl")
res_b, res = branches("build/logs/m1_resume.jsonl")
intr = json.load(open("build/logs/m1_interrupt.jsonl"))
insp = json.load(open("build/logs/m1_inspect.jsonl"))["run"]

assert seq["status"] == "completed" and conc["status"] == "completed"
assert res["status"] == "completed", res
assert intr["status"] == "interrupted"
assert seq_b == want_order == conc_b == res_b
assert len(seq_b) == want_count

# Same run_id preserved
assert res["run_id"] == "m1-resume"
assert insp["run_id"] == "m1-resume"

# Validated activations must not be re-invokable
policy = {p["activation_id"]: p for p in insp.get("reinvoke_policy", [])}
assert "split:main" in policy and policy["split:main"]["reinvoke_allowed"] is False

# Resume skipped at least the checkpointed activation
skipped = res.get("skipped_validated", [])
assert "split:main" in skipped, skipped

# No duplicate activation ids among completed leaf/control nodes
acts = [a["activation_id"] for a in res.get("activations", [])
        if not a["activation_id"].startswith("run:")]
assert len(acts) == len(set(acts)), acts

print("M1_RESUME_RECIPE_OK")
print(json.dumps({
  "oracle_branches": want_order,
  "sequential": seq_b,
  "concurrent": conc_b,
  "resumed": res_b,
  "interrupt_commits": intr.get("activation_commits"),
  "skipped_validated": skipped,
}, sort_keys=True))
PY

cp build/logs/m1_cont_seq.jsonl docs/qa/m1_cont_seq.jsonl
cp build/logs/m1_cont_conc.jsonl docs/qa/m1_cont_conc.jsonl
cp build/logs/m1_interrupt.jsonl docs/qa/m1_interrupt.jsonl
cp build/logs/m1_resume.jsonl docs/qa/m1_resume.jsonl
cp build/logs/m1_inspect.jsonl docs/qa/m1_inspect.jsonl
echo "m1_resume_recipe: ok sdk=${SDK_SHA}"
