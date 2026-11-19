## Deterministic mission tests (context discrimination + inject path).
## Inject does NOT qualify the LLM decision function.

import std/[os, strutils, json]
import nimfactory/mission

let root = getCurrentDir()
let fixture = root / "fixtures" / "e2e_bugfix"
let variantA = fixture / "variant_a"
let variantB = fixture / "variant_b"
let oracle = fixture / "oracle"
let symptom = fixture / "SYMPTOM.md"

block contextDiffers:
  let ca = buildApiContext(variantA, symptom)
  let cb = buildApiContext(variantB, symptom)
  doAssert "src/normalize.nim" in ca.sourceIds
  doAssert "src/util_misc.nim" in ca.sourceIds
  doAssert not ca.userPrompt.contains("oracle")
  doAssert not ca.userPrompt.contains("doAssert normalize")
  doAssert ca.userPrompt.contains("Buggy normalize — variant A")
  doAssert cb.userPrompt.contains("Buggy normalize — variant B")
  doAssert ca.userPrompt != cb.userPrompt
  let la = buildLocalMicroPatchContext(variantA, symptom)
  doAssert la.systemPrompt != ca.systemPrompt
  doAssert la.userPrompt.contains("Local micro-patch")
  echo "contextDiffers: ok"

block injectPassA:
  let wt = fixture / ".wt_a"
  var req = defaultMissionRequest()
  req.repoRoot = variantA
  req.symptomPath = symptom
  req.oracleDir = oracle
  req.worktreeRoot = wt
  req.route = "inject"
  req.injectPath = fixture / "inject" / "variant_a.json"
  let r = runMission(req)
  doAssert r.ok, r.warning & " / " & $reportToJson(r)
  doAssert r.decision.targetFile == "src/normalize.nim"
  doAssert r.verify.ok
  echo "injectPassA: ok"

block injectPassB:
  let wt = fixture / ".wt_b"
  var req = defaultMissionRequest()
  req.repoRoot = variantB
  req.symptomPath = symptom
  req.oracleDir = oracle
  req.worktreeRoot = wt
  req.route = "inject"
  req.injectPath = fixture / "inject" / "variant_b.json"
  let r = runMission(req)
  doAssert r.ok, r.warning & " / " & $reportToJson(r)
  echo "injectPassB: ok"

block wrongTargetFails:
  let wt = fixture / ".wt_wrong"
  var req = defaultMissionRequest()
  req.repoRoot = variantA
  req.symptomPath = symptom
  req.oracleDir = oracle
  req.worktreeRoot = wt
  req.route = "inject"
  req.injectPath = fixture / "inject" / "wrong_target.json"
  let r = runMission(req)
  doAssert not r.ok
  doAssert r.verdict in ["verify_failed", "apply_failed"]
  echo "wrongTargetFails: ok"

block apiUnavailableWithoutKey:
  putEnv("OPENAI_API_KEY", "")
  var req = defaultMissionRequest()
  req.repoRoot = variantA
  req.symptomPath = symptom
  req.oracleDir = oracle
  req.worktreeRoot = fixture / ".wt_api"
  req.route = "api"
  let r = runMission(req)
  doAssert not r.ok
  doAssert r.verdict == "api_unavailable"
  doAssert r.untested.len > 0
  doAssert r.warning.contains("Quentin")
  echo "apiUnavailableWithoutKey: ok"

echo "ALL mission deterministic tests passed"
