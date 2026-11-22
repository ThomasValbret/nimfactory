## Read model for project observation. The CLI and Studio use the same transaction.
import std/[json, os, strutils]
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

proc projectStepView(step: JsonNode): JsonNode =
  result = allowedFields(step, ["id", "title", "status", "depends_on", "mandate_key"])
  let detail = step{"result"}
  result["provider"] = allowedFields(detail{"provider_attempt"}, ["status", "route"])
  result["change"] = allowedFields(detail{"apply"}, ["target_file", "after_hash"])
  for key in ["accepted_tree_hash", "readable_diff"]:
    if detail{key} != nil:
      result[key] = detail[key]
  if detail{"verify"} != nil:
    result["verify"] = allowedFields(detail["verify"],
      ["ok", "kind", "message", "compile_exit", "list_out", "csv_out"])

proc projectCapabilities(doc: JsonNode): JsonNode =
  var commands = newJArray()
  if doc{"current_plan_version"}.getInt >= 1:
    commands.add(%"revise_plan")
  result = %*{
    "commands": commands,
    "revise_plan_pending": doc{"revise_plan_pending"}.getBool,
    "revise_plan_reason": doc{"revise_plan_reason"}.getStr,
    "revise_plan_step_id": doc{"revise_plan_step_id"}.getStr,
    "revise_plan_at_version": doc{"revise_plan_at_version"}.getInt
  }

proc projectView(doc: JsonNode): JsonNode =
  result = allowedFields(doc, ["project_id", "objective", "refinements",
    "current_plan_version", "last_verdict", "next_action", "blocked_reason"])
  result["schema"] = %"nimfactory.studio/v1"
  result["capabilities"] = projectCapabilities(doc)
  result["steps"] = newJArray()
  for step in doc{"steps"}.getElems:
    result["steps"].add(projectStepView(step))
  result["plan_versions"] = newJArray()
  for plan in doc{"plan_versions"}.getElems:
    var item = allowedFields(plan, ["version", "summary", "hypothesis"])
    item["steps"] = newJArray()
    for step in plan{"steps"}.getElems:
      item["steps"].add(allowedFields(step, ["id", "title", "depends_on"]))
    result["plan_versions"].add(item)

proc readProjectView*(path, projectId: string): JsonNode =
  ## One SQLite read snapshot, even while a worker commits. Never opens a writer,
  ## runs a schema migration, claims a lease or calls projectResume.
  if path.len == 0 or projectId.len == 0 or not fileExists(path):
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
    raise newException(ProjectMissing, "Unknown project")
  let doc = parseJson(row[0])
  if doc{"kind"}.getStr != "project_mission" or doc{"project_id"}.getStr != projectId:
    raise newException(ValueError, "Invalid project document")
  result = projectView(doc)
  let cursor = db.queryAll("SELECT event_seq FROM nf_runs WHERE run_id=?", [id])
  result["cursor"] = %parseBiggestInt(cursor[0])
  let rows = db.queryAll("""SELECT seq || ':' || event_json FROM nf_events
    WHERE run_id=? ORDER BY seq DESC LIMIT ?""", [id, $RecentEventLimit])
  result["events"] = newJArray()
  for i in countdown(rows.high, 0):
    let sep = rows[i].find(':')
    let payload = parseJson(rows[i][sep+1 .. ^1])
    var item = allowedFields(payload, ["kind", "ts", "step_id", "plan_version", "verdict", "action"])
    item["seq"] = %parseBiggestInt(rows[i][0..<sep])
    result["events"].add(item)
  db.execSql("COMMIT")
