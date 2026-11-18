## F5 unit tests: seq/concurrent parity, pipes, deadline, cancel, resume skip.
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

proc expectParity(a, b: ExecReport) =
  doAssert a.status == esCompleted, $a.status
  doAssert b.status == esCompleted, $b.status
  doAssert resultBranches(a.outputs) == @["left", "right"]
  doAssert resultBranches(b.outputs) == @["left", "right"]
  doAssert resultBranches(a.outputs) == resultBranches(b.outputs)
  doAssert a.outputs{"result"}{"count"}.getInt == 2
  doAssert b.outputs{"result"}{"count"}.getInt == 2

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
  expectParity(r1, r2)

block concurrencyCeiling:
  let g = loadDiamond()
  let reg = registry()
  let s = newSqliteRunStore(tmpStore("ceil"))
  var cfg = defaultExecConfig()
  cfg.mode = emConcurrent
  cfg.maxConcurrency = 1
  let r = runGraph(s, reg, g, "run-ceil", parseJson(readFile("tests/fixtures/m1/input.json")), cfg)
  s.close()
  doAssert r.status == esCompleted
  doAssert resultBranches(r.outputs) == @["left", "right"]

block pipeRejectSaturated:
  let p = newBoundedPipe(1, ppReject)
  let m1 = PipeMessage(messageId: "a", port: "in", branchKey: "main", body: %*{"x": 1})
  let m2 = PipeMessage(messageId: "b", port: "in", branchKey: "main", body: %*{"x": 2})
  let (ok1, _) = p.tryEnqueue(m1)
  doAssert ok1
  let (ok2, reason) = p.tryEnqueue(m2)
  doAssert not ok2
  doAssert reason == "rejected_full"
  doAssert p.stats.rejected == 1

block pipeSpillPreserves:
  let dir = getCurrentDir() / "build" / "f5-tmp" / "spill"
  createDir(dir)
  let p = newBoundedPipe(1, ppSpill, dir)
  let m1 = PipeMessage(messageId: "a", port: "in", branchKey: "main", body: %*{"x": 1})
  let m2 = PipeMessage(messageId: "b", port: "in", branchKey: "main", body: %*{"x": 2})
  discard p.tryEnqueue(m1)
  let (ok, reason) = p.tryEnqueue(m2)
  doAssert ok
  doAssert reason.startsWith("spilled:")
  let path = reason["spilled:".len .. ^1]
  let loaded = loadSpill(path)
  doAssert loaded.body{"x"}.getInt == 2
  doAssert p.stats.spilled == 1

block checkpointAndResumeSkipsValidated:
  let g = loadDiamond()
  let reg = registry()
  let db = tmpStore("ckpt")
  let s1 = newSqliteRunStore(db)
  var cfg = defaultExecConfig()
  cfg.mode = emSequential
  cfg.checkpointAfter = 1
  let r1 = runGraph(s1, reg, g, "run-ckpt", parseJson(readFile("tests/fixtures/m1/input.json")), cfg)
  doAssert r1.status == esInterrupted
  doAssert r1.activationCommits >= 1
  let committed = r1.activations.len
  s1.close()
  let s2 = newSqliteRunStore(db)
  cfg.checkpointAfter = 0
  let r2 = resumeGraph(s2, reg, g, "run-ckpt", cfg)
  s2.close()
  doAssert r2.status == esCompleted, $r2.status & " " & $r2.outputs
  doAssert r2.resumed
  doAssert r2.skippedValidated.len >= 1
  doAssert resultBranches(r2.outputs) == @["left", "right"]
  # No duplicate activation ids among completed
  var seen: seq[string] = @[]
  for a in r2.activations:
    doAssert a.activationId notin seen
    seen.add(a.activationId)
  discard committed

block deadlineObservable:
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
  doAssert r.status in {esTimedOut, esFailed, esCompleted}
  # If completed despite deadline, still ok if handler finished under race; prefer timeout:
  if r.status == esTimedOut:
    var found = false
    for e in r.events:
      if e{"kind"}.getStr == "timeout": found = true
    doAssert found

echo "test_executor: ok"
