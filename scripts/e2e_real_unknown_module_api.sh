#!/usr/bin/env bash
# One live gpt-4o-mini mission on fixtures/e2e_real_unknown_module (budget ≤ €3, ≤ 2 calls).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="/root/.nimble/bin:${PATH:-}"

# Project key first (.keys gitignored); host /opt/.keys as legacy fallback.
# shellcheck disable=SC1091
source "$ROOT/scripts/lib_load_openai_key.sh"
load_openai_key || true

nim c -d:release -d:ssl --hints:off --path:src --path:vendor/NimAgentLibrary/src \
  -o:build/nimfactory src/nimfactory_cli.nim

BIN=./build/nimfactory
FIX=fixtures/e2e_real_unknown_module
SHA="$(git rev-parse HEAD)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="docs/qa/e2e_intervention/campaigns/${STAMP}"
mkdir -p "$OUT"
echo "SHA=$SHA OUT=$OUT"

# Independent: public repro on faulty tree
set +e
nim c -r --hints:off --warnings:off --path:"$FIX/repo/src" \
  -o:/tmp/nf_glob_public_repro "$FIX/public/repro.nim" \
  > "$OUT/public_repro.txt" 2>&1
PUB_EC=$?
set -e
echo "public_repro_exit=$PUB_EC"
cp "$OUT/public_repro.txt" "$OUT/public_repro_observed.txt"

# Independent: oracle fails on original
set +e
nim c -r --hints:off --warnings:off --path:"$FIX/repo/src" \
  -o:/tmp/nf_glob_oracle_orig "$FIX/oracle/test_walk_shallow.nim" \
  > "$OUT/original_oracle.txt" 2>&1
ORIG_EC=$?
set -e
echo "original_oracle_exit=$ORIG_EC (expect non-zero)"

# Independent: oracle passes after historical fix body
WT_HIST="$(mktemp -d /tmp/nf_glob_hist.XXXXXX)"
cp -a "$FIX/repo/." "$WT_HIST/"
cp "$FIX/reference/glob_after_fix.nim" "$WT_HIST/src/glob.nim"
set +e
nim c -r --hints:off --warnings:off --path:"$WT_HIST/src" \
  -o:/tmp/nf_glob_oracle_hist "$FIX/oracle/test_walk_shallow.nim" \
  > "$OUT/historical_fix_oracle.txt" 2>&1
HIST_EC=$?
set -e
echo "historical_fix_oracle_exit=$HIST_EC (expect 0)"

# Inspect buildApiContext product (nested sources)
nim c -r --hints:off --path:src --path:vendor/NimAgentLibrary/src \
  -o:build/dump_ctx tests/mission/dump_real_unknown_context.nim \
  > "$OUT/build_api_context_dump.json" 2>"$OUT/build_api_context_dump.err"
echo "context_dump_written"

# Offline inject of historical fix
WT_REF="$(mktemp -d /tmp/nf_glob_ref.XXXXXX)"; rmdir "$WT_REF"
set +e
"$BIN" mission-fix --repo "$FIX/repo" --symptom "$FIX/SYMPTOM.md" \
  --oracle "$FIX/oracle" --route inject \
  --inject "$FIX/inject/ref_historical_fix.json" --worktree "$WT_REF" \
  > "$OUT/bench_ref_historical.json"
REF_EC=$?
set -e
echo "bench_ref_historical_exit=$REF_EC (expect 0)"

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo '{"ok":false,"verdict":"api_unavailable","warning":"OPENAI_API_KEY missing; model decision untested"}' \
    > "$OUT/api_real_unknown_module.json"
  echo "API unavailable — model decision untested; independent checks kept"
  python3 - "$OUT" "$SHA" "$PUB_EC" "$ORIG_EC" "$HIST_EC" "$REF_EC" <<'PY'
import json, sys
from pathlib import Path
out, sha = Path(sys.argv[1]), sys.argv[2]
pub, orig, hist, ref = map(int, sys.argv[3:])
d = json.loads((out/'api_real_unknown_module.json').read_text())
ctx = {}
cp = out/'build_api_context_dump.json'
if cp.exists():
  try: ctx = json.loads(cp.read_text())
  except Exception: ctx = {"raw_error": "parse"}
summary = {
  "sha": sha, "out": str(out), "case": "e2e_real_unknown_module",
  "upstream": "https://github.com/haltcase/glob",
  "faulty_sha": "589671a897c12398113605193130d1c60ffab282",
  "fix_sha": "1fa54df5fa57e38adc43de2cb050c7748c305047",
  "budget_eur_cap": 3, "public_repro_exit": pub,
  "original_oracle_exit": orig, "historical_fix_oracle_exit": hist,
  "bench_ref_historical_exit": ref, "api_exit": None,
  "api": d, "context_source_ids": ctx.get("source_ids"),
  "model_decision_tested": False,
}
(out/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
print(json.dumps(summary, indent=2))
PY
  exit 0
fi

WT_API="$(mktemp -d /tmp/nf_glob_api.XXXXXX)"; rmdir "$WT_API"
set +e
"$BIN" mission-fix --repo "$FIX/repo" --symptom "$FIX/SYMPTOM.md" \
  --oracle "$FIX/oracle" --route api --worktree "$WT_API" \
  > "$OUT/api_real_unknown_module.json"
API_EC=$?
set -e
echo "api_real_unknown_exit=$API_EC"

python3 - "$OUT" "$SHA" "$API_EC" "$PUB_EC" "$ORIG_EC" "$HIST_EC" "$REF_EC" <<'PY'
import json, sys
from pathlib import Path
out = Path(sys.argv[1]); sha = sys.argv[2]
api_ec, pub, orig, hist, ref = map(int, sys.argv[3:])
d = json.loads((out/'api_real_unknown_module.json').read_text())
ctx = {}
cp = out/'build_api_context_dump.json'
if cp.exists():
  try: ctx = json.loads(cp.read_text())
  except Exception as e: ctx = {"parse_error": str(e)}
attempts = []
prompt = completion = 0
for a in d.get('attempts') or []:
    p = (a.get('provider') or {})
    pt, ct = int(p.get('prompt_tokens') or 0), int(p.get('completion_tokens') or 0)
    prompt += pt; completion += ct
    dec = a.get('decision') or {}
    apply = a.get('apply') or {}
    ver = a.get('verify') or {}
    attempts.append({
        'index': a.get('index'), 'role': a.get('role'),
        'recovery_reason': a.get('recovery_reason'),
        'target': dec.get('target_file'),
        'decision': dec.get('decision'),
        'mode': dec.get('mode') or apply.get('mode'),
        'edits_count': dec.get('edits_count'),
        'edits_applied': apply.get('edits_applied'),
        'edit_details': apply.get('edit_details'),
        'cannot_fix': a.get('cannot_fix'),
        'effective_change': a.get('effective_change'),
        'identical_to_original': apply.get('identical_to_original'),
        'before_hash': apply.get('before_hash'),
        'after_hash': apply.get('after_hash'),
        'apply_message': apply.get('message'),
        'oracle_kind': ver.get('kind'), 'oracle_ok': ver.get('ok'),
        'oracle_message': ver.get('message'),
        'phase': ver.get('phase'),
        'provider_code': p.get('code'),
        'provider_status': p.get('status'),
        'prompt_tokens': pt, 'completion_tokens': ct,
        'model': p.get('model'), 'provider_kind': p.get('provider_kind'),
        'raw_excerpt': (dec.get('raw_excerpt') or '')[:500],
    })
cost = prompt * 0.15e-6 + completion * 0.60e-6
summary = {
    'sha': sha, 'out': str(out), 'case': 'e2e_real_unknown_module',
    'upstream': 'https://github.com/haltcase/glob',
    'faulty_sha': '589671a897c12398113605193130d1c60ffab282',
    'faulty_url': 'https://github.com/haltcase/glob/commit/589671a897c12398113605193130d1c60ffab282',
    'fix_sha': '1fa54df5fa57e38adc43de2cb050c7748c305047',
    'fix_url': 'https://github.com/haltcase/glob/commit/1fa54df5fa57e38adc43de2cb050c7748c305047',
    'budget_eur_cap': 3,
    'public_repro_exit': pub,
    'original_oracle_exit': orig,
    'historical_fix_oracle_exit': hist,
    'bench_ref_historical_exit': ref,
    'api_exit': api_ec,
    'context_source_ids': ctx.get('source_ids') or (d.get('context') or {}).get('source_ids'),
    'api': {
        'ok': d.get('ok'), 'verdict': d.get('verdict'),
        'provider_calls': d.get('provider_calls'),
        'recovery_triggered': d.get('recovery_triggered'),
        'recovery_reason': d.get('recovery_reason'),
        'sources': (d.get('context') or {}).get('source_ids'),
        'system_prompt': (d.get('context') or {}).get('system_prompt'),
        'user_prompt': (d.get('context') or {}).get('user_prompt'),
        'warning': d.get('warning'),
        'attempts': attempts,
        'prompt_tokens_total': prompt,
        'completion_tokens_total': completion,
        'estimated_usd': round(cost, 8),
    },
    'model_decision_tested': d.get('verdict') != 'api_unavailable' and (d.get('provider_calls') or 0) > 0,
}
(out/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
print(json.dumps({
    'sha': sha, 'out': str(out),
    'verdict': summary['api']['verdict'],
    'ok': summary['api']['ok'],
    'calls': summary['api']['provider_calls'],
    'recovery': summary['api']['recovery_triggered'],
    'targets': [a['target'] for a in attempts],
    'tokens': [prompt, completion],
    'est_usd': summary['api']['estimated_usd'],
    'sources': summary['api']['sources'],
}, indent=2))
PY

echo "done SHA=$SHA OUT=$OUT"
exit 0
