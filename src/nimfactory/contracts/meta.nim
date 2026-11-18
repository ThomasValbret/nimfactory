## Factory metadata companion for Message routing / correlation.
## Kept separate when Message cannot carry all factory fields.

import std/json
import ./errors
import ./validate

const
  MetaSchemaName* = "nimfactory.meta"
  MetaSchemaVersion* = "0.1"
  MetaSchema* = MetaSchemaName & "/" & MetaSchemaVersion

  MetaRequiredFields* = [
    "schema", "message_id", "run_id", "activation_id", "attempt_id",
    "epoch", "correlation_id", "causation_id", "payload_schema", "extensions"
  ]
  MetaOptionalFields* = ["required_features", "is_retransmission"]

type
  FactoryMeta* = object
    schema*: string
    messageId*: string
    runId*: string
    activationId*: string
    attemptId*: string
    epoch*: int
    correlationId*: string
    causationId*: string          ## empty string means JSON null
    causationIsNull*: bool
    payloadSchema*: string
    requiredFeatures*: seq[string]
    extensions*: JsonNode
    ## Attempt vs retransmission: same messageId = retransmission;
    ## new attemptId = new attempt of the same activation.
    isRetransmission*: bool

proc defaultMeta*(): FactoryMeta =
  FactoryMeta(
    schema: MetaSchema,
    messageId: "",
    runId: "",
    activationId: "",
    attemptId: "",
    epoch: 1,
    correlationId: "",
    causationId: "",
    causationIsNull: true,
    payloadSchema: "",
    requiredFeatures: @[],
    extensions: newJObject(),
    isRetransmission: false
  )

proc validateMeta*(m: FactoryMeta) =
  if m.schema != MetaSchema:
    raise newFactoryError(fecSchemaMismatch,
      "unsupported factory meta schema: " & m.schema, phase = "meta")
  if m.messageId.len == 0 or m.runId.len == 0 or m.activationId.len == 0 or
     m.attemptId.len == 0:
    raise newFactoryError(fecMissingRequiredInput,
      "meta identifiers must be non-empty", phase = "meta")
  if m.epoch < 0:
    raise newFactoryError(fecValidationFailed, "epoch must be >= 0", phase = "meta")
  for feat in m.requiredFeatures:
    raise newFactoryError(fecUnknownRequiredFeature,
      "unknown required_feature: " & feat, phase = "meta")

proc metaToJson*(m: FactoryMeta): JsonNode =
  validateMeta(m)
  result = newJObject()
  result["schema"] = %m.schema
  result["message_id"] = %m.messageId
  result["run_id"] = %m.runId
  result["activation_id"] = %m.activationId
  result["attempt_id"] = %m.attemptId
  result["epoch"] = %m.epoch
  result["correlation_id"] = %m.correlationId
  if m.causationIsNull:
    result["causation_id"] = newJNull()
  else:
    result["causation_id"] = %m.causationId
  result["payload_schema"] = %m.payloadSchema
  if m.requiredFeatures.len > 0:
    result["required_features"] = %m.requiredFeatures
  result["extensions"] = (if m.extensions.isNil: newJObject() else: m.extensions)
  result["is_retransmission"] = %m.isRetransmission

proc metaFromJson*(node: JsonNode): FactoryMeta =
  requireObject(node, "meta")
  var allowed: seq[string] = @[]
  for k in MetaRequiredFields: allowed.add(k)
  for k in MetaOptionalFields: allowed.add(k)
  rejectUnknownKeys(node, allowed, "meta")

  requireField(node, "schema", {JString}, "meta")
  requireField(node, "message_id", {JString}, "meta")
  requireField(node, "run_id", {JString}, "meta")
  requireField(node, "activation_id", {JString}, "meta")
  requireField(node, "attempt_id", {JString}, "meta")
  requireField(node, "epoch", {JInt}, "meta")
  requireField(node, "correlation_id", {JString}, "meta")
  requireField(node, "causation_id", {JString, JNull}, "meta")
  requireField(node, "payload_schema", {JString}, "meta")
  requireField(node, "extensions", {JObject}, "meta")

  result = defaultMeta()
  result.schema = node["schema"].getStr()
  acceptSchema(result.schema, MetaSchema)
  result.messageId = node["message_id"].getStr()
  result.runId = node["run_id"].getStr()
  result.activationId = node["activation_id"].getStr()
  result.attemptId = node["attempt_id"].getStr()
  result.epoch = node["epoch"].getInt()
  result.correlationId = node["correlation_id"].getStr()
  if node["causation_id"].kind == JNull:
    result.causationIsNull = true
    result.causationId = ""
  else:
    result.causationIsNull = false
    result.causationId = node["causation_id"].getStr()
  result.payloadSchema = node["payload_schema"].getStr()
  result.extensions = node["extensions"]
  if node.hasKey("required_features"):
    requireField(node, "required_features", {JArray}, "meta")
    for f in node["required_features"]:
      if f.kind != JString:
        raise newFactoryError(fecValidationFailed,
          "required_features items must be strings", phase = "meta")
      result.requiredFeatures.add(f.getStr())
  if node.hasKey("is_retransmission"):
    requireField(node, "is_retransmission", {JBool}, "meta")
    result.isRetransmission = node["is_retransmission"].getBool()
  validateMeta(result)
