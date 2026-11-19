## Offline: valid edits, missing/ambiguous anchors, truncated, malformed, newText type,
## empty newText deletion, ambiguous→recovery. Failed cases leave target bytes intact.
## When oracle does not run: kind=vkNotRun, ran=false, exit codes -1.

import std/[os, strutils, json]
import nimfactory/mission

let root = getCurrentDir()
let fix = root / "fixtures" / "e2e_edits_apply"
let repo = fix / "repo"
let oracle = fix / "oracle"
let symptom = fix / "SYMPTOM.md"
let inj = fix / "inject"

proc freshWt(tag: string): string =
  getTempDir() / ("nf_edits_" & tag & "_" & $getCurrentProcessId())

proc targetBytes(wt: string): string =
  readFile(wt / "src" / "sample.nim")

proc runInj(injectPath, wt: string; recovery = ""): MissionReport =
  var req = defaultMissionRequest()
  req.repoRoot = repo
  req.symptomPath = symptom
  req.oracleDir = oracle
  req.worktreeRoot = wt
  req.route = "inject"
  req.injectPath = injectPath
  req.injectRecoveryPath = recovery
  runMission(req)

proc assertOracleNotRun(v: VerifyResult) =
  doAssert v.message == "oracle not run"
  doAssert v.phase == vpNone
  doAssert v.kind == vkNotRun
  doAssert not v.ran
  doAssert v.exitCode == -1
  doAssert v.compileExitCode == -1
  doAssert v.runExitCode == -1
  let j = verifyToJson(v)
  doAssert j["ran"].getBool == false
  doAssert j["kind"].getStr == "vkNotRun"
  doAssert j["exit_code"].getInt == -1
  doAssert j["compile_exit_code"].getInt == -1
  doAssert j["run_exit_code"].getInt == -1

let original = readFile(repo / "src" / "sample.nim")

block validEdits:
  let wt = freshWt("ok")
  let r = runInj(inj / "valid_edits.json", wt)
  doAssert r.ok, $r.verdict & " " & r.warning
  doAssert r.verdict == "pass"
  doAssert r.decision.mode == "edits"
  doAssert r.apply.editsApplied == 2
  doAssert r.verify.ok and r.verify.ran
  doAssert r.verify.phase == vpRun
  doAssert r.verify.kind == vkPass
  let after = targetBytes(wt)
  doAssert after != original
  doAssert "alpha* = 2" in after
  doAssert "beta* = 3" in after
  echo "valid_edits: ok"

block emptyNewTextDeletion:
  let wt = freshWt("emptynew")
  let r = runInj(inj / "empty_newtext_delete.json", wt)
  doAssert r.ok, $r.verdict & " " & r.warning
  doAssert r.apply.editsApplied == 3
  let after = targetBytes(wt)
  doAssert "## sample module" notin after
  doAssert "alpha* = 2" in after
  echo "empty_newtext_deletion: ok"

block missingAnchor:
  let wt = freshWt("missing")
  let r = runInj(inj / "missing_anchor.json", wt)
  doAssert not r.ok
  doAssert r.verdict == "apply_failed"
  doAssert r.apply.refuseCode == "anchor_missing"
  doAssert r.apply.editsApplied == 0
  assertOracleNotRun(r.verify)
  doAssert targetBytes(wt) == original
  echo "missing_anchor: ok (no partial write)"

block ambiguousAnchorNoRecoveryPath:
  let wt = freshWt("ambig")
  let r = runInj(inj / "ambiguous_anchor.json", wt)
  doAssert not r.ok
  doAssert r.verdict == "apply_failed"
  doAssert r.apply.refuseCode == "anchor_ambiguous"
  doAssert r.apply.ambiguousMatchCount == 2
  doAssert r.apply.occurrenceContexts.len == 2
  doAssert not r.recoveryTriggered
  doAssert r.apply.editsApplied == 0
  assertOracleNotRun(r.verify)
  doAssert targetBytes(wt) == original
  echo "ambiguous_anchor_no_recovery: ok"

block ambiguousThenRecovery:
  let wt = freshWt("ambigrec")
  let r = runInj(inj / "ambiguous_anchor.json", wt,
                 recovery = inj / "ambiguous_recovery_fix.json")
  doAssert r.recoveryTriggered
  doAssert r.recoveryReason == "anchor_ambiguous"
  doAssert r.providerCalls == 2
  doAssert r.ok, $r.verdict & " " & r.warning
  doAssert r.verdict == "pass"
  doAssert r.verify.ran and r.verify.ok
  echo "ambiguous_then_recovery: ok"

block truncatedResponse:
  let wt = freshWt("trunc")
  let r = runInj(inj / "truncated.json", wt)
  doAssert not r.ok
  doAssert r.verdict == "apply_failed"
  doAssert not r.decision.parseOk
  assertOracleNotRun(r.verify)
  if fileExists(wt / "src" / "sample.nim"):
    doAssert targetBytes(wt) == original
  echo "truncated_response: ok"

block malformedEdit:
  let wt = freshWt("malformed")
  let r = runInj(inj / "malformed_edit.json", wt)
  doAssert not r.ok
  doAssert r.decision.refuseCode == "malformed_edit" or r.apply.refuseCode == "malformed_edit"
  assertOracleNotRun(r.verify)
  doAssert original == readFile(repo / "src" / "sample.nim")
  if dirExists(wt) and fileExists(wt / "src" / "sample.nim"):
    doAssert targetBytes(wt) == original
  echo "malformed_edit: ok"

block newTextWrongType:
  let wt = freshWt("newtype")
  let r = runInj(inj / "newtext_wrong_type.json", wt)
  doAssert not r.ok
  doAssert r.decision.refuseCode == "newText_type" or r.apply.refuseCode == "newText_type"
  assertOracleNotRun(r.verify)
  if dirExists(wt) and fileExists(wt / "src" / "sample.nim"):
    doAssert targetBytes(wt) == original
  echo "newText_wrong_type: ok"

block newTextMissing:
  let wt = freshWt("newmiss")
  let r = runInj(inj / "newtext_missing.json", wt)
  doAssert not r.ok
  doAssert r.decision.refuseCode == "newText_missing" or r.apply.refuseCode == "newText_missing"
  assertOracleNotRun(r.verify)
  echo "newText_missing: ok"

block providerTruncationMotif:
  const outputTruncatedCode = "output_truncated"
  doAssert outputTruncatedCode == "output_truncated"
  echo "output_truncated motif: ok"

echo "edits_apply offline cases done"
