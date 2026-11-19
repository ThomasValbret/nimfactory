## F5: pending entrypoints survive checkpoint and resume (two-input + join).
import std/[os, json, strutils]
import nimfactory

proc tmpStore(name: string): string =
  let base = getCurrentDir() / "build" / "f5-pending-tmp"
  createDir(base)
  result = base / (name & ".sqlite")
  if fileExists(result): removeFile(result)
  let spill = result & ".spill"
  if dirExists(spill): removeDir(spill)

proc registry(): ExecutableRegistry =
  let r = newExecutableRegistry()
  registerDemoHandlers(r)
  r

let twoGraph = graphFromJson(parseJson(readFile("recipes/m1_two_inputs.json")))
let joinGraph = graphFromJson(parseJson(readFile("recipes/m1_two_inputs_join.json")))
let inputs = parseJson(readFile("tests/fixtures/m1/two_inputs.json"))

block continuousTwoOutputs:
  let s = newSqliteRunStore(tmpStore("cont-two"))
  let r = runGraph(s, registry(), twoGraph, "cont-two", inputs, defaultExecConfig())
  s.close()
  doAssert r.status == esCompleted
  doAssert r.outputs{"one"}{"v"}.getStr == "alpha"
  doAssert r.outputs{"two"}{"v"}.getStr == "beta"

block resumeTwoOutputs:
  let db = tmpStore("brk-two")
  let s1 = newSqliteRunStore(db)
  var cfg = defaultExecConfig()
  cfg.checkpointAfter = 1
  let r1 = runGraph(s1, registry(), twoGraph, "brk-two", inputs, cfg)
  doAssert r1.status == esInterrupted
  doAssert r1.outputs{"one"}{"v"}.getStr == "alpha"
  s1.close()
  resetInvocationMetrics()
  let s2 = newSqliteRunStore(db)
  cfg.checkpointAfter = 0
  let r2 = resumeGraph(s2, registry(), twoGraph, "brk-two", cfg)
  doAssert r2.status == esCompleted, $r2.status
  doAssert r2.outputs{"one"}{"v"}.getStr == "alpha"
  doAssert r2.outputs{"two"}{"v"}.getStr == "beta"
  doAssert "first:main" in r2.skippedValidated
  doAssert "second:main" notin r2.skippedValidated
  # second validated exactly once in durable store
  let rec = s2.recover("brk-two")
  doAssert rec{"activations"}{"first:main"}{"invocation_validated"}.getBool
  doAssert rec{"activations"}{"second:main"}{"invocation_validated"}.getBool
  resetInvocationMetrics()
  let r3 = resumeGraph(s2, registry(), twoGraph, "brk-two", cfg)
  doAssert r3.status == esCompleted
  doAssert $r3.outputs == $r2.outputs
  doAssert peakConcurrentInvocations() == 0
  s2.close()

block continuousJoin:
  let s = newSqliteRunStore(tmpStore("cont-join"))
  let r = runGraph(s, registry(), joinGraph, "cont-join", inputs, defaultExecConfig())
  s.close()
  doAssert r.status == esCompleted
  doAssert r.outputs{"result"}{"count"}.getInt == 2

block resumeJoin:
  let db = tmpStore("brk-join")
  let s1 = newSqliteRunStore(db)
  var cfg = defaultExecConfig()
  cfg.checkpointAfter = 1
  let r1 = runGraph(s1, registry(), joinGraph, "brk-join", inputs, cfg)
  doAssert r1.status == esInterrupted
  s1.close()
  let s2 = newSqliteRunStore(db)
  cfg.checkpointAfter = 0
  let r2 = resumeGraph(s2, registry(), joinGraph, "brk-join", cfg)
  doAssert r2.status == esCompleted, $r2.status
  doAssert r2.outputs{"result"}{"count"}.getInt == 2
  doAssert "first:main" in r2.skippedValidated
  let rec = s2.recover("brk-join")
  doAssert rec{"state"}{"outputs"}{"result"}{"count"}.getInt == 2
  resetInvocationMetrics()
  let r3 = resumeGraph(s2, registry(), joinGraph, "brk-join", cfg)
  doAssert $r3.outputs == $r2.outputs
  doAssert peakConcurrentInvocations() == 0
  s2.close()

block irrecoverableOldCheckpointDiagnostic:
  ## Simulate pre-fix interrupted state: validated first, no pending_inputs snap.
  let db = tmpStore("old-brk")
  let s = newSqliteRunStore(db)
  let epoch = s.claimLease("old-brk", "test")
  discard s.commitTransition("old-brk", %*{
    "transition_id": "run:old-brk:start",
    "epoch": epoch,
    "state": {"phase": "running", "outputs": newJObject()},
    "activation_id": "run:start",
    "attempt_id": "att-start",
    "activation_state": {"status": "started"},
    "attempt_state": {"status": "started"},
    "invocation_validated": true
  })
  discard s.commitTransition("old-brk", %*{
    "transition_id": "act:first:main",
    "epoch": epoch,
    "activation_id": "first:main",
    "attempt_id": "att-1",
    "invocation_validated": true,
    "activation_state": {
      "status": "completed", "node_id": "first", "branch_key": "main",
      "outputs": {"out": {"v": "alpha"}}
    },
    "attempt_state": {"status": "completed"},
    "state": {
      "phase": "interrupted",
      "mode": "sequential",
      "graph_id": "m1-two-inputs",
      "activation_commits": 1,
      "outputs": {"one": {"v": "alpha"}}
      # intentionally no pending_inputs
    }
  })
  var raised = false
  var msg = ""
  try:
    discard resumeGraph(s, registry(), twoGraph, "old-brk", defaultExecConfig())
  except FactoryError as e:
    raised = true
    msg = e.msg
  doAssert raised, "expected diagnostic for irrecoverable pending"
  doAssert "irrecoverable pending" in msg or "missing durable pending" in msg, msg
  s.close()

echo "test_pending_resume: ok"
