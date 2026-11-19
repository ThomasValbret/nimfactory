## F5: diamond wait/cap1 resume, durable start, false-completed legacy DBs.
import std/[os, json, strutils, osproc]
import nimfactory

proc tmpStore(name: string): string =
  let base = getCurrentDir() / "build" / "f5-resume3-tmp"
  createDir(base)
  result = base / (name & ".sqlite")
  if fileExists(result): removeFile(result)
  let spill = result & ".spill"
  if dirExists(spill): removeDir(spill)

proc registry(): ExecutableRegistry =
  result = newExecutableRegistry()
  registerDemoHandlers(result)

let diamond = graphFromJson(parseJson(readFile("recipes/m1_diamond.json")))
let twoGraph = graphFromJson(parseJson(readFile("recipes/m1_two_inputs.json")))
let joinGraph = graphFromJson(parseJson(readFile("recipes/m1_two_inputs_join.json")))
let dInput = parseJson(readFile("tests/fixtures/m1/input.json"))
let twoInput = parseJson(readFile("tests/fixtures/m1/two_inputs.json"))
let oracle = parseJson(readFile("tests/fixtures/m1/oracle_outputs.json"))
let wantBranches = @[oracle{"expected_result"}{"branch_order"}[0].getStr(),
                     oracle{"expected_result"}{"branch_order"}[1].getStr()]

proc branches(o: JsonNode): seq[string] =
  result = @[]
  for it in o{"result"}{"items"}: result.add(it{"branch"}.getStr())

block diamondWaitCap1AllCheckpoints:
  for mode in [emSequential, emConcurrent]:
    for n in 1..5:
      let db = tmpStore("diam-" & $mode & "-" & $n)
      let s1 = newSqliteRunStore(db)
      var cfg = defaultExecConfig()
      cfg.mode = mode
      cfg.maxConcurrency = 2
      cfg.pipeCapacity = 1
      cfg.pipePolicy = ppWait
      cfg.checkpointAfter = n
      let r1 = runGraph(s1, registry(), diamond, "d-" & $n, dInput, cfg)
      doAssert r1.status == esInterrupted, $mode & " ckpt " & $n & " " & $r1.status
      s1.close()
      let s2 = newSqliteRunStore(db)
      cfg.checkpointAfter = 0
      let r2 = resumeGraph(s2, registry(), diamond, "d-" & $n, cfg)
      doAssert r2.status == esCompleted, $mode & " resume ckpt " & $n & " " & $r2.status
      doAssert branches(r2.outputs) == wantBranches
      let insp = s2.recover("d-" & $n)
      doAssert $insp{"state"}{"outputs"} == $r2.outputs
      resetInvocationMetrics()
      let r3 = resumeGraph(s2, registry(), diamond, "d-" & $n, cfg)
      doAssert $r3.outputs == $r2.outputs
      doAssert peakConcurrentInvocations() == 0
      s2.close()

block durableStartCrashThenResume:
  ## Stop after run:start (no activation commit); resume without re-feeding input.
  let g = graphFromJson(%*{
    "schema": "nimfactory.graph/0.1",
    "graph_id": "start-crash",
    "version": 1,
    "nodes": [
      {"id": "first", "handler": "demo.slow@0.1"},
      {"id": "second", "handler": "noop.passthrough@0.1"}
    ],
    "entrypoints": [
      {"input": "a", "to": "first.in"},
      {"input": "b", "to": "second.in"}
    ],
    "edges": [],
    "outputs": {"one": "first.out", "two": "second.out"},
    "loop_specs": []
  })
  let inputs = %*{"a": {"v": "alpha"}, "b": {"v": "beta"}}
  let db = tmpStore("start-crash")
  let s1 = newSqliteRunStore(db)
  # Continuous oracle
  let cont = runGraph(newSqliteRunStore(tmpStore("start-cont")), registry(), g,
                      "cont", inputs, defaultExecConfig())
  doAssert cont.status == esCompleted
  # Crash after start only
  discard beginGraphRun(s1, registry(), g, "crash", inputs, defaultExecConfig())
  s1.close()  # process boundary
  let s2 = newSqliteRunStore(db)
  let r = resumeGraph(s2, registry(), g, "crash", defaultExecConfig())
  doAssert r.status == esCompleted, $r.status
  doAssert $r.outputs == $cont.outputs
  doAssert r.outputs{"one"}{"v"}.getStr == "alpha"
  doAssert r.outputs{"two"}{"v"}.getStr == "beta"
  s2.close()

block falseCompletedFromLegacyBinary:
  ## Prefer authentic dd4fcf5 SQLite fixtures; else rebuild with legacy CLI / synthesize.
  let legacyCli = getCurrentDir() / "build" / "nimfactory_cli_dd4fcf5"
  let fixtureDir = getCurrentDir() / "docs" / "qa" / "m1_resume3_red" / "legacy_dbs"
  proc ensureFalseDb(label, graphPath, runId, storePath: string) =
    let canned = fixtureDir / (label & "_false.sqlite")
    if fileExists(canned):
      copyFile(canned, storePath)
      return
    if fileExists(legacyCli):
      discard execCmd(legacyCli & " run --graph " & graphPath & " --store " & storePath &
        " --run-id " & runId & " --mode sequential --checkpoint-after 1 " &
        "--input tests/fixtures/m1/two_inputs.json > /dev/null")
      discard execCmd(legacyCli & " resume --graph " & graphPath & " --store " & storePath &
        " --run-id " & runId & " --mode sequential > /dev/null")
      return
    let s = newSqliteRunStore(storePath)
    let ep = s.claimLease(runId, "legacy")
    let outs =
      if "join" in graphPath: newJObject()
      else: %*{"one": {"v": "alpha"}}
    discard s.commitTransition(runId, %*{
      "transition_id": "act:first:main",
      "epoch": ep,
      "activation_id": "first:main",
      "attempt_id": "att-1",
      "invocation_validated": true,
      "activation_state": {
        "status": "completed", "node_id": "first", "branch_key": "main",
        "outputs": {"out": {"v": "alpha"}}
      },
      "attempt_state": {"status": "completed"},
      "state": {"phase": "interrupted", "outputs": outs, "activation_commits": 1}
    })
    discard s.commitTransition(runId, %*{
      "transition_id": "run:" & runId & ":final",
      "epoch": ep,
      "state": {
        "phase": "completed", "mode": "sequential", "graph_id": "legacy",
        "activation_commits": 1, "outputs": outs
      },
      "activation_id": "run:final",
      "attempt_id": "att-final",
      "activation_state": {"status": "completed", "outputs": outs},
      "attempt_state": {"status": "completed"},
      "invocation_validated": true
    })
    s.close()

  for (label, graphPath, g) in [
    ("two", "recipes/m1_two_inputs.json", twoGraph),
    ("join", "recipes/m1_two_inputs_join.json", joinGraph)
  ]:
    let db = tmpStore("false-" & label)
    ensureFalseDb(label, graphPath, "false-" & label, db)
    let s = newSqliteRunStore(db)
    var raised = false
    var msg = ""
    try:
      discard resumeGraph(s, registry(), g, "false-" & label, defaultExecConfig())
    except FactoryError as e:
      raised = true
      msg = e.msg
    doAssert raised, label & " expected false-completed diagnostic"
    doAssert "false completed" in msg, msg
    s.close()

block genuineLegacyCompleteStillOk:
  let db = tmpStore("genuine-complete")
  let s1 = newSqliteRunStore(db)
  let r0 = runGraph(s1, registry(), twoGraph, "ok", twoInput, defaultExecConfig())
  doAssert r0.status == esCompleted
  s1.close()
  resetInvocationMetrics()
  let s2 = newSqliteRunStore(db)
  let r1 = resumeGraph(s2, registry(), twoGraph, "ok", defaultExecConfig())
  doAssert r1.status == esCompleted
  doAssert $r1.outputs == $r0.outputs
  doAssert peakConcurrentInvocations() == 0
  s2.close()

echo "test_resume_saturation_start_legacy: ok"
