#!/usr/bin/env bash
# Fetch the pinned NimAgent revision into vendor/ (isolated checkout).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN="${NIMAGENT_PIN:-bf22665ece77d7149dbe61df959a6024bf6b26f3}"
SRC="${NIMAGENT_SOURCE:-/opt/NimAgentLibrary}"
DEST="$ROOT/vendor/NimAgentLibrary"
mkdir -p "$ROOT/vendor"
if [ ! -d "$DEST/.git" ]; then
  if [ -d "$SRC/.git" ]; then
    git clone "$SRC" "$DEST"
  else
    echo "Set NIMAGENT_SOURCE to a NimAgentLibrary clone" >&2
    exit 1
  fi
fi
cd "$DEST"
git fetch --all --quiet || true
git checkout -f "$PIN"
echo "NimAgent at $(git rev-parse HEAD)"
