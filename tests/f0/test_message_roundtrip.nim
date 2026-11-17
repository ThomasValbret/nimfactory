import std/[json, strutils]
import nimfactory
import nimagent/messages

block accentsAndNulls:
  var m = userMsg("Café naïve — « guillemets » et résumé")
  m.finishReason = ""
  m.usage = TokenUsage(promptTokens: 1, completionTokens: 0, totalTokens: 1,
                       cacheTokens: 0, reasoningTokens: 0, isReported: true)
  let j = messageToFactoryJson(m)
  let back = messageFromFactoryJson(j)
  assertMessageEqual(m, back, "accents: ")

block toolCallsAndUsage:
  var m = assistantMsg("ok", @[ToolCall(id: "c1", name: "lookup",
                                        arguments: "{\"q\":\"été\"}")])
  m.finishReason = "tool_calls"
  m.usage = TokenUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15,
                       cacheTokens: 2, reasoningTokens: 3, isReported: true)
  let back = messageFromFactoryJson(messageToFactoryJson(m))
  assertMessageEqual(m, back, "tools: ")

block attemptVsRetransmit:
  let retransmit = envelopeFromJson(parseJson("""{
    "factory": {
      "schema": "nimfactory.meta/0.1",
      "message_id": "msg-same",
      "run_id": "run-1",
      "activation_id": "act-1",
      "attempt_id": "try-1",
      "epoch": 1,
      "correlation_id": "c1",
      "causation_id": null,
      "payload_schema": "nimfactory.result/0.1",
      "extensions": {},
      "is_retransmission": true
    },
    "message": {
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
    }
  }"""))
  let newAttempt = envelopeFromJson(parseJson("""{
    "factory": {
      "schema": "nimfactory.meta/0.1",
      "message_id": "msg-new",
      "run_id": "run-1",
      "activation_id": "act-1",
      "attempt_id": "try-2",
      "epoch": 1,
      "correlation_id": "c1",
      "causation_id": "msg-same",
      "payload_schema": "nimfactory.result/0.1",
      "extensions": {},
      "is_retransmission": false
    },
    "message": {
      "role": "Assistant",
      "content": "retry",
      "toolCallId": "",
      "toolName": "",
      "finishReason": "stop",
      "images": [],
      "toolCalls": [],
      "usage": {
        "promptTokens": 2, "completionTokens": 2, "totalTokens": 4,
        "cacheTokens": 0, "reasoningTokens": 0, "isReported": true
      }
    }
  }"""))
  doAssert retransmit.factory.isRetransmission
  doAssert retransmit.factory.messageId == "msg-same"
  doAssert retransmit.factory.attemptId == "try-1"
  doAssert not newAttempt.factory.isRetransmission
  doAssert newAttempt.factory.attemptId == "try-2"
  doAssert newAttempt.factory.messageId != retransmit.factory.messageId
  # Same activation, different attempt => new attempt, not retransmission
  doAssert newAttempt.factory.activationId == retransmit.factory.activationId

block envelopeRoundtrip:
  var env: FactoryEnvelope
  env.factory = defaultMeta()
  env.factory.messageId = "msg-rt"
  env.factory.runId = "run-rt"
  env.factory.activationId = "act-rt"
  env.factory.attemptId = "try-rt"
  env.factory.payloadSchema = ResultSchema
  env.message = userMsg("ping")
  env.payload = resultToJson(defaultResult(rsOk))
  let back = envelopeFromJson(envelopeToJson(env))
  doAssert back.factory.messageId == "msg-rt"
  assertMessageEqual(env.message, back.message, "envelope: ")

echo "test_message_roundtrip: ok"
