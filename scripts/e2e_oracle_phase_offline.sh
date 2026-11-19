#!/usr/bin/env bash
# Zero paid calls: oracle phase classification + offline replay of archived A/B.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="/root/.nimble/bin:${PATH:-}"
unset OPENAI_API_KEY || true

nim c -d:release --hints:off --path:src --path:vendor/NimAgentLibrary/src \
  -o:build/nimfactory src/nimfactory_cli.nim

nim c -r --hints:off --path:src --path:vendor/NimAgentLibrary/src \
  tests/mission/test_oracle_phases.nim
nim c -r --hints:off --path:src --path:vendor/NimAgentLibrary/src \
  tests/mission/test_noop_recovery.nim

BIN=./build/nimfactory
FIX=fixtures/e2e_intervention
SHA="$(git rev-parse HEAD)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="docs/qa/e2e_intervention/campaigns/${STAMP}"
mkdir -p "$OUT"
echo "SHA=$SHA OUT=$OUT paid_api_calls=0"

record() {
  local name="$1" ec="$2"
  python3 - "$OUT/${name}.json" "$OUT/${name}.meta.json" "$ec" <<'PY'
import json, sys
path, meta_path, ec = sys.argv[1], sys.argv[2], int(sys.argv[3])
d = json.load(open(path))
inj = net = ver = 0
phases = []
for a in d.get("attempts") or []:
    pk = (a.get("provider") or {}).get("provider_kind")
    if pk == "inject":
        inj += 1
    elif pk in ("openai", "ollama"):
        net += 1
    if (a.get("apply") or {}).get("ok"):
        ver += 1
        v = a.get("verify") or {}
        phases.append({
            "role": a.get("role"),
            "phase": v.get("phase"),
            "kind": v.get("kind"),
            "compile_exit_code": v.get("compile_exit_code"),
            "run_exit_code": v.get("run_exit_code"),
        })
meta = {
    "exit_code": ec,
    "ok": d.get("ok"),
    "verdict": d.get("verdict"),
    "provider_calls": d.get("provider_calls"),
    "injected_turns": inj,
    "network_calls": net,
    "verifications_run": ver,
    "verify_phases": phases,
    "recovery_triggered": d.get("recovery_triggered"),
    "recovery_reason": d.get("recovery_reason"),
}
json.dump(meta, open(meta_path, "w"), indent=2)
print(path, "exit", ec, "verdict", meta["verdict"],
      "inject", inj, "net", net, "verify", ver,
      "recovery", meta["recovery_triggered"])
PY
}

run_cli() {
  local name="$1"; shift
  local wt
  wt="$(mktemp -d /tmp/nf_off_${name}.XXXXXX)"; rmdir "$wt"
  set +e
  "$BIN" "$@" --worktree "$wt" > "$OUT/${name}.json"
  local ec=$?
  set -e
  record "$name" "$ec"
}

run_cli phase_quit1 mission-fix \
  --repo "$FIX/repo_a" --symptom "$FIX/SYMPTOM.md" \
  --oracle "$FIX/oracle_quit1" --route inject \
  --inject "$FIX/inject/ref_fix_a.json" \
  --inject-recovery "$FIX/inject/recovery_cannot.json"

run_cli phase_static_fail mission-fix \
  --repo "$FIX/repo_a" --symptom "$FIX/SYMPTOM.md" \
  --oracle "$FIX/oracle_static_fail" --route inject \
  --inject "$FIX/inject/ref_fix_a.json" \
  --inject-recovery "$FIX/inject/recovery_textutil_a.json"

run_cli offline_a_archived_failure mission-fix \
  --repo "$FIX/repo_a" --symptom "$FIX/SYMPTOM.md" \
  --oracle "$FIX/oracle" --route inject \
  --inject "$FIX/inject/historical_a_20261119T110158Z.json" \
  --inject-recovery "$FIX/inject/historical_a_recovery_20261119T112212Z.json"

run_cli offline_b_archived_success mission-fix \
  --repo "$FIX/repo_b" --symptom "$FIX/SYMPTOM.md" \
  --oracle "$FIX/oracle" --route inject \
  --inject "$FIX/inject/historical_b_20261119T112212Z.json" \
  --inject-recovery "$FIX/inject/recovery_cannot.json"

python3 - "$OUT" "$SHA" <<'PY'
import json, sys
from pathlib import Path
out, sha = Path(sys.argv[1]), sys.argv[2]
trials = {}
for p in sorted(out.glob("*.meta.json")):
    trials[p.name.replace(".meta.json", "")] = json.loads(p.read_text())
summary = {
    "sha": sha,
    "paid_api_calls": 0,
    "network_calls_total": sum(t.get("network_calls", 0) for t in trials.values()),
    "injected_turns_total": sum(t.get("injected_turns", 0) for t in trials.values()),
    "verifications_run_total": sum(t.get("verifications_run", 0) for t in trials.values()),
    "provenance": {
        "historical_campaign_110158Z_summary_sha": "f8a2170",
        "campaign_feature_commit": "d492dda",
        "prior_receipt_sha": "f2d5e38",
        "verify_recovery_campaign": "20261119T112212Z",
        "base_before_this_lot": "6f188ee",
        "this_trial_sha": sha,
        "a_failure_conserved": True,
        "novel_case_prepared": "fixtures/e2e_novel_followcall (API decision not run in this lot)",
    },
    "trials": trials,
}
(out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps({
    "sha": sha, "out": str(out), "paid_api_calls": 0,
    "network_calls_total": summary["network_calls_total"],
    "trials": {k: {"verdict": v.get("verdict"), "net": v.get("network_calls"),
                   "inject": v.get("injected_turns"), "verify": v.get("verifications_run"),
                   "recovery": v.get("recovery_triggered")}
               for k, v in trials.items()},
}, indent=2))
PY

echo "done SHA=$SHA OUT=$OUT"
exit 0
