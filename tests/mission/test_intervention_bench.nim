## Deterministic bench: oracle behaviour, worktree safety, intervention discrimination.
## Does not spend API credits.

import std/[os, strutils, json]
import nimfactory/mission

let root = getCurrentDir()
let fix = root / "fixtures" / "e2e_intervention"
let repoA = fix / "repo_a"
let repoB = fix / "repo_b"
let oracle = fix / "oracle"
let oracleFalse = fix / "oracle_false"
let symptom = fix / "SYMPTOM.md"
let inj = fix / "inject"

proc freshWt(tag: string): string =
  getTempDir() / ("nf_bench_" & tag & "_" & $getCurrentProcessId())

proc runInject(repo, injectPath, wt: string; oracleDir = oracle): MissionReport =
  var req = defaultMissionRequest()
  req.repoRoot = repo
  req.symptomPath = symptom
  req.oracleDir = oracleDir
  req.worktreeRoot = wt
  req.route = "inject"
  req.injectPath = injectPath
  runMission(req)

block oracleMissing:
  var req = defaultMissionRequest()
  req.repoRoot = repoA
  req.symptomPath = symptom
  req.oracleDir = fix / "oracle_does_not_exist"
  req.worktreeRoot = freshWt("miss")
  req.route = "inject"
  req.injectPath = inj / "ref_fix_a.json"
  let r = runMission(req)
  doAssert not r.ok
  doAssert r.verdict == "oracle_missing"
  doAssert r.warning.contains("not found")
  echo "oracleMissing: ok"

block oracleFalseFails:
  let r = runInject(repoA, inj / "ref_fix_a.json", freshWt("false"), oracleFalse)
  doAssert not r.ok, $reportToJson(r)
  doAssert r.verdict == "verify_failed"
  echo "oracleFalseFails: ok"

block oracleSatisfied:
  let r = runInject(repoA, inj / "ref_fix_a.json", freshWt("ok"), oracle)
  doAssert r.ok, r.warning & " " & $reportToJson(r)
  echo "oracleSatisfied: ok"

block worktreeRefuseOccupied:
  let wt = freshWt("occ")
  createDir(wt)
  writeFile(wt / "marker.txt", "keep")
  var req = defaultMissionRequest()
  req.repoRoot = repoA
  req.symptomPath = symptom
  req.oracleDir = oracle
  req.worktreeRoot = wt
  req.route = "inject"
  req.injectPath = inj / "ref_fix_a.json"
  let r = runMission(req)
  doAssert not r.ok
  doAssert r.verdict == "apply_failed"
  doAssert r.apply.message.contains("occupied")
  doAssert fileExists(wt / "marker.txt")
  echo "worktreeRefuseOccupied: ok"

block contextNoDefaultSpec:
  let ca = buildApiContext(repoA, symptom)
  let cb = buildApiContext(repoB, symptom)
  doAssert ca.ok and cb.ok
  doAssert "src/textutil.nim" in ca.sourceIds
  doAssert "src/labels.nim" in ca.sourceIds
  doAssert "src/logging.nim" in ca.sourceIds
  doAssert not ca.userPrompt.contains("normalize")
  doAssert not ca.userPrompt.contains("oracle")
  doAssert not ca.userPrompt.contains("doAssert")
  doAssert ca.userPrompt != cb.userPrompt
  let bad = buildApiContext(repoA, "")
  # repo has no SYMPTOM.md inside — should fail without inventing a spec
  doAssert not bad.ok
  doAssert bad.error.contains("symptom required")
  echo "contextNoDefaultSpec: ok"

block originalsFail:
  # Apply a no-op-ish wrong target so we still exercise verify on originals:
  # copy repo by applying wrong target then check... better: use runOracle on a copy.
  let wtA = freshWt("origA")
  createDir(wtA)
  copyRepoToWorktree(repoA, wtA)
  let vA = runOracle(wtA, oracle)
  doAssert not vA.ok, "repo_a original should fail oracle"
  let wtB = freshWt("origB")
  createDir(wtB)
  copyRepoToWorktree(repoB, wtB)
  let vB = runOracle(wtB, oracle)
  doAssert not vB.ok, "repo_b original should fail oracle"
  echo "originalsFail: ok"

block referenceFixesPass:
  let a = runInject(repoA, inj / "ref_fix_a.json", freshWt("refA"))
  doAssert a.ok and a.decision.targetFile == "src/textutil.nim", $reportToJson(a)
  let b = runInject(repoB, inj / "ref_fix_b.json", freshWt("refB"))
  doAssert b.ok and b.decision.targetFile == "src/labels.nim", $reportToJson(b)
  echo "referenceFixesPass: ok"

block crossFixesFail:
  let aOnB = runInject(repoB, inj / "ref_fix_a.json", freshWt("crossAB"))
  doAssert not aOnB.ok, "fix_a on repo_b must fail"
  doAssert aOnB.verdict in ["verify_failed", "apply_failed"]
  let bOnA = runInject(repoA, inj / "ref_fix_b.json", freshWt("crossBA"))
  doAssert not bOnA.ok, "fix_b on repo_a must fail"
  doAssert bOnA.verdict in ["verify_failed", "apply_failed"]
  echo "crossFixesFail: ok"

block wrongTargetFails:
  let r = runInject(repoA, inj / "wrong_target.json", freshWt("wrong"))
  doAssert not r.ok
  echo "wrongTargetFails: ok"

block localRequiresEstablishedTarget:
  let ctx = buildLocalMicroPatchContext(repoA, symptom, "", "", "")
  doAssert not ctx.ok
  let ctx2 = buildLocalMicroPatchContext(
    repoA, symptom, "src/textutil.nim",
    "blank detection misses empty string",
    "keep isBlank/trimText signatures")
  doAssert ctx2.ok
  doAssert ctx2.sourceIds == @["src/textutil.nim"]
  doAssert not ctx2.userPrompt.contains("src/labels.nim")
  echo "localRequiresEstablishedTarget: ok"

block apiUnavailableWithoutKey:
  putEnv("OPENAI_API_KEY", "")
  var req = defaultMissionRequest()
  req.repoRoot = repoA
  req.symptomPath = symptom
  req.oracleDir = oracle
  req.worktreeRoot = freshWt("api")
  req.route = "api"
  let r = runMission(req)
  doAssert not r.ok
  doAssert r.verdict == "api_unavailable"
  echo "apiUnavailableWithoutKey: ok"

echo "ALL intervention bench tests passed"
