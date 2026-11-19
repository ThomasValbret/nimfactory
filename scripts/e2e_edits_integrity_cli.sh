#!/usr/bin/env bash
# CLI counter-examples: malformed edit + wrong-type newText → refuse, file bytes intact.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="/root/.nimble/bin:${PATH:-}"

nim c -d:release --hints:off --path:src --path:vendor/NimAgentLibrary/src \
  -o:build/nimfactory src/nimfactory_cli.nim

BIN=./build/nimfactory
FIX=fixtures/e2e_edits_apply
ORIG_HASH="$(sha256sum "$FIX/repo/src/sample.nim" | awk '{print $1}')"
echo "original_sha256=$ORIG_HASH"

run_case() {
  local name="$1" inject="$2"
  local wt
  wt="$(mktemp -d /tmp/nf_edits_cli_${name}.XXXXXX)"
  rmdir "$wt"
  set +e
  "$BIN" mission-fix --repo "$FIX/repo" --symptom "$FIX/SYMPTOM.md" \
    --oracle "$FIX/oracle" --route inject --inject "$inject" --worktree "$wt" \
    > "/tmp/nf_edits_cli_${name}.json"
  local ec=$?
  set -e
  echo "case=$name exit=$ec"
  python3 - "$name" "$wt" "$ORIG_HASH" "/tmp/nf_edits_cli_${name}.json" <<'PY'
import json, hashlib, sys
from pathlib import Path
name, wt, orig, report = sys.argv[1], Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4])
d = json.loads(report.read_text())
print("  verdict=", d.get("verdict"), "refuse=", (d.get("decision") or {}).get("refuse_code") or (d.get("apply") or {}).get("refuse_code"))
v = d.get("verify") or {}
print("  verify.ran=", v.get("ran"), "kind=", v.get("kind"), "exit=", v.get("exit_code"),
      "compile=", v.get("compile_exit_code"), "run=", v.get("run_exit_code"), "msg=", v.get("message"))
assert v.get("ran") is False
assert v.get("kind") == "vkNotRun"
assert v.get("exit_code") == -1
assert v.get("compile_exit_code") == -1
assert v.get("run_exit_code") == -1
assert v.get("message") == "oracle not run"
repo_file = Path("fixtures/e2e_edits_apply/repo/src/sample.nim")
h = hashlib.sha256(repo_file.read_bytes()).hexdigest()
assert h == orig, "repo original mutated"
target = Path(wt) / "src" / "sample.nim"
if target.exists():
  th = hashlib.sha256(target.read_bytes()).hexdigest()
  assert th == orig, "worktree target partially written"
  print("  worktree_bytes_intact=yes")
else:
  print("  worktree_target_absent_after_parse_refuse=yes")
print("  bytes_ok")
PY
}

run_case malformed "$FIX/inject/malformed_edit.json"
run_case newtext_type "$FIX/inject/newtext_wrong_type.json"
echo "e2e_edits_integrity_cli: ok"
