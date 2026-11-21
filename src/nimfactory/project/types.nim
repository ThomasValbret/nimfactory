## Project mission document persisted in SqliteRunStore.state_json.

import std/[json, tables]

type
  StepStatus* = enum
    ssPending = "pending"
    ssRunning = "running"
    ssDone = "done"
    ssBlocked = "blocked"

  UsageRollup* = object
    promptTokens*: int
    completionTokens*: int
    calls*: int
    estimatedUsd*: float
    model*: string

  ProjectStep* = object
    id*: string
    title*: string
    dependsOn*: seq[string]
    status*: StepStatus
    mandateKey*: string
    result*: JsonNode

  PlanVersion* = object
    version*: int
    summary*: string
    hypothesis*: string
    steps*: seq[ProjectStep]
    raw*: JsonNode

  ProjectDoc* = object
    kind*: string
    projectId*: string
    cwd*: string
    objective*: string
    refinements*: seq[string]
    planVersions*: seq[PlanVersion]
    currentPlanVersion*: int
    steps*: seq[ProjectStep]
    mandates*: JsonNode          ## key -> mandate object
    usageByRole*: Table[string, UsageRollup]
    worktree*: string
    lastVerdict*: string
    lastDiff*: string
    blockedReason*: string
    nextAction*: string

proc emptyUsage*(): UsageRollup =
  UsageRollup(promptTokens: 0, completionTokens: 0, calls: 0, estimatedUsd: 0.0, model: "")

proc estimateUsd*(prompt, completion: int): float =
  ## gpt-4o-mini list-price arithmetic (same as E2E campaign scripts).
  prompt.float * 0.15e-6 + completion.float * 0.60e-6

proc addUsage*(u: var UsageRollup; prompt, completion: int; model: string) =
  u.promptTokens += prompt
  u.completionTokens += completion
  u.calls += 1
  u.estimatedUsd += estimateUsd(prompt, completion)
  if model.len > 0:
    u.model = model

proc stepStatusFromStr*(s: string): StepStatus =
  case s
  of "running": ssRunning
  of "done": ssDone
  of "blocked": ssBlocked
  else: ssPending

proc `$`*(s: StepStatus): string =
  case s
  of ssPending: "pending"
  of ssRunning: "running"
  of ssDone: "done"
  of ssBlocked: "blocked"

proc usageToJson*(u: UsageRollup): JsonNode =
  %*{
    "prompt_tokens": u.promptTokens,
    "completion_tokens": u.completionTokens,
    "calls": u.calls,
    "estimated_usd": u.estimatedUsd,
    "model": u.model
  }

proc usageFromJson*(j: JsonNode): UsageRollup =
  if j.isNil or j.kind != JObject:
    return emptyUsage()
  result.promptTokens = j{"prompt_tokens"}.getInt
  result.completionTokens = j{"completion_tokens"}.getInt
  result.calls = j{"calls"}.getInt
  result.estimatedUsd = j{"estimated_usd"}.getFloat
  result.model = j{"model"}.getStr

proc stepToJson*(s: ProjectStep): JsonNode =
  var deps = newJArray()
  for d in s.dependsOn: deps.add(%d)
  %*{
    "id": s.id,
    "title": s.title,
    "depends_on": deps,
    "status": $s.status,
    "mandate_key": s.mandateKey,
    "result": if s.result.isNil: newJObject() else: s.result
  }

proc stepFromJson*(j: JsonNode): ProjectStep =
  result.id = j{"id"}.getStr
  result.title = j{"title"}.getStr
  result.status = stepStatusFromStr(j{"status"}.getStr("pending"))
  result.mandateKey = j{"mandate_key"}.getStr
  result.result = j{"result"}
  if result.result.isNil: result.result = newJObject()
  result.dependsOn = @[]
  let deps = j{"depends_on"}
  if deps != nil and deps.kind == JArray:
    for d in deps: result.dependsOn.add(d.getStr)

proc planToJson*(p: PlanVersion): JsonNode =
  var steps = newJArray()
  for s in p.steps: steps.add(stepToJson(s))
  %*{
    "version": p.version,
    "summary": p.summary,
    "hypothesis": p.hypothesis,
    "steps": steps,
    "raw": if p.raw.isNil: newJObject() else: p.raw
  }

proc planFromJson*(j: JsonNode): PlanVersion =
  result.version = j{"version"}.getInt
  result.summary = j{"summary"}.getStr
  result.hypothesis = j{"hypothesis"}.getStr
  result.raw = j{"raw"}
  if result.raw.isNil: result.raw = newJObject()
  result.steps = @[]
  let steps = j{"steps"}
  if steps != nil and steps.kind == JArray:
    for s in steps: result.steps.add(stepFromJson(s))

proc docToJson*(d: ProjectDoc): JsonNode =
  var plans = newJArray()
  for p in d.planVersions: plans.add(planToJson(p))
  var steps = newJArray()
  for s in d.steps: steps.add(stepToJson(s))
  var refinements = newJArray()
  for r in d.refinements: refinements.add(%r)
  var usage = newJObject()
  for k, v in d.usageByRole: usage[k] = usageToJson(v)
  %*{
    "kind": d.kind,
    "project_id": d.projectId,
    "cwd": d.cwd,
    "objective": d.objective,
    "refinements": refinements,
    "plan_versions": plans,
    "current_plan_version": d.currentPlanVersion,
    "steps": steps,
    "mandates": if d.mandates.isNil: newJObject() else: d.mandates,
    "usage_by_role": usage,
    "worktree": d.worktree,
    "last_verdict": d.lastVerdict,
    "last_diff": d.lastDiff,
    "blocked_reason": d.blockedReason,
    "next_action": d.nextAction
  }

proc docFromJson*(j: JsonNode): ProjectDoc =
  result.kind = j{"kind"}.getStr("project_mission")
  result.projectId = j{"project_id"}.getStr
  result.cwd = j{"cwd"}.getStr
  result.objective = j{"objective"}.getStr
  result.currentPlanVersion = j{"current_plan_version"}.getInt
  result.worktree = j{"worktree"}.getStr
  result.lastVerdict = j{"last_verdict"}.getStr
  result.lastDiff = j{"last_diff"}.getStr
  result.blockedReason = j{"blocked_reason"}.getStr
  result.nextAction = j{"next_action"}.getStr
  result.mandates = j{"mandates"}
  if result.mandates.isNil: result.mandates = newJObject()
  result.refinements = @[]
  let refs = j{"refinements"}
  if refs != nil and refs.kind == JArray:
    for r in refs: result.refinements.add(r.getStr)
  result.planVersions = @[]
  let plans = j{"plan_versions"}
  if plans != nil and plans.kind == JArray:
    for p in plans: result.planVersions.add(planFromJson(p))
  result.steps = @[]
  let steps = j{"steps"}
  if steps != nil and steps.kind == JArray:
    for s in steps: result.steps.add(stepFromJson(s))
  result.usageByRole = initTable[string, UsageRollup]()
  let usage = j{"usage_by_role"}
  if usage != nil and usage.kind == JObject:
    for k, v in usage.pairs:
      result.usageByRole[k] = usageFromJson(v)

proc currentPlan*(d: ProjectDoc): PlanVersion =
  for p in d.planVersions:
    if p.version == d.currentPlanVersion:
      return p
  if d.planVersions.len > 0:
    return d.planVersions[^1]
  PlanVersion(version: 0)

proc nextPendingStep*(d: ProjectDoc): tuple[found: bool; step: ProjectStep] =
  for s in d.steps:
    if s.status == ssPending:
      return (true, s)
  (false, ProjectStep())
