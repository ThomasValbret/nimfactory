## F17 A.1 component probes (mode=component_probe) — expectations from WAVE_A_REVIEW R1–R5.
## Independent of qualification fixtures; error codes are hardcoded from the review text.

import std/[json, os, times, strutils]
import nimfactory
import nimfactory/contracts/[errors, ids, result, validate]
import nimfactory/graph/[registry, validator, codec]
import nimfactory/budget/file_ledger
import nimfactory/runtime/journal/run_store

proc expectFactoryCode(body: proc (); code: FactoryErrorCode) =
  var raised = false
  try:
    body()
  except FactoryError as e:
    raised = true
    doAssert e.code == code, $e.code & " vs " & $code & ": " & e.msg
  doAssert raised, "expected FactoryError " & $code

proc tempDir(tag: string): string =
  let p = getTempDir() / ("nf-a1-" & tag & "-" & $getTime().toUnix())
  createDir(p)
  p

proc reg(): SimulatedHandlerRegistry =
  let r = newSimulatedHandlerRegistry()
  registerSeedBasicHandlers(r)
  r

proc graphFixture(name: string): JsonNode =
  let path = "tests/fixtures/qualification/a1" / name
  parseFile(path)

proc expectGraphFail(j: JsonNode; code: string) =
  let r = validateGraphSpec(reg(), graphFromJson(j))
  doAssert r.status == rsFailed, "expected validation failure"
  var found = false
  for d in r.diagnostics:
    if d.code == code:
      found = true
      break
  doAssert found, "expected diagnostic code " & code

echo "F17 A.1 component probes (mode=component_probe, no LLM)"

block f0ReviewR5:
  expectFactoryCode(proc () = discard metaFromJson(%*{"schema": MetaSchema}),
    fecMissingRequiredInput)
  expectFactoryCode(proc () =
    discard resultFromJson(%*{
      "schema": ResultSchema,
      "outputs": {},
      "needs": [],
      "diagnostics": []
    }), fecMissingRequiredInput)
  expectFactoryCode(proc () =
    discard resultFromJson(%*{
      "schema": ResultSchema,
      "status": "ok",
      "outputs": 17,
      "needs": [],
      "diagnostics": []
    }), fecValidationFailed)
  expectFactoryCode(proc () = discard parseJsonStrict("""{"epoch":1,"epoch":2}"""),
    fecDuplicateKey)

block f1ReviewR4:
  let root = tempDir("f1")
  let store = newDirectoryArtifactStore(root)
  let snapSrc = newLocalSnapshotSource(store)
  let srcPath = root / "doc.txt"
  writeFile(srcPath, "body")
  let (snapshot, rs1) = snapSrc.capture(SourceCaptureRequest(
    sources: @[SourceSpec(sourceId: "doc", path: srcPath, revisionLabel: "r0")]
  ))
  doAssert rs1.version == 1
  let rs2 = snapSrc.appendRead(snapshot, ReadSetEntry(
    kind: "read", sourceId: "extra", artifactRef: artifactRef("art-a1-1"),
    revision: "r1", selector: "q1", emptySearch: false
  ))
  let rs3 = snapSrc.appendRead(snapshot, ReadSetEntry(
    kind: "negative_search", sourceId: "none", artifactRef: artifactRef(""),
    revision: "", selector: "q2", emptySearch: true
  ))
  doAssert rs2.version == 2
  doAssert rs3.version == 3
  doAssert rs2.readSetId != rs3.readSetId
  doAssert rs3.entries.len == 3
  let (snapB, _) = snapSrc.capture(SourceCaptureRequest(
    sources: @[SourceSpec(sourceId: "doc", path: srcPath, revisionLabel: "r0")],
    recipeRefs: @["recipe/v2"]
  ))
  doAssert snapshot.snapshotId != snapB.snapshotId
  let fresh = newLocalSnapshotSource(newDirectoryArtifactStore(root))
  doAssert fresh.reloadSnapshot(snapshot.snapshotId).snapshotId == snapshot.snapshotId

block f3ReviewR2:
  let path = tempDir("f3") / "run.sqlite3"
  let store = newSqliteRunStore(path)
  let tx = %*{
    "transition_id": "tx-a1-good",
    "activation_id": "act-1",
    "attempt_id": "try-1",
    "epoch": 1,
    "invocation_validated": false,
    "state": {"phase": "running"},
    "activation_state": {"status": "running"},
    "attempt_state": {"status": "running"},
    "outbox": []
  }
  discard store.commitTransition("run-a1", tx)
  discard store.claimLease("run-a1", "owner-2")
  var stale = tx
  stale["transition_id"] = % "tx-a1-stale"
  stale["epoch"] = %1
  stale["state"] = %*{"phase": "hijacked"}
  expectFactoryCode(proc () = discard store.commitTransition("run-a1", stale),
    fecStaleSnapshot)
  let rec = store.recover("run-a1")
  doAssert rec["state"]["phase"].getStr == "running"
  doAssert rec["epoch"].getInt == 2
  store.close()
  removeFile(path)

block f4ReviewR3:
  expectGraphFail(graphFixture("f4_isolated_seed_node.json"), $fecMissingRequiredInput)
  expectGraphFail(graphFixture("f4_parasitic_cycle.json"), $fecDependencyCycle)

block f14ReviewR1:
  let db = tempDir("f14")
  let scope = db / "leaf"
  var l = openFileBudgetLedger(scope)
  l.defineScope("run", "100", 2)
  l.defineScope("run/infer", "100", 2)
  expectFactoryCode(proc () = discard l.reserve("run/infer", "neg-amt", 1, "-50"),
    fecValidationFailed)
  expectFactoryCode(proc () = discard l.reserve("run/infer", "neg-send", -3, "10"),
    fecValidationFailed)
  discard l.reserve("run/infer", "first", 1, "70")
  let l2 = openFileBudgetLedger(scope)
  var secondRejected = false
  try:
    discard l2.reserve("run/infer", "second", 1, "70")
  except FactoryError as e:
    secondRejected = true
    doAssert e.code == fecBudgetExhausted
  doAssert secondRejected
  var reservedMicroused = ""
  for s in l2.snapshot()["scopes"]:
    if s["scope"].getStr == "run/infer":
      reservedMicroused = s["reserved_microusd"].getStr
  doAssert reservedMicroused == "70"
  closeFileBudgetLedger(l)
  closeFileBudgetLedger(l2)
  let dbIdem = tempDir("f14-idem")
  var l3 = openFileBudgetLedger(dbIdem / "leaf")
  l3.defineScope("leaf", "500", 10)
  discard l3.reserve("leaf", "idem", 1, "10")
  expectFactoryCode(proc () = discard l3.reserve("leaf", "idem", 1, "90"),
    fecValidationFailed)
  closeFileBudgetLedger(l3)
  let dbPf = tempDir("f14-persist")
  var l4 = openFileBudgetLedger(dbPf / "leaf")
  l4.defineScope("leaf", "1000", 10)
  budgetLedgerTestPersistFail = true
  var persistFailed = false
  try:
    discard l4.reserve("leaf", "ghost", 1, "40")
  except FactoryError as e:
    persistFailed = true
    doAssert e.code == fecEffectOutcomeUnknown
  doAssert persistFailed
  var memReserved = ""
  for s in l4.snapshot()["scopes"]:
    if s["scope"].getStr == "leaf":
      memReserved = s["reserved_microusd"].getStr
  doAssert memReserved == "0"
  closeFileBudgetLedger(l4)
  budgetLedgerTestPersistFail = false
  var l5 = openFileBudgetLedger(dbPf / "leaf")
  let okReserve = l5.reserve("leaf", "ghost", 1, "40")
  doAssert okReserve["state"].getStr == "reserved"
  closeFileBudgetLedger(l5)
  var l6 = openFileBudgetLedger(dbPf / "leaf")
  var diskReserved = ""
  for s in l6.snapshot()["scopes"]:
    if s["scope"].getStr == "leaf":
      diskReserved = s["reserved_microusd"].getStr
  doAssert diskReserved == "40"
  closeFileBudgetLedger(l6)

echo "test_a1_component_probes: ok"