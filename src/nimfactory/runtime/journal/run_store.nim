## Durable RunStore: SQLite backend, outbox, dedup, lease/epoch, recover.

import std/[json, os, strutils]
import nimfactory/contracts/[ports, errors]
import ./sqlite_ffi
import ./schema

export JournalStorageError

type
  CommitCrashPoint* = enum
    ccNone
    ccBeforeCommit
    ccAfterCommitBeforeOutboxVisible
    ccAfterCommit

  SqliteRunStore* = ref object of RunStore
    dbPath*: string
    db*: SqliteDb
    commitCrashPoint*: CommitCrashPoint

  DeliveryResult* = object
    accepted*: bool
    duplicate*: bool
    staleEpoch*: bool
    reason*: string

proc openDb(path: string): SqliteDb =
  var db: SqliteDb = nil
  let rc = sqlite3_open(path.cstring, addr db)
  if rc != SQLITE_OK:
    var msg = "failed to open sqlite db at " & path
    if db != nil:
      msg = sqliteErr(db, msg)
      discard sqlite3_close(db)
    raise newException(JournalStorageError, msg)
  applySchema(db)
  result = db

proc newSqliteRunStore*(dbPath: string): SqliteRunStore =
  let parent = splitPath(dbPath).head
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  SqliteRunStore(dbPath: dbPath, db: openDb(dbPath), commitCrashPoint: ccNone)

proc close*(s: SqliteRunStore) =
  if s.db != nil:
    discard sqlite3_close(s.db)
    s.db = nil

proc cloneStoreAt*(s: SqliteRunStore; newPath: string): SqliteRunStore =
  if fileExists(s.dbPath):
    copyFile(s.dbPath, newPath)
  newSqliteRunStore(newPath)

proc hasRun*(s: SqliteRunStore; runId: string): bool =
  ## True only if the run row already exists (does not create).
  let existing = queryAll(s.db,
    "SELECT run_id FROM nf_runs WHERE run_id = ?", [runId])
  existing.len > 0

proc ensureRun(s: SqliteRunStore; runId: string) =
  if s.hasRun(runId):
    return
  runPrepared(s.db,
    "INSERT INTO nf_runs(run_id, epoch, owner_token, state_json, event_seq) VALUES(?, 1, '', '{}', 0)",
    [runId])

proc nextEventSeq(s: SqliteRunStore; runId: string): int =
  runPrepared(s.db, "UPDATE nf_runs SET event_seq = event_seq + 1 WHERE run_id = ?", [runId])
  let rows = queryAll(s.db, "SELECT event_seq FROM nf_runs WHERE run_id = ?", [runId])
  if rows.len == 0:
    raise newException(JournalStorageError, "missing run " & runId)
  parseInt(rows[0])

proc currentEpoch*(s: SqliteRunStore; runId: string): int =
  ensureRun(s, runId)
  let rows = queryAll(s.db, "SELECT epoch FROM nf_runs WHERE run_id = ?", [runId])
  parseInt(rows[0])

proc claimLease*(s: SqliteRunStore; runId: string; ownerToken: string): int =
  ensureRun(s, runId)
  runPrepared(s.db,
    "UPDATE nf_runs SET owner_token = ?, epoch = epoch + 1 WHERE run_id = ?",
    [ownerToken, runId])
  s.currentEpoch(runId)

proc transitionCommitted(s: SqliteRunStore; runId, transitionId: string): bool =
  let rows = queryAll(s.db,
    "SELECT transition_id FROM nf_transitions WHERE run_id = ? AND transition_id = ?",
    [runId, transitionId])
  rows.len > 0

proc loadCommittedTransition(s: SqliteRunStore; runId, transitionId: string): JsonNode =
  let rows = queryAll(s.db,
    "SELECT transition_json FROM nf_transitions WHERE run_id = ? AND transition_id = ?",
    [runId, transitionId])
  if rows.len == 0:
    return newJNull()
  parseJson(rows[0])

proc runEpochInTxn(s: SqliteRunStore; runId: string): int =
  let rows = queryAll(s.db, "SELECT epoch FROM nf_runs WHERE run_id = ?", [runId])
  if rows.len == 0:
    raise newException(JournalStorageError, "missing run " & runId)
  parseInt(rows[0])

proc jsonSubstateText(transition: JsonNode; key: string): string =
  if not transition.hasKey(key):
    return "null"
  let node = transition[key]
  if node.kind == JNull:
    return "null"
  $node

proc validateTransitionFields(transition: JsonNode) =
  let actId = transition{"activation_id"}.getStr("")
  let attId = transition{"attempt_id"}.getStr("")
  if actId.len > 0 and not transition.hasKey("activation_state"):
    raise newFactoryError(fecMissingRequiredInput,
      "transition with activation_id requires activation_state",
      phase = "journal", retryable = false)
  if attId.len > 0 and not transition.hasKey("attempt_state"):
    raise newFactoryError(fecMissingRequiredInput,
      "transition with attempt_id requires attempt_state",
      phase = "journal", retryable = false)

method appendEvent*(s: SqliteRunStore; runId: string; event: JsonNode) =
  ensureRun(s, runId)
  let mid = event{"message_id"}.getStr("")
  if mid.len > 0:
    let seen = queryAll(s.db,
      "SELECT message_id FROM nf_inbound_consumed WHERE run_id = ? AND message_id = ?",
      [runId, mid])
    if seen.len > 0:
      return
    let evEpoch = event{"epoch"}.getInt(-1)
    if evEpoch >= 0:
      let cur = s.currentEpoch(runId)
      if evEpoch < cur:
        raise newFactoryError(fecStaleSnapshot,
          "late delivery from epoch " & $evEpoch & " (current " & $cur & ")",
          phase = "journal", retryable = false)
  execSql(s.db, "BEGIN IMMEDIATE")
  try:
    let seq = s.nextEventSeq(runId)
    runPrepared(s.db,
      "INSERT INTO nf_events(run_id, seq, message_id, event_json) VALUES(?, ?, ?, ?)",
      [runId, $seq, mid, $event])
    if mid.len > 0:
      runPrepared(s.db,
        "INSERT INTO nf_inbound_consumed(run_id, message_id) VALUES(?, ?)",
        [runId, mid])
    execSql(s.db, "COMMIT")
  except CatchableError:
    execSql(s.db, "ROLLBACK")
    raise

method commitTransition*(s: SqliteRunStore; runId: string; transition: JsonNode): JsonNode =
  ensureRun(s, runId)
  let transitionId = transition{"transition_id"}.getStr("")
  ## Idempotent replay: an already-persisted transition_id returns the stored JSON
  ## without re-checking epoch and without mutating events, state, or outbox.
  if transitionId.len > 0 and s.transitionCommitted(runId, transitionId):
    return s.loadCommittedTransition(runId, transitionId)

  validateTransitionFields(transition)

  if s.commitCrashPoint == ccBeforeCommit:
    raise newException(JournalStorageError, "simulated crash before commit")

  execSql(s.db, "BEGIN IMMEDIATE")
  try:
    let curEpoch = s.runEpochInTxn(runId)
    ## Mutating transitions must carry an integer epoch matching the current owner.
    if not transition.hasKey("epoch") or transition["epoch"].kind != JInt:
      raise newFactoryError(fecMissingRequiredInput,
        "transition.epoch required for mutating commit", phase = "journal",
        retryable = false)
    let txEpoch = transition["epoch"].getInt
    if txEpoch != curEpoch:
      raise newFactoryError(fecStaleSnapshot,
        "transition epoch " & $txEpoch & " does not match run epoch " & $curEpoch,
        phase = "journal", retryable = false)
    if transition.hasKey("state"):
      runPrepared(s.db,
        "UPDATE nf_runs SET state_json = ? WHERE run_id = ?",
        [$transition["state"], runId])
    let actId = transition{"activation_id"}.getStr("")
    let attId = transition{"attempt_id"}.getStr("")
    let epoch = txEpoch
    let validated = if transition{"invocation_validated"}.getBool(false): "1" else: "0"
    if actId.len > 0:
      runPrepared(s.db,
        "INSERT OR REPLACE INTO nf_activations(run_id, activation_id, state_json, epoch, invocation_validated) VALUES(?, ?, ?, ?, ?)",
        [runId, actId, jsonSubstateText(transition, "activation_state"), $epoch, validated])
    if actId.len > 0 and attId.len > 0:
      runPrepared(s.db,
        "INSERT OR REPLACE INTO nf_attempts(run_id, activation_id, attempt_id, state_json) VALUES(?, ?, ?, ?)",
        [runId, actId, attId, jsonSubstateText(transition, "attempt_state")])
    if transition.hasKey("result_refs"):
      # stored inside run state / activation; also echo in transition record
      discard transition["result_refs"]
    if transition.hasKey("external_effects"):
      for eff in transition["external_effects"]:
        let eid = eff{"effect_id"}.getStr("")
        if eid.len == 0:
          continue
        runPrepared(s.db,
          "INSERT OR REPLACE INTO nf_external_effects(run_id, effect_id, activation_id, attempt_id, status, receipt_ref) VALUES(?, ?, ?, ?, ?, ?)",
          [runId, eid, eff{"activation_id"}.getStr(actId), eff{"attempt_id"}.getStr(attId),
           eff{"status"}.getStr("unknown"), eff{"receipt_ref"}.getStr("")])
    let seq = s.nextEventSeq(runId)
    var ev = %*{"kind": "transition", "seq": seq, "body": transition}
    if transitionId.len > 0:
      ev["transition_id"] = %transitionId
    runPrepared(s.db,
      "INSERT INTO nf_events(run_id, seq, message_id, event_json) VALUES(?, ?, '', ?)",
      [runId, $seq, $ev])
    if transition.hasKey("outbox"):
      for msg in transition["outbox"]:
        let mid = msg{"message_id"}.getStr("")
        if mid.len == 0:
          continue
        let rows = queryAll(s.db,
          "SELECT message_id FROM nf_outbox WHERE run_id = ? AND message_id = ?",
          [runId, mid])
        if rows.len == 0:
          runPrepared(s.db,
            "INSERT INTO nf_outbox(run_id, message_id, payload_json, status, created_seq) VALUES(?, ?, ?, 'pending', ?)",
            [runId, mid, $msg, $seq])
    if transitionId.len > 0:
      runPrepared(s.db,
        "INSERT INTO nf_transitions(run_id, transition_id, transition_json) VALUES(?, ?, ?)",
        [runId, transitionId, $transition])
    execSql(s.db, "COMMIT")
  except CatchableError:
    execSql(s.db, "ROLLBACK")
    raise

  if s.commitCrashPoint == ccAfterCommit:
    raise newException(JournalStorageError, "simulated crash after commit")

  transition

proc pendingOutbox*(s: SqliteRunStore; runId: string): seq[JsonNode] =
  let rows = queryAll(s.db,
    "SELECT payload_json FROM nf_outbox WHERE run_id = ? AND status = 'pending' ORDER BY created_seq",
    [runId])
  for r in rows:
    result.add(parseJson(r))

proc publishPending*(s: SqliteRunStore; runId: string): seq[JsonNode] =
  result = s.pendingOutbox(runId)
  execSql(s.db, "BEGIN IMMEDIATE")
  try:
    runPrepared(s.db,
      "UPDATE nf_outbox SET status = 'publishing' WHERE run_id = ? AND status = 'pending'",
      [runId])
    execSql(s.db, "COMMIT")
  except CatchableError:
    execSql(s.db, "ROLLBACK")
    raise

proc redistributeUnackedOutbox*(s: SqliteRunStore; runId: string): seq[JsonNode] =
  ## Returns unacked messages left in ``publishing`` and re-arms them as ``pending``
  ## so ``publishPending`` can hand them off again with the same ``message_id``.
  let rows = queryAll(s.db,
    "SELECT payload_json FROM nf_outbox WHERE run_id = ? AND status = 'publishing' ORDER BY created_seq",
    [runId])
  for r in rows:
    result.add(parseJson(r))
  if result.len == 0:
    return
  execSql(s.db, "BEGIN IMMEDIATE")
  try:
    runPrepared(s.db,
      "UPDATE nf_outbox SET status = 'pending' WHERE run_id = ? AND status = 'publishing'",
      [runId])
    execSql(s.db, "COMMIT")
  except CatchableError:
    execSql(s.db, "ROLLBACK")
    raise

proc acknowledgeOutbox*(s: SqliteRunStore; runId, messageId: string;
                        crashAfterAck = false) =
  execSql(s.db, "BEGIN IMMEDIATE")
  try:
    runPrepared(s.db,
      "UPDATE nf_outbox SET status = 'acked' WHERE run_id = ? AND message_id = ?",
      [runId, messageId])
    execSql(s.db, "COMMIT")
  except CatchableError:
    execSql(s.db, "ROLLBACK")
    raise
  if crashAfterAck:
    raise newException(JournalStorageError, "simulated crash after outbox ack")

proc invocationMayBeRequested*(s: SqliteRunStore; runId, activationId, attemptId: string): bool =
  let rows = queryAll(s.db,
    "SELECT invocation_validated FROM nf_activations WHERE run_id = ? AND activation_id = ?",
    [runId, activationId])
  if rows.len == 0:
    return true
  if rows[0] == "1":
    return false
  true

proc acceptHandlerDelivery*(s: SqliteRunStore; runId: string; delivery: JsonNode): DeliveryResult =
  result = DeliveryResult(accepted: false)
  let mid = delivery{"message_id"}.getStr("")
  let epoch = delivery{"epoch"}.getInt(-1)
  if epoch >= 0 and epoch < s.currentEpoch(runId):
    return DeliveryResult(accepted: false, staleEpoch: true,
      reason: "stale owner epoch")
  if mid.len > 0:
    let seen = queryAll(s.db,
      "SELECT message_id FROM nf_inbound_consumed WHERE run_id = ? AND message_id = ?",
      [runId, mid])
    if seen.len > 0:
      return DeliveryResult(accepted: true, duplicate: true, reason: "dedup message_id")
    s.appendEvent(runId, delivery)
    return DeliveryResult(accepted: true, reason: "consumed")
  return DeliveryResult(accepted: false, reason: "missing message_id")

method recover*(s: SqliteRunStore; runId: string): JsonNode =
  ## Read-only recovery: unknown run_id must not create durable state.
  if not s.hasRun(runId):
    raise newFactoryError(fecMissingRequiredInput,
      "unknown run_id (refuse recover without creating state): " & runId,
      phase = "journal", retryable = false)
  result = newJObject()
  result["run_id"] = %runId
  let stateRows = queryAll(s.db, "SELECT state_json FROM nf_runs WHERE run_id = ?", [runId])
  if stateRows.len > 0:
    result["state"] = parseJson(stateRows[0])
  else:
    result["state"] = newJNull()
  result["epoch"] = %s.currentEpoch(runId)
  let ownerRows = queryAll(s.db, "SELECT owner_token FROM nf_runs WHERE run_id = ?", [runId])
  result["owner_token"] = if ownerRows.len > 0: %ownerRows[0] else: %""

  var events = newJArray()
  let evRows = queryAll(s.db,
    "SELECT event_json FROM nf_events WHERE run_id = ? ORDER BY seq", [runId])
  for e in evRows:
    events.add(parseJson(e))
  result["events"] = events

  var acts = newJObject()
  let actIds = queryAll(s.db, "SELECT activation_id FROM nf_activations WHERE run_id = ?", [runId])
  for aid in actIds:
    let st = queryAll(s.db,
      "SELECT state_json FROM nf_activations WHERE run_id = ? AND activation_id = ?",
      [runId, aid])
    let ep = queryAll(s.db,
      "SELECT epoch FROM nf_activations WHERE run_id = ? AND activation_id = ?",
      [runId, aid])
    let val = queryAll(s.db,
      "SELECT invocation_validated FROM nf_activations WHERE run_id = ? AND activation_id = ?",
      [runId, aid])
    acts[aid] = %*{
      "state": if st.len > 0: parseJson(st[0]) else: newJNull(),
      "epoch": if ep.len > 0: parseInt(ep[0]) else: 0,
      "invocation_validated": if val.len > 0 and val[0] == "1": true else: false,
    }
  result["activations"] = acts

  var effects = newJArray()
  let effIds = queryAll(s.db, "SELECT effect_id FROM nf_external_effects WHERE run_id = ?", [runId])
  for eid in effIds:
    let status = queryAll(s.db,
      "SELECT status FROM nf_external_effects WHERE run_id = ? AND effect_id = ?",
      [runId, eid])
    let receipt = queryAll(s.db,
      "SELECT receipt_ref FROM nf_external_effects WHERE run_id = ? AND effect_id = ?",
      [runId, eid])
    let act = queryAll(s.db,
      "SELECT activation_id FROM nf_external_effects WHERE run_id = ? AND effect_id = ?",
      [runId, eid])
    let att = queryAll(s.db,
      "SELECT attempt_id FROM nf_external_effects WHERE run_id = ? AND effect_id = ?",
      [runId, eid])
    effects.add(%*{
      "effect_id": eid,
      "activation_id": if act.len > 0: act[0] else: "",
      "attempt_id": if att.len > 0: att[0] else: "",
      "status": if status.len > 0: status[0] else: "unknown",
      "receipt_ref": if receipt.len > 0: receipt[0] else: "",
    })
  result["external_effects"] = effects

  var pending = newJArray()
  let outRows = queryAll(s.db,
    "SELECT payload_json FROM nf_outbox WHERE run_id = ? AND status IN ('pending', 'publishing') ORDER BY created_seq",
    [runId])
  for o in outRows:
    pending.add(parseJson(o))
  result["outbox_pending"] = pending

  var denied = newJArray()
  for aid, entry in acts.pairs:
    if entry{"invocation_validated"}.getBool(false):
      denied.add(%*{
        "activation_id": aid,
        "reason": "invocation_validated",
        "reinvoke_allowed": false,
      })
  result["reinvoke_policy"] = denied

proc effectOutcomeUnknown*(s: SqliteRunStore; runId, effectId: string): bool =
  let rows = queryAll(s.db,
    "SELECT status FROM nf_external_effects WHERE run_id = ? AND effect_id = ?",
    [runId, effectId])
  if rows.len == 0:
    return false
  rows[0] in ["effect_outcome_unknown", "unknown"]