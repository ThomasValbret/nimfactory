## Project CLI journey: ask → revise → step → status/resume.

import std/[os, json, tables, sequtils, strutils, times, algorithm]
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
    discard
  elif p.usageReported:
    addUsage(doc.usageByRole[role], p.promptTokens, p.completionTokens, p.model)
  else:
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

proc validatePlanNode(node: JsonNode): tuple[ok: bool; err: string] =
  ## Explicit planning failure for empty / fabricated-looking payloads.
  ## A bare `{}` has neither summary nor steps → plan_failed.
  if node.isNil or node.kind != JObject:
    return (false, "plan payload is not an object")
  let steps = node{"steps"}
  let hasSteps = steps != nil and steps.kind == JArray and steps.len > 0
  let summary = node{"summary"}.getStr
  if not hasSteps:
    return (false, "empty_plan: steps array missing or empty (no fabricated default)")
  if summary.len == 0 and node.len <= 1:
    ## {} or {"steps":[]} already caught; {"steps":[...]} without summary is ok if steps exist
    discard
  let mandate = node{"mandate_sketch"}
  if mandate.isNil or mandate.kind != JObject:
    return (false, "empty_plan: mandate_sketch object required (no fabricated mandate)")
  if mandate{"goal"}.getStr.len == 0:
    return (false, "empty_plan: mandate_sketch.goal required")
  (true, "")

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
    "accepted_tree_ref": doc.acceptedTreeRef,
    "accepted_tree_hash": doc.acceptedTreeHash,
    "accepted_step_id": doc.acceptedStepId,
    "last_verdict": doc.lastVerdict,
    "last_diff": doc.lastDiff,
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

proc sourceRootForStep(doc: ProjectDoc): string =
  ## Next edits apply on the last accepted tree when present.
  if doc.acceptedTreeRef.len > 0 and dirExists(doc.acceptedTreeRef):
    return doc.acceptedTreeRef
  doc.cwd

proc simpleContentHash(s: string): string =
  ## Stable short fingerprint (not cryptographic).
  var h: uint64 = 14695981039346656037u64
  for c in s:
    h = h xor uint64(ord(c))
    h = h * 1099511628211u64
  toHex(h, 16)

proc treeFingerprint(root: string): string =
  var paths: seq[string] = @[]
  for path in walkDirRec(root):
    if fileExists(path) and ("/nimcache/" notin path.replace('\\', '/')) and
       ("/build/" notin path.replace('\\', '/')):
      paths.add(path)
  paths.sort()
  var acc = ""
  for p in paths:
    let rel = relativePath(p, root).replace('\\', '/')
    acc.add(rel)
    acc.add('\n')
    acc.add(readFile(p))
    acc.add('\n')
  simpleContentHash(acc)

proc copyTree(src, dest: string) =
  if dirExists(dest):
    removeDir(dest)
  createDir(dest)
  for kind, path in walkDir(src):
    let name = path.extractFilename
    if name in ["nimcache", "build", ".git", "inject", ".nimfactory"]:
      continue
    let target = dest / name
    if kind == pcDir:
      copyTree(path, target)
    else:
      copyFile(path, target)

proc readableFileDiff(before, after, rel: string): string =
  var lines: seq[string] = @[]
  lines.add("--- a/" & rel)
  lines.add("+++ b/" & rel)
  let bLines = before.splitLines()
  let aLines = after.splitLines()
  let maxLen = max(bLines.len, aLines.len)
  var i = 0
  while i < maxLen:
    let bl = if i < bLines.len: bLines[i] else: ""
    let al = if i < aLines.len: aLines[i] else: ""
    if bl != al:
      if i < bLines.len: lines.add("-" & bl)
      if i < aLines.len: lines.add("+" & al)
    i += 1
  if lines.len == 2:
    lines.add("(no line changes)")
  lines.join("\n")

proc buildReadableDiff(sourceRoot, worktree, targetFile: string): string =
  let rel = targetFile.replace('\\', '/')
  let srcPath = sourceRoot / rel
  let dstPath = worktree / rel
  if not fileExists(dstPath):
    return "missing after apply: " & rel
  let after = readFile(dstPath)
  if not fileExists(srcPath):
    return "+++ b/" & rel & "\n(new file)\n" & after
  let before = readFile(srcPath)
  if before == after:
    return "unchanged: " & rel
  readableFileDiff(before, after, rel)

proc snapshotAcceptedTree(
    artifactDir, stepId, worktree: string): tuple[path, hash, diffPath: string] =
  let base =
    if artifactDir.len > 0: artifactDir
    else: worktree / ".." / "project_artifacts"
  let dest = absolutePath(base / "trees" / stepId)
  copyTree(worktree, dest)
  let hash = treeFingerprint(dest)
  (dest, hash, "")

proc maybePauseForInterruptTest() =
  ## Real process kill during step: NF_PROJECT_STEP_PAUSE_MS holds after
  ## marking running + provider_attempt=unknown, before the provider call.
  let raw = getEnv("NF_PROJECT_STEP_PAUSE_MS")
  if raw.len == 0: return
  try:
    let ms = parseInt(raw)
    if ms > 0:
      sleep(ms)
  except ValueError:
    discard

proc providerAttemptUnknown(step: ProjectStep): bool =
  let pa = step.result{"provider_attempt"}
  if pa.isNil or pa.kind != JObject: return false
  pa{"status"}.getStr == "unknown"

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

  let validated = validatePlanNode(parsed.node)
  if not validated.ok:
    result.ok = false
    result.verdict = "plan_failed"
    result.message = validated.err
    result.doc = doc
    result.report = reportBase("ask", doc)
    result.report["provider"] = providerToJson(result.provider)
    result.report["plan_payload"] = parsed.node
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
    result.ok = false
    result.verdict = "plan_failed"
    result.message = "empty_plan: no steps after parse"
    result.doc = doc
    return

  doc.planVersions = @[plan]
  doc.currentPlanVersion = 1
  doc.steps = plan.steps
  var mandate = parsed.node{"mandate_sketch"}.copy()
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

  let validated = validatePlanNode(parsed.node)
  if not validated.ok:
    result.ok = false
    result.verdict = "plan_failed"
    result.message = validated.err
    result.doc = doc
    saveProject(store, doc)
    result.report = reportBase("revise", doc)
    result.report["provider"] = providerToJson(result.provider)
    result.report["plan_payload"] = parsed.node
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
    result.ok = false
    result.verdict = "plan_failed"
    result.message = "empty_plan: no steps after parse"
    result.doc = doc
    saveProject(store, doc)
    return

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
  var mandate = parsed.node{"mandate_sketch"}.copy()
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

  let actionable = nextActionableStep(doc)
  if not actionable.found:
    result.ok = true
    result.verdict = "nothing_pending"
    result.message = "no pending steps"
    result.doc = doc
    result.report = reportBase("step", doc)
    return

  var step = actionable.step
  if actionable.kind == "retry" and providerAttemptUnknown(step):
    ## Explicit retry after interrupt: prior provider outcome stayed unknown —
    ## do not treat it as a completed billable success; proceed only because
    ## the user invoked `step` again.
    discard writeArtifact(req.artifactDir, "provider_unknown_retry.txt",
      "retrying step " & step.id &
      " after unknown provider outcome; prior attempt not assumed successful\n")

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

  let sourceRoot = sourceRootForStep(doc)
  let attemptStarted = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

  # Mark running + provider_attempt unknown BEFORE the provider call so a
  # killed process leaves a recoverable interrupted state (not a silent miss).
  for i, s in doc.steps.mpairs:
    if s.id == step.id:
      doc.steps[i].status = ssRunning
      doc.steps[i].result = %*{
        "provider_attempt": {
          "status": "unknown",
          "started_at": attemptStarted,
          "route": req.route,
          "source_tree": sourceRoot
        }
      }
  doc.nextAction = "step"
  saveProject(store, doc)
  emitProjectEvent(store, doc.projectId, "project.step_running", %*{
    "step_id": step.id,
    "provider_attempt": "unknown",
    "source_tree": sourceRoot
  })

  maybePauseForInterruptTest()

  var mandate = doc.mandates{step.mandateKey}
  if mandate.isNil or mandate.kind != JObject:
    result.ok = false
    result.verdict = "blocked"
    result.message = "mandate missing for step " & step.id & " (no fabricated mandate)"
    for i, s in doc.steps.mpairs:
      if s.id == step.id:
        doc.steps[i].status = ssPending
        doc.steps[i].result = %*{"error": result.message}
    saveProject(store, doc)
    result.doc = doc
    result.report = reportBase("step", doc)
    return
  mandate = mandate.copy()
  mandate["step_id"] = %step.id
  mandate["step_title"] = %step.title
  mandate["source_tree"] = %sourceRoot
  if doc.acceptedStepId.len > 0:
    mandate["prior_accepted_step"] = %doc.acceptedStepId

  let manPath = writeArtifact(
    if req.artifactDir.len > 0: req.artifactDir else: doc.cwd / ".nimfactory",
    "mandate.json", pretty(mandate))
  result.mandatePath = manPath
  emitProjectEvent(store, doc.projectId, "project.mandate", %*{
    "step_id": step.id,
    "mandate_key": step.mandateKey,
    "path": manPath
  })

  # Context from the accepted tree (or original cwd), not a stale pristine copy.
  let ctx = buildImplementContext(sourceRoot, mandate, step.title)
  result.provider = invokeProjectModel(req, ctx.systemPrompt, ctx.userPrompt)
  if req.route == "inject":
    result.untested.add("implementer model decision (inject)")

  let attemptStatus =
    if result.provider.ok: "completed"
    elif not result.provider.available: "unknown"
    else: "failed"

  if not result.provider.ok:
    result.ok = false
    result.verdict = if not result.provider.available: "api_unavailable" else: "model_failed"
    result.message = result.provider.message
    for i, s in doc.steps.mpairs:
      if s.id == step.id:
        # Unavailable / unknown outcome → interrupted (do not silent-retry as success).
        # Known model failure → pending for explicit retry.
        if attemptStatus == "unknown":
          doc.steps[i].status = ssInterrupted
        else:
          doc.steps[i].status = ssPending
        doc.steps[i].result = %*{
          "error": result.message,
          "provider_attempt": {
            "status": attemptStatus,
            "started_at": attemptStarted,
            "route": req.route,
            "source_tree": sourceRoot,
            "finished_at": now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
          }
        }
    # Only record usage when the call clearly completed or failed with a response.
    if attemptStatus != "unknown":
      recordUsage(doc, "implementer", result.provider)
    doc.nextAction = "step"
    saveProject(store, doc)
    result.doc = doc
    result.report = reportBase("step", doc)
    result.report["provider"] = providerToJson(result.provider)
    result.report["provider_attempt_status"] = %attemptStatus
    return

  recordUsage(doc, "implementer", result.provider)

  let decision = parseFixDecision(result.provider.rawText)
  # Apply on top of the accepted tree (chained), not always the original cwd.
  result.apply = applyDecision(sourceRoot, req.worktree, decision)
  if not result.apply.ok:
    result.ok = false
    result.verdict = "apply_failed"
    result.message = result.apply.message
    for i, s in doc.steps.mpairs:
      if s.id == step.id:
        doc.steps[i].status = ssPending
        doc.steps[i].result = %*{
          "apply": applyToJson(result.apply),
          "provider_attempt": {
            "status": "completed",
            "started_at": attemptStarted,
            "route": req.route,
            "source_tree": sourceRoot
          }
        }
    doc.blockedReason = result.apply.message
    saveProject(store, doc)
    emitProjectEvent(store, doc.projectId, "project.step_apply_failed", applyToJson(result.apply))
    result.doc = doc
    result.report = reportBase("step", doc)
    result.report["provider"] = providerToJson(result.provider)
    result.report["apply"] = applyToJson(result.apply)
    return

  doc.worktree = result.apply.worktree
  let readable = buildReadableDiff(sourceRoot, result.apply.worktree, result.apply.targetFile)
  doc.lastDiff = readable
  discard writeArtifact(req.artifactDir, "last_diff.txt", readable & "\n" &
                        "before_hash=" & result.apply.beforeHash &
                        " after_hash=" & result.apply.afterHash & "\n" &
                        "source_tree=" & sourceRoot & "\n")

  let recipe = loadProjectRecipe(doc.cwd)
  # Full CSV oracle only on the last pending step of the recipe; earlier
  # steps must keep list intact but may not yet expose export-csv.
  var otherPending = 0
  for s in doc.steps:
    if s.id != step.id and s.status in {ssPending, ssInterrupted, ssRunning, ssBlocked}:
      inc otherPending
  let finalStep = otherPending == 0
  result.verify = verifyForRecipe(
    recipe, result.apply.worktree, doc.cwd, finalStep = finalStep)
  result.report = newJObject()  # filled below

  if result.verify.ok:
    let snap = snapshotAcceptedTree(req.artifactDir, step.id, result.apply.worktree)
    doc.acceptedTreeRef = snap.path
    doc.acceptedTreeHash = snap.hash
    doc.acceptedStepId = step.id
    let diffPath = writeArtifact(req.artifactDir, "accepted_diff_" & step.id & ".txt", readable)
    for i, s in doc.steps.mpairs:
      if s.id == step.id:
        doc.steps[i].status = ssDone
        doc.steps[i].result = %*{
          "verify": verifyToJson(result.verify),
          "apply": applyToJson(result.apply),
          "accepted_tree_ref": snap.path,
          "accepted_tree_hash": snap.hash,
          "accepted_diff_path": diffPath,
          "readable_diff": readable,
          "source_tree": sourceRoot,
          "provider_attempt": {
            "status": "completed",
            "started_at": attemptStarted,
            "route": req.route,
            "source_tree": sourceRoot
          }
        }
    doc.lastVerdict = "step_pass"
    let more = nextPendingStep(doc)
    doc.nextAction = if more.found: "step" else: "done"
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
          "apply": applyToJson(result.apply),
          "readable_diff": readable,
          "source_tree": sourceRoot,
          "provider_attempt": {
            "status": "completed",
            "started_at": attemptStarted,
            "route": req.route,
            "source_tree": sourceRoot
          }
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
    "accepted_tree_ref": doc.acceptedTreeRef,
    "accepted_tree_hash": doc.acceptedTreeHash,
    "verify": verifyToJson(result.verify)
  })
  discard writeArtifact(req.artifactDir, "verify.json", pretty(verifyToJson(result.verify)))

  result.doc = doc
  result.report = reportBase("step", doc)
  result.report["provider"] = providerToJson(result.provider)
  result.report["apply"] = applyToJson(result.apply)
  result.report["verify"] = verifyToJson(result.verify)
  result.report["mandate_path"] = %manPath
  result.report["source_tree"] = %sourceRoot
  result.report["readable_diff"] = %readable
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
  ## Rehydrate after process death: no planner/reviser calls.
  ## Distinguishes a finished step from an interrupted attempt and names the action.
  result = projectStatus(req)
  result.command = "resume"
  if not result.ok:
    return

  var doc = result.doc
  var interruptedId = ""
  var interruptedUnknown = false
  for i, s in doc.steps.mpairs:
    if s.status == ssRunning:
      doc.steps[i].status = ssInterrupted
      interruptedId = s.id
      interruptedUnknown = providerAttemptUnknown(s) or
        (s.result{"provider_attempt"}{"status"}.getStr == "unknown")
      # Ensure provider_attempt remains unknown if still marked that way
      if doc.steps[i].result.isNil: doc.steps[i].result = newJObject()
      if not doc.steps[i].result.hasKey("provider_attempt"):
        doc.steps[i].result["provider_attempt"] = %*{
          "status": "unknown",
          "note": "process died while step was running"
        }
    elif s.status == ssInterrupted:
      interruptedId = s.id
      interruptedUnknown = providerAttemptUnknown(s)

  if interruptedId.len > 0:
    let store = openProjectStore(req.storePath)
    defer: closeProjectStore(store)
    doc.nextAction = "retry_step"
    saveProject(store, doc)
    result.doc = doc
    result.report = reportBase("resume", doc)
    result.report["sub"] = %"resume"
    result.report["resume"] = %*{
      "rehydrated": true,
      "planner_calls_this_command": 0,
      "reviser_calls_this_command": 0,
      "billable_plan_calls": 0,
      "interrupted_step": interruptedId,
      "step_state": "interrupted",
      "provider_attempt_unknown": interruptedUnknown,
      "action": "retry_step",
      "action_note":
        if interruptedUnknown:
          "Prior provider call outcome is unknown; do not assume success or silently rebill. Re-run `project step` explicitly to retry."
        else:
          "Interrupted attempt recorded; re-run `project step` to retry."
    }
    result.verdict = "interrupted"
    result.message = "resumed; interrupted step=" & interruptedId & "; action=retry_step"
    emitProjectEvent(store, doc.projectId, "project.resume", result.report["resume"])
    return

  let pending = nextPendingStep(doc)
  var doneCount = 0
  for s in doc.steps:
    if s.status == ssDone: inc doneCount

  let store = openProjectStore(req.storePath)
  defer: closeProjectStore(store)
  result.report["sub"] = %"resume"
  if pending.found:
    result.report["resume"] = %*{
      "rehydrated": true,
      "planner_calls_this_command": 0,
      "reviser_calls_this_command": 0,
      "billable_plan_calls": 0,
      "pending_step": pending.step.id,
      "step_state": "pending",
      "completed_steps": doneCount,
      "action": "run_step",
      "action_note": "Next pending step is ready; run `project step`."
    }
    result.verdict = "resumed"
    result.message = "resumed; next pending step=" & pending.step.id
  else:
    result.report["resume"] = %*{
      "rehydrated": true,
      "planner_calls_this_command": 0,
      "reviser_calls_this_command": 0,
      "billable_plan_calls": 0,
      "pending_step": "",
      "step_state": "done",
      "completed_steps": doneCount,
      "action": "done",
      "action_note": "All steps finished; nothing to retry."
    }
    result.verdict = "resumed"
    result.message = "resumed; no pending steps"
  emitProjectEvent(store, result.doc.projectId, "project.resume", result.report["resume"])
