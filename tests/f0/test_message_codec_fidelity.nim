## Fidelity probe recovered from the 2026-11-28 server inventory.
## Against a nimagent that exposes protocol / parts / counterPresence, the
## factory codec must preserve them through JSON round-trip (same contract as
## nimagent/memory/session helpers). Older pins compile this file as a no-op.
import std/[json, options]
import nimagent/messages
import nimfactory/adapters/nimagent/message_codec

const hasExtendedMessage = compiles((
  var m = default(Message)
  discard m.protocol
  discard m.parts
  var u = default(TokenUsage)
  discard u.counterPresence
))

when hasExtendedMessage:
  import nimagent/memory/session

  let usage = TokenUsage(isReported: true, counterPresence: some({ucInput}),
                         promptTokens: 0)
  var original = assistantMsg("ab", @[ToolCall(id: "call", name: "inspect",
                                               arguments: "{}")], usage)
  original.protocol = "anthropic.messages"
  original.parts = @[MessagePart(kind: pkText, offset: 0, length: 1),
                     MessagePart(kind: pkTool, offset: 0),
                     MessagePart(kind: pkText, offset: 1, length: 1)]

  block factoryFidelity:
    let restored = messageFromFactoryJson(messageToFactoryJson(original))
    assertMessageEqual(original, restored, "factory fidelity: ")
    doAssert restored.protocol == original.protocol
    doAssert restored.parts == original.parts
    doAssert restored.usage.counterPresence == original.usage.counterPresence

  block sdkBaselineStillHolds:
    let restored = messageFromJson(messageToJson(original))
    doAssert restored.protocol == original.protocol
    doAssert restored.parts == original.parts
    doAssert restored.usage.counterPresence == original.usage.counterPresence

  block oldRecordReadable:
    ## Records without the new keys keep defaults (backward compatible).
    let legacy = parseJson("""{
      "role": "Assistant",
      "content": "same",
      "toolCallId": "",
      "toolName": "",
      "finishReason": "stop",
      "images": [],
      "toolCalls": [],
      "usage": {
        "promptTokens": 1, "completionTokens": 1, "totalTokens": 2,
        "cacheTokens": 0, "reasoningTokens": 0, "isReported": true
      }
    }""")
    let back = messageFromFactoryJson(legacy)
    doAssert back.protocol.len == 0
    doAssert back.parts.len == 0
    doAssert back.usage.counterPresence.isNone
else:
  echo "skip: linked nimagent lacks protocol/parts/counterPresence"

echo "ok"
