## F5 unit tests: stable transitions, durable outputs, real concurrency, resume.
import std/[os, json, strutils]
import nimfactory

proc tmpStore(name: string): string =
  let base = getCurrentDir() / "build" / "f5-tmp"
  createDir(base)
  result = base / (name & ".sqlite")
  if fileExists(result): removeFile(result)
  let spill = result & ".spill"
  if dirExists(spill): removeDir(spill)

proc loadDiamond(): GraphSpec =
  graphFromJson(parseJson(readFile("recipes/m1_diamond.json")))

proc registry(): ExecutableRegistry =
  let r = newExecutableRegistry()
  registerDemoHandlers(r)
  r

proc resultBranches(outputs: JsonNode): seq[string] =
  result = @[]
  let r = outputs{"result"}
  if r.isNil or r.kind != JObject: return
  for it in r{"items"}:
    result.add(it{"branch"}.getStr())

block sequentialConcurrentSameResult:
  let g = loadDiamond()
  let reg = registry()
  let s1 = newSqliteRunStore(tmpStore("seq"))
  var cfg = defaultExecConfig()
  cfg.mode = emSequential
  let r1 = runGraph(s1, reg, g, "run-seq", parseJson(readFile("tests/fixtures/m1/input.json")), cfg)
  s1.close()
  let s2 = newSqliteRunStore(tmpStore("conc"))
  cfg.mode = emConcurrent
  cfg.maxConcurrency = 2
  let r2 = runGraph(s2, reg, g, "run-conc", parseJson(readFile("tests/fixtures/m1/input.json")), cfg)
  s2.close()
  doAssert r1.status == esCompleted and r2.status == esCompleted
  doAssert resultBranches(r1.outputs) == @["left", "right"]
  doAssert resultBranches(r1.outputs) == resultBranches(r2.outputs)
  doAssert r2.peakConcurrentInvocations >= 2,
    "expected real overlap, peak=" & $r2.peakConcurrentInvocations

block concurrencyCeilingOne:
  let g = loadDiamond()
  let reg = registry()
  let s = newSqliteRunStore(tmpStore("ceil1"))
  var cfg = defaultExecConfig()
  cfg.mode = emConcurrent
  cfg.maxConcurrency = 1
  let r = runGraph(s, reg, g, "run-ceil1", parseJson(readFile("tests/fixtures/m1/input.json")), cfg)
  s.close()
  doAssert r.status == esCompleted
  doAssert r.peakConcurrentInvocations == 1,
    "ceiling 1 must not overlap, peak=" & $r.peakConcurrentInvocations

block pipeRejectOnExecutorPath:
  ## Saturate real delivery path: capacity 1 + reject while map fans out 2.
  let g = loadDiamond()
  let reg = registry()
  let s = newSqliteRunStore(tmpStore("pipe-sat"))
  var cfg = defaultExecConfig()
  cfg.pipeCapacity = 1
  cfg.pipePolicy = ppReject
  var raised = false
  try:
    discard runGraph(s, reg, g, "run-sat", parseJson(readFile("tests/fixtures/m1/input.json")), cfg)
  except FactoryError as e:
    raised = true
    doAssert "pipe full" in e.msg or "rejected" in e.msg
  s.close()
  doAssert raised

block stableTransitionIdsAcrossResume:
  let g = loadDiamond()
  let reg = registry()
  let db = tmpStore("stable-tx")
  let s1 = newSqliteRunStore(db)
  var cfg = defaultExecConfig()
  cfg.checkpointAfter = 1
  let r1 = runGraph(s1, reg, g, "run-stx", parseJson(readFile("tests/fixtures/m1/input.json")), cfg)
  doAssert r1.status == esInterrupted
  let rec1 = s1.recover("run-stx")
  var sawActSplit = false
  for e in rec1["events"]:
    let tid = e{"transition_id"}.getStr(e{"body"}{"transition_id"}.getStr(""))
    if tid == "act:split:main": sawActSplit = true
    doAssert not tid.startsWith("tx-"), "unstable id " & tid
  doAssert sawActSplit
  s1.close()
  let s2 = newSqliteRunStore(db)
  cfg.checkpointAfter = 0
  let r2 = resumeGraph(s2, reg, g, "run-stx", cfg)
  let rec2 = s2.recover("run-stx")
  var sawLeft = false
  for e in rec2["events"]:
    let tid = e{"transition_id"}.getStr(e{"body"}{"transition_id"}.getStr(""))
    if tid == "act:left:left": sawLeft = true
    if tid.startsWith("tx-"):
      raiseAssert "unstable after resume: " & tid
  doAssert sawLeft
  doAssert r2.status == esCompleted
  s2.close()

block durableOutputsAtCheckpointBoundary:
  let g = loadDiamond()
  let reg = registry()
  let db = tmpStore("durable-out")
  let s = newSqliteRunStore(db)
  var cfg = defaultExecConfig()
  cfg.checkpointAfter = 5  # after reduce, before final
  let r = runGraph(s, reg, g, "run-dout", parseJson(readFile("tests/fixtures/m1/input.json")), cfg)
  doAssert r.status == esInterrupted
  doAssert resultBranches(r.outputs) == @["left", "right"]
  let rec = s.recover("run-dout")
  doAssert rec{"state"}{"outputs"}{"result"}{"count"}.getInt == 2,
    "displayed outputs must be durable: " & $rec{"state"}{"outputs"}
  doAssert $rec{"state"}{"outputs"} == $r.outputs
  s.close()

block unknownResumeRefused:
  let g = loadDiamond()
  let reg = registry()
  let s = newSqliteRunStore(tmpStore("unknown"))
  var raised = false
  try:
    discard resumeGraph(s, reg, g, "no-such-run", defaultExecConfig())
  except FactoryError as e:
    raised = true
    doAssert "unknown run_id" in e.msg
  doAssert raised
  doAssert not s.hasRun("no-such-run")
  s.close()

block secondResumeIdempotent:
  let g = loadDiamond()
  let reg = registry()
  let db = tmpStore("second-resume")
  let s1 = newSqliteRunStore(db)
  let r0 = runGraph(s1, reg, g, "run-2r", parseJson(readFile("tests/fixtures/m1/input.json")),
                    defaultExecConfig())
  doAssert r0.status == esCompleted
  s1.close()
  resetInvocationMetrics()
  let s2 = newSqliteRunStore(db)
  let r1 = resumeGraph(s2, reg, g, "run-2r", defaultExecConfig())
  doAssert r1.status == esCompleted
  doAssert resultBranches(r1.outputs) == @["left", "right"]
  doAssert peakConcurrentInvocations() == 0  # no handler re-entry
  let r2 = resumeGraph(s2, reg, g, "run-2r", defaultExecConfig())
  doAssert r2.status == esCompleted
  doAssert $r2.outputs == $r1.outputs
  s2.close()

block checkpointResumeSkipsValidated:
  let g = loadDiamond()
  let reg = registry()
  let db = tmpStore("ckpt")
  let s1 = newSqliteRunStore(db)
  var cfg = defaultExecConfig()
  cfg.checkpointAfter = 1
  let r1 = runGraph(s1, reg, g, "run-ckpt", parseJson(readFile("tests/fixtures/m1/input.json")), cfg)
  doAssert r1.status == esInterrupted
  s1.close()
  let s2 = newSqliteRunStore(db)
  cfg.checkpointAfter = 0
  let r2 = resumeGraph(s2, reg, g, "run-ckpt", cfg)
  s2.close()
  doAssert r2.status == esCompleted
  doAssert "split:main" in r2.skippedValidated
  doAssert resultBranches(r2.outputs) == @["left", "right"]

block deadlineMustNotSucceed:
  let g = graphFromJson(%*{
    "schema": "nimfactory.graph/0.1",
    "graph_id": "slow-one",
    "version": 1,
    "nodes": [{"id": "s", "handler": "demo.slow@0.1"}],
    "entrypoints": [{"input": "start", "to": "s.in"}],
    "edges": [],
    "outputs": {"out": "s.out"},
    "loop_specs": []
  })
  let reg = registry()
  let s = newSqliteRunStore(tmpStore("deadline"))
  var cfg = defaultExecConfig()
  cfg.deadlineMs = 1
  let r = runGraph(s, reg, g, "run-dl", %*{"start": {"v": 1}}, cfg)
  s.close()
  doAssert r.status == esTimedOut, "deadline must fail, got " & $r.status
  var found = false
  for e in r.events:
    if e{"kind"}.getStr == "timeout": found = true
  doAssert found

block cancelMustNotSucceed:
  let g = graphFromJson(%*{
    "schema": "nimfactory.graph/0.1",
    "graph_id": "slow-two",
    "version": 1,
    "nodes": [{"id": "s", "handler": "demo.slow@0.1"}],
    "entrypoints": [{"input": "start", "to": "s.in"}],
    "edges": [],
    "outputs": {"out": "s.out"},
    "loop_specs": []
  })
  let reg = registry()
  let s = newSqliteRunStore(tmpStore("cancel"))
  var cfg = defaultExecConfig()
  cfg.cancelRequested = true
  let r = runGraph(s, reg, g, "run-cancel", %*{"start": {"v": 1}}, cfg)
  s.close()
  doAssert r.status == esCancelled, "cancel must fail, got " & $r.status
  var found = false
  for e in r.events:
    if e{"kind"}.getStr == "cancelled": found = true
  doAssert found

block pipeWaitCapacityOneProgresses:
  ## Scheduler must progress consumers instead of hanging on wait.
  let g = loadDiamond()
  let reg = registry()
  let input = parseJson(readFile("tests/fixtures/m1/input.json"))
  for mode in [emSequential, emConcurrent]:
    let s = newSqliteRunStore(tmpStore("wait-" & $mode))
    var cfg = defaultExecConfig()
    cfg.mode = mode
    cfg.maxConcurrency = 2
    cfg.pipeCapacity = 1
    cfg.pipePolicy = ppWait
    let r = runGraph(s, reg, g, "run-wait-" & $mode, input, cfg)
    doAssert r.status == esCompleted, "wait cap1 " & $mode & " got " & $r.status
    doAssert resultBranches(r.outputs) == @["left", "right"]
    doAssert r.pipeStats.waited >= 1 or r.pipeStats.peakDepth == 1
    s.close()

block pipeSpillOnExecutorPath:
  let g = loadDiamond()
  let reg = registry()
  let db = tmpStore("spill")
  let s = newSqliteRunStore(db)
  var cfg = defaultExecConfig()
  cfg.pipeCapacity = 1
  cfg.pipePolicy = ppSpill
  cfg.spillDir = db & ".spill"
  let r = runGraph(s, reg, g, "run-spill",
                   parseJson(readFile("tests/fixtures/m1/input.json")), cfg)
  s.close()
  doAssert r.status == esCompleted, $r.status
  doAssert r.pipeStats.spilled >= 1, "expected spill under capacity 1"
  doAssert resultBranches(r.outputs) == @["left", "right"]
  var sawSpill = false
  for e in r.events:
    if e{"kind"}.getStr == "pipe_spilled": sawSpill = true
  doAssert sawSpill

block pipeWaitDeadlineObservable:
  ## Under wait policy, deadline must surface as timed_out (not hang).
  let g = graphFromJson(%*{
    "schema": "nimfactory.graph/0.1",
    "graph_id": "slow-deadline",
    "version": 1,
    "nodes": [{"id": "s", "handler": "demo.slow@0.1"}],
    "entrypoints": [{"input": "start", "to": "s.in"}],
    "edges": [],
    "outputs": {"out": "s.out"},
    "loop_specs": []
  })
  let reg = registry()
  let s = newSqliteRunStore(tmpStore("wait-dl"))
  var cfg = defaultExecConfig()
  cfg.pipeCapacity = 1
  cfg.pipePolicy = ppWait
  cfg.deadlineMs = 1
  let r = runGraph(s, reg, g, "run-wait-dl", %*{"start": {"v": 1}}, cfg)
  s.close()
  doAssert r.status == esTimedOut, "deadline must be observable, got " & $r.status


block witnessContextSequentialAndConcurrent:
  let g = graphFromJson(%*{
    "schema": "nimfactory.graph/0.1",
    "graph_id": "witness-pair",
    "version": 1,
    "nodes": [
      {"id": "w1", "handler": "demo.witness@0.1"},
      {"id": "w2", "handler": "demo.witness@0.1"}
    ],
    "entrypoints": [
      {"input": "a", "to": "w1.in"},
      {"input": "b", "to": "w2.in"}
    ],
    "edges": [],
    "outputs": {"o1": "w1.out", "o2": "w2.out"},
    "loop_specs": []
  })
  let reg = registry()
  let inputs = %*{"a": {"k": 1}, "b": {"k": 2}}
  for mode in [emSequential, emConcurrent]:
    let db = tmpStore("wit-" & $mode)
    let s = newSqliteRunStore(db)
    var cfg = defaultExecConfig()
    cfg.mode = mode
    cfg.maxConcurrency = 2
    let runId = "run-wit-" & $mode
    let r = runGraph(s, reg, g, runId, inputs, cfg)
    doAssert r.status == esCompleted, $r.status
    let epoch = s.currentEpoch(runId)
    for key in ["o1", "o2"]:
      let outp = r.outputs{key}
      doAssert outp{"run_id"}.getStr == runId, $outp
      doAssert outp{"epoch"}.getInt == epoch, $outp & " epoch=" & $epoch
      doAssert outp{"activation_id"}.getStr.len > 0
    if mode == emConcurrent:
      doAssert r.peakConcurrentInvocations >= 2
    s.close()

echo "test_executor: ok"
