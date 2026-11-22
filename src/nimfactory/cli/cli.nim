## Minimal M1 CLI: validate, run, resume, inspect, events (F16) + mission-fix + project.

import std/[os, parseopt, strutils, json, sequtils]
import nimfactory/contracts/[errors, result]
import nimfactory/runtime/executor/types
import nimfactory/application/compose
import nimfactory/runtime/executor/executor
import nimfactory/mission/pipeline
import nimfactory/project/pipeline
import nimfactory/project/store
import nimfactory/application/project_view
import nimfactory/application/project_command

const
  ExitOk* = 0
  ExitInvalid* = 2
  ExitBlocked* = 3
  ExitFailed* = 4
  ## Conceptual F16 code is 130; Nim 2.4 on this host clamps exit>127 to 127
  ## (ambiguous with ENOENT). M1 uses 5 so scripts can distinguish interruption.
  ExitInterrupted* = 5

type
  CliOptions = object
    cmd: string
    sub: string
    graph: string
    store: string
    runId: string
    mode: string
    maxConcurrency: int
    pipeCapacity: int
    pipePolicy: string
    checkpointAfter: int
    deadlineMs: int64
    input: string
    jsonMode: bool
    help: bool
    err: string
    repo: string
    symptom: string
    oracle: string
    worktree: string
    route: string
    inject: string
    injectRecovery: string
    localModel: string
    target: string
    diagnosis: string
    constraint: string
    recoveryApi: bool
    cwd: string
    projectId: string
    objective: string
    refinement: string
    artifactDir: string
    replayFirst: string
    historicalProvenance: string
    commandId: string
    expectedPlanVersion: int
    hasExpectedPlanVersion: bool
    positional: seq[string]

proc writeHuman(msg: string) =
  stderr.writeLine(msg)

proc writeMachine(node: JsonNode) =
  stdout.writeLine($node)

proc usage() =
  writeHuman("""
nimfactory — local deterministic execution (M1)

Commands:
  validate --graph PATH
  run --graph PATH --store PATH --run-id ID [options]
  resume --store PATH --run-id ID --graph PATH [options]
  inspect --store PATH --run-id ID
  events --store PATH --run-id ID
  mission-fix --repo PATH --oracle PATH --route api|local|inject [options]
  project ask|revise|step|status|resume|snapshot --store PATH [options]

Options:
  --mode sequential|concurrent
  --max-concurrency N
  --pipe-capacity N
  --pipe-policy wait|reject|spill
  --checkpoint-after N
  --deadline-ms N
  --input PATH
  --repo PATH           fixture repo root for mission-fix
  --symptom PATH        pilot symptom file (or repo/SYMPTOM.md)
  --oracle PATH         reception tests directory (required)
  --worktree PATH       empty/new apply directory (refuse if occupied)
  --route api|local|inject
  --inject PATH         injected model JSON (non-qualifying)
  --inject-recovery PATH  offline second inject after no-op / functional fail
  --replay-first PATH   historical first raw for project step (no new bill)
  --historical-provenance TEXT  provenance note for replayed first attempt
  --local-model NAME    ollama model for local micro-patch route
  --target PATH         local: established file to patch
  --diagnosis TEXT      local: established diagnosis
  --constraint TEXT     local: constraint to preserve
  --recovery-api        after inject first turn, recovery uses planned OpenAI API
  --cwd PATH            project root (AGENTS.md + src/)
  --project-id ID       project id (default demo_tasks_cli)
  --objective TEXT      initial pilot request (project ask)
  --refinement TEXT     pilot precision (project revise)
  --artifact-dir PATH   write plan/mandate/verify artifacts
  --command-id ID       idempotent project write command key
  --expected-plan-version N  refuse revise if plan moved
  --json                machine mode (stdout JSON only; default)
""")

proc takeValue(p: var OptParser): string =
  if p.val.len > 0:
    return p.val
  p.next()
  if p.kind == cmdArgument:
    return p.key
  ""

proc parseArgs(args: seq[string]): CliOptions =
  result.mode = "sequential"
  result.maxConcurrency = 2
  result.pipeCapacity = 8
  result.pipePolicy = "wait"
  result.checkpointAfter = 0
  result.deadlineMs = 0
  result.jsonMode = true
  result.route = "api"
  result.localModel = "qwen2.5-coder:7b"
  result.projectId = "demo_tasks_cli"
  result.expectedPlanVersion = -1
  result.hasExpectedPlanVersion = false
  result.positional = @[]
  if args.len == 0:
    result.help = true
    return
  result.cmd = args[0]
  var rest = args[1..^1]
  if result.cmd == "project" and rest.len > 0 and not rest[0].startsWith("-"):
    result.sub = rest[0]
    rest = rest[1..^1]
  var p = initOptParser(rest, shortNoVal = {'h'},
                        longNoVal = @["json", "human", "help", "recovery-api"])
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "graph":
        result.graph = takeValue(p)
      of "store":
        result.store = takeValue(p)
      of "run-id":
        result.runId = takeValue(p)
      of "mode":
        result.mode = takeValue(p)
      of "max-concurrency":
        result.maxConcurrency = parseInt(takeValue(p))
      of "pipe-capacity":
        result.pipeCapacity = parseInt(takeValue(p))
      of "pipe-policy":
        result.pipePolicy = takeValue(p)
      of "checkpoint-after":
        result.checkpointAfter = parseInt(takeValue(p))
      of "deadline-ms":
        result.deadlineMs = parseBiggestInt(takeValue(p))
      of "input":
        result.input = takeValue(p)
      of "repo":
        result.repo = takeValue(p)
      of "symptom":
        result.symptom = takeValue(p)
      of "oracle":
        result.oracle = takeValue(p)
      of "worktree":
        result.worktree = takeValue(p)
      of "route":
        result.route = takeValue(p)
      of "inject":
        result.inject = takeValue(p)
      of "inject-recovery":
        result.injectRecovery = takeValue(p)
      of "replay-first":
        result.replayFirst = takeValue(p)
      of "historical-provenance":
        result.historicalProvenance = takeValue(p)
      of "local-model":
        result.localModel = takeValue(p)
      of "target":
        result.target = takeValue(p)
      of "diagnosis":
        result.diagnosis = takeValue(p)
      of "constraint":
        result.constraint = takeValue(p)
      of "cwd":
        result.cwd = takeValue(p)
      of "project-id":
        result.projectId = takeValue(p)
      of "objective":
        result.objective = takeValue(p)
      of "refinement":
        result.refinement = takeValue(p)
      of "artifact-dir":
        result.artifactDir = takeValue(p)
      of "command-id":
        result.commandId = takeValue(p)
      of "expected-plan-version":
        result.expectedPlanVersion = parseInt(takeValue(p))
        result.hasExpectedPlanVersion = true
      of "recovery-api":
        result.recoveryApi = true
      of "json":
        result.jsonMode = true
      of "human":
        result.jsonMode = false
      of "h", "help":
        result.help = true
      else:
        result.err = "unknown option: " & p.key
    of cmdArgument:
      result.positional.add(p.key)

proc toConfig(o: CliOptions): ExecConfig =
  result = defaultExecConfig()
  result.mode = parseExecMode(o.mode)
  result.maxConcurrency = o.maxConcurrency
  result.pipeCapacity = o.pipeCapacity
  result.pipePolicy = parsePipePolicy(o.pipePolicy)
  result.checkpointAfter = o.checkpointAfter
  result.deadlineMs = o.deadlineMs
  if o.store.len > 0:
    result.spillDir = o.store & ".spill"

proc loadInputs(o: CliOptions): JsonNode =
  var path = o.input
  if path.len == 0:
    let fallback = "tests/fixtures/m1/input.json"
    if fileExists(fallback):
      path = fallback
  if path.len == 0:
    return %*{"start": newJObject()}
  parseJson(readFile(path))

proc statusExit(st: ExecStatus): int =
  case st
  of esCompleted: ExitOk
  of esInterrupted: ExitInterrupted
  of esCancelled: ExitInterrupted
  of esTimedOut: ExitFailed
  of esFailed: ExitFailed

proc runCli*(args: seq[string]): int =
  let o = parseArgs(args)
  if o.help or o.cmd in ["-h", "--help", "help"]:
    usage()
    return if o.cmd.len == 0: ExitInvalid else: ExitOk
  if o.err.len > 0:
    writeHuman(o.err)
    return ExitInvalid
  try:
    case o.cmd
    of "validate":
      if o.graph.len == 0:
        writeHuman("validate requires --graph")
        return ExitInvalid
      let r = validateGraphFile(o.graph)
      writeMachine(%*{
        "command": "validate",
        "status": $r.status,
        "diagnostics": r.diagnostics.mapIt(%*{
          "code": it.code, "phase": it.phase, "message": it.message
        }),
        "error": r.errorReason
      })
      if r.status == rsOk: return ExitOk
      elif r.status == rsBlocked: return ExitBlocked
      else: return ExitInvalid
    of "run":
      if o.graph.len == 0 or o.store.len == 0 or o.runId.len == 0:
        writeHuman("run requires --graph --store --run-id")
        return ExitInvalid
      let report = runDemoGraph(o.store, o.graph, o.runId, loadInputs(o), toConfig(o))
      writeMachine(reportToJson(report))
      return statusExit(report.status)
    of "resume":
      if o.graph.len == 0 or o.store.len == 0 or o.runId.len == 0:
        writeHuman("resume requires --graph --store --run-id")
        return ExitInvalid
      var cfg = toConfig(o)
      cfg.checkpointAfter = 0
      let report = resumeDemoGraph(o.store, o.graph, o.runId, cfg)
      writeMachine(reportToJson(report))
      return statusExit(report.status)
    of "inspect":
      if o.store.len == 0 or o.runId.len == 0:
        writeHuman("inspect requires --store --run-id")
        return ExitInvalid
      writeMachine(%*{
        "command": "inspect",
        "run": inspectRun(o.store, o.runId)
      })
      return ExitOk
    of "events":
      if o.store.len == 0 or o.runId.len == 0:
        writeHuman("events requires --store --run-id")
        return ExitInvalid
      let ev = listEvents(o.store, o.runId)
      if ev.kind == JArray:
        for e in ev:
          writeMachine(e)
      else:
        writeMachine(ev)
      return ExitOk
    of "mission-fix":
      if o.repo.len == 0:
        writeHuman("mission-fix requires --repo")
        return ExitInvalid
      if o.oracle.len == 0:
        writeHuman("mission-fix requires --oracle")
        return ExitInvalid
      if o.route == "inject" and o.inject.len == 0:
        writeHuman("mission-fix --route inject requires --inject")
        return ExitInvalid
      if o.route == "local" and (o.target.len == 0 or o.diagnosis.len == 0):
        writeHuman("mission-fix --route local requires --target and --diagnosis")
        return ExitInvalid
      var req = defaultMissionRequest()
      req.repoRoot = o.repo
      req.symptomPath = o.symptom
      req.oracleDir = o.oracle
      req.worktreeRoot = o.worktree
      req.route = o.route
      req.injectPath = o.inject
      req.injectRecoveryPath = o.injectRecovery
      req.localModel = o.localModel
      req.targetFile = o.target
      req.diagnosis = o.diagnosis
      req.constraint = o.constraint
      req.recoveryViaApi = o.recoveryApi
      let report = runMission(req)
      var outNode = reportToJson(report)
      outNode["command"] = %"mission-fix"
      writeMachine(outNode)
      if report.ok: return ExitOk
      if report.verdict == "api_unavailable": return ExitBlocked
      if report.verdict == "oracle_missing": return ExitInvalid
      return ExitFailed
    of "project":
      if o.sub.len == 0:
        writeHuman("project requires subcommand: ask|revise|step|status|resume|snapshot")
        return ExitInvalid
      if o.sub == "snapshot":
        writeMachine(readProjectView(o.store, o.projectId))
        return ExitOk
      var preq = defaultProjectRequest()
      preq.storePath = o.store
      preq.projectId = o.projectId
      preq.cwd = o.cwd
      preq.objective = o.objective
      preq.refinement = o.refinement
      preq.route = o.route
      preq.injectPath = o.inject
      preq.injectRecoveryPath = o.injectRecovery
      preq.replayFirstPath = o.replayFirst
      preq.historicalProvenance = o.historicalProvenance
      preq.worktree = o.worktree
      preq.artifactDir = o.artifactDir
      preq.commandId = o.commandId
      if o.hasExpectedPlanVersion:
        preq.expectedPlanVersion = o.expectedPlanVersion
        preq.expectPlanVersion = true
      if preq.objective.len == 0 and o.positional.len > 0:
        preq.objective = o.positional.join(" ")
      if preq.refinement.len == 0 and o.sub == "revise" and o.positional.len > 0:
        preq.refinement = o.positional.join(" ")
      if o.route == "inject" and o.inject.len == 0 and o.replayFirst.len == 0 and
         o.sub in ["ask", "revise", "step"]:
        writeHuman("project " & o.sub & " --route inject requires --inject (or --replay-first for step)")
        return ExitInvalid
      var prep: ProjectReport
      case o.sub
      of "ask":
        prep = projectAsk(preq)
      of "revise":
        prep = executeRevisePlan(preq)
      of "step":
        prep = projectStep(preq)
      of "status":
        prep = projectStatus(preq)
      of "resume":
        prep = projectResume(preq)
      else:
        writeHuman("unknown project subcommand: " & o.sub)
        return ExitInvalid
      var outNode =
        if prep.report.isNil: %*{"command": "project", "sub": o.sub}
        else: prep.report
      outNode["ok"] = %prep.ok
      outNode["verdict"] = %prep.verdict
      outNode["message"] = %prep.message
      outNode["run_id"] = %projectRunId(preq.projectId)
      writeMachine(outNode)
      if prep.ok: return ExitOk
      if prep.verdict == "api_unavailable": return ExitBlocked
      if prep.verdict in ["invalid", "missing"]: return ExitInvalid
      return ExitFailed
    else:
      writeHuman("unknown command: " & o.cmd)
      usage()
      return ExitInvalid
  except FactoryError as e:
    writeHuman("error: " & e.msg)
    writeMachine(%*{
      "error": e.msg,
      "code": $e.code,
      "phase": e.phase
    })
    return ExitFailed
  except CatchableError as e:
    writeHuman("error: " & e.msg)
    writeMachine(%*{"error": e.msg})
    return ExitFailed
