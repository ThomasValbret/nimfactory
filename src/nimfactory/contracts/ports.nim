## Conceptual ports for Wave A development. Implementations live in owning lots.
## F0 only defines the interface shapes and in-memory stubs for contract tests.

import std/json
import ./ids
import ./result

type
  ArtifactManifest* = object
    id*: ArtifactRef
    hashAlg*: string
    hash*: string
    mime*: string
    size*: int64
    origin*: string

  PutResult* = object
    id*: ArtifactRef
    created*: bool

  ArtifactStore* = ref object of RootObj

  SnapshotSource* = ref object of RootObj

  RunStore* = ref object of RootObj

  BudgetLedger* = ref object of RootObj

  GraphValidator* = ref object of RootObj

  HandlerRegistry* = ref object of RootObj

method put*(s: ArtifactStore; data: string; mime, origin: string): PutResult {.base.} =
  raise newException(CatchableError, "ArtifactStore.put not implemented")

method read*(s: ArtifactStore; id: ArtifactRef): string {.base.} =
  raise newException(CatchableError, "ArtifactStore.read not implemented")

method describe*(s: ArtifactStore; id: ArtifactRef): ArtifactManifest {.base.} =
  raise newException(CatchableError, "ArtifactStore.describe not implemented")

method appendEvent*(s: RunStore; runId: string; event: JsonNode) {.base.} =
  raise newException(CatchableError, "RunStore.appendEvent not implemented")

method commitTransition*(s: RunStore; runId: string; transition: JsonNode): JsonNode {.base.} =
  raise newException(CatchableError, "RunStore.commitTransition not implemented")

method recover*(s: RunStore; runId: string): JsonNode {.base.} =
  raise newException(CatchableError, "RunStore.recover not implemented")

method reserve*(l: BudgetLedger; scope, attemptId: string; maxSends: int;
                maxMicroUsd: string): JsonNode {.base.} =
  raise newException(CatchableError, "BudgetLedger.reserve not implemented")

method settle*(l: BudgetLedger; reservationId: string; usage: JsonNode) {.base.} =
  raise newException(CatchableError, "BudgetLedger.settle not implemented")

method markUnknown*(l: BudgetLedger; reservationId: string; reason: string) {.base.} =
  raise newException(CatchableError, "BudgetLedger.markUnknown not implemented")

method releaseBeforeSend*(l: BudgetLedger; reservationId: string) {.base.} =
  raise newException(CatchableError, "BudgetLedger.releaseBeforeSend not implemented")

method validate*(v: GraphValidator; graph: JsonNode): CommonResult {.base.} =
  raise newException(CatchableError, "GraphValidator.validate not implemented")
