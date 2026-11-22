## Read model for project observation. The CLI and Studio use the same transaction.
import std/[json, os, strutils, tables]
import nimfactory/project/types
import nimfactory/runtime/journal/sqlite_ffi

const RecentEventLimit* = 100
type ProjectMissing* = object of CatchableError

proc allowedFields(node: JsonNode; keys: openArray[string]): JsonNode =
  result = newJObject()
  for key in keys:
    let value = node{key}
    if value != nil:
      result[key] = value

proc usageTableView(node: JsonNode): JsonNode =
  result = newJObject()
  if node.isNil or node.kind != JObject: return
  var totalUsd = 0.0
  var totalCalls = 0
  for role, roll in node.pairs:
    let item = allowedFields(roll, ["prompt_tokens", "completion_tokens",
      "calls", "estimated_usd", "model"])
    result[role] = item
    totalUsd += roll{"estimated_usd"}.getFloat
    totalCalls += roll{"calls"}.getInt
  result["_total"] = %*{
    "estimated_usd": totalUsd,
    "calls": totalCalls
  }

proc projectStepView(step: JsonNode): JsonNode =
  result = allowedFields(step, ["id", "title", "status", "depends_on",
    "mandate_key", "criteria"])
  let detail = step{"result"}
  result["provider"] = allowedFields(detail{"provider_attempt"},
    ["status", "route", "model", "message"])
  result["change"] = allowedFields(detail{"apply"},
    ["target_file", "after_hash", "ok", "message"])
  for key in ["accepted_tree_hash", "readable_diff", "refuse_code",
              "decision", "recovery_reason", "via_recovery"]:
    if detail{key} != nil:
      result[key] = detail[key]
  if detail{"verify"} != nil:
    result["verify"] = allowedFields(detail["verify"],
      ["ok", "kind", "message", "compile_exit", "list_out", "csv_out",
       "list_ok", "csv_ok", "quote_ok", "criteria", "controls", "details"])
  ## Controls actually executed (for blocked / verified steps).
  var controls = newJArray()
  var outputIncorrect = false
  if detail{"verify"} != nil:
    let v = detail["verify"]
    if v{"compile_exit"} != nil:
      controls.add(%*{"name": "compile", "exit": v{"compile_exit"}.getInt,
                      "ok": v{"compile_exit"}.getInt == 0})
    if v{"list_out"}.getStr.len > 0:
      let listOk = v{"list_ok"}.getBool(v{"ok"}.getBool)
      controls.add(%*{
        "name": "list",
        "ok": listOk,
        "message": if listOk: "" else: "sortie non vide mais incorrecte"
      })
      if not listOk: outputIncorrect = true
    if v{"csv_out"}.getStr.len > 0:
      let csvOk = v{"csv_ok"}.getBool(false)
      let quoteOk = v{"quote_ok"}.getBool(true)
      let csvPass = csvOk and quoteOk
      controls.add(%*{
        "name": "export-csv",
        "ok": csvPass,
        "message":
          if csvPass: ""
          elif v{"csv_out"}.getStr.len > 0: "sortie non vide mais incorrecte"
          else: "sortie vide"
      })
      if not csvPass: outputIncorrect = true
    if v{"criteria"} != nil:
      for c in v{"criteria"}:
        controls.add(c)
  if detail{"apply","ok"} != nil:
    controls.add(%*{"name": "apply", "ok": detail{"apply","ok"}.getBool,
                    "message": detail{"apply","message"}.getStr})
  if controls.len > 0:
    result["controls_executed"] = controls
  if outputIncorrect:
    result["output_incorrect"] = %true
  let proof = detail{"accepted_tree_hash"}.getStr.len > 0 and
              step{"status"}.getStr == "done"
  result["has_proof"] = %proof

proc projectCapabilities(doc: JsonNode): JsonNode =
  var commands = newJArray()
  let next = doc{"next_action"}.getStr
  let version = doc{"current_plan_version"}.getInt
  let pendingRevise = doc{"revise_plan_pending"}.getBool
  let exhausted = doc{"recovery_exhausted"}.getBool
  var running = false
  for step in doc{"steps"}.getElems:
    if step{"status"}.getStr in ["running", "interrupted"]:
      running = true
      break
  if version == 0:
    commands.add(%"ask_plan")
  if version >= 1 or doc{"objective"}.getStr.len > 0:
    commands.add(%"run")
  if version >= 1 and not pendingRevise and not exhausted:
    commands.add(%"pause_after_step")
  if version >= 1:
    commands.add(%"revise_plan")
  if next in ["resume", "retry_step"] or running or
     doc{"last_verdict"}.getStr in ["interrupted", "provider_unknown"]:
    commands.add(%"resume")
  elif next in ["step", "revise_or_step", "done"] and version >= 1:
    ## Resume remains available after a pause to continue the walk.
    if next != "done":
      commands.add(%"resume")
  result = %*{
    "commands": commands,
    "revise_plan_pending": pendingRevise,
    "revise_plan_reason": doc{"revise_plan_reason"}.getStr,
    "revise_plan_step_id": doc{"revise_plan_step_id"}.getStr,
    "revise_plan_at_version": doc{"revise_plan_at_version"}.getInt,
    "recovery_exhausted": exhausted,
    "recovery_exhausted_reason": doc{"recovery_exhausted_reason"}.getStr,
    "recovery_exhausted_step_id": doc{"recovery_exhausted_step_id"}.getStr,
    "worker_active": running
  }

proc workflowStatus(doc: JsonNode; steps: JsonNode): JsonNode =
  var active = newJNull()
  var awaiting = newJArray()
  var obtained = newJArray()
  for step in steps:
    let st = step{"status"}.getStr
    if st in ["running", "interrupted", "blocked"]:
      if active.kind == JNull: active = step
    if st == "pending":
      awaiting.add(%*{
        "id": step{"id"}.getStr,
        "title": step{"title"}.getStr
      })
    if step{"has_proof"}.getBool:
      obtained.add(%*{
        "id": step{"id"}.getStr,
        "title": step{"title"}.getStr,
        "file": step{"change","target_file"}.getStr,
        "tree": step{"accepted_tree_hash"}.getStr,
        "verify": step{"verify","message"}.getStr
      })
  if active.kind == JNull:
    ## After verify_failed the step returns to pending but remains the focus.
    let last = doc{"last_verdict"}.getStr
    if last in ["verify_failed", "blocked", "recovery_exhausted", "revise_plan_needed"]:
      for step in steps:
        if step{"status"}.getStr == "pending" and
           (step{"verify"} != nil or step{"refuse_code"}.getStr.len > 0 or
            step{"controls_executed"} != nil):
          active = step
          break
    if active.kind == JNull:
      for step in steps:
        if step{"status"}.getStr == "pending":
          active = step
          break
  let next = doc{"next_action"}.getStr
  var decision = next
  if doc{"revise_plan_pending"}.getBool:
    decision = "revise"
  elif doc{"recovery_exhausted"}.getBool:
    decision = "revise"
  elif doc{"last_verdict"}.getStr == "verify_failed":
    decision = "blocked"
  var outputIncorrect = false
  var incorrectDetail = ""
  if active.kind != JNull and active{"output_incorrect"}.getBool:
    outputIncorrect = true
    incorrectDetail = active{"verify","message"}.getStr
  elif active.kind != JNull:
    for c in active{"controls_executed"}.getElems:
      if c{"message"}.getStr.contains("non vide"):
        outputIncorrect = true
        incorrectDetail = c{"message"}.getStr & " · " & active{"verify","message"}.getStr
        break
  let proposal =
    if doc{"revise_plan_pending"}.getBool: doc{"revise_plan_reason"}.getStr
    elif doc{"recovery_exhausted"}.getBool: doc{"recovery_exhausted_reason"}.getStr
    elif doc{"blocked_reason"}.getStr.len > 0: doc{"blocked_reason"}.getStr
    else: doc{"last_verdict"}.getStr
  result = %*{
    "objective": doc{"objective"}.getStr,
    "active_step": if active.kind == JNull: newJNull() else: %*{
      "id": active{"id"}.getStr,
      "title": active{"title"}.getStr,
      "status":
        if doc{"last_verdict"}.getStr == "verify_failed" and
           active{"status"}.getStr == "pending": "blocked"
        else: active{"status"}.getStr
    },
    "obtained_proofs": obtained,
    "awaiting_verification": awaiting,
    "next_decision": decision,
    "blocked_reason": doc{"blocked_reason"}.getStr,
    "engine_proposal": proposal,
    "engine_verdict": %*{
      "last_verdict": doc{"last_verdict"}.getStr,
      "next_action": next,
      "proposal": proposal,
      "output_incorrect": outputIncorrect,
      "incorrect_detail": incorrectDetail
    }
  }

proc projectView(doc: JsonNode): JsonNode =
  result = allowedFields(doc, ["project_id", "objective", "refinements",
    "current_plan_version", "last_verdict", "next_action", "blocked_reason",
    "accepted_step_id", "accepted_tree_hash"])
  result["schema"] = %"nimfactory.studio/v1"
  result["capabilities"] = projectCapabilities(doc)
  result["usage_by_role"] = usageTableView(doc{"usage_by_role"})
  result["cost"] = result["usage_by_role"]{"_total"}
  if result["cost"] == nil:
    result["cost"] = %*{"estimated_usd": 0.0, "calls": 0}
  result["steps"] = newJArray()
  for step in doc{"steps"}.getElems:
    result["steps"].add(projectStepView(step))
  result["workflow"] = workflowStatus(doc, result["steps"])
  result["plan_versions"] = newJArray()
  for plan in doc{"plan_versions"}.getElems:
    var item = allowedFields(plan, ["version", "summary", "hypothesis"])
    item["steps"] = newJArray()
    for step in plan{"steps"}.getElems:
      item["steps"].add(allowedFields(step, ["id", "title", "depends_on", "criteria"]))
    result["plan_versions"].add(item)

proc bootstrapProjectView*(projectId: string; objective = ""): JsonNode =
  ## Empty project shell for « Nouveau projet → demande → aperçu local ».
  result = %*{
    "schema": "nimfactory.studio/v1",
    "project_id": projectId,
    "objective": objective,
    "refinements": newJArray(),
    "current_plan_version": 0,
    "last_verdict": "",
    "next_action": "ask",
    "blocked_reason": "",
    "accepted_step_id": "",
    "accepted_tree_hash": "",
    "bootstrap": true,
    "steps": newJArray(),
    "plan_versions": newJArray(),
    "events": newJArray(),
    "cursor": 0,
    "cost": {"estimated_usd": 0.0, "calls": 0},
    "usage_by_role": {"_total": {"estimated_usd": 0.0, "calls": 0}},
    "capabilities": {
      "commands": ["ask_plan"],
      "revise_plan_pending": false,
      "recovery_exhausted": false,
      "worker_active": false
    },
    "workflow": {
      "objective": objective,
      "active_step": newJNull(),
      "obtained_proofs": newJArray(),
      "awaiting_verification": newJArray(),
      "next_decision": "ask",
      "blocked_reason": "",
      "engine_proposal": "Saisir une demande pour obtenir un aperçu local du plan.",
      "engine_verdict": {
        "last_verdict": "",
        "next_action": "ask",
        "proposal": "Saisir une demande pour obtenir un aperçu local du plan.",
        "output_incorrect": false,
        "incorrect_detail": ""
      }
    }
  }

proc readProjectView*(path, projectId: string; allowBootstrap = false;
                      objective = ""): JsonNode =
  ## One SQLite read snapshot, even while a worker commits. Never opens a writer,
  ## runs a schema migration, claims a lease or calls projectResume.
  if path.len == 0 or projectId.len == 0:
    if allowBootstrap: return bootstrapProjectView(projectId, objective)
    raise newException(ProjectMissing, "Existing store and project ID required")
  if not fileExists(path):
    if allowBootstrap: return bootstrapProjectView(projectId, objective)
    raise newException(ProjectMissing, "Existing store and project ID required")
  var db: SqliteDb
  const openReadonly = 1'i32
  let rc = sqlite3_open_v2(path.cstring, addr db, openReadonly, nil)
  defer:
    if db != nil: discard sqlite3_close(db)
  if rc != SQLITE_OK:
    raise newException(JournalStorageError, sqliteErr(db, "Cannot open project store"))
  db.execSql("PRAGMA busy_timeout=1000")
  db.execSql("BEGIN")
  let id = projectRunId(projectId)
  let row = db.queryAll("SELECT state_json FROM nf_runs WHERE run_id=?", [id])
  if row.len == 0:
    db.execSql("COMMIT")
    if allowBootstrap: return bootstrapProjectView(projectId, objective)
    raise newException(ProjectMissing, "Unknown project")
  let doc = parseJson(row[0])
  if doc{"kind"}.getStr != "project_mission" or doc{"project_id"}.getStr != projectId:
    raise newException(ValueError, "Invalid project document")
  result = projectView(doc)
  let cursor = db.queryAll("SELECT event_seq FROM nf_runs WHERE run_id=?", [id])
  result["cursor"] = %parseBiggestInt(cursor[0])
  ## Surface an active run lease without taking it.
  let leaseRows = db.queryAll(
    "SELECT transition_json FROM nf_transitions WHERE run_id=? AND transition_id=?",
    [id, "project.run_lease:" & projectId])
  if leaseRows.len > 0:
    let lease = parseJson(leaseRows[0])
    result["run_lease"] = %*{
      "status": lease{"status"}.getStr,
      "holder_pid": lease{"holder_pid"}.getInt
    }
    if lease{"status"}.getStr == "active":
      result["capabilities"]["worker_active"] = %true
  let rows = db.queryAll("""SELECT seq || ':' || event_json FROM nf_events
    WHERE run_id=? ORDER BY seq DESC LIMIT ?""", [id, $RecentEventLimit])
  result["events"] = newJArray()
  for i in countdown(rows.high, 0):
    let sep = rows[i].find(':')
    let payload = parseJson(rows[i][sep+1 .. ^1])
    var item = allowedFields(payload, ["kind", "ts", "step_id", "plan_version",
      "verdict", "action", "message", "refuse_code"])
    item["seq"] = %parseBiggestInt(rows[i][0..<sep])
    result["events"].add(item)
  db.execSql("COMMIT")
