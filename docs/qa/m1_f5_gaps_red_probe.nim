## Red probe: F5 gaps on f7b3aca — wait blocks scheduler; worker ctx missing run_id/epoch.
## Exit 1 when defects present (documentation rouge). After fix, use green probe.
import std/[os, json, strutils, osproc]
import nimfactory

var defects = 0

proc note(id: string; present: bool; detail: JsonNode) =
  if present: inc defects
  echo $(%*{"defect": id, "present": present, "detail": detail})

proc tmpDb(name: string): string =
  let p = getCurrentDir() / "build" / "m1-f5-gaps-red" / (name & ".sqlite")
  createDir(p.parentDir)
  if fileExists(p): removeFile(p)
  let spill = p & ".spill"
  if dirExists(spill): removeDir(spill)
  p

let g = graphFromJson(parseJson(readFile("recipes/m1_diamond.json")))
let reg = newExecutableRegistry()
registerDemoHandlers(reg)
let input = parseJson(readFile("tests/fixtures/m1/input.json"))

# --- D-PIPE: wait+capacity 1 hangs the process (scheduler cannot progress consumers) ---
block D_pipe_wait_blocks_scheduler:
  # External bound: if runGraph never returns, this child is killed → hang defect.
  let helper = getCurrentDir() / "build" / "m1_f5_wait_hang_child"
  let src = getCurrentDir() / "build" / "m1_f5_wait_hang_child.nim"
  writeFile(src, """
import std/[os, json]
import nimfactory
let g = graphFromJson(parseJson(readFile("recipes/m1_diamond.json")))
let reg = newExecutableRegistry()
registerDemoHandlers(reg)
let db = getCurrentDir() / "build" / "m1-f5-gaps-red" / "hang.sqlite"
createDir(db.parentDir)
if fileExists(db): removeFile(db)
let s = newSqliteRunStore(db)
var cfg = defaultExecConfig()
cfg.pipeCapacity = 1
cfg.pipePolicy = ppWait
cfg.mode = emSequential
discard runGraph(s, reg, g, "hang", parseJson(readFile("tests/fixtures/m1/input.json")), cfg)
s.close()
echo "UNEXPECTED_COMPLETED"
""")
  discard execCmd("nim c --hints:off --warnings:off --threads:on --path:src --path:vendor/NimAgentLibrary/src -o:" &
                  helper & " " & src)
  let (outp, exitCode) = execCmdEx("timeout 3s " & helper)
  # timeout → 124 means hang; or still stuck in wait
  let hung = exitCode == 124 or ("UNEXPECTED_COMPLETED" notin outp and exitCode != 0)
  # Also check tryEnqueue wait blocks via unit-level: full pipe + wait never returns without consumer
  note("D_pipe_wait_capacity1_hangs_scheduler", hung or exitCode == 124,
       %*{"exit": exitCode, "stdout_tail": outp[^min(200, outp.len) .. ^1],
          "note": "ppWait tryEnqueue blocks; consumers cannot run while publish waits"})

# --- D-CTX: concurrent workers get empty run_id / epoch 0 ---
block D_worker_context_empty:
  # Inspect source contract: IsolatedJob hardcodes runId="" epoch=0
  let src = readFile("src/nimfactory/runtime/executor/executor.nim")
  let emptyCtx = "runId: \"\"" in src and "epoch: 0" in src and "invokeIsolated" in src
  note("D_worker_invocation_context_missing_run_epoch", emptyCtx,
       %*{"note": "IsolatedJob/invokeIsolated does not pass ex.runId / ex.epoch"})

echo $(%*{"summary": "m1_f5_gaps_red", "defects_flagged": defects})
quit(if defects > 0: 1 else: 0)
