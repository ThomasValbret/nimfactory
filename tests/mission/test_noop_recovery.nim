## Offline qualification of recovery (no-op + functional-fail), ceiling of 2 calls.

import std/[os, strutils, json]
import nimfactory/mission

let root = getCurrentDir()
let fix = root / "fixtures" / "e2e_intervention"
let repoA = fix / "repo_a"
let oracle = fix / "oracle"
let symptom = fix / "SYMPTOM.md"
let inj = fix / "inject"

proc freshWt(tag: string): string =
  getTempDir() / ("nf_rec_" & tag & "_" & $getCurrentProcessId())

block noopTriggersRecoveryThenPass:
  var req = defaultMissionRequest()
  req.repoRoot = repoA
  req.symptomPath = symptom
  req.oracleDir = oracle
  req.worktreeRoot = freshWt("rec_ok")
  req.route = "inject"
  req.injectPath = inj / "noop_labels_a.json"
  req.injectRecoveryPath = inj / "recovery_textutil_a.json"
  let r = runMission(req)
  doAssert r.recoveryTriggered
  doAssert r.recoveryAttempted
  doAssert r.recoveryReason == "noop"
  doAssert r.providerCalls == 2, $r.providerCalls
  doAssert r.attempts.len == 2
  doAssert r.attempts[0].role == "initial"
  doAssert r.attempts[0].apply.identicalToOriginal
  doAssert r.attempts[1].role == "recovery"
  doAssert r.attempts[1].decision.targetFile == "src/textutil.nim"
  doAssert r.ok and r.verdict == "pass", $reportToJson(r)
  echo "noopTriggersRecoveryThenPass: ok"

block functionalFailTriggersRecovery:
  var req = defaultMissionRequest()
  req.repoRoot = repoA
  req.symptomPath = symptom
  req.oracleDir = oracle
  req.worktreeRoot = freshWt("rec_func")
  req.route = "inject"
  req.injectPath = inj / "historical_a_20261119T110158Z.json"
  req.injectRecoveryPath = inj / "recovery_textutil_a.json"
  let r = runMission(req)
  doAssert r.providerCalls == 2, $r.providerCalls
  doAssert r.recoveryTriggered
  doAssert r.recoveryReason == "functional_fail"
  doAssert r.attempts[0].effectiveChange
  doAssert r.attempts[0].verify.kind == vkFunctionalFail
  doAssert r.attempts[1].role == "recovery"
  doAssert r.ok and r.verdict == "pass", $reportToJson(r)
  # Recovery context must not leak oracle / expected target / variant names.
  let prompt = buildRecoveryContext(
    buildApiContext(repoA, symptom),
    "src/labels.nim", "d", "body", "functional check still fails").userPrompt
  doAssert not prompt.contains("doAssert")
  doAssert not prompt.contains("oracle")
  doAssert not prompt.contains("repo_a")
  doAssert not prompt.contains("variant")
  doAssert not prompt.contains("reference")
  echo "functionalFailTriggersRecovery: ok"

block compileErrorNoRecovery:
  var req = defaultMissionRequest()
  req.repoRoot = repoA
  req.symptomPath = symptom
  req.oracleDir = oracle
  req.worktreeRoot = freshWt("rec_compile")
  req.route = "inject"
  req.injectPath = inj / "compile_break_labels.json"
  req.injectRecoveryPath = inj / "recovery_textutil_a.json"
  let r = runMission(req)
  doAssert r.providerCalls == 1, $r.providerCalls
  doAssert not r.recoveryAttempted
  doAssert r.verdict == "compile_failed"
  doAssert r.attempts[0].verify.kind == vkCompileError
  echo "compileErrorNoRecovery: ok"

block stopsAfterSecondAttemptCannotFix:
  var req = defaultMissionRequest()
  req.repoRoot = repoA
  req.symptomPath = symptom
  req.oracleDir = oracle
  req.worktreeRoot = freshWt("rec_cannot")
  req.route = "inject"
  req.injectPath = inj / "noop_labels_a.json"
  req.injectRecoveryPath = inj / "recovery_cannot.json"
  let r = runMission(req)
  doAssert r.providerCalls == 2
  doAssert r.verdict == "model_cannot_fix"
  doAssert r.attempts[1].cannotFix
  echo "stopsAfterSecondAttemptCannotFix: ok"

block stopsAfterSecondNoop:
  var req = defaultMissionRequest()
  req.repoRoot = repoA
  req.symptomPath = symptom
  req.oracleDir = oracle
  req.worktreeRoot = freshWt("rec_noop2")
  req.route = "inject"
  req.injectPath = inj / "noop_labels_a.json"
  req.injectRecoveryPath = inj / "noop_labels_a.json"
  let r = runMission(req)
  doAssert r.providerCalls == 2
  doAssert r.verdict == "apply_failed"
  echo "stopsAfterSecondNoop: ok"

block noRecoveryCallAfterInitialSuccess:
  var req = defaultMissionRequest()
  req.repoRoot = repoA
  req.symptomPath = symptom
  req.oracleDir = oracle
  req.worktreeRoot = freshWt("rec_success")
  req.route = "inject"
  req.injectPath = inj / "ref_fix_a.json"
  req.injectRecoveryPath = inj / "recovery_textutil_a.json"
  let r = runMission(req)
  doAssert r.ok and r.verdict == "pass"
  doAssert r.providerCalls == 1, $r.providerCalls
  doAssert not r.recoveryTriggered
  doAssert r.attempts.len == 1
  echo "noRecoveryCallAfterInitialSuccess: ok"

block noRecoveryWithoutPathOnInject:
  var req = defaultMissionRequest()
  req.repoRoot = repoA
  req.symptomPath = symptom
  req.oracleDir = oracle
  req.worktreeRoot = freshWt("rec_nopath")
  req.route = "inject"
  req.injectPath = inj / "noop_labels_a.json"
  let r = runMission(req)
  doAssert r.providerCalls == 1
  doAssert not r.recoveryAttempted
  doAssert r.verdict == "apply_failed"
  echo "noRecoveryWithoutPathOnInject: ok"

echo "ALL recovery offline tests passed"
