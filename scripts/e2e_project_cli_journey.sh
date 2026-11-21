#!/usr/bin/env bash
# First project CLI journey: ask → revise → resume → step → status/inspect/events.
# Uses gpt-4o-mini when OPENAI_API_KEY / .keys present; else inject (model untested).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="/root/.nimble/bin:${PATH:-}"

# shellcheck disable=SC1091
source "$ROOT/scripts/lib_load_openai_key.sh"
# Override: NF_PROJECT_ROUTE=inject|api (default: api if key else inject)
ROUTE="${NF_PROJECT_ROUTE:-}"
MODEL_MODE=""
if [[ -z "$ROUTE" ]]; then
  if load_openai_key; then
    ROUTE=api
  else
    ROUTE=inject
  fi
elif [[ "$ROUTE" == "api" ]]; then
  load_openai_key || true
fi
if [[ "$ROUTE" == "api" ]]; then
  MODEL_MODE="live gpt-4o-mini"
else
  ROUTE=inject
  MODEL_MODE="inject (model decisions untested)"
fi

NIMCACHE="$ROOT/build/nimcache_cli"
mkdir -p "$ROOT/build" "$NIMCACHE"
nim c -d:release -d:ssl --hints:off --nimcache:"$NIMCACHE" \
  --path:src --path:vendor/NimAgentLibrary/src \
  -o:build/nimfactory src/nimfactory_cli.nim

BIN=./build/nimfactory
FIX=fixtures/demo_tasks_cli
SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="docs/qa/project_cli_journey/${STAMP}"
STORE="$OUT/project.sqlite"
ART="$OUT/artifacts"
WT="$OUT/worktree_step"
mkdir -p "$ART"
# fresh empty worktree path (must not exist / be empty for allocateWorktree)
rm -rf "$WT"
mkdir -p "$WT"
rmdir "$WT"

PID=demo_tasks_cli
OBJ="Je veux pouvoir exporter mes tâches."
REF="Je veux du CSV sur la sortie standard et je veux garder l'affichage actuel par défaut."

echo "SHA=$SHA ROUTE=$ROUTE OUT=$OUT"

run_proj() {
  local sub="$1"; shift
  local outf="$1"; shift
  set +e
  "$BIN" project "$sub" --store "$STORE" --project-id "$PID" \
    --cwd "$FIX" --artifact-dir "$ART" --route "$ROUTE" "$@" > "$outf"
  local ec=$?
  set -e
  echo "project_$sub exit=$ec file=$outf"
  return "$ec"
}

# --- ask ---
ASK_INJECT=()
if [[ "$ROUTE" == "inject" ]]; then
  ASK_INJECT=(--inject "$FIX/inject/plan_v1.json")
fi
run_proj ask "$OUT/ask.json" --objective "$OBJ" "${ASK_INJECT[@]}"
python3 - "$OUT/ask.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get("ok") is True, d
assert d.get("current_plan_version")==1, d
assert d.get("verdict")=="plan_ready", d
print("ask_ok plan_v1 steps=", len(d.get("steps") or []))
PY

# --- revise ---
REV_INJECT=()
if [[ "$ROUTE" == "inject" ]]; then
  REV_INJECT=(--inject "$FIX/inject/plan_v2.json")
fi
run_proj revise "$OUT/revise.json" --refinement "$REF" "${REV_INJECT[@]}"
python3 - "$OUT/revise.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get("ok") is True, d
assert d.get("current_plan_version")==2, d
assert any("CSV" in r or "csv" in r.lower() for r in (d.get("refinements") or [])), d
print("revise_ok plan_v2")
PY

# --- simulate interrupt: process ends; state stays in SQLite ---
cp "$STORE" "$OUT/store_after_revise.sqlite"

# --- resume (0 planner/reviser billable calls) ---
run_proj resume "$OUT/resume.json"
python3 - "$OUT/resume.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get("ok") is True, d
assert d.get("verdict")=="resumed", d
r=d.get("resume") or {}
assert r.get("rehydrated") is True
assert r.get("billable_plan_calls")==0
assert r.get("planner_calls_this_command")==0
assert r.get("reviser_calls_this_command")==0
assert (r.get("pending_step") or "") != ""
assert d.get("current_plan_version")==2
print("resume_ok pending=", r.get("pending_step"))
PY

# usage snapshot before step (plan/revise tokens only)
python3 - "$OUT/resume.json" "$OUT/usage_before_step.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
json.dump(d.get("usage_by_role") or {}, open(sys.argv[2],"w"), indent=2)
print("usage_before_step written")
PY

# --- step (implementer) ---
STEP_INJECT=()
if [[ "$ROUTE" == "inject" ]]; then
  STEP_INJECT=(--inject "$FIX/inject/step_export.json")
fi
run_proj step "$OUT/step.json" --worktree "$WT" "${STEP_INJECT[@]}"
python3 - "$OUT/step.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get("ok") is True, d
assert d.get("verdict")=="pass", d
v=d.get("verify") or {}
assert v.get("list_ok") and v.get("csv_ok") and v.get("quote_ok"), v
print("step_ok", v.get("message"))
print("csv_out=", repr(v.get("csv_out")))
PY

# --- status ---
run_proj status "$OUT/status.json"
python3 - "$OUT/status.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get("ok") is True
steps=d.get("steps") or []
assert all(s.get("status")=="done" for s in steps), steps
print("status_ok all done; usage=", d.get("usage_by_role"))
PY

# --- inspect / events via existing CLI (run_id project:…) ---
RUN_ID="project:${PID}"
"$BIN" inspect --store "$STORE" --run-id "$RUN_ID" > "$OUT/inspect.json"
"$BIN" events --store "$STORE" --run-id "$RUN_ID" > "$OUT/events.jsonl"

python3 - "$OUT" "$ROUTE" "$MODEL_MODE" "$SHA" <<'PY'
import json,sys
from pathlib import Path
out, route, mode, sha = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
status=json.loads((out/"status.json").read_text())
resume=json.loads((out/"resume.json").read_text())
ask=json.loads((out/"ask.json").read_text())
revise=json.loads((out/"revise.json").read_text())
step=json.loads((out/"step.json").read_text())
usage=status.get("usage_by_role") or {}
# After resume, plan version still 2; step must not bump planner calls beyond ask+revise
def calls(role):
    return int((usage.get(role) or {}).get("calls") or 0)
summary={
  "sha": sha,
  "route": route,
  "model_mode": mode,
  "plan_versions": status.get("current_plan_version"),
  "resume_billable_plan_calls": (resume.get("resume") or {}).get("billable_plan_calls"),
  "usage_by_role": usage,
  "planner_calls": calls("planner"),
  "reviser_calls": calls("reviser"),
  "implementer_calls": calls("implementer"),
  "step_verdict": step.get("verdict"),
  "verify": step.get("verify"),
  "artifacts": {
    "plan_v1": str(out/"artifacts"/"plan_v1.json"),
    "plan_v2": str(out/"artifacts"/"plan_v2.json"),
    "mandate": str(out/"artifacts"/"mandate.json"),
  },
  "untested": []
}
if route=="inject":
    summary["untested"]=["planner","reviser","implementer"]
(out/"summary.json").write_text(json.dumps(summary, indent=2)+"\n")
print(json.dumps(summary, indent=2))
# Sanity: inject ⇒ zero estimated usd; api ⇒ planner/reviser/implementer calls >=1 each when usage reported
if route=="inject":
    assert calls("planner")==0 and calls("reviser")==0
    # implementer inject also records zero billable via recordUsage skip
PY

# Keep a stable "latest" pointer for the recipe (copy summary + key outputs)
LATEST=docs/qa/project_cli_journey/latest
rm -rf "$LATEST"
mkdir -p "$LATEST"
cp "$OUT/summary.json" "$OUT/ask.json" "$OUT/revise.json" "$OUT/resume.json" \
   "$OUT/step.json" "$OUT/status.json" "$LATEST/" 2>/dev/null || true
cp -r "$ART" "$LATEST/artifacts" 2>/dev/null || true

echo "e2e_project_cli_journey: ok ROUTE=$ROUTE OUT=$OUT"
