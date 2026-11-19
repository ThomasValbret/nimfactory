## Independent M1 F5 counter-proof via public APIs (qualification 2026-11-19).
## Detects frozen epoch=2 after resume; requires wait saturation + exact reject semantics.
import std/[os, json, strutils, osproc, tables]
import nimfactory

var failed = 0
proc check(id: string; ok: bool; detail: JsonNode) =
  if not ok: inc failed
  echo $(%*{"check": id, "ok": ok, "detail": detail})

proc tmpDb(name: string): string =
  let p = getCurrentDir() / "build" / "m1-requal-counter" / (name & ".sqlite")
  createDir(p.parentDir)
  if fileExists(p): removeFile(p)
  let spill = p & ".spill"
  if dirExists(spill): removeDir(spill)
  p

proc branches(outputs: JsonNode): seq[string] =
  result = @[]
  for it in outputs{"result"}{"items"}:
    result.add(it{"branch"}.getStr())

let oracle = parseJson(readFile("tests/fixtures/m1/oracle_outputs.json"))
let want = @[oracle{"expected_result"}{"branch_order"}[0].getStr(),
             oracle{"expected_result"}{"branch_order"}[1].getStr()]
let diamond = graphFromJson(parseJson(readFile("recipes/m1_diamond.json")))
let reg = newExecutableRegistry()
registerDemoHandlers(reg)
let input = parseJson(readFile("tests/fixtures/m1/input.json"))

# --- Pipe wait: saturation observable, complete under wall bound, oracle parity ---
block pipeWaitSeqConc:
  for mode in [emSequential, emConcurrent]:
    let s = newSqliteRunStore(tmpDb("wait-" & $mode))
    var cfg = defaultExecConfig()
    cfg.mode = mode
    cfg.maxConcurrency = 2
    cfg.pipeCapacity = 1
    cfg.pipePolicy = ppWait
    let r = runGraph(s, reg, diamond, "cp-wait-" & $mode, input, cfg)
    let br = branches(r.outputs)
    let ok = r.status == esCompleted and br == want and
             r.pipeStats.waited >= 1 and
             r.outputs{"result"}{"count"}.getInt == 2
    check("pipe_wait_" & $mode, ok, %*{
      "status": $r.status, "branches": br, "waited": r.pipeStats.waited,
      "peak_depth": r.pipeStats.peakDepth, "peak_conc": r.peakConcurrentInvocations
    })
    s.close()

# --- Reject: public CLI must exit exactly 4 ---
block pipeRejectExactExit4:
  discard execCmd("nim c --hints:off --warnings:off --threads:on --path:src --path:vendor/NimAgentLibrary/src " &
                  "--nimcache:build/nimcache-requal-cli -o:build/nimfactory_cli_requal src/nimfactory_cli.nim")
  let store = tmpDb("rej-cli")
  let outf = getCurrentDir() / "build" / "m1-requal-counter" / "reject_out.jsonl"
  let cmd = "timeout 8s ./build/nimfactory_cli_requal run --graph recipes/m1_diamond.json --store " &
            store & " --run-id rej --mode sequential --pipe-capacity 1 --pipe-policy reject " &
            "--input tests/fixtures/m1/input.json > " & outf & " 2>/tmp/rej_err.txt"
  let ec = execCmd(cmd)
  let body = if fileExists(outf): readFile(outf) else: ""
  check("pipe_reject_exit_exactly_4", ec == 4, %*{
    "exit": ec, "stdout_prefix": body[0 .. min(120, max(0, body.len-1))],
    "stderr": readFile("/tmp/rej_err.txt")
  })

# --- Spill: overflow observed, same oracle outputs ---
block pipeSpillOracle:
  let db = tmpDb("spill")
  let s = newSqliteRunStore(db)
  var cfg = defaultExecConfig()
  cfg.pipeCapacity = 1
  cfg.pipePolicy = ppSpill
  cfg.spillDir = db & ".spill"
  let r = runGraph(s, reg, diamond, "cp-spill", input, cfg)
  check("pipe_spill_oracle",
        r.status == esCompleted and r.pipeStats.spilled >= 1 and branches(r.outputs) == want,
        %*{"status": $r.status, "spilled": r.pipeStats.spilled, "branches": branches(r.outputs)})
  s.close()

# --- No-progress diagnostic vs harness 124 ---
block noProgressVsHang:
  # Internal timed_out under wait+deadline (not hang): must finish with status timed_out.
  let g = graphFromJson(%*{
    "schema": "nimfactory.graph/0.1", "graph_id": "slow-dl", "version": 1,
    "nodes": [{"id": "s", "handler": "demo.slow@0.1"}],
    "entrypoints": [{"input": "start", "to": "s.in"}],
    "edges": [], "outputs": {"out": "s.out"}, "loop_specs": []
  })
  let s = newSqliteRunStore(tmpDb("dl"))
  var cfg = defaultExecConfig()
  cfg.pipeCapacity = 1
  cfg.pipePolicy = ppWait
  cfg.deadlineMs = 1
  let r = runGraph(s, reg, g, "cp-dl", %*{"start": {"v": 1}}, cfg)
  var kind = ""
  for e in r.events:
    if e{"kind"}.getStr in ["timeout", "pipe_blocked"]:
      kind = e{"kind"}.getStr
      break
  check("internal_timeout_not_harness_124",
        r.status == esTimedOut and kind == "timeout",
        %*{"status": $r.status, "event_kind": kind, "note": "harness 124 is timeout(1) kill; this is executor timed_out"})
  s.close()
  # Wait diamond under external 8s bound must NOT be 124
  let store = tmpDb("wait-bound")
  let outf = getCurrentDir() / "build" / "m1-requal-counter" / "wait_bound.jsonl"
  let cmd = "timeout 8s ./build/nimfactory_cli_requal run --graph recipes/m1_diamond.json --store " &
            store & " --run-id wb --mode sequential --pipe-capacity 1 --pipe-policy wait " &
            "--input tests/fixtures/m1/input.json > " & outf
  let ec = execCmd(cmd)
  check("wait_under_external_guard_not_124", ec == 0,
        %*{"exit": ec, "note": "124 would mean hang killed by harness"})

# --- Witness context: seq, concurrent peak>=2, resume epoch must not freeze at 2 ---
block witnessContext:
  let wg = graphFromJson(%*{
    "schema": "nimfactory.graph/0.1",
    "graph_id": "witness-diamond",
    "version": 1,
    "nodes": [
      {"id": "split", "kind": "map", "control": {"branches": ["left", "right"]}},
      {"id": "left", "handler": "demo.witness@0.1"},
      {"id": "right", "handler": "demo.witness@0.1"},
      {"id": "merge", "kind": "join", "control": {
        "policy": "all_required", "on_failure": "fail", "on_late": "discard", "on_cancel": "fail"
      }},
      {"id": "reduce", "kind": "reduce", "control": {
        "function": "concat", "stable_order": true, "commutative": false
      }}
    ],
    "entrypoints": [{"input": "start", "to": "split.in"}],
    "edges": [
      {"from": "split.branch", "to": "left.in"},
      {"from": "split.branch", "to": "right.in"},
      {"from": "left.out", "to": "merge.in_left"},
      {"from": "right.out", "to": "merge.in_right"},
      {"from": "merge.out", "to": "reduce.in"}
    ],
    "outputs": {"result": "reduce.out"},
    "loop_specs": []
  })
  # Sequential continuous
  block:
    let runId = "wit-seq"
    let s = newSqliteRunStore(tmpDb("wit-seq"))
    var cfg = defaultExecConfig()
    cfg.mode = emSequential
    let r = runGraph(s, reg, wg, runId, input, cfg)
    let epoch = s.currentEpoch(runId)
    var ok = r.status == esCompleted
    for a in r.activations:
      if a.nodeId in ["left", "right"]:
        let o = a.outputs{"out"}
        if o{"run_id"}.getStr != runId or o{"epoch"}.getInt != epoch:
          ok = false
    check("witness_sequential_matches_sqlite", ok,
          %*{"epoch": epoch, "status": $r.status})
    s.close()
  # Concurrent real overlap
  block:
    let runId = "wit-conc"
    let s = newSqliteRunStore(tmpDb("wit-conc"))
    var cfg = defaultExecConfig()
    cfg.mode = emConcurrent
    cfg.maxConcurrency = 2
    let r = runGraph(s, reg, wg, runId, input, cfg)
    let epoch = s.currentEpoch(runId)
    var ok = r.status == esCompleted and r.peakConcurrentInvocations >= 2
    for a in r.activations:
      if a.nodeId in ["left", "right"]:
        let o = a.outputs{"out"}
        if o{"run_id"}.getStr != runId or o{"epoch"}.getInt != epoch:
          ok = false
    check("witness_concurrent_peak_and_epoch", ok,
          %*{"epoch": epoch, "peak": r.peakConcurrentInvocations, "status": $r.status})
    s.close()
  # Interrupt after split; resume runs witnesses — epoch must advance (not frozen at 2)
  block:
    let runId = "wit-resume"
    let db = tmpDb("wit-resume")
    let s1 = newSqliteRunStore(db)
    var cfg = defaultExecConfig()
    cfg.checkpointAfter = 1
    let r1 = runGraph(s1, reg, wg, runId, input, cfg)
    let epochAtInterrupt = s1.currentEpoch(runId)
    doAssert r1.status == esInterrupted
    s1.close()
    let s2 = newSqliteRunStore(db)
    cfg.checkpointAfter = 0
    let r2 = resumeGraph(s2, reg, wg, runId, cfg)
    let epochAfterResume = s2.currentEpoch(runId)
    var witnessEpochs: seq[int] = @[]
    var runIdsOk = true
    for a in r2.activations:
      if a.nodeId in ["left", "right"]:
        let o = a.outputs{"out"}
        witnessEpochs.add(o{"epoch"}.getInt)
        if o{"run_id"}.getStr != runId: runIdsOk = false
    # Detect frozen epoch=2: after resume lease, store epoch must be > interrupt epoch,
    # and witnesses must report that resumed epoch (not a stale 2).
    let advanced = epochAfterResume > epochAtInterrupt and epochAfterResume != 2
    let witnessesMatch = witnessEpochs.len == 2 and
                         witnessEpochs[0] == epochAfterResume and
                         witnessEpochs[1] == epochAfterResume
    # Also fail if everything is stuck at 2 while claiming to have resumed
    let notFrozen2 = not (epochAfterResume == 2 and epochAtInterrupt == 2)
    check("witness_after_resume_epoch_not_frozen",
          r2.status == esCompleted and runIdsOk and advanced and witnessesMatch and
          "split:main" in r2.skippedValidated and notFrozen2,
          %*{
            "epoch_interrupt": epochAtInterrupt,
            "epoch_after_resume": epochAfterResume,
            "witness_epochs": witnessEpochs,
            "skipped": r2.skippedValidated,
            "status": $r2.status
          })
    s2.close()

# --- Resume acquisitions: checkpoints 1-5 durable + second resume + unknown id ---
block resumeAcquisitions:
  var allOk = true
  var details = newJArray()
  for n in 1..5:
    let db = tmpDb("ckpt-" & $n)
    let s1 = newSqliteRunStore(db)
    var cfg = defaultExecConfig()
    cfg.checkpointAfter = n
    let r1 = runGraph(s1, reg, diamond, "ckpt-" & $n, input, cfg)
    if r1.status != esInterrupted: allOk = false
    let durable = s1.recover("ckpt-" & $n){"state"}{"outputs"}
    if r1.outputs.len > 0 and $durable != $r1.outputs: allOk = false
    s1.close()
    let s2 = newSqliteRunStore(db)
    cfg.checkpointAfter = 0
    let r2 = resumeGraph(s2, reg, diamond, "ckpt-" & $n, cfg)
    if r2.status != esCompleted or branches(r2.outputs) != want: allOk = false
    resetInvocationMetrics()
    let r3 = resumeGraph(s2, reg, diamond, "ckpt-" & $n, cfg)
    if r3.status != esCompleted or $r3.outputs != $r2.outputs or peakConcurrentInvocations() != 0:
      allOk = false
    details.add(%*{
      "n": n, "intr": $r1.status, "res": $r2.status,
      "second_peak": peakConcurrentInvocations(), "branches": branches(r2.outputs)
    })
    s2.close()
  check("checkpoints_1_to_5_durable_and_second_resume", allOk, %*{"runs": details})
  # Unknown run_id: no row created
  let s = newSqliteRunStore(tmpDb("unknown"))
  var raised = false
  try:
    discard resumeGraph(s, reg, diamond, "no-such-requal", defaultExecConfig())
  except FactoryError:
    raised = true
  check("unknown_resume_no_row", raised and not s.hasRun("no-such-requal"),
        %*{"raised": raised, "has_run": s.hasRun("no-such-requal")})
  s.close()

echo $(%*{"summary": "m1_requal_counterproof", "failures": failed,
          "candidate": "dd4fcf57e801c69cf0257edf06c140ef5a37b235"})
quit(if failed == 0: 0 else: 1)
