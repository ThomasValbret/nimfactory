import std/[os, json, times]
import nimfactory/contracts/[errors, ids]
import nimfactory/runtime/journal/run_store

proc tempDb(name: string): string =
  result = getTempDir() / ("nf-f3-" & name & "-" & $getTime().toUnix() & ".sqlite3")

proc baseTransition(txId: string): JsonNode =
  %*{
    "transition_id": txId,
    "activation_id": "act-1",
    "attempt_id": "try-1",
    "epoch": 1,
    "invocation_validated": false,
    "state": {"phase": "running"},
    "activation_state": {"status": "running"},
    "attempt_state": {"status": "running"},
    "outbox": [
      {"message_id": "out-msg-1", "payload": {"kind": "result", "ref": "art-result-1"}}
    ]
  }

block crashBeforeCommit:
  let path = tempDb("before-commit")
  var store = newSqliteRunStore(path)
  store.commitCrashPoint = ccBeforeCommit
  var failed = false
  try:
    discard store.commitTransition("run-1", baseTransition("tx-bc"))
  except JournalStorageError:
    failed = true
  doAssert failed
  store.close()
  store = newSqliteRunStore(path)
  let rec = store.recover("run-1")
  doAssert rec["events"].len == 0
  doAssert store.pendingOutbox("run-1").len == 0
  store.close()
  removeFile(path)

block crashAfterCommit:
  let path = tempDb("after-commit")
  var store = newSqliteRunStore(path)
  store.commitCrashPoint = ccAfterCommit
  var failed = false
  try:
    discard store.commitTransition("run-1", baseTransition("tx-ac"))
  except JournalStorageError:
    failed = true
  doAssert failed
  store.close()
  store = newSqliteRunStore(path)
  let rec = store.recover("run-1")
  doAssert rec["events"].len == 1
  doAssert store.pendingOutbox("run-1").len == 1
  store.close()
  removeFile(path)

block outboxPublishAndAck:
  let path = tempDb("outbox-ack")
  let store = newSqliteRunStore(path)
  discard store.commitTransition("run-1", baseTransition("tx-ob"))
  doAssert store.pendingOutbox("run-1").len == 1
  let published = store.publishPending("run-1")
  doAssert published.len == 1
  doAssert store.pendingOutbox("run-1").len == 0
  store.acknowledgeOutbox("run-1", "out-msg-1")
  let rec = store.recover("run-1")
  doAssert rec["outbox_pending"].len == 0
  store.close()
  removeFile(path)

block crashBeforeAck:
  let path = tempDb("before-ack")
  var store = newSqliteRunStore(path)
  discard store.commitTransition("run-1", baseTransition("tx-ba"))
  discard store.publishPending("run-1")
  var crashed = false
  try:
    store.acknowledgeOutbox("run-1", "out-msg-1", crashAfterAck = true)
  except JournalStorageError:
    crashed = true
  doAssert crashed
  store.close()
  store = newSqliteRunStore(path)
  # ack is transactional: after successful ack + simulated crash, message is acked
  # publishing rows may remain if crash happened after commit of ack — should be acked
  let rec = store.recover("run-1")
  doAssert rec["outbox_pending"].len == 0
  store.close()
  removeFile(path)

block inboundDedupAndRetransmit:
  let path = tempDb("dedup")
  let store = newSqliteRunStore(path)
  let ev = %*{"message_id": "in-1", "kind": "handler_result", "epoch": 1,
              "attempt_id": "try-1", "activation_id": "act-1"}
  store.appendEvent("run-1", ev)
  store.appendEvent("run-1", ev)
  let rec = store.recover("run-1")
  doAssert rec["events"].len == 1
  let del = store.acceptHandlerDelivery("run-1", ev)
  doAssert del.duplicate
  store.close()
  removeFile(path)

block newAttemptNotDedup:
  let path = tempDb("new-attempt")
  let store = newSqliteRunStore(path)
  let ev1 = %*{"message_id": "in-a", "attempt_id": "try-1"}
  let ev2 = %*{"message_id": "in-b", "attempt_id": "try-2"}
  store.appendEvent("run-1", ev1)
  store.appendEvent("run-1", ev2)
  let rec = store.recover("run-1")
  doAssert rec["events"].len == 2
  store.close()
  removeFile(path)

block validatedInvocationNotReinvoked:
  let path = tempDb("validated")
  let store = newSqliteRunStore(path)
  var tx = baseTransition("tx-val")
  tx["invocation_validated"] = %true
  tx["attempt_id"] = %"try-done"
  discard store.commitTransition("run-1", tx)
  doAssert not store.invocationMayBeRequested("run-1", "act-1", "try-done")
  let rec = store.recover("run-1")
  doAssert rec["reinvoke_policy"].len == 1
  doAssert rec["reinvoke_policy"][0]{"reinvoke_allowed"}.getBool(true) == false
  store.close()
  removeFile(path)

block staleEpochAfterResume:
  let path = tempDb("stale-epoch")
  let store = newSqliteRunStore(path)
  discard store.commitTransition("run-1", baseTransition("tx-e1"))
  doAssert store.currentEpoch("run-1") == 1
  discard store.claimLease("run-1", "worker-b")
  doAssert store.currentEpoch("run-1") == 2
  let late = %*{"message_id": "late-1", "epoch": 1, "kind": "stale_result",
                 "result_ref": "art-stale"}
  var raised = false
  try:
    store.appendEvent("run-1", late)
  except FactoryError as e:
    raised = true
    doAssert e.code == fecStaleSnapshot
  doAssert raised
  let del = store.acceptHandlerDelivery("run-1", late)
  doAssert del.staleEpoch
  let rec = store.recover("run-1")
  doAssert rec["epoch"].getInt == 2
  store.close()
  removeFile(path)

block staleEpochCommitRejected:
  let path = tempDb("stale-commit")
  let store = newSqliteRunStore(path)
  discard store.commitTransition("run-1", baseTransition("tx-good"))
  discard store.claimLease("run-1", "owner-2")
  var hijack = baseTransition("tx-bad")
  hijack["epoch"] = %1
  hijack["state"] = %*{"phase": "hijacked"}
  var rejected = false
  try:
    discard store.commitTransition("run-1", hijack)
  except FactoryError as e:
    rejected = true
    doAssert e.code == fecStaleSnapshot
  doAssert rejected
  let rec = store.recover("run-1")
  doAssert rec["state"]["phase"].getStr == "running"
  doAssert rec["events"].len == 1
  doAssert store.pendingOutbox("run-1").len == 1
  store.close()
  removeFile(path)

block resumeCommitRaceAcrossHandles:
  let path = tempDb("resume-race")
  var storeA = newSqliteRunStore(path)
  discard storeA.commitTransition("run-1", baseTransition("tx-race"))
  let recBefore = storeA.recover("run-1")
  storeA.close()
  let storeB = newSqliteRunStore(path)
  discard storeB.claimLease("run-1", "resumed-worker")
  storeA = newSqliteRunStore(path)
  var lateTx = baseTransition("tx-late-owner")
  lateTx["epoch"] = %1
  var failed = false
  try:
    discard storeA.commitTransition("run-1", lateTx)
  except FactoryError as e:
    failed = true
    doAssert e.code == fecStaleSnapshot
  doAssert failed
  let rec = storeB.recover("run-1")
  doAssert rec["epoch"].getInt == 2
  doAssert $rec["state"] == $recBefore["state"]
  doAssert rec["events"].len == recBefore["events"].len
  storeA.close()
  storeB.close()
  removeFile(path)

block interruptedPublishRedelivery:
  let path = tempDb("publish-redeliver")
  var store = newSqliteRunStore(path)
  discard store.commitTransition("run-1", baseTransition("tx-pub"))
  discard store.publishPending("run-1")
  store.close()
  store = newSqliteRunStore(path)
  let rec = store.recover("run-1")
  doAssert rec["outbox_pending"].len == 1
  doAssert store.publishPending("run-1").len == 0
  let unacked = store.redistributeUnackedOutbox("run-1")
  doAssert unacked.len == 1
  doAssert unacked[0]{"message_id"}.getStr == "out-msg-1"
  let again = store.publishPending("run-1")
  doAssert again.len == 1
  doAssert again[0]{"message_id"}.getStr == "out-msg-1"
  store.close()
  removeFile(path)

block incompleteTransitionRejected:
  let path = tempDb("incomplete-tx")
  let store = newSqliteRunStore(path)
  var bad = %*{
    "transition_id": "tx-incomplete",
    "activation_id": "act-1",
    "attempt_id": "try-1",
    "epoch": 1,
    "invocation_validated": false,
    "state": {"phase": "running"},
    "outbox": []
  }
  var rejected = false
  try:
    discard store.commitTransition("run-1", bad)
  except FactoryError as e:
    rejected = true
    doAssert e.code == fecMissingRequiredInput
  doAssert rejected
  let rec = store.recover("run-1")
  doAssert rec["events"].len == 0
  store.close()
  removeFile(path)

block idempotentTransitionAfterLeaseBump:
  let path = tempDb("idempotent-after-lease")
  let store = newSqliteRunStore(path)
  let tx = baseTransition("tx-replay")
  discard store.commitTransition("run-1", tx)
  discard store.claimLease("run-1", "new-owner")
  let replayed = store.commitTransition("run-1", tx)
  doAssert replayed["transition_id"].getStr == "tx-replay"
  let rec = store.recover("run-1")
  doAssert rec["events"].len == 1
  doAssert store.pendingOutbox("run-1").len == 1
  store.close()
  removeFile(path)

block unknownExternalEffectPreserved:
  let path = tempDb("unknown-effect")
  let store = newSqliteRunStore(path)
  var tx = baseTransition("tx-unk")
  tx["external_effects"] = %*[
    {"effect_id": "eff-1", "status": "effect_outcome_unknown",
     "receipt_ref": "art-rcpt-1", "activation_id": "act-1", "attempt_id": "try-1"}
  ]
  discard store.commitTransition("run-1", tx)
  doAssert store.effectOutcomeUnknown("run-1", "eff-1")
  let rec = store.recover("run-1")
  doAssert rec["external_effects"].len == 1
  doAssert rec["external_effects"][0]{"status"}.getStr == "effect_outcome_unknown"
  store.close()
  removeFile(path)

block idempotentTransition:
  let path = tempDb("idempotent-tx")
  let store = newSqliteRunStore(path)
  let tx = baseTransition("tx-once")
  discard store.commitTransition("run-1", tx)
  discard store.commitTransition("run-1", tx)
  let rec = store.recover("run-1")
  doAssert rec["events"].len == 1
  doAssert store.pendingOutbox("run-1").len == 1
  store.close()
  removeFile(path)

block artifactRefOpaqueString:
  let aref = artifactRef("art-result-001")
  doAssert $aref == "art-result-001"

echo "test_journal: ok"