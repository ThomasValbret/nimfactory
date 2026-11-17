## Minimal F1 consumer: store bytes and capture a file snapshot.
import std/[os, strutils]
import nimfactory/artifacts

when isMainModule:
  let root = getTempDir() / "nimfactory-f1-example"
  createDir(root)
  let store = newDirectoryArtifactStore(root)
  discard store.put("example payload", "text/plain", "example-run")
  let srcPath = root / "input.txt"
  writeFile(srcPath, "initial content")
  let snapSrc = newLocalSnapshotSource(store)
  let (snap, rs) = snapSrc.capture(SourceCaptureRequest(
    sources: @[SourceSpec(sourceId: "input", path: srcPath, revisionLabel: "r1")]
  ))
  echo "snapshot=", snap.snapshotId, " read_set=", rs.readSetId
  echo "captured=", snapSrc.resolveSource(snap, "input")