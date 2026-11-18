## Child probe: reload snapshot in a fresh process (argv: storeRoot snapshotId).
import std/[os, strutils]
import nimfactory/artifacts

when isMainModule:
  let storeRoot = paramStr(1)
  let snapshotId = paramStr(2)
  let store = newDirectoryArtifactStore(storeRoot)
  let snapSrc = newLocalSnapshotSource(store)
  let snap = snapSrc.reloadSnapshot(snapshotId)
  echo snap.recipeRefs.join(";")