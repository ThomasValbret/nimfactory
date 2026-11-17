## Bidirectional codec between nimagent Message and factory JSON.
## Extends SDK session codec to preserve accents, nulls, cache/reasoning tokens,
## finishReason, and empty optional fields needed for lossless round-trips.

import std/json
import nimagent/messages
import ../../contracts/errors

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
