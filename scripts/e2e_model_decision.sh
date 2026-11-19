#!/usr/bin/env bash
# Deprecated entrypoint: intervention-choice QA lives in e2e_intervention.sh.
# Kept as a thin wrapper so older docs still resolve.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec bash "$ROOT/scripts/e2e_intervention.sh" "$@"
