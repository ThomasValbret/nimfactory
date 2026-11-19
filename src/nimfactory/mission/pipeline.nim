## End-to-end software_fix mission: context → model → apply → verify.
## API route: one no-op recovery turn when proposed content equals the original.

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
    injectRecoveryPath*: string ## offline: second inject after no-op
    localModel*: string
    targetFile*: string
    diagnosis*: string
    constraint*: string

  AttemptRecord* = object
    index*: int
    role*: string           ## initial | noop_recovery
    provider*: ProviderCallResult
    decision*: FixDecision
    apply*: ApplyResult
    verify*: VerifyResult
    cannotFix*: bool
    effectiveChange*: bool

  MissionReport* = object
    ok*: bool
    verdict*: string
    route*: string
    componentAttribution*: JsonNode
    context*: MissionContext
    provider*: ProviderCallResult   ## last provider call (compat)
    decision*: FixDecision          ## last decision (compat)
    apply*: ApplyResult             ## last apply (compat)
    verify*: VerifyResult           ## last verify (compat)
    attempts*: seq[AttemptRecord]
    providerCalls*: int
    recoveryTriggered*: bool
    recoveryAttempted*: bool
    untested*: seq[string]
    warning*: string

proc defaultMissionRequest*(): MissionRequest =
  result.route = "api"
  result.localModel = LocalMicroPatchModel

proc attemptToJson(a: AttemptRecord): JsonNode =
  %*{
    "index": a.index,
    "role": a.role,
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

proc finishVerify(report: var MissionReport; req: MissionRequest;
                  attempt: var AttemptRecord) =
  attempt.verify = runOracle(attempt.apply.worktree, req.oracleDir)
  report.verify = attempt.verify
  report.componentAttribution["verify"] = %*("nimfactory.mission.verify + " & req.oracleDir)
  if attempt.verify.ok:
    report.ok = true
    report.verdict = "pass"
  else:
    report.ok = false
    report.verdict = "verify_failed"
    report.warning =
      if attempt.verify.message.len > 0: attempt.verify.message
      else: "reception tests failed after applying model patch"

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

  # --- Initial model call ---
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
      "). Untested: live software_fix intervention choice via API (incl. no-op recovery)."
    result.untested = @[
      "callPlannedApi/live",
      "noop_recovery via API",
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
    finishVerify(result, req, attempt)
    result.attempts.add(attempt)
    # Success on first attempt: no recovery call.
    return

  # --- Single no-op recovery (API always; inject when recovery path provided) ---
  let canRecover =
    attempt.apply.identicalToOriginal and
    (req.route == "api" or
     (req.route == "inject" and req.injectRecoveryPath.len > 0))

  if not canRecover:
    result.ok = false
    result.verdict = "apply_failed"
    result.warning = attempt.apply.message
    result.attempts.add(attempt)
    return

  result.recoveryTriggered = true
  result.attempts.add(attempt)

  var recovery: AttemptRecord
  recovery.index = 2
  recovery.role = "noop_recovery"
  let recoveryCtx = buildNoOpRecoveryContext(result.context, attempt.decision.targetFile)
  if req.route == "api":
    recovery.provider = callPlannedApi(recoveryCtx)
  else:
    recovery.provider = callFromInject(req.injectRecoveryPath)
  result.providerCalls += 1
  result.recoveryAttempted = true
  result.provider = recovery.provider

  if not recovery.provider.ok:
    result.ok = false
    result.verdict = "model_failed"
    result.warning = "noop recovery call failed: " & recovery.provider.message
    result.attempts.add(recovery)
    return

  let cannot = parseCannotFix(recovery.provider.rawText)
  if cannot.hit:
    recovery.cannotFix = true
    recovery.decision.decision = cannot.decision
    recovery.decision.parseOk = true
    result.decision = recovery.decision
    result.ok = false
    result.verdict = "model_cannot_fix"
    result.warning = cannot.decision
    result.attempts.add(recovery)
    return

  recovery.decision = parseFixDecision(recovery.provider.rawText)
  result.decision = recovery.decision
  # Fresh worktree: never reuse the (possibly user-provided) occupied path.
  recovery.apply = applyDecision(req.repoRoot, "", recovery.decision)
  result.apply = recovery.apply

  if not recovery.apply.ok:
    result.ok = false
    result.verdict = "apply_failed"
    result.warning = "noop recovery apply: " & recovery.apply.message
    result.attempts.add(recovery)
    return

  recovery.effectiveChange = true
  finishVerify(result, req, recovery)
  result.attempts.add(recovery)

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
    "attempts": attempts,
    "component_attribution": r.componentAttribution,
    "context": contextToJson(r.context),
    "provider": providerToJson(r.provider),
    "decision": decisionToJson(r.decision),
    "apply": applyToJson(r.apply),
    "verify": verifyToJson(r.verify)
  }
