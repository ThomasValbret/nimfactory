## Legacy fixture smoke retained for prior API proof artifacts (e2e_bugfix).
## Intervention-choice qualification lives in test_intervention_bench.nim.

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

echo "legacy smoke done"
