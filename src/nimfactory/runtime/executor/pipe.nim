## Bounded in-process pipes with explicit backpressure policy (F5).

import std/[deques, json, locks, os, strutils]
import nimfactory/contracts/errors
import ./types

type
  PipeMessage* = object
    messageId*: string
    port*: string
    branchKey*: string
    body*: JsonNode

  BoundedPipe* = ref object
    capacity*: int
    policy*: PipePolicy
    spillDir*: string
    lock: Lock
    notFull: Cond
    notEmpty: Cond
    q: Deque[PipeMessage]
    closed: bool
    stats*: PipeStats
    spillSeq: int

proc newBoundedPipe*(capacity: int; policy: PipePolicy;
                     spillDir = ""): BoundedPipe =
  if capacity < 1:
    raise newFactoryError(fecValidationFailed, "pipe capacity must be >= 1",
      phase = "executor")
  result = BoundedPipe(
    capacity: capacity,
    policy: policy,
    spillDir: spillDir,
    q: initDeque[PipeMessage](),
    closed: false,
    spillSeq: 0
  )
  initLock(result.lock)
  initCond(result.notFull)
  initCond(result.notEmpty)

proc depth(p: BoundedPipe): int =
  p.q.len

proc spillMessage(p: BoundedPipe; msg: PipeMessage): string =
  if p.spillDir.len == 0:
    raise newFactoryError(fecValidationFailed,
      "spill policy requires spillDir", phase = "executor")
  createDir(p.spillDir)
  inc p.spillSeq
  let path = p.spillDir / ("spill-" & $p.spillSeq & "-" & msg.messageId & ".json")
  let payload = %*{
    "message_id": msg.messageId,
    "port": msg.port,
    "branch_key": msg.branchKey,
    "body": msg.body
  }
  writeFile(path, $payload)
  path

proc tryEnqueue*(p: BoundedPipe; msg: PipeMessage): tuple[ok: bool, reason: string] =
  ## Non-blocking relative to wait policy: wait blocks; reject/spill decide immediately.
  acquire(p.lock)
  defer: release(p.lock)
  if p.closed:
    return (false, "closed")
  case p.policy
  of ppWait:
    while p.q.len >= p.capacity and not p.closed:
      inc p.stats.waited
      wait(p.notFull, p.lock)
    if p.closed:
      return (false, "closed")
    p.q.addLast(msg)
    inc p.stats.enqueued
    if p.q.len > p.stats.peakDepth:
      p.stats.peakDepth = p.q.len
    signal(p.notEmpty)
    return (true, "enqueued")
  of ppReject:
    if p.q.len >= p.capacity:
      inc p.stats.rejected
      return (false, "rejected_full")
    p.q.addLast(msg)
    inc p.stats.enqueued
    if p.q.len > p.stats.peakDepth:
      p.stats.peakDepth = p.q.len
    signal(p.notEmpty)
    return (true, "enqueued")
  of ppSpill:
    if p.q.len >= p.capacity:
      let path = spillMessage(p, msg)
      inc p.stats.spilled
      signal(p.notEmpty)
      return (true, "spilled:" & path)
    p.q.addLast(msg)
    inc p.stats.enqueued
    if p.q.len > p.stats.peakDepth:
      p.stats.peakDepth = p.q.len
    signal(p.notEmpty)
    return (true, "enqueued")

proc dequeue*(p: BoundedPipe; waitMs = 0): tuple[ok: bool, msg: PipeMessage] =
  acquire(p.lock)
  defer: release(p.lock)
  let deadline = if waitMs > 0: nowMs() + waitMs else: 0'i64
  while p.q.len == 0 and not p.closed:
    if waitMs == 0:
      return (false, PipeMessage())
    if waitMs > 0 and nowMs() >= deadline:
      return (false, PipeMessage())
    wait(p.notEmpty, p.lock)
  if p.q.len == 0:
    return (false, PipeMessage())
  let msg = p.q.popFirst()
  inc p.stats.dequeued
  signal(p.notFull)
  (true, msg)

proc closePipe*(p: BoundedPipe) =
  acquire(p.lock)
  defer: release(p.lock)
  p.closed = true
  broadcast(p.notFull)
  broadcast(p.notEmpty)

proc loadSpill*(path: string): PipeMessage =
  let n = parseJson(readFile(path))
  PipeMessage(
    messageId: n{"message_id"}.getStr(),
    port: n{"port"}.getStr(),
    branchKey: n{"branch_key"}.getStr(),
    body: n{"body"}
  )
