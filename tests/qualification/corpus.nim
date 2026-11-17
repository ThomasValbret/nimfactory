import std/[json, os, osproc, strutils]
import types

proc loadCorpusManifest*(): JsonNode =
  let path = fixturesDir() / "corpus_manifest.json"
  if not fileExists(path):
    raise newException(IOError, "corpus manifest missing: " & path)
  parseFile(path)

proc fileSha256Hex(path: string): string =
  let (outp, exitCode) = execCmdEx("sha256sum " & quoteShell(path))
  if exitCode != 0:
    raise newException(IOError, "sha256sum failed for " & path)
  let line = outp.strip()
  if line.len == 0:
    raise newException(IOError, "empty sha256sum output for " & path)
  result = line.splitWhitespace()[0]

proc verifyFrozenCorpus*(): seq[string] =
  result = @[]
  let manifest = loadCorpusManifest()
  if manifest{"schema"}.getStr != QualSchemaCorpusManifest:
    result.add "corpus manifest schema mismatch"
  if manifest.getOrDefault("qualification_mode").getStr != QualificationModeSimulated:
    result.add "corpus manifest must declare simulated mode"
  let items = manifest{"items"}
  if items.kind != JArray or items.len == 0:
    result.add "corpus items empty"
  for item in items:
    let rel = item{"path"}.getStr
    let expect = item{"sha256"}.getStr
    let full = fixturesDir() / rel
    if not fileExists(full):
      result.add "missing corpus item " & rel
      continue
    let got = fileSha256Hex(full)
    if got != expect:
      result.add "frozen hash mismatch for " & rel & " (got " & got & ")"