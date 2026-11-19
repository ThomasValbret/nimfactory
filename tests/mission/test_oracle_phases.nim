## Before/after classification: quit(1) vs static doAssert; recovery gating.

import std/[os, json]
import nimfactory/mission

let root = getCurrentDir()
let fix = root / "fixtures" / "e2e_intervention"
let repoA = fix / "repo_a"
let symptom = fix / "SYMPTOM.md"
let inj = fix / "inject"

proc freshWt(tag: string): string =
  getTempDir() / ("nf_phase_" & tag & "_" & $getCurrentProcessId())

block quit1IsFunctionalFailAllowsRecovery:
  ## Apply a real fix so sources compile; oracle then quit(1) at run phase.
  var req = defaultMissionRequest()
  req.repoRoot = repoA
  req.symptomPath = symptom
  req.oracleDir = fix / "oracle_quit1"
  req.worktreeRoot = freshWt("quit1")
  req.route = "inject"
  req.injectPath = inj / "ref_fix_a.json"
  req.injectRecoveryPath = inj / "recovery_cannot.json"
  let r = runMission(req)
  doAssert r.attempts.len >= 1
  let v0 = r.attempts[0].verify
  doAssert v0.phase == vpRun, $v0.phase
  doAssert v0.kind == vkFunctionalFail, $v0.kind
  doAssert v0.compileExitCode == 0
  doAssert v0.runExitCode == 1
  doAssert r.recoveryTriggered
  doAssert r.recoveryReason == "functional_fail"
  doAssert r.providerCalls == 2
  doAssert r.verdict == "model_cannot_fix"  # recovery inject cannot_fix
  echo "quit1IsFunctionalFailAllowsRecovery: ok"

block staticAssertIsCompileFailedNoRecovery:
  var req = defaultMissionRequest()
  req.repoRoot = repoA
  req.symptomPath = symptom
  req.oracleDir = fix / "oracle_static_fail"
  req.worktreeRoot = freshWt("static")
  req.route = "inject"
  req.injectPath = inj / "ref_fix_a.json"
  req.injectRecoveryPath = inj / "recovery_textutil_a.json"
  let r = runMission(req)
  doAssert r.providerCalls == 1, $r.providerCalls
  doAssert not r.recoveryAttempted
  doAssert r.verdict == "compile_failed"
  let v0 = r.attempts[0].verify
  doAssert v0.phase == vpCompile, $v0.phase
  doAssert v0.kind == vkCompileError, $v0.kind
  doAssert v0.compileExitCode != 0
  doAssert v0.runExitCode == -1
  echo "staticAssertIsCompileFailedNoRecovery: ok"

block successStillOneCall:
  var req = defaultMissionRequest()
  req.repoRoot = repoA
  req.symptomPath = symptom
  req.oracleDir = fix / "oracle"
  req.worktreeRoot = freshWt("ok")
  req.route = "inject"
  req.injectPath = inj / "ref_fix_a.json"
  req.injectRecoveryPath = inj / "recovery_cannot.json"
  let r = runMission(req)
  doAssert r.ok and r.verdict == "pass"
  doAssert r.providerCalls == 1
  doAssert r.attempts[0].verify.phase == vpRun
  doAssert r.attempts[0].verify.kind == vkPass
  echo "successStillOneCall: ok"

echo "ALL oracle phase tests passed"
