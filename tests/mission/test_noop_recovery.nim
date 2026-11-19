## Offline qualification of the single no-op recovery path (no API spend).

import std/[os, json]
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
  doAssert r.providerCalls == 2, $r.providerCalls
  doAssert r.attempts.len == 2
  doAssert r.attempts[0].role == "initial"
  doAssert r.attempts[0].apply.identicalToOriginal
  doAssert not r.attempts[0].effectiveChange
  doAssert r.attempts[1].role == "noop_recovery"
  doAssert r.attempts[1].effectiveChange
  doAssert r.attempts[1].decision.targetFile == "src/textutil.nim"
  doAssert r.ok and r.verdict == "pass", $reportToJson(r)
  echo "noopTriggersRecoveryThenPass: ok"

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
  doAssert r.recoveryAttempted
  doAssert r.verdict == "model_cannot_fix"
  doAssert not r.ok
  doAssert r.attempts.len == 2
  doAssert r.attempts[1].cannotFix
  echo "stopsAfterSecondAttemptCannotFix: ok"

block stopsAfterSecondNoop:
  # Recovery also no-op → apply_failed, no third call.
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
  doAssert not r.ok
  echo "stopsAfterSecondNoop: ok"

block noRecoveryCallAfterInitialSuccess:
  var req = defaultMissionRequest()
  req.repoRoot = repoA
  req.symptomPath = symptom
  req.oracleDir = oracle
  req.worktreeRoot = freshWt("rec_success")
  req.route = "inject"
  req.injectPath = inj / "ref_fix_a.json"
  req.injectRecoveryPath = inj / "recovery_textutil_a.json" # must not be used
  let r = runMission(req)
  doAssert r.ok and r.verdict == "pass"
  doAssert r.providerCalls == 1, $r.providerCalls
  doAssert not r.recoveryTriggered
  doAssert not r.recoveryAttempted
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
  # no injectRecoveryPath
  let r = runMission(req)
  doAssert r.providerCalls == 1
  doAssert not r.recoveryAttempted
  doAssert r.verdict == "apply_failed"
  echo "noRecoveryWithoutPathOnInject: ok"

echo "ALL noop recovery offline tests passed"
