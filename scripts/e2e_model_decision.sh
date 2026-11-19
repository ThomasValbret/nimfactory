#!/usr/bin/env bash
# Reproducible E2E software_fix trials (API + local micro-patch A/B).
# For planned API trials: export OPENAI_API_KEY first. Build needs -d:ssl.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="/root/.nimble/bin:${PATH:-}"
mkdir -p build docs/qa/e2e_model_decision /tmp/nf_e2e

nim c -d:release -d:ssl --hints:off --path:src --path:vendor/NimAgentLibrary/src \
  -o:build/nimfactory src/nimfactory_cli.nim

nim c -r --hints:off --path:src --path:vendor/NimAgentLibrary/src \
  tests/mission/test_context_and_inject.nim

BIN=./build/nimfactory
FIX=fixtures/e2e_bugfix
SHA="$(git rev-parse HEAD)"
echo "SHA=$SHA"

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  set +e
  "$BIN" mission-fix --repo "$FIX/variant_a" --oracle "$FIX/oracle" \
    --worktree /tmp/nf_e2e/api_a --route api \
    > docs/qa/e2e_model_decision/api_unavailable.json
  API_EC=$?
  set -e
  echo "api_exit=$API_EC (expect 3 when key unset)"
else
  "$BIN" mission-fix --repo "$FIX/variant_a" --oracle "$FIX/oracle" \
    --worktree /tmp/nf_e2e/api_a --route api \
    > docs/qa/e2e_model_decision/api_variant_a.json
  echo "api_variant_a_ok"
  "$BIN" mission-fix --repo "$FIX/variant_b" --oracle "$FIX/oracle" \
    --worktree /tmp/nf_e2e/api_b --route api \
    > docs/qa/e2e_model_decision/api_variant_b.json
  echo "api_variant_b_ok"
fi

"$BIN" mission-fix --repo "$FIX/variant_a" --oracle "$FIX/oracle" \
  --worktree /tmp/nf_e2e/local_a --route local --local-model qwen2.5-coder:7b \
  > docs/qa/e2e_model_decision/local_variant_a.json
echo "local_variant_a_ok"

"$BIN" mission-fix --repo "$FIX/variant_b" --oracle "$FIX/oracle" \
  --worktree /tmp/nf_e2e/local_b --route local --local-model qwen2.5-coder:7b \
  > docs/qa/e2e_model_decision/local_variant_b.json
echo "local_variant_b_ok"
echo "done SHA=$SHA"
