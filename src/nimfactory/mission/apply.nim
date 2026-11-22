## Parse model decision JSON and apply the patch inside an isolated worktree.
## Supports full-file `patched_content` (legacy / local) and Code Zero–style
## `edits: [{oldText, newText}, ...]` for bounded replacements in one target file.
## The entire edits list is validated before any target write. Malformed elements
## or a missing / non-string newText refuse the whole proposal. An explicit empty
## newText string is a valid deletion. Ambiguous anchors refuse without choosing
## an occurrence for the model.

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
    refuseCode*: string          ## parse-time refuse code when applicable
    rawExcerpt*: string
    mode*: string                ## "edits" | "patched_content" | ""
    exactProposalJson*: string   ## normalized proposal JSON for recovery echo

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
    refuseCode*: string        ## empty_oldText | anchor_missing | anchor_ambiguous | …
    ambiguousEditIndex*: int   ## 1-based; 0 if N/A
    ambiguousMatchCount*: int
    ambiguousOldText*: string
    occurrenceContexts*: seq[string] ## lines around each match (ambiguous only)

proc extractJsonObject*(raw: string): string =
  ## Tolerate fenced markdown; return the first balanced `{...}` object.
  ## Important: do not use rfind('}') — dual ```json fences would span both
  ## objects and fail parse with "EOF expected".
  var t = raw.strip()
  if t.startsWith("```"):
    let firstNl = t.find('\n')
    if firstNl >= 0:
      t = t[firstNl+1 .. ^1]
    # Close of the first fence only (not a later second fence).
    let fenceEnd = t.find("```")
    if fenceEnd >= 0:
      t = t[0 ..< fenceEnd].strip()
    elif t.endsWith("```"):
      t = t[0 ..< t.len-3].strip()
  let start = t.find('{')
  if start < 0:
    return t
  var depth = 0
  var inStr = false
  var escape = false
  for i in start ..< t.len:
    let c = t[i]
    if inStr:
      if escape:
        escape = false
      elif c == '\\':
        escape = true
      elif c == '"':
        inStr = false
      continue
    case c
    of '"':
      inStr = true
    of '{':
      inc depth
    of '}':
      dec depth
      if depth == 0:
        return t[start .. i]
    else:
      discard
  # Unbalanced — fall back to legacy span for error messages upstream.
  let stop = t.rfind('}')
  if stop > start:
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

proc findNonOverlapPositions*(haystack, needle: string): seq[int] =
  result = @[]
  if needle.len == 0:
    return
  var i = 0
  while true:
    let p = haystack.find(needle, i)
    if p < 0:
      break
    result.add(p)
    i = p + max(needle.len, 1)

proc lineIndexAt*(content: string; bytePos: int): int =
  ## 1-based line number for a byte offset.
  result = 1
  var i = 0
  while i < bytePos and i < content.len:
    if content[i] == '\n':
      inc result
    inc i

proc contextAroundMatch*(content: string; pos, needleLen: int; radius = 3): string =
  ## A few lines around a match; does not pick or prefer an occurrence.
  let lines = content.split('\n')
  let lineNo = lineIndexAt(content, pos)  # 1-based
  let startLine = max(1, lineNo - radius)
  let endLine = min(lines.len, lineNo + radius)
  var parts: seq[string] = @[]
  parts.add("line " & $lineNo & " (bytes " & $pos & ".." & $(pos + needleLen - 1) & ")")
  for li in startLine .. endLine:
    let mark = if li == lineNo: ">>" else: "  "
    parts.add(mark & " " & $li & "| " & lines[li - 1])
  parts.join("\n")

proc requireEditStringField(
    item: JsonNode; names: openArray[string];
    missingCode, typeCode: string):
    tuple[ok: bool; value: string; err: string; code: string] =
  ## Require an explicit JSON string field (empty string allowed). Wrong type / absent → refuse.
  for name in names:
    if item.hasKey(name):
      let n = item[name]
      if n.kind != JString:
        return (false, "", "field `" & name & "` must be a JSON string", typeCode)
      return (true, n.getStr, "", "")
  (false, "", "missing required string field among " & names.join("/"), missingCode)

proc parseFixDecision*(raw: string): FixDecision =
  result.rawExcerpt = if raw.len > 400: raw[0 .. 399] else: raw
  try:
    let extracted = extractJsonObject(raw)
    let node = parseJson(extracted)
    result.targetFile = node{"target_file"}.getStr
    result.decision = node{"decision"}.getStr
    if node.hasKey("patched_content") and node["patched_content"].kind == JString:
      result.patchedContent = node["patched_content"].getStr
    let editsNode = node{"edits"}
    if editsNode != nil and editsNode.kind == JArray:
      for item in editsNode:
        if item.kind != JObject:
          result.parseOk = false
          result.refuseCode = "malformed_edit"
          result.parseError = "malformed edits element (not a JSON object)"
          return
        let oldF = requireEditStringField(
          item, ["oldText", "old_text", "search"], "oldText_missing", "oldText_type")
        if not oldF.ok:
          result.parseOk = false
          result.refuseCode = oldF.code
          result.parseError = "edit oldText: " & oldF.err
          return
        let newF = requireEditStringField(
          item, ["newText", "new_text", "replace"], "newText_missing", "newText_type")
        if not newF.ok:
          result.parseOk = false
          result.refuseCode = newF.code
          result.parseError = "edit newText: " & newF.err
          return
        result.edits.add(TextEdit(
          oldText: oldF.value.replace("\r\n", "\n"),
          newText: newF.value.replace("\r\n", "\n")))
    if result.targetFile.len == 0:
      result.parseOk = false
      result.parseError = "missing target_file"
      result.refuseCode = "missing_target"
    elif result.edits.len > 0:
      result.mode = "edits"
      result.parseOk = true
      # Exact proposal for recovery echo (model-owned fields only).
      var editsArr = newJArray()
      for e in result.edits:
        editsArr.add(%*{"oldText": e.oldText, "newText": e.newText})
      result.exactProposalJson = $(%*{
        "target_file": result.targetFile,
        "decision": result.decision,
        "edits": editsArr
      })
    elif result.patchedContent.len > 0:
      result.mode = "patched_content"
      result.parseOk = true
      result.exactProposalJson = $(%*{
        "target_file": result.targetFile,
        "decision": result.decision,
        "patched_content": result.patchedContent
      })
    else:
      result.parseOk = false
      result.parseError = "missing edits or patched_content"
      result.refuseCode = "missing_patch"
  except CatchableError as e:
    result.parseOk = false
    result.parseError = e.msg
    result.refuseCode = "parse_error"

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
): tuple[
    ok: bool; content: string; message: string; details: seq[string]; applied: int;
    refuseCode: string; ambigIndex: int; ambigCount: int; ambigOld: string;
    contexts: seq[string]] =
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
              @["edit_" & $i & ":empty_oldText"], 0,
              "empty_oldText", i, 0, "", @[])
    let positions = findNonOverlapPositions(updated, ed.oldText)
    let n = positions.len
    if n == 0:
      return (false, original, "edit " & $i & ": oldText anchor missing",
              @["edit_" & $i & ":anchor_missing"], 0,
              "anchor_missing", i, 0, ed.oldText, @[])
    if n > 1:
      var contexts: seq[string] = @[]
      var oi = 0
      for pos in positions:
        inc oi
        contexts.add("occurrence " & $oi & " of " & $n & ":\n" &
                     contextAroundMatch(updated, pos, ed.oldText.len))
      return (false, original,
              "edit " & $i & ": oldText anchor ambiguous (" & $n & " matches)",
              @["edit_" & $i & ":anchor_ambiguous:" & $n], 0,
              "anchor_ambiguous", i, n, ed.oldText, contexts)
    let pos = positions[0]
    updated = updated[0 ..< pos] & ed.newText & updated[pos + ed.oldText.len .. ^1]
    details.add("edit_" & $i & ":applied")
  if updated == baseline:
    return (false, original, "edits identical to original (no effective change)", details, 0,
            "identical", 0, 0, "", @[])
  (true, updated, "applied edits", details, edits.len, "", 0, 0, "", @[])

proc applyDecision*(repoRoot, worktreeRoot: string; dec: FixDecision): ApplyResult =
  result.targetFile = dec.targetFile
  result.decision = dec.decision
  result.mode = dec.mode
  if not dec.parseOk:
    result.ok = false
    result.refuseCode = dec.refuseCode
    result.message = "parse failed: " & dec.parseError
    return
  if dec.targetFile.contains("..") or isAbsolute(dec.targetFile):
    result.ok = false
    result.refuseCode = "unsafe_target"
    result.message = "refusing unsafe target_file: " & dec.targetFile
    return
  let alloc = allocateWorktree(worktreeRoot)
  result.worktree = alloc.path
  if not alloc.ok:
    result.ok = false
    result.refuseCode = "worktree_refused"
    result.message = alloc.message
    return
  try:
    copyRepoToWorktree(repoRoot, alloc.path)
  except CatchableError as e:
    result.ok = false
    result.refuseCode = "copy_failed"
    result.message = "copy to worktree failed: " & e.msg
    return
  let dest = alloc.path / dec.targetFile
  if not fileExists(dest):
    result.ok = false
    result.refuseCode = "target_missing"
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
    result.refuseCode = applied.refuseCode
    result.ambiguousEditIndex = applied.ambigIndex
    result.ambiguousMatchCount = applied.ambigCount
    result.ambiguousOldText = applied.ambigOld
    result.occurrenceContexts = applied.contexts
    if not applied.ok:
      result.ok = false
      result.identicalToOriginal = applied.refuseCode == "identical"
      result.message = applied.message
      result.afterHash = result.beforeHash
      return
    result.afterHash = simpleHash(applied.content)
    writeFile(dest, applied.content)
    result.ok = true
    result.identicalToOriginal = false
    result.message = applied.message
    return

  result.mode = "patched_content"
  let patched = dec.patchedContent.replace("\r\n", "\n")
  result.afterHash = simpleHash(patched)
  if before == patched:
    result.ok = false
    result.identicalToOriginal = true
    result.refuseCode = "identical"
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
    "refuse_code": d.refuseCode,
    "target_file": d.targetFile,
    "decision": d.decision,
    "mode": d.mode,
    "patched_len": d.patchedContent.len,
    "edits": edits,
    "edits_count": d.edits.len,
    "exact_proposal_json": d.exactProposalJson,
    "raw_excerpt": d.rawExcerpt
  }

proc applyToJson*(a: ApplyResult): JsonNode =
  var details = newJArray()
  for d in a.editDetails:
    details.add(%*d)
  var contexts = newJArray()
  for c in a.occurrenceContexts:
    contexts.add(%*c)
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
    "edit_details": details,
    "refuse_code": a.refuseCode,
    "ambiguous_edit_index": a.ambiguousEditIndex,
    "ambiguous_match_count": a.ambiguousMatchCount,
    "ambiguous_old_text": a.ambiguousOldText,
    "occurrence_contexts": contexts
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

proc buildAmbiguousFinding*(
    a: ApplyResult; exactProposal: string): string =
  ## Product knowledge at refusal: match count + contexts + intact file. No compile diagnosis.
  var parts: seq[string] = @[]
  parts.add("Apply refused with refuse_code=anchor_ambiguous.")
  parts.add("Edit " & $a.ambiguousEditIndex & " oldText matched " &
            $a.ambiguousMatchCount & " times. The file is unchanged.")
  parts.add("The product does not choose an occurrence for you.")
  parts.add("oldText:")
  parts.add("```")
  parts.add(a.ambiguousOldText)
  parts.add("```")
  for c in a.occurrenceContexts:
    parts.add(c)
  parts.add("Your exact first proposal:")
  parts.add("```json")
  parts.add(exactProposal)
  parts.add("```")
  parts.join("\n")
