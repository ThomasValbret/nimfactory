## Common handler result envelope.

import std/json
import ./errors
import ./validate

const
  ResultSchemaName* = "nimfactory.result"
  ResultSchemaVersion* = "0.1"
  ResultSchema* = ResultSchemaName & "/" & ResultSchemaVersion

  ResultRequiredFields* = ["schema", "status", "outputs", "needs", "diagnostics"]
  ResultOptionalFields* = ["read_set_ref", "usage_ref", "error"]

type
  ResultStatus* = enum
    rsOk = "ok"
    rsPartial = "partial"
    rsBlocked = "blocked"
    rsFailed = "failed"
    rsCancelled = "cancelled"

  NeedItem* = object
    id*: string
    chamberOrSource*: string
    selector*: string
    required*: bool
    reason*: string

  CommonResult* = object
    schema*: string
    status*: ResultStatus
    outputs*: JsonNode          ## map of output name -> value/ref
    needs*: seq[NeedItem]
    diagnostics*: seq[Diagnostic]
    readSetRef*: string         ## ArtifactRef as string; empty = null
    usageRef*: string           ## empty = null
    errorCode*: string
    errorPhase*: string
    errorRetryable*: bool
    errorReason*: string

proc parseStatus*(s: string): ResultStatus =
  case s
  of "ok": rsOk
  of "partial": rsPartial
  of "blocked": rsBlocked
  of "failed": rsFailed
  of "cancelled": rsCancelled
  else:
    raise newFactoryError(fecValidationFailed, "unknown status: " & s,
      phase = "result")

proc `$`*(s: ResultStatus): string =
  case s
  of rsOk: "ok"
  of rsPartial: "partial"
  of rsBlocked: "blocked"
  of rsFailed: "failed"
  of rsCancelled: "cancelled"

proc defaultResult*(status = rsOk): CommonResult =
  CommonResult(
    schema: ResultSchema,
    status: status,
    outputs: newJObject(),
    needs: @[],
    diagnostics: @[],
    readSetRef: "",
    usageRef: "",
    errorCode: "",
    errorPhase: "",
    errorRetryable: false,
    errorReason: ""
  )

proc resultToJson*(r: CommonResult): JsonNode =
  if r.schema != ResultSchema:
    raise newFactoryError(fecSchemaMismatch,
      "unsupported result schema: " & r.schema, phase = "result")
  result = newJObject()
  result["schema"] = %r.schema
  result["status"] = % $r.status
  result["outputs"] = (if r.outputs.isNil: newJObject() else: r.outputs)
  var needs = newJArray()
  for n in r.needs:
    needs.add(%*{
      "id": n.id,
      "target": n.chamberOrSource,
      "selector": n.selector,
      "required": n.required,
      "reason": n.reason
    })
  result["needs"] = needs
  var diags = newJArray()
  for d in r.diagnostics:
    diags.add(%*{
      "code": d.code,
      "phase": d.phase,
      "message": d.message,
      "retryable": d.retryable,
      "refs": d.refs
    })
  result["diagnostics"] = diags
  if r.readSetRef.len == 0:
    result["read_set_ref"] = newJNull()
  else:
    result["read_set_ref"] = %r.readSetRef
  if r.usageRef.len == 0:
    result["usage_ref"] = newJNull()
  else:
    result["usage_ref"] = %r.usageRef
  if r.status in {rsFailed, rsBlocked} and r.errorCode.len > 0:
    result["error"] = %*{
      "code": r.errorCode,
      "phase": r.errorPhase,
      "retryable": r.errorRetryable,
      "reason": r.errorReason
    }

proc resultFromJson*(node: JsonNode): CommonResult =
  requireObject(node, "result")
  var allowed: seq[string] = @[]
  for k in ResultRequiredFields: allowed.add(k)
  for k in ResultOptionalFields: allowed.add(k)
  rejectUnknownKeys(node, allowed, "result")

  requireField(node, "schema", {JString}, "result")
  requireField(node, "status", {JString}, "result")
  requireField(node, "outputs", {JObject}, "result")
  requireField(node, "needs", {JArray}, "result")
  requireField(node, "diagnostics", {JArray}, "result")

  result = defaultResult()
  result.schema = node["schema"].getStr()
  acceptSchema(result.schema, ResultSchema)
  # Never default missing status to ok — status field is required above.
  result.status = parseStatus(node["status"].getStr())
  result.outputs = node["outputs"]
  const needAllowed = ["id", "target", "selector", "required", "reason"]
  const diagAllowed = ["code", "phase", "message", "retryable", "refs"]
  for n in node["needs"]:
    if n.kind != JObject:
      raise newFactoryError(fecValidationFailed, "need must be object", phase = "result")
    rejectUnknownKeys(n, needAllowed, "need")
    var required = false
    if n.hasKey("required"):
      if n["required"].kind != JBool:
        raise newFactoryError(fecValidationFailed,
          "need.required must be boolean", phase = "result")
      required = n["required"].getBool()
    if n.hasKey("id") and n["id"].kind != JString:
      raise newFactoryError(fecValidationFailed, "need.id must be string", phase = "result")
    if n.hasKey("target") and n["target"].kind != JString:
      raise newFactoryError(fecValidationFailed, "need.target must be string", phase = "result")
    if n.hasKey("selector") and n["selector"].kind != JString:
      raise newFactoryError(fecValidationFailed, "need.selector must be string", phase = "result")
    if n.hasKey("reason") and n["reason"].kind != JString:
      raise newFactoryError(fecValidationFailed, "need.reason must be string", phase = "result")
    result.needs.add(NeedItem(
      id: n{"id"}.getStr(""),
      chamberOrSource: n{"target"}.getStr(""),
      selector: n{"selector"}.getStr(""),
      required: required,
      reason: n{"reason"}.getStr("")
    ))
  for d in node["diagnostics"]:
    if d.kind != JObject:
      raise newFactoryError(fecValidationFailed, "diagnostic must be object",
        phase = "result")
    rejectUnknownKeys(d, diagAllowed, "diagnostic")
    if d.hasKey("code") and d["code"].kind != JString:
      raise newFactoryError(fecValidationFailed,
        "diagnostic.code must be string", phase = "result")
    if d.hasKey("phase") and d["phase"].kind != JString:
      raise newFactoryError(fecValidationFailed,
        "diagnostic.phase must be string", phase = "result")
    if d.hasKey("message") and d["message"].kind != JString:
      raise newFactoryError(fecValidationFailed,
        "diagnostic.message must be string", phase = "result")
    if d.hasKey("retryable") and d["retryable"].kind != JBool:
      raise newFactoryError(fecValidationFailed,
        "diagnostic.retryable must be boolean", phase = "result")
    var refs: seq[string] = @[]
    if d.hasKey("refs"):
      if d["refs"].kind != JArray:
        raise newFactoryError(fecValidationFailed,
          "diagnostic.refs must be array", phase = "result")
      for r in d["refs"]:
        if r.kind != JString:
          raise newFactoryError(fecValidationFailed,
            "diagnostic.refs items must be strings", phase = "result")
        refs.add(r.getStr())
    result.diagnostics.add(diagnostic(
      d{"code"}.getStr(""), d{"phase"}.getStr(""), d{"message"}.getStr(""),
      d{"retryable"}.getBool(false), refs))
  if node.hasKey("read_set_ref"):
    if node["read_set_ref"].kind == JNull:
      result.readSetRef = ""
    elif node["read_set_ref"].kind == JString:
      result.readSetRef = node["read_set_ref"].getStr()
    else:
      raise newFactoryError(fecValidationFailed, "read_set_ref must be string|null",
        phase = "result")
  if node.hasKey("usage_ref"):
    if node["usage_ref"].kind == JNull:
      result.usageRef = ""
    elif node["usage_ref"].kind == JString:
      result.usageRef = node["usage_ref"].getStr()
    else:
      raise newFactoryError(fecValidationFailed, "usage_ref must be string|null",
        phase = "result")
  if node.hasKey("error"):
    requireField(node, "error", {JObject}, "result")
    let e = node["error"]
    const errorAllowed = ["code", "phase", "retryable", "reason"]
    rejectUnknownKeys(e, errorAllowed, "error")
    if e.hasKey("code") and e["code"].kind != JString:
      raise newFactoryError(fecValidationFailed,
        "error.code must be string", phase = "result")
    if e.hasKey("phase") and e["phase"].kind != JString:
      raise newFactoryError(fecValidationFailed,
        "error.phase must be string", phase = "result")
    if e.hasKey("reason") and e["reason"].kind != JString:
      raise newFactoryError(fecValidationFailed,
        "error.reason must be string", phase = "result")
    if e.hasKey("retryable") and e["retryable"].kind != JBool:
      raise newFactoryError(fecValidationFailed,
        "error.retryable must be boolean", phase = "result")
    result.errorCode = e{"code"}.getStr("")
    result.errorPhase = e{"phase"}.getStr("")
    result.errorRetryable = e{"retryable"}.getBool(false)
    result.errorReason = e{"reason"}.getStr("")
