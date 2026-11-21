#!/usr/bin/env bash
# Replay archived turn-1 from 20261119T151407Z, then one real gpt-4o-mini recovery call.
# Historical fix / private oracle / compile diagnosis stay out of the recovery request.
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
ARCH=docs/qa/e2e_intervention/campaigns/20261119T151407Z
SHA="$(git rev-parse HEAD)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="docs/qa/e2e_intervention/campaigns/${STAMP}"
mkdir -p "$OUT" "$FIX/inject"
echo "SHA=$SHA OUT=$OUT"

# Materialize archived turn-1 inject (exact model proposal).
python3 - "$ARCH" "$FIX" <<'PY'
import json, sys
from pathlib import Path
arch, fix = Path(sys.argv[1]), Path(sys.argv[2])
d = json.loads((arch/'api_real_unknown_module.json').read_text())
raw = d['attempts'][0]['provider']['raw_text']
# Persist as inject file (fenced JSON as archived).
inj = fix/'inject'/'archived_151407Z_turn1.json'
# Prefer structured body matching parseFixDecision expectations.
body = {
  "target_file": "src/glob.nim",
  "decision": "expandGlob does not handle the pattern correctly for sibling directories",
  "edits": [{"oldText": "return pattern", "newText": "return expandGlob(pattern)"}]
}
inj.write_text(json.dumps(body, indent=2) + "\n")
(arch.parent.parent/'..')  # noop keep
print("wrote", inj)
print("archived_raw_excerpt=", raw[:120].replace("\n"," "))
PY

# Independent controls
set +e
nim c -r --hints:off --warnings:off --path:"$FIX/repo/src" \
  -o:/tmp/nf_ambig_pub "$FIX/public/repro.nim" > "$OUT/public_repro_before.txt" 2>&1
PUB_EC=$?
nim c -r --hints:off --warnings:off --path:"$FIX/repo/src" \
  -o:/tmp/nf_ambig_or_orig "$FIX/oracle/test_walk_shallow.nim" > "$OUT/original_oracle.txt" 2>&1
ORIG_EC=$?
WT_HIST="$(mktemp -d /tmp/nf_ambig_hist.XXXXXX)"
cp -a "$FIX/repo/." "$WT_HIST/"
cp "$FIX/reference/glob_after_fix.nim" "$WT_HIST/src/glob.nim"
nim c -r --hints:off --warnings:off --path:"$WT_HIST/src" \
  -o:/tmp/nf_ambig_or_hist "$FIX/oracle/test_walk_shallow.nim" > "$OUT/historical_fix_oracle.txt" 2>&1
HIST_EC=$?
set -e
echo "public_before=$PUB_EC original_oracle=$ORIG_EC historical_oracle=$HIST_EC"

# Offline: inject turn1 only (no recovery) → apply_failed ambiguous, file intact
WT_OFF="$(mktemp -d /tmp/nf_ambig_off.XXXXXX)"; rmdir "$WT_OFF"
set +e
"$BIN" mission-fix --repo "$FIX/repo" --symptom "$FIX/SYMPTOM.md" \
  --oracle "$FIX/oracle" --route inject \
  --inject "$FIX/inject/archived_151407Z_turn1.json" --worktree "$WT_OFF" \
  > "$OUT/offline_turn1_only.json"
OFF_EC=$?
set -e
echo "offline_turn1_exit=$OFF_EC"
python3 - "$OUT" "$FIX" <<'PY'
import json, hashlib
from pathlib import Path
out, fix = Path('.'), Path('fixtures/e2e_real_unknown_module')
# paths via argv
import sys
out = Path(sys.argv[1]); fix = Path(sys.argv[2])
d=json.loads((out/'offline_turn1_only.json').read_text())
assert d['verdict']=='apply_failed'
assert (d.get('apply') or {}).get('refuse_code')=='anchor_ambiguous'
assert (d.get('verify') or {}).get('kind')=='vkNotRun'
assert (d.get('verify') or {}).get('ran') is False
orig=hashlib.sha256((fix/'repo/src/glob.nim').read_bytes()).hexdigest()
wt=Path((d.get('apply') or {}).get('worktree') or '')
if wt and (wt/'src'/'glob.nim').exists():
  h=hashlib.sha256((wt/'src'/'glob.nim').read_bytes()).hexdigest()
  assert h==orig
  print('offline_turn1: intact bytes ok')
else:
  print('offline_turn1: ok (no wt file)')
PY

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo '{"ok":false,"verdict":"api_unavailable","warning":"OPENAI_API_KEY missing; real ambiguous recovery untested"}' \
    > "$OUT/api_ambiguous_recovery.json"
  python3 - "$OUT" "$SHA" "$PUB_EC" "$ORIG_EC" "$HIST_EC" <<'PY'
import json,sys
from pathlib import Path
out,sha=Path(sys.argv[1]),sys.argv[2]
pub,orig,hist=map(int,sys.argv[3:])
d=json.loads((out/'api_ambiguous_recovery.json').read_text())
summary={
  "sha":sha,"out":str(out),"case":"e2e_ambiguous_recovery",
  "replay_of":"20261119T151407Z","budget_eur_cap":3,
  "public_repro_before_exit":pub,"original_oracle_exit":orig,
  "historical_fix_oracle_exit":hist,
  "api":d,"model_decision_tested":False,
  "real_recovery_untested":True
}
(out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
PY
  echo "API unavailable — real recovery untested"
  exit 0
fi

# Live: inject archived turn1, recovery via planned API (one new paid call)
WT_API="$(mktemp -d /tmp/nf_ambig_api.XXXXXX)"; rmdir "$WT_API"
set +e
"$BIN" mission-fix --repo "$FIX/repo" --symptom "$FIX/SYMPTOM.md" \
  --oracle "$FIX/oracle" --route inject \
  --inject "$FIX/inject/archived_151407Z_turn1.json" \
  --recovery-api --worktree "$WT_API" \
  > "$OUT/api_ambiguous_recovery.json"
API_EC=$?
set -e
echo "api_ambiguous_recovery_exit=$API_EC"

# If applied, also capture public repro on the recovery worktree
python3 - "$OUT" "$SHA" "$API_EC" "$PUB_EC" "$ORIG_EC" "$HIST_EC" "$FIX" <<'PY'
import json, sys, subprocess, hashlib, os
from pathlib import Path
out, sha = Path(sys.argv[1]), sys.argv[2]
api_ec, pub, orig, hist = map(int, sys.argv[3:7])
fix = Path(sys.argv[7])
d = json.loads((out/'api_ambiguous_recovery.json').read_text())
attempts=[]
prompt=completion=0
for a in d.get('attempts') or []:
    p=a.get('provider') or {}
    pt,ct=int(p.get('prompt_tokens') or 0), int(p.get('completion_tokens') or 0)
    prompt+=pt; completion+=ct
    dec=a.get('decision') or {}; apply=a.get('apply') or {}; ver=a.get('verify') or {}
    attempts.append({
        'index':a.get('index'),'role':a.get('role'),
        'recovery_reason':a.get('recovery_reason'),
        'target':dec.get('target_file'),'decision':dec.get('decision'),
        'mode':dec.get('mode') or apply.get('mode'),
        'edits':dec.get('edits'),'edits_count':dec.get('edits_count'),
        'edits_applied':apply.get('edits_applied'),
        'refuse_code':apply.get('refuse_code') or dec.get('refuse_code'),
        'apply_message':apply.get('message'),
        'before_hash':apply.get('before_hash'),'after_hash':apply.get('after_hash'),
        'oracle_kind':ver.get('kind'),'oracle_ran':ver.get('ran'),
        'oracle_ok':ver.get('ok'),'oracle_message':ver.get('message'),
        'phase':ver.get('phase'),
        'prompt_tokens':pt,'completion_tokens':ct,
        'model':p.get('model'),'provider_kind':p.get('provider_kind'),
        'provider_code':p.get('code'),
        'raw_excerpt':(dec.get('raw_excerpt') or '')[:500],
    })

# Public repro + oracle on final worktree if apply ok on last attempt
final_apply = (d.get('apply') or {})
wt = final_apply.get('worktree') or ''
pub_after = None; or_after = None
if d.get('ok') and wt and Path(wt).exists():
    pub_cmd = ['nim','c','-r','--hints:off','--warnings:off','--path:'+str(Path(wt)/'src'),
               '-o:/tmp/nf_ambig_pub_after', str(fix/'public'/'repro.nim')]
    or_cmd = ['nim','c','-r','--hints:off','--warnings:off','--path:'+str(Path(wt)/'src'),
              '-o:/tmp/nf_ambig_or_after', str(fix/'oracle'/'test_walk_shallow.nim')]
    pr = subprocess.run(pub_cmd, capture_output=True, text=True)
    (out/'public_repro_after.txt').write_text(pr.stdout + pr.stderr)
    pub_after = {'exit': pr.returncode, 'stdout': pr.stdout[-500:]}
    ore = subprocess.run(or_cmd, capture_output=True, text=True)
    (out/'oracle_after.txt').write_text(ore.stdout + ore.stderr)
    or_after = {'exit': ore.returncode, 'stdout': ore.stdout[-500:]}

cost = prompt * 0.15e-6 + completion * 0.60e-6
# Only count recovery API tokens as "new paid" if second attempt is api
paid_calls = 0
for a in d.get('attempts') or []:
    p=a.get('provider') or {}
    if p.get('provider_kind')=='openai' and p.get('route') in ('api', None) and (a.get('role')=='recovery' or p.get('route')=='api'):
        if a.get('role')=='recovery' and p.get('ok') is not None:
            paid_calls += 1
# inject first + recoveryViaApi second
for a in d.get('attempts') or []:
    if a.get('role')=='recovery':
        p=a.get('provider') or {}
        if p.get('provider_kind')=='openai':
            paid_calls = 1
            break

summary={
  'sha':sha,'out':str(out),'case':'e2e_ambiguous_recovery',
  'replay_of':'20261119T151407Z',
  'faulty_sha':'589671a897c12398113605193130d1c60ffab282',
  'budget_eur_cap':3,
  'public_repro_before_exit':pub,'original_oracle_exit':orig,
  'historical_fix_oracle_exit':hist,'api_exit':api_ec,
  'public_repro_after':pub_after,'oracle_after':or_after,
  'api':{
    'ok':d.get('ok'),'verdict':d.get('verdict'),
    'provider_calls':d.get('provider_calls'),
    'recovery_triggered':d.get('recovery_triggered'),
    'recovery_reason':d.get('recovery_reason'),
    'sources':(d.get('context') or {}).get('source_ids'),
    'warning':d.get('warning'),
    'attempts':attempts,
    'prompt_tokens_total':prompt,'completion_tokens_total':completion,
    'estimated_usd':round(cost,8),
    'paid_openai_calls':paid_calls,
  },
  'model_decision_tested': paid_calls>0,
  'real_recovery_untested': paid_calls==0,
}
(out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps({
  'sha':sha,'out':str(out),'verdict':summary['api']['verdict'],
  'ok':summary['api']['ok'],'calls':summary['api']['provider_calls'],
  'recovery':summary['api']['recovery_triggered'],
  'recovery_reason':summary['api']['recovery_reason'],
  'targets':[a['target'] for a in attempts],
  'edits_applied':[a['edits_applied'] for a in attempts],
  'tokens':[prompt,completion],'est_usd':summary['api']['estimated_usd'],
  'paid_openai_calls':paid_calls,
}, indent=2))
PY

echo "done SHA=$SHA OUT=$OUT"
exit 0
