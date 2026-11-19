## Green reception: the three resume defects must be absent after the corrective.
## Exit 0 only when all three classes are fixed; non-zero otherwise.
import std/[os, json, strutils]
import nimfactory

var failures = 0

proc check(id: string; ok: bool; detail: JsonNode) =
  if not ok: inc failures
  echo $(%*{"check": id, "ok": ok, "detail": detail})

proc tmpDb(name: string): string =
  let p = getCurrentDir() / "build" / "m1-defect-green" / (name & ".sqlite")
  createDir(p.parentDir)
  if fileExists(p): removeFile(p)
  p

let g = graphFromJson(parseJson(readFile("recipes/m1_diamond.json")))
let reg = newExecutableRegistry()
registerDemoHandlers(reg)
let input = parseJson(readFile("tests/fixtures/m1/input.json"))

block G1_stable_transition_ids:
  let db = tmpDb("g1")
  let s = newSqliteRunStore(db)
  var cfg = defaultExecConfig()
  cfg.checkpointAfter = 1
  let r1 = runGraph(s, reg, g, "g1", input, cfg)
  doAssert r1.status == esInterrupted
  let rec1 = s.recover("g1")
  var bad: seq[string] = @[]
  var sawAct = false
  for e in rec1["events"]:
    let tid = e{"transition_id"}.getStr(e{"body"}{"transition_id"}.getStr(""))
    if tid.startsWith("tx-") and tid != "tx-start":
      bad.add(tid)
    if tid == "act:split:main": sawAct = true
  s.close()
  let s2 = newSqliteRunStore(db)
  cfg.checkpointAfter = 0
  discard resumeGraph(s2, reg, g, "g1", cfg)
  let rec2 = s2.recover("g1")
  for e in rec2["events"]:
    let tid = e{"transition_id"}.getStr(e{"body"}{"transition_id"}.getStr(""))
    if tid.startsWith("tx-") and tid != "tx-start":
      bad.add(tid)
  check("G1_stable_matched_transition_ids", bad.len == 0 and sawAct,
        %*{"bad": bad, "saw_act_split": sawAct})
  s2.close()

block G2_durable_outputs_and_unknown_refuse:
  let db = tmpDb("g2")
  let s = newSqliteRunStore(db)
  var cfg = defaultExecConfig()
  cfg.checkpointAfter = 5
  let r = runGraph(s, reg, g, "g2", input, cfg)
  let displayed = r.outputs
  let rec = s.recover("g2")
  let durableOut = rec{"state"}{"outputs"}
  let match = not displayed.isNil and durableOut.kind == JObject and
              $durableOut == $displayed and displayed.len > 0
  var unknownRaised = false
  var created = false
  try:
    discard resumeGraph(s, reg, g, "never-existed-m1", defaultExecConfig())
  except FactoryError:
    unknownRaised = true
  created = s.hasRun("never-existed-m1")
  check("G2_durable_outputs_unknown_refused",
        match and unknownRaised and not created,
        %*{
          "status": $r.status,
          "match": match,
          "unknown_raised": unknownRaised,
          "created": created,
          "durable_keys": if durableOut.isNil: 0 else: durableOut.len
        })
  s.close()

block G3_concurrency_and_second_resume:
  let db = tmpDb("g3")
  let s = newSqliteRunStore(db)
  var cfg = defaultExecConfig()
  cfg.mode = emConcurrent
  cfg.maxConcurrency = 2
  let r1 = runGraph(s, reg, g, "g3", input, cfg)
  doAssert r1.status == esCompleted
  let peak = r1.peakConcurrentInvocations
  s.close()
  resetInvocationMetrics()
  let s2 = newSqliteRunStore(db)
  let r2 = resumeGraph(s2, reg, g, "g3", defaultExecConfig())
  let r3 = resumeGraph(s2, reg, g, "g3", defaultExecConfig())
  check("G3_real_peak_and_idempotent_resume",
        peak >= 2 and r2.status == esCompleted and r3.status == esCompleted and
        $r2.outputs == $r3.outputs and peakConcurrentInvocations() == 0,
        %*{
          "peak": peak,
          "resume2": $r2.status,
          "resume3": $r3.status,
          "second_peak": peakConcurrentInvocations()
        })
  s2.close()

echo $(%*{"summary": "m1_resume_defects_green", "failures": failures})
quit(if failures == 0: 0 else: 1)
