## File-journal BudgetLedger — authoritative reservations (F14).
##
## Backend: append-only NDJSON journal + atomic state snapshot (rename).
## No SQLite dependency; suitable for local single-host runs.

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

  FileBudgetLedger* = ref object of BudgetLedger
    rootDir: string
    statePath: string
    journalPath: string
    lock: Lock
    scopes: Table[string, ScopeRow]
    reservations: Table[string, ReservationRow]
    settles: Table[string, JsonNode]

proc ledgerRoot(dbPath: string): string =
  if dbPath.endsWith(".ledger"):
    dbPath
  else:
    dbPath & ".ledger"

proc openFileBudgetLedger*(dbPath: string): FileBudgetLedger =
  let root = ledgerRoot(dbPath)
  createDir(root)
  result = FileBudgetLedger(
    rootDir: root,
    statePath: root / "state.json",
    journalPath: root / "journal.ndjson",
    scopes: initTable[string, ScopeRow](),
    reservations: initTable[string, ReservationRow](),
    settles: initTable[string, JsonNode]()
  )
  initLock(result.lock)
  if fileExists(result.statePath):
    let j = parseFile(result.statePath)
    if "scopes" in j:
      for k, v in j["scopes"].pairs:
        result.scopes[k] = ScopeRow(
          ceilingMicroUsd: v["ceiling_microusd"].getStr,
          maxSends: v["max_sends"].getInt,
          reservedMicroUsd: v["reserved_microusd"].getStr,
          sendsReserved: v["sends_reserved"].getInt,
          spentMicroUsd: v["spent_microusd"].getStr,
          sendsSpent: v["sends_spent"].getInt
        )
    if "reservations" in j:
      for k, v in j["reservations"].pairs:
        result.reservations[k] = ReservationRow(
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
        result.settles[k] = v

proc closeFileBudgetLedger*(l: FileBudgetLedger) =
  discard

proc appendJournal(l: FileBudgetLedger; event: JsonNode) =
  let line = $event & "\n"
  let f = open(l.journalPath, fmAppend)
  defer: f.close()
  f.write(line)
  f.flushFile()

proc persistState(l: FileBudgetLedger) =
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
    "saved_at": $getTime().toUnixFloat()
  }
  let tmp = l.statePath & ".tmp"
  writeFile(tmp, $payload)
  moveFile(tmp, l.statePath)

proc defineScope*(l: FileBudgetLedger; scopePath, ceilingMicroUsd: string;
                   maxSends: int) =
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
  appendJournal(l, %*{"op": "define_scope", "scope": scopePath,
    "ceiling_microusd": ceilingMicroUsd, "max_sends": maxSends})
  persistState(l)

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
  %*{"scopes": scopes, "ledger_dir": l.rootDir}

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

proc readScope(l: FileBudgetLedger; scopePath: string): ScopeRow =
  if scopePath notin l.scopes:
    raise newFactoryError(fecMissingRequiredInput,
      "unknown budget scope: " & scopePath, phase = "budget")
  l.scopes[scopePath]

proc wouldExceed(ceiling, reserved, spent, delta: int64): bool =
  ceiling < reserved + spent + delta

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

method reserve*(l: FileBudgetLedger; scope, attemptId: string; maxSends: int;
                maxMicroUsd: string): JsonNode =
  if attemptId.len == 0:
    raise newFactoryError(fecValidationFailed, "attempt_id required",
      phase = "budget")
  acquire(l.lock)
  defer: release(l.lock)
  if attemptId in l.reservations:
    let r = l.reservations[attemptId]
    return reservationJson(r, scopeChain(r.scopePath))
  let reserveAmt = parseBigIntStr(maxMicroUsd)
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
  appendJournal(l, %*{"op": "reserve", "attempt_id": attemptId,
    "scope": scope, "max_microusd": maxMicroUsd, "max_sends": maxSends})
  persistState(l)
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
  elif u.accountingKind == "estimated":
    actual = reservedMax
  else:
    raise newFactoryError(fecValidationFailed,
      "usage missing cost_microusd; absent counter is not zero", phase = "budget")
  for sp in chain:
    applySpend(l, sp, reservedMax, actual, res.maxSends)
  res.state = "settled"
  res.sendState = "dispatched"
  l.reservations[attemptId] = res
  let usageNorm = usageToJson(u)
  l.settles[attemptId] = usageNorm
  appendJournal(l, %*{"op": "settle", "attempt_id": attemptId,
    "actual_microusd": $actual})
  persistState(l)

method markUnknown*(l: FileBudgetLedger; reservationId: string; reason: string) =
  let attemptId = attemptIdFromReservation(reservationId)
  acquire(l.lock)
  defer: release(l.lock)
  if attemptId notin l.reservations:
    raise newFactoryError(fecMissingRequiredInput,
      "unknown reservation " & reservationId, phase = "budget")
  if l.reservations[attemptId].state == "settled":
    return
  var res = l.reservations[attemptId]
  res.state = "unknown"
  res.sendState = "unknown"
  l.reservations[attemptId] = res
  appendJournal(l, %*{"op": "mark_unknown", "attempt_id": attemptId, "reason": reason})
  persistState(l)

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
  for sp in chain:
    bumpReleased(l, sp, amt, res.maxSends)
  l.reservations.del(attemptId)
  appendJournal(l, %*{"op": "release_before_send", "attempt_id": attemptId})
  persistState(l)

## Primary ledger alias used by tests and future integrators.
type SqliteBudgetLedger* = FileBudgetLedger

proc openSqliteBudgetLedger*(dbPath: string): SqliteBudgetLedger =
  openFileBudgetLedger(dbPath)

proc closeSqliteBudgetLedger*(l: SqliteBudgetLedger) =
  closeFileBudgetLedger(l)