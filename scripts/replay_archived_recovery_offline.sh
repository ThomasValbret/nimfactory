#!/usr/bin/env bash
# Offline CLI replay of both archived recovery cases (152200Z / 152308Z raw).
# No OpenAI calls. Verifies diagnosis + revise_plan persistence / helpers path.
set -euo pipefail
export PATH="/root/.nimble/bin:/root/.choosenim/toolchains/nim-2.4.0/bin:${PATH:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

HIST="${HIST_CAMPAIGN:-docs/qa/project_cli_journey/20261122T150522Z}"
RAW_A="docs/qa/project_cli_journey/recovery_replay_20261122T152200Z/historical_first_raw.txt"
RAW_B="docs/qa/project_cli_journey/recovery_replay_20261122T152308Z/historical_first_raw.txt"
FIX=fixtures/demo_tasks_cli
INJ="$FIX/inject"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="docs/qa/project_cli_journey/offline_archive_replay_${STAMP}"
SHA="$(git rev-parse HEAD)"
mkdir -p "$OUT"

NIMCACHE="$ROOT/build/nimcache_cli"
mkdir -p "$ROOT/build" "$NIMCACHE"
nim c -d:release -d:ssl --hints:off --nimcache:"$NIMCACHE" \
  --path:src --path:vendor/NimAgentLibrary/src \
  -o:build/nimfactory src/nimfactory_cli.nim
BIN=./build/nimfactory

seed() {
  local store="$1" art="$2" pid="$3"
  mkdir -p "$art"
  "$BIN" project ask --store "$store" --project-id "$pid" --cwd "$FIX" \
    --artifact-dir "$art" --route inject --inject "$HIST/artifacts/plan_v1.json" \
    --objective "Je veux pouvoir exporter mes tâches." >"$art/ask.json"
  "$BIN" project revise --store "$store" --project-id "$pid" --cwd "$FIX" \
    --artifact-dir "$art" --route inject --inject "$HIST/artifacts/plan_v2.json" \
    --refinement "Je veux du CSV sur la sortie standard et je veux garder l'affichage actuel par défaut." \
    >"$art/revise.json"
}

# --- Case A (152200Z raw): recovery → revise_plan; persist; status/resume/step; revise; step ---
A_STORE="$OUT/case_a.sqlite"
A_ART="$OUT/case_a"
seed "$A_STORE" "$A_ART" case_a
"$BIN" project step --store "$A_STORE" --project-id case_a --cwd "$FIX" \
  --artifact-dir "$A_ART" --route inject \
  --replay-first "$RAW_A" \
  --historical-provenance "$RAW_A" \
  --inject-recovery "$INJ/step_recovery_revise_plan.json" \
  --worktree "$A_ART/wt" >"$OUT/case_a_step.json" || true
"$BIN" project status --store "$A_STORE" --project-id case_a >"$OUT/case_a_status.json"
"$BIN" project resume --store "$A_STORE" --project-id case_a >"$OUT/case_a_resume.json"
"$BIN" project step --store "$A_STORE" --project-id case_a --cwd "$FIX" \
  --artifact-dir "$A_ART" --route inject --inject "$INJ/step_helpers.json" \
  >"$OUT/case_a_step_blocked.json" || true
"$BIN" project revise --store "$A_STORE" --project-id case_a --cwd "$FIX" \
  --artifact-dir "$A_ART" --route inject --inject "$INJ/plan_v3_after_revise.json" \
  >"$OUT/case_a_revise.json"
"$BIN" project step --store "$A_STORE" --project-id case_a --cwd "$FIX" \
  --artifact-dir "$A_ART" --route inject --inject "$INJ/step_helpers.json" \
  --worktree "$A_ART/wt_after" >"$OUT/case_a_step_after.json"

# --- Case B (152308Z raw): recovery → helpers (compilable step) ---
B_STORE="$OUT/case_b.sqlite"
B_ART="$OUT/case_b"
seed "$B_STORE" "$B_ART" case_b
"$BIN" project step --store "$B_STORE" --project-id case_b --cwd "$FIX" \
  --artifact-dir "$B_ART" --route inject \
  --replay-first "$RAW_B" \
  --historical-provenance "$RAW_B" \
  --inject-recovery "$INJ/step_helpers.json" \
  --worktree "$B_ART/wt" >"$OUT/case_b_step.json"

python3 - <<PY
import json
from pathlib import Path
out = Path("$OUT")
a_step = json.loads((out/"case_a_step.json").read_text())
a_status = json.loads((out/"case_a_status.json").read_text())
a_resume = json.loads((out/"case_a_resume.json").read_text())
a_blocked = json.loads((out/"case_a_step_blocked.json").read_text())
a_rev = json.loads((out/"case_a_revise.json").read_text())
a_after = json.loads((out/"case_a_step_after.json").read_text())
b_step = json.loads((out/"case_b_step.json").read_text())
assert a_step.get("verdict") == "revise_plan_needed", a_step.get("verdict")
assert a_step.get("recovery_attempted") is True
assert a_status.get("revise_plan_pending") is True
assert a_resume.get("resume", {}).get("action") == "revise"
assert a_blocked.get("provider_calls_this_command", -1) == 0
assert a_blocked.get("verdict") == "revise_plan_needed"
assert a_rev.get("ok") is True
assert a_rev.get("revise_plan_pending") is False
assert a_after.get("ok") is True and a_after.get("verdict") == "pass"
assert b_step.get("ok") is True and b_step.get("verdict") == "pass", b_step.get("verdict")
assert b_step.get("via_recovery") is True
assert b_step.get("recovery_reason") == "multi_proposal"
summary = {
  "stamp": "$STAMP",
  "code_sha": "$SHA",
  "case_a": {
    "archive": "recovery_replay_20261122T152200Z",
    "verdict": a_step.get("verdict"),
    "next_action": a_step.get("next_action"),
    "status_verdict": a_status.get("verdict"),
    "resume_action": a_resume.get("resume", {}).get("action"),
    "blocked_provider_calls": a_blocked.get("provider_calls_this_command"),
    "after_revise_step": a_after.get("verdict"),
  },
  "case_b": {
    "archive": "recovery_replay_20261122T152308Z",
    "verdict": b_step.get("verdict"),
    "via_recovery": b_step.get("via_recovery"),
    "recovery_reason": b_step.get("recovery_reason"),
    "verify": b_step.get("verify"),
  },
  "api_calls": 0,
}
(out/"summary.json").write_text(json.dumps(summary, indent=2)+"\n")
print("offline archive replay ok", summary)
PY

echo "replay_archived_recovery_offline: $OUT"
