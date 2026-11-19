## End-to-end software_fix mission: context → model → apply → verify.
## Shared ceiling: at most two provider calls. Recovery after no-op or
## functional verify failure. Compile errors and missing oracle stay distinct.

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
    injectRecoveryPath*: string ## offline second inject
    recoveryViaApi*: bool   ## after inject first turn, recovery calls planned API
    localModel*: string
    targetFile*: string
    diagnosis*: string
    constraint*: string

  AttemptRecord* = object
    index*: int
    role*: string           ## initial | recovery
    provider*: ProviderCallResult
    decision*: FixDecision
    apply*: ApplyResult
    verify*: VerifyResult
    cannotFix*: bool
    effectiveChange*: bool
    recoveryReason*: string ## noop | functional_fail | ""

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
    attempts*: seq[AttemptRecord]
    providerCalls*: int
    recoveryTriggered*: bool
    recoveryAttempted*: bool
    recoveryReason*: string
    untested*: seq[string]
    warning*: string

proc defaultMissionRequest*(): MissionRequest =
  result.route = "api"
  result.localModel = LocalMicroPatchModel

proc attemptToJson(a: AttemptRecord): JsonNode =
  %*{
    "index": a.index,
    "role": a.role,
    "recovery_reason": a.recoveryReason,
    "provider": providerToJson(a.provider),
    "decision": decisionToJson(a.decision),
    "apply": applyToJson(a.apply),
    "verify": verifyToJson(a.verify),
    "cannot_fix": a.cannotFix,
    "effective_change": a.effectiveChange
  }

proc invokeModel(req: MissionRequest; ctx: MissionContext;
                 recoveryInject: bool): ProviderCallResult =
  case req.route
  of "api":
    result = callPlannedApi(ctx)
  of "local":
    result = callLocalMicroPatch(ctx, model = req.localModel)
  of "inject":
    let path =
      if recoveryInject: req.injectRecoveryPath
      else: req.injectPath
    result = callFromInject(path)
  else:
    result.ok = false
    result.available = false
    result.message = "unknown route: " & req.route
    result.status = "failed"

proc invokeRecovery(req: MissionRequest; ctx: MissionContext): ProviderCallResult =
  if req.route == "api" or req.recoveryViaApi:
    result = callPlannedApi(ctx)
  elif req.route == "inject" and req.injectRecoveryPath.len > 0:
    result = callFromInject(req.injectRecoveryPath)
  else:
    result.ok = false
    result.available = false
    result.message = "no recovery provider configured"
    result.status = "failed"

proc canUseRecoveryProvider(req: MissionRequest): bool =
  req.route == "api" or req.recoveryViaApi or
    (req.route == "inject" and req.injectRecoveryPath.len > 0)

proc runRecovery(report: var MissionReport; req: MissionRequest;
                 prior: AttemptRecord; reason, finding: string) =
  report.recoveryTriggered = true
  report.recoveryReason = reason
  var recovery: AttemptRecord
  recovery.index = 2
  recovery.role = "recovery"
  recovery.recoveryReason = reason
  let recoveryCtx = buildRecoveryContext(
    report.context,
    prior.decision.targetFile,
    prior.decision.decision,
    prior.decision.patchedContent,
    finding)
  recovery.provider = invokeRecovery(req, recoveryCtx)
  report.providerCalls += 1
  report.recoveryAttempted = true
  report.provider = recovery.provider

  if not recovery.provider.ok:
    report.ok = false
    report.verdict = "model_failed"
    report.warning = "recovery call failed: " & recovery.provider.message
    if req.recoveryViaApi and not recovery.provider.available:
      report.verdict = "api_unavailable"
      report.warning =
        "Quentin: planned OpenAI API unavailable on recovery (" &
        recovery.provider.message & "). Live recovery untested."
      report.untested.add("noop_or_verify recovery via API")
    report.attempts.add(recovery)
    return

  let cannot = parseCannotFix(recovery.provider.rawText)
  if cannot.hit:
    recovery.cannotFix = true
    recovery.decision.decision = cannot.decision
    recovery.decision.parseOk = true
    report.decision = recovery.decision
    report.ok = false
    report.verdict = "model_cannot_fix"
    report.warning = cannot.decision
    report.attempts.add(recovery)
    return

  recovery.decision = parseFixDecision(recovery.provider.rawText)
  report.decision = recovery.decision
  recovery.apply = applyDecision(req.repoRoot, "", recovery.decision)
  report.apply = recovery.apply
  if not recovery.apply.ok:
    report.ok = false
    report.verdict = "apply_failed"
    report.warning = "recovery apply: " & recovery.apply.message
    report.attempts.add(recovery)
    return

  recovery.effectiveChange = true
  recovery.verify = runOracle(recovery.apply.worktree, req.oracleDir)
  report.verify = recovery.verify
  report.componentAttribution["verify"] = %*("nimfactory.mission.verify + " & req.oracleDir)
  if recovery.verify.ok:
    report.ok = true
    report.verdict = "pass"
  else:
    report.ok = false
    case recovery.verify.kind
    of vkCompileError:
      report.verdict = "compile_failed"
    of vkFunctionalFail:
      report.verdict = "verify_failed"
    of vkOracleMissing:
      report.verdict = "oracle_missing"
    of vkLaunchError:
      report.verdict = "oracle_launch_failed"
    else:
      report.verdict = "verify_failed"
    report.warning = recovery.verify.message
  report.attempts.add(recovery)

proc runMission*(req: MissionRequest): MissionReport =
  result.route = req.route
  result.componentAttribution = newJObject()
  result.untested = @[]
  result.attempts = @[]
  result.providerCalls = 0

  let oracleCheck = resolveOracleEntry(req.oracleDir)
  if not oracleCheck.ok:
    result.ok = false
    result.verdict = "oracle_missing"
    result.warning = oracleCheck.message
    result.verify.kind = vkOracleMissing
    result.verify.message = oracleCheck.message
    result.verify.stderr = oracleCheck.message
    result.verify.ok = false
    result.verify.exitCode = 2
    return

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

  var attempt: AttemptRecord
  attempt.index = 1
  attempt.role = "initial"
  case req.route
  of "api":
    result.componentAttribution["model"] = %*(PlannedApiProvider & "/" & PlannedApiModel)
  of "local":
    result.componentAttribution["model"] = %*("ollama/" & req.localModel)
  of "inject":
    result.componentAttribution["model"] = %*"inject (non-qualifying for LLM)"
    if req.recoveryViaApi:
      result.componentAttribution["recovery_model"] =
        %*(PlannedApiProvider & "/" & PlannedApiModel)
  else:
    result.ok = false
    result.verdict = "invalid_route"
    result.warning = "unknown route: " & req.route
    return

  attempt.provider = invokeModel(req, result.context, recoveryInject = false)
  result.providerCalls += 1
  result.provider = attempt.provider
  result.componentAttribution["provider_adapter"] = %*"nimfactory.mission.provider"

  if req.route == "api" and not attempt.provider.available:
    result.ok = false
    result.verdict = "api_unavailable"
    result.warning =
      "Quentin: planned OpenAI API unavailable (" & attempt.provider.message &
      "). Untested: live software_fix + recovery via API."
    result.untested = @[
      "callPlannedApi/live",
      "recovery via API",
      "parseFixDecision on API text",
      "applyDecision from API patch",
      "runOracle after API patch"
    ]
    result.attempts.add(attempt)
    return

  if not attempt.provider.ok:
    result.ok = false
    result.verdict = "model_failed"
    result.warning = attempt.provider.message
    result.attempts.add(attempt)
    return

  attempt.decision = parseFixDecision(attempt.provider.rawText)
  result.decision = attempt.decision
  result.componentAttribution["parse_apply"] = %*"nimfactory.mission.apply"
  attempt.apply = applyDecision(req.repoRoot, req.worktreeRoot, attempt.decision)
  result.apply = attempt.apply

  if attempt.apply.ok:
    attempt.effectiveChange = true
    attempt.verify = runOracle(attempt.apply.worktree, req.oracleDir)
    result.verify = attempt.verify
    result.componentAttribution["verify"] = %*("nimfactory.mission.verify + " & req.oracleDir)
    if attempt.verify.ok:
      result.ok = true
      result.verdict = "pass"
      result.attempts.add(attempt)
      return

    # Applied but reception failed — classify before considering recovery.
    case attempt.verify.kind
    of vkCompileError:
      result.ok = false
      result.verdict = "compile_failed"
      result.warning = attempt.verify.message
      result.attempts.add(attempt)
      return
    of vkOracleMissing:
      result.ok = false
      result.verdict = "oracle_missing"
      result.warning = attempt.verify.message
      result.attempts.add(attempt)
      return
    of vkLaunchError:
      result.ok = false
      result.verdict = "oracle_launch_failed"
      result.warning = attempt.verify.message
      result.attempts.add(attempt)
      return
    of vkFunctionalFail:
      ## Only a launched functional failure authorizes recovery.
      if canUseRecoveryProvider(req):
        result.attempts.add(attempt)
        runRecovery(result, req, attempt, "functional_fail",
          "patch applied and compiled, but the functional check still fails")
        return
      result.ok = false
      result.verdict = "verify_failed"
      result.warning = attempt.verify.message
      result.attempts.add(attempt)
      return
    of vkOther:
      result.ok = false
      result.verdict = "verify_failed"
      result.warning = attempt.verify.message
      result.attempts.add(attempt)
      return
    of vkPass:
      discard

  # Apply failed path: only identical-to-original is recoverable.
  if attempt.apply.identicalToOriginal and canUseRecoveryProvider(req):
    result.attempts.add(attempt)
    runRecovery(result, req, attempt, "noop",
      "proposed content identical to the original")
    return

  result.ok = false
  result.verdict = "apply_failed"
  result.warning = attempt.apply.message
  result.attempts.add(attempt)

proc reportToJson*(r: MissionReport): JsonNode =
  var attempts = newJArray()
  for a in r.attempts:
    attempts.add(attemptToJson(a))
  %*{
    "ok": r.ok,
    "verdict": r.verdict,
    "route": r.route,
    "warning": r.warning,
    "untested": r.untested,
    "provider_calls": r.providerCalls,
    "recovery_triggered": r.recoveryTriggered,
    "recovery_attempted": r.recoveryAttempted,
    "recovery_reason": r.recoveryReason,
    "attempts": attempts,
    "component_attribution": r.componentAttribution,
    "context": contextToJson(r.context),
    "provider": providerToJson(r.provider),
    "decision": decisionToJson(r.decision),
    "apply": applyToJson(r.apply),
    "verify": verifyToJson(r.verify)
  }
