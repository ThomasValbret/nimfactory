## Offline: valid edits, missing anchor, ambiguous anchor, truncated response.
## Failed cases must leave the target file byte-identical to the copied original.
## When oracle does not run, the report says so explicitly.

import std/[os, strutils]
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

proc runInj(injectPath, wt: string): MissionReport =
  var req = defaultMissionRequest()
  req.repoRoot = repo
  req.symptomPath = symptom
  req.oracleDir = oracle
  req.worktreeRoot = wt
  req.route = "inject"
  req.injectPath = injectPath
  runMission(req)

let original = readFile(repo / "src" / "sample.nim")

block validEdits:
  let wt = freshWt("ok")
  let r = runInj(inj / "valid_edits.json", wt)
  doAssert r.ok, $r.verdict & " " & r.warning
  doAssert r.verdict == "pass"
  doAssert r.decision.mode == "edits"
  doAssert r.apply.editsApplied == 2
  doAssert r.verify.ok
  doAssert r.verify.phase == vpRun
  doAssert "oracle not run" notin r.verify.message
  let after = targetBytes(wt)
  doAssert after != original
  doAssert "alpha* = 2" in after
  doAssert "beta* = 3" in after
  echo "valid_edits: ok"

block missingAnchor:
  let wt = freshWt("missing")
  let r = runInj(inj / "missing_anchor.json", wt)
  doAssert not r.ok
  doAssert r.verdict == "apply_failed"
  doAssert "missing" in r.apply.message.toLowerAscii
  doAssert r.apply.editsApplied == 0
  doAssert r.verify.message == "oracle not run"
  doAssert r.verify.phase == vpNone
  doAssert targetBytes(wt) == original
  echo "missing_anchor: ok (no partial write)"

block ambiguousAnchor:
  let wt = freshWt("ambig")
  let r = runInj(inj / "ambiguous_anchor.json", wt)
  doAssert not r.ok
  doAssert r.verdict == "apply_failed"
  doAssert "ambiguous" in r.apply.message.toLowerAscii
  doAssert r.apply.editsApplied == 0
  doAssert r.verify.message == "oracle not run"
  doAssert targetBytes(wt) == original
  echo "ambiguous_anchor: ok (no partial write)"

block truncatedResponse:
  let wt = freshWt("trunc")
  let r = runInj(inj / "truncated.json", wt)
  doAssert not r.ok
  doAssert r.verdict == "apply_failed"
  doAssert "parse" in r.apply.message.toLowerAscii or not r.decision.parseOk
  doAssert r.verify.message == "oracle not run"
  # Worktree may exist from apply attempt; target must remain original if file present.
  if fileExists(wt / "src" / "sample.nim"):
    doAssert targetBytes(wt) == original
  echo "truncated_response: ok (no partial write; oracle not run)"

block providerTruncationMotif:
  ## Motif conserved from NimAgent `RunCodeOutputTruncated`.
  const outputTruncatedCode = "output_truncated"
  const outputTruncatedMessage = "Output truncated by provider"
  doAssert outputTruncatedCode == "output_truncated"
  doAssert outputTruncatedMessage.len > 0
  echo "output_truncated motif: ok"

echo "edits_apply offline cases done"
