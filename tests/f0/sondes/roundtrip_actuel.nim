## Compare the same current Message through the SDK and the historical consumer.
import std/[json, options, os]
import nimagent/messages
import nimagent/memory/session
import nimfactory/adapters/nimagent/message_codec

let usage = TokenUsage(isReported: true, counterPresence: some({ucInput}),
                       promptTokens: 0)
var original = assistantMsg("ab", @[ToolCall(id: "call", name: "inspect",
                                             arguments: "{}")], usage)
original.protocol = "anthropic.messages"
original.parts = @[MessagePart(kind: pkText, offset: 0, length: 1),
                   MessagePart(kind: pkTool, offset: 0),
                   MessagePart(kind: pkText, offset: 1, length: 1)]

let restored = case paramStr(1)
  of "sdk": messageFromJson(messageToJson(original))
  of "factory": messageFromFactoryJson(messageToFactoryJson(original))
  else: quit("usage: roundtrip_actuel sdk|factory", 64)

let payload = restored.role == original.role and restored.content == original.content and
              restored.toolCalls == original.toolCalls and restored.usage.isReported and
              restored.usage.promptTokens == original.usage.promptTokens
let protocol = restored.protocol == original.protocol
let parts = restored.parts == original.parts
let counters = restored.usage.counterPresence == original.usage.counterPresence
echo $(%*{"payload": payload, "protocol": protocol, "parts": parts,
          "counterPresence": counters})
if not (payload and protocol and parts and counters):
  quit(1)
