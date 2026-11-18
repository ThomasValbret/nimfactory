## Bounded concurrency helper for ready activations (F5).

import std/[locks, atomics]
import ./types

type
  WorkItem* = object
    activationId*: string
    nodeId*: string
    branchKey*: string

  ConcurrencyGate* = ref object
    maxWorkers: int
    lock: Lock
    active: int
    peak*: int

proc newConcurrencyGate*(maxWorkers: int): ConcurrencyGate =
  let m = if maxWorkers < 1: 1 else: maxWorkers
  result = ConcurrencyGate(maxWorkers: m, active: 0, peak: 0)
  initLock(result.lock)

proc tryEnter*(g: ConcurrencyGate): bool =
  acquire(g.lock)
  defer: release(g.lock)
  if g.active >= g.maxWorkers:
    return false
  inc g.active
  if g.active > g.peak:
    g.peak = g.active
  true

proc leave*(g: ConcurrencyGate) =
  acquire(g.lock)
  defer: release(g.lock)
  if g.active > 0:
    dec g.active

proc activeCount*(g: ConcurrencyGate): int =
  acquire(g.lock)
  defer: release(g.lock)
  g.active
