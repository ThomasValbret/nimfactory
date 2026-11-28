## Bidirectional codec between nimagent Message and factory JSON.
## Extends SDK session codec to preserve accents, nulls, cache/reasoning tokens,
## finishReason, and empty optional fields needed for lossless round-trips.
## When the linked nimagent exposes protocol / parts / counterPresence, those
## fields are preserved too; older pins compile without them and older records
## remain readable (missing keys keep defaults).

import std/[json, options]
import nimagent/messages
import ../../contracts/errors

const factoryHasProtocolParts = compiles((var m = default(Message); discard m.protocol; discard m.parts))
const factoryHasCounterPresence = compiles((var u = default(TokenUsage); discard u.counterPresence))

proc roleToJson*(r: Role): string =
  case r
  of Role.System: "System"
  of Role.User: "User"
  of Role.Assistant: "Assistant"
  of Role.Tool: "Tool"

proc roleFromJson*(s: string): Role =
  case s
  of "System": Role.System
  of "User": Role.User
  of "Assistant": Role.Assistant
  of "Tool": Role.Tool
  else:
    raise newFactoryError(fecValidationFailed, "unknown role: " & s, phase = "message")

when factoryHasCounterPresence:
  proc storeFactoryCounterPresence(node: JsonNode; usage: TokenUsage) =
    if usage.counterPresence.isSome:
      let fields = newJArray()
      for counter in usage.counterPresence.get:
        fields.add(%($counter))
      node["reportedCounters"] = fields

  proc restoreFactoryCounterPresence(node: JsonNode; usage: var TokenUsage) =
    if node.hasKey("reportedCounters"):
      var present: set[UsageCounter]
      let counters = node["reportedCounters"]
      if counters.kind != JArray:
        raise newFactoryError(fecValidationFailed, "usage.reportedCounters must be array", phase = "message")
      for value in counters:
        for counter in UsageCounter:
          if value.getStr == $counter:
            present.incl(counter)
      usage.counterPresence = some(present)

when factoryHasProtocolParts:
  proc partsToFactoryJson(parts: seq[MessagePart]): JsonNode =
    result = newJArray()
    for part in parts:
      result.add(%*[ord(part.kind), part.offset, part.length])

  proc partsFromFactoryJson(node: JsonNode): seq[MessagePart] =
    if node.kind != JArray:
      raise newFactoryError(fecValidationFailed, "parts must be array", phase = "message")
    for item in node:
      if item.kind != JArray or item.len != 3 or item[0].getInt(-1) notin 0..ord(high(PartKind)):
        raise newFactoryError(fecValidationFailed, "invalid message part", phase = "message")
      result.add(MessagePart(
        kind: PartKind(item[0].getInt),
        offset: item[1].getInt(-1),
        length: item[2].getInt(-1)
      ))

proc messageToFactoryJson*(m: Message): JsonNode =
  ## Lossless factory codec for Message (superset of SDK session helpers).
  result = newJObject()
  result["role"] = %roleToJson(m.role)
  result["content"] = %m.content
  result["toolCallId"] = %m.toolCallId
  result["toolName"] = %m.toolName
  result["finishReason"] = %m.finishReason
  var images = newJArray()
  for img in m.images:
    images.add(%img)
  result["images"] = images
  var toolCalls = newJArray()
  for tc in m.toolCalls:
    toolCalls.add(%*{
      "id": tc.id,
      "name": tc.name,
      "arguments": tc.arguments
    })
  result["toolCalls"] = toolCalls
  result["usage"] = %*{
    "promptTokens": m.usage.promptTokens,
    "completionTokens": m.usage.completionTokens,
    "totalTokens": m.usage.totalTokens,
    "cacheTokens": m.usage.cacheTokens,
    "reasoningTokens": m.usage.reasoningTokens,
    "isReported": m.usage.isReported
  }
  when factoryHasCounterPresence:
    storeFactoryCounterPresence(result["usage"], m.usage)
  when factoryHasProtocolParts:
    if m.protocol.len > 0:
      result["protocol"] = %m.protocol
    if m.parts.len > 0:
      result["parts"] = partsToFactoryJson(m.parts)

proc messageFromFactoryJson*(node: JsonNode): Message =
  if node.isNil or node.kind != JObject:
    raise newFactoryError(fecInvalidJson, "message must be object", phase = "message")
  if not node.hasKey("role"):
    raise newFactoryError(fecMissingRequiredInput, "message.role required", phase = "message")
  result = Message(
    role: roleFromJson(node["role"].getStr()),
    content: node{"content"}.getStr(""),
    toolCallId: node{"toolCallId"}.getStr(""),
    toolName: node{"toolName"}.getStr(""),
    finishReason: node{"finishReason"}.getStr("")
  )
  when factoryHasProtocolParts:
    result.protocol = node{"protocol"}.getStr("")
  if node.hasKey("images"):
    if node["images"].kind != JArray:
      raise newFactoryError(fecValidationFailed, "images must be array", phase = "message")
    for img in node["images"]:
      result.images.add(img.getStr())
  if node.hasKey("toolCalls"):
    if node["toolCalls"].kind != JArray:
      raise newFactoryError(fecValidationFailed, "toolCalls must be array", phase = "message")
    for tc in node["toolCalls"]:
      result.toolCalls.add(ToolCall(
        id: tc{"id"}.getStr(""),
        name: tc{"name"}.getStr(""),
        arguments: tc{"arguments"}.getStr("")
      ))
  when factoryHasProtocolParts:
    if node.hasKey("parts"):
      result.parts = partsFromFactoryJson(node["parts"])
  if node.hasKey("usage") and node["usage"].kind == JObject:
    let u = node["usage"]
    result.usage = TokenUsage(
      promptTokens: u{"promptTokens"}.getInt(0),
      completionTokens: u{"completionTokens"}.getInt(0),
      totalTokens: u{"totalTokens"}.getInt(0),
      cacheTokens: u{"cacheTokens"}.getInt(0),
      reasoningTokens: u{"reasoningTokens"}.getInt(0),
      isReported: u{"isReported"}.getBool(false)
    )
    when factoryHasCounterPresence:
      restoreFactoryCounterPresence(u, result.usage)

proc assertMessageEqual*(a, b: Message; context = "") =
  ## Discriminating equality for round-trip tests.
  template fail(msg: string) =
    raise newFactoryError(fecValidationFailed, context & msg, phase = "message")
  if a.role != b.role: fail("role mismatch")
  if a.content != b.content: fail("content mismatch")
  if a.toolCallId != b.toolCallId: fail("toolCallId mismatch")
  if a.toolName != b.toolName: fail("toolName mismatch")
  if a.finishReason != b.finishReason: fail("finishReason mismatch")
  if a.images != b.images: fail("images mismatch")
  if a.toolCalls.len != b.toolCalls.len: fail("toolCalls len mismatch")
  for i in 0 ..< a.toolCalls.len:
    if a.toolCalls[i].id != b.toolCalls[i].id or
       a.toolCalls[i].name != b.toolCalls[i].name or
       a.toolCalls[i].arguments != b.toolCalls[i].arguments:
      fail("toolCalls[" & $i & "] mismatch")
  if a.usage.promptTokens != b.usage.promptTokens or
     a.usage.completionTokens != b.usage.completionTokens or
     a.usage.totalTokens != b.usage.totalTokens or
     a.usage.cacheTokens != b.usage.cacheTokens or
     a.usage.reasoningTokens != b.usage.reasoningTokens or
     a.usage.isReported != b.usage.isReported:
    fail("usage mismatch")
  when factoryHasCounterPresence:
    if a.usage.counterPresence != b.usage.counterPresence:
      fail("usage.counterPresence mismatch")
  when factoryHasProtocolParts:
    if a.protocol != b.protocol: fail("protocol mismatch")
    if a.parts != b.parts: fail("parts mismatch")
