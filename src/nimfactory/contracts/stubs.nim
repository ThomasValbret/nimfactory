## Contractual in-memory stubs for ports not yet owned by Wave A lots.
## Observable invariants match the port contracts; not production backends.

import std/[json, tables, strutils]
import ./ids
import ./ports
import ./result
import ./errors

type
  MemoryArtifactStore* = ref object of ArtifactStore
    blobs: Table[string, string]
    manifests: Table[string, ArtifactManifest]
    nextId: int

  MemoryRunStore* = ref object of RunStore
    events: Table[string, seq[JsonNode]]
    state: Table[string, JsonNode]
    seenMessageIds: Table[string, bool]

  MemoryBudgetLedger* = ref object of BudgetLedger
    reservations: Table[string, JsonNode]
    settled: Table[string, bool]
    unknown: Table[string, string]
    ceilingMicroUsd: int64
    usedMicroUsd: int64

proc newMemoryArtifactStore*(): MemoryArtifactStore =
  MemoryArtifactStore(blobs: initTable[string, string](),
                      manifests: initTable[string, ArtifactManifest](),
                      nextId: 1)

method put*(s: MemoryArtifactStore; data: string; mime, origin: string): PutResult =
  # Content-addressed id for stub (SHA-256 hex would be F1; stub uses simple key)
  var existing = ""
  for id, blob in s.blobs:
    if blob == data:
      existing = id
      break
  if existing.len > 0:
    # Distinct origin preserved on new provenance record conceptually;
    # stub returns same content id but notes origin in manifest.origin append.
    var m = s.manifests[existing]
    if origin.len > 0 and not m.origin.contains(origin):
      m.origin = m.origin & "|" & origin
      s.manifests[existing] = m
    return PutResult(id: artifactRef(existing), created: false)
  let id = "art-stub-" & $s.nextId
  inc s.nextId
  s.blobs[id] = data
  s.manifests[id] = ArtifactManifest(
    id: artifactRef(id),
    hashAlg: "stub",
    hash: $data.len,
    mime: mime,
    size: data.len.int64,
    origin: origin
  )
  PutResult(id: artifactRef(id), created: true)

method read*(s: MemoryArtifactStore; id: ArtifactRef): string =
  let key = $id
  if key notin s.blobs:
    raise newFactoryError(fecMissingRequiredInput, "unknown artifact " & key,
      phase = "artifact")
  s.blobs[key]

method describe*(s: MemoryArtifactStore; id: ArtifactRef): ArtifactManifest =
  let key = $id
  if key notin s.manifests:
    raise newFactoryError(fecMissingRequiredInput, "unknown artifact " & key,
      phase = "artifact")
  s.manifests[key]

proc newMemoryRunStore*(): MemoryRunStore =
  MemoryRunStore(
    events: initTable[string, seq[JsonNode]](),
    state: initTable[string, JsonNode](),
    seenMessageIds: initTable[string, bool]()
  )

method appendEvent*(s: MemoryRunStore; runId: string; event: JsonNode) =
  if runId notin s.events:
    s.events[runId] = @[]
  let mid = event{"message_id"}.getStr("")
  if mid.len > 0 and mid in s.seenMessageIds:
    return  # dedup retransmission
  if mid.len > 0:
    s.seenMessageIds[mid] = true
  s.events[runId].add(event)

method commitTransition*(s: MemoryRunStore; runId: string; transition: JsonNode): JsonNode =
  s.state[runId] = transition
  if runId notin s.events:
    s.events[runId] = @[]
  s.events[runId].add(%*{"kind": "transition", "body": transition})
  transition

method recover*(s: MemoryRunStore; runId: string): JsonNode =
  result = newJObject()
  result["run_id"] = %runId
  if runId in s.state:
    result["state"] = s.state[runId]
  else:
    result["state"] = newJNull()
  var ev = newJArray()
  if runId in s.events:
    for e in s.events[runId]:
      ev.add(e)
  result["events"] = ev

proc newMemoryBudgetLedger*(ceilingMicroUsd: int64 = 1_000_000): MemoryBudgetLedger =
  MemoryBudgetLedger(
    reservations: initTable[string, JsonNode](),
    settled: initTable[string, bool](),
    unknown: initTable[string, string](),
    ceilingMicroUsd: ceilingMicroUsd,
    usedMicroUsd: 0
  )

method reserve*(l: MemoryBudgetLedger; scope, attemptId: string; maxSends: int;
                maxMicroUsd: string): JsonNode =
  if attemptId in l.reservations:
    return l.reservations[attemptId]  # idempotent by inference_attempt_id
  let amount = maxMicroUsd.parseBiggestInt()
  if l.usedMicroUsd + amount > l.ceilingMicroUsd:
    raise newFactoryError(fecBudgetExhausted, "budget ceiling exceeded",
      phase = "budget")
  l.usedMicroUsd += amount
  result = %*{
    "reservation_id": "rsv-" & attemptId,
    "attempt_id": attemptId,
    "scope": scope,
    "max_sends": maxSends,
    "max_microusd": maxMicroUsd,
    "state": "reserved"
  }
  l.reservations[attemptId] = result

method settle*(l: MemoryBudgetLedger; reservationId: string; usage: JsonNode) =
  let attemptId = reservationId.replace("rsv-", "")
  if attemptId in l.settled:
    return
  l.settled[attemptId] = true
  if attemptId in l.reservations:
    var r = l.reservations[attemptId]
    r["state"] = %"settled"
    r["usage"] = usage
    l.reservations[attemptId] = r

method markUnknown*(l: MemoryBudgetLedger; reservationId: string; reason: string) =
  l.unknown[reservationId] = reason
  let attemptId = reservationId.replace("rsv-", "")
  if attemptId in l.reservations:
    var r = l.reservations[attemptId]
    r["state"] = %"unknown"
    r["reason"] = %reason
    l.reservations[attemptId] = r

method releaseBeforeSend*(l: MemoryBudgetLedger; reservationId: string) =
  let attemptId = reservationId.replace("rsv-", "")
  if attemptId in l.settled or reservationId in l.unknown:
    raise newFactoryError(fecValidationFailed,
      "cannot release after send/settle/unknown", phase = "budget")
  if attemptId in l.reservations:
    let amount = l.reservations[attemptId]["max_microusd"].getStr("0").parseBiggestInt()
    l.usedMicroUsd -= amount
    l.reservations.del(attemptId)

type
  AcceptAllGraphValidator* = ref object of GraphValidator

method validate*(v: AcceptAllGraphValidator; graph: JsonNode): CommonResult =
  var r = defaultResult(rsOk)
  r.outputs = %*{"accepted": true}
  r
