## Green reception: F5 wait/scheduler + worker context gaps must be closed.
import std/[os, json, strutils, osproc]
import nimfactory

var failures = 0

proc check(id: string; ok: bool; detail: JsonNode) =
  if not ok: inc failures
  echo $(%*{"check": id, "ok": ok, "detail": detail})

proc tmpDb(name: string): string =
  let p = getCurrentDir() / "build" / "m1-f5-gaps-green" / (name & ".sqlite")
  createDir(p.parentDir)
  if fileExists(p): removeFile(p)
  let spill = p & ".spill"
  if dirExists(spill): removeDir(spill)
  p

let g = graphFromJson(parseJson(readFile("recipes/m1_diamond.json")))
let reg = newExecutableRegistry()
registerDemoHandlers(reg)
let input = parseJson(readFile("tests/fixtures/m1/input.json"))

block G_pipe_wait_progresses:
  var okAll = true
  var detail = newJObject()
  for mode in [emSequential, emConcurrent]:
    let s = newSqliteRunStore(tmpDb("wait-" & $mode))
    var cfg = defaultExecConfig()
    cfg.mode = mode
    cfg.maxConcurrency = 2
    cfg.pipeCapacity = 1
    cfg.pipePolicy = ppWait
    let r = runGraph(s, reg, g, "g-wait-" & $mode, input, cfg)
    let branches = block:
      var b: seq[string] = @[]
      for it in r.outputs{"result"}{"items"}: b.add(it{"branch"}.getStr())
      b
    let ok = r.status == esCompleted and branches == @["left", "right"]
    if not ok: okAll = false
    detail[$mode] = %*{"status": $r.status, "branches": branches, "waited": r.pipeStats.waited}
    s.close()
  # External hang bound via timeout on CLI path is in m1_pipe_backpressure_cli.sh;
  # also verify in-process returns (would hang forever before fix).
  check("G_pipe_wait_cap1_progresses_seq_conc", okAll, detail)

block G_worker_context:
  let wg = graphFromJson(%*{
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
  var okAll = true
  var detail = newJObject()
  for mode in [emSequential, emConcurrent]:
    let runId = "g-wit-" & $mode
    let s = newSqliteRunStore(tmpDb("wit-" & $mode))
    var cfg = defaultExecConfig()
    cfg.mode = mode
    cfg.maxConcurrency = 2
    let r = runGraph(s, reg, wg, runId, %*{"a": {"k": 1}, "b": {"k": 2}}, cfg)
    let epoch = s.currentEpoch(runId)
    let o1 = r.outputs{"o1"}
    let o2 = r.outputs{"o2"}
    let ok = r.status == esCompleted and
             o1{"run_id"}.getStr == runId and o2{"run_id"}.getStr == runId and
             o1{"epoch"}.getInt == epoch and o2{"epoch"}.getInt == epoch
    if not ok: okAll = false
    detail[$mode] = %*{
      "status": $r.status, "epoch": epoch,
      "o1_run": o1{"run_id"}.getStr, "o1_epoch": o1{"epoch"}.getInt,
      "o2_run": o2{"run_id"}.getStr, "o2_epoch": o2{"epoch"}.getInt,
      "peak": r.peakConcurrentInvocations
    }
    s.close()
  check("G_worker_context_run_epoch_seq_conc", okAll, detail)

echo $(%*{"summary": "m1_f5_gaps_green", "failures": failures})
quit(if failures == 0: 0 else: 1)
