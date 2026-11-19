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

# Threadpool worker needs a process-wide registry pointer for isolated invokes.
var gThreadRegistry: ExecutableRegistry

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

  DeferredDelivery = object
    toNode: string
    toPort: string
    branchKey: string
    body: JsonNode
    messageId: string

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
    deferred: seq[DeferredDelivery]       ## wait backpressure: retry after consumers
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

proc stableActivationTransitionId*(activationId: string): string =
  ## Stable across process restarts; unique per activation completion.
  "act:" & activationId

proc stableRunTransitionId*(runId, kind: string): string =
  "run:" & runId & ":" & kind

proc snapshotPendingInputs(ex: LocalExecutor; excludeAid = ""): JsonNode =
  ## Durable pending port payloads for activations not yet validated.
  result = newJObject()
  for aid, ports in ex.pending.pairs:
    if aid in ex.completed or aid == excludeAid:
      continue
    var po = newJObject()
    for p, body in ports.pairs:
      po[p] = body
    if po.len > 0:
      result[aid] = po

proc snapshotReadyIds(ex: LocalExecutor; excludeAid = ""): JsonNode =
  result = newJArray()
  for aid in ex.ready:
    if aid in ex.completed or aid == excludeAid:
      continue
    result.add(%aid)

proc snapshotDeferred(ex: LocalExecutor): JsonNode =
  result = newJArray()
  for d in ex.deferred:
    result.add(%*{
      "to_node": d.toNode,
      "to_port": d.toPort,
      "branch_key": d.branchKey,
      "body": d.body,
      "message_id": d.messageId
    })

proc schedulerStateFields(ex: LocalExecutor; excludeAid = ""): JsonNode =
  %*{
    "pending_inputs": snapshotPendingInputs(ex, excludeAid),
    "ready": snapshotReadyIds(ex, excludeAid),
    "deferred": snapshotDeferred(ex)
  }

proc commitActivation(ex: LocalExecutor; act: ActivationRecord; phase = "running"): bool =
  ## Returns true only when the durable commit corresponds to this activation.
  acquire(ex.commitLock)
  defer: release(ex.commitLock)
  let already = act.activationId in ex.completed
  let tid = stableActivationTransitionId(act.activationId)
  var outObj = act.outputs
  if outObj.isNil: outObj = newJObject()
  let sched = schedulerStateFields(ex, act.activationId)
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
      "phase": phase,
      "mode": $ex.config.mode,
      "graph_id": ex.graph.graphId,
      "activation_commits": ex.activationCommits + (if already: 0 else: 1),
      "outputs": ex.outputs,
      "pending_inputs": sched["pending_inputs"],
      "ready": sched["ready"],
      "deferred": sched["deferred"]
    }
  }
  let stored = ex.store.commitTransition(ex.runId, transition)
  let storedAid = stored{"activation_id"}.getStr("")
  let storedTid = stored{"transition_id"}.getStr("")
  if storedAid != act.activationId or storedTid != tid:
    raise newFactoryError(fecValidationFailed,
      "deduped transition does not match requested activation " & act.activationId &
      " (got " & storedAid & " / " & storedTid & ")", phase = "executor")
  result = true
  if not already:
    inc ex.activationCommits
    ex.completed[act.activationId] = act
    appendEvent(ex, "activation_committed", %*{
      "activation_id": act.activationId,
      "node_id": act.nodeId,
      "branch_key": act.branchKey,
      "transition_id": tid
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

proc restoreSchedulerFromState(ex: LocalExecutor; state: JsonNode) =
  ## Reload pending / ready / deferred that were checkpointed with the run.
  if state.isNil or state.kind != JObject:
    return
  if state.hasKey("pending_inputs") and state["pending_inputs"].kind == JObject:
    for aid, ports in state["pending_inputs"].pairs:
      if aid in ex.completed:
        continue
      if ports.kind != JObject:
        continue
      ensurePending(ex, aid)
      for p, body in ports.pairs:
        ex.pending[aid][p] = body
  if state.hasKey("ready") and state["ready"].kind == JArray:
    for n in state["ready"]:
      let aid = n.getStr
      if aid.len > 0:
        enqueueReady(ex, aid)
  if state.hasKey("deferred") and state["deferred"].kind == JArray:
    for n in state["deferred"]:
      if n.kind != JObject:
        continue
      ex.deferred.add(DeferredDelivery(
        toNode: n{"to_node"}.getStr,
        toPort: n{"to_port"}.getStr,
        branchKey: n{"branch_key"}.getStr("main"),
        body: n{"body"},
        messageId: n{"message_id"}.getStr
      ))

proc requeueReadyFromPending(ex: LocalExecutor) =
  for aid, _ in ex.pending.pairs:
    if aid in ex.completed:
      continue
    let parts = aid.split({':'}, 1)
    let nodeId = parts[0]
    if nodeId notin ex.nodes:
      continue
    if ex.isReady(aid, ex.nodes[nodeId]):
      enqueueReady(ex, aid)

proc graphOutputsIncomplete(ex: LocalExecutor): bool =
  for name, _ in ex.graph.outputs.pairs:
    if name notin ex.outputs:
      return true
  false

proc missingDurablePendingDiagnostic(ex: LocalExecutor; state: JsonNode): string =
  var missing: seq[string] = @[]
  for ep in ex.graph.entrypoints:
    let (tn, tp) = parsePort(ep.toPort)
    let aid = activationIdOf(tn, "main")
    if aid in ex.completed:
      continue
    let hasPort = aid in ex.pending and tp in ex.pending[aid]
    if not hasPort:
      missing.add(ep.inputName & "->" & tn & "." & tp & " (" & aid & ")")
  let hadSnap = not state.isNil and state.kind == JObject and
                state.hasKey("pending_inputs")
  if missing.len == 0 and not graphOutputsIncomplete(ex):
    return ""
  if not hadSnap:
    return "irrecoverable pending inputs after resume (pre-pending_inputs checkpoint); missing: " &
           missing.join(", ")
  if missing.len > 0:
    return "missing durable pending inputs after resume: " & missing.join(", ")
  if graphOutputsIncomplete(ex) and ex.ready.len == 0 and ex.deferred.len == 0:
    return "resume has incomplete graph outputs and no ready work (pending snapshot exhausted)"
  ""

proc acceptDelivery(ex: LocalExecutor; toNode, toPort, branchKey: string;
                    body: JsonNode; messageId: string): bool =
  ## Attempt one pipe delivery. Returns false when ``wait`` must yield to consumers.
  let aid = activationIdOf(toNode, branchKey)
  if aid in ex.completed:
    return true
  ensurePending(ex, aid)
  let msg = PipeMessage(
    messageId: messageId,
    port: toPort,
    branchKey: branchKey,
    body: body
  )
  let (ok, reason) = ex.pipe.tryEnqueue(msg)
  if not ok:
    if reason == "would_wait":
      appendEvent(ex, "pipe_wait", %*{
        "to": aid, "port": toPort, "depth": ex.pipe.depth(),
        "capacity": ex.pipe.capacity
      })
      return false
    appendEvent(ex, "pipe_rejected", %*{"reason": reason, "to": aid, "port": toPort})
    if ex.config.pipePolicy == ppReject:
      raise newFactoryError(fecValidationFailed,
        "pipe full: " & reason, phase = "executor")
    return true
  if reason.startsWith("spilled:"):
    appendEvent(ex, "pipe_spilled", %*{"path": reason, "to": aid, "port": toPort})
    let path = reason["spilled:".len .. ^1]
    let spilled = loadSpill(path)
    ex.pending[aid][toPort] = spilled.body
    # Spill path holds no in-memory slot.
  else:
    # Mirror into pending. Hold the pipe slot only when the destination becomes
    # ready (consumer can run and will release on start). Incomplete multi-input
    # gathers free the slot immediately so sibling ports are not deadlocked.
    ex.pending[aid][toPort] = body
  let node = ex.nodes[toNode]
  if ex.isReady(aid, node):
    enqueueReady(ex, aid)
    # Slot remains occupied until processActivation / worker start.
  elif not reason.startsWith("spilled:"):
    discard ex.pipe.dequeue(0)
  true

proc deliverTo(ex: LocalExecutor; toNode, toPort, branchKey: string; body: JsonNode) =
  let aid = activationIdOf(toNode, branchKey)
  if aid in ex.completed:
    return
  inc ex.transitionSeq
  let mid = "msg-" & aid & "-" & toPort & "-" & $ex.transitionSeq
  if not acceptDelivery(ex, toNode, toPort, branchKey, body, mid):
    # Yield: keep the delivery for after consumers free capacity.
    ex.deferred.add(DeferredDelivery(
      toNode: toNode, toPort: toPort, branchKey: branchKey,
      body: body, messageId: mid
    ))

proc flushDeferred(ex: LocalExecutor): bool =
  ## Retry wait-deferred deliveries. Returns true if at least one progressed.
  result = false
  if ex.deferred.len == 0:
    return
  var remaining: seq[DeferredDelivery] = @[]
  for d in ex.deferred:
    if acceptDelivery(ex, d.toNode, d.toPort, d.branchKey, d.body, d.messageId):
      result = true
    else:
      remaining.add(d)
  ex.deferred = remaining

proc releasePipeSlots(ex: LocalExecutor; n: int) =
  ## Free in-memory pipe capacity after mirrored inputs are taken by a handler.
  for i in 1 .. n:
    discard ex.pipe.dequeue(0)
  discard flushDeferred(ex)

proc observeNoPipeProgress(ex: LocalExecutor) =
  ## Deferred wait deliveries with nothing ready → deadline or explicit block.
  if ex.deferred.len == 0:
    return
  if ex.absoluteDeadline > 0 and nowMs() > ex.absoluteDeadline:
    ex.status = esTimedOut
    appendEvent(ex, "timeout", %*{
      "reason": "pipe_wait_no_progress",
      "deferred": ex.deferred.len,
      "pipe_depth": ex.pipe.depth()
    })
  else:
    ex.status = esFailed
    appendEvent(ex, "pipe_blocked", %*{
      "reason": "no_consumer_progress",
      "deferred": ex.deferred.len,
      "pipe_depth": ex.pipe.depth(),
      "ready": ex.ready.len
    })
    raise newFactoryError(fecValidationFailed,
      "pipe wait blocked with no consumer progress (deferred=" &
      $ex.deferred.len & ")", phase = "executor")

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
  # Inputs were mirrored while messages stayed in the pipe; free those slots.
  releasePipeSlots(ex, inputs.len)
  var ctx = InvocationContext(
    runId: ex.runId,
    activationId: aid,
    attemptId: "att-1",
    epoch: ex.epoch,
    branchKey: branchKey,
    deadlineMs: ex.absoluteDeadline,
    cancelled: ex.config.cancelRequested or ex.status == esCancelled,
    mode: ex.config.mode
  )
  if ctx.cancelled:
    ex.status = esCancelled
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

proc collectGraphOutputs(ex: LocalExecutor; nodeId: string;
                         outputs: Table[string, JsonNode]) =
  for name, portRef in ex.graph.outputs:
    let (n, p) = parsePort(portRef)
    if n == nodeId and p in outputs:
      ex.outputs[name] = outputs[p]

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
  var outJson = newJObject()
  for k, v in oc.outputs:
    outJson[k] = v
  # Graph outputs must be durable at this commit boundary (incl. last activation).
  collectGraphOutputs(ex, oc.nodeId, oc.outputs)
  # Fan-out into pending/ready before the durable commit so a checkpoint
  # snapshot retains sibling entrypoints and downstream gathers.
  publishOutputs(ex, oc.nodeId, oc.branchKey, oc.outputs)
  let act = ActivationRecord(
    activationId: oc.activationId,
    nodeId: oc.nodeId,
    branchKey: oc.branchKey,
    status: "completed",
    outputs: outJson,
    attemptId: "att-1"
  )
  let phase =
    if ex.config.checkpointAfter > 0 and
        ex.activationCommits + 1 >= ex.config.checkpointAfter:
      "interrupted"
    else:
      "running"
  if not commitActivation(ex, act, phase):
    raise newFactoryError(fecValidationFailed,
      "activation commit rejected: " & act.activationId, phase = "executor")
  if ex.config.checkpointAfter > 0 and
      ex.activationCommits >= ex.config.checkpointAfter:
    ex.status = esInterrupted
    appendEvent(ex, "checkpoint", %*{
      "activation_commits": ex.activationCommits,
      "outputs": ex.outputs,
      "pending_inputs": snapshotPendingInputs(ex),
      "ready": snapshotReadyIds(ex)
    })

proc stillRunning(ex: LocalExecutor): bool =
  ex.status notin {esInterrupted, esFailed, esCancelled, esTimedOut}

type
  IsolatedJob = object
    aid: string
    nodeId: string
    branchKey: string
    href: string
    inputsJson: string
    runId: string
    epoch: int
    deadlineMs: int64
    cancelled: bool
    mode: ExecMode
    isHandler: bool
    controlKind: string
    controlJson: string

  IsolatedPack = object
    job: IsolatedJob
    outcome: HandlerOutcome

proc invokeIsolated(job: IsolatedJob): HandlerOutcome =
  ## Runs in a worker thread; only touches copied data + global registry.
  result = HandlerOutcome(ok: false, activationId: job.aid,
    nodeId: job.nodeId, branchKey: job.branchKey)
  var ctx = InvocationContext(
    runId: job.runId,
    activationId: job.aid,
    attemptId: "att-1",
    epoch: job.epoch,
    branchKey: job.branchKey,
    deadlineMs: job.deadlineMs,
    cancelled: job.cancelled,
    mode: job.mode
  )
  try:
    var inputs = initTable[string, JsonNode]()
    let root = parseJson(job.inputsJson)
    if root.kind == JObject:
      for k, v in root.pairs:
        inputs[k] = v
    if job.isHandler:
      var outs: Table[string, JsonNode]
      {.cast(gcsafe).}:
        outs = invokeHandler(gThreadRegistry, job.href, inputs, ctx)
      result.ok = true
      result.outputs = outs
    else:
      result.err = "control_on_worker"
  except FactoryError as e:
    result.err = e.msg
    if e.msg.contains("cancelled"): result.cancelled = true
    elif e.msg.contains("deadline"): result.timedOut = true
  except CatchableError as e:
    result.err = e.msg

proc runLoop(ex: LocalExecutor) =
  var running = true
  ex.status = esCompleted
  gThreadRegistry = ex.registry
  while running and stillRunning(ex):
    discard flushDeferred(ex)
    if ex.ready.len == 0:
      if ex.deferred.len > 0:
        observeNoPipeProgress(ex)
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
      if ex.deferred.len > 0:
        observeNoPipeProgress(ex)
      break
    if ex.config.mode == emConcurrent and batch.len > 1:
      var jobs: seq[IsolatedJob] = @[]
      var controlAids: seq[string] = @[]
      for aid in batch:
        let parts = aid.split({':'}, 1)
        let nodeId = parts[0]
        let branchKey = if parts.len > 1: parts[1] else: "main"
        let node = ex.nodes[nodeId]
        if node.kind == ckHandler:
          var inObj = newJObject()
          for k, v in ex.pending[aid]:
            inObj[k] = v
          releasePipeSlots(ex, inObj.len)
          let cancelNow = ex.config.cancelRequested or ex.status == esCancelled
          if cancelNow:
            ex.status = esCancelled
          jobs.add(IsolatedJob(
            aid: aid, nodeId: nodeId, branchKey: branchKey,
            href: $node.handler, inputsJson: $inObj,
            runId: ex.runId, epoch: ex.epoch,
            deadlineMs: ex.absoluteDeadline,
            cancelled: cancelNow,
            mode: ex.config.mode, isHandler: true
          ))
        else:
          controlAids.add(aid)
      # Real OS threads for independent handlers (measure overlap via atomics).
      var packs = newSeq[IsolatedPack](jobs.len)
      var threads = newSeq[Thread[ptr IsolatedPack]](jobs.len)
      proc thr(p: ptr IsolatedPack) {.thread.} =
        p.outcome = invokeIsolated(p.job)
      for i in 0 ..< jobs.len:
        packs[i].job = jobs[i]
        createThread(threads[i], thr, addr packs[i])
      for i in 0 ..< jobs.len:
        joinThread(threads[i])
        ex.gate.leave()
      var outcomes: seq[HandlerOutcome] = @[]
      for i in 0 ..< packs.len:
        outcomes.add(packs[i].outcome)
      for aid in controlAids:
        outcomes.add(processActivation(ex, aid))
        ex.gate.leave()
      outcomes.sort(proc (a, b: HandlerOutcome): int =
        cmp(a.activationId, b.activationId))
      for oc in outcomes:
        if not stillRunning(ex): break
        applyOutcome(ex, oc)
        discard flushDeferred(ex)
        if ex.status == esInterrupted:
          running = false
          break
    else:
      for aid in batch:
        let oc = processActivation(ex, aid)
        ex.gate.leave()
        applyOutcome(ex, oc)
        discard flushDeferred(ex)
        if ex.status == esInterrupted or not stillRunning(ex):
          running = false
          break
        if ex.config.mode == emSequential:
          break
  discard flushDeferred(ex)
  if stillRunning(ex) and ex.deferred.len > 0 and ex.ready.len == 0:
    observeNoPipeProgress(ex)
  if ex.status == esCompleted and graphOutputsIncomplete(ex):
    # Do not seal a partial run as completed (e.g. lost pending after resume).
    let msg = "cannot finalize run with incomplete graph outputs (ready=" &
              $ex.ready.len & ", deferred=" & $ex.deferred.len & ")"
    ex.status = esFailed
    appendEvent(ex, "incomplete_outputs", %*{
      "outputs": ex.outputs, "ready": snapshotReadyIds(ex),
      "pending_inputs": snapshotPendingInputs(ex)
    })
    raise newFactoryError(fecMissingRequiredInput, msg, phase = "executor")
  if ex.status == esCompleted:
    let tid = stableRunTransitionId(ex.runId, "final")
    let sched = schedulerStateFields(ex)
    let stored = ex.store.commitTransition(ex.runId, %*{
      "transition_id": tid,
      "epoch": ex.epoch,
      "state": {
        "phase": "completed",
        "mode": $ex.config.mode,
        "graph_id": ex.graph.graphId,
        "activation_commits": ex.activationCommits,
        "outputs": ex.outputs,
        "pending_inputs": sched["pending_inputs"],
        "ready": sched["ready"],
        "deferred": sched["deferred"]
      },
      "activation_id": "run:final",
      "attempt_id": "att-final",
      "activation_state": {"status": "completed", "outputs": ex.outputs},
      "attempt_state": {"status": "completed"},
      "invocation_validated": true
    })
    if stored{"transition_id"}.getStr != tid or
        stored{"activation_id"}.getStr != "run:final":
      raise newFactoryError(fecValidationFailed,
        "final transition dedup mismatch", phase = "executor")
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
    deferred: @[],
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
    if a.activationId.startsWith("run:"): continue
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
    peakConcurrentInvocations: peakConcurrentInvocations(),
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
  resetInvocationMetrics()
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
  let startTid = stableRunTransitionId(runId, "start")
  let started = store.commitTransition(runId, %*{
    "transition_id": startTid,
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
  if started{"transition_id"}.getStr != startTid:
    raise newFactoryError(fecValidationFailed,
      "start transition dedup mismatch", phase = "executor")
  ex.seedEntrypoints(inputs)
  ex.runLoop()
  ex.toReport()

proc resumeGraph*(store: SqliteRunStore; registry: ExecutableRegistry;
                  graph: GraphSpec; runId: string; config: ExecConfig): ExecReport =
  if not store.hasRun(runId):
    raise newFactoryError(fecMissingRequiredInput,
      "unknown run_id (refuse resume without creating state): " & runId,
      phase = "executor")
  var cfg = config
  if cfg.mode == emSequential:
    cfg.maxConcurrency = 1
  resetInvocationMetrics()
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
  # Count prior durable activation commits (exclude run:start / run:final)
  ex.activationCommits = 0
  for aid, _ in ex.completed:
    if not aid.startsWith("run:"):
      inc ex.activationCommits
  let rec = store.recover(runId)
  let state =
    if rec.hasKey("state") and rec["state"].kind == JObject: rec["state"]
    else: newJObject()
  if state.hasKey("outputs") and state["outputs"].kind == JObject:
    ex.outputs = state["outputs"]
  let phase = state{"phase"}.getStr("")
  if phase == "completed":
    # Second resume of a finished run: return durable outputs, no handler re-invoke.
    ex.status = esCompleted
    return ex.toReport()
  # Restore entrypoints / gathers that were still due at the last commit.
  restoreSchedulerFromState(ex, state)
  for aid, act in ex.completed:
    if act.outputs.isNil: continue
    if aid.startsWith("run:"): continue
    var outs = initTable[string, JsonNode]()
    if act.outputs.kind == JObject:
      for k, v in act.outputs.pairs:
        outs[k] = v
    publishOutputs(ex, act.nodeId, act.branchKey, outs)
  requeueReadyFromPending(ex)
  let diag = missingDurablePendingDiagnostic(ex, state)
  if diag.len > 0 and ex.ready.len == 0 and ex.deferred.len == 0 and
      graphOutputsIncomplete(ex):
    raise newFactoryError(fecMissingRequiredInput, diag, phase = "executor")
  ex.runLoop()
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
    "peak_concurrent_invocations": r.peakConcurrentInvocations,
    "events": evs,
    "resumed": r.resumed,
    "skipped_validated": skipped
  }
