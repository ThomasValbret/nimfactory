## Offline: multi-proposal refuse before write; one recovery turn ceiling.
## No OpenAI calls.

import std/[os, json, strutils, times]
import nimfactory/project/pipeline
import nimfactory/mission/apply

let root = getCurrentDir()
let fix = root / "fixtures" / "demo_tasks_cli"
let inj = fix / "inject"

proc tmpPath(tag: string): string =
  getTempDir() / ("nf_proj_" & tag & "_" & $getCurrentProcessId() & "_" &
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
  let r1 = projectAsk(ask)
  doAssert r1.ok, r1.message
  var rev = ask
  rev.refinement = "CSV sur stdout; garder list par défaut."
  rev.injectPath = inj / "plan_v2.json"
  let r2 = projectRevise(rev)
  doAssert r2.ok, r2.message

block countProposals:
  let raw = readFile(inj / "step_multi_proposal.json")
  let c = countFixProposals(raw)
  doAssert c.count == 2, $c.count
  doAssert "src/demo_tasks.nim" in c.targets
  doAssert "src/tasks.nim" in c.targets
  # Historical 150522Z second fence is missing a comma — still two proposals.
  let hist = root / "docs" / "qa" / "project_cli_journey" /
             "recovery_replay_20261122T152200Z" / "historical_first_raw.txt"
  if fileExists(hist):
    let h = countFixProposals(readFile(hist))
    doAssert h.count == 2, "historical multi count=" & $h.count & " targets=" & $h.targets
  echo "count_fix_proposals: ok"

block multiRefuseNoWrite:
  let store = tmpPath("multi") & ".sqlite"
  let art = tmpPath("multi_art")
  let wt = tmpPath("multi_wt")
  createDir(art)
  seedPlan(store, art, "multi_refuse")
  var req = defaultProjectRequest()
  req.storePath = store
  req.projectId = "multi_refuse"
  req.cwd = fix
  req.route = "inject"
  req.injectPath = inj / "step_multi_proposal.json"
  req.worktree = wt
  req.artifactDir = art
  let r = projectStep(req)
  doAssert not r.ok
  doAssert r.verdict == "multi_proposal_refused", r.verdict
  doAssert r.report{"refuse_code"}.getStr == "multi_proposal"
  doAssert r.report{"apply"}{"wrote"}.getBool == false
  doAssert not r.recoveryAttempted
  doAssert not dirExists(wt) or not fileExists(wt / "src" / "demo_tasks.nim")
  # Source fixture untouched.
  let src = readFile(fix / "src" / "demo_tasks.nim")
  doAssert "export-csv" notin src
  echo "multi_refuse_no_write: ok"

block oneRecoveryCeiling:
  let store = tmpPath("ceil") & ".sqlite"
  let art = tmpPath("ceil_art")
  let wt = tmpPath("ceil_wt")
  createDir(art)
  seedPlan(store, art, "ceil_rec")
  var req = defaultProjectRequest()
  req.storePath = store
  req.projectId = "ceil_rec"
  req.cwd = fix
  req.route = "inject"
  req.injectPath = inj / "step_multi_proposal.json"
  req.injectRecoveryPath = inj / "step_recovery_still_multi.json"
  req.worktree = wt
  req.artifactDir = art
  let r = projectStep(req)
  doAssert not r.ok
  doAssert r.recoveryTriggered
  doAssert r.recoveryAttempted
  doAssert r.recoveryReason == "multi_proposal"
  doAssert r.verdict == "multi_proposal_refused", r.verdict
  doAssert r.report{"apply"}{"recovery_exhausted"}.getBool == true
  doAssert r.providerCallsThisCommand == 2  # first inject + one recovery inject
  doAssert r.apiCallsThisCommand == 0
  # Still no write to occupied recovery targets as multi.
  doAssert r.report{"apply"}{"wrote"}.getBool == false
  echo "one_recovery_ceiling: ok"

block recoveryMayRevisePlan:
  let store = tmpPath("rev") & ".sqlite"
  let art = tmpPath("rev_art")
  let wt = tmpPath("rev_wt")
  createDir(art)
  seedPlan(store, art, "rev_plan")
  var req = defaultProjectRequest()
  req.storePath = store
  req.projectId = "rev_plan"
  req.cwd = fix
  req.route = "inject"
  req.injectPath = inj / "step_multi_proposal.json"
  req.injectRecoveryPath = inj / "step_recovery_revise_plan.json"
  req.worktree = wt
  req.artifactDir = art
  let r = projectStep(req)
  doAssert not r.ok
  doAssert r.verdict == "revise_plan_needed", r.verdict
  doAssert r.recoveryAttempted
  doAssert r.recoveryReason == "multi_proposal"
  doAssert r.report{"apply"}{"wrote"}.getBool == false
  echo "recovery_may_revise_plan: ok"

block ambiguousThenHelpers:
  let store = tmpPath("amb") & ".sqlite"
  let art = tmpPath("amb_art")
  let wt = tmpPath("amb_wt")
  createDir(art)
  seedPlan(store, art, "amb_ok")
  var req = defaultProjectRequest()
  req.storePath = store
  req.projectId = "amb_ok"
  req.cwd = fix
  req.route = "inject"
  req.injectPath = inj / "step_ambiguous_else.json"
  req.injectRecoveryPath = inj / "step_helpers.json"
  req.worktree = wt
  req.artifactDir = art
  let r = projectStep(req)
  doAssert r.recoveryTriggered
  doAssert r.recoveryAttempted
  doAssert r.recoveryReason == "anchor_ambiguous"
  doAssert r.providerCallsThisCommand == 2
  # helpers recovery should leave a compilable tree for step 1 of plan_v2
  doAssert r.ok, r.verdict & " / " & r.message
  doAssert r.verdict == "pass"
  doAssert r.report{"via_recovery"}.getBool == true
  echo "ambiguous_then_helpers: ok"

echo "ALL project step contract offline tests passed"
