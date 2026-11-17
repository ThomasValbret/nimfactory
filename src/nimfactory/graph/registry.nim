## Simulated handler registry for graph validation (F4).

import std/[tables]
import ../contracts/[ids, errors, ports]
import ./types

type
  SimulatedHandlerRegistry* = ref object of HandlerRegistry
    handlers*: Table[string, HandlerDescriptor]

proc newSimulatedHandlerRegistry*(): SimulatedHandlerRegistry =
  SimulatedHandlerRegistry(handlers: initTable[string, HandlerDescriptor]())

proc port*(name, schema: string; required = true): PortDecl =
  PortDecl(name: name, schema: schema, required: required)

proc registerHandler*(r: SimulatedHandlerRegistry; desc: HandlerDescriptor) =
  let key = $desc.handlerRef
  if key in r.handlers:
    raise newFactoryError(fecDuplicateKey, "duplicate handler: " & key,
      phase = "graph")
  r.handlers[key] = desc

proc lookupHandler*(r: SimulatedHandlerRegistry; href: HandlerRef): HandlerDescriptor =
  let key = $href
  if key notin r.handlers:
    raise newFactoryError(fecValidationFailed, "unknown handler: " & key,
      phase = "graph")
  r.handlers[key]

proc hasHandler*(r: SimulatedHandlerRegistry; href: HandlerRef): bool =
  ($href) in r.handlers

proc registerSeedBasicHandlers*(r: SimulatedHandlerRegistry) =
  const
    ctx = "nimfactory.context_request/0.1"
    frg = "nimfactory.fragments_bundle/0.1"
    plan = "nimfactory.model_plan/0.1"
    seed = "nimfactory.inference_seed/0.1"
    rcpt = "nimfactory.preparation_receipt/0.1"
    pass = "nimfactory.control_pass/0.1"
    flag = "nimfactory.control_flag/0.1"
    agg = "nimfactory.control_aggregate/0.1"
    evt = "nimfactory.control_event/0.1"
  registerHandler(r, HandlerDescriptor(
    handlerRef: handlerRef("prompt.prepare@0.1"),
    inputs: @[port("request", ctx)],
    outputs: @[port("fragments", frg)],
    params: @[],
    capabilities: @["prepare"],
    effectClass: "pure"
  ))
  registerHandler(r, HandlerDescriptor(
    handlerRef: handlerRef("instructions.select@0.1"),
    inputs: @[port("request", ctx)],
    outputs: @[port("fragments", frg)],
    params: @[],
    capabilities: @["prepare"],
    effectClass: "pure"
  ))
  registerHandler(r, HandlerDescriptor(
    handlerRef: handlerRef("seed.assemble@0.1"),
    inputs: @[
      port("request", ctx),
      port("model_plan", plan),
      port("task_fragments", frg),
      port("instruction_fragments", frg)
    ],
    outputs: @[port("seed", seed), port("receipt", rcpt)],
    params: @[],
    capabilities: @["assemble"],
    effectClass: "pure"
  ))
  registerHandler(r, HandlerDescriptor(
    handlerRef: handlerRef("noop.passthrough@0.1"),
    inputs: @[port("in", pass)],
    outputs: @[port("out", pass)],
    params: @[],
    capabilities: @[],
    effectClass: "pure"
  ))
  registerHandler(r, HandlerDescriptor(
    handlerRef: handlerRef("noop.flag@0.1"),
    inputs: @[port("in", flag)],
    outputs: @[port("out", flag)],
    params: @[],
    capabilities: @[],
    effectClass: "pure"
  ))
  registerHandler(r, HandlerDescriptor(
    handlerRef: handlerRef("noop.aggregate@0.1"),
    inputs: @[port("in", agg, required = false)],
    outputs: @[port("out", agg)],
    params: @[],
    capabilities: @[],
    effectClass: "pure"
  ))
  registerHandler(r, HandlerDescriptor(
    handlerRef: handlerRef("noop.reduce@0.1"),
    inputs: @[port("in", agg, required = false)],
    outputs: @[port("out", agg)],
    params: @[],
    capabilities: @[],
    effectClass: "pure"
  ))
  registerHandler(r, HandlerDescriptor(
    handlerRef: handlerRef("noop.event@0.1"),
    inputs: @[port("await", evt)],
    outputs: @[port("out", pass)],
    params: @[],
    capabilities: @[],
    effectClass: "external"
  ))

proc controlInputPorts*(kind: ControlKind): seq[PortDecl] =
  const pass = "nimfactory.control_pass/0.1"
  const flag = "nimfactory.control_flag/0.1"
  const evt = "nimfactory.control_event/0.1"
  const agg = "nimfactory.control_aggregate/0.1"
  case kind
  of ckHandler: @[]
  of ckSequence:
    @[port("in", pass), port("next", pass, required = false)]
  of ckBranch:
    @[port("in", flag)]
  of ckMap:
    @[port("in", pass)]
  of ckJoin:
    @[port("in", pass, required = false)]
  of ckReduce:
    @[port("in", agg, required = false)]
  of ckLoop:
    @[port("in", pass)]
  of ckSubgraph:
    @[port("in", pass)]
  of ckAwaitEvent:
    @[port("trigger", evt)]

proc controlOutputPorts*(kind: ControlKind): seq[PortDecl] =
  const pass = "nimfactory.control_pass/0.1"
  const flag = "nimfactory.control_flag/0.1"
  const agg = "nimfactory.control_aggregate/0.1"
  case kind
  of ckHandler: @[]
  of ckSequence:
    @[port("out", pass)]
  of ckBranch:
    @[port("then", pass), port("else", pass)]
  of ckMap:
    @[port("branch", pass)]
  of ckJoin:
    @[port("out", agg)]
  of ckReduce:
    @[port("out", agg)]
  of ckLoop:
    @[port("body", pass), port("done", pass)]
  of ckSubgraph:
    @[port("out", pass)]
  of ckAwaitEvent:
    @[port("out", pass)]