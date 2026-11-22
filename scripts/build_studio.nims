## Invoke with "nim e scripts/build_studio.nims" from the repository root.
import std/os

let root = currentSourcePath().parentDir.parentDir
let nim = getCurrentCompilerExe().quoteShell
withDir root:
  mkDir "build/studio"
  exec nim & " js -d:release -o:build/studio/client.js src/nimfactory/studio/client.nim"
  exec nim & " c -d:release --path:src -o:build/nimfactory-studio src/nimfactory_studio.nim"
