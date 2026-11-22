## Invoke with "nim e scripts/build_studio.nims" from the repository root.
import std/os

let root = currentSourcePath().parentDir.parentDir
let nim = getCurrentCompilerExe().quoteShell
withDir root:
  mkDir "build/studio"
  mkDir "build/nimcache_studio_js"
  mkDir "build/nimcache_studio"
  exec nim & " js -d:release --nimcache:build/nimcache_studio_js -o:build/studio/client.js src/nimfactory/studio/client.nim"
  exec nim & " c -d:release -d:ssl --nimcache:build/nimcache_studio --path:src --path:/opt/NimAgentLibrary/src -o:build/nimfactory-studio src/nimfactory_studio.nim"
