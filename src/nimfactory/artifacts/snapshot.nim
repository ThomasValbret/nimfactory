## SnapshotSource: materialize mutable sources as artifacts; sealed snapshots.

import std/[os, json, tables]
import ../contracts/[ids, errors, ports]
import ./types
import ./store
import ./sha256

type
  LocalSnapshotSource* = ref object of SnapshotSource
    store*: DirectoryArtifactStore
    root*: string
    snapshots*: Table[string, SourceSnapshot]
    readSets*: Table[string, ReadSet]

proc newLocalSnapshotSource*(store: DirectoryArtifactStore;
                            root: string = ""): LocalSnapshotSource =
  let snapRoot = if root.len > 0: root else: store.root / "snapshots"
  createDir(snapRoot)
  LocalSnapshotSource(store: store, root: snapRoot,
                      snapshots: initTable[string, SourceSnapshot](),
                      readSets: initTable[string, ReadSet]())

proc captureSourceFile(store: DirectoryArtifactStore;
                       spec: SourceSpec): SourceRevision =
  if not fileExists(spec.path):
    raise newFactoryError(fecMissingRequiredInput,
      "source file missing: " & spec.path, phase = "snapshot")
  let bytes = readFile(spec.path)
  let label = if spec.revisionLabel.len > 0: spec.revisionLabel else: spec.sourceId
  let origin = "source:" & spec.sourceId & "@" & label
  let put = store.put(bytes, "application/octet-stream", origin)
  let manifest = store.describe(put.id)
  SourceRevision(
    sourceId: spec.sourceId,
    artifactRef: put.id,
    contentHash: manifest.hash,
    revisionLabel: label
  )

proc capture*(src: LocalSnapshotSource;
              req: SourceCaptureRequest): tuple[snapshot: SourceSnapshot, readSet: ReadSet] =
  var revisions: seq[SourceRevision] = @[]
  for spec in req.sources:
    revisions.add(captureSourceFile(src.store, spec))
  var snapSeed = ""
  for r in revisions:
    snapSeed.add(r.contentHash)
  snapSeed.add($req.chamberRevisions)
  let snapshotId = "snap-" & sha256Hex(snapSeed)[0 ..< 16]
  var snapshot = SourceSnapshot(
    snapshotId: snapshotId,
    capturedAt: utcNowIso(),
    sealed: true,
    sourceRevisions: revisions,
    chamberRevisions: req.chamberRevisions,
    recipeRefs: req.recipeRefs,
    indexRevisions: req.indexRevisions,
    manifestRef: artifactRef("")
  )
  let snapJson = $snapshotToJson(snapshot)
  let put = src.store.put(snapJson, "application/json", "snapshot:" & snapshotId)
  snapshot.manifestRef = put.id
  src.snapshots[snapshotId] = snapshot

  var entries: seq[ReadSetEntry] = @[]
  for r in revisions:
    entries.add(ReadSetEntry(
      kind: "source_capture",
      sourceId: r.sourceId,
      artifactRef: r.artifactRef,
      revision: r.contentHash,
      selector: "",
      emptySearch: false
    ))
  let rsId = "readset-" & snapshotId
  let readSet = ReadSet(
    readSetId: rsId,
    snapshotId: snapshotId,
    version: 1,
    entries: entries
  )
  src.readSets[rsId] = readSet
  let rsJson = $readSetToJson(readSet)
  discard src.store.put(rsJson, "application/json", "readset:" & rsId)
  (snapshot, readSet)

proc resolveSource*(src: LocalSnapshotSource; snapshot: SourceSnapshot;
                   sourceId: string): string =
  for r in snapshot.sourceRevisions:
    if r.sourceId == sourceId:
      return src.store.read(r.artifactRef)
  raise newFactoryError(fecMissingRequiredInput,
    "source not in snapshot: " & sourceId, phase = "snapshot")

proc reloadSnapshot*(src: LocalSnapshotSource; snapshotId: string): SourceSnapshot =
  if snapshotId in src.snapshots:
    return src.snapshots[snapshotId]
  raise newFactoryError(fecMissingRequiredInput,
    "unknown snapshot " & snapshotId, phase = "snapshot")

proc appendRead*(src: LocalSnapshotSource; snapshot: SourceSnapshot;
                 entry: ReadSetEntry): ReadSet =
  ## Adds a read entry without mutating the sealed snapshot; bumps read set version.
  let prevKey = "readset-" & snapshot.snapshotId
  var version = 1
  if prevKey in src.readSets:
    version = src.readSets[prevKey].version + 1
  var entries: seq[ReadSetEntry] = @[]
  if prevKey in src.readSets:
    for e in src.readSets[prevKey].entries:
      entries.add(e)
  entries.add(entry)
  let rsId = prevKey & "-v" & $version
  result = ReadSet(
    readSetId: rsId,
    snapshotId: snapshot.snapshotId,
    version: version,
    entries: entries
  )
  src.readSets[rsId] = result
  discard src.store.put($readSetToJson(result), "application/json",
                        "readset:" & rsId)

proc reproduceInitialRead*(src: LocalSnapshotSource; snapshot: SourceSnapshot;
                           sourceId, livePath: string): tuple[snapshotBytes, liveBytes: string] =
  let snapBytes = resolveSource(src, snapshot, sourceId)
  let liveBytes =
    if fileExists(livePath): readFile(livePath) else: ""
  (snapBytes, liveBytes)