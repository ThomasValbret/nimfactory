#!/usr/bin/env bash
# M1 reception recipe: continuous vs interrupt+resume at every diamond checkpoint.
# Fails if a displayed result is missing from durable SQLite state.
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
nim c --hints:off --warnings:off --nimcache:build/nimcache-cli --threads:on \
  -o:build/nimfactory_cli "${PATHS[@]}" src/nimfactory_cli.nim

GRAPH=recipes/m1_diamond.json
INPUT=tests/fixtures/m1/input.json
ORACLE=tests/fixtures/m1/oracle_outputs.json
CLI=./build/nimfactory_cli

echo "=== validate ===" >&2
"$CLI" validate --graph "$GRAPH" | tee build/logs/m1_validate.jsonl

echo "=== continuous sequential ===" >&2
STORE_CONT=build/m1-recipe/continuous.sqlite
rm -f "$STORE_CONT"; rm -rf "${STORE_CONT}.spill"
"$CLI" run --graph "$GRAPH" --store "$STORE_CONT" --run-id m1-cont-seq \
  --mode sequential --input "$INPUT" | tee build/logs/m1_cont_seq.jsonl

echo "=== continuous concurrent ===" >&2
STORE_CONC=build/m1-recipe/concurrent.sqlite
rm -f "$STORE_CONC"; rm -rf "${STORE_CONC}.spill"
"$CLI" run --graph "$GRAPH" --store "$STORE_CONC" --run-id m1-cont-conc \
  --mode concurrent --max-concurrency 2 --input "$INPUT" | tee build/logs/m1_cont_conc.jsonl

# Diamond activations in sequential order: split, left, right, merge, reduce (then final).
# Checkpoint after N commits; verify durable outputs match displayed at interrupt.
EXPECTED_VALIDATED_AT=(
  "1:split:main"
  "2:split:main,left:left"
  "3:split:main,left:left,right:right"
  "4:split:main,left:left,right:right,merge:main"
  "5:split:main,left:left,right:right,merge:main,reduce:main"
)

for spec in "${EXPECTED_VALIDATED_AT[@]}"; do
  N="${spec%%:*}"
  WANT_ACTS="${spec#*:}"
  STORE_BRK="build/m1-recipe/broken-ckpt${N}.sqlite"
  rm -f "$STORE_BRK"; rm -rf "${STORE_BRK}.spill"
  echo "=== interrupt checkpoint-after ${N} ===" >&2
  set +e
  "$CLI" run --graph "$GRAPH" --store "$STORE_BRK" --run-id "m1-resume-${N}" \
    --mode sequential --checkpoint-after "$N" --input "$INPUT" \
    > "build/logs/m1_interrupt_ckpt${N}.jsonl"
  INT_EXIT=$?
  set -e
  echo "interrupt_exit_${N}=${INT_EXIT}" >&2
  if [ "$INT_EXIT" -ne 5 ]; then
    echo "expected exit 5 after checkpoint ${N}, got ${INT_EXIT}" >&2
    cat "build/logs/m1_interrupt_ckpt${N}.jsonl" >&2 || true
    exit 4
  fi

  echo "=== inspect at interrupt ${N} (durable must match displayed) ===" >&2
  "$CLI" inspect --store "$STORE_BRK" --run-id "m1-resume-${N}" \
    | tee "build/logs/m1_inspect_intr_ckpt${N}.jsonl" >/dev/null

  python3 - <<PY
import json
N = ${N}
want_acts = "${WANT_ACTS}".split(",")
intr = json.load(open(f"build/logs/m1_interrupt_ckpt{N}.jsonl"))
insp = json.load(open(f"build/logs/m1_inspect_intr_ckpt{N}.jsonl"))["run"]
assert intr.get("status") == "interrupted", intr
displayed = intr.get("outputs") or {}
durable = (insp.get("state") or {}).get("outputs") or {}
if displayed and len(displayed) > 0:
    assert durable == displayed, (
        "FAIL: displayed result missing from SQLite at interrupt",
        {"displayed": displayed, "durable": durable},
    )
acts = insp.get("activations") or {}
for aid in want_acts:
    assert aid in acts, f"missing activation {aid}"
    assert acts[aid].get("invocation_validated") is True, acts[aid]
for e in insp.get("events", []):
    tid = e.get("transition_id") or (e.get("body") or {}).get("transition_id") or ""
    if isinstance(tid, str) and tid.startswith("tx-") and tid != "tx-start":
        raise AssertionError(f"unstable transition id: {tid}")
print(f"interrupt_durable_ok ckpt={N}")
PY

  echo "=== resume after checkpoint ${N} ===" >&2
  "$CLI" resume --graph "$GRAPH" --store "$STORE_BRK" --run-id "m1-resume-${N}" \
    --mode sequential | tee "build/logs/m1_resume_ckpt${N}.jsonl"

  echo "=== inspect after resume ${N} ===" >&2
  "$CLI" inspect --store "$STORE_BRK" --run-id "m1-resume-${N}" \
    | tee "build/logs/m1_inspect_ckpt${N}.jsonl" >/dev/null

  # Second resume of completed run must be idempotent (CLI).
  "$CLI" resume --graph "$GRAPH" --store "$STORE_BRK" --run-id "m1-resume-${N}" \
    --mode sequential | tee "build/logs/m1_resume2_ckpt${N}.jsonl" >/dev/null

  python3 - <<PY
import json
N = ${N}
want_acts = "${WANT_ACTS}".split(",")
oracle = json.load(open("tests/fixtures/m1/oracle_outputs.json"))
want_order = oracle["expected_result"]["branch_order"]
want_count = oracle["expected_result"]["count"]
cont = json.load(open("build/logs/m1_cont_seq.jsonl"))
res = json.load(open(f"build/logs/m1_resume_ckpt{N}.jsonl"))
res2 = json.load(open(f"build/logs/m1_resume2_ckpt{N}.jsonl"))
insp = json.load(open(f"build/logs/m1_inspect_ckpt{N}.jsonl"))["run"]

assert res.get("status") == "completed", res
assert res2.get("status") == "completed", res2
assert res.get("run_id") == f"m1-resume-{N}"

def branches(r):
    items = r.get("outputs", {}).get("result", {}).get("items", [])
    return [i.get("branch") for i in items]

assert branches(res) == want_order == branches(cont), (branches(res), want_order)
assert res["outputs"]["result"]["count"] == want_count
assert res["outputs"] == cont["outputs"], "resume outputs must match continuous"
assert res2["outputs"] == res["outputs"], "second resume must be identical"

acts = insp.get("activations") or {}
for aid in want_acts:
    assert aid in acts and acts[aid].get("invocation_validated") is True

skipped = set(res.get("skipped_validated") or [])
for aid in want_acts:
    assert aid in skipped, f"validated {aid} was re-run; skipped={skipped}"

policy = {p["activation_id"]: p for p in insp.get("reinvoke_policy", [])}
for aid in want_acts:
    assert aid in policy and policy[aid]["reinvoke_allowed"] is False

print(f"checkpoint_{N}_ok validated={want_acts}")
PY
done

# Keep legacy single-file names for docs/qa copy (checkpoint 1 + final resume).
cp build/logs/m1_cont_seq.jsonl docs/qa/m1_cont_seq.jsonl
cp build/logs/m1_cont_conc.jsonl docs/qa/m1_cont_conc.jsonl
cp build/logs/m1_interrupt_ckpt1.jsonl docs/qa/m1_interrupt.jsonl
cp build/logs/m1_resume_ckpt1.jsonl docs/qa/m1_resume.jsonl
cp build/logs/m1_inspect_ckpt1.jsonl docs/qa/m1_inspect.jsonl

python3 - <<'PY'
import json
oracle = json.load(open("tests/fixtures/m1/oracle_outputs.json"))
want = oracle["expected_result"]["branch_order"]
seq = json.load(open("build/logs/m1_cont_seq.jsonl"))
conc = json.load(open("build/logs/m1_cont_conc.jsonl"))
assert seq["status"] == "completed" and conc["status"] == "completed"
def br(r):
    return [i.get("branch") for i in r.get("outputs", {}).get("result", {}).get("items", [])]
assert br(seq) == want == br(conc)
# Concurrent path must report real overlap when maxConcurrency=2
peak = conc.get("peak_concurrent_invocations", 0)
assert peak >= 2, f"expected peak>=2, got {peak}"
print("M1_RESUME_RECIPE_OK")
print(json.dumps({
  "oracle_branches": want,
  "sequential": br(seq),
  "concurrent": br(conc),
  "peak_concurrent": peak,
  "checkpoints": [1, 2, 3, 4, 5],
}, sort_keys=True))
PY

echo "m1_resume_recipe: ok sdk=${SDK_SHA}"
