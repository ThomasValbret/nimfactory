## Legacy fixture smoke + nested src/ collection for buildApiContext.

import std/[os, strutils]
import nimfactory/mission

let root = getCurrentDir()
let fixture = root / "fixtures" / "e2e_bugfix"
# Keep a minimal check that historical fixtures still parse if present.
if dirExists(fixture / "variant_a"):
  let ca = buildApiContext(fixture / "variant_a", fixture / "SYMPTOM.md")
  doAssert ca.ok
  doAssert ca.sourceIds.len >= 1
  echo "legacy_e2e_bugfix_context: ok"
else:
  echo "legacy_e2e_bugfix_context: skipped"

block nestedSrcCollection:
  let realFix = root / "fixtures" / "e2e_real_unknown_module"
  let ctx = buildApiContext(realFix / "repo", realFix / "SYMPTOM.md")
  doAssert ctx.ok, ctx.error
  doAssert "src/glob.nim" in ctx.sourceIds
  doAssert "src/glob/regexer.nim" in ctx.sourceIds,
    "nested package modules must be collected without flattening: " & $ctx.sourceIds
  doAssert not ctx.userPrompt.contains("historical_fix")
  doAssert not ctx.userPrompt.contains("shouldDescend")
  doAssert not ctx.userPrompt.contains("oracle_glob_walk")
  echo "nested_src_collection: ok sources=", ctx.sourceIds.join(",")

echo "legacy smoke done"
