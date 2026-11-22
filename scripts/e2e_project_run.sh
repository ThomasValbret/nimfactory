#!/usr/bin/env bash
# Qualify project run: offline inject archive, optional API route.
set -euo pipefail
export PATH="/root/.nimble/bin:/root/.choosenim/toolchains/nim-2.4.0/bin:${PATH:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib_load_openai_key.sh
source "$ROOT/scripts/lib_load_openai_key.sh" 2>/dev/null || true

ROUTE="${NF_PROJECT_ROUTE:-inject}"
FIX=fixtures/demo_tasks_cli
INJ="$FIX/inject"
SHA="$(git rev-parse HEAD)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="docs/qa/project_run/${STAMP}_${ROUTE}"
STORE="$OUT/project.sqlite"
ART="$OUT/artifacts"
WT="$OUT/worktrees"
mkdir -p "$ART" "$WT"

NIMCACHE="$ROOT/build/nimcache_cli"
mkdir -p "$ROOT/build" "$NIMCACHE"
if [[ ! -e vendor/NimAgentLibrary ]]; then
  mkdir -p vendor
  ln -sfn /opt/nimFactory/vendor/NimAgentLibrary vendor/NimAgentLibrary
fi
nim c -d:release -d:ssl --hints:off --nimcache:"$NIMCACHE" \
  --path:src --path:vendor/NimAgentLibrary/src \
  -o:build/nimfactory src/nimfactory_cli.nim
BIN=./build/nimfactory

OBJ="Je veux pouvoir exporter mes tâches."
REF="Je veux du CSV sur la sortie standard et je veux garder l'affichage actuel par défaut."

ARGS=(
  project run --store "$STORE" --project-id demo_tasks_cli
  --cwd "$FIX" --artifact-dir "$ART" --worktree "$WT"
  --objective "$OBJ" --refinement "$REF" --route "$ROUTE"
)
if [[ "$ROUTE" == "inject" ]]; then
  ARGS+=(--inject-dir "$INJ")
elif [[ "$ROUTE" == "api" ]]; then
  load_openai_key || { echo "OPENAI_API_KEY missing" >&2; exit 2; }
fi

set +e
if [[ "$ROUTE" == "api" ]] && ! ip -br link show eth0 &>/dev/null && ! ip -br link show tailscale0 &>/dev/null; then
  bash "$ROOT/scripts/with_host_net.sh" -- "$BIN" "${ARGS[@]}" >"$OUT/run.json"
  EC=$?
else
  "$BIN" "${ARGS[@]}" >"$OUT/run.json"
  EC=$?
fi
set -e

"$BIN" project status --store "$STORE" --project-id demo_tasks_cli >"$OUT/status.json" || true

python3 - <<PY
import json, os, subprocess
from pathlib import Path
out = Path("$OUT")
run = json.loads((out/"run.json").read_text())
status = json.loads((out/"status.json").read_text()) if (out/"status.json").exists() else {}
tree = run.get("delivered_tree") or run.get("accepted_tree_ref") or ""
bin_out = {}
if tree and Path(tree, "build/demo_tasks").exists():
    binp = str(Path(tree)/"build"/"demo_tasks")
    for args, key in [([], "no_args"), (["list"], "list"), (["export-csv"], "export_csv")]:
        r = subprocess.run([binp, *args], cwd=tree, capture_output=True, text=True)
        bin_out[key] = {"exit": r.returncode, "out": r.stdout.strip()[:500]}
summary = {
  "stamp": "$STAMP",
  "route": "$ROUTE",
  "code_sha": "$SHA",
  "exit_code": $EC,
  "ok": run.get("ok"),
  "verdict": run.get("verdict"),
  "message": run.get("message"),
  "next_action": run.get("next_action"),
  "interventions": run.get("interventions"),
  "api_calls_this_command": run.get("api_calls_this_command"),
  "provider_calls_this_command": run.get("provider_calls_this_command"),
  "usage_by_role": run.get("usage_by_role"),
  "delivered_tree": tree,
  "delivered_hash": run.get("delivered_hash") or run.get("accepted_tree_hash"),
  "binary_behaviour": bin_out,
  "blocked": run.get("blocked"),
  "status_verdict": status.get("verdict"),
  "user_command": "nimfactory project run --store … --cwd fixtures/demo_tasks_cli --objective 'Je veux pouvoir exporter mes tâches.' --refinement '…CSV…' --route $ROUTE" + (" --inject-dir fixtures/demo_tasks_cli/inject" if "$ROUTE"=="inject" else ""),
}
usd = 0.0
for u in (summary.get("usage_by_role") or {}).values():
    usd += float(u.get("estimated_usd") or 0)
summary["estimated_usd_total"] = usd
(out/"summary.json").write_text(json.dumps(summary, indent=2)+"\n")
print(json.dumps({k: summary[k] for k in ["ok","verdict","api_calls_this_command","estimated_usd_total","binary_behaviour"]}, indent=2))
PY

echo "e2e_project_run: route=$ROUTE out=$OUT exit=$EC sha=$SHA"
exit "$EC"
