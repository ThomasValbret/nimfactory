#!/usr/bin/env bash
# Intervention-choice qualification (API route). No systematic Ollama.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="/root/.nimble/bin:${PATH:-}"
mkdir -p build docs/qa/e2e_intervention

nim c -d:release -d:ssl --hints:off --path:src --path:vendor/NimAgentLibrary/src \
  -o:build/nimfactory src/nimfactory_cli.nim

nim c -r --hints:off --path:src --path:vendor/NimAgentLibrary/src \
  tests/mission/test_intervention_bench.nim

BIN=./build/nimfactory
FIX=fixtures/e2e_intervention
SHA="$(git rev-parse HEAD)"
echo "SHA=$SHA"

# Load planned-API key from host file when unset (never commit /opt/.keys).
if [[ -z "${OPENAI_API_KEY:-}" && -f /opt/.keys ]]; then
  # File may be either `OPENAI_API_KEY=...` or a raw sk-... line.
  # shellcheck disable=SC1091
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

set +e
"$BIN" mission-fix --repo "$FIX/repo_a" --symptom "$FIX/SYMPTOM.md" \
  --oracle "$FIX/no_such_oracle" --route inject \
  --inject "$FIX/inject/ref_fix_a.json" \
  > docs/qa/e2e_intervention/cli_oracle_missing.json
echo "cli_oracle_missing_exit=$?"
set -e

WT_FALSE=$(mktemp -d /tmp/nf_cli_false.XXXXXX)
set +e
"$BIN" mission-fix --repo "$FIX/repo_a" --symptom "$FIX/SYMPTOM.md" \
  --oracle "$FIX/oracle_false" --route inject \
  --inject "$FIX/inject/ref_fix_a.json" --worktree "$WT_FALSE" \
  > docs/qa/e2e_intervention/cli_oracle_false.json
echo "cli_oracle_false_exit=$?"
set -e

WT_OK=$(mktemp -d /tmp/nf_cli_ok.XXXXXX)
rmdir "$WT_OK"
"$BIN" mission-fix --repo "$FIX/repo_a" --symptom "$FIX/SYMPTOM.md" \
  --oracle "$FIX/oracle" --route inject \
  --inject "$FIX/inject/ref_fix_a.json" --worktree "$WT_OK" \
  > docs/qa/e2e_intervention/cli_oracle_ok.json
echo "cli_oracle_ok"

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  set +e
  "$BIN" mission-fix --repo "$FIX/repo_a" --symptom "$FIX/SYMPTOM.md" \
    --oracle "$FIX/oracle" --route api \
    > docs/qa/e2e_intervention/api_unavailable.json
  echo "api_unavailable_exit=$?"
  set -e
  echo "API key unset; skipping live API trials"
  echo "done SHA=$SHA"
  exit 0
fi

WT_A=$(mktemp -d /tmp/nf_api_a.XXXXXX); rmdir "$WT_A"
WT_B=$(mktemp -d /tmp/nf_api_b.XXXXXX); rmdir "$WT_B"
"$BIN" mission-fix --repo "$FIX/repo_a" --symptom "$FIX/SYMPTOM.md" \
  --oracle "$FIX/oracle" --route api --worktree "$WT_A" \
  > docs/qa/e2e_intervention/api_repo_a.json
echo "api_repo_a"

"$BIN" mission-fix --repo "$FIX/repo_b" --symptom "$FIX/SYMPTOM.md" \
  --oracle "$FIX/oracle" --route api --worktree "$WT_B" \
  > docs/qa/e2e_intervention/api_repo_b.json
echo "api_repo_b"

python3 scripts/replay_cross_intervention.py
echo "done SHA=$SHA"
