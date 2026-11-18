## SnapshotSource: materialize mutable sources as artifacts; sealed snapshots.

import std/[os, json, tables, times, random]
import ../contracts/[ids, errors, ports]
import ./types
import ./store
import ./sha256

type
  SnapshotIndexEntry* = object
    manifestRef*: ArtifactRef
    latestReadSetId*: string
    readSetRefs*: Table[string, ArtifactRef]

  SnapshotIndex* = object
    snapshots*: Table[string, SnapshotIndexEntry]

type
  LocalSnapshotSource* = ref object of SnapshotSource
    store*: DirectoryArtifactStore
    root*: string
    snapshots*: Table[string, SourceSnapshot]
    readSets*: Table[string, ReadSet]
    latestReadSetBySnapshot*: Table[string, string]
    index*: SnapshotIndex

proc snapshotIndexPath(root: string): string =
  root / "snapshot-index.json"

proc indexToJson(idx: SnapshotIndex): JsonNode =
  var snaps = newJObject()
  for sid, ent in idx.snapshots:
    var rsRefs = newJObject()
    for rsid, artRef in ent.readSetRefs:
      rsRefs[rsid] = newJString($artRef)
    snaps[sid] = %*{
      "manifest_ref": $ent.manifestRef,
      "latest_read_set_id": ent.latestReadSetId,
      "read_set_refs": rsRefs
    }
  %*{
    "schema": SnapshotIndexSchema,
    "snapshots": snaps
  }

proc indexFromJson(node: JsonNode): SnapshotIndex =
  result.snapshots = initTable[string, SnapshotIndexEntry]()
  if node{"snapshots"}.kind != JObject:
    return
  for sid, ent in node["snapshots"]:
    var entry = SnapshotIndexEntry(
      manifestRef: artifactRef(ent["manifest_ref"].getStr("")),
      latestReadSetId: ent["latest_read_set_id"].getStr(""),
      readSetRefs: initTable[string, ArtifactRef]()
    )
    if ent{"read_set_refs"}.kind == JObject:
      for rsid, refNode in ent["read_set_refs"]:
        entry.readSetRefs[rsid] = artifactRef(refNode.getStr(""))
    result.snapshots[sid] = entry

proc writeIndexAtomic(root: string; idx: SnapshotIndex) =
  let path = snapshotIndexPath(root)
  let tmp = path & ".tmp." & $epochTime() & "-" & $rand(1_000_000)
  writeFile(tmp, $indexToJson(idx))
  moveFile(tmp, path)

proc loadSnapshotIndexFromDisk(root: string): SnapshotIndex =
  let path = snapshotIndexPath(root)
  if not fileExists(path):
    return SnapshotIndex(snapshots: initTable[string, SnapshotIndexEntry]())
  indexFromJson(parseFile(path))

proc persistSnapshotIndex*(src: LocalSnapshotSource) =
  writeIndexAtomic(src.root, src.index)

proc registerSnapshotInIndex*(src: LocalSnapshotSource;
                              snapshot: SourceSnapshot;
                              readSet: ReadSet;
                              manifestRef, readSetRef: ArtifactRef) =
  var ent = SnapshotIndexEntry(
    manifestRef: manifestRef,
    latestReadSetId: readSet.readSetId,
    readSetRefs: initTable[string, ArtifactRef]()
  )
  ent.readSetRefs[readSet.readSetId] = readSetRef
  src.index.snapshots[snapshot.snapshotId] = ent
  src.latestReadSetBySnapshot[snapshot.snapshotId] = readSet.readSetId
  persistSnapshotIndex(src)

proc registerReadSetInIndex*(src: LocalSnapshotSource; snapshotId: string;
                             readSet: ReadSet; readSetRef: ArtifactRef) =
  if snapshotId notin src.index.snapshots:
    raise newFactoryError(fecMissingRequiredInput,
      "snapshot not in index: " & snapshotId, phase = "snapshot")
  var ent = src.index.snapshots[snapshotId]
  ent.latestReadSetId = readSet.readSetId
  ent.readSetRefs[readSet.readSetId] = readSetRef
  src.index.snapshots[snapshotId] = ent
  src.latestReadSetBySnapshot[snapshotId] = readSet.readSetId
  persistSnapshotIndex(src)

proc newLocalSnapshotSource*(store: DirectoryArtifactStore;
                            root: string = ""): LocalSnapshotSource =
  let snapRoot = if root.len > 0: root else: store.root / "snapshots"
  createDir(snapRoot)
  let idx = loadSnapshotIndexFromDisk(snapRoot)
  var latest = initTable[string, string]()
  for sid, ent in idx.snapshots:
    if ent.latestReadSetId.len > 0:
      latest[sid] = ent.latestReadSetId
  LocalSnapshotSource(
    store: store,
    root: snapRoot,
    snapshots: initTable[string, SourceSnapshot](),
    readSets: initTable[string, ReadSet](),
    latestReadSetBySnapshot: latest,
    index: idx
  )

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

proc loadReadSetFromStore(src: LocalSnapshotSource;
                          readSetId: string): ReadSet =
  for _, ent in src.index.snapshots:
    if readSetId in ent.readSetRefs:
      let artRef = ent.readSetRefs[readSetId]
      let node = parseJson(src.store.read(artRef))
      return readSetFromJson(node)
  raise newFactoryError(fecMissingRequiredInput,
    "unknown read set " & readSetId, phase = "snapshot")

proc resolveLatestReadSet*(src: LocalSnapshotSource;
                           snapshotId: string): ReadSet =
  var rsId = ""
  if snapshotId in src.latestReadSetBySnapshot:
    rsId = src.latestReadSetBySnapshot[snapshotId]
  elif snapshotId in src.index.snapshots:
    rsId = src.index.snapshots[snapshotId].latestReadSetId
  else:
    raise newFactoryError(fecMissingRequiredInput,
      "no read set for snapshot " & snapshotId, phase = "snapshot")
  if rsId in src.readSets:
    return src.readSets[rsId]
  let loaded = loadReadSetFromStore(src, rsId)
  src.readSets[rsId] = loaded
  loaded

proc capture*(src: LocalSnapshotSource;
              req: SourceCaptureRequest): tuple[snapshot: SourceSnapshot, readSet: ReadSet] =
  var revisions: seq[SourceRevision] = @[]
  for spec in req.sources:
    revisions.add(captureSourceFile(src.store, spec))
  let snapshotId = snapshotIdFromIdentity(
    revisions, req.chamberRevisions, req.recipeRefs, req.indexRevisions)
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
    predecessorReadSetId: "",
    entries: entries
  )
  src.readSets[rsId] = readSet
  let rsPut = src.store.put($readSetToJson(readSet), "application/json",
                            "readset:" & rsId)
  registerSnapshotInIndex(src, snapshot, readSet, put.id, rsPut.id)
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
  if snapshotId notin src.index.snapshots:
    raise newFactoryError(fecMissingRequiredInput,
      "unknown snapshot " & snapshotId, phase = "snapshot")
  let manifestRef = src.index.snapshots[snapshotId].manifestRef
  let node = parseJson(src.store.read(manifestRef))
  let snapshot = snapshotFromJson(node)
  if snapshot.snapshotId != snapshotId:
    raise newFactoryError(fecValidationFailed,
      "snapshot id mismatch for " & snapshotId, phase = "snapshot")
  src.snapshots[snapshotId] = snapshot
  snapshot

proc reloadReadSet*(src: LocalSnapshotSource; readSetId: string): ReadSet =
  if readSetId in src.readSets:
    return src.readSets[readSetId]
  result = loadReadSetFromStore(src, readSetId)
  src.readSets[readSetId] = result

proc appendRead*(src: LocalSnapshotSource; snapshot: SourceSnapshot;
                 entry: ReadSetEntry): ReadSet =
  ## Adds a read entry without mutating the sealed snapshot; bumps read set version.
  let pred = resolveLatestReadSet(src, snapshot.snapshotId)
  let version = pred.version + 1
  var entries: seq[ReadSetEntry] = @[]
  for e in pred.entries:
    entries.add(e)
  entries.add(entry)
  let rsId = "readset-" & snapshot.snapshotId & "-v" & $version
  result = ReadSet(
    readSetId: rsId,
    snapshotId: snapshot.snapshotId,
    version: version,
    predecessorReadSetId: pred.readSetId,
    entries: entries
  )
  src.readSets[rsId] = result
  let rsPut = src.store.put($readSetToJson(result), "application/json",
                            "readset:" & rsId)
  registerReadSetInIndex(src, snapshot.snapshotId, result, rsPut.id)

proc reproduceInitialRead*(src: LocalSnapshotSource; snapshot: SourceSnapshot;
                           sourceId, livePath: string): tuple[snapshotBytes, liveBytes: string] =
  let snapBytes = resolveSource(src, snapshot, sourceId)
  let liveBytes =
    if fileExists(livePath): readFile(livePath) else: ""
  (snapBytes, liveBytes)