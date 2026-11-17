## Local directory ArtifactStore: content-addressed blobs + atomic manifest publish.

import std/[os, json, strutils, times, random]
import ../contracts/[ids, ports, errors]
import ./types
import ./sha256

const
  HashAlg* = "sha256"
  IdPrefix* = "art-sha256-"

type
  DiskManifest* = object
    id*: ArtifactRef
    hash*: string
    mime*: string
    size*: int64
    objectRelPath*: string
    origins*: seq[string]
    provenance*: seq[ProvenanceRecord]

  DirectoryArtifactStore* = ref object of ArtifactStore
    root*: string
    ## When true, put stops after object write (tests: no visible manifest).
    testHaltBeforeManifest*: bool

proc artifactIdForHash*(hash: string): ArtifactRef =
  artifactRef(IdPrefix & hash)

proc hashObjectRelPath*(hash: string): string =
  if hash.len < 2:
    raise newException(ValueError, "hash too short")
  "objects" / HashAlg / hash[0 ..< 2] / (hash & ".bin")

proc manifestPath(root, id: string): string =
  root / "manifests" / (id.replace("/", "_") & ".json")

proc stagingPath(root, hash: string): string =
  root / "staging" / (hash & ".part")

proc ensureDir*(path: string) =
  let parent = path.parentDir
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)

proc newDirectoryArtifactStore*(root: string): DirectoryArtifactStore =
  createDir(root)
  createDir(root / "objects")
  createDir(root / "manifests")
  createDir(root / "staging")
  DirectoryArtifactStore(root: root)

proc objectAbsPath*(s: DirectoryArtifactStore; rel: string): string =
  s.root / rel

proc readDiskManifest(s: DirectoryArtifactStore; id: string): DiskManifest =
  let path = manifestPath(s.root, id)
  if not fileExists(path):
    raise newFactoryError(fecMissingRequiredInput,
      "unknown artifact manifest " & id, phase = "artifact")
  let node = parseFile(path)
  result.id = artifactRef(node["id"].getStr(""))
  result.hash = node["hash"].getStr("")
  result.mime = node["mime"].getStr("application/octet-stream")
  result.size = node["size"].getInt().int64
  result.objectRelPath = node["object_relpath"].getStr("")
  if node{"origins"}.kind == JArray:
    for o in node["origins"]:
      result.origins.add(o.getStr(""))
  else:
    let legacy = node{"origin"}.getStr("")
    if legacy.len > 0:
      result.origins.add(legacy)
  if node{"provenance"}.kind == JArray:
    for p in node["provenance"]:
      result.provenance.add(ProvenanceRecord(
        origin: p["origin"].getStr(""),
        recordedAt: p["recorded_at"].getStr("")
      ))

proc originsJoined(origins: seq[string]): string =
  origins.join("|")

proc writeManifestAtomic(root: string; id: string; node: JsonNode) =
  let finalPath = manifestPath(root, id)
  ensureDir(finalPath)
  let tmp = finalPath & ".tmp." & $epochTime() & "-" & $rand(1_000_000)
  writeFile(tmp, $node)
  moveFile(tmp, finalPath)

proc publishManifest(s: DirectoryArtifactStore; dm: DiskManifest) =
  var prov = newJArray()
  for p in dm.provenance:
    prov.add(%*{"origin": p.origin, "recorded_at": p.recordedAt})
  let node = %*{
    "schema": ManifestDiskSchema,
    "id": $dm.id,
    "hash_alg": HashAlg,
    "hash": dm.hash,
    "mime": dm.mime,
    "size": dm.size,
    "object_relpath": dm.objectRelPath,
    "origins": dm.origins,
    "provenance": prov
  }
  writeManifestAtomic(s.root, $dm.id, node)

proc writeObjectAtomic(s: DirectoryArtifactStore; hash, data: string): string =
  let rel = hashObjectRelPath(hash)
  let finalAbs = s.objectAbsPath(rel)
  if fileExists(finalAbs):
    return rel
  let stageAbs = stagingPath(s.root, hash)
  ensureDir(stageAbs)
  writeFile(stageAbs, data)
  ensureDir(finalAbs)
  moveFile(stageAbs, finalAbs)
  rel

proc loadObjectBytes(s: DirectoryArtifactStore; rel: string): string =
  readFile(s.objectAbsPath(rel))

proc findManifestByHash(s: DirectoryArtifactStore; hash: string): string =
  let candidate = $artifactIdForHash(hash)
  let path = manifestPath(s.root, candidate)
  if fileExists(path):
    candidate
  else:
    ""

method put*(s: DirectoryArtifactStore; data: string; mime, origin: string): PutResult =
  let hash = sha256Hex(data)
  let id = artifactIdForHash(hash)
  let existingId = findManifestByHash(s, hash)
  let rel = writeObjectAtomic(s, hash, data)
  var created = existingId.len == 0
  var dm: DiskManifest
  if existingId.len > 0:
    dm = readDiskManifest(s, existingId)
    if origin.len > 0 and origin notin dm.origins:
      dm.origins.add(origin)
      dm.provenance.add(ProvenanceRecord(origin: origin, recordedAt: utcNowIso()))
  else:
    dm = DiskManifest(
      id: id,
      hash: hash,
      mime: mime,
      size: data.len.int64,
      objectRelPath: rel,
      origins: if origin.len > 0: @[origin] else: @[],
      provenance: if origin.len > 0:
        @[ProvenanceRecord(origin: origin, recordedAt: utcNowIso())]
      else:
        @[]
    )
  if not s.testHaltBeforeManifest:
    publishManifest(s, dm)
  PutResult(id: dm.id, created: created)

method read*(s: DirectoryArtifactStore; id: ArtifactRef): string =
  let dm = readDiskManifest(s, $id)
  let bytes = loadObjectBytes(s, dm.objectRelPath)
  if bytes.len.int64 != dm.size:
    raise newFactoryError(fecValidationFailed,
      "artifact size mismatch for " & $id, phase = "artifact")
  let hash = sha256Hex(bytes)
  if hash != dm.hash:
    raise newFactoryError(fecValidationFailed,
      "artifact hash mismatch for " & $id, phase = "artifact")
  bytes

method describe*(s: DirectoryArtifactStore; id: ArtifactRef): ArtifactManifest =
  let dm = readDiskManifest(s, $id)
  ArtifactManifest(
    id: dm.id,
    hashAlg: HashAlg,
    hash: dm.hash,
    mime: dm.mime,
    size: dm.size,
    origin: originsJoined(dm.origins)
  )

proc manifestVisible*(s: DirectoryArtifactStore; id: ArtifactRef): bool =
  fileExists(manifestPath(s.root, $id))

proc objectExistsForHash*(s: DirectoryArtifactStore; hash: string): bool =
  fileExists(s.objectAbsPath(hashObjectRelPath(hash)))

proc corruptObjectForTest*(s: DirectoryArtifactStore; id: ArtifactRef) =
  let dm = readDiskManifest(s, $id)
  let path = s.objectAbsPath(dm.objectRelPath)
  var bytes = loadObjectBytes(s, dm.objectRelPath)
  if bytes.len > 0:
    bytes[0] = char((ord(bytes[0]) + 1) mod 256)
  writeFile(path, bytes)