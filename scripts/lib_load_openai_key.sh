# Shared OpenAI key loader for NimFactory E2E / mission scripts.
# Preference: env → project .keys → main checkout .keys → host /opt/.keys (legacy).
# Never commit secrets; `.keys` is gitignored.
#
# Usage: source this file from a script whose ROOT is the repo root, or set ROOT first.

load_openai_key() {
  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    return 0
  fi
  local root="${ROOT:-}"
  if [[ -z "$root" ]]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
  local f=""
  if [[ -f "$root/.keys/api_provider_key" ]]; then
    f="$root/.keys/api_provider_key"
  elif [[ -f "$root/.keys" ]]; then
    f="$root/.keys"
  elif [[ -f /opt/nimFactory/.keys/api_provider_key ]]; then
    f=/opt/nimFactory/.keys/api_provider_key
  elif [[ -f /opt/nimFactory/.keys ]]; then
    f=/opt/nimFactory/.keys
  elif [[ -f /opt/.keys/api_provider_key ]]; then
    f=/opt/.keys/api_provider_key
  elif [[ -f /opt/.keys ]]; then
    f=/opt/.keys
  fi
  [[ -z "$f" ]] && return 1
  if grep -q '^OPENAI_API_KEY=' "$f" 2>/dev/null; then
    set -a
    # shellcheck disable=SC1090
    source "$f"
    set +a
  else
    OPENAI_API_KEY="$(tr -d ' \t\r\n' < "$f")"
    export OPENAI_API_KEY
  fi
  echo "OPENAI_API_KEY loaded from $f"
  return 0
}
