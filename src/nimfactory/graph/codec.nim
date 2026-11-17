## JSON codec for GraphSpec and control primitives.

import std/[json, tables, algorithm, sequtils]
import ../contracts/[errors, validate, ids]
import ./types

proc predicateFromJson*(node: JsonNode): BranchPredicate =
  if node.isNil or node.kind != JObject:
    raise newFactoryError(fecValidationFailed, "predicate must be object",
      phase = "graph")
  if node.hasKey("eval"):
    raise newFactoryError(fecValidationFailed,
      "branch predicate eval strings are forbidden", phase = "graph")
  requireStringField(node, "op")
  result.op = parsePredicateOp(node{"op"}.getStr())
  result.path = node{"path"}.getStr("")
  if node.hasKey("value"):
    result.value = node["value"]
  else:
    result.value = newJNull()
  if node.hasKey("predicates") and node["predicates"].kind == JArray:
    for p in node["predicates"]:
      result.predicates.add(predicateFromJson(p))

proc predicateToJson*(p: BranchPredicate): JsonNode =
  result = %*{"op": $p.op}
  if p.path.len > 0:
    result["path"] = %p.path
  if p.op == poEquals:
    result["value"] = p.value
  if p.op in {poAll, poAny}:
    var arr = newJArray()
    for child in p.predicates:
      arr.add(predicateToJson(child))
    result["predicates"] = arr

proc joinControlFromJson*(node: JsonNode): JoinControl =
  result = defaultJoinControl()
  if node.isNil or node.kind != JObject:
    return
  if node.hasKey("policy"):
    result.policy = parseJoinPolicy(node{"policy"}.getStr())
  if node.hasKey("quorum"):
    result.quorum = node{"quorum"}.getInt()
  if node.hasKey("on_failure"):
    result.onFailure = parseJoinFailurePolicy(node{"on_failure"}.getStr())
  if node.hasKey("on_late"):
    result.onLate = parseJoinLatePolicy(node{"on_late"}.getStr())
  if node.hasKey("on_cancel"):
    result.onCancel = parseJoinCancelPolicy(node{"on_cancel"}.getStr())

proc joinControlToJson*(j: JoinControl): JsonNode =
  result = %*{
    "policy": $j.policy,
    "on_failure": case j.onFailure
      of jfpFail: "fail"
      of jfpCompletePartial: "complete_partial"
      of jfpIgnore: "ignore",
    "on_late": case j.onLate
      of jlpDiscard: "discard"
      of jlpBuffer: "buffer"
      of jlpFail: "fail",
    "on_cancel": case j.onCancel
      of jcpFail: "fail"
      of jcpCompletePartial: "complete_partial"
      of jcpIgnore: "ignore"
  }
  if j.policy == jpQuorum:
    result["quorum"] = %j.quorum

proc nodeFromJson*(node: JsonNode): GraphNode =
  requireObject(node, "node")
  requireStringField(node, "id")
  result.id = node{"id"}.getStr()
  if node.hasKey("kind"):
    result.kind = parseControlKind(node{"kind"}.getStr())
  elif node.hasKey("handler"):
    result.kind = ckHandler
    result.handler = handlerRef(node{"handler"}.getStr())
  else:
    raise newFactoryError(fecMissingRequiredInput,
      "node requires handler or kind", phase = "graph")
  if node.hasKey("handler"):
    result.handler = handlerRef(node{"handler"}.getStr())
  if node.hasKey("params"):
    result.params = node["params"]
  else:
    result.params = newJObject()
  if node.hasKey("control"):
    result.control = node["control"]
  else:
    result.control = newJObject()

proc nodeToJson*(n: GraphNode): JsonNode =
  result = %*{"id": n.id}
  if n.kind != ckHandler:
    result["kind"] = % $n.kind
  if ($n.handler).len > 0:
    result["handler"] = % $n.handler
  if not n.params.isNil and n.params.len > 0:
    result["params"] = n.params
  if not n.control.isNil and n.control.len > 0:
    result["control"] = n.control

proc loopSpecFromJson*(node: JsonNode): LoopSpec =
  requireObject(node, "loop_spec")
  requireStringField(node, "loop_node_id")
  result.loopNodeId = node{"loop_node_id"}.getStr()
  result.bodyEntry = node{"body_entry"}.getStr("")
  if node.hasKey("exit") and node["exit"].kind == JObject:
    let e = node["exit"]
    if e.hasKey("predicate"):
      result.exit.predicate = predicateFromJson(e["predicate"])
    result.exit.maxIterations = e{"max_iterations"}.getInt(0)
    result.exit.onLimit = e{"on_limit"}.getStr("limit_reached")

proc loopSpecToJson*(s: LoopSpec): JsonNode =
  %*{
    "loop_node_id": s.loopNodeId,
    "body_entry": s.bodyEntry,
    "exit": %*{
      "predicate": predicateToJson(s.exit.predicate),
      "max_iterations": s.exit.maxIterations,
      "on_limit": s.exit.onLimit
    }
  }

proc terminationFromJson*(node: JsonNode): TerminationRules =
  result = defaultTermination()
  if node.isNil or node.kind != JObject:
    return
  if node.hasKey("on_success"):
    result.onSuccess = node{"on_success"}.getStr(result.onSuccess)
  if node.hasKey("on_failure"):
    result.onFailure = node{"on_failure"}.getStr(result.onFailure)
  if node.hasKey("on_cancel"):
    result.onCancel = node{"on_cancel"}.getStr(result.onCancel)
  if node.hasKey("on_limit"):
    result.onLimit = node{"on_limit"}.getStr(result.onLimit)

proc graphFromJson*(node: JsonNode): GraphSpec =
  requireObject(node, "graph")
  requireStringField(node, "schema")
  acceptSchema(node{"schema"}.getStr(), GraphSchema)
  requireStringField(node, "graph_id")
  result = emptyGraphSpec()
  result.schema = node{"schema"}.getStr()
  result.graphId = node{"graph_id"}.getStr()
  result.version = node{"version"}.getInt(1)
  if not node.hasKey("nodes") or node["nodes"].kind != JArray:
    raise newFactoryError(fecMissingRequiredInput, "graph.nodes required",
      phase = "graph")
  for n in node["nodes"]:
    result.nodes.add(nodeFromJson(n))
  if node.hasKey("edges") and node["edges"].kind == JArray:
    for e in node["edges"]:
      requireObject(e, "edge")
      requireStringField(e, "from")
      requireStringField(e, "to")
      result.edges.add(GraphEdge(
        fromPort: e{"from"}.getStr(),
        toPort: e{"to"}.getStr()
      ))
  if node.hasKey("entrypoints") and node["entrypoints"].kind == JArray:
    for ep in node["entrypoints"]:
      requireObject(ep, "entrypoint")
      requireStringField(ep, "input")
      requireStringField(ep, "to")
      result.entrypoints.add(GraphEntrypoint(
        inputName: ep{"input"}.getStr(),
        toPort: ep{"to"}.getStr()
      ))
  if not node.hasKey("outputs") or node["outputs"].kind != JObject:
    raise newFactoryError(fecMissingRequiredInput, "graph.outputs required",
      phase = "graph")
  for k, v in node["outputs"].pairs:
    result.outputs[k] = v.getStr()
  if node.hasKey("loop_specs") and node["loop_specs"].kind == JArray:
    for ls in node["loop_specs"]:
      result.loopSpecs.add(loopSpecFromJson(ls))
  if node.hasKey("termination"):
    result.termination = terminationFromJson(node["termination"])

proc graphToJson*(g: GraphSpec): JsonNode =
  var nodes = newJArray()
  for n in g.nodes:
    nodes.add(nodeToJson(n))
  var edges = newJArray()
  for e in g.edges:
    edges.add(%*{"from": e.fromPort, "to": e.toPort})
  var entrypoints = newJArray()
  for ep in g.entrypoints:
    entrypoints.add(%*{"input": ep.inputName, "to": ep.toPort})
  var outputs = newJObject()
  let keys = toSeq(g.outputs.keys)
  for k in keys.sorted(system.cmp):
    outputs[k] = %g.outputs[k]
  var loopSpecs = newJArray()
  for ls in g.loopSpecs:
    loopSpecs.add(loopSpecToJson(ls))
  result = %*{
    "schema": g.schema,
    "graph_id": g.graphId,
    "version": g.version,
    "nodes": nodes,
    "edges": edges,
    "entrypoints": entrypoints,
    "outputs": outputs,
    "loop_specs": loopSpecs,
    "termination": %*{
      "on_success": g.termination.onSuccess,
      "on_failure": g.termination.onFailure,
      "on_cancel": g.termination.onCancel,
      "on_limit": g.termination.onLimit
    }
  }

proc graphFromJsonString*(raw: string): GraphSpec =
  graphFromJson(parseJsonStrict(raw))