## Parse model decision JSON and apply the patch inside an isolated worktree.

import std/[os, json, strutils]

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
    worktree*: string
    targetFile*: string
    decision*: string
    message*: string
    beforeHash*: string
    afterHash*: string

proc extractJsonObject(raw: string): string =
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

proc copyRepoToWorktree*(repoRoot, worktree: string) =
  if dirExists(worktree):
    removeDir(worktree)
  createDir(worktree)
  for kind, path in walkDir(repoRoot):
    let name = splitPath(path).tail
    if name in [".git", "oracle"]:
      continue
    let dest = worktree / name
    if kind == pcDir:
      copyDir(path, dest)
    elif kind == pcFile:
      copyFile(path, dest)

proc simpleHash(s: string): string =
  ## Stable short fingerprint for reports (not cryptographic).
  var h: uint32 = 2166136261'u32
  for c in s:
    h = (h xor uint32(ord(c))) * 16777619'u32
  result = toHex(h)

proc applyDecision*(repoRoot, worktreeRoot: string; dec: FixDecision): ApplyResult =
  result.worktree = worktreeRoot
  result.targetFile = dec.targetFile
  result.decision = dec.decision
  if not dec.parseOk:
    result.ok = false
    result.message = "parse failed: " & dec.parseError
    return
  if dec.targetFile.contains("..") or dec.targetFile.isAbsolute:
    result.ok = false
    result.message = "refusing unsafe target_file: " & dec.targetFile
    return
  copyRepoToWorktree(repoRoot, worktreeRoot)
  let dest = worktreeRoot / dec.targetFile
  if not fileExists(dest):
    result.ok = false
    result.message = "target not present in worktree: " & dec.targetFile
    return
  let before = readFile(dest)
  result.beforeHash = simpleHash(before)
  writeFile(dest, dec.patchedContent)
  result.afterHash = simpleHash(dec.patchedContent)
  if before == dec.patchedContent:
    result.ok = false
    result.message = "patched_content identical to original (no effective change)"
    return
  result.ok = true
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
    "worktree": a.worktree,
    "target_file": a.targetFile,
    "decision": a.decision,
    "message": a.message,
    "before_hash": a.beforeHash,
    "after_hash": a.afterHash
  }
