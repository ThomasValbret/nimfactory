#!/usr/bin/env bash
# Replay historical A (inject) → product recovery via gpt-4o-mini; B as success witness.
# Writes under docs/qa/e2e_intervention/campaigns/<stamp>/ ; preserves prior campaigns.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="/root/.nimble/bin:${PATH:-}"

nim c -d:release -d:ssl --hints:off --path:src --path:vendor/NimAgentLibrary/src \
  -o:build/nimfactory src/nimfactory_cli.nim

nim c -r --hints:off --path:src --path:vendor/NimAgentLibrary/src \
  tests/mission/test_noop_recovery.nim

BIN=./build/nimfactory
FIX=fixtures/e2e_intervention
SHA="$(git rev-parse HEAD)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="docs/qa/e2e_intervention/campaigns/${STAMP}"
mkdir -p "$OUT"
echo "SHA=$SHA OUT=$OUT"

# Project key first (.keys gitignored); host /opt/.keys as legacy fallback.
# shellcheck disable=SC1091
source "$ROOT/scripts/lib_load_openai_key.sh"
load_openai_key || true

write_meta() {
  local name="$1" ec="$2"
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
  "recovery_reason": d.get("recovery_reason"),
  "warning": d.get("warning"),
}
json.dump(meta, open(meta_path, "w"), indent=2)
print(f"{path}: exit={ec} verdict={meta['verdict']} calls={meta['provider_calls']}")
PY
}

# --- A: replay exact historical first response, then real API recovery ---
WT_A="$(mktemp -d /tmp/nf_vrec_a.XXXXXX)"; rmdir "$WT_A"
if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  set +e
  "$BIN" mission-fix --repo "$FIX/repo_a" --symptom "$FIX/SYMPTOM.md" \
    --oracle "$FIX/oracle" --route inject \
    --inject "$FIX/inject/historical_a_20261119T110158Z.json" \
    --recovery-api --worktree "$WT_A" > "$OUT/api_repo_a_replay_recovery.json"
  EC_A=$?
  set -e
  write_meta api_repo_a_replay_recovery "$EC_A"
  echo '{"global_ok":false,"reason":"api_unavailable_on_recovery","sha":"'"$SHA"'","base_commit_note":"start from identified tip; historical campaign summary listed f8a2170; feature d492dda; prior receipt f2d5e38"}' \
    > "$OUT/summary.json"
  echo "API unavailable; recovery live untested"
  exit 0
fi

set +e
"$BIN" mission-fix --repo "$FIX/repo_a" --symptom "$FIX/SYMPTOM.md" \
  --oracle "$FIX/oracle" --route inject \
  --inject "$FIX/inject/historical_a_20261119T110158Z.json" \
  --recovery-api --worktree "$WT_A" > "$OUT/api_repo_a_replay_recovery.json"
EC_A=$?
set -e
write_meta api_repo_a_replay_recovery "$EC_A"

# --- B witness: success stops without recovery ---
WT_B="$(mktemp -d /tmp/nf_vrec_b.XXXXXX)"; rmdir "$WT_B"
set +e
"$BIN" mission-fix --repo "$FIX/repo_b" --symptom "$FIX/SYMPTOM.md" \
  --oracle "$FIX/oracle" --route api --worktree "$WT_B" \
  > "$OUT/api_repo_b_success_witness.json"
EC_B=$?
set -e
write_meta api_repo_b_success_witness "$EC_B"

python3 - "$OUT" "$SHA" "$EC_A" "$EC_B" <<'PY'
import json, sys
from pathlib import Path
out, sha, eca, ecb = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3]), int(sys.argv[4])

def attempts(path):
    d = json.loads(path.read_text())
    rows = []
    for a in d.get("attempts") or []:
        rows.append({
            "index": a.get("index"),
            "role": a.get("role"),
            "recovery_reason": a.get("recovery_reason"),
            "target": (a.get("decision") or {}).get("target_file"),
            "decision": (a.get("decision") or {}).get("decision"),
            "patched_len": (a.get("decision") or {}).get("patched_len"),
            "effective_change": a.get("effective_change"),
            "identical_to_original": (a.get("apply") or {}).get("identical_to_original"),
            "oracle_kind": (a.get("verify") or {}).get("kind"),
            "oracle_ok": (a.get("verify") or {}).get("ok"),
            "prompt_tokens": (a.get("provider") or {}).get("prompt_tokens"),
            "completion_tokens": (a.get("provider") or {}).get("completion_tokens"),
            "model": (a.get("provider") or {}).get("model"),
            "provider_kind": (a.get("provider") or {}).get("provider_kind"),
            "raw_excerpt": (a.get("decision") or {}).get("raw_excerpt"),
        })
    return {
        "verdict": d.get("verdict"),
        "ok": d.get("ok"),
        "provider_calls": d.get("provider_calls"),
        "recovery_triggered": d.get("recovery_triggered"),
        "recovery_attempted": d.get("recovery_attempted"),
        "recovery_reason": d.get("recovery_reason"),
        "sources": (d.get("context") or {}).get("source_ids"),
        "attempts": rows,
        "warning": d.get("warning"),
    }

summary = {
    "sha": sha,
    "out": str(out),
    "provenance": {
        "historical_campaign": "20261119T110158Z",
        "historical_summary_sha_field": "f8a2170",
        "campaign_feature_commit": "d492dda",
        "prior_receipt_sha_mentioned": "f2d5e38",
        "this_trial_base": sha,
        "historical_a_inject": "fixtures/e2e_intervention/inject/historical_a_20261119T110158Z.json",
    },
    "exit_codes": {
        "api_repo_a_replay_recovery": eca,
        "api_repo_b_success_witness": ecb,
    },
    "api_repo_a_replay_recovery": attempts(out / "api_repo_a_replay_recovery.json"),
    "api_repo_b_success_witness": attempts(out / "api_repo_b_success_witness.json"),
}
# Cost estimate for the single new recovery API call (attempt 2 of A) + B if any
def tok(detail, idx):
    acts = detail.get("attempts") or []
    if len(acts) <= idx:
        return 0, 0
    a = acts[idx]
    return int(a.get("prompt_tokens") or 0), int(a.get("completion_tokens") or 0)

pa, ca = tok(summary["api_repo_a_replay_recovery"], 1)  # recovery turn only (new spend)
pb, cb = tok(summary["api_repo_b_success_witness"], 0)
# gpt-4o-mini ~ $0.15/1M in + $0.60/1M out
cost = (pa + pb) * 0.15e-6 + (ca + cb) * 0.60e-6
summary["estimated_usd_new_calls"] = round(cost, 8)
summary["global_ok"] = bool(summary["api_repo_a_replay_recovery"].get("ok")) and bool(
    summary["api_repo_b_success_witness"].get("ok"))
(out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps({
    "sha": sha,
    "out": str(out),
    "A_verdict": summary["api_repo_a_replay_recovery"]["verdict"],
    "A_calls": summary["api_repo_a_replay_recovery"]["provider_calls"],
    "B_verdict": summary["api_repo_b_success_witness"]["verdict"],
    "B_calls": summary["api_repo_b_success_witness"]["provider_calls"],
    "est_usd": summary["estimated_usd_new_calls"],
    "global_ok": summary["global_ok"],
}, indent=2))
PY

echo "done SHA=$SHA OUT=$OUT"
exit 0
