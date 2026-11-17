## Budget scope paths, usage normalization, and micro-USD helpers.

import std/[json, strutils]

const
  UsageSchema* = "nimfactory.usage-receipt/0.1"

type
  TokenCounter* = object
    value*: int64
    present*: bool

  UsageReceipt* = object
    inferenceAttemptId*: string
    reservationId*: string
    accountingKind*: string  ## reported | estimated
    inputTokens*: TokenCounter
    outputTokens*: TokenCounter
    cachedTokens*: TokenCounter
    costMicroUsd*: string
    costPresent*: bool
    providerCostMicroUsd*: string
    providerCostPresent*: bool
    localResources*: JsonNode
    role*: string
    obsoleteAttempt*: bool

proc parseBigIntStr*(s: string): int64 =
  if s.len == 0:
    return 0
  parseBiggestInt(s).int64

proc tokenField(j: JsonNode; key: string): TokenCounter =
  if j.isNil or j.kind != JObject or key notin j:
    return TokenCounter(present: false)
  let n = j[key]
  if n.isNil or n.kind == JNull:
    return TokenCounter(present: false)
  if n.kind == JInt:
    return TokenCounter(value: n.getInt, present: true)
  if n.kind == JString:
    return TokenCounter(value: parseBigIntStr(n.getStr), present: true)
  TokenCounter(present: false)

proc optionalAmount(j: JsonNode; key: string): (string, bool) =
  if j.isNil or j.kind != JObject or key notin j:
    return ("", false)
  let n = j[key]
  if n.isNil or n.kind == JNull:
    return ("", false)
  if n.kind == JString:
    return (n.getStr, true)
  if n.kind == JInt:
    return ($n.getInt, true)
  ("", false)

proc usageFromJson*(j: JsonNode): UsageReceipt =
  result.accountingKind = j{"accounting_kind"}.getStr("estimated")
  result.inferenceAttemptId = j{"inference_attempt_id"}.getStr("")
  result.reservationId = j{"reservation_id"}.getStr("")
  result.inputTokens = tokenField(j, "input_tokens")
  result.outputTokens = tokenField(j, "output_tokens")
  result.cachedTokens = tokenField(j, "cached_tokens")
  let (c, cp) = optionalAmount(j, "cost_microusd")
  result.costMicroUsd = c
  result.costPresent = cp
  let (pc, pcp) = optionalAmount(j, "provider_cost_microusd")
  result.providerCostMicroUsd = pc
  result.providerCostPresent = pcp
  if "local_resources" in j and j["local_resources"].kind != JNull:
    result.localResources = j["local_resources"]
  else:
    result.localResources = newJNull()
  result.role = j{"role"}.getStr("")
  result.obsoleteAttempt = j{"obsolete_attempt"}.getBool(false)

proc effectiveCostMicroUsd*(u: UsageReceipt): (string, bool) =
  if u.costPresent:
    return (u.costMicroUsd, true)
  if u.providerCostPresent:
    return (u.providerCostMicroUsd, true)
  ("", false)

proc usageToJson*(u: UsageReceipt): JsonNode =
  var j = %*{
    "schema": UsageSchema,
    "accounting_kind": u.accountingKind,
    "inference_attempt_id": u.inferenceAttemptId,
    "reservation_id": u.reservationId,
    "obsolete_attempt": u.obsoleteAttempt
  }
  if u.inputTokens.present:
    j["input_tokens"] = %u.inputTokens.value
  if u.outputTokens.present:
    j["output_tokens"] = %u.outputTokens.value
  if u.cachedTokens.present:
    j["cached_tokens"] = %u.cachedTokens.value
  if u.costPresent:
    j["cost_microusd"] = %u.costMicroUsd
  if u.providerCostPresent:
    j["provider_cost_microusd"] = %u.providerCostMicroUsd
  if u.localResources.kind != JNull:
    j["local_resources"] = u.localResources
  if u.role.len > 0:
    j["role"] = %u.role
  j

proc scopeChain*(leafScope: string): seq[string] =
  ## Nested scopes: project/run/prep/task -> prefixes at each level.
  var parts: seq[string] = @[]
  for p in leafScope.split('/'):
    if p.len > 0:
      parts.add(p)
  if parts.len == 0:
    return @[leafScope]
  result = @[]
  var acc = ""
  for i, p in parts:
    if i == 0:
      acc = p
    else:
      acc = acc & "/" & p
    result.add(acc)