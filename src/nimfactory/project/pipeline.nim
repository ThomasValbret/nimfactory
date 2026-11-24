## Project CLI journey: ask → revise → step → status/resume.

import std/[os, json, tables, sequtils, strutils, times, algorithm, posix]
import nimfactory/mission/[provider, apply, context]
import nimfactory/runtime/journal/run_store
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
    injectRecoveryPath*: string ## offline second inject (one recovery turn)
    injectCompileRepairPath*: string ## offline post-compile repair inject
    injectDir*: string          ## ask/revise/step injects for project run
    replayFirstPath*: string    ## historical first raw; no new ask/revise/step bill
    historicalProvenance*: string ## note / path preserved in report
    worktree*: string
    artifactDir*: string        ## optional: write plan/mandate/diff here
    commandId*: string          ## idempotency key for write commands
    expectedPlanVersion*: int   ## optimistic concurrency (with expectPlanVersion)
    expectPlanVersion*: bool    ## when true, refuse if current != expected
    maxSteps*: int              ## project run safety ceiling (0 → 8)
    pauseAfterStep*: bool       ## stop after one successful step (Studio « Pause »)
    maxAutoRevises*: int        ## run may request motivated revise after exhaustion (0 → 1)

  ProjectReport* = object
    ok*: bool
    command*: string
    projectId*: string
    verdict*: string
    message*: string
    doc*: ProjectDoc
    provider*: ProviderCallResult
    recoveryProvider*: ProviderCallResult
    recoveryTriggered*: bool
    recoveryAttempted*: bool
    recoveryReason*: string
    repairProvider*: ProviderCallResult
    repairTriggered*: bool
    repairAttempted*: bool
    repairReason*: string
    providerCallsThisCommand*: int
    apiCallsThisCommand*: int
    verify*: ProjectVerifyResult
    apply*: ApplyResult
    mandatePath*: string
    untested*: seq[string]
    report*: JsonNode

proc defaultProjectRequest*(): ProjectRequest =
  result.route = "api"
  result.projectId = "demo_tasks_cli"
  result.expectedPlanVersion = -1
  result.expectPlanVersion = false

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

proc canProjectRecovery(req: ProjectRequest): bool =
  req.injectRecoveryPath.len > 0 or req.route == "api"

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

proc invokeProjectRecovery(req: ProjectRequest; systemPrompt, userPrompt: string): ProviderCallResult =
  ## Prefer explicit recovery inject (offline); else same API route as step.
  if req.injectRecoveryPath.len > 0:
    return callFromInject(req.injectRecoveryPath)
  if req.route == "api":
    var ctx = MissionContext(
      route: "api",
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      ok: true
    )
    return callPlannedApi(ctx)
  result.ok = false
  result.available = false
  result.message = "no recovery provider configured"
  result.status = "failed"

proc invokeCompileRepair(req: ProjectRequest; systemPrompt, userPrompt: string): ProviderCallResult =
  ## Prefer explicit compile-repair inject; else API; else fall back to recovery inject.
  if req.injectCompileRepairPath.len > 0:
    return callFromInject(req.injectCompileRepairPath)
  if req.injectRecoveryPath.len > 0:
    return callFromInject(req.injectRecoveryPath)
  if req.route == "api":
    var ctx = MissionContext(
      route: "api",
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      ok: true
    )
    return callPlannedApi(ctx)
  result.ok = false
  result.available = false
  result.message = "no compile-repair provider configured"
  result.status = "failed"

proc canCompileRepair(req: ProjectRequest): bool =
  req.injectCompileRepairPath.len > 0 or req.injectRecoveryPath.len > 0 or
  req.route == "api"

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

proc recipeDefaultCriteria(cwd: string): seq[string] =
  ## Defaults follow the bound recipe only. No recipe ⇒ no CSV inheritance.
  let recipe = loadProjectRecipe(cwd)
  result = @[]
  if not recipe.raw.isNil and recipe.raw.hasKey("criteria"):
    let arr = recipe.raw{"criteria"}
    if arr.kind == JArray:
      for c in arr: result.add(c.getStr)
  if result.len > 0:
    return
  case recipe.verify
  of "csv_journey":
    result = @["compile", "list_intact"]
  of "loan_notebook":
    result = @["server_starts", "schema_ok"]
  of "generic_program", "run_stdout":
    result = @["file_exists", "program_runs"]
  else:
    # Empty / unknown recipe: generic tokens — never invent export_command.
    result = @["file_exists", "program_runs"]

proc recipeExportCriteria(cwd: string): seq[string] =
  let recipe = loadProjectRecipe(cwd)
  result = @[]
  if not recipe.raw.isNil and recipe.raw.hasKey("export_criteria"):
    let arr = recipe.raw{"export_criteria"}
    if arr.kind == JArray:
      for c in arr: result.add(c.getStr)
  if result.len > 0:
    return
  if recipe.verify != "csv_journey":
    # Non-CSV recipes must not inherit export_command from demo_tasks defaults.
    return recipeDefaultCriteria(cwd)
  result = recipeDefaultCriteria(cwd)
  if "export_command" notin result:
    result.add("export_command")

proc stepLooksLikeHelper(st: ProjectStep): bool =
  ## "helpers pour l'export CSV" is still a helper step (one file: tasks.nim).
  let t = st.title.toLowerAscii
  let id = st.id.toLowerAscii
  let compact = t.replace(" ", "")
  if "wire" in t or "wire" in id or "câbl" in t or "cabl" in t:
    return false
  if "demo_tasks" in t and "helper" notin t and "helpers" notin t:
    return false
  "helper" in t or "helpers" in t or "helper" in id or "helpers" in id or
    "csvquote" in compact or "formatcsv" in compact or
    ("tasks.nim" in t and "export-csv" notin t)

proc stepObjectiveImpliesExport(st: ProjectStep; index, total: int;
                                objective = ""; hasFinalCriteria = false;
                                cwd = ""): bool =
  ## When the plan declares final_criteria, do not push export onto helpers.
  ## Bare "csv" in a helper title (csvQuote/formatCsv) is not an export wire.
  ## Without a csv_journey recipe, never imply export from objective prose.
  let recipe = loadProjectRecipe(cwd)
  if recipe.verify != "csv_journey":
    return false
  let t = st.title.toLowerAscii
  let id = st.id.toLowerAscii
  let obj = objective.toLowerAscii
  if stepLooksLikeHelper(st):
    return false
  let exportish =
    "export" in t or "export" in id or "exporte" in t or "wire" in t or
    "wire" in id or "câbl" in t or "cabl" in t or "csv" in t or "csv" in id
  if hasFinalCriteria:
    return exportish or index == total
  exportish or index == total or "export" in obj or "exporte" in obj or
    "csv" in obj

proc planFinalCriteria*(node: JsonNode): seq[string] =
  result = @[]
  let arr = node{"final_criteria"}
  if arr != nil and arr.kind == JArray:
    for c in arr: result.add(c.getStr)

proc inferStepCriteria*(st: ProjectStep; index, total: int;
                        cwd = ""; objective = "";
                        finalCriteria: seq[string] = @[]): seq[string]

proc coerceExecutableCriteria*(raw: seq[string]; st: ProjectStep;
                               index, total: int; cwd, objective: string;
                               finalCriteria: seq[string]): seq[string] =
  ## Map prose / free-form postconditions onto executable oracle tokens.
  ## Explicit executable tokens win; final_criteria enrich the last step only.
  ## CSV tokens only apply when the recipe is csv_journey.
  let recipe = loadProjectRecipe(cwd)
  let csvBound = recipe.verify == "csv_journey"
  const csvKnown = ["compile", "list_intact", "export_command", "csv_helpers"]
  const genericKnown = ["file_exists", "file_created", "program_runs",
                        "stdout_bonjour", "run_stdout"]
  const loanKnown = ["server_starts", "schema_ok", "mark_returned"]
  var kept: seq[string] = @[]
  template addUnique(tok: string) =
    if tok notin kept: kept.add(tok)
  for c in raw:
    let cl = c.toLowerAscii.strip()
    for k in csvKnown:
      if cl == k and (csvBound or k == "compile"): addUnique(k)
    for k in genericKnown:
      if cl == k: addUnique(k)
    for k in loanKnown:
      if cl == k: addUnique(k)
    if "file_exists" in cl or ("fichier" in cl and "cré" in cl):
      addUnique("file_exists")
    if "file_created" in cl or "crée" in cl or "creer" in cl or "create" in cl:
      addUnique("file_exists")
    if "program_runs" in cl or "exécut" in cl or "execut" in cl or
       "affiche" in cl or "bonjour" in cl or "hello" in cl:
      addUnique("program_runs")
    if "bonjour" in cl or "stdout_bonjour" in cl:
      addUnique("stdout_bonjour")
    if csvBound:
      if "compile" == cl or cl.startsWith("compile ") or " compil" in cl or
         cl.startsWith("compil"): addUnique("compile")
      if "list_intact" in cl or "list intact" in cl: addUnique("list_intact")
      if "export_command" in cl or "export-csv" in cl or "export_csv" in cl:
        addUnique("export_command")
      elif "exporte" in cl or "exportation" in cl:
        addUnique("export_command")
      elif "export" in cl and
           ("stdout" in cl or "sortie" in cl or "commande" in cl or
            "command" in cl or "csv" in cl or "drapeau" in cl or
            "opt-in" in cl or "optin" in cl):
        addUnique("export_command")
      elif "csv" in cl and
           ("stdout" in cl or "sortie" in cl or "commande" in cl or
            "command" in cl or "export" in cl or "exporte" in cl):
        addUnique("export_command")
      if ("list_intact" in cl or "list intact" in cl or
          (cl.contains("list") and ("intact" in cl or "inchang" in cl or
           "défaut" in cl or "defaut" in cl or "default" in cl or
           "affichage" in cl))):
        addUnique("list_intact")
      elif ("affichage" in cl or "défaut" in cl or "defaut" in cl) and
           "csv" notin cl:
        addUnique("list_intact")
  if kept.len == 0:
    var tmp = st
    tmp.criteria = @[]
    return inferStepCriteria(tmp, index, total, cwd, objective, finalCriteria)
  if csvBound:
    if "compile" notin kept:
      kept.insert("compile", 0)
    if stepLooksLikeHelper(st) and "export_command" notin kept:
      addUnique("csv_helpers")
  if index == total and finalCriteria.len > 0:
    let mapped = coerceExecutableCriteria(
      finalCriteria, st, index, total, cwd, objective, @[])
    for f in mapped:
      addUnique(f)
  elif csvBound and "export_command" notin kept and
       stepObjectiveImpliesExport(st, index, total, objective,
                                  finalCriteria.len > 0, cwd):
    addUnique("export_command")
  kept

proc inferStepCriteria*(st: ProjectStep; index, total: int;
                        cwd = ""; objective = "";
                        finalCriteria: seq[string] = @[]): seq[string] =
  ## Prefer explicit step criteria/postconditions; else recipe + step objective.
  ## final_criteria belong to the delivered binary, not every intermediate step.
  if st.criteria.len > 0:
    return coerceExecutableCriteria(
      st.criteria, st, index, total, cwd, objective, finalCriteria)
  let hasFinal = finalCriteria.len > 0
  if stepObjectiveImpliesExport(st, index, total, objective, hasFinal, cwd):
    if hasFinal and index == total:
      return coerceExecutableCriteria(
        finalCriteria, st, index, total, cwd, objective, @[])
    return recipeExportCriteria(cwd)
  result = recipeDefaultCriteria(cwd)
  let recipe = loadProjectRecipe(cwd)
  if recipe.verify == "csv_journey" and stepLooksLikeHelper(st) and
     "csv_helpers" notin result:
    result.add("csv_helpers")

proc stepsFromPlanNode*(node: JsonNode; mandateKey: string;
                       cwd = ""; objective = ""): seq[ProjectStep] =
  result = @[]
  let arr = node{"steps"}
  if arr.isNil or arr.kind != JArray:
    return
  let finalCrit = planFinalCriteria(node)
  var i = 0
  let total = arr.len
  for s in arr:
    inc i
    var st = stepFromJson(s)
    if st.id.len == 0:
      st.id = "step_" & $i
    if st.title.len == 0:
      st.title = st.id
    st.status = ssPending
    st.mandateKey = mandateKey
    st.criteria = inferStepCriteria(st, i, total, cwd, objective, finalCrit)
    if st.result.isNil: st.result = newJObject()
    result.add(st)

proc planStepsFingerprint*(steps: seq[ProjectStep]): string =
  ## Structural identity for "equivalent revision" (id, deps, criteria).
  var parts: seq[string] = @[]
  for s in steps:
    var deps = s.dependsOn
    deps.sort()
    var crit = s.criteria
    crit.sort()
    parts.add(s.id & "|" & deps.join(",") & "|" & crit.join(","))
  parts.join(";")

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

proc inferDiffOrigin(doc: ProjectDoc): string =
  for step in doc.steps:
    if step.result.isNil: continue
    let r = step.result{"provider_attempt", "route"}.getStr
    if r == "inject": return "inject"
    if r == "api": return "model"
    if r.len > 0: return r
  if doc.lastVerdict == "historical_replay": return "historical_replay"
  "model"

proc fingerprintStillMatches(treeRef: string; recorded: JsonNode): bool =
  ## True when every recorded file fingerprint still matches the tree on disk.
  if recorded.isNil or recorded.kind != JObject: return true
  if treeRef.len == 0 or not dirExists(treeRef): return false
  for key, val in recorded.pairs:
    let want = val.getStr
    if want.len == 0: continue
    let absPath = treeRef / key
    if not fileExists(absPath): return false
    if fileContentFingerprint(absPath) != want: return false
  true

proc collectControls(doc: ProjectDoc): tuple[requested, executed: JsonNode; obs: string] =
  ## Prefer per-control observations from verify.details.controls.
  ## Fall back for legacy receipts and mark their limits.
  result.requested = newJArray()
  result.executed = newJArray()
  result.obs = ""
  var seenReq: seq[string] = @[]
  for step in doc.steps:
    for c in step.criteria:
      if c notin seenReq:
        seenReq.add(c)
        result.requested.add(%c)
    if step.result.isNil: continue
    let v = step.result{"verify"}
    let tree = step.result{"accepted_tree_ref"}.getStr
    let hash = step.result{"accepted_tree_hash"}.getStr
    let attempt = step.result{"provider_attempt"}
    let detailControls =
      if v.isNil: nil else: v{"details", "controls"}
    if detailControls != nil and detailControls.kind == JArray and
       detailControls.len > 0:
      for n in detailControls:
        var node = n.copy()
        node["tree_ref"] = %tree
        node["tree_hash"] = %hash
        node["step_id"] = %step.id
        if attempt != nil: node["attempt"] = attempt
        let fps = n{"file_fingerprints"}
        if step.status == ssDone and tree.len > 0 and
           not fingerprintStillMatches(tree, fps):
          node["ok"] = %false
          node["status"] = %"stale"
          let prev = node{"observations"}.getStr
          node["observations"] = %(
            "proof stale — verified files changed on delivered tree" &
            (if prev.len > 0: " (was: " & prev & ")" else: ""))
        elif step.status != ssDone and node{"status"}.getStr == "passed":
          node["status"] = %"unexecuted"
          node["ok"] = %false
        result.executed.add(node)
        if step.id == doc.acceptedStepId:
          result.obs = node{"observations"}.getStr
    elif step.status == ssDone:
      # Legacy receipt: global ok copied per criterion — surface the limit.
      let msg = if v.isNil: "" else: v{"message"}.getStr
      let globalOk = if v.isNil: false else: v{"ok"}.getBool
      for c in step.criteria:
        result.executed.add(%*{
          "name": c,
          "ok": globalOk,
          "status": if globalOk: "passed_legacy" else: "failed_legacy",
          "tree_ref": tree,
          "tree_hash": hash,
          "observations": msg,
          "step_id": step.id,
          "attempt": attempt,
          "file_fingerprints": newJObject(),
          "receipt_limits": ["pre_per_control_observations"]
        })
      if step.id == doc.acceptedStepId and msg.len > 0:
        result.obs = msg
    else:
      for c in step.criteria:
        result.executed.add(%*{
          "name": c,
          "ok": false,
          "status": "unexecuted",
          "tree_ref": tree,
          "tree_hash": hash,
          "observations": "control " & c & " not yet executed on step " & step.id,
          "step_id": step.id
        })
  # Requested but never appeared in executed → absent.
  var seenExec: seq[string] = @[]
  for n in result.executed:
    let nm = n{"name"}.getStr
    if nm notin seenExec: seenExec.add(nm)
  for c in seenReq:
    if c notin seenExec:
      result.executed.add(%*{
        "name": c,
        "ok": false,
        "status": "absent",
        "observations": "control " & c & " obligatory but absent from execution",
        "tree_ref": doc.acceptedTreeRef,
        "tree_hash": doc.acceptedTreeHash
      })
  if result.obs.len == 0 and doc.blockedReason.len > 0:
    result.obs = doc.blockedReason

proc reportBase(cmd: string; doc: ProjectDoc): JsonNode =
  let controls = collectControls(doc)
  result = %*{
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
    "blocked_reason": doc.blockedReason,
    "revise_plan_pending": doc.revisePlanPending,
    "revise_plan_reason": doc.revisePlanReason,
    "revise_plan_step_id": doc.revisePlanStepId,
    "revise_plan_at_version": doc.revisePlanAtVersion,
    "recovery_exhausted": doc.recoveryExhausted,
    "recovery_exhausted_step_id": doc.recoveryExhaustedStepId,
    "recovery_exhausted_reason": doc.recoveryExhaustedReason,
    "usage_by_role": usageTableJson(doc),
    "steps": doc.steps.mapIt(stepToJson(it)),
    "plan_versions": doc.planVersions.mapIt(planToJson(it)),
    "diff_origin": inferDiffOrigin(doc),
    "attempt": {
      "kind": cmd,
      "plan_version": doc.currentPlanVersion,
      "source_tree": doc.cwd,
      "accepted_tree_ref": doc.acceptedTreeRef,
      "accepted_tree_hash": doc.acceptedTreeHash
    },
    "controls_requested": controls.requested,
    "controls_executed": controls.executed,
    "observations": controls.obs
  }

proc finishStepRefuse*(
    report: var ProjectReport; doc: var ProjectDoc; store: SqliteRunStore;
    req: ProjectRequest; stepId, sourceRoot, attemptStarted: string;
    refuseCode, verdictText, messageText: string; applyNode: JsonNode) =
  ## Persist a pre-write or apply refuse; no further recovery after this call.
  report.ok = false
  report.verdict = verdictText
  report.message = messageText
  for i, s in doc.steps.mpairs:
    if s.id == stepId:
      doc.steps[i].status = ssPending
      doc.steps[i].result = %*{
        "refuse_code": refuseCode,
        "apply": applyNode,
        "recovery_triggered": report.recoveryTriggered,
        "recovery_attempted": report.recoveryAttempted,
        "recovery_reason": report.recoveryReason,
        "provider_attempt": {
          "status": "completed",
          "started_at": attemptStarted,
          "route": report.provider.route,
          "source_tree": sourceRoot
        }
      }
  doc.blockedReason = messageText
  doc.lastVerdict = verdictText
  let exhausted = applyNode{"recovery_exhausted"}.getBool(false)
  if exhausted:
    ## Survives restart: next decision must differ (force revise, no silent retry).
    doc.recoveryExhausted = true
    doc.recoveryExhaustedStepId = stepId
    doc.recoveryExhaustedReason = messageText
    doc.recoveryExhaustedFingerprint = applyNode{"prior_refuse"}.getStr & ":" &
      refuseCode
    doc.revisePlanPending = true
    doc.revisePlanReason =
      "recovery exhausted on step " & stepId & ": " & messageText &
      "; propose a different plan or edit (same recovery path refused)"
    doc.revisePlanStepId = stepId
    doc.revisePlanAtVersion = doc.currentPlanVersion
    doc.nextAction = "revise"
    doc.lastVerdict = "recovery_exhausted"
    report.verdict = "recovery_exhausted"
  elif refuseCode == "revise_plan":
    doc.revisePlanPending = true
    doc.revisePlanReason = messageText
    doc.revisePlanStepId = stepId
    doc.revisePlanAtVersion = doc.currentPlanVersion
    doc.nextAction = "revise"
  else:
    doc.nextAction = "step"
  saveProject(store, doc)
  emitProjectEvent(store, doc.projectId, "project.step_refused", %*{
    "step_id": stepId,
    "refuse_code": refuseCode,
    "verdict": report.verdict,
    "recovery_attempted": report.recoveryAttempted,
    "revise_plan_pending": doc.revisePlanPending,
    "recovery_exhausted": doc.recoveryExhausted
  })
  report.doc = doc
  report.report = reportBase("step", doc)
  report.report["provider"] = providerToJson(report.provider)
  report.report["apply"] = applyNode
  report.report["refuse_code"] = %refuseCode
  report.report["recovery_triggered"] = %report.recoveryTriggered
  report.report["recovery_attempted"] = %report.recoveryAttempted
  report.report["recovery_reason"] = %report.recoveryReason
  report.report["provider_calls_this_command"] = %report.providerCallsThisCommand
  report.report["api_calls_this_command"] = %report.apiCallsThisCommand
  if report.recoveryAttempted:
    report.report["recovery_provider"] = providerToJson(report.recoveryProvider)
  if req.historicalProvenance.len > 0:
    report.report["historical_provenance"] = %req.historicalProvenance
  if report.untested.len > 0:
    report.report["untested"] = %report.untested

proc runOneRecoveryTurn*(
    report: var ProjectReport; doc: var ProjectDoc; req: ProjectRequest;
    sourceRoot: string; mandate: JsonNode; stepTitle: string;
    reason, finding, priorTarget, priorDecision, rawFaithful: string;
    recoveryRound: var int; rawText: var string; usedRecovery: var bool): bool =
  ## At most one recovery turn. Fills report.recovery* and refreshes rawText.
  if recoveryRound >= 1:
    return false
  if not canProjectRecovery(req):
    return false
  report.recoveryTriggered = true
  report.recoveryReason = reason
  inc recoveryRound
  let rctx = buildProjectRecoveryContext(
    sourceRoot, mandate, stepTitle,
    priorTarget, priorDecision, finding, rawFaithful)
  report.recoveryProvider = invokeProjectRecovery(
    req, rctx.systemPrompt, rctx.userPrompt)
  report.recoveryAttempted = true
  inc report.providerCallsThisCommand
  if report.recoveryProvider.route == "api" or
     (req.injectRecoveryPath.len == 0 and req.route == "api"):
    inc report.apiCallsThisCommand
    recordUsage(doc, "implementer_recovery", report.recoveryProvider)
  if req.injectRecoveryPath.len > 0:
    report.untested.add("recovery via inject")
  if not report.recoveryProvider.ok:
    return false
  rawText = report.recoveryProvider.rawText
  usedRecovery = true
  true

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

proc incompletePlanReason*(doc: ProjectDoc): string =
  ## Called only after the scheduler has no further actionable step.
  ## Done gate: each obligatory control must pass on the accepted delivered tree
  ## with fresh fingerprints (stale / absent / failed / unexecuted ⇒ motif).
  if doc.steps.len == 0:
    return "plan has no steps"
  for step in doc.steps:
    if step.status != ssDone:
      return "step " & step.id & " is " & $step.status
  if doc.acceptedTreeRef.len == 0 or not dirExists(doc.acceptedTreeRef):
    return "accepted tree missing"
  let controls = collectControls(doc)
  for n in controls.executed:
    let st = n{"status"}.getStr
    let name = n{"name"}.getStr
    let obs = n{"observations"}.getStr
    if st in ["failed", "failed_legacy", "absent", "unexecuted", "stale"] or
       not n{"ok"}.getBool:
      return "control " & name & " " & (if st.len > 0: st else: "failed") &
             (if obs.len > 0: ": " & obs else: "")
  for step in doc.steps:
    if step.status != ssDone: continue
    if step.result.isNil:
      return "step " & step.id & " missing result/controls"
    let tree = step.result{"accepted_tree_ref"}.getStr
    if tree.len == 0:
      return "step " & step.id & " control missing tree_ref"
    if step.id == doc.acceptedStepId and tree != doc.acceptedTreeRef:
      return "controls not executed on accepted tree"

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

proc providerOwnerPid(step: ProjectStep): int =
  let pa = step.result{"provider_attempt"}
  if pa.isNil or pa.kind != JObject: return 0
  pa{"owner_pid"}.getInt

proc processAlive*(pid: int): bool =
  ## True if `pid` still exists (including if we lack permission to signal it).
  if pid <= 0:
    return false
  let rc = posix.kill(Pid(pid), cint(0))
  if rc == 0:
    return true
  # ESRCH = no such process; EPERM = exists but not signalable → still alive.
  errno == EPERM

proc stepOwnerAlive(step: ProjectStep): bool =
  processAlive(providerOwnerPid(step))

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
  result.providerCallsThisCommand = 1
  if req.route == "api" or result.provider.route == "api":
    result.apiCallsThisCommand = 1
  if req.route == "inject":
    result.untested.add("planner model decision (inject)")
  if not result.provider.ok:
    result.ok = false
    result.verdict = if not result.provider.available: "api_unavailable" else: "model_failed"
    result.message = result.provider.message
    result.doc = doc
    result.report = reportBase("ask", doc)
    result.report["provider"] = providerToJson(result.provider)
    result.report["provider_calls_this_command"] = %result.providerCallsThisCommand
    result.report["api_calls_this_command"] = %result.apiCallsThisCommand
    return

  let parsed = parsePlanPayload(result.provider.rawText)
  if not parsed.ok:
    result.ok = false
    result.verdict = "parse_failed"
    result.message = parsed.err
    result.doc = doc
    result.report = reportBase("ask", doc)
    result.report["provider"] = providerToJson(result.provider)
    result.report["provider_calls_this_command"] = %result.providerCallsThisCommand
    result.report["api_calls_this_command"] = %result.apiCallsThisCommand
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
    result.report["provider_calls_this_command"] = %result.providerCallsThisCommand
    result.report["api_calls_this_command"] = %result.apiCallsThisCommand
    return

  let mandateKey = "mandate_v1"
  var plan = PlanVersion(
    version: 1,
    summary: parsed.node{"summary"}.getStr,
    hypothesis: parsed.node{"hypothesis"}.getStr,
    raw: parsed.node,
    steps: stepsFromPlanNode(parsed.node, mandateKey, cwd, req.objective)
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
  let fc1 = planFinalCriteria(parsed.node)
  if fc1.len > 0:
    var arr = newJArray()
    for c in fc1: arr.add(%c)
    mandate["final_criteria"] = arr
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
  result.report["provider_calls_this_command"] = %result.providerCallsThisCommand
  result.report["api_calls_this_command"] = %result.apiCallsThisCommand
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

  let store = openProjectStore(req.storePath)
  defer: closeProjectStore(store)
  let loaded = loadProject(store, req.projectId)
  if not loaded.ok:
    result.ok = false
    result.verdict = "missing"
    result.message = loaded.err
    return
  var doc = loaded.doc
  let implementerReason = doc.revisePlanReason
  var refinement = req.refinement
  if refinement.len == 0 and doc.revisePlanPending and implementerReason.len > 0:
    ## Motif implémenteur suffit pour enclencher la révision demandée.
    refinement = "Prérequis implémenteur: " & implementerReason
  if refinement.len == 0:
    result.ok = false
    result.verdict = "invalid"
    result.message = "revise requires --refinement (or a pending revise_plan motif)"
    result.doc = doc
    return
  doc.refinements.add(refinement)

  let prior = currentPlan(doc)
  let priorJson = pretty(if prior.raw.isNil: newJObject() else: prior.raw)
  let ctx = buildReviseContext(
    doc.cwd, doc.objective, doc.refinements, priorJson, implementerReason)
  result.provider = invokeProjectModel(req, ctx.systemPrompt, ctx.userPrompt)
  result.providerCallsThisCommand = 1
  if result.provider.route == "api":
    result.apiCallsThisCommand = 1
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
    steps: stepsFromPlanNode(parsed.node, mandateKey, doc.cwd, doc.objective)
  )
  if plan.steps.len == 0:
    result.ok = false
    result.verdict = "plan_failed"
    result.message = "empty_plan: no steps after parse"
    result.doc = doc
    saveProject(store, doc)
    return

  # Equivalent revision: same structure → hand back with motif preserved.
  let priorFp = planStepsFingerprint(doc.steps)
  let newFp = planStepsFingerprint(plan.steps)
  if priorFp.len > 0 and priorFp == newFp and doc.revisePlanPending:
    recordUsage(doc, "reviser", result.provider)
    # Motif conserved; do not clear revisePlanPending / recoveryExhausted.
    if doc.revisePlanReason.len == 0 and implementerReason.len > 0:
      doc.revisePlanReason = implementerReason
    doc.nextAction = "revise"
    doc.lastVerdict = "revise_equivalent"
    saveProject(store, doc)
    emitProjectEvent(store, doc.projectId, "project.revise_equivalent", %*{
      "plan_version": doc.currentPlanVersion,
      "motif": doc.revisePlanReason,
      "fingerprint": priorFp
    })
    result.doc = doc
    result.ok = false
    result.verdict = "revise_equivalent"
    result.message =
      "revision equivalent; motif preserved: " & doc.revisePlanReason
    result.report = reportBase("revise", doc)
    result.report["provider"] = providerToJson(result.provider)
    result.report["motif_preserved"] = %doc.revisePlanReason
    result.report["equivalent_fingerprint"] = %priorFp
    result.report["provider_calls_this_command"] = %result.providerCallsThisCommand
    result.report["api_calls_this_command"] = %result.apiCallsThisCommand
    return

  var doneIds = initTable[string, ProjectStep]()
  for s in doc.steps:
    if s.status == ssDone:
      doneIds[s.id] = s
  var keptProof = newJArray()
  var droppedProof = newJArray()
  # First mark candidates; deps checked after statuses assigned.
  for i, s in plan.steps.mpairs:
    if s.id in doneIds:
      let old = doneIds[s.id]
      let verifyNode = if old.result.isNil: newJObject() else: old.result{"verify"}
      if proofCoversCriteria(verifyNode, s.criteria):
        plan.steps[i].status = ssDone
        plan.steps[i].result = old.result
        keptProof.add(%*{"id": s.id, "criteria": s.criteria})
      else:
        droppedProof.add(%*{
          "id": s.id,
          "reason": "proof_does_not_cover_criteria",
          "criteria": s.criteria
        })
  # Drop proofs whose dependencies are no longer done in the revised plan.
  for i, s in plan.steps.mpairs:
    if s.status != ssDone: continue
    for d in s.dependsOn:
      var depOk = false
      for t in plan.steps:
        if t.id == d and t.status == ssDone:
          depOk = true
          break
      if not depOk:
        plan.steps[i].status = ssPending
        plan.steps[i].result = newJObject()
        droppedProof.add(%*{
          "id": s.id,
          "reason": "dependency_not_covered",
          "missing_dep": d
        })
        break

  doc.planVersions.add(plan)
  doc.currentPlanVersion = newVersion
  doc.steps = plan.steps
  # Tip accepted tree only if that step remains done.
  if doc.acceptedStepId.len > 0:
    var tipOk = false
    for s in doc.steps:
      if s.id == doc.acceptedStepId and s.status == ssDone:
        tipOk = true
        break
    if not tipOk:
      doc.acceptedTreeRef = ""
      doc.acceptedTreeHash = ""
      doc.acceptedStepId = ""
  var mandate = parsed.node{"mandate_sketch"}.copy()
  mandate["plan_version"] = %newVersion
  mandate["change_notes"] = %parsed.node{"change_notes"}.getStr
  mandate["agents_md_excerpt"] = %ctx.agentsMd
  mandate["source_ids"] = %ctx.sourceIds
  mandate["refinement"] = %refinement
  if implementerReason.len > 0:
    mandate["implementer_revise_reason"] = %implementerReason
  let fcR = planFinalCriteria(parsed.node)
  if fcR.len > 0:
    var arr = newJArray()
    for c in fcR: arr.add(%c)
    mandate["final_criteria"] = arr
  if doc.mandates.isNil: doc.mandates = newJObject()
  doc.mandates[mandateKey] = mandate
  recordUsage(doc, "reviser", result.provider)
  # Accepted revision clears implementer + exhausted-recovery blocks.
  doc.revisePlanPending = false
  doc.revisePlanReason = ""
  doc.revisePlanStepId = ""
  doc.revisePlanAtVersion = 0
  doc.recoveryExhausted = false
  doc.recoveryExhaustedStepId = ""
  doc.recoveryExhaustedReason = ""
  doc.recoveryExhaustedFingerprint = ""
  doc.blockedReason = ""
  doc.nextAction = "step"
  doc.lastVerdict = "plan_v" & $newVersion

  saveProject(store, doc)
  emitProjectEvent(store, doc.projectId, "project.revise", %*{
    "plan_version": newVersion,
    "summary": plan.summary,
    "refinement": refinement,
    "implementer_revise_reason": implementerReason,
    "route": result.provider.route,
    "proof_kept": keptProof,
    "proof_dropped": droppedProof
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
  result.report["proof_kept"] = keptProof
  result.report["proof_dropped"] = droppedProof
  result.report["provider_calls_this_command"] = %result.providerCallsThisCommand
  result.report["api_calls_this_command"] = %result.apiCallsThisCommand
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

  # Implementer prerequisite: hand back to reviser without a provider call.
  if doc.revisePlanPending:
    result.ok = false
    result.verdict = "revise_plan_needed"
    result.message = doc.revisePlanReason
    result.providerCallsThisCommand = 0
    result.apiCallsThisCommand = 0
    result.doc = doc
    result.report = reportBase("step", doc)
    result.report["provider_calls_this_command"] = %0
    result.report["api_calls_this_command"] = %0
    result.report["revise_plan"] = %*{
      "pending": true,
      "reason": doc.revisePlanReason,
      "step_id": doc.revisePlanStepId,
      "at_version": doc.revisePlanAtVersion,
      "action": "revise",
      "action_note": "No provider call; run project revise with the persisted motif."
    }
    return

  # Concurrent run held by another live process must not double-spend.
  let runLease = peekProjectRunLease(store, req.projectId)
  if runLease.active and runLease.holderPid != getCurrentProcessId():
    result.ok = false
    result.verdict = "already_running"
    result.message =
      "project run lease held by pid=" & $runLease.holderPid &
      "; no provider call from concurrent step"
    result.doc = doc
    result.report = reportBase("step", doc)
    result.report["provider_calls_this_command"] = %0
    result.report["api_calls_this_command"] = %0
    result.report["already_running"] = %*{
      "kind": "run_lease",
      "holder_pid": runLease.holderPid,
      "action": "wait_or_status"
    }
    return

  let actionable = nextActionableStep(doc)
  if not actionable.found:
    let reason = incompletePlanReason(doc)
    if reason.len > 0:
      result.verdict = "blocked"
      result.message = reason
      result.doc = doc
      result.report = reportBase("step", doc)
      return
    result.ok = true
    result.verdict = "nothing_pending"
    result.message = "no pending steps"
    result.doc = doc
    result.report = reportBase("step", doc)
    return

  var step = actionable.step

  # Concurrent guard: a live owner waiting on the provider must not be
  # double-entered by a second `project step` (no silent rebill / no call).
  if step.status == ssRunning and stepOwnerAlive(step):
    result.ok = false
    result.verdict = "already_running"
    result.message =
      "step " & step.id & " is already running (owner_pid=" &
      $providerOwnerPid(step) & "); no provider call"
    result.doc = doc
    result.report = reportBase("step", doc)
    result.report["provider_calls_this_command"] = %0
    result.report["already_running"] = %*{
      "step_id": step.id,
      "owner_pid": providerOwnerPid(step),
      "provider_attempt_unknown": providerAttemptUnknown(step),
      "action": "wait_or_status"
    }
    return

  # Stale running (owner dead) → treat as interrupted before explicit retry.
  if step.status == ssRunning and not stepOwnerAlive(step):
    for i, s in doc.steps.mpairs:
      if s.id == step.id:
        doc.steps[i].status = ssInterrupted
        step.status = ssInterrupted
    saveProject(store, doc)

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
    doc.lastVerdict = "blocked"
    doc.nextAction = "revise"
    for i, s in doc.steps.mpairs:
      if s.id == step.id: doc.steps[i].status = ssBlocked
    saveProject(store, doc)
    result.doc = doc
    result.report = reportBase("step", doc)
    return

  let sourceRoot = sourceRootForStep(doc)
  # Wire step without formatCsv in the accepted tree → revise, don't invent helpers.
  if not stepLooksLikeHelper(step) and
     stepObjectiveImpliesExport(step, 2, 2, doc.objective, true, doc.cwd):
    let tasksSrc = sourceRoot / "src" / "tasks.nim"
    if fileExists(tasksSrc) and "formatCsv" notin readFile(tasksSrc):
      let motif =
        "formatCsv missing in src/tasks.nim on accepted tree; " &
        "complete csv helpers before CLI wire"
      for i, s in doc.steps.mpairs:
        if s.id == step.id: doc.steps[i].status = ssBlocked
      doc.revisePlanPending = true
      doc.revisePlanReason = motif
      doc.revisePlanStepId = step.id
      doc.revisePlanAtVersion = doc.currentPlanVersion
      doc.nextAction = "revise"
      doc.lastVerdict = "revise_plan_needed"
      doc.blockedReason = motif
      saveProject(store, doc)
      result.ok = false
      result.verdict = "revise_plan_needed"
      result.message = motif
      result.doc = doc
      result.report = reportBase("step", doc)
      result.report["blocked"] = %*{
        "kind": "missing_csv_helpers", "step_id": step.id, "message": motif
      }
      return

  let attemptStarted = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  let ownerPid = getCurrentProcessId()

  # Mark running + provider_attempt unknown BEFORE the provider call so a
  # killed process leaves a recoverable interrupted state (not a silent miss).
  # owner_pid lets resume/step distinguish a live waiter from a dead process.
  for i, s in doc.steps.mpairs:
    if s.id == step.id:
      doc.steps[i].status = ssRunning
      doc.steps[i].result = %*{
        "provider_attempt": {
          "status": "unknown",
          "started_at": attemptStarted,
          "route": req.route,
          "source_tree": sourceRoot,
          "owner_pid": ownerPid
        }
      }
  doc.nextAction = "step"
  saveProject(store, doc)
  emitProjectEvent(store, doc.projectId, "project.step_running", %*{
    "step_id": step.id,
    "provider_attempt": "unknown",
    "owner_pid": ownerPid,
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
  var postArr = newJArray()
  for c in step.criteria: postArr.add(%c)
  mandate["postconditions"] = postArr
  if not mandate.hasKey("stdout_constraint"):
    let stepRecipe = loadProjectRecipe(doc.cwd)
    if stepRecipe.verify == "csv_journey":
      mandate["stdout_constraint"] =
        %"CSV export must write to stdout (not a file); keep default list intact"
    else:
      mandate["stdout_constraint"] = %""
  if doc.acceptedStepId.len > 0:
    mandate["prior_accepted_step"] = %doc.acceptedStepId
    mandate["prior_accepted_tree"] = %doc.acceptedTreeRef

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
  let stdoutConstraint = mandate{"stdout_constraint"}.getStr
  let ctx = buildImplementContext(
    sourceRoot, mandate, step.title, step.criteria, stdoutConstraint)
  result.providerCallsThisCommand = 0
  result.apiCallsThisCommand = 0
  let historicalFirst = req.replayFirstPath.len > 0
  if historicalFirst:
    result.provider = callFromInject(req.replayFirstPath)
    result.provider.route = "historical_replay"
    result.providerCallsThisCommand = 0
    result.untested.add("first attempt = historical replay (no new bill)")
  else:
    result.provider = invokeProjectModel(req, ctx.systemPrompt, ctx.userPrompt)
    result.providerCallsThisCommand = 1
    if req.route == "api":
      result.apiCallsThisCommand = 1
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
        if attemptStatus == "unknown":
          doc.steps[i].status = ssInterrupted
        else:
          doc.steps[i].status = ssPending
        doc.steps[i].result = %*{
          "error": result.message,
          "provider_attempt": {
            "status": attemptStatus,
            "started_at": attemptStarted,
            "route": result.provider.route,
            "source_tree": sourceRoot,
            "finished_at": now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
          }
        }
    if attemptStatus != "unknown" and not historicalFirst:
      recordUsage(doc, "implementer", result.provider)
    doc.nextAction = "step"
    saveProject(store, doc)
    result.doc = doc
    result.report = reportBase("step", doc)
    result.report["provider"] = providerToJson(result.provider)
    result.report["provider_attempt_status"] = %attemptStatus
    result.report["provider_calls_this_command"] = %result.providerCallsThisCommand
    result.report["api_calls_this_command"] = %result.apiCallsThisCommand
    return

  if not historicalFirst:
    recordUsage(doc, "implementer", result.provider)

  # --- Plan↔exec contract gates (before any write) ---
  var rawText = result.provider.rawText
  var decision = FixDecision()
  var usedRecovery = false
  var recoveryRound = 0  # at most one
  var readable = ""

  template refuseNow(refuseCode, verdictText, messageText: string; applyNode: JsonNode) =
    finishStepRefuse(result, doc, store, req, step.id, sourceRoot, attemptStarted,
                     refuseCode, verdictText, messageText, applyNode)

  template tryRecovery(reason, finding, priorTarget, priorDecision,
                       rawFaithful: string): bool =
    runOneRecoveryTurn(result, doc, req, sourceRoot, mandate, step.title,
                       reason, finding, priorTarget, priorDecision, rawFaithful,
                       recoveryRound, rawText, usedRecovery)

  proc gateSignals(raw: string): tuple[reviseHit: bool; reviseDecision: string;
                                       cannotHit: bool; cannotDecision: string] =
    let r = parseRevisePlan(raw)
    let c = parseCannotFix(raw)
    (r.hit, r.decision, c.hit, c.decision)

  block applyGate:
    # 1) Explicit plan revision / cannot_fix (no write).
    let sig0 = gateSignals(rawText)
    if sig0.reviseHit:
      refuseNow("revise_plan", "revise_plan_needed", sig0.reviseDecision,
        %*{"ok": false, "refuse_code": "revise_plan", "message": sig0.reviseDecision,
           "wrote": false})
      return
    if sig0.cannotHit:
      refuseNow("cannot_fix", "model_cannot_fix", sig0.cannotDecision,
        %*{"ok": false, "refuse_code": "cannot_fix", "message": sig0.cannotDecision,
           "wrote": false})
      return

    # 2) Read-only diagnosis against current tree (faithful raw, no write).
    #    Unreadable JSON (parse_error) must enter bounded recovery — not skip it.
    var diag = diagnoseRawAgainstTree(sourceRoot, rawText)
    if not diag.needsRefuse:
      let probe = parseFixDecision(rawText)
      if not probe.parseOk:
        diag.needsRefuse = true
        diag.refuseCode =
          if probe.refuseCode.len > 0: probe.refuseCode else: "parse_error"
        diag.finding =
          "Parse refused before write: " & probe.parseError & "\n" &
          "Prefer insertBefore/insertAfter on a unique anchor, or strict JSON.\n" &
          diag.finding
    if diag.needsRefuse:
      let reason =
        if diag.refuseCode.len > 0: diag.refuseCode else: "apply_refused"
      let priorTarget = if diag.targets.len > 0: diag.targets[0] else: ""
      result.apply.ok = false
      result.apply.refuseCode = reason
      result.apply.message = reason & "; diagnosed without write"
      result.apply.editDetails = diag.targets
      if tryRecovery(reason, diag.finding, priorTarget, reason, diag.rawFaithful):
        let sig1 = gateSignals(rawText)
        if sig1.reviseHit:
          refuseNow("revise_plan", "revise_plan_needed", sig1.reviseDecision,
            %*{"ok": false, "refuse_code": "revise_plan", "message": sig1.reviseDecision,
               "wrote": false, "prior_refuse": reason})
          return
        if sig1.cannotHit:
          refuseNow("cannot_fix", "model_cannot_fix", sig1.cannotDecision,
            %*{"ok": false, "refuse_code": "cannot_fix", "message": sig1.cannotDecision,
               "wrote": false, "prior_refuse": reason})
          return
        let diag2 = diagnoseRawAgainstTree(sourceRoot, rawText)
        if diag2.needsRefuse:
          refuseNow(diag2.refuseCode,
            if diag2.refuseCode == "multi_proposal": "multi_proposal_refused"
            else: "apply_failed",
            "recovery still refused (" & diag2.refuseCode & "); no write",
            %*{"ok": false, "refuse_code": diag2.refuseCode, "wrote": false,
               "targets": diag2.targets, "recovery_exhausted": true,
               "prior_refuse": reason})
          return
        # Unique anchors after recovery — fall through to apply.
      else:
        let verdict =
          if reason == "multi_proposal": "multi_proposal_refused"
          elif reason == "revise_plan": "revise_plan_needed"
          else: "apply_failed"
        refuseNow(reason, verdict, result.apply.message,
          %*{"ok": false, "refuse_code": reason, "wrote": false,
             "targets": diag.targets, "message": result.apply.message})
        return

    decision = parseFixDecision(rawText)
    result.apply = applyDecision(sourceRoot, req.worktree, decision)
    if not result.apply.ok:
      # Diagnosis should have caught anchors; residual refuse after write attempt.
      refuseNow(result.apply.refuseCode, "apply_failed",
        result.apply.message, applyToJson(result.apply))
      return

  # Applied successfully (first or recovery).
  doc.worktree = result.apply.worktree
  readable = buildReadableDiff(sourceRoot, result.apply.worktree, result.apply.targetFile)
  doc.lastDiff = readable
  discard writeArtifact(req.artifactDir, "last_diff.txt", readable & "\n" &
                        "before_hash=" & result.apply.beforeHash &
                        " after_hash=" & result.apply.afterHash & "\n" &
                        "source_tree=" & sourceRoot & "\n" &
                        "via_recovery=" & $usedRecovery & "\n")

  let recipe = loadProjectRecipe(doc.cwd)
  # Criteria attached to the step drive the oracle (export_command ⇒ CSV check).
  var otherPending = 0
  for s in doc.steps:
    if s.id != step.id and s.status in {ssPending, ssInterrupted, ssRunning, ssBlocked}:
      inc otherPending
  let finalStep = otherPending == 0
  let stepCriteria = if step.criteria.len > 0: step.criteria
                     else: inferStepCriteria(step, 1, if finalStep: 1 else: 2)
  result.verify = verifyStepCriteria(
    recipe, result.apply.worktree, doc.cwd, stepCriteria, finalStep = finalStep)

  var usedCompileRepair = false
  var compileRepairRound = 0

  if result.verify.ok:
    discard
  else:
    # Post-compile repair: rejected candidate + diff + localized diagnosis.
    let compileOut =
      if result.verify.details.isNil: ""
      else: result.verify.details{"compile_out"}.getStr
    let loc = localizeCompileDiagnosis(
      compileOut, result.apply.worktree, result.apply.targetFile)
    if loc.hit and compileRepairRound < 1 and canCompileRepair(req):
      inc compileRepairRound
      result.repairTriggered = true
      result.repairReason = "compile_failed"
      let rejectedCandidate =
        if decision.exactProposalJson.len > 0: decision.exactProposalJson
        else: rawText
      let repairCtx = buildCompileRepairContext(
        result.apply.worktree, mandate, step.title,
        rejectedCandidate, readable, loc.finding)
      result.repairProvider = invokeCompileRepair(
        req, repairCtx.systemPrompt, repairCtx.userPrompt)
      result.repairAttempted = true
      inc result.providerCallsThisCommand
      if result.repairProvider.route == "api":
        inc result.apiCallsThisCommand
        recordUsage(doc, "implementer_compile_repair", result.repairProvider)
      else:
        result.untested.add("compile repair via inject")
      if result.repairProvider.ok:
        let sigR = gateSignals(result.repairProvider.rawText)
        if sigR.reviseHit:
          doc.revisePlanPending = true
          doc.revisePlanReason = sigR.reviseDecision
          doc.revisePlanStepId = step.id
          doc.revisePlanAtVersion = doc.currentPlanVersion
          doc.nextAction = "revise"
          doc.lastVerdict = "revise_plan_needed"
          for i, s in doc.steps.mpairs:
            if s.id == step.id:
              doc.steps[i].status = ssPending
              doc.steps[i].result = %*{
                "verify": verifyToJson(result.verify),
                "apply": applyToJson(result.apply),
                "readable_diff": readable,
                "compile_diagnosis": loc.finding,
                "repair_revise_plan": sigR.reviseDecision,
                "provider_attempt": {
                  "status": "completed",
                  "started_at": attemptStarted,
                  "route": result.provider.route
                }
              }
          saveProject(store, doc)
          result.ok = false
          result.verdict = "revise_plan_needed"
          result.message = sigR.reviseDecision
          result.doc = doc
          result.report = reportBase("step", doc)
          result.report["provider"] = providerToJson(result.provider)
          result.report["repair_provider"] = providerToJson(result.repairProvider)
          result.report["verify"] = verifyToJson(result.verify)
          result.report["compile_diagnosis"] = %loc.finding
          result.report["readable_diff"] = %readable
          result.report["rejected_candidate"] = %rejectedCandidate
          result.report["repair_triggered"] = %true
          result.report["repair_attempted"] = %true
          result.report["provider_calls_this_command"] = %result.providerCallsThisCommand
          result.report["api_calls_this_command"] = %result.apiCallsThisCommand
          return
        let repairDec = parseFixDecision(result.repairProvider.rawText)
        let repairWt =
          if req.worktree.len > 0: req.worktree & "_repair"
          else: ""
        # Repair edits the rejected candidate tree (not pristine source).
        let repaired = applyDecision(result.apply.worktree, repairWt, repairDec)
        if repaired.ok:
          usedCompileRepair = true
          result.apply = repaired
          doc.worktree = repaired.worktree
          readable = buildReadableDiff(
            sourceRoot, repaired.worktree, repaired.targetFile)
          doc.lastDiff = readable
          result.verify = verifyStepCriteria(
            recipe, repaired.worktree, doc.cwd, stepCriteria,
            finalStep = finalStep)
          discard writeArtifact(req.artifactDir, "compile_repair_diff.txt",
            readable & "\n" & loc.finding & "\n")

  if result.verify.ok:
    let snap = snapshotAcceptedTree(req.artifactDir, step.id, result.apply.worktree)
    doc.acceptedTreeRef = snap.path
    doc.acceptedTreeHash = snap.hash
    doc.acceptedStepId = step.id
    let diffPath = writeArtifact(req.artifactDir, "accepted_diff_" & step.id & ".txt", readable)
    for i, s in doc.steps.mpairs:
      if s.id == step.id:
        doc.steps[i].status = ssDone
        doc.steps[i].criteria = stepCriteria
        doc.steps[i].result = %*{
          "verify": verifyToJson(result.verify),
          "apply": applyToJson(result.apply),
          "criteria": stepCriteria,
          "accepted_tree_ref": snap.path,
          "accepted_tree_hash": snap.hash,
          "accepted_diff_path": diffPath,
          "readable_diff": readable,
          "source_tree": sourceRoot,
          "via_recovery": usedRecovery,
          "via_compile_repair": usedCompileRepair,
          "recovery_reason": result.recoveryReason,
          "provider_attempt": {
            "status": "completed",
            "started_at": attemptStarted,
            "route": result.provider.route,
            "source_tree": sourceRoot
          }
        }
    doc.lastVerdict = "step_pass"
    let more = nextPendingStep(doc)
    doc.nextAction =
      if more.found: "step"
      elif incompletePlanReason(doc).len > 0: "revise"
      else: "done"
    doc.blockedReason = ""
    doc.recoveryExhausted = false
    doc.recoveryExhaustedStepId = ""
    doc.recoveryExhaustedReason = ""
    doc.recoveryExhaustedFingerprint = ""
    result.ok = true
    result.verdict = "pass"
    result.message = result.verify.message
  else:
    let compileOut =
      if result.verify.details.isNil: ""
      else: result.verify.details{"compile_out"}.getStr
    let loc = localizeCompileDiagnosis(
      compileOut, result.apply.worktree, result.apply.targetFile)
    for i, s in doc.steps.mpairs:
      if s.id == step.id:
        doc.steps[i].status = ssPending
        doc.steps[i].result = %*{
          "verify": verifyToJson(result.verify),
          "apply": applyToJson(result.apply),
          "readable_diff": readable,
          "source_tree": sourceRoot,
          "via_recovery": usedRecovery,
          "via_compile_repair": usedCompileRepair,
          "compile_diagnosis": loc.finding,
          "provider_attempt": {
            "status": "completed",
            "started_at": attemptStarted,
            "route": result.provider.route,
            "source_tree": sourceRoot
          }
        }
    # Motivated revise: compile still broken after repair → change treatment.
    if loc.hit and (result.repairAttempted or not canCompileRepair(req)):
      doc.revisePlanPending = true
      doc.revisePlanReason =
        "compile failed on step " & step.id & ": " & loc.message &
        "; change how the blockage is treated (prefer insertLine* / different split)"
      doc.revisePlanStepId = step.id
      doc.revisePlanAtVersion = doc.currentPlanVersion
      doc.nextAction = "revise"
    else:
      doc.nextAction = "step"
    doc.lastVerdict = "verify_failed"
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
    "via_recovery": usedRecovery,
    "via_compile_repair": usedCompileRepair,
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
  result.report["via_recovery"] = %usedRecovery
  result.report["via_compile_repair"] = %usedCompileRepair
  result.report["recovery_triggered"] = %result.recoveryTriggered
  result.report["recovery_attempted"] = %result.recoveryAttempted
  result.report["recovery_reason"] = %result.recoveryReason
  result.report["repair_triggered"] = %result.repairTriggered
  result.report["repair_attempted"] = %result.repairAttempted
  result.report["repair_reason"] = %result.repairReason
  result.report["provider_calls_this_command"] = %result.providerCallsThisCommand
  result.report["api_calls_this_command"] = %result.apiCallsThisCommand
  if result.recoveryAttempted:
    result.report["recovery_provider"] = providerToJson(result.recoveryProvider)
  if result.repairAttempted:
    result.report["repair_provider"] = providerToJson(result.repairProvider)
  if req.historicalProvenance.len > 0:
    result.report["historical_provenance"] = %req.historicalProvenance
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
  if loaded.doc.revisePlanPending:
    result.verdict = "revise_plan_needed"
    result.message = "revise pending: " & loaded.doc.revisePlanReason
  else:
    result.verdict = loaded.doc.lastVerdict
    result.message = "status ok"
  result.report = reportBase("status", loaded.doc)
  result.report["mandates"] = loaded.doc.mandates
  let tip = loaded.doc.acceptedTreeRef
  let tipHash = loaded.doc.acceptedTreeHash
  result.report["proof_tree_hash"] = %tipHash
  if tip.len > 0 and dirExists(tip):
    let live = treeFingerprint(tip)
    result.report["files_current_hash"] = %live
    result.report["proof_matches_files"] = %(live == tipHash)
    if live != tipHash:
      result.report["proof_freshness"] = %"stale"
      result.report["proof_freshness_motif"] =
        %("accepted tree hash " & tipHash & " ≠ current files " & live)
    else:
      result.report["proof_freshness"] = %"fresh"
  else:
    result.report["proof_matches_files"] = %false
    result.report["proof_freshness"] = %"absent"
  if loaded.doc.revisePlanPending:
    result.report["revise_plan"] = %*{
      "pending": true,
      "reason": loaded.doc.revisePlanReason,
      "step_id": loaded.doc.revisePlanStepId,
      "at_version": loaded.doc.revisePlanAtVersion,
      "action": "revise"
    }

proc projectResume*(req: ProjectRequest): ProjectReport =
  ## Rehydrate after process death: no planner/reviser calls.
  ## Live owner waiting on provider → active (do not flip to interrupted).
  ## Dead owner / interrupted → explicit retry_step; keep provider unknown.
  ## Pending revise_plan → action=revise (no step/provider).
  result = projectStatus(req)
  result.command = "resume"
  if not result.ok:
    return

  var doc = result.doc
  if doc.revisePlanPending:
    result.verdict = "revise_plan_needed"
    result.message = "resumed; revise pending: " & doc.revisePlanReason
    result.report = reportBase("resume", doc)
    result.report["sub"] = %"resume"
    result.report["resume"] = %*{
      "rehydrated": true,
      "planner_calls_this_command": 0,
      "reviser_calls_this_command": 0,
      "billable_plan_calls": 0,
      "revise_plan_pending": true,
      "revise_plan_reason": doc.revisePlanReason,
      "revise_plan_step_id": doc.revisePlanStepId,
      "action": "revise",
      "action_note":
        "Implementer prerequisite blocks step; run project revise (motif persisted)."
    }
    result.doc = doc
    return

  var activeId = ""
  var activePid = 0
  var interruptedId = ""
  var interruptedUnknown = false
  for i, s in doc.steps.mpairs:
    if s.status == ssRunning:
      if stepOwnerAlive(s):
        activeId = s.id
        activePid = providerOwnerPid(s)
      else:
        doc.steps[i].status = ssInterrupted
        interruptedId = s.id
        interruptedUnknown = providerAttemptUnknown(s) or
          (s.result{"provider_attempt"}{"status"}.getStr == "unknown")
        if doc.steps[i].result.isNil: doc.steps[i].result = newJObject()
        var pa = doc.steps[i].result{"provider_attempt"}
        if pa.isNil or pa.kind != JObject:
          pa = newJObject()
          doc.steps[i].result["provider_attempt"] = pa
        pa["status"] = %"unknown"
        pa["note"] = %"owner process dead while step was running; outcome unknown"
    elif s.status == ssInterrupted:
      interruptedId = s.id
      interruptedUnknown = providerAttemptUnknown(s)

  if activeId.len > 0:
    # Do not mutate a live running step; report active and refuse duplicate work.
    result.doc = doc
    result.report = reportBase("resume", doc)
    result.report["sub"] = %"resume"
    result.report["resume"] = %*{
      "rehydrated": true,
      "planner_calls_this_command": 0,
      "reviser_calls_this_command": 0,
      "billable_plan_calls": 0,
      "active_step": activeId,
      "owner_pid": activePid,
      "step_state": "running",
      "provider_attempt_unknown": true,
      "action": "wait",
      "action_note":
        "Step is still active and waiting on the provider; do not start another step for it."
    }
    result.verdict = "active"
    result.message = "resumed; active step=" & activeId & " owner_pid=" & $activePid
    let store = openProjectStore(req.storePath)
    defer: closeProjectStore(store)
    emitProjectEvent(store, doc.projectId, "project.resume", result.report["resume"])
    return

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
  let completionIssue = if pending.found: "" else: incompletePlanReason(doc)
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
  elif completionIssue.len > 0:
    result.ok = false
    result.verdict = "blocked"
    result.message = completionIssue
    result.report["resume"] = %*{
      "rehydrated": true, "action": "revise", "action_note": result.message,
      "completed_steps": doneCount, "billable_plan_calls": 0
    }
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

proc resolveInject(req: ProjectRequest; name: string): string =
  if req.injectDir.len > 0:
    let p = req.injectDir / name
    if fileExists(p): return p
  if req.injectPath.len > 0 and name.len == 0:
    return req.injectPath
  ""

proc projectRun*(req: ProjectRequest): ProjectReport =
  ## Pilot walk through ask → (revise) → step* until binary accepted or explainable block.
  ## Reuses project services + journal lease (M1 transition serialization).
  result.command = "run"
  result.projectId = req.projectId
  result.untested = @[]
  result.providerCallsThisCommand = 0
  result.apiCallsThisCommand = 0
  if req.storePath.len == 0:
    result.ok = false
    result.verdict = "invalid"
    result.message = "run requires --store"
    return
  if req.cwd.len == 0 and req.objective.len == 0:
    result.ok = false
    result.verdict = "invalid"
    result.message = "run requires --cwd and --objective (or existing project)"
    return

  let store = openProjectStore(req.storePath)
  defer: closeProjectStore(store)
  let lease = claimProjectRunLease(store, req.projectId)
  if not lease.ok:
    result.ok = false
    result.verdict = "already_running"
    result.message = lease.message
    result.providerCallsThisCommand = 0
    result.apiCallsThisCommand = 0
    result.report = %*{
      "command": "project", "sub": "run", "ok": false,
      "verdict": "already_running", "message": lease.message,
      "holder_pid": lease.holderPid,
      "provider_calls_this_command": 0,
      "api_calls_this_command": 0
    }
    return
  defer: releaseProjectRunLease(store, req.projectId)

  var interventions = newJArray()
  var reqMut = req
  let maxSteps = if req.maxSteps > 0: req.maxSteps else: 8
  let maxAutoRevises = if req.maxAutoRevises > 0: req.maxAutoRevises else: 2
  var autoRevises = 0
  var totalProvider = 0
  var totalApi = 0
  var firstFaultyRaw = ""
  var firstFaultyDecision = ""

  template recordIntervention(kind: string; prep: ProjectReport) =
    interventions.add(%*{
      "kind": kind,
      "ok": prep.ok,
      "verdict": prep.verdict,
      "message": prep.message,
      "api_calls": prep.apiCallsThisCommand,
      "provider_calls": prep.providerCallsThisCommand
    })
    totalProvider += prep.providerCallsThisCommand
    totalApi += prep.apiCallsThisCommand
    for u in prep.untested: result.untested.add(u)
    if firstFaultyRaw.len == 0 and not prep.ok and prep.provider.rawText.len > 0:
      firstFaultyRaw = prep.provider.rawText
      firstFaultyDecision = prep.verdict

  # Refuse if a live step owner already spends the attempt (run↔step mutex).
  block checkLiveStep:
    let existingLive = loadProject(store, req.projectId)
    if existingLive.ok:
      for s in existingLive.doc.steps:
        if s.status == ssRunning and stepOwnerAlive(s) and
           providerOwnerPid(s) != getCurrentProcessId():
          result.ok = false
          result.verdict = "already_running"
          result.message =
            "step " & s.id & " already running owner_pid=" &
            $providerOwnerPid(s) & "; run will not double-spend"
          result.providerCallsThisCommand = 0
          result.apiCallsThisCommand = 0
          result.report = %*{
            "command": "project", "sub": "run", "ok": false,
            "verdict": "already_running", "message": result.message,
            "provider_calls_this_command": 0,
            "api_calls_this_command": 0
          }
          return

  let existing = loadProject(store, req.projectId)
  if not existing.ok:
    if req.objective.len == 0:
      result.ok = false
      result.verdict = "missing"
      result.message = existing.err
      return
    var askReq = reqMut
    askReq.injectPath = resolveInject(reqMut, "plan_v1.json")
    if askReq.injectPath.len == 0: askReq.injectPath = reqMut.injectPath
    let asked = projectAsk(askReq)
    recordIntervention("ask", asked)
    if not asked.ok:
      result = asked
      result.command = "run"
      result.providerCallsThisCommand = totalProvider
      result.apiCallsThisCommand = totalApi
      if result.report.isNil: result.report = newJObject()
      result.report["sub"] = %"run"
      result.report["interventions"] = interventions
      return
    result.doc = asked.doc

  var loaded = loadProject(store, req.projectId)
  if not loaded.ok:
    result.ok = false
    result.verdict = "missing"
    result.message = loaded.err
    return
  result.doc = loaded.doc

  ## Apply an explicit refinement once; resume/relaunch must not re-bump the plan.
  if req.refinement.len > 0 and result.doc.currentPlanVersion >= 1 and
     req.refinement notin result.doc.refinements:
    var revReq = reqMut
    let nextPlan = resolveInject(reqMut, "plan_v" & $(result.doc.currentPlanVersion + 1) & ".json")
    let v2 = resolveInject(reqMut, "plan_v2.json")
    revReq.injectPath =
      if nextPlan.len > 0: nextPlan
      elif v2.len > 0: v2
      else: reqMut.injectPath
    let revised = projectRevise(revReq)
    recordIntervention("revise", revised)
    if not revised.ok:
      result = revised
      result.command = "run"
      result.providerCallsThisCommand = totalProvider
      result.apiCallsThisCommand = totalApi
      if result.report.isNil: result.report = newJObject()
      result.report["sub"] = %"run"
      result.report["interventions"] = interventions
      return
    result.doc = revised.doc

  var stepIdx = 0
  while stepIdx < maxSteps:
    inc stepIdx
    loaded = loadProject(store, req.projectId)
    if not loaded.ok:
      result.ok = false
      result.verdict = "missing"
      result.message = loaded.err
      break
    result.doc = loaded.doc

    if result.doc.revisePlanPending or result.doc.recoveryExhausted:
      if autoRevises < maxAutoRevises:
        inc autoRevises
        var revReq = reqMut
        revReq.refinement = ""  # motif implémenteur suffit
        let postInj = resolveInject(reqMut, "plan_revise_postconditions.json")
        let autoInj = resolveInject(reqMut, "plan_v3_after_revise.json")
        if postInj.len > 0: revReq.injectPath = postInj
        elif autoInj.len > 0: revReq.injectPath = autoInj
        elif reqMut.injectPath.len > 0: revReq.injectPath = reqMut.injectPath
        let revised = projectRevise(revReq)
        recordIntervention("revise:auto", revised)
        if revised.ok:
          result.doc = revised.doc
          continue
        # Auto-revise failed → surface that block.
        result.ok = false
        result.verdict = revised.verdict
        result.message = revised.message
        result.doc = revised.doc
        result.providerCallsThisCommand = totalProvider
        result.apiCallsThisCommand = totalApi
        result.report = reportBase("run", revised.doc)
        result.report["sub"] = %"run"
        result.report["interventions"] = interventions
        result.report["provider_calls_this_command"] = %totalProvider
        result.report["api_calls_this_command"] = %totalApi
        result.report["blocked"] = %*{
          "kind": revised.verdict,
          "next_action": "revise",
          "reason": revised.message
        }
        if firstFaultyRaw.len > 0:
          result.report["first_faulty_raw"] = %firstFaultyRaw
          result.report["first_faulty_decision"] = %firstFaultyDecision
        return
      result.ok = false
      result.verdict =
        if result.doc.recoveryExhausted: "recovery_exhausted"
        else: "revise_plan_needed"
      result.message =
        if result.doc.recoveryExhausted: result.doc.recoveryExhaustedReason
        else: result.doc.revisePlanReason
      result.providerCallsThisCommand = totalProvider
      result.apiCallsThisCommand = totalApi
      result.report = reportBase("run", result.doc)
      result.report["sub"] = %"run"
      result.report["interventions"] = interventions
      result.report["provider_calls_this_command"] = %totalProvider
      result.report["api_calls_this_command"] = %totalApi
      result.report["blocked"] = %*{
        "kind": result.verdict,
        "next_action": "revise",
        "reason": result.message
      }
      if firstFaultyRaw.len > 0:
        result.report["first_faulty_raw"] = %firstFaultyRaw
        result.report["first_faulty_decision"] = %firstFaultyDecision
      return

    let actionable = nextActionableStep(result.doc)
    if not actionable.found:
      break

    var stepReq = reqMut
    let byId = resolveInject(reqMut, "step_" & actionable.step.id & ".json")
    let helpers = resolveInject(reqMut, "step_helpers.json")
    let exportInj = resolveInject(reqMut, "step_export.json")
    let markRet = resolveInject(reqMut, "step_mark_returned.json")
    let helloInj = resolveInject(reqMut, "step_hello.json")
    if byId.len > 0:
      stepReq.injectPath = byId
    elif actionable.step.id == "add_csv_helpers" and helpers.len > 0:
      stepReq.injectPath = helpers
    elif actionable.step.id == "mark_returned" and markRet.len > 0:
      stepReq.injectPath = markRet
    elif actionable.step.id == "create_hello" and helloInj.len > 0:
      stepReq.injectPath = helloInj
    elif ("export" in actionable.step.id.toLowerAscii or
          "export" in actionable.step.title.toLowerAscii) and exportInj.len > 0:
      stepReq.injectPath = exportInj
    elif helpers.len > 0 and stepIdx == 1:
      stepReq.injectPath = helpers
    elif exportInj.len > 0:
      stepReq.injectPath = exportInj
    elif markRet.len > 0 and "return" in actionable.step.id.toLowerAscii:
      stepReq.injectPath = markRet
    elif helloInj.len > 0 and "hello" in actionable.step.id.toLowerAscii:
      stepReq.injectPath = helloInj
    elif reqMut.injectPath.len > 0:
      stepReq.injectPath = reqMut.injectPath
    if reqMut.worktree.len > 0:
      # Unique dir per attempt — reuse after revise/repair must not hit occupied.
      stepReq.worktree = reqMut.worktree /
        ("step_" & actionable.step.id & "_a" & $stepIdx & "_" & $autoRevises)
    let stepped = projectStep(stepReq)
    recordIntervention("step:" & actionable.step.id, stepped)
    result.apply = stepped.apply
    result.verify = stepped.verify
    result.provider = stepped.provider
    result.recoveryProvider = stepped.recoveryProvider
    result.recoveryTriggered = stepped.recoveryTriggered
    result.recoveryAttempted = stepped.recoveryAttempted
    result.recoveryReason = stepped.recoveryReason
    result.doc = stepped.doc
    if not stepped.ok:
      if autoRevises < maxAutoRevises and
         (stepped.doc.revisePlanPending or stepped.doc.recoveryExhausted):
        continue
      result.ok = false
      result.verdict = stepped.verdict
      result.message = stepped.message
      result.providerCallsThisCommand = totalProvider
      result.apiCallsThisCommand = totalApi
      result.report = if stepped.report.isNil: reportBase("run", stepped.doc)
                      else: stepped.report
      result.report["sub"] = %"run"
      result.report["interventions"] = interventions
      result.report["provider_calls_this_command"] = %totalProvider
      result.report["api_calls_this_command"] = %totalApi
      result.report["blocked"] = %*{
        "kind": stepped.verdict,
        "step_id": actionable.step.id,
        "next_action": stepped.doc.nextAction,
        "message": stepped.message
      }
      if firstFaultyRaw.len > 0:
        result.report["first_faulty_raw"] = %firstFaultyRaw
        result.report["first_faulty_decision"] = %firstFaultyDecision
      elif stepped.provider.rawText.len > 0:
        result.report["first_faulty_raw"] = %stepped.provider.rawText
        result.report["first_faulty_decision"] = %stepped.verdict
      return
    if req.pauseAfterStep:
      result.ok = true
      result.verdict = "paused_after_step"
      result.message = "paused after step " & actionable.step.id
      result.providerCallsThisCommand = totalProvider
      result.apiCallsThisCommand = totalApi
      result.report = reportBase("run", result.doc)
      result.report["sub"] = %"run"
      result.report["interventions"] = interventions
      result.report["provider_calls_this_command"] = %totalProvider
      result.report["api_calls_this_command"] = %totalApi
      result.report["paused_after_step"] = %actionable.step.id
      return

  loaded = loadProject(store, req.projectId)
  if loaded.ok: result.doc = loaded.doc
  let pending = nextPendingStep(result.doc)
  result.providerCallsThisCommand = totalProvider
  result.apiCallsThisCommand = totalApi
  if result.verdict.len == 0:
    if pending.found:
      result.ok = false
      result.verdict = "step_ceiling"
      result.message = "max steps reached with pending work"
    else:
      let reason = incompletePlanReason(result.doc)
      result.ok = reason.len == 0
      result.verdict = if result.ok: "done" else: "blocked"
      result.message = if result.ok: "project run complete; accepted tree ready" else: reason
  result.report = reportBase("run", result.doc)
  result.report["sub"] = %"run"
  result.report["interventions"] = interventions
  result.report["provider_calls_this_command"] = %totalProvider
  result.report["api_calls_this_command"] = %totalApi
  result.report["provider_calls"] = %totalProvider
  result.report["api_calls"] = %totalApi
  result.report["replayed"] = %false
  if result.doc.acceptedTreeRef.len > 0:
    result.report["delivered_tree"] = %result.doc.acceptedTreeRef
    result.report["delivered_hash"] = %result.doc.acceptedTreeHash
  if result.untested.len > 0:
    result.report["untested"] = %result.untested
