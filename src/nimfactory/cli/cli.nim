## Minimal M1 CLI: validate, run, resume, inspect, events (F16).

import std/[os, parseopt, strutils, json, sequtils]
import nimfactory/contracts/[errors, result]
import nimfactory/runtime/executor/types
import nimfactory/application/compose
import nimfactory/runtime/executor/executor

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

Options:
  --mode sequential|concurrent
  --max-concurrency N
  --pipe-capacity N
  --pipe-policy wait|reject|spill
  --checkpoint-after N
  --deadline-ms N
  --input PATH
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
  if args.len == 0:
    result.help = true
    return
  result.cmd = args[0]
  var p = initOptParser(args[1..^1], shortNoVal = {'h'},
                        longNoVal = @["json", "human", "help"])
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
      of "json":
        result.jsonMode = true
      of "human":
        result.jsonMode = false
      of "h", "help":
        result.help = true
      else:
        result.err = "unknown option: " & p.key
    of cmdArgument:
      result.err = "unexpected argument: " & p.key

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
