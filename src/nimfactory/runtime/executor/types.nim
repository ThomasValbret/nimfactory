## F5 executor types: modes, pipes, invocation context, reports.

import std/[json, tables, times]
import nimfactory/contracts/errors

type
  ExecMode* = enum
    emSequential = "sequential"
    emConcurrent = "concurrent"

  PipePolicy* = enum
    ppWait = "wait"
    ppReject = "reject"
    ppSpill = "spill"

  ExecStatus* = enum
    esCompleted = "completed"
    esInterrupted = "interrupted"
    esFailed = "failed"
    esCancelled = "cancelled"
    esTimedOut = "timed_out"

  InvocationContext* = object
    runId*: string
    activationId*: string
    attemptId*: string
    epoch*: int
    branchKey*: string
    deadlineMs*: int64          ## absolute epoch ms; 0 = none
    cancelled*: bool
    mode*: ExecMode

  PipeStats* = object
    enqueued*: int
    dequeued*: int
    rejected*: int
    spilled*: int
    waited*: int
    peakDepth*: int

  ExecConfig* = object
    mode*: ExecMode
    maxConcurrency*: int
    pipeCapacity*: int
    pipePolicy*: PipePolicy
    checkpointAfter*: int       ## 0 = disabled; stop after N durable activation commits
    deadlineMs*: int64          ## relative wall-clock budget from start; 0 = none
    cancelRequested*: bool      ## cooperative cancel before/during handlers
    ownerToken*: string
    spillDir*: string           ## for spill policy persistence

  ActivationRecord* = object
    activationId*: string
    nodeId*: string
    branchKey*: string
    status*: string
    outputs*: JsonNode
    attemptId*: string

  ExecReport* = object
    runId*: string
    status*: ExecStatus
    mode*: ExecMode
    outputs*: JsonNode
    activations*: seq[ActivationRecord]
    activationCommits*: int
    pipeStats*: PipeStats
    peakConcurrentInvocations*: int
    events*: seq[JsonNode]
    error*: string
    resumed*: bool
    skippedValidated*: seq[string]

proc defaultExecConfig*(): ExecConfig =
  ExecConfig(
    mode: emSequential,
    maxConcurrency: 1,
    pipeCapacity: 8,
    pipePolicy: ppWait,
    checkpointAfter: 0,
    deadlineMs: 0,
    cancelRequested: false,
    ownerToken: "local-executor",
    spillDir: ""
  )

proc parseExecMode*(s: string): ExecMode =
  case s
  of "sequential": emSequential
  of "concurrent": emConcurrent
  else:
    raise newFactoryError(fecValidationFailed, "unknown exec mode: " & s,
      phase = "executor")

proc parsePipePolicy*(s: string): PipePolicy =
  case s
  of "wait": ppWait
  of "reject": ppReject
  of "spill": ppSpill
  else:
    raise newFactoryError(fecValidationFailed, "unknown pipe policy: " & s,
      phase = "executor")

proc nowMs*(): int64 =
  (epochTime() * 1000).int64

proc deadlineExceeded*(ctx: InvocationContext): bool =
  ctx.deadlineMs > 0 and nowMs() > ctx.deadlineMs
