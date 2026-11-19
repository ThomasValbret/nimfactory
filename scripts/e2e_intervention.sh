#!/usr/bin/env bash
# Intervention-choice campaign (API route). Continues after A failure.
# Each run writes under docs/qa/e2e_intervention/campaigns/<stamp>/ to preserve priors.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="/root/.nimble/bin:${PATH:-}"

nim c -d:release -d:ssl --hints:off --path:src --path:vendor/NimAgentLibrary/src \
  -o:build/nimfactory src/nimfactory_cli.nim

nim c -r --hints:off --path:src --path:vendor/NimAgentLibrary/src \
  tests/mission/test_intervention_bench.nim

nim c -r --hints:off --path:src --path:vendor/NimAgentLibrary/src \
  tests/mission/test_noop_recovery.nim

BIN=./build/nimfactory
FIX=fixtures/e2e_intervention
SHA="$(git rev-parse HEAD)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="docs/qa/e2e_intervention/campaigns/${STAMP}"
mkdir -p "$OUT"
echo "SHA=$SHA"
echo "OUT=$OUT"

# Load planned-API key from host file when unset (never commit /opt/.keys).
if [[ -z "${OPENAI_API_KEY:-}" && -f /opt/.keys ]]; then
  if grep -q '^OPENAI_API_KEY=' /opt/.keys 2>/dev/null; then
    set -a
    # shellcheck disable=SC1090
    source /opt/.keys
    set +a
  else
    OPENAI_API_KEY="$(tr -d ' \t\r\n' < /opt/.keys)"
    export OPENAI_API_KEY
  fi
  echo "OPENAI_API_KEY loaded from /opt/.keys"
fi

run_one() {
  local name="$1"; shift
  local wt
  wt="$(mktemp -d /tmp/nf_camp_${name}.XXXXXX)"
  rmdir "$wt"
  set +e
  "$BIN" "$@" --worktree "$wt" > "$OUT/${name}.json"
  local ec=$?
  set -e
  python3 - "$OUT/${name}.json" "$OUT/${name}.meta.json" "$ec" <<'PY'
import json, sys
path, meta_path, ec = sys.argv[1], sys.argv[2], int(sys.argv[3])
d = json.load(open(path))
meta = {
  "exit_code": ec,
  "ok": d.get("ok"),
  "verdict": d.get("verdict"),
  "provider_calls": d.get("provider_calls"),
  "recovery_triggered": d.get("recovery_triggered"),
  "recovery_attempted": d.get("recovery_attempted"),
  "warning": d.get("warning"),
}
json.dump(meta, open(meta_path, "w"), indent=2)
print(f"recorded {path} exit={ec} verdict={meta['verdict']}")
PY
  return "$ec"
}

GLOBAL_OK=1

# --- API campaign (or unavailable probe) ---
if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  set +e
  "$BIN" mission-fix --repo "$FIX/repo_a" --symptom "$FIX/SYMPTOM.md" \
    --oracle "$FIX/oracle" --route api > "$OUT/api_unavailable.json"
  echo "api_unavailable_exit=$?"
  set -e
  echo '{"global_ok":false,"reason":"api_unavailable","sha":"'"$SHA"'"}' > "$OUT/summary.json"
  echo "API key unset; recovery live path untested"
  echo "done SHA=$SHA OUT=$OUT"
  exit 0
fi

# A may fail; always continue to B and crosses.
run_one api_repo_a mission-fix \
  --repo "$FIX/repo_a" --symptom "$FIX/SYMPTOM.md" \
  --oracle "$FIX/oracle" --route api || GLOBAL_OK=0

run_one api_repo_b mission-fix \
  --repo "$FIX/repo_b" --symptom "$FIX/SYMPTOM.md" \
  --oracle "$FIX/oracle" --route api || GLOBAL_OK=0

# Cross-replay from this campaign's API traces (no new model spend).
export NF_CAMPAIGN_OUT="$OUT"
python3 scripts/replay_cross_intervention.py
for name in cross_a_on_b cross_b_on_a; do
  if [[ -f "$OUT/${name}.json" ]]; then
    python3 - "$OUT/${name}.json" "$OUT/${name}.meta.json" <<'PY'
import json, sys
path, meta_path = sys.argv[1], sys.argv[2]
d = json.load(open(path))
meta = {
  "exit_code": 0 if d.get("ok") else 4,
  "ok": d.get("ok"),
  "verdict": d.get("verdict"),
  "provider_calls": d.get("provider_calls"),
  "note": "inject replay; exit_code derived from ok",
}
json.dump(meta, open(meta_path, "w"), indent=2)
print(name if False else f"recorded {path} verdict={meta['verdict']}")
PY
    if ! python3 -c "import json;raise SystemExit(0 if json.load(open('$OUT/${name}.json')).get('ok') else 1)"; then
      GLOBAL_OK=0
    fi
  fi
done

python3 - "$OUT" "$SHA" "$GLOBAL_OK" <<'PY'
import json, sys
from pathlib import Path
out, sha, gok = Path(sys.argv[1]), sys.argv[2], sys.argv[3] == "1"
trials = {}
for p in sorted(out.glob("*.meta.json")):
    trials[p.name.replace(".meta.json","")] = json.loads(p.read_text())
# Attempt detail from API JSON
detail = {}
for name in ("api_repo_a", "api_repo_b"):
    jp = out / f"{name}.json"
    if not jp.exists():
        continue
    d = json.loads(jp.read_text())
    detail[name] = {
        "verdict": d.get("verdict"),
        "ok": d.get("ok"),
        "provider_calls": d.get("provider_calls"),
        "recovery_triggered": d.get("recovery_triggered"),
        "recovery_attempted": d.get("recovery_attempted"),
        "attempts": [
            {
                "index": a.get("index"),
                "role": a.get("role"),
                "target": (a.get("decision") or {}).get("target_file"),
                "decision": (a.get("decision") or {}).get("decision"),
                "effective_change": a.get("effective_change"),
                "identical_to_original": (a.get("apply") or {}).get("identical_to_original"),
                "oracle_ok": (a.get("verify") or {}).get("ok"),
                "prompt_tokens": (a.get("provider") or {}).get("prompt_tokens"),
                "completion_tokens": (a.get("provider") or {}).get("completion_tokens"),
            }
            for a in d.get("attempts") or []
        ],
        "sources": (d.get("context") or {}).get("source_ids"),
    }
summary = {
    "sha": sha,
    "out": str(out),
    "global_ok": gok,
    "trials": trials,
    "api_detail": detail,
}
(out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps({"global_ok": gok, "sha": sha, "out": str(out)}, indent=2))
PY

echo "done SHA=$SHA OUT=$OUT global_ok=$GLOBAL_OK"
exit 0
