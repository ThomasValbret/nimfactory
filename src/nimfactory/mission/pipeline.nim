## End-to-end software_fix mission: context → model → apply → verify.

import std/[os, json]
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

  # 1. Context (deterministic factory component)
  if req.route == "local":
    result.context = buildLocalMicroPatchContext(req.repoRoot, req.symptomPath)
  else:
    # api and inject share the API-shaped context package (inject still uses product context)
    result.context = buildApiContext(req.repoRoot, req.symptomPath)
  result.componentAttribution["context"] = %*"nimfactory.mission.context"

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
        "). Untested: live software_fix decision via API, consumption of API " &
        "patched_content under reception tests."
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

  # 3. Parse + apply
  result.decision = parseFixDecision(result.provider.rawText)
  result.componentAttribution["parse_apply"] = %*"nimfactory.mission.apply"
  let wt =
    if req.worktreeRoot.len > 0: req.worktreeRoot
    else: req.repoRoot & ".worktree"
  result.apply = applyDecision(req.repoRoot, wt, result.decision)
  if not result.apply.ok:
    result.ok = false
    result.verdict = "apply_failed"
    result.warning = result.apply.message
    return

  # 4. Verify with external oracle
  let oracle =
    if req.oracleDir.len > 0: req.oracleDir
    else: parentDir(req.repoRoot) / "oracle"
  result.verify = runOracle(wt, oracle)
  result.componentAttribution["verify"] = %*"nimfactory.mission.verify + fixtures/e2e_bugfix/oracle"

  if result.verify.ok:
    result.ok = true
    result.verdict = "pass"
  else:
    result.ok = false
    result.verdict = "verify_failed"
    result.warning = "reception tests failed after applying model patch"

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
