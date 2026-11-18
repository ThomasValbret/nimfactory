## Independent A.1 probes (no façade). Exit 1 if any invariant fails.
## Expectations = corrected behavior from WAVE_A_1_INDEPENDENT_REVIEW.md.
import std/[os, json, strutils, times, tables]
import nimfactory/contracts/[ids, validate, result, errors]
import nimfactory/artifacts/[store, snapshot, types]
import nimfactory/budget/file_ledger
import nimfactory/runtime/journal/run_store
import nimfactory/graph/[types, codec, registry, validator]

var failed = 0
var total = 0

proc note(caseId: string; pass: bool; observed: JsonNode) =
  inc total
  if not pass: inc failed
  echo $(%*{"case": caseId, "pass": pass, "observed": observed})

proc tmpRoot(): string =
  let p = getTempDir() / ("nf-a1-probe-" & $epochTime().int & "-" & $getCurrentProcessId())
  createDir(p)
  p

block F0_exact_duplicate:
  var rejected = false
  try: discard parseJsonStrict("""{"epoch":1,"epoch":2}""")
  except FactoryError: rejected = true
  note("F0_exact_duplicate", rejected, %*{"rejected": rejected})

block F0_unicode_duplicate:
  var rejected = false
  var parsed = newJNull()
  try: parsed = parseJsonStrict("""{"epoch":1,"\u0065poch":2}""")
  except FactoryError: rejected = true
  note("F0_unicode_duplicate", rejected, %*{"rejected": rejected, "parsed": parsed})

block F0_distinct_unicode_keys:
  var accepted = false
  var reason = ""
  try:
    let n = parseJsonStrict("""{"\u0065":1,"0065":2}""")
    accepted = n.len == 2
  except FactoryError as e:
    reason = e.msg
  note("F0_distinct_unicode_keys", accepted, %*{"accepted": accepted, "reason": reason})

block F0_need_wrong_boolean:
  var rejected = false
  var decodedRequired = false
  try:
    let r = resultFromJson(%*{
      "schema": ResultSchema, "status": "blocked", "outputs": {},
      "needs": [{"id": "n1", "target": "c", "selector": "s",
                 "required": "true", "reason": "x"}],
      "diagnostics": []
    })
    decodedRequired = r.needs[0].required
  except FactoryError:
    rejected = true
  note("F0_need_wrong_boolean", rejected,
       %*{"rejected": rejected, "decoded_required": decodedRequired})

block F1_recapture_readset_immutability:
  let root = tmpRoot()
  let store = newDirectoryArtifactStore(root / "art")
  var src = newLocalSnapshotSource(store)
  let path = root / "src.txt"
  writeFile(path, "stable")
  let req = SourceCaptureRequest(
    sources: @[SourceSpec(sourceId: "source", path: path, revisionLabel: "r1")])
  let (snap1, _) = src.capture(req)
  let rsA = src.appendRead(snap1, ReadSetEntry(
    kind: "query", sourceId: "source", artifactRef: artifactRef("art-qA"),
    revision: "A", selector: "query-A", emptySearch: false))
  let oldId = rsA.readSetId
  let (snap2, _) = src.capture(req)
  let sameSnap = snap2.snapshotId == snap1.snapshotId
  var oldLost = false
  var src2 = newLocalSnapshotSource(store)
  try:
    let old = src2.reloadReadSet(oldId)
    oldLost = not (old.version == 2 and old.entries.len >= 2 and
                   old.entries[^1].selector == "query-A")
  except CatchableError:
    oldLost = true
  let rsB = src.appendRead(snap1, ReadSetEntry(
    kind: "query", sourceId: "source", artifactRef: artifactRef("art-qB"),
    revision: "B", selector: "query-B", emptySearch: false))
  let idReuse = rsB.readSetId == oldId
  var resolved: seq[string] = @[]
  var src3 = newLocalSnapshotSource(store)
  try:
    let again = src3.reloadReadSet(oldId)
    for e in again.entries:
      if e.selector.len > 0: resolved.add(e.selector)
      else: resolved.add(e.sourceId)
  except CatchableError:
    resolved = @["missing"]
  let oldOk = ("query-A" in resolved) and ("query-B" notin resolved)
  note("F1_recapture_readset_immutability",
       sameSnap and oldOk and (not idReuse),
       %*{
         "same_snapshot": sameSnap,
         "old_version_lost_after_recapture": oldLost or not oldOk,
         "id_reused_for_different_entries": idReuse,
         "old_id_now_resolves_to_sources": resolved
       })

block F14_same_path_handles:
  let root = tmpRoot() / "same-budget"
  var l1 = openFileBudgetLedger(root)
  l1.defineScope("run", "100", 10)
  discard l1.reserve("run", "a1", 1, "70")
  var l2 = openFileBudgetLedger(root)
  var rejected = false
  try: discard l2.reserve("run", "a2", 1, "70")
  except FactoryError: rejected = true
  closeFileBudgetLedger(l1); closeFileBudgetLedger(l2)
  note("F14_same_path_handles", rejected, %*{"second_reservation_rejected": rejected})

block F14_equivalent_path_handles:
  ## Discriminating shape (review): open both handles before first reservation.
  let base = tmpRoot()
  let p1 = base / "alias-budget"
  ## Literal `./` segment (do not use Path `/` which may collapse `.`).
  let p2 = base & "/./alias-budget"
  var l1 = openFileBudgetLedger(p1)
  var l2 = openFileBudgetLedger(p2)
  l1.defineScope("run", "100", 10)
  var rejected = false
  discard l1.reserve("run", "b1", 1, "70")
  try: discard l2.reserve("run", "b2", 1, "70")
  except FactoryError: rejected = true
  closeFileBudgetLedger(l1); closeFileBudgetLedger(l2)
  note("F14_equivalent_path_handles", rejected,
       %*{"second_reservation_rejected": rejected, "ceiling": 100})

block F3_explicit_stale_epoch:
  let db = tmpRoot() / "j1.sqlite"
  var s = newSqliteRunStore(db)
  discard s.commitTransition("run1", %*{
    "transition_id": "t0", "epoch": 1, "state": {"owner": "init"},
    "activation_id": "act", "attempt_id": "att",
    "activation_state": {"s": 1}, "attempt_state": {"s": 1}
  })
  discard s.claimLease("run1", "owner")
  var rejected = false
  try:
    discard s.commitTransition("run1", %*{
      "transition_id": "t-stale", "epoch": 1, "state": {"owner": "stale"},
      "activation_id": "act2", "attempt_id": "att2",
      "activation_state": {"s": 2}, "attempt_state": {"s": 2},
      "outbox": [{"message_id": "m1", "body": {"x": 1}}]
    })
  except FactoryError: rejected = true
  s.close()
  note("F3_explicit_stale_epoch", rejected, %*{"rejected": rejected})

block F3_missing_epoch_mutation:
  let db = tmpRoot() / "j2.sqlite"
  var s = newSqliteRunStore(db)
  discard s.commitTransition("run2", %*{
    "transition_id": "t0", "epoch": 1, "state": {"owner": "init"},
    "activation_id": "act", "attempt_id": "att",
    "activation_state": {"s": 1}, "attempt_state": {"s": 1}
  })
  let ep = s.claimLease("run2", "owner")
  var rejected = false
  var state = newJNull()
  var outboxCount = 0
  try:
    discard s.commitTransition("run2", %*{
      "transition_id": "t-missing-epoch", "state": {"owner": "unfenced"},
      "activation_id": "actX", "attempt_id": "attX",
      "activation_state": {"s": 9}, "attempt_state": {"s": 9},
      "outbox": [{"message_id": "m-miss", "body": {"x": 1}}]
    })
    let rec = s.recover("run2")
    state = rec{"state"}
    if rec.hasKey("outbox_pending") and rec["outbox_pending"].kind == JArray:
      outboxCount = rec["outbox_pending"].len
  except FactoryError:
    rejected = true
  s.close()
  note("F3_missing_epoch_mutation", rejected, %*{
    "rejected": rejected, "current_epoch": ep, "state": state,
    "outbox_count": outboxCount
  })

block F4_cycle_bypasses_loop_limit:
  let reg = newSimulatedHandlerRegistry()
  registerSeedBasicHandlers(reg)
  let g = graphFromJson(%*{
    "schema": GraphSchema,
    "graph_id": "bypass-loop",
    "version": 1,
    "nodes": [
      {"id": "loop", "kind": "loop"},
      {"id": "a", "kind": "sequence"},
      {"id": "b", "handler": "noop.passthrough@0.1"}
    ],
    "entrypoints": [{"input": "start", "to": "loop.in"}],
    "edges": [
      {"from": "loop.body", "to": "a.in"},
      {"from": "a.out", "to": "b.in"},
      {"from": "b.out", "to": "a.next"},
      {"from": "b.out", "to": "loop.in"}
    ],
    "outputs": {"done": "loop.done"},
    "loop_specs": [{
      "loop_node_id": "loop",
      "exit": {"max_iterations": 3, "on_limit": "limit_reached"}
    }]
  })
  let r = validateGraphSpec(reg, g)
  ## Require residual-cycle signal, not any other invalidity.
  var hasResidual = false
  for d in r.diagnostics:
    let blob = (d.code & " " & d.message).toLowerAscii()
    if "cycle" in blob or "residual" in blob or "uncontrolled" in blob:
      hasResidual = true
  let pass = r.status != rsOk and hasResidual
  note("F4_cycle_bypasses_loop_limit", pass, %*{
    "validation": $r.status,
    "diagnostics_count": r.diagnostics.len,
    "residual_cycle_diagnostic": hasResidual,
    "uncontrolled_cycle": ["a", "b", "a"]
  })

echo $(%*{"summary": "independent_a1_probes", "failed": failed, "total": total})
quit(if failed > 0: 1 else: 0)
