## F1 domain types for snapshots and read sets (not F0 transport codecs).

import std/[json, times]
import ../contracts/ids

type
  SourceSpec* = object
    sourceId*: string
    path*: string
    revisionLabel*: string

  SourceCaptureRequest* = object
    sources*: seq[SourceSpec]
    chamberRevisions*: seq[tuple[chamberId, revision: string]]
    recipeRefs*: seq[string]
    indexRevisions*: seq[tuple[indexId, revision: string]]

  SourceRevision* = object
    sourceId*: string
    artifactRef*: ArtifactRef
    contentHash*: string
    revisionLabel*: string

  SourceSnapshot* = object
    snapshotId*: string
    capturedAt*: string
    sealed*: bool
    sourceRevisions*: seq[SourceRevision]
    chamberRevisions*: seq[tuple[chamberId, revision: string]]
    recipeRefs*: seq[string]
    indexRevisions*: seq[tuple[indexId, revision: string]]
    manifestRef*: ArtifactRef

  ReadSetEntry* = object
    kind*: string
    sourceId*: string
    artifactRef*: ArtifactRef
    revision*: string
    selector*: string
    emptySearch*: bool

  ReadSet* = object
    readSetId*: string
    snapshotId*: string
    version*: int
    entries*: seq[ReadSetEntry]

  ProvenanceRecord* = object
    origin*: string
    recordedAt*: string

const SnapshotSchema* = "nimfactory.source-snapshot/0.1"
const ReadSetSchema* = "nimfactory.read-set/0.1"
const ManifestDiskSchema* = "nimfactory.artifact-manifest/0.1"

proc utcNowIso*(): string =
  format(times.utc(now()), "yyyy-MM-dd'T'HH:mm:ss'Z'")

proc snapshotToJson*(s: SourceSnapshot): JsonNode =
  var revs = newJArray()
  for r in s.sourceRevisions:
    revs.add(%*{
      "source_id": r.sourceId,
      "artifact_ref": $r.artifactRef,
      "content_hash": r.contentHash,
      "revision_label": r.revisionLabel
    })
  var chambers = newJArray()
  for c in s.chamberRevisions:
    chambers.add(%*{"chamber_id": c.chamberId, "revision": c.revision})
  var indexes = newJArray()
  for i in s.indexRevisions:
    indexes.add(%*{"index_id": i.indexId, "revision": i.revision})
  %*{
    "schema": SnapshotSchema,
    "snapshot_id": s.snapshotId,
    "captured_at": s.capturedAt,
    "sealed": s.sealed,
    "source_revisions": revs,
    "chamber_revisions": chambers,
    "recipe_refs": s.recipeRefs,
    "index_revisions": indexes,
    "manifest_ref": $s.manifestRef
  }

proc snapshotFromJson*(node: JsonNode): SourceSnapshot =
  result.snapshotId = node["snapshot_id"].getStr("")
  result.capturedAt = node["captured_at"].getStr("")
  result.sealed = node{"sealed"}.getBool(true)
  result.manifestRef = artifactRef(node["manifest_ref"].getStr(""))
  for r in node["source_revisions"]:
    result.sourceRevisions.add(SourceRevision(
      sourceId: r["source_id"].getStr(""),
      artifactRef: artifactRef(r["artifact_ref"].getStr("")),
      contentHash: r["content_hash"].getStr(""),
      revisionLabel: r["revision_label"].getStr("")
    ))
  for c in node["chamber_revisions"]:
    result.chamberRevisions.add((c["chamber_id"].getStr(""), c["revision"].getStr("")))
  for rf in node["recipe_refs"]:
    result.recipeRefs.add(rf.getStr(""))
  for i in node["index_revisions"]:
    result.indexRevisions.add((i["index_id"].getStr(""), i["revision"].getStr("")))

proc readSetToJson*(rs: ReadSet): JsonNode =
  var entries = newJArray()
  for e in rs.entries:
    entries.add(%*{
      "kind": e.kind,
      "source_id": e.sourceId,
      "artifact_ref": $e.artifactRef,
      "revision": e.revision,
      "selector": e.selector,
      "empty_search": e.emptySearch
    })
  %*{
    "schema": ReadSetSchema,
    "read_set_id": rs.readSetId,
    "snapshot_id": rs.snapshotId,
    "version": rs.version,
    "entries": entries
  }

proc readSetFromJson*(node: JsonNode): ReadSet =
  result.readSetId = node["read_set_id"].getStr("")
  result.snapshotId = node["snapshot_id"].getStr("")
  result.version = node{"version"}.getInt(1)
  for e in node["entries"]:
    result.entries.add(ReadSetEntry(
      kind: e["kind"].getStr("read"),
      sourceId: e["source_id"].getStr(""),
      artifactRef: artifactRef(e["artifact_ref"].getStr("")),
      revision: e["revision"].getStr(""),
      selector: e["selector"].getStr(""),
      emptySearch: e{"empty_search"}.getBool(false)
    ))