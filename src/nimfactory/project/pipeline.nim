## Project CLI journey: ask → revise → step → status/resume.

import std/[os, json, tables, sequtils]
import nimfactory/mission/[provider, apply, context]
import ./types
import ./store
import ./plan_context
import ./verify

type
  ProjectRoute* = enum
    prApi = "api"
    prInject = "inject"

  ProjectCommand* = enum
    pcAsk = "ask"
    pcRevise = "revise"
    pcStep = "step"
    pcStatus = "status"
    pcResume = "resume"

  ProjectRequest* = object
    storePath*: string
    projectId*: string
    cwd*: string
    objective*: string
    refinement*: string
    route*: string              ## api | inject
    injectPath*: string
    worktree*: string
    artifactDir*: string        ## optional: write plan/mandate/diff here

  ProjectReport* = object
    ok*: bool
    command*: string
    projectId*: string
    verdict*: string
    message*: string
    doc*: ProjectDoc
    provider*: ProviderCallResult
    verify*: ProjectVerifyResult
    apply*: ApplyResult
    mandatePath*: string
    untested*: seq[string]
    report*: JsonNode

proc defaultProjectRequest*(): ProjectRequest =
  result.route = "api"
  result.projectId = "demo_tasks_cli"

proc ensureUsage(doc: var ProjectDoc; role: string) =
  if role notin doc.usageByRole:
    doc.usageByRole[role] = emptyUsage()

proc recordUsage(doc: var ProjectDoc; role: string; p: ProviderCallResult) =
  ensureUsage(doc, role)
  if p.route == "inject":
    # inject: zero billable
    discard
  elif p.usageReported:
    addUsage(doc.usageByRole[role], p.promptTokens, p.completionTokens, p.model)
  else:
    # call happened but usage unknown — still count the call
    var u = doc.usageByRole[role]
    u.calls += 1
    if p.model.len > 0: u.model = p.model
    doc.usageByRole[role] = u

proc invokeProjectModel(req: ProjectRequest; systemPrompt, userPrompt: string): ProviderCallResult =
  case req.route
  of "api":
    var ctx = MissionContext(
      route: "api",
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      ok: true
    )
    result = callPlannedApi(ctx)
  of "inject":
    if req.injectPath.len == 0:
      result.ok = false
      result.available = false
      result.message = "inject route requires --inject"
      result.status = "failed"
      return
    result = callFromInject(req.injectPath)
  else:
    result.ok = false
    result.available = false
    result.message = "unknown route: " & req.route
    result.status = "failed"

proc parsePlanPayload(raw: string): tuple[ok: bool; node: JsonNode; err: string] =
  try:
    let extracted = extractJsonObject(raw)
    let node = parseJson(extracted)
    if node.kind != JObject:
      return (false, newJObject(), "plan payload is not an object")
    (true, node, "")
  except CatchableError as e:
    (false, newJObject(), e.msg)

proc stepsFromPlanNode(node: JsonNode; mandateKey: string): seq[ProjectStep] =
  result = @[]
  let arr = node{"steps"}
  if arr.isNil or arr.kind != JArray:
    return
  var i = 0
  for s in arr:
    inc i
    var st = stepFromJson(s)
    if st.id.len == 0:
      st.id = "step_" & $i
    if st.title.len == 0:
      st.title = st.id
    st.status = ssPending
    st.mandateKey = mandateKey
    if st.result.isNil: st.result = newJObject()
    result.add(st)

proc writeArtifact(dir, name, body: string): string =
  if dir.len == 0:
    return ""
  createDir(dir)
  let path = dir / name
  writeFile(path, body)
  path

proc usageTableJson(doc: ProjectDoc): JsonNode =
  result = newJObject()
  for k, v in doc.usageByRole:
    result[k] = usageToJson(v)

proc reportBase(cmd: string; doc: ProjectDoc): JsonNode =
  %*{
    "command": "project",
    "sub": cmd,
    "project_id": doc.projectId,
    "cwd": doc.cwd,
    "objective": doc.objective,
    "refinements": doc.refinements,
    "current_plan_version": doc.currentPlanVersion,
    "next_action": doc.nextAction,
    "worktree": doc.worktree,
    "last_verdict": doc.lastVerdict,
    "usage_by_role": usageTableJson(doc),
    "steps": doc.steps.mapIt(stepToJson(it)),
    "plan_versions": doc.planVersions.mapIt(planToJson(it))
  }

proc depsSatisfied(doc: ProjectDoc; step: ProjectStep): bool =
  for d in step.dependsOn:
    var found = false
    for s in doc.steps:
      if s.id == d:
        found = true
        if s.status != ssDone:
          return false
    if not found:
      return false
  true

proc projectAsk*(req: ProjectRequest): ProjectReport =
  result.command = "ask"
  result.projectId = req.projectId
  result.untested = @[]
  if req.storePath.len == 0 or req.cwd.len == 0:
    result.ok = false
    result.verdict = "invalid"
    result.message = "ask requires --store and --cwd"
    return
  if req.objective.len == 0:
    result.ok = false
    result.verdict = "invalid"
    result.message = "ask requires --objective (or positional text)"
    return
  let cwd = absolutePath(req.cwd)
  if not dirExists(cwd):
    result.ok = false
    result.verdict = "invalid"
    result.message = "cwd not found: " & cwd
    return

  var doc = newProjectDoc(req.projectId, cwd, req.objective)
  let ctx = buildAskContext(cwd, req.objective)
  if not ctx.ok:
    result.ok = false
    result.verdict = "context_failed"
    result.message = ctx.error
    result.doc = doc
    return

  result.provider = invokeProjectModel(req, ctx.systemPrompt, ctx.userPrompt)
  if req.route == "inject":
    result.untested.add("planner model decision (inject)")
  if not result.provider.ok:
    result.ok = false
    result.verdict = if not result.provider.available: "api_unavailable" else: "model_failed"
    result.message = result.provider.message
    result.doc = doc
    return

  let parsed = parsePlanPayload(result.provider.rawText)
  if not parsed.ok:
    result.ok = false
    result.verdict = "parse_failed"
    result.message = parsed.err
    result.doc = doc
    return

  let mandateKey = "mandate_v1"
  var plan = PlanVersion(
    version: 1,
    summary: parsed.node{"summary"}.getStr,
    hypothesis: parsed.node{"hypothesis"}.getStr,
    raw: parsed.node,
    steps: stepsFromPlanNode(parsed.node, mandateKey)
  )
  if plan.steps.len == 0:
    # synthesize a single pending step from mandate sketch
    plan.steps = @[ProjectStep(
      id: "implement_export",
      title: "Implémenter l'export demandé",
      dependsOn: @[],
      status: ssPending,
      mandateKey: mandateKey,
      result: newJObject()
    )]

  doc.planVersions = @[plan]
  doc.currentPlanVersion = 1
  doc.steps = plan.steps
  var mandate = parsed.node{"mandate_sketch"}
  if mandate.isNil or mandate.kind != JObject:
    mandate = %*{
      "goal": req.objective,
      "constraints": ["respecter AGENTS.md"],
      "files_likely": ctx.sourceIds
    }
  mandate["plan_version"] = %1
  mandate["agents_md_excerpt"] = %ctx.agentsMd
  mandate["source_ids"] = %ctx.sourceIds
  doc.mandates = newJObject()
  doc.mandates[mandateKey] = mandate
  recordUsage(doc, "planner", result.provider)
  doc.nextAction = "revise_or_step"
  doc.lastVerdict = "plan_v1"

  let store = openProjectStore(req.storePath)
  defer: closeProjectStore(store)
  saveProject(store, doc)
  emitProjectEvent(store, doc.projectId, "project.ask", %*{
    "plan_version": 1,
    "summary": plan.summary,
    "steps": plan.steps.len,
    "route": result.provider.route,
    "model": result.provider.model
  })

  let planPath = writeArtifact(req.artifactDir, "plan_v1.json", pretty(parsed.node))
  let manPath = writeArtifact(req.artifactDir, "mandate_v1.json", pretty(mandate))
  result.mandatePath = manPath
  result.doc = doc
  result.ok = true
  result.verdict = "plan_ready"
  result.message = "plan v1 persisted"
  result.report = reportBase("ask", doc)
  result.report["provider"] = providerToJson(result.provider)
  result.report["artifacts"] = %*{"plan": planPath, "mandate": manPath}
  if result.untested.len > 0:
    result.report["untested"] = %result.untested

proc projectRevise*(req: ProjectRequest): ProjectReport =
  result.command = "revise"
  result.projectId = req.projectId
  result.untested = @[]
  if req.storePath.len == 0:
    result.ok = false
    result.verdict = "invalid"
    result.message = "revise requires --store"
    return
  if req.refinement.len == 0:
    result.ok = false
    result.verdict = "invalid"
    result.message = "revise requires --refinement"
    return

  let store = openProjectStore(req.storePath)
  defer: closeProjectStore(store)
  let loaded = loadProject(store, req.projectId)
  if not loaded.ok:
    result.ok = false
    result.verdict = "missing"
    result.message = loaded.err
    return
  var doc = loaded.doc
  doc.refinements.add(req.refinement)

  let prior = currentPlan(doc)
  let priorJson = pretty(if prior.raw.isNil: newJObject() else: prior.raw)
  let ctx = buildReviseContext(doc.cwd, doc.objective, doc.refinements, priorJson)
  result.provider = invokeProjectModel(req, ctx.systemPrompt, ctx.userPrompt)
  if req.route == "inject":
    result.untested.add("reviser model decision (inject)")
  if not result.provider.ok:
    result.ok = false
    result.verdict = if not result.provider.available: "api_unavailable" else: "model_failed"
    result.message = result.provider.message
    result.doc = doc
    saveProject(store, doc)  # keep refinement even if model fails? better not half-state
    # Actually revert refinement on failure — reload would be cleaner; leave refinement recorded
    # but don't bump plan. Persist refinements so resume sees them.
    saveProject(store, doc)
    return

  let parsed = parsePlanPayload(result.provider.rawText)
  if not parsed.ok:
    result.ok = false
    result.verdict = "parse_failed"
    result.message = parsed.err
    result.doc = doc
    saveProject(store, doc)
    return

  let newVersion = doc.currentPlanVersion + 1
  let mandateKey = "mandate_v" & $newVersion
  var plan = PlanVersion(
    version: newVersion,
    summary: parsed.node{"summary"}.getStr,
    hypothesis: parsed.node{"hypothesis"}.getStr,
    raw: parsed.node,
    steps: stepsFromPlanNode(parsed.node, mandateKey)
  )
  if plan.steps.len == 0:
    plan.steps = @[ProjectStep(
      id: "implement_export",
      title: "Implémenter export CSV opt-in",
      dependsOn: @[],
      status: ssPending,
      mandateKey: mandateKey,
      result: newJObject()
    )]

  # Preserve done steps by id when revising mid-flight
  var doneIds = initTable[string, ProjectStep]()
  for s in doc.steps:
    if s.status == ssDone:
      doneIds[s.id] = s
  for i, s in plan.steps.mpairs:
    if s.id in doneIds:
      plan.steps[i].status = ssDone
      plan.steps[i].result = doneIds[s.id].result

  doc.planVersions.add(plan)
  doc.currentPlanVersion = newVersion
  doc.steps = plan.steps
  var mandate = parsed.node{"mandate_sketch"}
  if mandate.isNil or mandate.kind != JObject:
    mandate = %*{
      "goal": doc.objective,
      "refinement": req.refinement,
      "constraints": [
        "CSV sur stdout via commande opt-in",
        "garder l'affichage list par défaut"
      ],
      "files_likely": ctx.sourceIds
    }
  mandate["plan_version"] = %newVersion
  mandate["change_notes"] = %parsed.node{"change_notes"}.getStr
  mandate["agents_md_excerpt"] = %ctx.agentsMd
  mandate["source_ids"] = %ctx.sourceIds
  mandate["refinement"] = %req.refinement
  if doc.mandates.isNil: doc.mandates = newJObject()
  doc.mandates[mandateKey] = mandate
  recordUsage(doc, "reviser", result.provider)
  doc.nextAction = "step"
  doc.lastVerdict = "plan_v" & $newVersion

  saveProject(store, doc)
  emitProjectEvent(store, doc.projectId, "project.revise", %*{
    "plan_version": newVersion,
    "summary": plan.summary,
    "refinement": req.refinement,
    "route": result.provider.route
  })

  let planPath = writeArtifact(req.artifactDir, "plan_v" & $newVersion & ".json", pretty(parsed.node))
  let manPath = writeArtifact(req.artifactDir, "mandate_v" & $newVersion & ".json", pretty(mandate))
  result.mandatePath = manPath
  result.doc = doc
  result.ok = true
  result.verdict = "plan_revised"
  result.message = "plan v" & $newVersion & " persisted"
  result.report = reportBase("revise", doc)
  result.report["provider"] = providerToJson(result.provider)
  result.report["artifacts"] = %*{"plan": planPath, "mandate": manPath}
  if result.untested.len > 0:
    result.report["untested"] = %result.untested

proc projectStep*(req: ProjectRequest): ProjectReport =
  result.command = "step"
  result.projectId = req.projectId
  result.untested = @[]
  if req.storePath.len == 0:
    result.ok = false
    result.verdict = "invalid"
    result.message = "step requires --store"
    return

  let store = openProjectStore(req.storePath)
  defer: closeProjectStore(store)
  let loaded = loadProject(store, req.projectId)
  if not loaded.ok:
    result.ok = false
    result.verdict = "missing"
    result.message = loaded.err
    return
  var doc = loaded.doc

  let pending = nextPendingStep(doc)
  if not pending.found:
    result.ok = true
    result.verdict = "nothing_pending"
    result.message = "no pending steps"
    result.doc = doc
    result.report = reportBase("step", doc)
    return

  var step = pending.step
  if not depsSatisfied(doc, step):
    result.ok = false
    result.verdict = "blocked"
    result.message = "dependencies not satisfied for " & step.id
    doc.blockedReason = result.message
    for i, s in doc.steps.mpairs:
      if s.id == step.id: doc.steps[i].status = ssBlocked
    saveProject(store, doc)
    result.doc = doc
    result.report = reportBase("step", doc)
    return

  # mark running
  for i, s in doc.steps.mpairs:
    if s.id == step.id:
      doc.steps[i].status = ssRunning
  saveProject(store, doc)

  var mandate = doc.mandates{step.mandateKey}
  if mandate.isNil or mandate.kind != JObject:
    mandate = %*{
      "goal": doc.objective,
      "step_id": step.id,
      "step_title": step.title,
      "constraints": doc.refinements
    }
  else:
    mandate = mandate.copy()
    mandate["step_id"] = %step.id
    mandate["step_title"] = %step.title

  let manPath = writeArtifact(
    if req.artifactDir.len > 0: req.artifactDir else: doc.cwd / ".nimfactory",
    "mandate.json", pretty(mandate))
  result.mandatePath = manPath
  emitProjectEvent(store, doc.projectId, "project.mandate", %*{
    "step_id": step.id,
    "mandate_key": step.mandateKey,
    "path": manPath
  })

  let ctx = buildImplementContext(doc.cwd, mandate, step.title)
  result.provider = invokeProjectModel(req, ctx.systemPrompt, ctx.userPrompt)
  if req.route == "inject":
    result.untested.add("implementer model decision (inject)")
  recordUsage(doc, "implementer", result.provider)

  if not result.provider.ok:
    result.ok = false
    result.verdict = if not result.provider.available: "api_unavailable" else: "model_failed"
    result.message = result.provider.message
    for i, s in doc.steps.mpairs:
      if s.id == step.id:
        doc.steps[i].status = ssPending
        doc.steps[i].result = %*{"error": result.message}
    doc.nextAction = "step"
    saveProject(store, doc)
    result.doc = doc
    result.report = reportBase("step", doc)
    result.report["provider"] = providerToJson(result.provider)
    return

  let decision = parseFixDecision(result.provider.rawText)
  result.apply = applyDecision(doc.cwd, req.worktree, decision)
  if not result.apply.ok:
    result.ok = false
    result.verdict = "apply_failed"
    result.message = result.apply.message
    for i, s in doc.steps.mpairs:
      if s.id == step.id:
        doc.steps[i].status = ssPending
        doc.steps[i].result = applyToJson(result.apply)
    doc.blockedReason = result.apply.message
    saveProject(store, doc)
    emitProjectEvent(store, doc.projectId, "project.step_apply_failed", applyToJson(result.apply))
    result.doc = doc
    result.report = reportBase("step", doc)
    result.report["provider"] = providerToJson(result.provider)
    result.report["apply"] = applyToJson(result.apply)
    return

  doc.worktree = result.apply.worktree
  result.verify = verifyCsvJourney(result.apply.worktree, doc.cwd)
  let diffNote = "target=" & result.apply.targetFile & " mode=" & result.apply.mode &
                 " edits=" & $result.apply.editsApplied
  doc.lastDiff = diffNote
  discard writeArtifact(req.artifactDir, "last_diff.txt", diffNote & "\n" &
                        "before=" & result.apply.beforeHash & " after=" & result.apply.afterHash)

  if result.verify.ok:
    for i, s in doc.steps.mpairs:
      if s.id == step.id:
        doc.steps[i].status = ssDone
        doc.steps[i].result = %*{
          "verify": verifyToJson(result.verify),
          "apply": applyToJson(result.apply)
        }
    doc.lastVerdict = "step_pass"
    doc.nextAction = if nextPendingStep(doc).found: "step" else: "done"
    doc.blockedReason = ""
    result.ok = true
    result.verdict = "pass"
    result.message = result.verify.message
  else:
    for i, s in doc.steps.mpairs:
      if s.id == step.id:
        doc.steps[i].status = ssPending
        doc.steps[i].result = %*{
          "verify": verifyToJson(result.verify),
          "apply": applyToJson(result.apply)
        }
    doc.lastVerdict = "verify_failed"
    doc.nextAction = "step"
    doc.blockedReason = result.verify.message
    result.ok = false
    result.verdict = "verify_failed"
    result.message = result.verify.message

  saveProject(store, doc)
  emitProjectEvent(store, doc.projectId, "project.step", %*{
    "step_id": step.id,
    "verdict": result.verdict,
    "worktree": doc.worktree,
    "verify": verifyToJson(result.verify)
  })
  discard writeArtifact(req.artifactDir, "verify.json", pretty(verifyToJson(result.verify)))

  result.doc = doc
  result.report = reportBase("step", doc)
  result.report["provider"] = providerToJson(result.provider)
  result.report["apply"] = applyToJson(result.apply)
  result.report["verify"] = verifyToJson(result.verify)
  result.report["mandate_path"] = %manPath
  if result.untested.len > 0:
    result.report["untested"] = %result.untested

proc projectStatus*(req: ProjectRequest): ProjectReport =
  result.command = "status"
  result.projectId = req.projectId
  if req.storePath.len == 0:
    result.ok = false
    result.verdict = "invalid"
    result.message = "status requires --store"
    return
  let store = openProjectStore(req.storePath)
  defer: closeProjectStore(store)
  let loaded = loadProject(store, req.projectId)
  if not loaded.ok:
    result.ok = false
    result.verdict = "missing"
    result.message = loaded.err
    return
  result.doc = loaded.doc
  result.ok = true
  result.verdict = loaded.doc.lastVerdict
  result.message = "status ok"
  result.report = reportBase("status", loaded.doc)
  result.report["mandates"] = loaded.doc.mandates

proc projectResume*(req: ProjectRequest): ProjectReport =
  ## Rehydrate after process death: no planner/reviser calls; report pending work.
  result = projectStatus(req)
  result.command = "resume"
  if not result.ok:
    return
  let pending = nextPendingStep(result.doc)
  result.report["sub"] = %"resume"
  result.report["resume"] = %*{
    "rehydrated": true,
    "planner_calls_this_command": 0,
    "reviser_calls_this_command": 0,
    "pending_step": if pending.found: pending.step.id else: "",
    "billable_plan_calls": 0
  }
  result.verdict = "resumed"
  result.message =
    if pending.found: "resumed; next pending step=" & pending.step.id
    else: "resumed; no pending steps"
  # Emit resume event without mutating usage
  let store = openProjectStore(req.storePath)
  defer: closeProjectStore(store)
  emitProjectEvent(store, result.doc.projectId, "project.resume", result.report["resume"])
