#!/usr/bin/env bash
# Project CLI journey: ask → revise → kill/resume → chained steps → status.
# Uses gpt-4o-mini when OPENAI_API_KEY / .keys present; else inject.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="/root/.nimble/bin:${PATH:-}"

# shellcheck disable=SC1091
source "$ROOT/scripts/lib_load_openai_key.sh"
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
WT1="$OUT/worktree_step1"
WT2="$OUT/worktree_step2"
WT_BAD="$OUT/worktree_bad"
mkdir -p "$ART"
rm -rf "$WT1" "$WT2" "$WT_BAD"
mkdir -p "$WT1" "$WT2" "$WT_BAD"
rmdir "$WT1" "$WT2" "$WT_BAD"

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

# --- integrity: {} must fail planning (no fabricated steps/mandates) ---
EMPTY_STORE="$OUT/empty_plan.sqlite"
set +e
"$BIN" project ask --store "$EMPTY_STORE" --project-id empty_probe \
  --cwd "$FIX" --objective "$OBJ" --route inject \
  --inject "$FIX/inject/empty_plan.json" > "$OUT/empty_plan.json"
EMPTY_EC=$?
set -e
python3 - "$OUT/empty_plan.json" "$EMPTY_EC" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
ec=int(sys.argv[2])
assert d.get("ok") is False, d
assert d.get("verdict")=="plan_failed", d
assert "empty_plan" in (d.get("message") or ""), d
assert ec != 0
print("empty_plan_ok verdict=plan_failed")
PY

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
assert len(d.get("steps") or []) >= 1, d
print("ask_ok plan_v1 steps=", len(d.get("steps") or []))
PY

# --- revise (inject: two chained steps) ---
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
steps=d.get("steps") or []
assert len(steps) >= 1, steps
print("revise_ok plan_v2 steps=", [(s.get("id"), s.get("depends_on")) for s in steps])
PY

# Persist plan step count for later multi-step loop
PLAN_STEPS=$(python3 -c "import json; print(len(json.load(open('$OUT/revise.json')).get('steps') or []))")

# --- concurrent step: live owner → resume=active; second step=already_running ---
cp "$STORE" "$OUT/store_before_kill.sqlite"
KILL_STORE="$OUT/kill.sqlite"
cp "$STORE" "$KILL_STORE"
KILL_ART="$OUT/kill_artifacts"
KILL_WT="$OUT/kill_worktree"
KILL_WT2="$OUT/kill_worktree2"
mkdir -p "$KILL_ART"
rm -rf "$KILL_WT" "$KILL_WT2"
mkdir -p "$KILL_WT" "$KILL_WT2" && rmdir "$KILL_WT" "$KILL_WT2"

if [[ "$ROUTE" == "inject" ]]; then
  KILL_INJECT=(--inject "$FIX/inject/step_helpers.json")
else
  KILL_INJECT=()
fi

export NF_PROJECT_STEP_PAUSE_MS=12000
set +e
"$BIN" project step --store "$KILL_STORE" --project-id "$PID" \
  --cwd "$FIX" --artifact-dir "$KILL_ART" --route "$ROUTE" \
  --worktree "$KILL_WT" "${KILL_INJECT[@]}" > "$OUT/step_alive.json" &
KILL_PID=$!
set -e

python3 - "$KILL_STORE" "$PID" <<'PY'
import json, sqlite3, sys, time
store, pid = sys.argv[1], sys.argv[2]
rid = "project:" + pid
deadline = time.time() + 15
while time.time() < deadline:
    try:
        con = sqlite3.connect(store)
        row = con.execute("select state_json from nf_runs where run_id=?", (rid,)).fetchone()
        con.close()
        if row:
            doc = json.loads(row[0])
            for s in doc.get("steps") or []:
                if s.get("status") == "running":
                    pa = (s.get("result") or {}).get("provider_attempt") or {}
                    print("observed_running", s.get("id"), "owner_pid=", pa.get("owner_pid"))
                    raise SystemExit(0)
    except SystemExit:
        raise
    except Exception:
        pass
    time.sleep(0.15)
print("timeout_waiting_running")
raise SystemExit(1)
PY

# While first process is alive: resume must say active
set +e
"$BIN" project resume --store "$KILL_STORE" --project-id "$PID" \
  --cwd "$FIX" --route "$ROUTE" > "$OUT/resume_while_alive.json"
set -e
python3 - "$OUT/resume_while_alive.json" "$KILL_PID" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
alive_pid=int(sys.argv[2])
assert d.get("ok") is True, d
assert d.get("verdict")=="active", d
r=d.get("resume") or {}
assert r.get("action")=="wait", r
assert r.get("step_state")=="running", r
assert (r.get("active_step") or "") != "", r
assert int(r.get("owner_pid") or 0) == alive_pid, (r, alive_pid)
assert r.get("billable_plan_calls")==0
print("concurrent_resume_active ok owner_pid=", r.get("owner_pid"))
PY

# Second step on same store must not call the provider
set +e
"$BIN" project step --store "$KILL_STORE" --project-id "$PID" \
  --cwd "$FIX" --artifact-dir "$KILL_ART" --route "$ROUTE" \
  --worktree "$KILL_WT2" "${KILL_INJECT[@]}" > "$OUT/step_concurrent.json"
CONC_EC=$?
set -e
python3 - "$OUT/step_concurrent.json" "$CONC_EC" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
ec=int(sys.argv[2])
assert d.get("ok") is False, d
assert d.get("verdict")=="already_running", d
assert d.get("provider_calls_this_command")==0, d
assert "provider" not in d or d.get("provider") is None or d.get("provider",{}).get("raw_text") in (None,""), d
assert ec != 0
print("concurrent_step_refused ok (no provider call)")
PY

kill -9 "$KILL_PID" 2>/dev/null || true
wait "$KILL_PID" 2>/dev/null || true
unset NF_PROJECT_STEP_PAUSE_MS

# After kill: resume → interrupted + unknown + retry_step
set +e
"$BIN" project resume --store "$KILL_STORE" --project-id "$PID" \
  --cwd "$FIX" --route "$ROUTE" > "$OUT/resume_after_kill.json"
set -e
python3 - "$OUT/resume_after_kill.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get("ok") is True, d
assert d.get("verdict")=="interrupted", d
r=d.get("resume") or {}
assert r.get("rehydrated") is True
assert r.get("billable_plan_calls")==0
assert r.get("action")=="retry_step", r
assert (r.get("interrupted_step") or "") != "", r
assert r.get("provider_attempt_unknown") is True, r
assert "unknown" in (r.get("action_note") or "").lower() or "rebill" in (r.get("action_note") or "").lower(), r
print("kill_resume_ok interrupted=", r.get("interrupted_step"), "action=", r.get("action"))
PY

# --- resume on main store (after revise, before any step) ---
run_proj resume "$OUT/resume.json"
python3 - "$OUT/resume.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get("ok") is True, d
assert d.get("verdict")=="resumed", d
r=d.get("resume") or {}
assert r.get("rehydrated") is True
assert r.get("billable_plan_calls")==0
assert r.get("action")=="run_step", r
assert (r.get("pending_step") or "") != ""
assert d.get("current_plan_version")==2
print("resume_ok pending=", r.get("pending_step"), "action=", r.get("action"))
PY

python3 - "$OUT/resume.json" "$OUT/usage_before_step.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
json.dump(d.get("usage_by_role") or {}, open(sys.argv[2],"w"), indent=2)
print("usage_before_step written")
PY

# --- steps: follow plan (inject: helpers then export on accepted tree) ---
STEP_IDX=0
ACCEPTED_HASH=""
while true; do
  PENDING=$(python3 - "$STORE" "$PID" <<'PY'
import json,sqlite3,sys
con=sqlite3.connect(sys.argv[1])
row=con.execute("select state_json from nf_runs where run_id=?", ("project:"+sys.argv[2],)).fetchone()
con.close()
doc=json.loads(row[0])
for s in doc.get("steps") or []:
    if s.get("status") in ("pending","interrupted","running"):
        print(s.get("id"))
        break
PY
)
  if [[ -z "$PENDING" ]]; then
    break
  fi
  STEP_IDX=$((STEP_IDX + 1))
  WT="$OUT/worktree_step${STEP_IDX}"
  rm -rf "$WT"
  mkdir -p "$WT" && rmdir "$WT"
  STEP_INJECT=()
  if [[ "$ROUTE" == "inject" ]]; then
    if [[ "$PENDING" == "add_csv_helpers" ]]; then
      STEP_INJECT=(--inject "$FIX/inject/step_helpers.json")
    elif [[ "$PENDING" == "wire_export_csv" ]] || [[ "$PENDING" == "implement_export" ]]; then
      STEP_INJECT=(--inject "$FIX/inject/step_export.json")
    else
      echo "unknown pending step for inject: $PENDING" >&2
      exit 1
    fi
  fi
  run_proj step "$OUT/step${STEP_IDX}.json" --worktree "$WT" "${STEP_INJECT[@]}"
  python3 - "$OUT/step${STEP_IDX}.json" "$PENDING" "$STEP_IDX" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
pending, idx = sys.argv[2], int(sys.argv[3])
assert d.get("ok") is True, d
assert d.get("verdict")=="pass", d
assert d.get("accepted_tree_ref"), d
assert d.get("accepted_tree_hash"), d
assert d.get("readable_diff") or d.get("last_diff"), d
src=d.get("source_tree") or ""
print(f"step{idx}_ok id={pending} source_tree={src}")
print("accepted_tree_ref=", d.get("accepted_tree_ref"))
print("accepted_tree_hash=", d.get("accepted_tree_hash"))
if idx >= 2:
    # Step 2+ must chain from prior accepted tree, not pristine cwd alone.
    assert "trees/" in src.replace("\\","/") or src.endswith("add_csv_helpers") or "add_csv_helpers" in src, (src, d)
v=d.get("verify") or {}
# Behavioural oracle only — API solutions may invent their own function names.
if v.get("kind") == "csv_journey":
    assert v.get("list_ok") and v.get("csv_ok") and v.get("quote_ok"), v
elif idx >= 2 or pending in ("wire_export_csv", "implement_export"):
    # Final wiring step under inject plan_v2
    if v.get("require_csv") is True or (v.get("details") or {}).get("require_csv") is True:
        assert v.get("list_ok") and v.get("csv_ok") and v.get("quote_ok"), v
print("verify=", v.get("message"), "kind=", v.get("kind"))
PY
  ACCEPTED_HASH=$(python3 -c "import json; print(json.load(open('$OUT/step${STEP_IDX}.json')).get('accepted_tree_hash') or '')")
  # Safety: don't loop forever
  if [[ "$STEP_IDX" -ge 8 ]]; then
    echo "too many steps" >&2
    exit 1
  fi
done

# For API route with a single-step plan, still ok; inject expects 2.
if [[ "$ROUTE" == "inject" ]]; then
  python3 - "$STEP_IDX" <<'PY'
import sys
assert int(sys.argv[1]) == 2, "inject plan_v2 expects exactly 2 steps, got "+sys.argv[1]
print("two_step_chain_ok")
PY
fi

# --- separate binary checks on last accepted tree ---
LAST_TREE=$(python3 -c "import json; print(json.load(open('$OUT/step${STEP_IDX}.json'))['accepted_tree_ref'])")
python3 - "$LAST_TREE" "$FIX" <<'PY'
import subprocess, json, sys, pathlib
tree = pathlib.Path(sys.argv[1]).resolve()
fix = pathlib.Path(sys.argv[2]).resolve()
bin_path = tree / "build" / "demo_tasks"
subprocess.check_call([
  "nim","c","-d:release","--hints:off","--warnings:off",
  f"--nimcache:{tree/'nimcache'}",
  f"--path:{tree/'src'}",
  f"-o:{bin_path}",
  str(tree/"src"/"demo_tasks.nim"),
], cwd=str(tree))
data=json.loads((fix/"data"/"tasks.json").read_text())
expect_list="\n".join(f'{t["id"]}. {t["title"]}' for t in data)

def run(args):
    r=subprocess.run([str(bin_path), *args], cwd=str(tree), capture_output=True, text=True)
    return r.returncode, r.stdout.strip()

ec0, out0 = run([])
ec1, out1 = run(["list"])
ec2, out2 = run(["export-csv"])
ec3, out3 = run(["list", "--format=csv"])
assert ec0==0 and out0==expect_list, (ec0, out0, expect_list)
assert ec1==0 and out1==expect_list, (ec1, out1)
# Recipe admits export-csv and/or list --format=csv
csv_ok = (ec2==0 and out2.startswith("id,title") and '"Appeler Alice, Bob"' in out2) or \
         (ec3==0 and out3.startswith("id,title") and '"Appeler Alice, Bob"' in out3)
assert csv_ok, (ec2, out2, ec3, out3)
print("binary_checks_ok no-args/list/export-forms")
PY

# --- negative control via project step (mastered fixture, alternate names) ---
NEG=fixtures/demo_tasks_cli_neg
NEG_STORE="$OUT/neg.sqlite"
NEG_ART="$OUT/neg_artifacts"
NEG_WT="$OUT/neg_worktree"
mkdir -p "$NEG_ART"
rm -rf "$NEG_WT"
mkdir -p "$NEG_WT" && rmdir "$NEG_WT"
set +e
"$BIN" project ask --store "$NEG_STORE" --project-id neg_list \
  --cwd "$NEG" --artifact-dir "$NEG_ART" --route inject \
  --inject "$NEG/inject/plan_neg.json" \
  --objective "contrôle négatif list_mismatch" > "$OUT/neg_ask.json"
"$BIN" project step --store "$NEG_STORE" --project-id neg_list \
  --cwd "$NEG" --artifact-dir "$NEG_ART" --route inject \
  --inject "$NEG/inject/bad_list.json" --worktree "$NEG_WT" > "$OUT/neg_step.json"
NEG_EC=$?
set -e
python3 - "$OUT/neg_step.json" "$NEG_EC" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
ec=int(sys.argv[2])
assert d.get("ok") is False, d
assert d.get("verdict")=="verify_failed", d
v=d.get("verify") or {}
assert v.get("list_ok") is False, v
assert "list_mismatch" in (v.get("message") or d.get("message") or ""), (v, d)
assert ec != 0
print("neg_project_step_ok verdict=verify_failed list_mismatch")
PY

# --- status ---
run_proj status "$OUT/status.json"
python3 - "$OUT/status.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get("ok") is True
steps=d.get("steps") or []
assert all(s.get("status")=="done" for s in steps), steps
assert d.get("accepted_tree_ref"), d
print("status_ok all done; accepted=", d.get("accepted_tree_ref"))
print("usage=", d.get("usage_by_role"))
PY

RUN_ID="project:${PID}"
"$BIN" inspect --store "$STORE" --run-id "$RUN_ID" > "$OUT/inspect.json"
"$BIN" events --store "$STORE" --run-id "$RUN_ID" > "$OUT/events.jsonl"

python3 - "$OUT" "$ROUTE" "$MODEL_MODE" "$SHA" "$STEP_IDX" <<'PY'
import json,sys
from pathlib import Path
out, route, mode, sha, nsteps = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
status=json.loads((out/"status.json").read_text())
resume=json.loads((out/"resume.json").read_text())
ask=json.loads((out/"ask.json").read_text())
revise=json.loads((out/"revise.json").read_text())
kill_resume=json.loads((out/"resume_after_kill.json").read_text())
alive_resume=json.loads((out/"resume_while_alive.json").read_text())
conc=json.loads((out/"step_concurrent.json").read_text())
neg=json.loads((out/"neg_step.json").read_text())
empty=json.loads((out/"empty_plan.json").read_text())
last=json.loads((out/f"step{nsteps}.json").read_text())
usage=status.get("usage_by_role") or {}
def calls(role):
    return int((usage.get(role) or {}).get("calls") or 0)
def role_row(name):
    u=usage.get(name) or {}
    return {
      "calls": int(u.get("calls") or 0),
      "prompt_tokens": int(u.get("prompt_tokens") or 0),
      "completion_tokens": int(u.get("completion_tokens") or 0),
      "estimated_usd": float(u.get("estimated_usd") or 0),
      "model": u.get("model") or "",
    }
summary={
  "sha": sha,
  "route": route,
  "model_mode": mode,
  "plan_versions": status.get("current_plan_version"),
  "plan_steps": len(status.get("steps") or []),
  "steps_executed": nsteps,
  "resume_billable_plan_calls": (resume.get("resume") or {}).get("billable_plan_calls"),
  "concurrent": {
    "resume_while_alive": alive_resume.get("resume"),
    "resume_verdict": alive_resume.get("verdict"),
    "second_step_verdict": conc.get("verdict"),
    "second_step_provider_calls": conc.get("provider_calls_this_command"),
  },
  "kill_resume": kill_resume.get("resume"),
  "neg_step": {"verdict": neg.get("verdict"), "verify": neg.get("verify")},
  "empty_plan_verdict": empty.get("verdict"),
  "usage_by_role": usage,
  "roles": {
    "planner": role_row("planner"),
    "reviser": role_row("reviser"),
    "implementer": role_row("implementer"),
  },
  "planner_calls": calls("planner"),
  "reviser_calls": calls("reviser"),
  "implementer_calls": calls("implementer"),
  "accepted_tree_ref": status.get("accepted_tree_ref"),
  "accepted_tree_hash": status.get("accepted_tree_hash"),
  "last_step_verdict": last.get("verdict"),
  "verify": last.get("verify"),
  "source_tree_last": last.get("source_tree"),
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
if route=="inject":
    assert calls("planner")==0 and calls("reviser")==0
PY

LATEST=docs/qa/project_cli_journey/latest
rm -rf "$LATEST"
mkdir -p "$LATEST"
cp "$OUT/summary.json" "$OUT/ask.json" "$OUT/revise.json" "$OUT/resume.json" \
   "$OUT/resume_while_alive.json" "$OUT/step_concurrent.json" \
   "$OUT/resume_after_kill.json" "$OUT/empty_plan.json" "$OUT/status.json" \
   "$OUT/neg_ask.json" "$OUT/neg_step.json" "$LATEST/" 2>/dev/null || true
for i in $(seq 1 "$STEP_IDX"); do
  cp "$OUT/step${i}.json" "$LATEST/" 2>/dev/null || true
done
cp -r "$ART" "$LATEST/artifacts" 2>/dev/null || true

echo "e2e_project_cli_journey: ok ROUTE=$ROUTE OUT=$OUT STEPS=$STEP_IDX"
