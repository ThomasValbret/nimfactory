## Shared project write commands (Studio + CLI). Idempotent by command_id.
import std/[json, tables, times, os, sequtils, strutils]
import nimfactory/project/[pipeline, types, store, tree_id]
import nimfactory/runtime/journal/[run_store, sqlite_ffi]

const
  CommandSchema* = "nimfactory.project_command/v1"
  AskPlanCommand* = "ask_plan"
  RevisePlanCommand* = "revise_plan"
  RunCommand* = "run"
  ResumeCommand* = "resume"
  PauseAfterStepCommand* = "pause_after_step"

type
  CommandPhase* = enum
    cpFresh
    cpActive
    cpDone
    cpAbsent

  CommandRecord* = object
    phase*: CommandPhase
    body*: JsonNode

proc commandTransitionId*(commandId: string): string =
  "project.cmd:" & commandId

proc loadCommandRecord*(store: SqliteRunStore; projectId, commandId: string): CommandRecord =
  result.phase = cpAbsent
  result.body = newJNull()
  if commandId.len == 0:
    return
  let rows = store.db.queryAll(
    "SELECT transition_json FROM nf_transitions WHERE run_id = ? AND transition_id = ?",
    [projectRunId(projectId), commandTransitionId(commandId)])
  if rows.len == 0:
    return
  let body = parseJson(rows[0])
  result.body = body
  result.phase = if body{"status"}.getStr == "done": cpDone else: cpActive

proc loadCommandReceipt*(storePath, projectId, commandId: string): JsonNode =
  ## Readonly-friendly receipt lookup for Studio GET.
  let store = openProjectStore(storePath)
  defer: closeProjectStore(store)
  let rec = loadCommandRecord(store, projectId, commandId)
  if rec.phase == cpAbsent:
    return newJNull()
  result = rec.body.copy()
  result["phase"] = %($rec.phase)

proc claimCommandActive*(
    store: SqliteRunStore; projectId, commandId, command: string;
    expectedPlanVersion: int; refinement: string): CommandRecord =
  result.phase = cpAbsent
  result.body = newJNull()
  if commandId.len == 0:
    return
  let rid = projectRunId(projectId)
  store.ensureRunId(rid)
  store.db.execSql("BEGIN IMMEDIATE")
  try:
    let rows = store.db.queryAll(
      "SELECT transition_json FROM nf_transitions WHERE run_id = ? AND transition_id = ?",
      [rid, commandTransitionId(commandId)])
    if rows.len > 0:
      let body = parseJson(rows[0])
      result.body = body
      result.phase = if body{"status"}.getStr == "done": cpDone else: cpActive
      store.db.execSql("COMMIT")
      return
    let body = %*{
      "schema": CommandSchema,
      "status": "active",
      "command": command,
      "command_id": commandId,
      "project_id": projectId,
      "expected_plan_version": expectedPlanVersion,
      "refinement": refinement,
      "holder_pid": getCurrentProcessId(),
      "started_ts": $epochTime()
    }
    store.db.runPrepared(
      "INSERT INTO nf_transitions(run_id, transition_id, transition_json) VALUES(?, ?, ?)",
      [rid, commandTransitionId(commandId), $body])
    store.db.execSql("COMMIT")
    result.phase = cpFresh
    result.body = body
  except CatchableError:
    store.db.execSql("ROLLBACK")
    raise

proc finishCommandRecord*(
    store: SqliteRunStore; projectId, commandId: string; receipt: JsonNode) =
  if commandId.len == 0:
    return
  var body = if receipt.isNil: newJObject() else: receipt.copy()
  body["schema"] = %CommandSchema
  body["status"] = %"done"
  body["command_id"] = %commandId
  body["project_id"] = %projectId
  body["finished_ts"] = %($epochTime())
  let rid = projectRunId(projectId)
  store.db.execSql("BEGIN IMMEDIATE")
  try:
    let existing = store.db.queryAll(
      "SELECT 1 FROM nf_transitions WHERE run_id = ? AND transition_id = ?",
      [rid, commandTransitionId(commandId)])
    if existing.len == 0:
      store.db.runPrepared(
        "INSERT INTO nf_transitions(run_id, transition_id, transition_json) VALUES(?, ?, ?)",
        [rid, commandTransitionId(commandId), $body])
    else:
      store.db.runPrepared(
        "UPDATE nf_transitions SET transition_json = ? WHERE run_id = ? AND transition_id = ?",
        [$body, rid, commandTransitionId(commandId)])
    store.db.execSql("COMMIT")
  except CatchableError:
    store.db.execSql("ROLLBACK")
    raise

proc planDelta*(before, after: seq[ProjectStep]): JsonNode =
  var beforeSet = initTable[string, ProjectStep]()
  var afterSet = initTable[string, ProjectStep]()
  for s in before: beforeSet[s.id] = s
  for s in after: afterSet[s.id] = s
  var added = newJArray()
  var removed = newJArray()
  var kept = newJArray()
  var droppedAccepted = newJArray()
  for s in after:
    if s.id in beforeSet:
      kept.add(%*{"id": s.id, "title": s.title})
    else:
      added.add(%*{"id": s.id, "title": s.title})
  for s in before:
    if s.id notin afterSet:
      removed.add(%*{"id": s.id, "title": s.title, "status": $s.status})
      if s.status == ssDone:
        let tree = if s.result.isNil: "" else: s.result{"accepted_tree_hash"}.getStr
        droppedAccepted.add(%*{"id": s.id, "title": s.title, "accepted_tree_hash": tree})
  result = %*{
    "added": added,
    "removed": removed,
    "kept": kept,
    "accepted_steps_dropped": droppedAccepted
  }

proc annotateSpend*(receipt: JsonNode; newProvider, newApi: int; replayed: bool) =
  let historicalProvider = if replayed: receipt{"provider_calls"}.getInt(newProvider) else: 0
  let historicalApi = if replayed: receipt{"api_calls"}.getInt(newApi) else: 0
  if replayed:
    receipt["historical_provider_calls"] = %historicalProvider
    receipt["historical_api_calls"] = %historicalApi
    receipt["new_provider_calls"] = %0
    receipt["new_api_calls"] = %0
    receipt["provider_calls"] = %historicalProvider
    receipt["api_calls"] = %historicalApi
  else:
    receipt["historical_provider_calls"] = %0
    receipt["historical_api_calls"] = %0
    receipt["new_provider_calls"] = %newProvider
    receipt["new_api_calls"] = %newApi
    receipt["provider_calls"] = %newProvider
    receipt["api_calls"] = %newApi
  receipt["replayed"] = %replayed

proc reportFromReceipt*(receipt: JsonNode): ProjectReport =
  ## Historical replay of a finished command_id: zero new spend; surface limits.
  result.command = receipt{"command"}.getStr
  result.projectId = receipt{"project_id"}.getStr
  result.ok = receipt{"ok"}.getBool
  result.verdict = receipt{"verdict"}.getStr
  result.message = receipt{"message"}.getStr
  result.providerCallsThisCommand = receipt{"provider_calls"}.getInt
  result.apiCallsThisCommand = receipt{"api_calls"}.getInt
  result.report = receipt.copy()
  annotateSpend(result.report, 0, 0, true)
  result.report["historical_receipt"] = %true
  var limits = newJArray()
  if not result.report.hasKey("controls_executed"):
    limits.add(%"pre_controls_v2")
  else:
    var legacy = false
    for c in result.report{"controls_executed"}:
      if c{"status"}.getStr.endsWith("_legacy") or
         c.hasKey("receipt_limits"):
        legacy = true
      if not c.hasKey("file_fingerprints"):
        limits.add(%"missing_file_fingerprints")
        break
    if legacy: limits.add(%"pre_per_control_observations")
  if limits.len > 0:
    result.report["receipt_limits"] = limits
  # Resolve tree path/hash from top-level, delivered_*, or attempt (legacy receipts).
  let body = result.report
  proc pickStr(node: JsonNode; keys: openArray[string]): string =
    for k in keys:
      if node.hasKey(k) and node[k].kind == JString:
        let s = node[k].getStr
        if s.len > 0: return s
    ""
  var tree = pickStr(body, ["accepted_tree_ref", "delivered_tree", "proof_tree_ref"])
  var proofHash = pickStr(body, ["accepted_tree_hash", "delivered_hash", "proof_tree_hash"])
  let attempt = body{"attempt"}
  if attempt != nil and attempt.kind == JObject:
    if tree.len == 0: tree = attempt{"accepted_tree_ref"}.getStr
    if proofHash.len == 0: proofHash = attempt{"accepted_tree_hash"}.getStr
  body["proof_tree_ref"] = %tree
  body["proof_tree_hash"] = %proofHash
  if tree.len > 0 and not body.hasKey("accepted_tree_ref"):
    body["accepted_tree_ref"] = %tree
  if proofHash.len > 0 and not body.hasKey("accepted_tree_hash"):
    body["accepted_tree_hash"] = %proofHash
  if tree.len > 0 and dirExists(tree):
    body["proof_tree_present"] = %true
    let live = treeFingerprint(tree)
    body["files_current_hash"] = %live
    body["proof_matches_files"] = %(proofHash.len > 0 and live == proofHash)
    body["proof_freshness"] =
      %(if proofHash.len > 0 and live == proofHash: "fresh" else: "stale")
    if proofHash.len > 0 and live != proofHash:
      body["proof_freshness_motif"] = %(
        "historical proof hash " & proofHash & " ≠ current files " & live)
  else:
    body["proof_tree_present"] = %false
    body["proof_matches_files"] = %false
    body["proof_freshness"] = %"absent"
  body["distinguished_from_current_files"] = %true

proc buildReviseReceipt*(
    req: ProjectRequest; prep: ProjectReport; fromVersion: int;
    beforeSteps: seq[ProjectStep]; replayed: bool): JsonNode =
  let toVersion =
    if prep.doc.currentPlanVersion > 0: prep.doc.currentPlanVersion
    else: fromVersion
  result = %*{
    "schema": CommandSchema,
    "command": RevisePlanCommand,
    "command_id": req.commandId,
    "project_id": req.projectId,
    "ok": prep.ok,
    "verdict": prep.verdict,
    "message": prep.message,
    "from_version": fromVersion,
    "to_version": toVersion,
    "expected_plan_version": req.expectedPlanVersion,
    "refinement": req.refinement,
    "plan_delta": planDelta(beforeSteps, prep.doc.steps),
    "next_action": prep.doc.nextAction,
    "current_plan_version": prep.doc.currentPlanVersion,
    "last_verdict": prep.doc.lastVerdict,
    "blocked_reason": prep.doc.blockedReason,
    "revise_plan_pending": prep.doc.revisePlanPending
  }
  annotateSpend(result, prep.providerCallsThisCommand, prep.apiCallsThisCommand, replayed)
  if prep.report != nil:
    for key in ["provider", "artifacts", "untested", "usage_by_role", "steps",
                "plan_versions", "refinements", "proof_kept", "proof_dropped"]:
      if prep.report.hasKey(key):
        result[key] = prep.report[key]

proc buildGenericReceipt*(
    command: string; req: ProjectRequest; prep: ProjectReport; replayed: bool): JsonNode =
  result = %*{
    "schema": CommandSchema,
    "command": command,
    "command_id": req.commandId,
    "project_id": req.projectId,
    "ok": prep.ok,
    "verdict": prep.verdict,
    "message": prep.message,
    "next_action": prep.doc.nextAction,
    "current_plan_version": prep.doc.currentPlanVersion,
    "last_verdict": prep.doc.lastVerdict,
    "blocked_reason": prep.doc.blockedReason,
    "pause_after_step": req.pauseAfterStep
  }
  annotateSpend(result, prep.providerCallsThisCommand, prep.apiCallsThisCommand, replayed)
  if prep.report != nil:
    for key in ["provider", "artifacts", "untested", "usage_by_role", "steps",
                "plan_versions", "refinements", "interventions", "blocked",
                "proof_kept", "proof_dropped", "paused_after_step", "resume",
                "provider_calls_this_command", "api_calls_this_command",
                "diff_origin", "attempt", "controls_requested",
                "controls_executed", "observations", "delivered_tree",
                "delivered_hash", "proof_tree_ref", "proof_tree_hash",
                "files_current_hash", "proof_matches_files", "proof_freshness",
                "proof_freshness_motif", "verify_recheck"]:
      if prep.report.hasKey(key):
        result[key] = prep.report[key]

proc beginOrReplay(
    store: SqliteRunStore; req: ProjectRequest; command: string): tuple[
    early: bool; report: ProjectReport] =
  result.early = false
  if req.commandId.len == 0:
    return
  let claimed = claimCommandActive(
    store, req.projectId, req.commandId, command,
    req.expectedPlanVersion, req.refinement)
  case claimed.phase
  of cpDone:
    result.early = true
    result.report = reportFromReceipt(claimed.body)
  of cpActive:
    result.early = true
    result.report.ok = false
    result.report.command = command
    result.report.projectId = req.projectId
    result.report.verdict = "command_active"
    result.report.message = "command_id already active or outcome unknown: " & req.commandId
    result.report.providerCallsThisCommand = 0
    result.report.report = claimed.body.copy()
    result.report.report["ok"] = %false
    result.report.report["verdict"] = %"command_active"
    result.report.report["message"] = %result.report.message
    annotateSpend(result.report.report, 0, 0, true)
  of cpFresh, cpAbsent:
    discard

proc bindReviseInject*(req: var ProjectRequest; fromVersion: int) =
  ## When Studio/CLI only has --inject-dir, pick the next plan fixture.
  if req.injectPath.len > 0 or req.injectDir.len == 0:
    return
  let candidates = @[
    "plan_v" & $(fromVersion + 1) & ".json",
    "plan_v3_after_revise.json",
    "plan_v2.json"
  ]
  for name in candidates:
    let p = req.injectDir / name
    if fileExists(p):
      req.injectPath = p
      return

proc executeRevisePlan*(req: ProjectRequest): ProjectReport =
  if req.storePath.len == 0:
    result.ok = false
    result.command = "revise"
    result.verdict = "invalid"
    result.message = "revise requires --store"
    result.report = %*{
      "schema": CommandSchema, "command": RevisePlanCommand, "ok": false,
      "verdict": "invalid", "message": result.message
    }
    return

  let store = openProjectStore(req.storePath)
  defer: closeProjectStore(store)
  let gate = beginOrReplay(store, req, RevisePlanCommand)
  if gate.early: return gate.report

  let loaded = loadProject(store, req.projectId)
  if not loaded.ok:
    result.ok = false
    result.command = "revise"
    result.projectId = req.projectId
    result.verdict = "missing"
    result.message = loaded.err
    result.report = %*{
      "schema": CommandSchema, "command": RevisePlanCommand, "ok": false,
      "verdict": "missing", "message": result.message, "command_id": req.commandId
    }
    annotateSpend(result.report, 0, 0, false)
    if req.commandId.len > 0:
      finishCommandRecord(store, req.projectId, req.commandId, result.report)
    return

  let fromVersion = loaded.doc.currentPlanVersion
  let beforeSteps = loaded.doc.steps
  if req.expectPlanVersion and fromVersion != req.expectedPlanVersion:
    result.ok = false
    result.command = "revise"
    result.projectId = req.projectId
    result.verdict = "stale_plan_version"
    result.message = "expected plan v" & $req.expectedPlanVersion &
      " but project is at v" & $fromVersion
    result.doc = loaded.doc
    result.report = buildReviseReceipt(req, result, fromVersion, beforeSteps, false)
    result.report["ok"] = %false
    result.report["verdict"] = %result.verdict
    result.report["message"] = %result.message
    if req.commandId.len > 0:
      finishCommandRecord(store, req.projectId, req.commandId, result.report)
    return

  var work = req
  bindReviseInject(work, fromVersion)
  result = projectRevise(work)
  let receipt = buildReviseReceipt(work, result, fromVersion, beforeSteps, false)
  result.report = receipt
  if work.commandId.len > 0:
    finishCommandRecord(store, work.projectId, work.commandId, receipt)

proc bindAskInject*(req: var ProjectRequest) =
  if req.injectPath.len > 0: return
  if req.injectDir.len == 0: return
  let p = req.injectDir / "plan_v1.json"
  if fileExists(p): req.injectPath = p

proc executeAskPlan*(req: ProjectRequest): ProjectReport =
  ## Nouveau projet → demande → aperçu local (plan v1, sans step).
  if req.storePath.len == 0 or req.projectId.len == 0:
    result.ok = false
    result.command = AskPlanCommand
    result.verdict = "invalid"
    result.message = "ask_plan requires --store and --project-id"
    result.report = %*{
      "schema": CommandSchema, "command": AskPlanCommand, "ok": false,
      "verdict": "invalid", "message": result.message
    }
    return
  if req.objective.len == 0:
    result.ok = false
    result.command = AskPlanCommand
    result.verdict = "invalid"
    result.message = "ask_plan requires an objective"
    result.report = %*{
      "schema": CommandSchema, "command": AskPlanCommand, "ok": false,
      "verdict": "invalid", "message": result.message
    }
    return
  let store = openProjectStore(req.storePath)
  defer: closeProjectStore(store)
  let gate = beginOrReplay(store, req, AskPlanCommand)
  if gate.early: return gate.report
  var work = req
  bindAskInject(work)
  result = projectAsk(work)
  result.command = AskPlanCommand
  let receipt = buildGenericReceipt(AskPlanCommand, work, result, false)
  if result.ok:
    receipt["preview"] = %*{
      "plan_version": result.doc.currentPlanVersion,
      "steps": result.doc.steps.mapIt(%*{
        "id": it.id, "title": it.title, "depends_on": it.dependsOn,
        "criteria": it.criteria
      }),
      "next_action": result.doc.nextAction,
      "summary":
        if result.doc.planVersions.len > 0: result.doc.planVersions[^1].summary
        else: ""
    }
  result.report = receipt
  if work.commandId.len > 0:
    finishCommandRecord(store, work.projectId, work.commandId, receipt)

proc performProjectCommand*(command: string; req: ProjectRequest): ProjectReport =
  ## Engine work only — caller owns claim/finish for command_id.
  var work = req
  if command == PauseAfterStepCommand:
    work.pauseAfterStep = true
    if work.maxSteps == 0: work.maxSteps = 1
  case command
  of AskPlanCommand:
    bindAskInject(work)
    result = projectAsk(work)
    result.command = command
  of ResumeCommand:
    result = projectResume(work)
    if result.doc.nextAction in ["step", "revise_or_step", "retry_step"] or
       result.verdict in ["ok", "ready", "interrupted", ""]:
      ## Continue the walk after resume when the engine points back to step work.
      if result.doc.nextAction in ["step", "revise_or_step", "retry_step"]:
        var cont = work
        cont.pauseAfterStep = work.pauseAfterStep
        let continued = projectRun(cont)
        let priorProvider = result.providerCallsThisCommand
        let priorApi = result.apiCallsThisCommand
        result = continued
        result.providerCallsThisCommand = priorProvider + continued.providerCallsThisCommand
        result.apiCallsThisCommand = priorApi + continued.apiCallsThisCommand
    result.command = command
  of RunCommand, PauseAfterStepCommand:
    result = projectRun(work)
    result.command = command
  of RevisePlanCommand:
    block:
      let st = openProjectStore(work.storePath)
      defer: closeProjectStore(st)
      let cur = loadProject(st, work.projectId)
      if cur.ok: bindReviseInject(work, cur.doc.currentPlanVersion)
    result = projectRevise(work)
    result.command = command
  else:
    result.ok = false
    result.command = command
    result.verdict = "unsupported_command"
    result.message = "unsupported command: " & command

proc finishPerformedCommand*(
    command: string; req: ProjectRequest; prep: ProjectReport;
    beforeSteps: seq[ProjectStep] = @[]; fromVersion = -1): JsonNode =
  if command == RevisePlanCommand:
    let fv = if fromVersion >= 0: fromVersion else: prep.doc.currentPlanVersion
    result = buildReviseReceipt(req, prep, fv, beforeSteps, false)
  else:
    result = buildGenericReceipt(command, req, prep, false)

proc executeProjectCommand*(command: string; req: ProjectRequest): ProjectReport =
  ## Studio/CLI entry for ask_plan, run, resume, pause_after_step, revise_plan.
  if command == RevisePlanCommand:
    return executeRevisePlan(req)
  if command == AskPlanCommand:
    return executeAskPlan(req)
  if command notin [RunCommand, PauseAfterStepCommand, ResumeCommand]:
    result.ok = false
    result.command = command
    result.verdict = "unsupported_command"
    result.message = "unsupported command: " & command
    result.report = %*{
      "schema": CommandSchema, "command": command, "ok": false,
      "verdict": "unsupported_command", "message": result.message
    }
    return

  if req.storePath.len == 0:
    result.ok = false
    result.command = command
    result.verdict = "invalid"
    result.message = command & " requires --store"
    result.report = %*{
      "schema": CommandSchema, "command": command, "ok": false,
      "verdict": "invalid", "message": result.message
    }
    return

  var work = req
  if command == PauseAfterStepCommand:
    work.pauseAfterStep = true
    work.maxSteps = 1

  let store = openProjectStore(work.storePath)
  defer: closeProjectStore(store)
  let gate = beginOrReplay(store, work, command)
  if gate.early: return gate.report

  result = performProjectCommand(command, work)
  let receipt = finishPerformedCommand(command, work, result)
  result.report = receipt
  if work.commandId.len > 0:
    finishCommandRecord(store, work.projectId, work.commandId, receipt)

proc parseStudioCommand*(body: JsonNode; base: ProjectRequest): ProjectRequest =
  result = base
  result.commandId = body{"command_id"}.getStr
  if body{"refinement"}.getStr.len > 0:
    result.refinement = body{"refinement"}.getStr
  if body{"objective"}.getStr.len > 0:
    result.objective = body{"objective"}.getStr
  if body.hasKey("expected_plan_version"):
    result.expectedPlanVersion = body{"expected_plan_version"}.getInt
    result.expectPlanVersion = true
  if body{"project_id"}.getStr.len > 0:
    result.projectId = body{"project_id"}.getStr
  if body{"pause_after_step"}.getBool:
    result.pauseAfterStep = true
    result.maxSteps = 1
  if body{"max_steps"}.getInt > 0:
    result.maxSteps = body{"max_steps"}.getInt
