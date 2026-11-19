## Parse model decision JSON and apply the patch inside an isolated worktree.
## Supports full-file `patched_content` (legacy / local) and Code Zero–style
## `edits: [{oldText, newText}, ...]` for bounded replacements in one target file.
## Never deletes an existing --worktree destination: create a fresh mission dir
## or refuse an occupied path. Anchors are validated before any target write;
## the set applies only when every replacement is uniquely valid.

import std/[os, json, strutils, times]

type
  TextEdit* = object
    oldText*: string
    newText*: string

  FixDecision* = object
    targetFile*: string
    decision*: string
    patchedContent*: string      ## full-file body when present (legacy / local)
    edits*: seq[TextEdit]        ## preferred for API large-file repairs
    parseOk*: bool
    parseError*: string
    rawExcerpt*: string
    mode*: string                ## "edits" | "patched_content" | ""

  ApplyResult* = object
    ok*: bool
    identicalToOriginal*: bool ## true when proposed body equals current file (no-op)
    worktree*: string
    targetFile*: string
    decision*: string
    message*: string
    beforeHash*: string
    afterHash*: string
    mode*: string
    editsApplied*: int
    editDetails*: seq[string]  ## short per-edit notes when applied / refused

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

proc countNonOverlap*(haystack, needle: string): int =
  if needle.len == 0:
    return 0
  var i = 0
  while true:
    let p = haystack.find(needle, i)
    if p < 0:
      break
    inc result
    i = p + max(needle.len, 1)

proc parseFixDecision*(raw: string): FixDecision =
  result.rawExcerpt = if raw.len > 400: raw[0 .. 399] else: raw
  try:
    let node = parseJson(extractJsonObject(raw))
    result.targetFile = node{"target_file"}.getStr
    result.decision = node{"decision"}.getStr
    result.patchedContent = node{"patched_content"}.getStr
    let editsNode = node{"edits"}
    if editsNode != nil and editsNode.kind == JArray:
      for item in editsNode:
        if item.kind != JObject:
          continue
        let oldTxt = item{"oldText"}.getStr(item{"old_text"}.getStr(
          item{"search"}.getStr("")))
        let newTxt = item{"newText"}.getStr(item{"new_text"}.getStr(
          item{"replace"}.getStr("")))
        result.edits.add(TextEdit(
          oldText: oldTxt.replace("\r\n", "\n"),
          newText: newTxt.replace("\r\n", "\n")))
    if result.targetFile.len == 0:
      result.parseOk = false
      result.parseError = "missing target_file"
    elif result.edits.len > 0:
      result.mode = "edits"
      result.parseOk = true
    elif result.patchedContent.len > 0:
      result.mode = "patched_content"
      result.parseOk = true
    else:
      result.parseOk = false
      result.parseError = "missing edits or patched_content"
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

proc applyEditsToContent*(
    original: string; edits: seq[TextEdit]
): tuple[ok: bool; content: string; message: string; details: seq[string]; applied: int] =
  ## Validate every anchor against the evolving buffer, then apply. On any
  ## missing/ambiguous/empty oldText, refuse with zero mutations to `original`.
  var updated = original.replace("\r\n", "\n")
  let baseline = updated
  var details: seq[string] = @[]
  var i = 0
  for ed in edits:
    inc i
    if ed.oldText.len == 0:
      return (false, original, "edit " & $i & ": empty oldText",
              @["edit_" & $i & ":empty_oldText"], 0)
    let n = countNonOverlap(updated, ed.oldText)
    if n == 0:
      return (false, original, "edit " & $i & ": oldText anchor missing",
              @["edit_" & $i & ":anchor_missing"], 0)
    if n > 1:
      return (false, original, "edit " & $i & ": oldText anchor ambiguous (" & $n & " matches)",
              @["edit_" & $i & ":anchor_ambiguous:" & $n], 0)
    let pos = updated.find(ed.oldText)
    updated = updated[0 ..< pos] & ed.newText & updated[pos + ed.oldText.len .. ^1]
    details.add("edit_" & $i & ":applied")
  if updated == baseline:
    return (false, original, "edits identical to original (no effective change)", details, 0)
  (true, updated, "applied edits", details, edits.len)

proc applyDecision*(repoRoot, worktreeRoot: string; dec: FixDecision): ApplyResult =
  result.targetFile = dec.targetFile
  result.decision = dec.decision
  result.mode = dec.mode
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
  let beforeRaw = readFile(dest)
  let before = beforeRaw.replace("\r\n", "\n")
  result.beforeHash = simpleHash(before)

  if dec.mode == "edits" or (dec.edits.len > 0 and dec.patchedContent.len == 0):
    result.mode = "edits"
    let applied = applyEditsToContent(before, dec.edits)
    result.editDetails = applied.details
    result.editsApplied = applied.applied
    if not applied.ok:
      result.ok = false
      result.identicalToOriginal = applied.message.contains("identical")
      result.message = applied.message
      result.afterHash = result.beforeHash
      # Target file untouched (still the copied original).
      return
    result.afterHash = simpleHash(applied.content)
    writeFile(dest, applied.content)
    result.ok = true
    result.identicalToOriginal = false
    result.message = applied.message
    return

  # Legacy / local full-file body.
  result.mode = "patched_content"
  let patched = dec.patchedContent.replace("\r\n", "\n")
  result.afterHash = simpleHash(patched)
  if before == patched:
    result.ok = false
    result.identicalToOriginal = true
    result.message = "patched_content identical to original (no effective change)"
    return
  writeFile(dest, patched)
  result.ok = true
  result.identicalToOriginal = false
  result.message = "applied"
  result.editsApplied = 0

proc decisionToJson*(d: FixDecision): JsonNode =
  var edits = newJArray()
  for e in d.edits:
    edits.add(%*{
      "oldText": e.oldText,
      "newText": e.newText,
      "old_len": e.oldText.len,
      "new_len": e.newText.len
    })
  %*{
    "parse_ok": d.parseOk,
    "parse_error": d.parseError,
    "target_file": d.targetFile,
    "decision": d.decision,
    "mode": d.mode,
    "patched_len": d.patchedContent.len,
    "edits": edits,
    "edits_count": d.edits.len,
    "raw_excerpt": d.rawExcerpt
  }

proc applyToJson*(a: ApplyResult): JsonNode =
  var details = newJArray()
  for d in a.editDetails:
    details.add(%*d)
  %*{
    "ok": a.ok,
    "identical_to_original": a.identicalToOriginal,
    "worktree": a.worktree,
    "target_file": a.targetFile,
    "decision": a.decision,
    "message": a.message,
    "before_hash": a.beforeHash,
    "after_hash": a.afterHash,
    "mode": a.mode,
    "edits_applied": a.editsApplied,
    "edit_details": details
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
