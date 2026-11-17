## GraphSpec and control-primitive types (F4).

import std/[json, tables]
import ../contracts/[ids, errors]

const
  GraphSchemaName* = "nimfactory.graph"
  GraphSchemaVersion* = "0.1"
  GraphSchema* = GraphSchemaName & "/" & GraphSchemaVersion

type
  ControlKind* = enum
    ckHandler = "handler"
    ckSequence = "sequence"
    ckBranch = "branch"
    ckMap = "map"
    ckJoin = "join"
    ckReduce = "reduce"
    ckLoop = "loop"
    ckSubgraph = "subgraph"
    ckAwaitEvent = "await_event"

  PredicateOp* = enum
    poEquals = "equals"
    poExists = "exists"
    poAll = "all"
    poAny = "any"

  JoinPolicy* = enum
    jpAllRequired = "all_required"
    jpQuorum = "quorum"
    jpFirstSuccess = "first_success"

  JoinFailurePolicy* = enum
    jfpFail = "fail"
    jfpCompletePartial = "complete_partial"
    jfpIgnore = "ignore"

  JoinLatePolicy* = enum
    jlpDiscard = "discard"
    jlpBuffer = "buffer"
    jlpFail = "fail"

  JoinCancelPolicy* = enum
    jcpFail = "fail"
    jcpCompletePartial = "complete_partial"
    jcpIgnore = "ignore"

  PortDecl* = object
    name*: string
    schema*: string
    required*: bool

  ParamDecl* = object
    name*: string
    schema*: string
    required*: bool

  HandlerDescriptor* = object
    handlerRef*: HandlerRef
    inputs*: seq[PortDecl]
    outputs*: seq[PortDecl]
    params*: seq[ParamDecl]
    capabilities*: seq[string]
    effectClass*: string

  BranchPredicate* = object
    op*: PredicateOp
    path*: string
    value*: JsonNode
    predicates*: seq[BranchPredicate]

  JoinControl* = object
    policy*: JoinPolicy
    quorum*: int
    onFailure*: JoinFailurePolicy
    onLate*: JoinLatePolicy
    onCancel*: JoinCancelPolicy

  ReduceControl* = object
    function*: string
    stableOrder*: bool
    commutative*: bool

  MapControl* = object
    branches*: seq[string]

  SubgraphControl* = object
    graphId*: string
    graphVersion*: int

  AwaitEventControl* = object
    eventType*: string
    correlationPort*: string
    deadlineMs*: int

  LoopExit* = object
    predicate*: BranchPredicate
    maxIterations*: int
    onLimit*: string

  GraphNode* = object
    id*: string
    kind*: ControlKind
    handler*: HandlerRef
    params*: JsonNode
    control*: JsonNode

  GraphEdge* = object
    fromPort*: string
    toPort*: string

  GraphEntrypoint* = object
    inputName*: string
    toPort*: string

  LoopSpec* = object
    loopNodeId*: string
    bodyEntry*: string
    exit*: LoopExit

  TerminationRules* = object
    onSuccess*: string
    onFailure*: string
    onCancel*: string
    onLimit*: string

  GraphSpec* = object
    schema*: string
    graphId*: string
    version*: int
    nodes*: seq[GraphNode]
    edges*: seq[GraphEdge]
    entrypoints*: seq[GraphEntrypoint]
    outputs*: Table[string, string]
    loopSpecs*: seq[LoopSpec]
    termination*: TerminationRules

proc parseControlKind*(s: string): ControlKind =
  case s
  of "handler": ckHandler
  of "sequence": ckSequence
  of "branch": ckBranch
  of "map": ckMap
  of "join": ckJoin
  of "reduce": ckReduce
  of "loop": ckLoop
  of "subgraph": ckSubgraph
  of "await_event": ckAwaitEvent
  else:
    raise newFactoryError(fecValidationFailed, "unknown control kind: " & s,
      phase = "graph")

proc `$`*(k: ControlKind): string =
  case k
  of ckHandler: "handler"
  of ckSequence: "sequence"
  of ckBranch: "branch"
  of ckMap: "map"
  of ckJoin: "join"
  of ckReduce: "reduce"
  of ckLoop: "loop"
  of ckSubgraph: "subgraph"
  of ckAwaitEvent: "await_event"

proc parsePredicateOp*(s: string): PredicateOp =
  case s
  of "equals": poEquals
  of "exists": poExists
  of "all": poAll
  of "any": poAny
  of "eval":
    raise newFactoryError(fecValidationFailed,
      "branch predicate eval strings are forbidden", phase = "graph")
  else:
    raise newFactoryError(fecValidationFailed, "unknown predicate op: " & s,
      phase = "graph")

proc `$`*(o: PredicateOp): string =
  case o
  of poEquals: "equals"
  of poExists: "exists"
  of poAll: "all"
  of poAny: "any"

proc parseJoinPolicy*(s: string): JoinPolicy =
  case s
  of "all_required": jpAllRequired
  of "quorum": jpQuorum
  of "first_success": jpFirstSuccess
  else:
    raise newFactoryError(fecValidationFailed, "unknown join policy: " & s,
      phase = "graph")

proc `$`*(p: JoinPolicy): string =
  case p
  of jpAllRequired: "all_required"
  of jpQuorum: "quorum"
  of jpFirstSuccess: "first_success"

proc parseJoinFailurePolicy*(s: string): JoinFailurePolicy =
  case s
  of "fail": jfpFail
  of "complete_partial": jfpCompletePartial
  of "ignore": jfpIgnore
  else:
    raise newFactoryError(fecValidationFailed,
      "unknown join on_failure policy: " & s, phase = "graph")

proc parseJoinLatePolicy*(s: string): JoinLatePolicy =
  case s
  of "discard": jlpDiscard
  of "buffer": jlpBuffer
  of "fail": jlpFail
  else:
    raise newFactoryError(fecValidationFailed,
      "unknown join on_late policy: " & s, phase = "graph")

proc parseJoinCancelPolicy*(s: string): JoinCancelPolicy =
  case s
  of "fail": jcpFail
  of "complete_partial": jcpCompletePartial
  of "ignore": jcpIgnore
  else:
    raise newFactoryError(fecValidationFailed,
      "unknown join on_cancel policy: " & s, phase = "graph")

proc defaultJoinControl*(): JoinControl =
  JoinControl(
    policy: jpAllRequired,
    quorum: 0,
    onFailure: jfpFail,
    onLate: jlpDiscard,
    onCancel: jcpFail
  )

proc defaultTermination*(): TerminationRules =
  TerminationRules(
    onSuccess: "completed",
    onFailure: "failed",
    onCancel: "cancelled",
    onLimit: "limit_reached"
  )

proc emptyGraphSpec*(): GraphSpec =
  GraphSpec(
    schema: GraphSchema,
    graphId: "",
    version: 0,
    nodes: @[],
    edges: @[],
    entrypoints: @[],
    outputs: initTable[string, string](),
    loopSpecs: @[],
    termination: defaultTermination()
  )