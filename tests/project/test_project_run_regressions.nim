## Regressions conditioning `project run`, archive replay, criteria, lease.
## No OpenAI calls (inject / historical replay only).

import std/[os, json, strutils, times, osproc]
import nimfactory/project/[pipeline, store, verify, types]
import nimfactory/mission/apply

let root = getCurrentDir()
let fix = root / "fixtures" / "demo_tasks_cli"
let inj = fix / "inject"

proc tmpPath(tag: string): string =
  getTempDir() / ("nf_run_" & tag & "_" & $getCurrentProcessId() & "_" &
                  $epochTime().int)

proc seedPlan(store, art, pid: string) =
  var ask = defaultProjectRequest()
  ask.storePath = store
  ask.projectId = pid
  ask.cwd = fix
  ask.objective = "Je veux pouvoir exporter mes tâches."
  ask.route = "inject"
  ask.injectPath = inj / "plan_v1.json"
  ask.artifactDir = art
  let asked = projectAsk(ask)
  doAssert asked.ok
  doAssert asked.providerCallsThisCommand == 1, "ask must count provider call"
  doAssert asked.apiCallsThisCommand == 0, "inject ask must not count api"
  var rev = ask
  rev.refinement = "CSV sur stdout; garder list par défaut."
  rev.injectPath = inj / "plan_v2.json"
  doAssert projectRevise(rev).ok

# --- Replay archived real-campaign outputs ---
block archiveParseErrorRecovery:
  let store = tmpPath("arch1") & ".sqlite"
  let art = tmpPath("arch1_art")
  createDir(art)
  seedPlan(store, art, "arch1")
  # Helpers first so insertAfter recovery can compile against formatCsv.
  var h = defaultProjectRequest()
  h.storePath = store
  h.projectId = "arch1"
  h.cwd = fix
  h.route = "inject"
  h.injectPath = inj / "step_helpers.json"
  h.worktree = tmpPath("arch1_h")
  h.artifactDir = art
  doAssert projectStep(h).ok
  var req = h
  req.replayFirstPath = inj / "archive_api_raw_parse_error.txt"
  req.injectRecoveryPath = inj / "step_recovery_insert_after.json"
  req.injectPath = ""
  req.worktree = tmpPath("arch1_w")
  let r = projectStep(req)
  doAssert r.recoveryTriggered, "parse_error must enter bounded recovery"
  doAssert r.recoveryAttempted
  doAssert r.recoveryReason == "parse_error", r.recoveryReason
  doAssert r.ok, r.verdict & " " & r.message
  echo "archive_parse_error_recovery: ok"

block archiveEmptyOldTextRecovery:
  let store = tmpPath("arch2") & ".sqlite"
  let art = tmpPath("arch2_art")
  createDir(art)
  seedPlan(store, art, "arch2")
  var h = defaultProjectRequest()
  h.storePath = store
  h.projectId = "arch2"
  h.cwd = fix
  h.route = "inject"
  h.injectPath = inj / "step_helpers.json"
  h.worktree = tmpPath("arch2_h")
  h.artifactDir = art
  doAssert projectStep(h).ok
  var req = h
  req.replayFirstPath = inj / "archive_api_raw_empty_oldtext.txt"
  req.injectRecoveryPath = inj / "step_recovery_insert_after.json"
  req.worktree = tmpPath("arch2_w")
  let r = projectStep(req)
  doAssert r.recoveryTriggered
  doAssert r.recoveryReason == "empty_or_missing_oldText", r.recoveryReason
  doAssert r.ok, r.verdict & " " & r.message
  echo "archive_empty_oldtext_recovery: ok"

block archiveEngineExhaustedSticky:
  ## Third archive: engine sticky revise after exhaustion (no provider body).
  let meta = parseJson(readFile(inj / "archive_api_engine_exhausted.json"))
  doAssert meta{"verdict"}.getStr == "revise_plan_needed"
  let store = tmpPath("arch3") & ".sqlite"
  let art = tmpPath("arch3_art")
  createDir(art)
  seedPlan(store, art, "arch3")
  var req = defaultProjectRequest()
  req.storePath = store
  req.projectId = "arch3"
  req.cwd = fix
  req.route = "inject"
  req.injectPath = inj / "step_multi_proposal.json"
  req.injectRecoveryPath = inj / "step_recovery_still_multi.json"
  req.worktree = tmpPath("arch3_w")
  req.artifactDir = art
  let r = projectStep(req)
  doAssert r.doc.recoveryExhausted
  doAssert r.doc.revisePlanPending
  doAssert r.doc.nextAction == "revise"
  var st = defaultProjectRequest()
  st.storePath = store
  st.projectId = "arch3"
  doAssert projectResume(st).report{"resume"}{"action"}.getStr == "revise"
  echo "archive_engine_exhausted_sticky: ok"

# --- Insert before/after unique anchor ---
block insertAfterUnique:
  let content = readFile(fix / "src" / "demo_tasks.nim")
  let edits = @[TextEdit(
    oldText: "  of \"list\", \"\":\n    echo formatList(loadTasks())\n",
    newText: "  of \"export-csv\":\n    echo \"id,title\"\n",
    op: "insert_after")]
  let applied = applyEditsToContent(content, edits)
  doAssert applied.ok, applied.message
  doAssert "export-csv" in applied.content
  let dec = parseFixDecision("""{"target_file":"src/demo_tasks.nim","edits":[{"insertAfter":"case cmd\n","newText":"  # inserted\n"}]}""")
  doAssert dec.parseOk
  doAssert dec.edits[0].op == "insert_after"
  let diag = diagnoseRawAgainstTree(fix, pretty(%*{
    "target_file": "src/demo_tasks.nim",
    "edits": [{"insertAfter": "case cmd\n", "newText": "  # x\n"}]
  }))
  doAssert not diag.needsRefuse, diag.refuseCode
  doAssert diag.edits[0].note == "insert_after_unique"
  echo "insert_after_unique: ok"

# --- 1) Two simultaneous starts → one provider attempt ---
block concurrentRunLease:
  let store = tmpPath("lease") & ".sqlite"
  let art = tmpPath("lease_art")
  createDir(art)
  let s = openProjectStore(store)
  let a = claimProjectRunLease(s, "lease_demo")
  doAssert a.ok, a.message
  let b = claimProjectRunLease(s, "lease_demo")
  doAssert not b.ok
  doAssert b.alreadyHeld
  releaseProjectRunLease(s, "lease_demo")
  closeProjectStore(s)

  var r1 = defaultProjectRequest()
  r1.storePath = store
  r1.projectId = "lease_demo"
  r1.cwd = fix
  r1.objective = "Je veux pouvoir exporter mes tâches."
  r1.refinement = "CSV sur stdout; garder list."
  r1.route = "inject"
  r1.injectDir = inj
  r1.artifactDir = art
  r1.worktree = tmpPath("lease_wt")
  let s2 = openProjectStore(store)
  discard claimProjectRunLease(s2, "lease_demo")
  var r2 = r1
  let blocked = projectRun(r2)
  doAssert not blocked.ok
  doAssert blocked.verdict == "already_running", blocked.verdict
  doAssert blocked.providerCallsThisCommand == 0
  doAssert blocked.apiCallsThisCommand == 0
  releaseProjectRunLease(s2, "lease_demo")
  closeProjectStore(s2)
  echo "concurrent_run_lease: ok"

# --- run↔step cannot double-spend; unknown visible after interrupt ---
block runStepMutexAndUnknown:
  let store = tmpPath("mutex") & ".sqlite"
  let art = tmpPath("mutex_art")
  createDir(art)
  seedPlan(store, art, "mutex_demo")
  # Simulate live step owner (this pid) with unknown attempt.
  let s = openProjectStore(store)
  var loaded = loadProject(s, "mutex_demo")
  doAssert loaded.ok
  var doc = loaded.doc
  for i, st in doc.steps.mpairs:
    if st.id == "add_csv_helpers":
      doc.steps[i].status = ssRunning
      doc.steps[i].result = %*{
        "provider_attempt": {
          "status": "unknown",
          "owner_pid": getCurrentProcessId(),
          "started_at": "2026-01-01T00:00:00Z",
          "route": "inject"
        }
      }
  saveProject(s, doc)
  closeProjectStore(s)

  var runReq = defaultProjectRequest()
  runReq.storePath = store
  runReq.projectId = "mutex_demo"
  runReq.cwd = fix
  runReq.route = "inject"
  runReq.injectDir = inj
  runReq.artifactDir = art
  runReq.worktree = tmpPath("mutex_run")
  let runBlocked = projectRun(runReq)
  doAssert runBlocked.verdict == "already_running", runBlocked.verdict
  doAssert runBlocked.providerCallsThisCommand == 0

  # Kill simulation: mark owner dead pid → resume keeps unknown visible.
  let s2 = openProjectStore(store)
  loaded = loadProject(s2, "mutex_demo")
  doc = loaded.doc
  for i, st in doc.steps.mpairs:
    if st.id == "add_csv_helpers":
      doc.steps[i].result{"provider_attempt"}{"owner_pid"} = %(-1)
      doc.steps[i].result{"provider_attempt"}{"status"} = %"unknown"
      doc.steps[i].status = ssRunning
  saveProject(s2, doc)
  closeProjectStore(s2)
  var stReq = defaultProjectRequest()
  stReq.storePath = store
  stReq.projectId = "mutex_demo"
  let resumed = projectResume(stReq)
  doAssert resumed.verdict == "interrupted", resumed.verdict
  doAssert resumed.report{"resume"}{"provider_attempt_unknown"}.getBool
  doAssert resumed.report{"resume"}{"action"}.getStr == "retry_step"
  echo "run_step_mutex_unknown: ok"

# --- 2) Exhausted recovery survives restart → different decision ---
block recoveryExhaustedSticky:
  let store = tmpPath("exh") & ".sqlite"
  let art = tmpPath("exh_art")
  createDir(art)
  seedPlan(store, art, "exh_demo")
  var req = defaultProjectRequest()
  req.storePath = store
  req.projectId = "exh_demo"
  req.cwd = fix
  req.route = "inject"
  req.injectPath = inj / "step_multi_proposal.json"
  req.injectRecoveryPath = inj / "step_recovery_still_multi.json"
  req.worktree = tmpPath("exh_wt")
  req.artifactDir = art
  let r = projectStep(req)
  doAssert not r.ok
  doAssert r.verdict == "recovery_exhausted" or r.doc.recoveryExhausted,
    r.verdict & " exh=" & $r.doc.recoveryExhausted
  doAssert r.doc.recoveryExhausted
  doAssert r.doc.revisePlanPending
  doAssert r.doc.nextAction == "revise"
  let fingerprint = r.doc.recoveryExhaustedFingerprint

  var st = defaultProjectRequest()
  st.storePath = store
  st.projectId = "exh_demo"
  let status = projectStatus(st)
  doAssert status.doc.recoveryExhausted
  doAssert status.verdict in ["revise_plan_needed", "recovery_exhausted"] or
           status.doc.revisePlanPending
  let resume = projectResume(st)
  doAssert resume.report{"resume"}{"action"}.getStr == "revise"
  var step2 = req
  step2.injectPath = inj / "step_helpers.json"
  step2.injectRecoveryPath = ""
  let blocked = projectStep(step2)
  doAssert blocked.providerCallsThisCommand == 0
  doAssert blocked.verdict == "revise_plan_needed"
  doAssert blocked.doc.recoveryExhaustedFingerprint == fingerprint
  doAssert blocked.doc.nextAction == "revise"
  echo "recovery_exhausted_sticky: ok"

# --- Equivalent revise preserves motif ---
block equivalentReviseKeepsMotif:
  let store = tmpPath("eq") & ".sqlite"
  let art = tmpPath("eq_art")
  createDir(art)
  seedPlan(store, art, "eq_demo")
  var req = defaultProjectRequest()
  req.storePath = store
  req.projectId = "eq_demo"
  req.cwd = fix
  req.route = "inject"
  req.injectPath = inj / "step_multi_proposal.json"
  req.injectRecoveryPath = inj / "step_recovery_still_multi.json"
  req.worktree = tmpPath("eq_wt")
  req.artifactDir = art
  let r = projectStep(req)
  doAssert r.doc.revisePlanPending
  let motif = r.doc.revisePlanReason
  doAssert motif.len > 0
  var rev = defaultProjectRequest()
  rev.storePath = store
  rev.projectId = "eq_demo"
  rev.cwd = fix
  rev.route = "inject"
  rev.injectPath = inj / "plan_revise_equivalent.json"
  # Empty refinement → motif drives revise.
  let eq = projectRevise(rev)
  doAssert eq.verdict == "revise_equivalent", eq.verdict
  doAssert eq.doc.revisePlanPending
  doAssert eq.doc.revisePlanReason == motif
  doAssert eq.doc.nextAction == "revise"
  echo "equivalent_revise_keeps_motif: ok"

# --- Run auto-revise after exhaustion within budget ---
block runAutoReviseAfterExhaustion:
  let store = tmpPath("auto") & ".sqlite"
  let art = tmpPath("auto_art")
  createDir(art)
  seedPlan(store, art, "auto_demo")
  # Pre-exhaust via step, then run should auto-revise with plan_v3.
  var req = defaultProjectRequest()
  req.storePath = store
  req.projectId = "auto_demo"
  req.cwd = fix
  req.route = "inject"
  req.injectPath = inj / "step_multi_proposal.json"
  req.injectRecoveryPath = inj / "step_recovery_still_multi.json"
  req.worktree = tmpPath("auto_pre")
  req.artifactDir = art
  doAssert projectStep(req).doc.recoveryExhausted
  var runReq = defaultProjectRequest()
  runReq.storePath = store
  runReq.projectId = "auto_demo"
  runReq.cwd = fix
  runReq.objective = "Je veux pouvoir exporter mes tâches."
  runReq.route = "inject"
  runReq.injectDir = inj
  runReq.artifactDir = art
  runReq.worktree = tmpPath("auto_run")
  runReq.maxAutoRevises = 1
  let run = projectRun(runReq)
  # Either done (auto-revise + steps) or revise_equivalent / blocked with motif.
  doAssert run.report.hasKey("interventions")
  var sawAuto = false
  for it in run.report{"interventions"}:
    if it{"kind"}.getStr == "revise:auto":
      sawAuto = true
  doAssert sawAuto, $run.report{"interventions"}
  echo "run_auto_revise_after_exhaustion: ok verdict=", run.verdict

# --- 3) Comment-only fails for export_command mid-plan ---
block commentOnlyFailsExport:
  let store = tmpPath("cmt") & ".sqlite"
  let art = tmpPath("cmt_art")
  createDir(art)
  seedPlan(store, art, "cmt_demo")
  var h = defaultProjectRequest()
  h.storePath = store
  h.projectId = "cmt_demo"
  h.cwd = fix
  h.route = "inject"
  h.injectPath = inj / "step_helpers.json"
  h.worktree = tmpPath("cmt_wt1")
  h.artifactDir = art
  let r1 = projectStep(h)
  doAssert r1.ok, r1.verdict & " " & r1.message
  var c = h
  c.injectPath = inj / "step_comment_only.json"
  c.worktree = tmpPath("cmt_wt2")
  let r2 = projectStep(c)
  doAssert not r2.ok, "comment-only must fail"
  doAssert r2.verdict == "verify_failed", r2.verdict
  doAssert "export" in r2.message.toLowerAscii or "csv" in r2.message.toLowerAscii or
           "mismatch" in r2.message.toLowerAscii or "list_mismatch" in r2.message,
           r2.message
  echo "comment_only_fails_export: ok"

# --- Old compile+list proof cannot cover export added by revise ---
block proofDroppedWhenExportAdded:
  let store = tmpPath("proof") & ".sqlite"
  let art = tmpPath("proof_art")
  createDir(art)
  seedPlan(store, art, "proof_demo")
  var h = defaultProjectRequest()
  h.storePath = store
  h.projectId = "proof_demo"
  h.cwd = fix
  h.route = "inject"
  h.injectPath = inj / "step_helpers.json"
  h.worktree = tmpPath("proof_wt")
  h.artifactDir = art
  doAssert projectStep(h).ok
  var rev = h
  rev.refinement = "Les helpers doivent aussi prouver export-csv."
  rev.injectPath = inj / "plan_revise_add_export_criteria.json"
  let revised = projectRevise(rev)
  doAssert revised.ok, revised.verdict
  var helpersPending = false
  var dropped = false
  for s in revised.doc.steps:
    if s.id == "add_csv_helpers":
      doAssert s.status != ssDone, "compile+list proof must not cover export_command"
      helpersPending = true
  for d in revised.report{"proof_dropped"}:
    if d{"id"}.getStr == "add_csv_helpers":
      dropped = true
      doAssert d{"reason"}.getStr == "proof_does_not_cover_criteria"
  doAssert helpersPending and dropped
  echo "proof_dropped_when_export_added: ok"

# --- Proof retention when criteria still covered ---
block proofRetention:
  let store = tmpPath("keep") & ".sqlite"
  let art = tmpPath("keep_art")
  createDir(art)
  seedPlan(store, art, "keep_demo")
  var h = defaultProjectRequest()
  h.storePath = store
  h.projectId = "keep_demo"
  h.cwd = fix
  h.route = "inject"
  h.injectPath = inj / "step_helpers.json"
  h.worktree = tmpPath("keep_wt")
  h.artifactDir = art
  doAssert projectStep(h).ok
  var rev = h
  rev.refinement = "Conserver helpers; préciser export."
  rev.injectPath = inj / "plan_v2.json"
  let revised = projectRevise(rev)
  doAssert revised.ok
  var kept = false
  for s in revised.doc.steps:
    if s.id == "add_csv_helpers" and s.status == ssDone:
      kept = true
  doAssert kept, "helpers proof should be retained when criteria still covered"
  doAssert revised.report.hasKey("proof_kept")
  echo "proof_retention: ok"

# --- Full project run inject walk ---
block projectRunInject:
  let store = tmpPath("full") & ".sqlite"
  let art = tmpPath("full_art")
  createDir(art)
  var req = defaultProjectRequest()
  req.storePath = store
  req.projectId = "full_demo"
  req.cwd = fix
  req.objective = "Je veux pouvoir exporter mes tâches."
  req.refinement = "CSV sur stdout; garder list par défaut."
  req.route = "inject"
  req.injectDir = inj
  req.artifactDir = art
  req.worktree = tmpPath("full_wt")
  let r = projectRun(req)
  doAssert r.ok, r.verdict & " / " & r.message & " / " & $r.report
  doAssert r.verdict == "done", r.verdict
  doAssert r.doc.acceptedTreeRef.len > 0
  # Ask counted in interventions
  var askCalls = -1
  for it in r.report{"interventions"}:
    if it{"kind"}.getStr == "ask":
      askCalls = it{"provider_calls"}.getInt
  doAssert askCalls == 1, "ask intervention must report 1 provider call"
  let v = verifyCsvJourney(r.doc.acceptedTreeRef, fix, requireCsv = true)
  doAssert v.ok, v.message
  echo "project_run_inject: ok"

echo "ALL project run regression tests passed"
