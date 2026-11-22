#!/usr/bin/env bash
# Preflight OpenAI reachability, then run one real project CLI API campaign.
# Must run on the VPS host network (SSH / tmux), NOT inside the Cursor agent
# sandbox: that sandbox proxies egress and denies api.openai.com (CONNECT 403).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="/root/.nimble/bin:${PATH:-}"

# Prefer host/Tailscale netns (nsenter into tailscaled) when the agent shell
# is isolated. Requires an unsandboxed shell (Cursor permission "all").
# shellcheck disable=SC1091
source "$ROOT/scripts/lib_load_openai_key.sh"
load_openai_key || {
  echo "FAIL: OPENAI_API_KEY missing (.keys / env)" >&2
  exit 2
}

run_net() {
  if [[ -x "$ROOT/scripts/with_host_net.sh" ]]; then
    bash "$ROOT/scripts/with_host_net.sh" -- "$@"
  else
    "$@"
  fi
}

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="docs/qa/project_cli_journey/api_preflight_${STAMP}"
mkdir -p "$OUT"
SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"

{
  echo "sha=$SHA"
  echo "date=$(date -u -Iseconds)"
  echo "proxy_vars=$(env | grep -ci proxy || true)"
  echo "--- ip (host/tailscale net) ---"
  run_net bash -c 'ip -br addr | head -12' || true
  echo "--- dns ---"
  run_net getent hosts api.openai.com || true
  echo "--- curl models ---"
} | tee "$OUT/preflight.txt"

set +e
CURL_BODY="$OUT/models.json"
HTTP=$(run_net curl -sS --connect-timeout 20 -o "$CURL_BODY" -w "%{http_code}" \
  https://api.openai.com/v1/models \
  -H "Authorization: Bearer ${OPENAI_API_KEY}")
CURL_EC=$?
set -e
echo "curl_exit=$CURL_EC http=$HTTP" | tee -a "$OUT/preflight.txt"
head -c 240 "$CURL_BODY" 2>/dev/null | tee -a "$OUT/preflight.txt" || true
echo | tee -a "$OUT/preflight.txt"

if [[ "$CURL_EC" -ne 0 || "$HTTP" != "200" ]]; then
  python3 - "$OUT" "$SHA" "$CURL_EC" "$HTTP" <<'PY'
import json,sys,pathlib
out, sha, ec, http = pathlib.Path(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4]
summary={
  "sha": sha,
  "route": "api",
  "preflight_ok": False,
  "curl_exit": ec,
  "http": http,
  "roles_untested": ["planner","reviser","implementer"],
  "how_to_fix": [
    "Unsandboxed agent shell (required_permissions all) then: bash scripts/with_host_net.sh -- ...",
    "Or SSH/console on the VPS host (already on eth0/tailscale0).",
    "nsenter -t $(pgrep -x tailscaled) -n -m -- env -u HTTP_PROXY -u HTTPS_PROXY ...",
    "Then: NF_PROJECT_ROUTE=api bash scripts/e2e_project_cli_journey.sh"
  ]
}
(out/"summary.json").write_text(json.dumps(summary, indent=2)+"\n")
print(json.dumps(summary, indent=2))
PY
  echo "PREFLIGHT FAILED — see $OUT (do not substitute inject/local)." >&2
  exit 3
fi

echo "PREFLIGHT OK — launching NF_PROJECT_ROUTE=api campaign via host/tailscale net"
run_net env NF_PROJECT_ROUTE=api PATH="/root/.nimble/bin:${PATH:-}" \
  bash "$ROOT/scripts/e2e_project_cli_journey.sh" | tee "$OUT/e2e.log"
echo "done; preflight dir=$OUT"
