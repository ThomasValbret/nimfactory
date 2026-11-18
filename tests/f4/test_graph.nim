import std/[json, strutils]
import nimfactory/contracts/[result, errors]
import nimfactory/graph/[graph, registry, validator, codec]

proc reg(): SimulatedHandlerRegistry =
  let r = newSimulatedHandlerRegistry()
  registerSeedBasicHandlers(r)
  r

proc expectOk(r: CommonResult) =
  if r.status != rsOk:
    echo "expected ok, got ", r.status, ": ", r.errorReason
    for d in r.diagnostics:
      echo "  ", d.code, ": ", d.message
    raise newException(AssertionDefect, "validation should pass")

proc expectFail(r: CommonResult; substr = "") =
  if r.status != rsFailed:
    raise newException(AssertionDefect, "validation should fail")
  if substr.len > 0:
    var found = false
    for d in r.diagnostics:
      if d.message.contains(substr) or d.code.contains(substr):
        found = true
        break
    if r.errorReason.contains(substr):
      found = true
    if not found:
      echo r.errorReason
      for d in r.diagnostics:
        echo d.code, ": ", d.message
      raise newException(AssertionDefect,
        "expected diagnostic containing: " & substr)

proc seedBasicGraph(): JsonNode =
  %*{
    "schema": "nimfactory.graph/0.1",
    "graph_id": "seed-basic",
    "version": 1,
    "nodes": [
      {"id": "task", "handler": "prompt.prepare@0.1"},
      {"id": "rules", "handler": "instructions.select@0.1"},
      {"id": "seed", "handler": "seed.assemble@0.1"}
    ],
    "entrypoints": [
      {"input": "context_request", "to": "task.request"},
      {"input": "context_request", "to": "rules.request"},
      {"input": "context_request", "to": "seed.request"},
      {"input": "model_plan", "to": "seed.model_plan"}
    ],
    "edges": [
      {"from": "task.fragments", "to": "seed.task_fragments"},
      {"from": "rules.fragments", "to": "seed.instruction_fragments"}
    ],
    "outputs": {"seed": "seed.seed", "receipt": "seed.receipt"},
    "loop_specs": []
  }

block validSequence:
  let g = %*{
    "schema": "nimfactory.graph/0.1",
    "graph_id": "seq-demo",
    "version": 1,
    "nodes": [
      {"id": "a", "handler": "noop.passthrough@0.1"},
      {"id": "b", "handler": "noop.passthrough@0.1"},
      {"id": "c", "kind": "sequence", "control": {}}
    ],
    "entrypoints": [{"input": "start", "to": "a.in"}],
    "edges": [
      {"from": "a.out", "to": "b.in"},
      {"from": "b.out", "to": "c.in"}
    ],
    "outputs": {"result": "c.out"},
    "loop_specs": []
  }
  let v = newNimGraphValidator(reg())
  expectOk(v.validate(g))

block validBranch:
  let g = %*{
    "schema": "nimfactory.graph/0.1",
    "graph_id": "branch-demo",
    "version": 1,
    "nodes": [
      {"id": "probe", "handler": "noop.flag@0.1"},
      {"id": "br", "kind": "branch", "control": {
        "predicate": {"op": "equals", "path": "ready", "value": true}
      }},
      {"id": "yes", "handler": "noop.passthrough@0.1"},
      {"id": "no", "handler": "noop.passthrough@0.1"}
    ],
    "entrypoints": [{"input": "flag", "to": "probe.in"}],
    "edges": [
      {"from": "probe.out", "to": "br.in"},
      {"from": "br.then", "to": "yes.in"},
      {"from": "br.else", "to": "no.in"}
    ],
    "outputs": {"yes_out": "yes.out", "no_out": "no.out"},
    "loop_specs": []
  }
  expectOk(validateGraphSpec(reg(), graphFromJson(g)))

block validParallel:
  let g = %*{
    "schema": "nimfactory.graph/0.1",
    "graph_id": "parallel-demo",
    "version": 1,
    "nodes": [
      {"id": "split", "kind": "map", "control": {"branches": ["p1", "p2"]}},
      {"id": "p1", "handler": "noop.passthrough@0.1"},
      {"id": "p2", "handler": "noop.passthrough@0.1"},
      {"id": "merge", "kind": "join", "control": {
        "policy": "all_required",
        "on_failure": "fail",
        "on_late": "discard",
        "on_cancel": "fail"
      }}
    ],
    "entrypoints": [{"input": "start", "to": "split.in"}],
    "edges": [
      {"from": "split.branch", "to": "p1.in"},
      {"from": "split.branch", "to": "p2.in"},
      {"from": "p1.out", "to": "merge.in_1"},
      {"from": "p2.out", "to": "merge.in_2"}
    ],
    "outputs": {"merged": "merge.out"},
    "loop_specs": []
  }
  expectOk(validateGraphSpec(reg(), graphFromJson(g)))

block validLoop:
  let g = %*{
    "schema": "nimfactory.graph/0.1",
    "graph_id": "loop-demo",
    "version": 1,
    "nodes": [
      {"id": "loop", "kind": "loop", "control": {}},
      {"id": "step", "handler": "noop.passthrough@0.1"}
    ],
    "entrypoints": [{"input": "start", "to": "loop.in"}],
    "edges": [
      {"from": "loop.body", "to": "step.in"},
      {"from": "step.out", "to": "loop.in"}
    ],
    "outputs": {"done": "loop.done"},
    "loop_specs": [{
      "loop_node_id": "loop",
      "body_entry": "step",
      "exit": {
        "predicate": {"op": "exists", "path": "done"},
        "max_iterations": 8,
        "on_limit": "limit_reached"
      }
    }]
  }
  expectOk(validateGraphSpec(reg(), graphFromJson(g)))

block validSeedBasic:
  let v = newNimGraphValidator(reg())
  expectOk(v.validate(seedBasicGraph()))

block rejectIncompatiblePort:
  var g = seedBasicGraph()
  g["edges"] = %*[
    {"from": "task.fragments", "to": "seed.model_plan"}
  ]
  let r = validateGraphSpec(reg(), graphFromJson(g))
  expectFail(r, "incompatible")

block rejectUndeclaredCycle:
  let g = %*{
    "schema": "nimfactory.graph/0.1",
    "graph_id": "cycle-bad",
    "version": 1,
    "nodes": [
      {"id": "a", "handler": "noop.passthrough@0.1"},
      {"id": "b", "handler": "noop.passthrough@0.1"}
    ],
    "entrypoints": [{"input": "start", "to": "a.in"}],
    "edges": [
      {"from": "a.out", "to": "b.in"},
      {"from": "b.out", "to": "a.in"}
    ],
    "outputs": {"out": "b.out"},
    "loop_specs": []
  }
  let r = validateGraphSpec(reg(), graphFromJson(g))
  expectFail(r, "dependency_cycle")

block rejectImpossibleJoin:
  let g = %*{
    "schema": "nimfactory.graph/0.1",
    "graph_id": "join-bad",
    "version": 1,
    "nodes": [
      {"id": "p1", "handler": "noop.passthrough@0.1"},
      {"id": "merge", "kind": "join", "control": {
        "policy": "quorum",
        "quorum": 3,
        "on_failure": "fail",
        "on_late": "discard",
        "on_cancel": "fail"
      }}
    ],
    "entrypoints": [{"input": "start", "to": "p1.in"}],
    "edges": [
      {"from": "p1.out", "to": "merge.in_1"}
    ],
    "outputs": {"merged": "merge.out"},
    "loop_specs": []
  }
  let r = validateGraphSpec(reg(), graphFromJson(g))
  expectFail(r, "impossible_join")

block rejectBranchEval:
  let g = %*{
    "schema": "nimfactory.graph/0.1",
    "graph_id": "eval-bad",
    "version": 1,
    "nodes": [
      {"id": "br", "kind": "branch", "control": {
        "predicate": {"op": "equals", "path": "x", "value": 1},
        "eval": "unsafe"
      }}
    ],
    "entrypoints": [],
    "edges": [],
    "outputs": {},
    "loop_specs": []
  }
  expectFail(validateGraphSpec(reg(), graphFromJson(g)), "forbidden_eval")
  var raised = false
  try:
    discard predicateFromJson(%*{"op": "eval", "path": "x"})
  except FactoryError:
    raised = true
  doAssert raised

block roundtrip:
  let spec = graphFromJson(seedBasicGraph())
  let again = graphFromJson(graphToJson(spec))
  doAssert again.graphId == spec.graphId
  doAssert again.nodes.len == spec.nodes.len

echo "test_graph: ok"