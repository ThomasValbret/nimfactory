#!/usr/bin/env bash
# Replay campaign 20261122T150522Z step1: historical first raw + one recovery API call.
# Ask/revise are inject-only (no rebill). Archives first recovery result either way.
set -euo pipefail
export PATH="/root/.nimble/bin:/root/.choosenim/toolchains/nim-2.4.0/bin:${PATH:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib_load_openai_key.sh
source "$ROOT/scripts/lib_load_openai_key.sh"
load_openai_key || { echo "OPENAI_API_KEY missing" >&2; exit 2; }

HIST="${HIST_CAMPAIGN:-docs/qa/project_cli_journey/20261122T150522Z}"
FIX=fixtures/demo_tasks_cli
SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="docs/qa/project_cli_journey/recovery_replay_${STAMP}"
STORE="$OUT/project.sqlite"
ART="$OUT/artifacts"
WT="$OUT/worktree_step1"
mkdir -p "$ART" "$OUT"
rm -rf "$WT"

NIMCACHE="$ROOT/build/nimcache_cli"
mkdir -p "$ROOT/build" "$NIMCACHE"
nim c -d:release -d:ssl --hints:off --nimcache:"$NIMCACHE" \
  --path:src --path:vendor/NimAgentLibrary/src \
  -o:build/nimfactory src/nimfactory_cli.nim
BIN=./build/nimfactory

# Extract historical first raw (verbatim) and plan provenance.
python3 - <<PY
import json, pathlib
hist = pathlib.Path("$HIST")
out = pathlib.Path("$OUT")
step = json.loads((hist / "step1.json").read_text())
raw = step["provider"]["raw_text"]
(out / "historical_first_raw.txt").write_text(raw)
prov = {
  "source_campaign": "$HIST",
  "source_step_artifact": str(hist / "step1.json"),
  "source_plan_v2": str(hist / "artifacts" / "plan_v2.json"),
  "source_ask": str(hist / "ask.json"),
  "source_revise": str(hist / "revise.json"),
  "tip_at_campaign": "30a410f",
  "replay_sha": "$SHA",
  "note": "First implementer raw reused; ask/revise not re-billed; one recovery API call only."
}
(out / "historical_provenance.json").write_text(json.dumps(prov, indent=2) + "\n")
print("historical_first_raw_bytes", len(raw))
print("historical_targets_hint", raw.count('"target_file"'))
PY

run_proj() {
  local sub="$1"; shift
  local outf="$1"; shift
  set +e
  "$BIN" project "$sub" --store "$STORE" --project-id demo_tasks_cli \
    --cwd "$FIX" --artifact-dir "$ART" "$@" >"$outf"
  local ec=$?
  set -e
  echo "project_$sub exit=$ec file=$outf"
  return $ec
}

# Seed plan v2 from historical artifacts (inject — zero API).
run_proj ask "$OUT/ask.json" \
  --route inject --inject "$HIST/artifacts/plan_v1.json" \
  --objective "Je veux pouvoir exporter mes tâches."

run_proj revise "$OUT/revise.json" \
  --route inject --inject "$HIST/artifacts/plan_v2.json" \
  --refinement "Je veux du CSV sur la sortie standard et je veux garder l'affichage actuel par défaut."

# Single recovery API call via host/Tailscale netns when needed.
STEP_ARGS=(
  step "$OUT/step1_recovery.json"
  --route api
  --worktree "$WT"
  --replay-first "$OUT/historical_first_raw.txt"
  --historical-provenance "$HIST/step1.json#provider.raw_text + $HIST/artifacts/plan_v2.json"
)

set +e
if ip -br link show eth0 &>/dev/null || ip -br link show tailscale0 &>/dev/null; then
  run_proj "${STEP_ARGS[@]}"
  SEC=$?
else
  bash "$ROOT/scripts/with_host_net.sh" -- "$BIN" project step \
    --store "$STORE" --project-id demo_tasks_cli \
    --cwd "$FIX" --artifact-dir "$ART" \
    --route api --worktree "$WT" \
    --replay-first "$OUT/historical_first_raw.txt" \
    --historical-provenance "$HIST/step1.json#provider.raw_text + $HIST/artifacts/plan_v2.json" \
    >"$OUT/step1_recovery.json"
  SEC=$?
  echo "project_step exit=$SEC file=$OUT/step1_recovery.json (via with_host_net)"
fi
# Always archive summary even when step fails (set +e).
python3 - <<PY
import json, pathlib, hashlib
out = pathlib.Path("$OUT")
step = json.loads((out / "step1_recovery.json").read_text())
summary = {
  "stamp": "$STAMP",
  "sha": "$SHA",
  "historical_campaign": "$HIST",
  "ok": step.get("ok"),
  "verdict": step.get("verdict"),
  "message": step.get("message"),
  "refuse_code": step.get("refuse_code"),
  "via_recovery": step.get("via_recovery"),
  "recovery_triggered": step.get("recovery_triggered"),
  "recovery_attempted": step.get("recovery_attempted"),
  "recovery_reason": step.get("recovery_reason"),
  "api_calls_this_command": step.get("api_calls_this_command"),
  "provider_calls_this_command": step.get("provider_calls_this_command"),
  "apply": step.get("apply"),
  "verify": step.get("verify"),
  "readable_diff": step.get("readable_diff"),
  "usage_by_role": step.get("usage_by_role"),
  "recovery_provider": step.get("recovery_provider"),
  "historical_provenance": step.get("historical_provenance"),
  "exit_code": $SEC,
}
(out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
# Convenience extracts
rp = step.get("recovery_provider") or {}
(out / "recovery_raw.txt").write_text(rp.get("raw_text") or "")
(out / "readable_diff.txt").write_text((step.get("readable_diff") or "") + "\n")
print("verdict", summary["verdict"])
print("api_calls", summary["api_calls_this_command"])
print("recovery_reason", summary["recovery_reason"])
print("ok", summary["ok"])
usd = 0.0
for role, u in (summary.get("usage_by_role") or {}).items():
  usd += float(u.get("estimated_usd") or 0)
  print("usage", role, u)
print("estimated_usd_total_new", usd)
PY

echo "replay_project_step_recovery: archived $OUT exit=$SEC"
exit "$SEC"
