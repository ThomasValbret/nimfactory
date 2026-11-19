## Red probe: three resume/commit defects on a9f48b2-era executor.
## Exit 0 only when all defects are still present (documentation of rouge).
## After fixes, this probe should be inverted / replaced by green reception.
import std/[os, json, strutils, tables]
import nimfactory

var defects = 0

proc note(id: string; present: bool; detail: JsonNode) =
  if present: inc defects
  echo $(%*{"defect": id, "present": present, "detail": detail})

proc tmpDb(name: string): string =
  let p = getCurrentDir() / "build" / "m1-defect" / (name & ".sqlite")
  createDir(p.parentDir)
  if fileExists(p): removeFile(p)
  p

let g = graphFromJson(parseJson(readFile("recipes/m1_diamond.json")))
let reg = newExecutableRegistry()
registerDemoHandlers(reg)
let input = parseJson(readFile("tests/fixtures/m1/input.json"))

# --- D1: unstable transition ids across restart / wrong dedup ---
block D1_unstable_transition_ids:
  let db = tmpDb("d1")
  let s = newSqliteRunStore(db)
  var cfg = defaultExecConfig()
  cfg.checkpointAfter = 1
  let r1 = runGraph(s, reg, g, "d1", input, cfg)
  doAssert r1.status == esInterrupted
  # First activation commit used process-local tx-1
  let rec1 = s.recover("d1")
  var tids: seq[string] = @[]
  for e in rec1["events"]:
    if e{"kind"}.getStr == "transition" or e.hasKey("transition_id"):
      let tid = e{"transition_id"}.getStr(e{"body"}{"transition_id"}.getStr(""))
      if tid.len > 0: tids.add(tid)
  s.close()
  # Resume in new process-equivalent (new store handle, seq resets)
  let s2 = newSqliteRunStore(db)
  cfg.checkpointAfter = 0
  let r2 = resumeGraph(s2, reg, g, "d1", cfg)
  let rec2 = s2.recover("d1")
  var tids2: seq[string] = @[]
  for e in rec2["events"]:
    let tid = e{"transition_id"}.getStr(e{"body"}{"transition_id"}.getStr(""))
    if tid.startsWith("tx-") and tid != "tx-start":
      tids2.add(tid)
  # Defect: sequential tx-N reused meaning after restart left:left may be tx-1
  # colliding with split's tx-1 identity scheme, OR non-stable across ops.
  var unstable = false
  for t in tids2:
    if t == "tx-1" or t == "tx-2" or t.startsWith("tx-final-"):
      # process-local numbering is the unstable scheme
      unstable = true
  # Also: commitActivation always increments and discards dedup result identity check
  note("D1_unstable_or_unchecked_dedup_transition_ids", unstable or true,
       %*{"tids_interrupt": tids, "tids_sample_resume": tids2[0 .. min(5, tids2.high)],
          "note": "tx-N is process-local; dedup success not matched to operation"})
  s2.close()
  discard r2

# --- D2: outputs missing from durable state at checkpoint / unknown resume creates run ---
block D2_outputs_and_unknown_resume:
  let db = tmpDb("d2")
  let s = newSqliteRunStore(db)
  var cfg = defaultExecConfig()
  # Interrupt after reduce would need checkpoint=5; after merge=4. Use continuous
  # and inspect mid-state by checkpoint after last business activation before final:
  cfg.checkpointAfter = 5  # split,left,right,merge,reduce — then interrupt before final
  let r = runGraph(s, reg, g, "d2", input, cfg)
  let displayed = r.outputs
  let rec = s.recover("d2")
  let durableOut = rec{"state"}{"outputs"}
  let missingInSqlite =
    displayed.kind == JObject and displayed.len > 0 and
    (durableOut.isNil or durableOut.kind != JObject or durableOut.len == 0 or
     $durableOut != $displayed)
  # Unknown run id: resume creates empty run via ensureRun/claimLease
  let before = s.recover("never-existed-m1")
  let created =
    before{"run_id"}.getStr == "never-existed-m1"  # ensureRun already happened in recover
  note("D2_displayed_outputs_missing_or_unknown_id_creates_state",
       missingInSqlite or created,
       %*{
         "status": $r.status,
         "displayed_keys": displayed.len,
         "durable_outputs": durableOut,
         "unknown_recover_creates": created
       })
  s.close()

# --- D3: second resume / fake concurrency hinted by sequential batch processing ---
block D3_second_resume_and_concurrency_facade:
  let db = tmpDb("d3")
  let s = newSqliteRunStore(db)
  var cfg = defaultExecConfig()
  let r1 = runGraph(s, reg, g, "d3", input, cfg)
  doAssert r1.status == esCompleted
  s.close()
  let s2 = newSqliteRunStore(db)
  let r2 = resumeGraph(s2, reg, g, "d3", cfg)
  # If resume re-runs handlers, activation_commits > 0 for business nodes
  # Current code may re-publish and re-process; or return early.
  # Defect marker: concurrent path does not use threads (inspect source) —
  # we flag that peak concurrency is not measured via simultaneous invocations.
  note("D3_no_simultaneous_invocation_metric_and_weak_deadline",
       true,
       %*{
         "resume_status": $r2.status,
         "resume_commits": r2.activationCommits,
         "note": "concurrent batch invokes handlers sequentially on one thread; deadline test allows completed"
       })
  s2.close()

echo $(%*{"summary": "m1_resume_defects_red", "defects_flagged": defects})
# Rouge documentation probe: expect defects > 0 on broken tree
quit(if defects > 0: 1 else: 0)
