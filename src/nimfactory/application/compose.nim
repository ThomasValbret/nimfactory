## Local application composition for M1 (F16): real journal + validator, demo handlers.

import std/[json, os]
import nimfactory/contracts/[errors, result]
import nimfactory/graph/[types, codec, registry, validator]
import nimfactory/runtime/journal/run_store
import nimfactory/runtime/executor

type
  AppContext* = object
    registry*: ExecutableRegistry
    graph*: GraphSpec
    store*: SqliteRunStore

proc newDemoRegistry*(): ExecutableRegistry =
  result = newExecutableRegistry()
  registerDemoHandlers(result)

proc loadGraphFile*(path: string): GraphSpec =
  if not fileExists(path):
    raise newFactoryError(fecMissingRequiredInput, "graph not found: " & path,
      phase = "cli")
  graphFromJson(parseJson(readFile(path)))

proc validateGraphFile*(path: string): CommonResult =
  let reg = newDemoRegistry()
  let g = loadGraphFile(path)
  validateGraphSpec(reg.descriptors, g)

proc openAppStore*(storePath: string): SqliteRunStore =
  let parent = splitPath(storePath).head
  if parent.len > 0:
    createDir(parent)
  newSqliteRunStore(storePath)

proc runDemoGraph*(storePath, graphPath, runId: string; inputs: JsonNode;
                   config: ExecConfig): ExecReport =
  let reg = newDemoRegistry()
  let g = loadGraphFile(graphPath)
  let store = openAppStore(storePath)
  defer: store.close()
  runGraph(store, reg, g, runId, inputs, config)

proc resumeDemoGraph*(storePath, graphPath, runId: string;
                      config: ExecConfig): ExecReport =
  let reg = newDemoRegistry()
  let g = loadGraphFile(graphPath)
  let store = openAppStore(storePath)
  defer: store.close()
  resumeGraph(store, reg, g, runId, config)

proc inspectRun*(storePath, runId: string): JsonNode =
  let store = openAppStore(storePath)
  defer: store.close()
  store.recover(runId)

proc listEvents*(storePath, runId: string): JsonNode =
  let rec = inspectRun(storePath, runId)
  if rec.hasKey("events"): rec["events"] else: newJArray()
