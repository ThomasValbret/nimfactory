## Shared project write commands (Studio + CLI). Idempotent by command_id.
import std/[json, tables, times, os]
import nimfactory/project/[pipeline, types, store]
import nimfactory/runtime/journal/[run_store, sqlite_ffi]

const
  CommandSchema* = "nimfactory.project_command/v1"
  RevisePlanCommand* = "revise_plan"

type
  CommandPhase* = enum
    cpFresh      ## we just inserted the active marker
    cpActive     ## another attempt already holds this command_id
    cpDone       ## final receipt available
    cpAbsent     ## no command_id supplied

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

proc claimCommandActive*(
    store: SqliteRunStore; projectId, commandId, command: string;
    expectedPlanVersion: int; refinement: string): CommandRecord =
  ## Serialize on command_id: replay done, refuse concurrent active, else claim.
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

proc capabilitiesForDoc*(doc: ProjectDoc): JsonNode =
  var commands = newJArray()
  if doc.currentPlanVersion >= 1:
    commands.add(%RevisePlanCommand)
  result = %*{
    "commands": commands,
    "revise_plan_pending": doc.revisePlanPending,
    "revise_plan_reason": doc.revisePlanReason,
    "revise_plan_step_id": doc.revisePlanStepId,
    "revise_plan_at_version": doc.revisePlanAtVersion
  }

proc reportFromReceipt*(receipt: JsonNode): ProjectReport =
  result.command = "revise"
  result.projectId = receipt{"project_id"}.getStr
  result.ok = receipt{"ok"}.getBool
  result.verdict = receipt{"verdict"}.getStr
  result.message = receipt{"message"}.getStr
  result.providerCallsThisCommand = receipt{"provider_calls"}.getInt
  result.apiCallsThisCommand = receipt{"api_calls"}.getInt
  result.report = receipt.copy()
  result.report["replayed"] = %true

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
    "replayed": replayed,
    "from_version": fromVersion,
    "to_version": toVersion,
    "expected_plan_version": req.expectedPlanVersion,
    "refinement": req.refinement,
    "provider_calls": prep.providerCallsThisCommand,
    "api_calls": prep.apiCallsThisCommand,
    "plan_delta": planDelta(beforeSteps, prep.doc.steps),
    "next_action": prep.doc.nextAction,
    "current_plan_version": prep.doc.currentPlanVersion,
    "last_verdict": prep.doc.lastVerdict,
    "blocked_reason": prep.doc.blockedReason,
    "revise_plan_pending": prep.doc.revisePlanPending
  }
  if prep.report != nil:
    for key in ["provider", "artifacts", "untested", "usage_by_role", "steps",
                "plan_versions", "refinements"]:
      if prep.report.hasKey(key):
        result[key] = prep.report[key]

proc executeRevisePlan*(req: ProjectRequest): ProjectReport =
  ## Studio and CLI entry: same preconditions, idempotency and receipt.
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

  if req.commandId.len > 0:
    let claimed = claimCommandActive(
      store, req.projectId, req.commandId, RevisePlanCommand,
      req.expectedPlanVersion, req.refinement)
    case claimed.phase
    of cpDone:
      return reportFromReceipt(claimed.body)
    of cpActive:
      result.ok = false
      result.command = "revise"
      result.projectId = req.projectId
      result.verdict = "command_active"
      result.message = "command_id already active or outcome unknown: " & req.commandId
      result.providerCallsThisCommand = 0
      result.report = claimed.body.copy()
      result.report["ok"] = %false
      result.report["verdict"] = %"command_active"
      result.report["message"] = %result.message
      result.report["replayed"] = %true
      return
    of cpFresh, cpAbsent:
      discard

  let loaded = loadProject(store, req.projectId)
  if not loaded.ok:
    result.ok = false
    result.command = "revise"
    result.projectId = req.projectId
    result.verdict = "missing"
    result.message = loaded.err
    result.report = %*{
      "schema": CommandSchema, "command": RevisePlanCommand, "ok": false,
      "verdict": "missing", "message": result.message, "command_id": req.commandId,
      "provider_calls": 0, "api_calls": 0
    }
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
    result.providerCallsThisCommand = 0
    result.report = buildReviseReceipt(req, result, fromVersion, beforeSteps, false)
    result.report["ok"] = %false
    result.report["verdict"] = %result.verdict
    result.report["message"] = %result.message
    if req.commandId.len > 0:
      finishCommandRecord(store, req.projectId, req.commandId, result.report)
    return

  ## projectRevise opens its own store handle; keep ours only for the receipt.
  result = projectRevise(req)
  let receipt = buildReviseReceipt(req, result, fromVersion, beforeSteps, false)
  result.report = receipt
  if req.commandId.len > 0:
    finishCommandRecord(store, req.projectId, req.commandId, receipt)

proc parseStudioCommand*(body: JsonNode; base: ProjectRequest): ProjectRequest =
  result = base
  result.commandId = body{"command_id"}.getStr
  if body{"refinement"}.getStr.len > 0:
    result.refinement = body{"refinement"}.getStr
  if body.hasKey("expected_plan_version"):
    result.expectedPlanVersion = body{"expected_plan_version"}.getInt
    result.expectPlanVersion = true
  if body{"project_id"}.getStr.len > 0:
    result.projectId = body{"project_id"}.getStr
