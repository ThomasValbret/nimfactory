#!/usr/bin/env bash
# Real planned-API run for fixtures/e2e_novel_followcall (budget-conscious).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="/root/.nimble/bin:${PATH:-}"

load_openai_key() {
  local f=""
  if [[ -f /opt/.keys/api_provider_key ]]; then f=/opt/.keys/api_provider_key
  elif [[ -f /opt/.keys ]]; then f=/opt/.keys
  fi
  [[ -z "$f" ]] && return 1
  if grep -q '^OPENAI_API_KEY=' "$f" 2>/dev/null; then
    set -a; # shellcheck disable=SC1090
    source "$f"; set +a
  else
    OPENAI_API_KEY="$(tr -d ' \t\r\n' < "$f")"; export OPENAI_API_KEY
  fi
  echo "OPENAI_API_KEY loaded from $f"
}
if [[ -z "${OPENAI_API_KEY:-}" ]]; then load_openai_key || true; fi

nim c -d:release -d:ssl --hints:off --path:src --path:vendor/NimAgentLibrary/src \
  -o:build/nimfactory src/nimfactory_cli.nim

BIN=./build/nimfactory
FIX=fixtures/e2e_novel_followcall
SHA="$(git rev-parse HEAD)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="docs/qa/e2e_intervention/campaigns/${STAMP}"
mkdir -p "$OUT"
echo "SHA=$SHA OUT=$OUT"

# Bench: originals fail oracle; reference fix passes (inject, no network).
python3 - <<'PY'
import json, subprocess, tempfile, os
from pathlib import Path
root = Path('.').resolve()
fix = root / 'fixtures' / 'e2e_novel_followcall'
bin = root / 'build' / 'nimfactory'
out = Path(os.environ.get('OUT_DIR', 'docs/qa/e2e_intervention/campaigns/tmp'))
# write via shell OUT later
PY

# Independent: original fails
WT0="$(mktemp -d /tmp/nf_novel_orig.XXXXXX)"
# copy repo manually into empty wt for oracle-only check via inject wrong noop?
# Use mission inject with identical cart (no-op) would recover — instead compile oracle on copy:
cp -a "$FIX/repo/." "$WT0/"
set +e
nim c -r --hints:off --warnings:off --path:"$WT0/src" \
  -o:/tmp/nf_novel_oracle_orig "$FIX/oracle/test_cart_total.nim" >/tmp/nf_novel_orig_oracle.txt 2>&1
ORIG_EC=$?
set -e
echo "original_oracle_exit=$ORIG_EC (expect non-zero)"
cp /tmp/nf_novel_orig_oracle.txt "$OUT/original_oracle.txt"

# Reference inject
mkdir -p "$FIX/inject"
python3 - <<'PY'
from pathlib import Path
fix = Path('fixtures/e2e_novel_followcall')
body = (fix / 'reference' / 'fix_cart.nim').read_text()
# reference file uses import ./catalog — for repo path it's src/cart.nim with same content adjusted
# Use the fixed cart body matching repo layout:
body = '''import ./catalog

type
  Line* = object
    skuId*: string
    qty*: int

proc lineTotal*(line: Line): int =
  let unit = lookupUnitCents(line.skuId)
  var total = 0
  var i = 0
  while i < line.qty:
    total += unit
    inc i
  result = total

proc cartTotal*(lines: openArray[Line]): int =
  var sum = 0
  for line in lines:
    sum += lineTotal(line)
  result = sum
'''
import json
(fix/'inject').mkdir(exist_ok=True)
(fix/'inject'/'ref_fix_cart.json').write_text(json.dumps({
  'target_file': 'src/cart.nim',
  'decision': 'remove extra unit add after qty loop in lineTotal',
  'patched_content': body,
}, indent=2) + '\n')
print('wrote ref inject')
PY

WT_REF="$(mktemp -d /tmp/nf_novel_ref.XXXXXX)"; rmdir "$WT_REF"
set +e
"$BIN" mission-fix --repo "$FIX/repo" --symptom "$FIX/SYMPTOM.md" \
  --oracle "$FIX/oracle" --route inject \
  --inject "$FIX/inject/ref_fix_cart.json" --worktree "$WT_REF" \
  > "$OUT/bench_ref_fix.json"
REF_EC=$?
set -e
echo "bench_ref_fix_exit=$REF_EC (expect 0)"

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo '{"ok":false,"verdict":"api_unavailable","warning":"OPENAI_API_KEY missing; novel model decision untested"}' \
    > "$OUT/api_novel_followcall.json"
  echo "API unavailable — model decision untested"
  exit 0
fi

WT_API="$(mktemp -d /tmp/nf_novel_api.XXXXXX)"; rmdir "$WT_API"
set +e
"$BIN" mission-fix --repo "$FIX/repo" --symptom "$FIX/SYMPTOM.md" \
  --oracle "$FIX/oracle" --route api --worktree "$WT_API" \
  > "$OUT/api_novel_followcall.json"
API_EC=$?
set -e
echo "api_novel_exit=$API_EC"

python3 - "$OUT" "$SHA" "$API_EC" "$REF_EC" "$ORIG_EC" <<'PY'
import json, sys
from pathlib import Path
out, sha, api_ec, ref_ec, orig_ec = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
d = json.loads((out/'api_novel_followcall.json').read_text())
attempts = []
prompt = completion = 0
for a in d.get('attempts') or []:
    p = (a.get('provider') or {})
    pt, ct = int(p.get('prompt_tokens') or 0), int(p.get('completion_tokens') or 0)
    prompt += pt; completion += ct
    attempts.append({
        'index': a.get('index'), 'role': a.get('role'),
        'recovery_reason': a.get('recovery_reason'),
        'target': (a.get('decision') or {}).get('target_file'),
        'decision': (a.get('decision') or {}).get('decision'),
        'effective_change': a.get('effective_change'),
        'identical_to_original': (a.get('apply') or {}).get('identical_to_original'),
        'oracle_kind': (a.get('verify') or {}).get('kind'),
        'oracle_ok': (a.get('verify') or {}).get('ok'),
        'phase': (a.get('verify') or {}).get('phase'),
        'prompt_tokens': pt, 'completion_tokens': ct,
        'model': p.get('model'), 'provider_kind': p.get('provider_kind'),
        'raw_excerpt': (a.get('decision') or {}).get('raw_excerpt'),
    })
# gpt-4o-mini approx
cost = prompt * 0.15e-6 + completion * 0.60e-6
summary = {
    'sha': sha,
    'out': str(out),
    'case': 'e2e_novel_followcall',
    'budget_eur_cap': 3,
    'original_oracle_exit': orig_ec,
    'bench_ref_fix_exit': ref_ec,
    'api_exit': api_ec,
    'api': {
        'ok': d.get('ok'), 'verdict': d.get('verdict'),
        'provider_calls': d.get('provider_calls'),
        'recovery_triggered': d.get('recovery_triggered'),
        'recovery_reason': d.get('recovery_reason'),
        'sources': (d.get('context') or {}).get('source_ids'),
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
