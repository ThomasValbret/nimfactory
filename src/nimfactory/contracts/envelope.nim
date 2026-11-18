## Transport envelope: factory meta + nimagent Message (codec form).
## In memory: FactoryEnvelope holds typed Message + FactoryMeta.
## On the wire / fixtures: JSON with "factory" and "message" fields.

import std/json
import nimagent/messages
import ./meta
import ./errors
import ./validate
import ./result
import ../adapters/nimagent/message_codec

type
  FactoryEnvelope* = object
    factory*: FactoryMeta
    message*: Message
    payload*: JsonNode   ## optional typed business payload (not Message content)

proc envelopeToJson*(e: FactoryEnvelope): JsonNode =
  result = newJObject()
  result["factory"] = metaToJson(e.factory)
  result["message"] = messageToFactoryJson(e.message)
  if not e.payload.isNil:
    result["payload"] = e.payload

proc envelopeFromJson*(node: JsonNode): FactoryEnvelope =
  requireObject(node, "envelope")
  rejectUnknownKeys(node, ["factory", "message", "payload"], "envelope")
  if not node.hasKey("factory") or not node.hasKey("message"):
    raise newFactoryError(fecMissingRequiredInput,
      "envelope requires factory and message", phase = "envelope")
  result.factory = metaFromJson(node["factory"])
  result.message = messageFromFactoryJson(node["message"])
  if node.hasKey("payload"):
    result.payload = node["payload"]
    # If payload claims result schema, validate it fully.
    if result.payload.kind == JObject and
       result.payload{"schema"}.getStr("") == ResultSchema:
      discard resultFromJson(result.payload)
  else:
    result.payload = nil

proc envelopeFromJsonStrict*(raw: string): FactoryEnvelope =
  envelopeFromJson(parseJsonStrict(raw))

proc ndjsonLine*(e: FactoryEnvelope): string =
  $envelopeToJson(e)
