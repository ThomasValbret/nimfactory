## Parse model decision JSON and apply the patch inside an isolated worktree.
## Never deletes an existing --worktree destination: create a fresh mission dir
## or refuse an occupied path.

import std/[os, json, strutils, times]

type
  FixDecision* = object
    targetFile*: string
    decision*: string
    patchedContent*: string
    parseOk*: bool
    parseError*: string
    rawExcerpt*: string

  ApplyResult* = object
    ok*: bool
    identicalToOriginal*: bool ## true when proposed body equals current file (no-op)
    worktree*: string
    targetFile*: string
    decision*: string
    message*: string
    beforeHash*: string
    afterHash*: string

proc extractJsonObject*(raw: string): string =
  ## Tolerate fenced markdown around a JSON object.
  var t = raw.strip()
  if t.startsWith("```"):
    let firstNl = t.find('\n')
    if firstNl >= 0:
      t = t[firstNl+1 .. ^1]
    if t.endsWith("```"):
      t = t[0 ..< t.len-3].strip()
  let start = t.find('{')
  let stop = t.rfind('}')
  if start >= 0 and stop > start:
    return t[start .. stop]
  t

proc parseFixDecision*(raw: string): FixDecision =
  result.rawExcerpt = if raw.len > 400: raw[0 .. 399] else: raw
  try:
    let node = parseJson(extractJsonObject(raw))
    result.targetFile = node{"target_file"}.getStr
    result.decision = node{"decision"}.getStr
    result.patchedContent = node{"patched_content"}.getStr
    if result.targetFile.len == 0 or result.patchedContent.len == 0:
      result.parseOk = false
      result.parseError = "missing target_file or patched_content"
    else:
      result.parseOk = true
  except CatchableError as e:
    result.parseOk = false
    result.parseError = e.msg

proc dirIsOccupied(path: string): bool =
  if fileExists(path):
    return true
  if not dirExists(path):
    return false
  for _ in walkDir(path):
    return true
  false

proc allocateWorktree*(requested: string): tuple[ok: bool; path: string; message: string] =
  ## If `requested` is empty, create a fresh mission-owned directory.
  ## If provided, refuse when the path already exists or is occupied.
  if requested.len == 0:
    let path = getTempDir() / ("nf_mission_" & $getCurrentProcessId() & "_" &
               $(epochTime().int))
    createDir(path)
    return (true, path, "allocated fresh worktree")
  if fileExists(requested):
    return (false, requested, "worktree path is an existing file; refuse to overwrite: " & requested)
  if dirExists(requested):
    if dirIsOccupied(requested):
      return (false, requested,
        "worktree already occupied; refuse to delete or reuse: " & requested)
    # empty existing dir is acceptable
    return (true, requested, "using empty worktree directory")
  createDir(requested)
  (true, requested, "created worktree directory")

proc copyRepoToWorktree*(repoRoot, worktree: string) =
  ## Copy repo contents into an already-prepared (empty) worktree. Does not removeDir.
  for kind, path in walkDir(repoRoot):
    let name = splitPath(path).tail
    if name in [".git", "oracle"]:
      continue
    let dest = worktree / name
    if kind == pcDir:
      copyDir(path, dest)
    elif kind == pcFile:
      copyFile(path, dest)

proc simpleHash*(s: string): string =
  var h: uint32 = 2166136261'u32
  for c in s:
    h = (h xor uint32(ord(c))) * 16777619'u32
  result = toHex(h)

proc applyDecision*(repoRoot, worktreeRoot: string; dec: FixDecision): ApplyResult =
  result.targetFile = dec.targetFile
  result.decision = dec.decision
  if not dec.parseOk:
    result.ok = false
    result.message = "parse failed: " & dec.parseError
    return
  if dec.targetFile.contains("..") or isAbsolute(dec.targetFile):
    result.ok = false
    result.message = "refusing unsafe target_file: " & dec.targetFile
    return
  let alloc = allocateWorktree(worktreeRoot)
  result.worktree = alloc.path
  if not alloc.ok:
    result.ok = false
    result.message = alloc.message
    return
  try:
    copyRepoToWorktree(repoRoot, alloc.path)
  except CatchableError as e:
    result.ok = false
    result.message = "copy to worktree failed: " & e.msg
    return
  let dest = alloc.path / dec.targetFile
  if not fileExists(dest):
    result.ok = false
    result.message = "target not present in worktree: " & dec.targetFile
    return
  let before = readFile(dest)
  result.beforeHash = simpleHash(before)
  result.afterHash = simpleHash(dec.patchedContent)
  if before == dec.patchedContent:
    result.ok = false
    result.identicalToOriginal = true
    result.message = "patched_content identical to original (no effective change)"
    return
  writeFile(dest, dec.patchedContent)
  result.ok = true
  result.identicalToOriginal = false
  result.message = "applied"

proc decisionToJson*(d: FixDecision): JsonNode =
  %*{
    "parse_ok": d.parseOk,
    "parse_error": d.parseError,
    "target_file": d.targetFile,
    "decision": d.decision,
    "patched_len": d.patchedContent.len,
    "raw_excerpt": d.rawExcerpt
  }

proc applyToJson*(a: ApplyResult): JsonNode =
  %*{
    "ok": a.ok,
    "identical_to_original": a.identicalToOriginal,
    "worktree": a.worktree,
    "target_file": a.targetFile,
    "decision": a.decision,
    "message": a.message,
    "before_hash": a.beforeHash,
    "after_hash": a.afterHash
  }

proc parseCannotFix*(raw: string): tuple[hit: bool; decision: string] =
  ## Recovery may conclude it cannot propose a correction.
  try:
    let node = parseJson(extractJsonObject(raw))
    if node{"cannot_fix"}.getBool(false):
      return (true, node{"decision"}.getStr("cannot_fix"))
  except CatchableError:
    discard
  (false, "")
