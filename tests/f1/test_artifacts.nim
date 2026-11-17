import std/[os, strutils, random, times]
import nimfactory
import nimfactory/artifacts

proc tempRoot(): string =
  randomize()
  let base = getTempDir() / ("nimfactory-f1-" & $epochTime() & "-" & $rand(1_000_000_000))
  createDir(base)
  base

block putReadDescribe:
  let root = tempRoot()
  let store = newDirectoryArtifactStore(root)
  let put = store.put("hello", "text/plain", "origin-a")
  doAssert put.created
  let manifest = store.describe(put.id)
  doAssert manifest.hashAlg == HashAlg
  doAssert manifest.mime == "text/plain"
  doAssert manifest.size == 5
  doAssert manifest.hash.len == 64
  doAssert store.read(put.id) == "hello"

block twoOriginsSameBytes:
  let root = tempRoot()
  let store = newDirectoryArtifactStore(root)
  let p1 = store.put("shared", "text/plain", "origin-a")
  let p2 = store.put("shared", "text/plain", "origin-b")
  doAssert $p1.id == $p2.id
  doAssert not p2.created
  let m = store.describe(p1.id)
  doAssert m.origin.contains("origin-a")
  doAssert m.origin.contains("origin-b")

block partialObjectNoVisibleManifest:
  let root = tempRoot()
  let store = newDirectoryArtifactStore(root)
  store.testHaltBeforeManifest = true
  let put = store.put("partial-test", "text/plain", "interrupt")
  let id = put.id
  doAssert not store.manifestVisible(id)
  let h = sha256Hex("partial-test")
  doAssert store.objectExistsForHash(h)
  var failed = false
  try:
    discard store.read(id)
  except FactoryError as e:
    failed = true
    doAssert e.code == fecMissingRequiredInput
  doAssert failed
  store.testHaltBeforeManifest = false
  let completed = store.put("partial-test", "text/plain", "interrupt")
  doAssert store.manifestVisible(completed.id)
  doAssert store.read(completed.id) == "partial-test"

block tamperedObjectDetected:
  let root = tempRoot()
  let store = newDirectoryArtifactStore(root)
  let put = store.put("tamper-me", "text/plain", "origin")
  store.corruptObjectForTest(put.id)
  var failed = false
  try:
    discard store.read(put.id)
  except FactoryError as e:
    failed = true
    doAssert e.code == fecValidationFailed
  doAssert failed

block snapshotSurvivesSourceMutation:
  let root = tempRoot()
  let store = newDirectoryArtifactStore(root)
  let snapSrc = newLocalSnapshotSource(store)
  let srcPath = root / "mutable.txt"
  writeFile(srcPath, "version-1")
  let req = SourceCaptureRequest(
    sources: @[
      SourceSpec(sourceId: "mutable", path: srcPath, revisionLabel: "v1")
    ]
  )
  let (snapshot, readSet) = snapSrc.capture(req)
  doAssert snapshot.sealed
  doAssert readSet.entries.len == 1
  writeFile(srcPath, "version-2-mutated")
  let (snapBytes, liveBytes) =
    snapSrc.reproduceInitialRead(snapshot, "mutable", srcPath)
  doAssert snapBytes == "version-1"
  doAssert liveBytes == "version-2-mutated"
  doAssert snapSrc.resolveSource(snapshot, "mutable") == "version-1"

block appendReadDoesNotMutateSnapshot:
  let root = tempRoot()
  let store = newDirectoryArtifactStore(root)
  let snapSrc = newLocalSnapshotSource(store)
  let srcPath = root / "doc.txt"
  writeFile(srcPath, "body")
  let (snapshot, _) = snapSrc.capture(SourceCaptureRequest(
    sources: @[SourceSpec(sourceId: "doc", path: srcPath, revisionLabel: "r0")]
  ))
  let snapCopy = snapshot
  let rs2 = snapSrc.appendRead(snapshot, ReadSetEntry(
    kind: "negative_search",
    sourceId: "missing",
    artifactRef: artifactRef(""),
    revision: "",
    selector: "query:noop",
    emptySearch: true
  ))
  doAssert rs2.version == 2
  doAssert snapCopy.sourceRevisions == snapshot.sourceRevisions
  doAssert snapCopy.snapshotId == snapshot.snapshotId

echo "test_artifacts: ok"