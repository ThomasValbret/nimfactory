#!/usr/bin/env bash
# Preflight OpenAI reachability, then run one real project CLI API campaign.
# Must run on the VPS host network (SSH / tmux), NOT inside the Cursor agent
# sandbox: that sandbox proxies egress and denies api.openai.com (CONNECT 403).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="/root/.nimble/bin:${PATH:-}"

# Clear Cursor sandbox proxy leftovers if any leaked into the shell.
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy \
  SOCKS_PROXY SOCKS5_PROXY socks_proxy socks5_proxy GIT_HTTP_PROXY GIT_HTTPS_PROXY \
  __CURSOR_SANDBOX_ENV_RESTORE 2>/dev/null || true

# shellcheck disable=SC1091
source "$ROOT/scripts/lib_load_openai_key.sh"
load_openai_key || {
  echo "FAIL: OPENAI_API_KEY missing (.keys / env)" >&2
  exit 2
}

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="docs/qa/project_cli_journey/api_preflight_${STAMP}"
mkdir -p "$OUT"
SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"

{
  echo "sha=$SHA"
  echo "date=$(date -u -Iseconds)"
  echo "proxy_vars=$(env | grep -ci proxy || true)"
  echo "--- ip ---"
  ip -4 addr || true
  echo "--- dns ---"
  getent hosts api.openai.com || true
  echo "--- curl models ---"
} | tee "$OUT/preflight.txt"

set +e
CURL_BODY="$OUT/models.json"
HTTP=$(curl -sS --connect-timeout 20 -o "$CURL_BODY" -w "%{http_code}" \
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
    "SSH onto the VPS host (not Cursor agent shell).",
    "Confirm: curl -sS https://api.openai.com/v1/models -H \"Authorization: Bearer $OPENAI_API_KEY\" | head",
    "Then: NF_PROJECT_ROUTE=api bash scripts/e2e_project_cli_journey.sh",
    "Agent sandbox allowlist denies api.openai.com (CONNECT 403); host eth0 has real egress."
  ]
}
(out/"summary.json").write_text(json.dumps(summary, indent=2)+"\n")
print(json.dumps(summary, indent=2))
PY
  echo "PREFLIGHT FAILED — see $OUT (do not substitute inject/local)." >&2
  exit 3
fi

echo "PREFLIGHT OK — launching NF_PROJECT_ROUTE=api campaign"
NF_PROJECT_ROUTE=api bash "$ROOT/scripts/e2e_project_cli_journey.sh" | tee "$OUT/e2e.log"
echo "done; preflight dir=$OUT"
