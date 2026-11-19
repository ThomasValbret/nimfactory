## Provider binding for the software_fix role (planned API + local micro-patch).

import std/[os, json]
import nimagent
import ./context

proc silenceAgentConsole() =
  ## Keep machine-mode CLI stdout JSON-only.
  enableConsoleLog = false
  setLogLevel(lvlError)

type
  ProviderCallResult* = object
    ok*: bool
    available*: bool
    route*: string
    model*: string
    providerKind*: string
    rawText*: string
    status*: string
    code*: string
    message*: string
    promptTokens*: int
    completionTokens*: int
    usageReported*: bool
    costKnown*: bool
    costNote*: string

const
  PlannedApiModel* = "gpt-4o-mini"
  PlannedApiProvider* = "openai"
  LocalMicroPatchModel* = "qwen2.5-coder:7b"

proc openaiKeyPresent*(): bool =
  getEnv("OPENAI_API_KEY").len > 0

proc callPlannedApi*(ctx: MissionContext): ProviderCallResult =
  ## Planned binding for software_fix: OpenAI gpt-4o-mini via NimAgent.
  result.route = "api"
  result.providerKind = PlannedApiProvider
  result.model = PlannedApiModel
  result.costKnown = false
  result.costNote = "unknown (no usage pricing wired for this mission)"
  if not openaiKeyPresent():
    result.ok = false
    result.available = false
    result.status = "unavailable"
    result.code = "provider_unavailable"
    result.message =
      "OPENAI_API_KEY unset; planned API for software_fix cannot be called"
    return
  try:
    silenceAgentConsole()
    let provider = newOpenAIProvider(model = PlannedApiModel)
    var cfg = defaultConfig()
    cfg.enableTracing = false
    let agent = newAgent(
      provider = provider,
      config = cfg,
      systemPrompt = ctx.systemPrompt
    )
    let reply = agent.runSync(ctx.userPrompt)
    result.available = true
    result.status = $reply.status
    result.code = reply.code
    result.message = reply.message
    result.rawText = reply.text
    result.usageReported = reply.usage.isReported
    if reply.usage.isReported:
      result.promptTokens = reply.usage.promptTokens
      result.completionTokens = reply.usage.completionTokens
    result.ok = reply.status == rsCompleted and reply.text.len > 0
    if not result.ok and result.message.len == 0:
      result.message = "API call did not complete with usable text"
  except CatchableError as e:
    result.ok = false
    result.available = false
    result.status = "failed"
    result.code = "provider_error"
    result.message = e.msg

proc callLocalMicroPatch*(ctx: MissionContext;
                          model = LocalMicroPatchModel;
                          baseUrl = ""): ProviderCallResult =
  ## Local route for the bounded micro-patch sub-mission (dedicated context).
  result.route = "local"
  result.providerKind = "ollama"
  result.model = model
  result.costKnown = true
  result.costNote = "local ollama; provider_cost_microusd = 0"
  let url = if baseUrl.len > 0: baseUrl else: getEnv("OLLAMA_HOST", "http://localhost:11434")
  try:
    silenceAgentConsole()
    let provider = newOllamaProvider(baseUrl = url, model = model, temperature = 0.1)
    var cfg = defaultConfig()
    cfg.enableTracing = false
    let agent = newAgent(
      provider = provider,
      config = cfg,
      systemPrompt = ctx.systemPrompt
    )
    let reply = agent.runSync(ctx.userPrompt)
    result.available = true
    result.status = $reply.status
    result.code = reply.code
    result.message = reply.message
    result.rawText = reply.text
    result.usageReported = reply.usage.isReported
    if reply.usage.isReported:
      result.promptTokens = reply.usage.promptTokens
      result.completionTokens = reply.usage.completionTokens
    result.ok = reply.status == rsCompleted and reply.text.len > 0
    if not result.ok and result.message.len == 0:
      result.message = "local model call did not complete with usable text"
  except CatchableError as e:
    result.ok = false
    result.available = false
    result.status = "failed"
    result.code = "provider_error"
    result.message = e.msg

proc callFromInject*(rawJsonPath: string): ProviderCallResult =
  ## Non-qualifying path: pilot-supplied model text (does NOT exercise LLM).
  result.route = "inject"
  result.providerKind = "inject"
  result.model = "injected"
  result.available = true
  result.costKnown = true
  result.costNote = "no model call"
  result.rawText = readFile(rawJsonPath)
  result.ok = result.rawText.len > 0
  result.status = if result.ok: "rsCompleted" else: "failed"
  result.message = if result.ok: "injected response" else: "empty inject file"

proc providerToJson*(r: ProviderCallResult): JsonNode =
  %*{
    "ok": r.ok,
    "available": r.available,
    "route": r.route,
    "model": r.model,
    "provider_kind": r.providerKind,
    "status": r.status,
    "code": r.code,
    "message": r.message,
    "raw_text": r.rawText,
    "prompt_tokens": r.promptTokens,
    "completion_tokens": r.completionTokens,
    "usage_reported": r.usageReported,
    "cost_known": r.costKnown,
    "cost_note": r.costNote
  }
