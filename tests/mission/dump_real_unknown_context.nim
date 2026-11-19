## Dump buildApiContext JSON for the real unknown-module fixture (campaign inspection).
import std/[os, json]
import nimfactory/mission

let root = getCurrentDir()
let fix = root / "fixtures" / "e2e_real_unknown_module"
let ctx = buildApiContext(fix / "repo", fix / "SYMPTOM.md")
echo pretty(contextToJson(ctx))
