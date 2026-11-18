## Local GraphSpec executor: sequential / bounded concurrent, durable resume (F5).

import std/[json, os, strutils, tables, sequtils, algorithm, locks]
import nimfactory/contracts/[errors, ids, result]
import nimfactory/graph/[types, codec, registry, validator]
import nimfactory/runtime/journal/run_store
import ./types
import ./pipe
import ./handlers
import ./scheduler

export types, pipe, handlers, scheduler

type
  EdgeRef = object
    fromNode: string
    fromPort: string
    toNode: string
    toPort: string

  PendingInputs = Table[string, JsonNode]  ## port -> body

  ActivationWork = object
    activationId: string
    nodeId: string
    branchKey: string
    inputs: PendingInputs

  HandlerOutcome = object
    ok: bool
    activationId: string
    nodeId: string
    branchKey: string
    outputs: Table[string, JsonNode]
    err: string
    cancelled: bool
    timedOut: bool

  LocalExecutor* = ref object
    store*: SqliteRunStore
    registry*: ExecutableRegistry
    config*: ExecConfig
    graph*: GraphSpec
    nodes: Table[string, GraphNode]
    edges: seq[EdgeRef]
    inbound: Table[string, seq[EdgeRef]]   ## toNode -> edges
    outbound: Table[string, seq[EdgeRef]]  ## fromNode -> edges
    pending: Table[string, PendingInputs] ## activationId -> ports
    completed: Table[string, ActivationRecord]
    ready: seq[string]
    pipe*: BoundedPipe
    gate: ConcurrencyGate
    commitLock: Lock
    epoch: int
    transitionSeq: int
    activationCommits: int
    events: seq[JsonNode]
    skippedValidated: seq[string]
    runId: string
    status: ExecStatus
    outputs: JsonNode
    resumed: bool
    absoluteDeadline: int64

proc parsePort(s: string): tuple[node, port: string] =
  let i = s.rfind('.')
  if i <= 0:
    raise newFactoryError(fecValidationFailed, "bad port ref: " & s, phase = "executor")
  (s[0 ..< i], s[i+1 .. ^1])

proc buildTopology(ex: LocalExecutor) =
  ex.nodes = initTable[string, GraphNode]()
  for n in ex.graph.nodes:
    ex.nodes[n.id] = n
  ex.edges = @[]
  ex.inbound = initTable[string, seq[EdgeRef]]()
  ex.outbound = initTable[string, seq[EdgeRef]]()
  for e in ex.graph.edges:
    let (fn, fp) = parsePort(e.fromPort)
    let (tn, tp) = parsePort(e.toPort)
    let er = EdgeRef(fromNode: fn, fromPort: fp, toNode: tn, toPort: tp)
    ex.edges.add(er)
    if tn notin ex.inbound: ex.inbound[tn] = @[]
    ex.inbound[tn].add(er)
    if fn notin ex.outbound: ex.outbound[fn] = @[]
    ex.outbound[fn].add(er)

proc activationIdOf(nodeId, branchKey: string): string =
  nodeId & ":" & branchKey

proc appendEvent(ex: LocalExecutor; kind: string; body: JsonNode) =
  var ev = %*{"kind": kind, "body": body}
  ex.events.add(ev)
  try:
    ex.store.appendEvent(ex.runId, %*{
      "message_id": "ev-" & kind & "-" & $ex.events.len,
      "epoch": ex.epoch,
      "kind": kind,
      "body": body
    })
  except CatchableError:
    discard

proc loadValidatedFromStore(ex: LocalExecutor) =
  let rec = ex.store.recover(ex.runId)
  if rec.hasKey("activations") and rec["activations"].kind == JObject:
    for aid, entry in rec["activations"].pairs:
      if entry{"invocation_validated"}.getBool(false):
        let st = entry{"state"}
        var outputs = newJObject()
        if st.kind == JObject and st.hasKey("outputs"):
          outputs = st["outputs"]
        ex.completed[aid] = ActivationRecord(
          activationId: aid,
          nodeId: aid.split(':')[0],
          branchKey: if ':' in aid: aid.split(':')[1] else: "main",
          status: "completed",
          outputs: outputs,
          attemptId: "att-1"
        )
        ex.skippedValidated.add(aid)

proc commitActivation(ex: LocalExecutor; act: ActivationRecord) =
  acquire(ex.commitLock)
  defer: release(ex.commitLock)
  inc ex.transitionSeq
  let tid = "tx-" & $ex.transitionSeq
  var outObj = act.outputs
  if outObj.isNil: outObj = newJObject()
  let transition = %*{
    "transition_id": tid,
    "epoch": ex.epoch,
    "activation_id": act.activationId,
    "attempt_id": act.attemptId,
    "invocation_validated": true,
    "activation_state": {
      "status": "completed",
      "node_id": act.nodeId,
      "branch_key": act.branchKey,
      "outputs": outObj
    },
    "attempt_state": {"status": "completed"},
    "state": {
      "phase": "running",
      "mode": $ex.config.mode,
      "graph_id": ex.graph.graphId,
      "activation_commits": ex.activationCommits + 1,
      "outputs": ex.outputs
    }
  }
  discard ex.store.commitTransition(ex.runId, transition)
  inc ex.activationCommits
  ex.completed[act.activationId] = act
  appendEvent(ex, "activation_committed", %*{
    "activation_id": act.activationId,
    "node_id": act.nodeId,
    "branch_key": act.branchKey
  })

proc requiredPorts(ex: LocalExecutor; node: GraphNode): seq[string] =
  case node.kind
  of ckHandler:
    let d = ex.registry.descriptors.lookupHandler(node.handler)
    for p in d.inputs:
      if p.required: result.add(p.name)
  of ckMap, ckSequence, ckBranch, ckLoop, ckSubgraph, ckAwaitEvent:
    result = @["in"]
  of ckJoin:
    if node.id in ex.inbound:
      for e in ex.inbound[node.id]:
        if e.toPort notin result:
          result.add(e.toPort)
    if result.len == 0:
      result = @["in"]
  of ckReduce:
    result = @["in"]

proc isReady(ex: LocalExecutor; activationId: string; node: GraphNode): bool =
  if activationId notin ex.pending:
    return false
  let inputs = ex.pending[activationId]
  for p in ex.requiredPorts(node):
    if p notin inputs:
      return false
  true

proc ensurePending(ex: LocalExecutor; activationId: string) =
  if activationId notin ex.pending:
    ex.pending[activationId] = initTable[string, JsonNode]()

proc enqueueReady(ex: LocalExecutor; activationId: string) =
  if activationId in ex.completed:
    return
  if activationId in ex.ready:
    return
  ex.ready.add(activationId)

proc deliverTo(ex: LocalExecutor; toNode, toPort, branchKey: string; body: JsonNode) =
  let aid = activationIdOf(toNode, branchKey)
  if aid in ex.completed:
    return
  ensurePending(ex, aid)
  # Pipe backpressure on every delivery attempt
  let msg = PipeMessage(
    messageId: "msg-" & aid & "-" & toPort & "-" & $ex.transitionSeq,
    port: toPort,
    branchKey: branchKey,
    body: body
  )
  let (ok, reason) = ex.pipe.tryEnqueue(msg)
  if not ok:
    appendEvent(ex, "pipe_rejected", %*{"reason": reason, "to": aid, "port": toPort})
    if ex.config.pipePolicy == ppReject:
      raise newFactoryError(fecValidationFailed,
        "pipe full: " & reason, phase = "executor")
    return
  if reason.startsWith("spilled:"):
    appendEvent(ex, "pipe_spilled", %*{"path": reason, "to": aid, "port": toPort})
    # Reload spill into pending (message not lost)
    let path = reason["spilled:".len .. ^1]
    let spilled = loadSpill(path)
    ex.pending[aid][toPort] = spilled.body
  else:
    # Dequeue immediately into pending (pipe accounts for capacity pressure)
    let (got, m) = ex.pipe.dequeue(0)
    if got:
      ex.pending[aid][m.port] = m.body
    else:
      ex.pending[aid][toPort] = body
  let node = ex.nodes[toNode]
  if ex.isReady(aid, node):
    enqueueReady(ex, aid)

proc publishOutputs(ex: LocalExecutor; nodeId, branchKey: string;
                    outputs: Table[string, JsonNode]) =
  if nodeId notin ex.outbound:
    return
  for e in ex.outbound[nodeId]:
    if e.fromPort notin outputs:
      continue
    let body = outputs[e.fromPort]
    # Map fan-out: deliver one copy per target branch (activation key = branch name).
    if e.fromPort == "branch":
      let targetBranch = e.toNode
      var tagged: JsonNode
      if body.kind == JObject:
        tagged = newJObject()
        for k, v in body.pairs:
          tagged[k] = v
        tagged["branch"] = %targetBranch
      else:
        tagged = %*{"branch": targetBranch, "payload": body}
      deliverTo(ex, e.toNode, e.toPort, targetBranch, tagged)
    else:
      # Join/reduce/sequence consumers share one activation (`main`), while the
      # payload retains any branch tag for stable aggregation.
      let destNode = ex.nodes[e.toNode]
      let destKey =
        if destNode.kind in {ckJoin, ckReduce, ckSequence}: "main"
        else: branchKey
      var tagged = body
      if body.kind == JObject and "branch" notin body and branchKey != "main":
        tagged = newJObject()
        for k, v in body.pairs:
          tagged[k] = v
        tagged["branch"] = %branchKey
      deliverTo(ex, e.toNode, e.toPort, destKey, tagged)

proc evalPredicate(p: BranchPredicate; data: JsonNode): bool =
  case p.op
  of poEquals:
    if data.isNil or data.kind != JObject: return false
    let parts = p.path.split('.')
    var cur = data
    for part in parts:
      if cur.kind != JObject or part notin cur: return false
      cur = cur[part]
    return cur == p.value
  of poExists:
    if data.isNil or data.kind != JObject: return false
    return data.hasKey(p.path) or data.hasKey(p.path.split('.')[^1])
  of poAll:
    for c in p.predicates:
      if not evalPredicate(c, data): return false
    return true
  of poAny:
    for c in p.predicates:
      if evalPredicate(c, data): return true
    return false

proc runControlNode(ex: LocalExecutor; node: GraphNode; inputs: PendingInputs;
                    ctx: InvocationContext): Table[string, JsonNode] =
  result = initTable[string, JsonNode]()
  case node.kind
  of ckSequence:
    result["out"] = inputs["in"]
  of ckMap:
    # Emit on branch port; publishOutputs fans out per target
    result["branch"] = inputs["in"]
  of ckBranch:
    let pred = predicateFromJson(node.control{"predicate"})
    let data = inputs["in"]
    if evalPredicate(pred, data):
      result["then"] = data
    else:
      result["else"] = data
  of ckJoin:
    var parts: seq[JsonNode] = @[]
    var keys = toSeq(inputs.keys)
    keys.sort()
    for k in keys:
      parts.add(inputs[k])
    result["out"] = stableAggregate(parts)
  of ckReduce:
    if inputs["in"].kind == JObject and inputs["in"].hasKey("items"):
      var items: seq[JsonNode] = @[]
      for it in inputs["in"]["items"]:
        items.add(it)
      result["out"] = stableAggregate(items)
    else:
      result["out"] = stableAggregate(@[inputs["in"]])
  of ckHandler:
    discard
  of ckLoop, ckSubgraph, ckAwaitEvent:
    raise newFactoryError(fecUnsupportedCapability,
      "control kind not executable in M1: " & $node.kind, phase = "executor")

proc processActivation(ex: LocalExecutor; aid: string): HandlerOutcome =
  result = HandlerOutcome(ok: false, activationId: aid)
  let parts = aid.split({':'}, 1)
  let nodeId = parts[0]
  let branchKey = if parts.len > 1: parts[1] else: "main"
  result.nodeId = nodeId
  result.branchKey = branchKey
  if aid in ex.completed:
    result.ok = true
    return
  if not ex.store.invocationMayBeRequested(ex.runId, aid, "att-1"):
    ex.skippedValidated.add(aid)
    result.ok = true
    return
  let node = ex.nodes[nodeId]
  let inputs = ex.pending[aid]
  var ctx = InvocationContext(
    runId: ex.runId,
    activationId: aid,
    attemptId: "att-1",
    epoch: ex.epoch,
    branchKey: branchKey,
    deadlineMs: ex.absoluteDeadline,
    cancelled: false,
    mode: ex.config.mode
  )
  if ex.status == esCancelled:
    ctx.cancelled = true
  try:
    var outputs: Table[string, JsonNode]
    if node.kind == ckHandler:
      let href = $node.handler
      outputs = invokeHandler(ex.registry, href, inputs, ctx)
    else:
      outputs = runControlNode(ex, node, inputs, ctx)
    result.ok = true
    result.outputs = outputs
  except FactoryError as e:
    result.err = e.msg
    if e.msg.contains("cancelled"):
      result.cancelled = true
    elif e.msg.contains("deadline"):
      result.timedOut = true

proc applyOutcome(ex: LocalExecutor; oc: HandlerOutcome) =
  if not oc.ok:
    if oc.cancelled:
      ex.status = esCancelled
      appendEvent(ex, "cancelled", %*{"activation_id": oc.activationId})
    elif oc.timedOut:
      ex.status = esTimedOut
      appendEvent(ex, "timeout", %*{"activation_id": oc.activationId})
    else:
      ex.status = esFailed
      appendEvent(ex, "activation_failed", %*{
        "activation_id": oc.activationId, "error": oc.err
      })
    return
  if oc.activationId in ex.completed:
    return
  # Serialize outputs to JSON object for persistence
  var outJson = newJObject()
  for k, v in oc.outputs:
    outJson[k] = v
  let act = ActivationRecord(
    activationId: oc.activationId,
    nodeId: oc.nodeId,
    branchKey: oc.branchKey,
    status: "completed",
    outputs: outJson,
    attemptId: "att-1"
  )
  commitActivation(ex, act)
  publishOutputs(ex, oc.nodeId, oc.branchKey, oc.outputs)
  # Collect graph outputs
  for name, portRef in ex.graph.outputs:
    let (n, p) = parsePort(portRef)
    if n == oc.nodeId and p in oc.outputs:
      ex.outputs[name] = oc.outputs[p]
  if ex.config.checkpointAfter > 0 and
      ex.activationCommits >= ex.config.checkpointAfter:
    ex.status = esInterrupted
    appendEvent(ex, "checkpoint", %*{
      "activation_commits": ex.activationCommits
    })

proc stillRunning(ex: LocalExecutor): bool =
  ex.status notin {esInterrupted, esFailed, esCancelled, esTimedOut}

proc runLoop(ex: LocalExecutor) =
  ## Drive until idle or terminal status. Initial status should be esCompleted meaning OK-running;
  ## we reuse esCompleted as success terminal only at end.
  var running = true
  ex.status = esCompleted  # provisional; flipped on failure/interrupt; confirmed at end
  while running and stillRunning(ex):
    if ex.ready.len == 0:
      break
    let limit = if ex.config.mode == emSequential: 1
                else: max(1, ex.config.maxConcurrency)
    var batch: seq[string] = @[]
    while batch.len < limit and ex.ready.len > 0:
      let aid = ex.ready[0]
      ex.ready.delete(0)
      if aid in ex.completed:
        continue
      if not ex.gate.tryEnter():
        ex.ready.insert(aid, 0)
        break
      batch.add(aid)
    if batch.len == 0:
      break
    if ex.config.mode == emConcurrent and batch.len > 1:
      # Run handlers; commits stay serial via applyOutcome on this thread.
      var outcomes: seq[HandlerOutcome] = @[]
      for aid in batch:
        outcomes.add(processActivation(ex, aid))
        ex.gate.leave()
      # Stable apply order by activation id for determinism of commit sequence
      outcomes.sort(proc (a, b: HandlerOutcome): int =
        cmp(a.activationId, b.activationId))
      for oc in outcomes:
        if not stillRunning(ex): break
        applyOutcome(ex, oc)
        if ex.status == esInterrupted:
          running = false
          break
    else:
      for aid in batch:
        let oc = processActivation(ex, aid)
        ex.gate.leave()
        applyOutcome(ex, oc)
        if ex.status == esInterrupted or not stillRunning(ex):
          running = false
          break
        if ex.config.mode == emSequential:
          break
  if ex.status == esCompleted:
    # success path: mark phase completed in store
    inc ex.transitionSeq
    discard ex.store.commitTransition(ex.runId, %*{
      "transition_id": "tx-final-" & $ex.transitionSeq,
      "epoch": ex.epoch,
      "state": {
        "phase": "completed",
        "mode": $ex.config.mode,
        "graph_id": ex.graph.graphId,
        "activation_commits": ex.activationCommits,
        "outputs": ex.outputs
      },
      "activation_id": "run:final",
      "attempt_id": "att-final",
      "activation_state": {"status": "completed"},
      "attempt_state": {"status": "completed"},
      "invocation_validated": true
    })
    appendEvent(ex, "run_completed", %*{"outputs": ex.outputs})

proc seedEntrypoints(ex: LocalExecutor; inputs: JsonNode) =
  for ep in ex.graph.entrypoints:
    let (tn, tp) = parsePort(ep.toPort)
    var body = newJObject()
    if inputs.kind == JObject and ep.inputName in inputs:
      body = inputs[ep.inputName]
    elif inputs.kind == JObject and "start" in inputs:
      body = inputs["start"]
    else:
      body = inputs
    deliverTo(ex, tn, tp, "main", body)

proc newLocalExecutor*(store: SqliteRunStore; registry: ExecutableRegistry;
                       graph: GraphSpec; config: ExecConfig): LocalExecutor =
  result = LocalExecutor(
    store: store,
    registry: registry,
    config: config,
    graph: graph,
    pending: initTable[string, PendingInputs](),
    completed: initTable[string, ActivationRecord](),
    ready: @[],
    pipe: newBoundedPipe(config.pipeCapacity, config.pipePolicy, config.spillDir),
    gate: newConcurrencyGate(
      if config.mode == emSequential: 1 else: max(1, config.maxConcurrency)),
    transitionSeq: 0,
    activationCommits: 0,
    events: @[],
    skippedValidated: @[],
    status: esCompleted,
    outputs: newJObject(),
    resumed: false,
    absoluteDeadline: 0
  )
  initLock(result.commitLock)
  result.buildTopology()

proc validateOrRaise(ex: LocalExecutor) =
  let r = validateGraphSpec(ex.registry.descriptors, ex.graph)
  if r.status != rsOk:
    var msg = r.errorReason
    for d in r.diagnostics:
      msg.add("; " & d.message)
    raise newFactoryError(fecValidationFailed, msg, phase = "executor")

proc toReport(ex: LocalExecutor): ExecReport =
  var acts: seq[ActivationRecord] = @[]
  for _, a in ex.completed:
    acts.add(a)
  acts.sort(proc (a, b: ActivationRecord): int = cmp(a.activationId, b.activationId))
  ExecReport(
    runId: ex.runId,
    status: ex.status,
    mode: ex.config.mode,
    outputs: ex.outputs,
    activations: acts,
    activationCommits: ex.activationCommits,
    pipeStats: ex.pipe.stats,
    events: ex.events,
    error: "",
    resumed: ex.resumed,
    skippedValidated: ex.skippedValidated
  )

proc runGraph*(store: SqliteRunStore; registry: ExecutableRegistry;
               graph: GraphSpec; runId: string; inputs: JsonNode;
               config: ExecConfig): ExecReport =
  var cfg = config
  if cfg.mode == emSequential:
    cfg.maxConcurrency = 1
  let ex = newLocalExecutor(store, registry, graph, cfg)
  ex.runId = runId
  ex.validateOrRaise()
  if cfg.spillDir.len == 0:
    ex.pipe.spillDir = store.dbPath & ".spill"
  else:
    ex.pipe.spillDir = cfg.spillDir
  createDir(ex.pipe.spillDir)
  ex.epoch = store.claimLease(runId, cfg.ownerToken)
  if cfg.deadlineMs > 0:
    ex.absoluteDeadline = nowMs() + cfg.deadlineMs
  discard store.commitTransition(runId, %*{
    "transition_id": "tx-start",
    "epoch": ex.epoch,
    "state": {
      "phase": "running",
      "mode": $cfg.mode,
      "graph_id": graph.graphId,
      "outputs": newJObject()
    },
    "activation_id": "run:start",
    "attempt_id": "att-start",
    "activation_state": {"status": "started"},
    "attempt_state": {"status": "started"},
    "invocation_validated": true
  })
  ex.seedEntrypoints(inputs)
  ex.runLoop()
  ex.toReport()

proc resumeGraph*(store: SqliteRunStore; registry: ExecutableRegistry;
                  graph: GraphSpec; runId: string; config: ExecConfig): ExecReport =
  var cfg = config
  if cfg.mode == emSequential:
    cfg.maxConcurrency = 1
  let ex = newLocalExecutor(store, registry, graph, cfg)
  ex.runId = runId
  ex.resumed = true
  ex.validateOrRaise()
  if cfg.spillDir.len == 0:
    ex.pipe.spillDir = store.dbPath & ".spill"
  ex.epoch = store.claimLease(runId, cfg.ownerToken & "-resume")
  if cfg.deadlineMs > 0:
    ex.absoluteDeadline = nowMs() + cfg.deadlineMs
  ex.loadValidatedFromStore()
  let rec = store.recover(runId)
  if rec.hasKey("state") and rec["state"].kind == JObject:
    if rec["state"].hasKey("outputs"):
      ex.outputs = rec["state"]["outputs"]
  # Rebuild pending work: re-seed from completed outputs for unfinished consumers
  for aid, act in ex.completed:
    if act.outputs.isNil: continue
    var outs = initTable[string, JsonNode]()
    if act.outputs.kind == JObject:
      for k, v in act.outputs.pairs:
        outs[k] = v
    publishOutputs(ex, act.nodeId, act.branchKey, outs)
  # If nothing ready and no outputs yet, re-entry from stored inputs is unavailable;
  # resume expects checkpoint left ready downstream from published outputs.
  if ex.ready.len == 0 and ex.outputs.len > 0 and
      rec{"state"}{"phase"}.getStr("") == "completed":
    ex.status = esCompleted
    return ex.toReport()
  # Reset interrupt semantics: checkpointAfter counts new commits in this process
  let priorCommits = ex.completed.len
  ex.activationCommits = 0
  ex.runLoop()
  # Annotate skipped
  discard priorCommits
  ex.toReport()

proc reportToJson*(r: ExecReport): JsonNode =
  var acts = newJArray()
  for a in r.activations:
    acts.add(%*{
      "activation_id": a.activationId,
      "node_id": a.nodeId,
      "branch_key": a.branchKey,
      "status": a.status,
      "outputs": a.outputs
    })
  var skipped = newJArray()
  for s in r.skippedValidated: skipped.add(%s)
  var evs = newJArray()
  for e in r.events: evs.add(e)
  %*{
    "run_id": r.runId,
    "status": $r.status,
    "mode": $r.mode,
    "outputs": r.outputs,
    "activations": acts,
    "activation_commits": r.activationCommits,
    "pipe_stats": {
      "enqueued": r.pipeStats.enqueued,
      "dequeued": r.pipeStats.dequeued,
      "rejected": r.pipeStats.rejected,
      "spilled": r.pipeStats.spilled,
      "waited": r.pipeStats.waited,
      "peak_depth": r.pipeStats.peakDepth
    },
    "events": evs,
    "resumed": r.resumed,
    "skipped_validated": skipped,
    "concurrency_peak_hint": r.pipeStats.peakDepth
  }
