## Common handler result envelope.

import std/json
import ./errors

const
  ResultSchemaName* = "nimfactory.result"
  ResultSchemaVersion* = "0.1"
  ResultSchema* = ResultSchemaName & "/" & ResultSchemaVersion

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
  if node.isNil or node.kind != JObject:
    raise newFactoryError(fecInvalidJson, "result must be object", phase = "result")
  result = defaultResult()
  result.schema = node{"schema"}.getStr("")
  if result.schema != ResultSchema:
    raise newFactoryError(fecSchemaMismatch,
      "unsupported result schema: " & result.schema, phase = "result")
  result.status = parseStatus(node{"status"}.getStr("ok"))
  if node.hasKey("outputs"):
    result.outputs = node["outputs"]
  if node.hasKey("needs") and node["needs"].kind == JArray:
    for n in node["needs"]:
      result.needs.add(NeedItem(
        id: n{"id"}.getStr(""),
        chamberOrSource: n{"target"}.getStr(""),
        selector: n{"selector"}.getStr(""),
        required: n{"required"}.getBool(false),
        reason: n{"reason"}.getStr("")
      ))
  if node.hasKey("diagnostics") and node["diagnostics"].kind == JArray:
    for d in node["diagnostics"]:
      var refs: seq[string] = @[]
      if d.hasKey("refs") and d["refs"].kind == JArray:
        for r in d["refs"]:
          refs.add(r.getStr())
      result.diagnostics.add(diagnostic(
        d{"code"}.getStr(""), d{"phase"}.getStr(""), d{"message"}.getStr(""),
        d{"retryable"}.getBool(false), refs))
  if node.hasKey("read_set_ref") and node["read_set_ref"].kind != JNull:
    result.readSetRef = node["read_set_ref"].getStr("")
  if node.hasKey("usage_ref") and node["usage_ref"].kind != JNull:
    result.usageRef = node["usage_ref"].getStr("")
  if node.hasKey("error") and node["error"].kind == JObject:
    let e = node["error"]
    result.errorCode = e{"code"}.getStr("")
    result.errorPhase = e{"phase"}.getStr("")
    result.errorRetryable = e{"retryable"}.getBool(false)
    result.errorReason = e{"reason"}.getStr("")
