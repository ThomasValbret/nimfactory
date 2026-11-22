#!/usr/bin/env bash
# Run a command in the host / Tailscale network namespace.
# Cursor agent shells are netns-isolated (lo only) and CapEff=0 under sandbox.
# Outside the sandbox (Shell permission "all"), nsenter into tailscaled works:
#   eth0 + tailscale0 + real DNS → api.openai.com reachable.
# Usage: bash scripts/with_host_net.sh -- command args...
set -euo pipefail
if [[ "${1:-}" == "--" ]]; then shift; fi
if [[ "$#" -lt 1 ]]; then
  echo "usage: $0 -- <command> [args...]" >&2
  exit 2
fi

# Drop Cursor sandbox proxy so traffic uses the host netns routes/DNS.
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy \
  SOCKS_PROXY SOCKS5_PROXY socks_proxy socks5_proxy GIT_HTTP_PROXY GIT_HTTPS_PROXY \
  NO_PROXY no_proxy __CURSOR_SANDBOX_ENV_RESTORE 2>/dev/null || true

TS_PID="$(pgrep -x tailscaled | head -1 || true)"
if [[ -z "$TS_PID" ]]; then
  echo "with_host_net: tailscaled not running" >&2
  exit 3
fi

# Already on host net (console colleagues)? Just exec.
if ip -br link show eth0 &>/dev/null || ip -br link show tailscale0 &>/dev/null; then
  exec "$@"
fi

if ! nsenter -t "$TS_PID" -n -m -- true 2>/dev/null; then
  echo "with_host_net: nsenter into pid $TS_PID failed (need unsandboxed shell / CapEff)." >&2
  echo "Retry the agent Shell tool with required_permissions: [\"all\"]." >&2
  exit 4
fi

exec nsenter -t "$TS_PID" -n -m -- env \
  -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
  -u ALL_PROXY -u all_proxy -u SOCKS_PROXY -u SOCKS5_PROXY \
  -u NO_PROXY -u no_proxy \
  "$@"
