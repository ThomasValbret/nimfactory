import std/[os, strutils, random, times, osproc]
import nimfactory/contracts/[errors, ids]
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
  let (snapshot, rs1) = snapSrc.capture(SourceCaptureRequest(
    sources: @[SourceSpec(sourceId: "doc", path: srcPath, revisionLabel: "r0")]
  ))
  let snapCopy = snapshot
  let rs2 = snapSrc.appendRead(snapshot, ReadSetEntry(
    kind: "negative_search",
    sourceId: "missing",
    artifactRef: artifactRef(""),
    revision: "",
    selector: "query:noop-a",
    emptySearch: true
  ))
  doAssert rs2.version == 2
  doAssert snapCopy.sourceRevisions == snapshot.sourceRevisions
  doAssert snapCopy.snapshotId == snapshot.snapshotId

block cumulativeAppendReadVersions:
  let root = tempRoot()
  let store = newDirectoryArtifactStore(root)
  let snapSrc = newLocalSnapshotSource(store)
  let srcPath = root / "doc.txt"
  writeFile(srcPath, "body")
  let (snapshot, rs1) = snapSrc.capture(SourceCaptureRequest(
    sources: @[SourceSpec(sourceId: "doc", path: srcPath, revisionLabel: "r0")]
  ))
  doAssert rs1.version == 1
  doAssert rs1.predecessorReadSetId == ""
  doAssert rs1.entries.len == 1
  let rs2 = snapSrc.appendRead(snapshot, ReadSetEntry(
    kind: "read", sourceId: "extra", artifactRef: artifactRef("art-sha256-dead"),
    revision: "r1", selector: "q1", emptySearch: false
  ))
  let rs3 = snapSrc.appendRead(snapshot, ReadSetEntry(
    kind: "negative_search", sourceId: "none", artifactRef: artifactRef(""),
    revision: "", selector: "q2", emptySearch: true
  ))
  doAssert rs2.version == 2
  doAssert rs3.version == 3
  doAssert rs2.predecessorReadSetId == rs1.readSetId
  doAssert rs3.predecessorReadSetId == rs2.readSetId
  doAssert rs2.entries.len == 2
  doAssert rs3.entries.len == 3
  doAssert rs2.readSetId != rs3.readSetId
  let rs2Again = snapSrc.reloadReadSet(rs2.readSetId)
  let rs3Again = snapSrc.reloadReadSet(rs3.readSetId)
  doAssert rs2Again.entries.len == 2
  doAssert rs3Again.entries.len == 3
  doAssert rs2Again.entries[1].selector == "q1"
  doAssert rs3Again.entries[2].selector == "q2"

block snapshotIdentityMetadata:
  let root = tempRoot()
  let store = newDirectoryArtifactStore(root)
  let snapSrc = newLocalSnapshotSource(store)
  let srcPath = root / "same-bytes.txt"
  writeFile(srcPath, "fixed-payload")
  let baseSources = @[SourceSpec(sourceId: "main", path: srcPath, revisionLabel: "v1")]
  let (snapA, _) = snapSrc.capture(SourceCaptureRequest(
    sources: baseSources,
    recipeRefs: @["recipe/v1"],
    indexRevisions: @[("idx", "1")]
  ))
  let (snapB, _) = snapSrc.capture(SourceCaptureRequest(
    sources: baseSources,
    recipeRefs: @["recipe/v2"],
    indexRevisions: @[("idx", "1")]
  ))
  doAssert snapA.snapshotId != snapB.snapshotId
  doAssert snapA.recipeRefs == @["recipe/v1"]
  doAssert snapB.recipeRefs == @["recipe/v2"]
  let reloadedA = snapSrc.reloadSnapshot(snapA.snapshotId)
  doAssert reloadedA.recipeRefs == @["recipe/v1"]
  doAssert reloadedA.indexRevisions == @[("idx", "1")]
  doAssert snapSrc.reloadSnapshot(snapB.snapshotId).recipeRefs == @["recipe/v2"]

block reloadSnapshotNewInstance:
  let root = tempRoot()
  let store = newDirectoryArtifactStore(root)
  let snapSrc = newLocalSnapshotSource(store)
  let srcPath = root / "persist.txt"
  writeFile(srcPath, "persisted")
  let (snapshot, _) = snapSrc.capture(SourceCaptureRequest(
    sources: @[SourceSpec(sourceId: "p", path: srcPath, revisionLabel: "r1")],
    chamberRevisions: @[("room", "c1")],
    recipeRefs: @["rec-a"],
    indexRevisions: @[("ix", "v0")]
  ))
  let snapId = snapshot.snapshotId
  let freshStore = newDirectoryArtifactStore(root)
  let freshSrc = newLocalSnapshotSource(freshStore)
  let reloaded = freshSrc.reloadSnapshot(snapId)
  doAssert reloaded.snapshotId == snapId
  doAssert reloaded.chamberRevisions == @[("room", "c1")]
  doAssert freshSrc.resolveSource(reloaded, "p") == "persisted"
  let latest = freshSrc.resolveLatestReadSet(snapId)
  doAssert latest.version == 1
  doAssert latest.entries.len == 1

block reloadSnapshotSeparateProcess:
  let repo = getCurrentDir()
  let root = tempRoot()
  let store = newDirectoryArtifactStore(root)
  let snapSrc = newLocalSnapshotSource(store)
  let srcPath = root / "child.txt"
  writeFile(srcPath, "child-probe")
  let (snapshot, _) = snapSrc.capture(SourceCaptureRequest(
    sources: @[SourceSpec(sourceId: "c", path: srcPath, revisionLabel: "r1")],
    recipeRefs: @["recipe-child"]
  ))
  let nimBin = findExe("nim")
  let probe = repo / "tests/f1/snapshot_cold_reload.nim"
  let repoSrcPath = repo / "src"
  let vendorPath = repo / "vendor/NimAgentLibrary/src"
  let cmd = nimBin & " r --hints:off --warnings:off --skipUserCfg --skipParentCfg " &
    "--path:" & quoteShell(repoSrcPath) & " --path:" & quoteShell(vendorPath) & " " &
    quoteShell(probe) & " " & quoteShell(root) & " " & quoteShell(snapshot.snapshotId)
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0
  doAssert output.strip() == "recipe-child"

echo "test_artifacts: ok"