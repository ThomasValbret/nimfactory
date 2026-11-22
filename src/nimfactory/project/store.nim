## Project mission persistence via SqliteRunStore (nf_runs.state_json + events).

import std/[json, times, tables, os, posix]
import nimfactory/runtime/journal/run_store
import nimfactory/runtime/journal/sqlite_ffi
import nimfactory/application/compose
import ./types

export types.projectRunId

const
  RunLeaseSchema* = "nimfactory.project_run_lease/v1"

proc openProjectStore*(storePath: string): SqliteRunStore =
  openAppStore(storePath)

proc closeProjectStore*(store: SqliteRunStore) =
  store.close()

proc runLeaseTransitionId*(projectId: string): string =
  "project.run_lease:" & projectId

proc claimProjectRunLease*(
    store: SqliteRunStore; projectId: string): tuple[
    ok: bool; alreadyHeld: bool; holderPid: int; message: string] =
  ## Two simultaneous `project run` starts: only the first holds the lease.
  result.ok = false
  result.alreadyHeld = false
  result.holderPid = 0
  let rid = projectRunId(projectId)
  let tid = runLeaseTransitionId(projectId)
  store.ensureRunId(rid)
  store.db.execSql("BEGIN IMMEDIATE")
  try:
    let rows = store.db.queryAll(
      "SELECT transition_json FROM nf_transitions WHERE run_id = ? AND transition_id = ?",
      [rid, tid])
    if rows.len > 0:
      let body = parseJson(rows[0])
      let status = body{"status"}.getStr
      let pid = body{"holder_pid"}.getInt
      if status == "active":
        # Alive holder → refuse; dead holder → steal.
        if pid > 0:
          let alive = (kill(Pid(pid), 0.cint) == 0.cint)
          if alive:
            store.db.execSql("COMMIT")
            return (false, true, pid, "project run already active holder_pid=" & $pid)
      # Stale or done → reclaim below.
      store.db.runPrepared(
        "DELETE FROM nf_transitions WHERE run_id = ? AND transition_id = ?",
        [rid, tid])
    let body = %*{
      "schema": RunLeaseSchema,
      "status": "active",
      "project_id": projectId,
      "holder_pid": getCurrentProcessId(),
      "started_ts": $epochTime()
    }
    store.db.runPrepared(
      "INSERT INTO nf_transitions(run_id, transition_id, transition_json) VALUES(?, ?, ?)",
      [rid, tid, $body])
    store.db.execSql("COMMIT")
    result.ok = true
    result.holderPid = getCurrentProcessId()
    result.message = "lease acquired"
  except CatchableError as e:
    store.db.execSql("ROLLBACK")
    result.message = e.msg

proc releaseProjectRunLease*(store: SqliteRunStore; projectId: string) =
  let rid = projectRunId(projectId)
  let tid = runLeaseTransitionId(projectId)
  store.db.execSql("BEGIN IMMEDIATE")
  try:
    let body = %*{
      "schema": RunLeaseSchema,
      "status": "done",
      "project_id": projectId,
      "holder_pid": getCurrentProcessId(),
      "finished_ts": $epochTime()
    }
    let existing = store.db.queryAll(
      "SELECT 1 FROM nf_transitions WHERE run_id = ? AND transition_id = ?",
      [rid, tid])
    if existing.len == 0:
      store.db.runPrepared(
        "INSERT INTO nf_transitions(run_id, transition_id, transition_json) VALUES(?, ?, ?)",
        [rid, tid, $body])
    else:
      store.db.runPrepared(
        "UPDATE nf_transitions SET transition_json = ? WHERE run_id = ? AND transition_id = ?",
        [$body, rid, tid])
    store.db.execSql("COMMIT")
  except CatchableError:
    store.db.execSql("ROLLBACK")

proc loadProject*(store: SqliteRunStore; projectId: string): tuple[ok: bool; doc: ProjectDoc; err: string] =
  let rid = projectRunId(projectId)
  if not store.hasRun(rid):
    return (false, ProjectDoc(), "unknown project_id: " & projectId)
  let state = store.getRunState(rid)
  if state{"kind"}.getStr != "project_mission":
    return (false, ProjectDoc(), "run is not a project_mission: " & projectId)
  (true, docFromJson(state), "")

proc saveProject*(store: SqliteRunStore; doc: ProjectDoc) =
  let rid = projectRunId(doc.projectId)
  store.ensureRunId(rid)
  store.putRunState(rid, docToJson(doc))

proc emitProjectEvent*(store: SqliteRunStore; projectId, kind: string; body: JsonNode) =
  ## Copy body so callers can keep an unmutated report node.
  var ev = if body.isNil: newJObject() else: body.copy()
  ev["kind"] = %kind
  ev["project_id"] = %projectId
  ev["ts"] = %($epochTime())
  store.appendEvent(projectRunId(projectId), ev)

proc newProjectDoc*(projectId, cwd, objective: string): ProjectDoc =
  result.kind = "project_mission"
  result.projectId = projectId
  result.cwd = cwd
  result.objective = objective
  result.refinements = @[]
  result.planVersions = @[]
  result.currentPlanVersion = 0
  result.steps = @[]
  result.mandates = newJObject()
  result.usageByRole = initTable[string, UsageRollup]()
  result.worktree = ""
  result.nextAction = "ask"
