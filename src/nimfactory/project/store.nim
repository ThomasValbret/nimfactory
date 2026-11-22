## Project mission persistence via SqliteRunStore (nf_runs.state_json + events).

import std/[json, times, tables]
import nimfactory/runtime/journal/run_store
import nimfactory/application/compose
import ./types

proc projectRunId*(projectId: string): string =
  "project:" & projectId

proc openProjectStore*(storePath: string): SqliteRunStore =
  openAppStore(storePath)

proc closeProjectStore*(store: SqliteRunStore) =
  store.close()

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
