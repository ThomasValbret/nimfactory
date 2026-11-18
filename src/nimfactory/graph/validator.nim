## GraphValidator implementation (F4).

import std/[tables, sets, json, strutils]
import ../contracts/[errors, ports, result, ids]
import ./[types, codec, registry]

type
  PortRef = tuple[nodeId, portName: string]

  ResolvedPort = object
    schema: string
    required: bool
    isOutput: bool

  NimGraphValidator* = ref object of GraphValidator
    registry*: SimulatedHandlerRegistry

proc newNimGraphValidator*(registry: SimulatedHandlerRegistry): NimGraphValidator =
  NimGraphValidator(registry: registry)

proc parsePortRef(s: string): PortRef =
  let dot = s.rfind('.')
  if dot <= 0 or dot >= s.high:
    raise newFactoryError(fecValidationFailed,
      "invalid port ref: " & s, phase = "graph")
  (s[0..<dot], s[dot + 1 .. ^1])

proc failResult(code: FactoryErrorCode; msg, phase: string;
                  refs: seq[string] = @[]): CommonResult =
  var r = defaultResult(rsFailed)
  r.errorCode = $code
  r.errorPhase = phase
  r.errorReason = msg
  r.diagnostics.add(diagnostic($code, phase, msg, refs = refs))
  r

proc okGraphResult(g: GraphSpec): CommonResult =
  var r = defaultResult(rsOk)
  r.outputs = %*{
    "graph_id": g.graphId,
    "version": g.version,
    "node_count": g.nodes.len,
    "edge_count": g.edges.len
  }
  r

proc validatePredicate(p: BranchPredicate; diags: var seq[Diagnostic]) =
  if p.op in {poAll, poAny}:
    if p.predicates.len == 0:
      diags.add(diagnostic("missing_predicates", "graph",
        "all/any predicates require children"))
    for child in p.predicates:
      validatePredicate(child, diags)
  elif p.op in {poEquals, poExists} and p.path.len == 0:
    diags.add(diagnostic("missing_path", "graph",
      "equals/exists predicate requires path"))

proc buildNodeIndex(g: GraphSpec): Table[string, GraphNode] =
  result = initTable[string, GraphNode]()
  for n in g.nodes:
    if n.id in result:
      raise newFactoryError(fecDuplicateKey, "duplicate node id: " & n.id,
        phase = "graph")
    result[n.id] = n
  if result.len == 0:
    raise newFactoryError(fecMissingRequiredInput, "graph needs nodes",
      phase = "graph")

proc lookupPort(registry: SimulatedHandlerRegistry; node: GraphNode;
                portName: string; isOutput: var bool): ResolvedPort =
  if node.kind == ckHandler:
    if ($node.handler).len == 0:
      raise newFactoryError(fecValidationFailed,
        "handler node missing handler ref", phase = "graph")
    let desc = registry.lookupHandler(node.handler)
    for p in desc.inputs:
      if p.name == portName:
        isOutput = false
        return ResolvedPort(schema: p.schema, required: p.required,
          isOutput: false)
    for p in desc.outputs:
      if p.name == portName:
        isOutput = true
        return ResolvedPort(schema: p.schema, required: p.required,
          isOutput: true)
    raise newFactoryError(fecValidationFailed,
      "unknown port " & portName & " on handler " & $node.handler,
      phase = "graph")
  else:
    if node.kind == ckJoin and (portName == "in" or portName.startsWith("in_")):
      isOutput = false
      return ResolvedPort(schema: "nimfactory.control_pass/0.1",
        required: false, isOutput: false)
    for p in controlInputPorts(node.kind):
      if p.name == portName:
        isOutput = false
        return ResolvedPort(schema: p.schema, required: p.required,
          isOutput: false)
    for p in controlOutputPorts(node.kind):
      if p.name == portName:
        isOutput = true
        return ResolvedPort(schema: p.schema, required: p.required,
          isOutput: true)
    if node.kind == ckMap and portName.startsWith("branch_"):
      isOutput = true
      return ResolvedPort(schema: "nimfactory.control_pass/0.1",
        required: false, isOutput: true)
    raise newFactoryError(fecValidationFailed,
      "unknown port " & portName & " on control node " & $node.kind,
      phase = "graph")

proc validateControlNode(node: GraphNode; diags: var seq[Diagnostic]) =
  case node.kind
  of ckBranch:
    if not node.control.hasKey("predicate"):
      diags.add(diagnostic("missing_predicate", "graph",
        "branch node requires control.predicate", refs = @[node.id]))
    else:
      try:
        let p = predicateFromJson(node.control["predicate"])
        validatePredicate(p, diags)
      except FactoryError as e:
        diags.add(diagnostic($e.code, "graph", e.msg, refs = @[node.id]))
    if node.control.hasKey("eval"):
      diags.add(diagnostic("forbidden_eval", "graph",
        "branch eval strings forbidden", refs = @[node.id]))
  of ckJoin:
    let jc = joinControlFromJson(node.control)
    if jc.policy == jpQuorum and jc.quorum < 1:
      diags.add(diagnostic("invalid_quorum", "graph",
        "join quorum must be >= 1", refs = @[node.id]))
    if jc.policy == jpFirstSuccess and jc.onFailure == jfpCompletePartial:
      diags.add(diagnostic("impossible_join", "graph",
        "first_success join cannot complete_partial on failure",
        refs = @[node.id]))
  of ckMap:
    if not node.control.hasKey("branches") or node.control["branches"].kind != JArray:
      diags.add(diagnostic("missing_branches", "graph",
        "map node requires control.branches", refs = @[node.id]))
    elif node.control["branches"].len == 0:
      diags.add(diagnostic("empty_branches", "graph",
        "map requires at least one branch", refs = @[node.id]))
  of ckReduce:
    if node.control{"function"}.getStr("").len == 0:
      diags.add(diagnostic("missing_reduce_fn", "graph",
        "reduce node requires control.function", refs = @[node.id]))
  of ckSubgraph:
    if node.control{"graph_id"}.getStr("").len == 0:
      diags.add(diagnostic("missing_subgraph", "graph",
        "subgraph node requires control.graph_id", refs = @[node.id]))
  of ckAwaitEvent:
    if node.control{"event_type"}.getStr("").len == 0:
      diags.add(diagnostic("missing_event", "graph",
        "await_event requires control.event_type", refs = @[node.id]))
  of ckLoop:
    discard
  else:
    discard

proc countJoinInputs(g: GraphSpec; nodeId: string): int =
  for e in g.edges:
    let (toNode, toPort) = parsePortRef(e.toPort)
    if toNode == nodeId and (toPort == "in" or toPort.startsWith("in_")):
      inc result

proc validateJoinFeasibility(g: GraphSpec; nodes: Table[string, GraphNode];
                               diags: var seq[Diagnostic]) =
  for n in g.nodes:
    if n.kind != ckJoin:
      continue
    let jc = joinControlFromJson(n.control)
    let wired = countJoinInputs(g, n.id)
    case jc.policy
    of jpAllRequired:
      if wired == 0:
        diags.add(diagnostic("impossible_join", "graph",
          "join all_required needs at least one input edge", refs = @[n.id]))
    of jpQuorum:
      if jc.quorum > wired:
        diags.add(diagnostic("impossible_join", "graph",
          "join quorum " & $jc.quorum & " exceeds wired inputs " & $wired,
          refs = @[n.id]))
    of jpFirstSuccess:
      if wired < 1:
        diags.add(diagnostic("impossible_join", "graph",
          "join first_success needs at least one input", refs = @[n.id]))

proc validateLoopSpecs(g: GraphSpec; nodes: Table[string, GraphNode];
                         diags: var seq[Diagnostic]) =
  var loopNodes = initHashSet[string]()
  for n in g.nodes:
    if n.kind == ckLoop:
      loopNodes.incl(n.id)
  var specsByNode = initTable[string, LoopSpec]()
  for ls in g.loopSpecs:
    if ls.loopNodeId in specsByNode:
      diags.add(diagnostic("duplicate_loop_spec", "graph",
        "duplicate loop_spec for " & ls.loopNodeId,
        refs = @[ls.loopNodeId]))
    specsByNode[ls.loopNodeId] = ls
    if ls.loopNodeId notin nodes:
      diags.add(diagnostic("unknown_loop_node", "graph",
        "loop_spec references missing node", refs = @[ls.loopNodeId]))
    elif nodes[ls.loopNodeId].kind != ckLoop:
      diags.add(diagnostic("loop_kind_mismatch", "graph",
        "loop_spec target is not a loop node", refs = @[ls.loopNodeId]))
    if ls.exit.maxIterations <= 0:
      diags.add(diagnostic("missing_loop_limit", "graph",
        "loop must declare max_iterations > 0", refs = @[ls.loopNodeId]))
    if ls.exit.onLimit.len == 0:
      diags.add(diagnostic("missing_on_limit", "graph",
        "loop must declare on_limit explicit state", refs = @[ls.loopNodeId]))
    validatePredicate(ls.exit.predicate, diags)
  for id in loopNodes:
    if id notin specsByNode:
      diags.add(diagnostic("missing_loop_spec", "graph",
        "loop node requires loop_specs entry", refs = @[id]))

proc buildAdjacency(g: GraphSpec): Table[string, HashSet[string]] =
  result = initTable[string, HashSet[string]]()
  for e in g.edges:
    let (fromNode, _) = parsePortRef(e.fromPort)
    let (toNode, _) = parsePortRef(e.toPort)
    if fromNode notin result:
      result[fromNode] = initHashSet[string]()
    result[fromNode].incl(toNode)

proc selfLoopNodes(g: GraphSpec): HashSet[string] =
  result = initHashSet[string]()
  for e in g.edges:
    let (fromNode, _) = parsePortRef(e.fromPort)
    let (toNode, _) = parsePortRef(e.toPort)
    if fromNode == toNode:
      result.incl(fromNode)

type TarjanState = object
  index: Table[string, int]
  lowlink: Table[string, int]
  stack: seq[string]
  onStack: HashSet[string]
  indexCounter: int
  sccs: seq[HashSet[string]]

proc tarjanVisit(u: string; adj: Table[string, HashSet[string]];
                 st: var TarjanState) =
  st.index[u] = st.indexCounter
  st.lowlink[u] = st.indexCounter
  inc st.indexCounter
  st.stack.add(u)
  st.onStack.incl(u)
  if u in adj:
    for v in adj[u]:
      if v notin st.index:
        tarjanVisit(v, adj, st)
        st.lowlink[u] = min(st.lowlink[u], st.lowlink[v])
      elif v in st.onStack:
        st.lowlink[u] = min(st.lowlink[u], st.index[v])
  if st.lowlink[u] == st.index[u]:
    var scc = initHashSet[string]()
    while st.stack.len > 0:
      let w = st.stack.pop()
      st.onStack.excl(w)
      scc.incl(w)
      if w == u:
        break
    st.sccs.add(scc)

proc strongComponents(adj: Table[string, HashSet[string]];
                        nodeIds: HashSet[string]): seq[HashSet[string]] =
  var st = TarjanState(
    index: initTable[string, int](),
    lowlink: initTable[string, int](),
    stack: @[],
    onStack: initHashSet[string](),
    indexCounter: 0,
    sccs: @[]
  )
  for id in nodeIds:
    if id notin st.index:
      tarjanVisit(id, adj, st)
  st.sccs

proc loopNodesWithSpec(g: GraphSpec;
                       nodes: Table[string, GraphNode]): HashSet[string] =
  result = initHashSet[string]()
  var specIds = initHashSet[string]()
  for ls in g.loopSpecs:
    if ls.loopNodeId.len == 0 or ls.exit.maxIterations <= 0:
      continue
    if ls.loopNodeId in nodes and nodes[ls.loopNodeId].kind == ckLoop:
      specIds.incl(ls.loopNodeId)
  for id in specIds:
    result.incl(id)

proc sccHasCycle(comp: HashSet[string];
                 selfLoops: HashSet[string]): bool =
  if comp.len > 1:
    return true
  if comp.len == 1:
    for id in comp:
      return id in selfLoops
  false

proc loopCoversScc(comp: HashSet[string];
                   declaredLoops: HashSet[string]): bool =
  for id in comp:
    if id in declaredLoops:
      return true
  false

proc residualCycleWithoutLoopControllers(comp: HashSet[string];
    declaredLoops: HashSet[string]; adj: Table[string, HashSet[string]];
    selfLoops: HashSet[string]): bool =
  ## After removing declared loop controllers, any remaining cycle is uncontrolled.
  var residual = initHashSet[string]()
  for id in comp:
    if id notin declaredLoops:
      residual.incl(id)
  if residual.len == 0:
    return false
  for id in residual:
    if id in selfLoops:
      return true
  var subAdj = initTable[string, HashSet[string]]()
  for id in residual:
    subAdj[id] = initHashSet[string]()
    if id in adj:
      for nxt in adj[id]:
        if nxt in residual:
          subAdj[id].incl(nxt)
  for scc in strongComponents(subAdj, residual):
    if sccHasCycle(scc, selfLoops):
      return true
  false

proc validateUndeclaredCycles(g: GraphSpec; nodes: Table[string, GraphNode];
                                diags: var seq[Diagnostic]) =
  let adj = buildAdjacency(g)
  var nodeIds = initHashSet[string]()
  for n in g.nodes:
    nodeIds.incl(n.id)
  let selfLoops = selfLoopNodes(g)
  let declaredLoops = loopNodesWithSpec(g, nodes)
  for comp in strongComponents(adj, nodeIds):
    if not sccHasCycle(comp, selfLoops):
      continue
    if not loopCoversScc(comp, declaredLoops) or
       residualCycleWithoutLoopControllers(comp, declaredLoops, adj, selfLoops):
      var refs: seq[string] = @[]
      for id in comp:
        refs.add(id)
      diags.add(diagnostic($fecDependencyCycle, "graph",
        "undeclared cyclic wiring; each cycle must traverse a declared " &
        "bounded loop controller",
        refs = refs))

proc collectFedPorts(g: GraphSpec): Table[string, HashSet[string]] =
  var fed = initTable[string, HashSet[string]]()
  for ep in g.entrypoints:
    let (nodeId, portName) = parsePortRef(ep.toPort)
    if nodeId notin fed:
      fed[nodeId] = initHashSet[string]()
    fed[nodeId].incl(portName)
  for e in g.edges:
    let (toNode, toPort) = parsePortRef(e.toPort)
    if toNode notin fed:
      fed[toNode] = initHashSet[string]()
    fed[toNode].incl(toPort)
  fed

proc allowsMultiProducer(node: GraphNode; portName: string): bool =
  node.kind == ckLoop and portName == "in"

proc validatePortProducers(g: GraphSpec; nodes: Table[string, GraphNode];
                             diags: var seq[Diagnostic]) =
  type PortKey = tuple[nodeId, portName: string]
  var counts = initTable[PortKey, int]()
  var refs = initTable[PortKey, seq[string]]()
  proc note(nodeId, portName, refPort: string) =
    let key = (nodeId, portName)
    if key notin counts:
      counts[key] = 0
      refs[key] = @[]
    inc counts[key]
    refs[key].add(refPort)
  for ep in g.entrypoints:
    let (nodeId, portName) = parsePortRef(ep.toPort)
    let src = if ep.inputName.len > 0: "entry:" & ep.inputName
              else: "entrypoint"
    note(nodeId, portName, src)
  for e in g.edges:
    let (toNode, toPort) = parsePortRef(e.toPort)
    note(toNode, toPort, e.fromPort)
  for key, n in counts.pairs:
    if n <= 1:
      continue
    if key.nodeId notin nodes:
      continue
    let node = nodes[key.nodeId]
    if allowsMultiProducer(node, key.portName):
      continue
    diags.add(diagnostic("ambiguous_multi_producer", "graph",
      "port " & key.nodeId & "." & key.portName &
      " has " & $n & " structural producers; at most one is supported",
      refs = refs[key]))

proc requiredInputPorts(registry: SimulatedHandlerRegistry;
                        node: GraphNode): seq[PortDecl] =
  if node.kind == ckHandler:
    if ($node.handler).len == 0:
      return @[]
    let desc = registry.lookupHandler(node.handler)
    for p in desc.inputs:
      if p.required:
        result.add(p)
  else:
    for p in controlInputPorts(node.kind):
      if p.required:
        result.add(p)

proc validateRequiredPortsFed(registry: SimulatedHandlerRegistry;
                                g: GraphSpec;
                                nodes: Table[string, GraphNode];
                                diags: var seq[Diagnostic]) =
  let fed = collectFedPorts(g)
  for n in g.nodes:
    try:
      for p in requiredInputPorts(registry, n):
        let wired = n.id in fed and p.name in fed[n.id]
        if not wired:
          diags.add(diagnostic($fecMissingRequiredInput, "graph",
            "required input port not fed: " & n.id & "." & p.name,
            refs = @[n.id, n.id & "." & p.name]))
    except FactoryError as e:
      diags.add(diagnostic($e.code, "graph", e.msg, refs = @[n.id]))

proc validateGraphSpec*(registry: SimulatedHandlerRegistry;
                        g: GraphSpec): CommonResult =
  var diags: seq[Diagnostic] = @[]
  if g.schema != GraphSchema:
    return failResult(fecSchemaMismatch,
      "expected schema " & GraphSchema & " got " & g.schema, "graph")
  let nodes = buildNodeIndex(g)

  for n in g.nodes:
    if n.kind == ckHandler:
      if ($n.handler).len == 0:
        diags.add(diagnostic("missing_handler", "graph",
          "handler node requires handler ref", refs = @[n.id]))
      elif not registry.hasHandler(n.handler):
        diags.add(diagnostic($fecValidationFailed, "graph",
          "unknown handler: " & $n.handler, refs = @[n.id]))
    else:
      validateControlNode(n, diags)

  for ep in g.entrypoints:
    let (nodeId, portName) = parsePortRef(ep.toPort)
    if nodeId notin nodes:
      diags.add(diagnostic("unknown_entrypoint", "graph",
        "entrypoint targets missing node", refs = @[ep.toPort]))
      continue
    try:
      var isOut: bool
      let rp = lookupPort(registry, nodes[nodeId], portName, isOut)
      if isOut:
        diags.add(diagnostic("entrypoint_output", "graph",
          "entrypoint must target input port", refs = @[ep.toPort]))
      if rp.required == false and ep.inputName.len == 0:
        diags.add(diagnostic("optional_entry", "graph",
          "optional entrypoints need input name", refs = @[ep.toPort]))
    except FactoryError as e:
      diags.add(diagnostic($e.code, "graph", e.msg, refs = @[ep.toPort]))

  for k, v in g.outputs.pairs:
    let (nodeId, portName) = parsePortRef(v)
    if nodeId notin nodes:
      diags.add(diagnostic("unknown_output", "graph",
        "output targets missing node", refs = @[k, v]))
      continue
    try:
      var isOut: bool
      let rp = lookupPort(registry, nodes[nodeId], portName, isOut)
      if not isOut:
        diags.add(diagnostic("output_not_output", "graph",
          "graph output must reference handler output port", refs = @[k, v]))
    except FactoryError as e:
      diags.add(diagnostic($e.code, "graph", e.msg, refs = @[k, v]))

  for e in g.edges:
    let (fromNode, fromPort) = parsePortRef(e.fromPort)
    let (toNode, toPort) = parsePortRef(e.toPort)
    if fromNode notin nodes:
      diags.add(diagnostic("unknown_edge_from", "graph",
        "edge from unknown node", refs = @[e.fromPort]))
      continue
    if toNode notin nodes:
      diags.add(diagnostic("unknown_edge_to", "graph",
        "edge to unknown node", refs = @[e.toPort]))
      continue
    try:
      var fromIsOut, toIsOut: bool
      let src = lookupPort(registry, nodes[fromNode], fromPort, fromIsOut)
      let dst = lookupPort(registry, nodes[toNode], toPort, toIsOut)
      if not fromIsOut:
        diags.add(diagnostic("edge_source", "graph",
          "edge must start at output port", refs = @[e.fromPort]))
      if toIsOut:
        diags.add(diagnostic("edge_sink", "graph",
          "edge must end at input port", refs = @[e.toPort]))
      if src.schema != dst.schema:
        diags.add(diagnostic($fecValidationFailed, "graph",
          "incompatible port types: " & src.schema & " -> " & dst.schema,
          refs = @[e.fromPort, e.toPort]))
    except FactoryError as ex:
      diags.add(diagnostic($ex.code, "graph", ex.msg,
        refs = @[e.fromPort, e.toPort]))

  validateJoinFeasibility(g, nodes, diags)
  validateLoopSpecs(g, nodes, diags)
  validatePortProducers(g, nodes, diags)
  validateRequiredPortsFed(registry, g, nodes, diags)
  validateUndeclaredCycles(g, nodes, diags)

  if diags.len > 0:
    var r = defaultResult(rsFailed)
    r.errorCode = $fecValidationFailed
    r.errorPhase = "graph"
    r.errorReason = diags[0].message
    r.diagnostics = diags
    return r
  okGraphResult(g)

method validate*(v: NimGraphValidator; graph: JsonNode): CommonResult =
  try:
    let spec = graphFromJson(graph)
    validateGraphSpec(v.registry, spec)
  except FactoryError as e:
    failResult(e.code, e.msg, e.phase, e.refs)