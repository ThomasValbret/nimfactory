## Deterministic demo handlers for F5 / M1 (simulated adapters).

import std/[json, strutils, tables, algorithm, atomics, os]
import nimfactory/contracts/[ids, errors]
import nimfactory/graph/[types, registry]
import ./types

type
  HandlerFn* = proc (inputs: Table[string, JsonNode];
                     ctx: InvocationContext): Table[string, JsonNode] {.nimcall.}

  ExecutableRegistry* = ref object
    descriptors*: SimulatedHandlerRegistry
    impls*: Table[string, HandlerFn]

var
  activeInvocations*: Atomic[int]
  peakInvocations*: Atomic[int]

proc resetInvocationMetrics*() =
  activeInvocations.store(0)
  peakInvocations.store(0)

proc noteInvocationEnter*() =
  let n = activeInvocations.fetchAdd(1) + 1
  var cur = peakInvocations.load
  while n > cur:
    if peakInvocations.compareExchange(cur, n):
      break
    cur = peakInvocations.load

proc noteInvocationLeave*() =
  discard activeInvocations.fetchSub(1)

proc peakConcurrentInvocations*(): int =
  peakInvocations.load

proc newExecutableRegistry*(): ExecutableRegistry =
  let desc = newSimulatedHandlerRegistry()
  registerSeedBasicHandlers(desc)
  result = ExecutableRegistry(
    descriptors: desc,
    impls: initTable[string, HandlerFn]()
  )

proc registerImpl*(r: ExecutableRegistry; href: string; fn: HandlerFn) =
  if not r.descriptors.hasHandler(handlerRef(href)):
    registerHandler(r.descriptors, HandlerDescriptor(
      handlerRef: handlerRef(href),
      inputs: @[port("in", "nimfactory.control_pass/0.1")],
      outputs: @[port("out", "nimfactory.control_pass/0.1")],
      params: @[],
      capabilities: @["demo"],
      effectClass: "pure"
    ))
  r.impls[href] = fn

proc demoLeaf(inputs: Table[string, JsonNode];
              ctx: InvocationContext): Table[string, JsonNode] =
  noteInvocationEnter()
  defer: noteInvocationLeave()
  if ctx.cancelled:
    raise newFactoryError(fecValidationFailed, "cancelled", phase = "handler")
  if deadlineExceeded(ctx):
    raise newFactoryError(fecValidationFailed, "deadline_exceeded", phase = "handler")
  # Hold the slot long enough for a peer thread to overlap under concurrency.
  if ctx.mode == emConcurrent:
    sleep(80)
  if ctx.cancelled:
    raise newFactoryError(fecValidationFailed, "cancelled", phase = "handler")
  if deadlineExceeded(ctx):
    raise newFactoryError(fecValidationFailed, "deadline_exceeded", phase = "handler")
  var payload = newJObject()
  if "in" in inputs and not inputs["in"].isNil:
    payload = inputs["in"]
  let tagged = %*{
    "branch": ctx.branchKey,
    "payload": payload,
    "activation_id": ctx.activationId
  }
  result = initTable[string, JsonNode]()
  result["out"] = tagged

proc demoPassthrough(inputs: Table[string, JsonNode];
                     ctx: InvocationContext): Table[string, JsonNode] =
  noteInvocationEnter()
  defer: noteInvocationLeave()
  if ctx.cancelled:
    raise newFactoryError(fecValidationFailed, "cancelled", phase = "handler")
  if deadlineExceeded(ctx):
    raise newFactoryError(fecValidationFailed, "deadline_exceeded", phase = "handler")
  result = initTable[string, JsonNode]()
  if "in" in inputs:
    result["out"] = inputs["in"]
  else:
    result["out"] = newJObject()

proc demoSlow(inputs: Table[string, JsonNode];
              ctx: InvocationContext): Table[string, JsonNode] =
  noteInvocationEnter()
  defer: noteInvocationLeave()
  let until = nowMs() + 80
  while nowMs() < until:
    if ctx.cancelled:
      raise newFactoryError(fecValidationFailed, "cancelled", phase = "handler")
    if deadlineExceeded(ctx):
      raise newFactoryError(fecValidationFailed, "deadline_exceeded", phase = "handler")
    sleep(5)
  result = initTable[string, JsonNode]()
  if "in" in inputs:
    result["out"] = inputs["in"]
  else:
    result["out"] = newJObject()

proc demoFlag(inputs: Table[string, JsonNode];
              ctx: InvocationContext): Table[string, JsonNode] =
  noteInvocationEnter()
  defer: noteInvocationLeave()
  result = initTable[string, JsonNode]()
  if "in" in inputs:
    result["out"] = inputs["in"]
  else:
    result["out"] = %*{"ready": true}

proc registerDemoHandlers*(r: ExecutableRegistry) =
  registerImpl(r, "demo.leaf@0.1", demoLeaf)
  registerImpl(r, "demo.passthrough@0.1", demoPassthrough)
  registerImpl(r, "demo.slow@0.1", demoSlow)
  registerImpl(r, "demo.flag@0.1", demoFlag)
  registerImpl(r, "noop.passthrough@0.1", demoPassthrough)
  registerImpl(r, "noop.flag@0.1", demoFlag)
  registerImpl(r, "noop.aggregate@0.1", demoPassthrough)
  registerImpl(r, "noop.reduce@0.1", demoPassthrough)

proc invokeHandler*(r: ExecutableRegistry; href: string;
                    inputs: Table[string, JsonNode];
                    ctx: InvocationContext): Table[string, JsonNode] =
  if href notin r.impls:
    raise newFactoryError(fecUnsupportedCapability,
      "no executable impl for handler: " & href, phase = "executor")
  r.impls[href](inputs, ctx)

proc stableAggregate*(parts: seq[JsonNode]): JsonNode =
  var items: seq[JsonNode] = @[]
  for p in parts:
    items.add(p)
  items.sort(proc (a, b: JsonNode): int =
    let ba = a{"branch"}.getStr(a{"branch_key"}.getStr(""))
    let bb = b{"branch"}.getStr(b{"branch_key"}.getStr(""))
    result = cmp(ba, bb)
    if result == 0:
      result = cmp($a, $b)
  )
  result = %*{"items": items, "count": items.len}
