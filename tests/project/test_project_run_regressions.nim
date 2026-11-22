## Three regressions that condition `project run`, plus a full inject walk.
## No OpenAI calls.

import std/[os, json, strutils, times]
import nimfactory/project/[pipeline, store, verify, types]

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
  doAssert projectAsk(ask).ok
  var rev = ask
  rev.refinement = "CSV sur stdout; garder list par défaut."
  rev.injectPath = inj / "plan_v2.json"
  doAssert projectRevise(rev).ok

# --- 1) Two simultaneous starts → one provider attempt ---
block concurrentRunLease:
  let store = tmpPath("lease") & ".sqlite"
  let art = tmpPath("lease_art")
  createDir(art)
  # First lease held by this process via claim, second refuses.
  let s = openProjectStore(store)
  let a = claimProjectRunLease(s, "lease_demo")
  doAssert a.ok, a.message
  let b = claimProjectRunLease(s, "lease_demo")
  doAssert not b.ok
  doAssert b.alreadyHeld
  releaseProjectRunLease(s, "lease_demo")
  closeProjectStore(s)

  # Two projectRun calls: seed then parallel — second already_running, 0 calls.
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
  # Hold lease while "running"
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

  # Simulate restart: reopen store, status/resume/step → no provider, different decision path.
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
  # Decision after restart is revise (not silent re-apply of same recovery).
  doAssert blocked.doc.nextAction == "revise"
  echo "recovery_exhausted_sticky: ok"

# --- 3) Comment-only fails for export_command step ---
block commentOnlyFailsExport:
  let store = tmpPath("cmt") & ".sqlite"
  let art = tmpPath("cmt_art")
  createDir(art)
  seedPlan(store, art, "cmt_demo")
  # Step 1 helpers ok
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
  # Step 2 comment-only must fail export_command criteria
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

# --- Proof retention after revise ---
block proofRetention:
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
  # Revise to plan that keeps add_csv_helpers with same criteria → proof kept
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
  # Binary behaviour on delivered tree
  let v = verifyCsvJourney(r.doc.acceptedTreeRef, fix, requireCsv = true)
  doAssert v.ok, v.message
  echo "project_run_inject: ok"

echo "ALL project run regression tests passed"
