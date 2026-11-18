## File-journal BudgetLedger — authoritative reservations (F14).
##
## Durability authority: atomic `state.json` checkpoint + tail replay from
## `journal.ndjson` for events appended after the checkpoint (crash recovery).
## In-process: one shared ledger object per storage root (reference-counted opens).

import std/[json, locks, os, strutils, times, tables]
import nimfactory/contracts/[ports, errors]
import ./types

type
  ScopeRow = object
    ceilingMicroUsd: string
    maxSends: int
    reservedMicroUsd: string
    sendsReserved: int
    spentMicroUsd: string
    sendsSpent: int

  ReservationRow = object
    reservationId: string
    attemptId: string
    scopePath: string
    maxSends: int
    maxMicroUsd: string
    state: string
    sendState: string
    createdAt: string

  FileBudgetLedgerCapabilities* = object
    backend*: string
    storageLayout*: string
    authority*: string
    sharedInProcess*: bool
    multiProcessLock*: bool
    journalRecovery*: bool

  FileBudgetLedger* = ref object of BudgetLedger
    rootDir: string
    statePath: string
    journalPath: string
    lock: Lock
    scopes: Table[string, ScopeRow]
    reservations: Table[string, ReservationRow]
    settles: Table[string, JsonNode]
    journalLineCount: int
    openRefs: int

  OpenRegistryEntry = object
    ledger: FileBudgetLedger

var
  gOpenRegistry = initTable[string, OpenRegistryEntry]()
  gRegistryLock: Lock
  gRegistryInit = false

## Test-only: next `persistState` raises (F14 A.1 persist-failure probe).
var budgetLedgerTestPersistFail* = false

proc fileBudgetLedgerCapabilities*(): FileBudgetLedgerCapabilities =
  FileBudgetLedgerCapabilities(
    backend: "file_journal",
    storageLayout: "directory.state_json_plus_journal_ndjson",
    authority: "state_snapshot_with_journal_tail_replay",
    sharedInProcess: true,
    multiProcessLock: false,
    journalRecovery: true
  )

proc ledgerRoot(dbPath: string): string =
  ## Canonical storage identity: absolute normalized path (collapses `.` / `..`).
  var p = dbPath
  if not p.endsWith(".ledger"):
    p = p & ".ledger"
  result = absolutePath(normalizedPath(p))


proc ensureRegistryLock() =
  if not gRegistryInit:
    initLock(gRegistryLock)
    gRegistryInit = true

proc countJournalLines(path: string): int =
  if not fileExists(path):
    return 0
  result = 0
  for line in path.lines:
    if line.strip.len > 0:
      inc result

proc appendJournal(l: FileBudgetLedger; event: JsonNode) =
  let line = $event & "\n"
  let f = open(l.journalPath, fmAppend)
  defer: f.close()
  f.write(line)
  f.flushFile()
  inc l.journalLineCount

proc truncateJournalTo(l: FileBudgetLedger; lineCount: int) =
  l.journalLineCount = lineCount
  if lineCount <= 0:
    if fileExists(l.journalPath):
      removeFile(l.journalPath)
    return
  var kept: seq[string] = @[]
  var idx = 0
  for line in l.journalPath.lines:
    if line.strip.len == 0:
      continue
    if idx < lineCount:
      kept.add(line)
    inc idx
  let payload = kept.join("\n") & (if kept.len > 0: "\n" else: "")
  writeFile(l.journalPath, payload)

proc persistState(l: FileBudgetLedger) =
  if budgetLedgerTestPersistFail:
    raise newFactoryError(fecEffectOutcomeUnknown,
      "budget persist failed (test hook)", phase = "budget", retryable = true)
  var scopes = newJObject()
  for k, v in l.scopes:
    scopes[k] = %*{
      "ceiling_microusd": v.ceilingMicroUsd,
      "max_sends": v.maxSends,
      "reserved_microusd": v.reservedMicroUsd,
      "sends_reserved": v.sendsReserved,
      "spent_microusd": v.spentMicroUsd,
      "sends_spent": v.sendsSpent
    }
  var reservations = newJObject()
  for k, v in l.reservations:
    reservations[k] = %*{
      "reservation_id": v.reservationId,
      "attempt_id": v.attemptId,
      "scope_path": v.scopePath,
      "max_sends": v.maxSends,
      "max_microusd": v.maxMicroUsd,
      "state": v.state,
      "send_state": v.sendState,
      "created_at": v.createdAt
    }
  var settles = newJObject()
  for k, v in l.settles:
    settles[k] = v
  let payload = %*{
    "schema": "nimfactory.budget-state/0.1",
    "scopes": scopes,
    "reservations": reservations,
    "settles": settles,
    "journal_line_count": l.journalLineCount,
    "saved_at": $getTime().toUnixFloat()
  }
  let tmp = l.statePath & ".tmp"
  writeFile(tmp, $payload)
  try:
    moveFile(tmp, l.statePath)
  except CatchableError as e:
    if fileExists(tmp):
      try:
        removeFile(tmp)
      except CatchableError:
        discard
    raise newFactoryError(fecEffectOutcomeUnknown,
      "budget state persist failed: " & e.msg, phase = "budget", retryable = true)

proc validateNonNegativeAmount*(label, amount: string) =
  let v = parseBigIntStr(amount)
  if v < 0:
    raise newFactoryError(fecValidationFailed, label & " must be non-negative",
      phase = "budget")

proc validateNonNegativeSends*(label: string; maxSends: int) =
  if maxSends < 0:
    raise newFactoryError(fecValidationFailed, label & " must be non-negative",
      phase = "budget")

proc reservationMatches*(existing: ReservationRow; scope: string;
                           maxSends: int; maxMicroUsd: string): bool =
  existing.scopePath == scope and existing.maxSends == maxSends and
    existing.maxMicroUsd == maxMicroUsd

proc readScope(l: FileBudgetLedger; scopePath: string): ScopeRow =
  if scopePath notin l.scopes:
    raise newFactoryError(fecMissingRequiredInput,
      "unknown budget scope: " & scopePath, phase = "budget")
  l.scopes[scopePath]

proc wouldExceed(ceiling, reserved, spent, delta: int64): bool =
  delta < 0 or ceiling < reserved + spent + delta

proc cloneScopes(t: Table[string, ScopeRow]): Table[string, ScopeRow] =
  result = initTable[string, ScopeRow]()
  for k, v in t:
    result[k] = v

proc cloneReservations(t: Table[string, ReservationRow]): Table[string, ReservationRow] =
  result = initTable[string, ReservationRow]()
  for k, v in t:
    result[k] = v

proc cloneSettles(t: Table[string, JsonNode]): Table[string, JsonNode] =
  result = initTable[string, JsonNode]()
  for k, v in t:
    result[k] = v

proc bumpReserved(l: FileBudgetLedger; scopePath: string;
                  deltaMicroUsd: int64; deltaSends: int) =
  var row = l.scopes[scopePath]
  row.reservedMicroUsd = $(parseBigIntStr(row.reservedMicroUsd) + deltaMicroUsd)
  row.sendsReserved += deltaSends
  l.scopes[scopePath] = row

proc bumpReleased(l: FileBudgetLedger; scopePath: string;
                  deltaMicroUsd: int64; deltaSends: int) =
  var row = l.scopes[scopePath]
  row.reservedMicroUsd = $(parseBigIntStr(row.reservedMicroUsd) - deltaMicroUsd)
  row.sendsReserved -= deltaSends
  l.scopes[scopePath] = row

proc applySpend(l: FileBudgetLedger; scopePath: string;
                reservedMax, actual: int64; maxSends: int) =
  var row = l.scopes[scopePath]
  row.reservedMicroUsd = $(parseBigIntStr(row.reservedMicroUsd) - reservedMax)
  row.spentMicroUsd = $(parseBigIntStr(row.spentMicroUsd) + actual)
  row.sendsReserved -= maxSends
  row.sendsSpent += maxSends
  l.scopes[scopePath] = row

proc reservationJson(r: ReservationRow; chain: seq[string]): JsonNode =
  %*{
    "schema": "nimfactory.budget-reservation/0.1",
    "reservation_id": r.reservationId,
    "attempt_id": r.attemptId,
    "scope": r.scopePath,
    "scope_chain": chain,
    "max_sends": r.maxSends,
    "max_microusd": r.maxMicroUsd,
    "state": r.state,
    "send_state": r.sendState
  }

proc attemptIdFromReservation(reservationId: string): string =
  if reservationId.startsWith("rsv-"):
    reservationId[4 .. ^1]
  else:
    reservationId

proc applyJournalEvent(l: FileBudgetLedger; ev: JsonNode) =
  if ev.kind != JObject or "op" notin ev:
    return
  case ev["op"].getStr
  of "define_scope":
    let scope = ev["scope"].getStr
    let ceiling = ev["ceiling_microusd"].getStr
    let maxSends = ev["max_sends"].getInt
    validateNonNegativeAmount("ceiling_microusd", ceiling)
    validateNonNegativeSends("max_sends", maxSends)
    if scope notin l.scopes:
      l.scopes[scope] = ScopeRow(
        ceilingMicroUsd: ceiling, maxSends: maxSends,
        reservedMicroUsd: "0", sendsReserved: 0,
        spentMicroUsd: "0", sendsSpent: 0
      )
    else:
      var row = l.scopes[scope]
      row.ceilingMicroUsd = ceiling
      row.maxSends = maxSends
      l.scopes[scope] = row
  of "reserve":
    let attemptId = ev["attempt_id"].getStr
    let scope = ev["scope"].getStr
    let maxMicroUsd = ev["max_microusd"].getStr
    let maxSends = ev["max_sends"].getInt
    validateNonNegativeAmount("max_microusd", maxMicroUsd)
    validateNonNegativeSends("max_sends", maxSends)
    if attemptId in l.reservations:
      let existing = l.reservations[attemptId]
      if not reservationMatches(existing, scope, maxSends, maxMicroUsd):
        raise newFactoryError(fecValidationFailed,
          "journal replay: idempotent reserve conflict for " & attemptId,
          phase = "budget")
      return
    let reserveAmt = parseBigIntStr(maxMicroUsd)
    let chain = scopeChain(scope)
    for sp in chain:
      let row = readScope(l, sp)
      let ceiling = parseBigIntStr(row.ceilingMicroUsd)
      let reserved = parseBigIntStr(row.reservedMicroUsd)
      let spent = parseBigIntStr(row.spentMicroUsd)
      if wouldExceed(ceiling, reserved, spent, reserveAmt):
        raise newFactoryError(fecEffectOutcomeUnknown,
          "journal replay: ceiling exceeded at " & sp, phase = "budget")
      if maxSends > 0 and (row.sendsSpent + row.sendsReserved + maxSends) > row.maxSends:
        raise newFactoryError(fecEffectOutcomeUnknown,
          "journal replay: max sends exceeded at " & sp, phase = "budget")
    for sp in chain:
      bumpReserved(l, sp, reserveAmt, maxSends)
    let resId = "rsv-" & attemptId
    l.reservations[attemptId] = ReservationRow(
      reservationId: resId, attemptId: attemptId, scopePath: scope,
      maxSends: maxSends, maxMicroUsd: maxMicroUsd,
      state: "reserved", sendState: "not_sent",
      createdAt: $getTime().toUnixFloat()
    )
  of "settle":
    let attemptId = ev["attempt_id"].getStr
    if attemptId in l.settles:
      return
    if attemptId notin l.reservations:
      return
    var res = l.reservations[attemptId]
    let chain = scopeChain(res.scopePath)
    let reservedMax = parseBigIntStr(res.maxMicroUsd)
    let actual = parseBigIntStr(ev{"actual_microusd"}.getStr($reservedMax))
    for sp in chain:
      applySpend(l, sp, reservedMax, actual, res.maxSends)
    res.state = "settled"
    res.sendState = "dispatched"
    l.reservations[attemptId] = res
    l.settles[attemptId] = %*{"attempt_id": attemptId, "actual_microusd": $actual}
  of "mark_unknown":
    let attemptId = ev["attempt_id"].getStr
    if attemptId notin l.reservations:
      return
    if l.reservations[attemptId].state == "settled":
      return
    var res = l.reservations[attemptId]
    res.state = "unknown"
    res.sendState = "unknown"
    l.reservations[attemptId] = res
  of "release_before_send":
    let attemptId = ev["attempt_id"].getStr
    if attemptId notin l.reservations:
      return
    let res = l.reservations[attemptId]
    if res.state != "reserved" or res.sendState != "not_sent":
      return
    let chain = scopeChain(res.scopePath)
    let amt = parseBigIntStr(res.maxMicroUsd)
    for sp in chain:
      bumpReleased(l, sp, amt, res.maxSends)
    l.reservations.del(attemptId)
  else:
    discard

proc replayJournalTail(l: FileBudgetLedger; fromLine: int) =
  if not fileExists(l.journalPath):
    return
  var idx = 0
  for line in l.journalPath.lines:
    if line.strip.len == 0:
      continue
    if idx >= fromLine:
      let ev = parseJson(line)
      applyJournalEvent(l, ev)
    inc idx
  l.journalLineCount = idx

proc loadSnapshotInto(l: FileBudgetLedger) =
  l.scopes.clear()
  l.reservations.clear()
  l.settles.clear()
  l.journalLineCount = 0
  if not fileExists(l.statePath):
    let onDisk = countJournalLines(l.journalPath)
    if onDisk > 0:
      replayJournalTail(l, 0)
    return
  let j = parseFile(l.statePath)
  if "scopes" in j:
    for k, v in j["scopes"].pairs:
      l.scopes[k] = ScopeRow(
        ceilingMicroUsd: v["ceiling_microusd"].getStr,
        maxSends: v["max_sends"].getInt,
        reservedMicroUsd: v["reserved_microusd"].getStr,
        sendsReserved: v["sends_reserved"].getInt,
        spentMicroUsd: v["spent_microusd"].getStr,
        sendsSpent: v["sends_spent"].getInt
      )
  if "reservations" in j:
    for k, v in j["reservations"].pairs:
      l.reservations[k] = ReservationRow(
        reservationId: v["reservation_id"].getStr,
        attemptId: v["attempt_id"].getStr,
        scopePath: v["scope_path"].getStr,
        maxSends: v["max_sends"].getInt,
        maxMicroUsd: v["max_microusd"].getStr,
        state: v["state"].getStr,
        sendState: v["send_state"].getStr,
        createdAt: v["created_at"].getStr
      )
  if "settles" in j:
    for k, v in j["settles"].pairs:
      l.settles[k] = v
  let checkpoint = j{"journal_line_count"}.getInt(0)
  l.journalLineCount = checkpoint
  let onDisk = countJournalLines(l.journalPath)
  if onDisk > checkpoint:
    replayJournalTail(l, checkpoint)

proc newFileBudgetLedger(root: string): FileBudgetLedger =
  result = FileBudgetLedger(
    rootDir: root,
    statePath: root / "state.json",
    journalPath: root / "journal.ndjson",
    scopes: initTable[string, ScopeRow](),
    reservations: initTable[string, ReservationRow](),
    settles: initTable[string, JsonNode](),
    journalLineCount: 0,
    openRefs: 1
  )
  initLock(result.lock)
  loadSnapshotInto(result)

proc openFileBudgetLedger*(dbPath: string): FileBudgetLedger =
  let root = ledgerRoot(dbPath)
  createDir(root)
  ensureRegistryLock()
  acquire(gRegistryLock)
  defer: release(gRegistryLock)
  if root in gOpenRegistry:
    let entry = gOpenRegistry[root]
    entry.ledger.openRefs += 1
    return entry.ledger
  let ledger = newFileBudgetLedger(root)
  gOpenRegistry[root] = OpenRegistryEntry(ledger: ledger)
  ledger

proc closeFileBudgetLedger*(l: FileBudgetLedger) =
  if l.isNil:
    return
  ensureRegistryLock()
  acquire(gRegistryLock)
  defer: release(gRegistryLock)
  l.openRefs -= 1
  if l.openRefs <= 0:
    gOpenRegistry.del(l.rootDir)

proc reloadFileBudgetLedgerFromDisk*(l: FileBudgetLedger) =
  acquire(l.lock)
  defer: release(l.lock)
  loadSnapshotInto(l)

proc defineScope*(l: FileBudgetLedger; scopePath, ceilingMicroUsd: string;
                   maxSends: int) =
  validateNonNegativeAmount("ceiling_microusd", ceilingMicroUsd)
  validateNonNegativeSends("max_sends", maxSends)
  acquire(l.lock)
  defer: release(l.lock)
  if scopePath notin l.scopes:
    l.scopes[scopePath] = ScopeRow(
      ceilingMicroUsd: ceilingMicroUsd, maxSends: maxSends,
      reservedMicroUsd: "0", sendsReserved: 0,
      spentMicroUsd: "0", sendsSpent: 0
    )
  else:
    var row = l.scopes[scopePath]
    row.ceilingMicroUsd = ceilingMicroUsd
    row.maxSends = maxSends
    l.scopes[scopePath] = row
  let journalBefore = l.journalLineCount
  try:
    appendJournal(l, %*{"op": "define_scope", "scope": scopePath,
      "ceiling_microusd": ceilingMicroUsd, "max_sends": maxSends})
    persistState(l)
  except FactoryError:
    raise
  except CatchableError as e:
    truncateJournalTo(l, journalBefore)
    raise newFactoryError(fecEffectOutcomeUnknown,
      "define_scope persist failed: " & e.msg, phase = "budget", retryable = true)

proc snapshot*(l: FileBudgetLedger): JsonNode =
  acquire(l.lock)
  defer: release(l.lock)
  var scopes = newJArray()
  for k, v in l.scopes:
    scopes.add(%*{
      "scope": k,
      "ceiling_microusd": v.ceilingMicroUsd,
      "max_sends": v.maxSends,
      "reserved_microusd": v.reservedMicroUsd,
      "sends_reserved": v.sendsReserved,
      "spent_microusd": v.spentMicroUsd,
      "sends_spent": v.sendsSpent
    })
  let caps = fileBudgetLedgerCapabilities()
  %*{
    "scopes": scopes,
    "ledger_dir": l.rootDir,
    "capabilities": %*{
      "backend": caps.backend,
      "authority": caps.authority,
      "journal_line_count": l.journalLineCount
    }
  }

method reserve*(l: FileBudgetLedger; scope, attemptId: string; maxSends: int;
                maxMicroUsd: string): JsonNode =
  if attemptId.len == 0:
    raise newFactoryError(fecValidationFailed, "attempt_id required",
      phase = "budget")
  validateNonNegativeSends("max_sends", maxSends)
  validateNonNegativeAmount("max_microusd", maxMicroUsd)
  let reserveAmt = parseBigIntStr(maxMicroUsd)
  acquire(l.lock)
  defer: release(l.lock)
  if attemptId in l.reservations:
    let existing = l.reservations[attemptId]
    if not reservationMatches(existing, scope, maxSends, maxMicroUsd):
      raise newFactoryError(fecValidationFailed,
        "reserve idempotency conflict for attempt " & attemptId, phase = "budget")
    return reservationJson(existing, scopeChain(existing.scopePath))
  let chain = scopeChain(scope)
  for sp in chain:
    let row = readScope(l, sp)
    let ceiling = parseBigIntStr(row.ceilingMicroUsd)
    let reserved = parseBigIntStr(row.reservedMicroUsd)
    let spent = parseBigIntStr(row.spentMicroUsd)
    if wouldExceed(ceiling, reserved, spent, reserveAmt):
      raise newFactoryError(fecBudgetExhausted, "budget ceiling exceeded at " & sp,
        phase = "budget", refs = @[sp])
    if maxSends > 0 and (row.sendsSpent + row.sendsReserved + maxSends) > row.maxSends:
      raise newFactoryError(fecBudgetExhausted, "max sends exceeded at " & sp,
        phase = "budget", refs = @[sp])
  let scopesBefore = cloneScopes(l.scopes)
  let reservationsBefore = cloneReservations(l.reservations)
  for sp in chain:
    bumpReserved(l, sp, reserveAmt, maxSends)
  let resId = "rsv-" & attemptId
  let row = ReservationRow(
    reservationId: resId, attemptId: attemptId, scopePath: scope,
    maxSends: maxSends, maxMicroUsd: maxMicroUsd,
    state: "reserved", sendState: "not_sent",
    createdAt: $getTime().toUnixFloat()
  )
  l.reservations[attemptId] = row
  let journalBefore = l.journalLineCount
  try:
    appendJournal(l, %*{"op": "reserve", "attempt_id": attemptId,
      "scope": scope, "max_microusd": maxMicroUsd, "max_sends": maxSends})
    persistState(l)
  except CatchableError:
    l.scopes = scopesBefore
    l.reservations = reservationsBefore
    truncateJournalTo(l, journalBefore)
    raise
  reservationJson(row, chain)

method settle*(l: FileBudgetLedger; reservationId: string; usage: JsonNode) =
  let attemptId = attemptIdFromReservation(reservationId)
  var u = usageFromJson(usage)
  if u.inferenceAttemptId.len == 0:
    u.inferenceAttemptId = attemptId
  if u.reservationId.len == 0:
    u.reservationId = reservationId
  acquire(l.lock)
  defer: release(l.lock)
  if attemptId in l.settles:
    return
  if attemptId notin l.reservations:
    raise newFactoryError(fecMissingRequiredInput,
      "unknown reservation " & reservationId, phase = "budget")
  var res = l.reservations[attemptId]
  let chain = scopeChain(res.scopePath)
  let reservedMax = parseBigIntStr(res.maxMicroUsd)
  let (actualStr, ok) = effectiveCostMicroUsd(u)
  var actual = reservedMax
  if ok:
    actual = parseBigIntStr(actualStr)
    validateNonNegativeAmount("cost_microusd", $actual)
  elif u.accountingKind == "estimated":
    actual = reservedMax
  else:
    raise newFactoryError(fecValidationFailed,
      "usage missing cost_microusd; absent counter is not zero", phase = "budget")
  let scopesBefore = cloneScopes(l.scopes)
  let reservationsBefore = cloneReservations(l.reservations)
  let settlesBefore = cloneSettles(l.settles)
  for sp in chain:
    applySpend(l, sp, reservedMax, actual, res.maxSends)
  res.state = "settled"
  res.sendState = "dispatched"
  l.reservations[attemptId] = res
  let usageNorm = usageToJson(u)
  l.settles[attemptId] = usageNorm
  let journalBefore = l.journalLineCount
  try:
    appendJournal(l, %*{"op": "settle", "attempt_id": attemptId,
      "actual_microusd": $actual})
    persistState(l)
  except CatchableError:
    l.scopes = scopesBefore
    l.reservations = reservationsBefore
    l.settles = settlesBefore
    truncateJournalTo(l, journalBefore)
    raise

method markUnknown*(l: FileBudgetLedger; reservationId: string; reason: string) =
  let attemptId = attemptIdFromReservation(reservationId)
  acquire(l.lock)
  defer: release(l.lock)
  if attemptId notin l.reservations:
    raise newFactoryError(fecMissingRequiredInput,
      "unknown reservation " & reservationId, phase = "budget")
  if l.reservations[attemptId].state == "settled":
    return
  let reservationsBefore = cloneReservations(l.reservations)
  var res = l.reservations[attemptId]
  res.state = "unknown"
  res.sendState = "unknown"
  l.reservations[attemptId] = res
  let journalBefore = l.journalLineCount
  try:
    appendJournal(l, %*{"op": "mark_unknown", "attempt_id": attemptId, "reason": reason})
    persistState(l)
  except CatchableError:
    l.reservations = reservationsBefore
    truncateJournalTo(l, journalBefore)
    raise

method releaseBeforeSend*(l: FileBudgetLedger; reservationId: string) =
  let attemptId = attemptIdFromReservation(reservationId)
  acquire(l.lock)
  defer: release(l.lock)
  if attemptId notin l.reservations:
    raise newFactoryError(fecMissingRequiredInput,
      "unknown reservation for attempt " & attemptId, phase = "budget")
  let res = l.reservations[attemptId]
  if res.state != "reserved" or res.sendState != "not_sent":
    raise newFactoryError(fecValidationFailed,
      "cannot release after send/settle/unknown", phase = "budget")
  let chain = scopeChain(res.scopePath)
  let amt = parseBigIntStr(res.maxMicroUsd)
  let scopesBefore = cloneScopes(l.scopes)
  let reservationsBefore = cloneReservations(l.reservations)
  for sp in chain:
    bumpReleased(l, sp, amt, res.maxSends)
  l.reservations.del(attemptId)
  let journalBefore = l.journalLineCount
  try:
    appendJournal(l, %*{"op": "release_before_send", "attempt_id": attemptId})
    persistState(l)
  except CatchableError:
    l.scopes = scopesBefore
    l.reservations = reservationsBefore
    truncateJournalTo(l, journalBefore)
    raise

type SqliteBudgetLedger* {.deprecated:
  "SqliteBudgetLedger is a file journal backend; use FileBudgetLedger.".} = FileBudgetLedger

proc openSqliteBudgetLedger*(dbPath: string): SqliteBudgetLedger {.deprecated:
  "Use openFileBudgetLedger (file journal backend, not SQLite).".} =
  openFileBudgetLedger(dbPath)

proc closeSqliteBudgetLedger*(l: SqliteBudgetLedger) {.deprecated:
  "Use closeFileBudgetLedger.".} =
  closeFileBudgetLedger(l)