## Factory metadata companion for Message routing / correlation.
## Kept separate when Message cannot carry all factory fields.

import std/json
import ./errors

const
  MetaSchemaName* = "nimfactory.meta"
  MetaSchemaVersion* = "0.1"
  MetaSchema* = MetaSchemaName & "/" & MetaSchemaVersion

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
  for feat in m.requiredFeatures:
    # v0.1 declares no optional required_features yet
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
  if node.isNil or node.kind != JObject:
    raise newFactoryError(fecInvalidJson, "meta must be object", phase = "meta")
  result = defaultMeta()
  result.schema = node{"schema"}.getStr("")
  if result.schema.len == 0:
    raise newFactoryError(fecMissingRequiredInput, "schema required", phase = "meta")
  if result.schema != MetaSchema:
    raise newFactoryError(fecSchemaMismatch,
      "unsupported factory meta schema: " & result.schema, phase = "meta")
  if node.hasKey("required_features"):
    let feats = node["required_features"]
    if feats.kind != JArray:
      raise newFactoryError(fecValidationFailed, "required_features must be array",
        phase = "meta")
    for f in feats:
      let name = f.getStr()
      raise newFactoryError(fecUnknownRequiredFeature,
        "unknown required_feature: " & name, phase = "meta")
  result.messageId = node{"message_id"}.getStr("")
  result.runId = node{"run_id"}.getStr("")
  result.activationId = node{"activation_id"}.getStr("")
  result.attemptId = node{"attempt_id"}.getStr("")
  result.epoch = node{"epoch"}.getInt(1)
  result.correlationId = node{"correlation_id"}.getStr("")
  if node.hasKey("causation_id") and node["causation_id"].kind == JNull:
    result.causationIsNull = true
    result.causationId = ""
  else:
    result.causationIsNull = false
    result.causationId = node{"causation_id"}.getStr("")
  result.payloadSchema = node{"payload_schema"}.getStr("")
  if node.hasKey("extensions"):
    result.extensions = node["extensions"]
  else:
    result.extensions = newJObject()
  result.isRetransmission = node{"is_retransmission"}.getBool(false)
