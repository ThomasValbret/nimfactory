## End-to-end software_fix mission: context → model → apply → verify.

import std/[json]
import ./context
import ./provider
import ./apply
import ./verify

type
  MissionRequest* = object
    repoRoot*: string
    symptomPath*: string
    oracleDir*: string
    worktreeRoot*: string
    route*: string          ## api | local | inject
    injectPath*: string
    localModel*: string
    targetFile*: string     ## local micro-patch: established target
    diagnosis*: string      ## local micro-patch: established diagnosis
    constraint*: string     ## local micro-patch: constraint to preserve

  MissionReport* = object
    ok*: bool
    verdict*: string
    route*: string
    componentAttribution*: JsonNode
    context*: MissionContext
    provider*: ProviderCallResult
    decision*: FixDecision
    apply*: ApplyResult
    verify*: VerifyResult
    untested*: seq[string]
    warning*: string

proc defaultMissionRequest*(): MissionRequest =
  result.route = "api"
  result.localModel = LocalMicroPatchModel

proc runMission*(req: MissionRequest): MissionReport =
  result.route = req.route
  result.componentAttribution = newJObject()
  result.untested = @[]

  # 0. Oracle must be resolvable before any model spend / apply.
  let oracleCheck = resolveOracleEntry(req.oracleDir)
  if not oracleCheck.ok:
    result.ok = false
    result.verdict = "oracle_missing"
    result.warning = oracleCheck.message
    result.verify.message = oracleCheck.message
    result.verify.stderr = oracleCheck.message
    result.verify.ok = false
    result.verify.exitCode = 2
    return

  # 1. Context
  if req.route == "local":
    result.context = buildLocalMicroPatchContext(
      req.repoRoot, req.symptomPath, req.targetFile, req.diagnosis, req.constraint)
  else:
    result.context = buildApiContext(req.repoRoot, req.symptomPath)
  result.componentAttribution["context"] = %*"nimfactory.mission.context"
  if not result.context.ok:
    result.ok = false
    result.verdict = "context_failed"
    result.warning = result.context.error
    return

  # 2. Model / inject
  case req.route
  of "api":
    result.provider = callPlannedApi(result.context)
    result.componentAttribution["model"] = %*(PlannedApiProvider & "/" & PlannedApiModel)
    if not result.provider.available:
      result.ok = false
      result.verdict = "api_unavailable"
      result.warning =
        "Quentin: planned OpenAI API unavailable (" & result.provider.message &
        "). Untested: live software_fix intervention choice via API."
      result.untested = @[
        "callPlannedApi/live",
        "parseFixDecision on API text",
        "applyDecision from API patch",
        "runOracle after API patch"
      ]
      return
  of "local":
    result.provider = callLocalMicroPatch(result.context, model = req.localModel)
    result.componentAttribution["model"] = %*("ollama/" & req.localModel)
  of "inject":
    result.provider = callFromInject(req.injectPath)
    result.componentAttribution["model"] = %*"inject (non-qualifying for LLM)"
  else:
    result.ok = false
    result.verdict = "invalid_route"
    result.warning = "unknown route: " & req.route
    return

  result.componentAttribution["provider_adapter"] = %*"nimfactory.mission.provider"

  if not result.provider.ok:
    result.ok = false
    result.verdict = "model_failed"
    result.warning = result.provider.message
    return

  # 3. Parse + apply (safe worktree)
  result.decision = parseFixDecision(result.provider.rawText)
  result.componentAttribution["parse_apply"] = %*"nimfactory.mission.apply"
  result.apply = applyDecision(req.repoRoot, req.worktreeRoot, result.decision)
  if not result.apply.ok:
    result.ok = false
    result.verdict = "apply_failed"
    result.warning = result.apply.message
    return

  # 4. Verify with the oracle directory actually supplied
  result.verify = runOracle(result.apply.worktree, req.oracleDir)
  result.componentAttribution["verify"] = %*("nimfactory.mission.verify + " & req.oracleDir)

  if result.verify.ok:
    result.ok = true
    result.verdict = "pass"
  else:
    result.ok = false
    result.verdict = "verify_failed"
    result.warning =
      if result.verify.message.len > 0: result.verify.message
      else: "reception tests failed after applying model patch"

proc reportToJson*(r: MissionReport): JsonNode =
  %*{
    "ok": r.ok,
    "verdict": r.verdict,
    "route": r.route,
    "warning": r.warning,
    "untested": r.untested,
    "component_attribution": r.componentAttribution,
    "context": contextToJson(r.context),
    "provider": providerToJson(r.provider),
    "decision": decisionToJson(r.decision),
    "apply": applyToJson(r.apply),
    "verify": verifyToJson(r.verify)
  }
