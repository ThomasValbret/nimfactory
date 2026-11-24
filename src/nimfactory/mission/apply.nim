## Parse model decision JSON and apply the patch inside an isolated worktree.
## Supports full-file `patched_content` (legacy / local) and Code Zero–style
## `edits: [{oldText, newText}, ...]` for bounded replacements in one target file.
## The entire edits list is validated before any target write. Malformed elements
## or a missing / non-string newText refuse the whole proposal. An explicit empty
## newText string is a valid deletion. Ambiguous anchors refuse without choosing
## an occurrence for the model.

import std/[os, json, strutils, times, algorithm]

type
  TextEdit* = object
    oldText*: string             ## replace search text, or unique insert anchor
    newText*: string             ## replacement body, or text to insert
    op*: string                  ## replace | insert_before | insert_after |
                                 ## insert_line_before | insert_line_after
                                 ## (textual insert* preserved; line* = new line(s))

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

proc extractBalancedObjectAt*(raw: string; start: int): tuple[ok: bool; stop: int; body: string] =
  ## First balanced `{...}` starting at or after `start`. Respects JSON strings.
  result.ok = false
  result.stop = -1
  if start < 0 or start >= raw.len:
    return
  var depth = 0
  var inStr = false
  var escape = false
  var begun = false
  for i in start ..< raw.len:
    let c = raw[i]
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
      if not begun:
        begun = true
        depth = 1
      else:
        inc depth
    of '}':
      if not begun: continue
      dec depth
      if depth == 0:
        return (true, i, raw[start .. i])
    else:
      discard

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
  let bal = extractBalancedObjectAt(t, start)
  if bal.ok:
    return bal.body
  let stop = t.rfind('}')
  if stop > start:
    return t[start .. stop]
  t

proc extractAllBalancedObjects*(raw: string): seq[string] =
  ## All top-level balanced JSON objects in document order (fences ignored as text).
  result = @[]
  var i = 0
  while i < raw.len:
    let start = raw.find('{', i)
    if start < 0: break
    let bal = extractBalancedObjectAt(raw, start)
    if not bal.ok:
      break
    result.add(bal.body)
    i = bal.stop + 1

proc countFixProposals*(raw: string): tuple[count: int; targets: seq[string]] =
  ## Count proposal objects that carry a target_file (multi-file replies).
  ## Unparseable objects that still mention target_file count: dual fences with a
  ## broken second JSON must not silently collapse to the first proposal.
  result.count = 0
  result.targets = @[]
  for body in extractAllBalancedObjects(raw):
    try:
      let node = parseJson(body)
      if node.kind != JObject: continue
      let tf = node{"target_file"}.getStr
      if tf.len > 0:
        inc result.count
        result.targets.add(tf)
    except CatchableError:
      if "\"target_file\"" in body:
        inc result.count
        # Best-effort target extraction without full parse.
        let key = "\"target_file\""
        let k = body.find(key)
        var tf = "(unparseable)"
        if k >= 0:
          let colon = body.find(':', k + key.len)
          let q1 = if colon >= 0: body.find('"', colon + 1) else: -1
          let q2 = if q1 >= 0: body.find('"', q1 + 1) else: -1
          if q1 >= 0 and q2 > q1:
            tf = body[q1+1 ..< q2]
        result.targets.add(tf)

proc parseRevisePlan*(raw: string): tuple[hit: bool; decision: string] =
  ## Model may signal that the step requires a plan revision (prerequisite).
  try:
    let node = parseJson(extractJsonObject(raw))
    if node{"revise_plan"}.getBool(false) or node{"needs_plan_revision"}.getBool(false):
      return (true, node{"decision"}.getStr("revise_plan"))
  except CatchableError:
    discard
  (false, "")

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

const
  SupportedEditOps = [
    "replace", "insert_before", "insert_after",
    "insert_line_before", "insert_line_after"
  ]

proc parseOneTextEdit(item: JsonNode): tuple[ok: bool; edit: TextEdit; err: string; code: string] =
  ## replace {oldText,newText}; textual insertBefore/After (legacy); or
  ## insertLineBefore/After (new line(s) around the line holding the anchor).
  if item.kind != JObject:
    return (false, TextEdit(), "malformed edits element (not a JSON object)", "malformed_edit")
  let newF = requireEditStringField(
    item, ["newText", "new_text", "replace", "text"], "newText_missing", "newText_type")
  if not newF.ok:
    return (false, TextEdit(), "edit newText: " & newF.err, newF.code)
  # Line insertion keys take precedence over textual ones when both appear.
  let hasLineBefore = item.hasKey("insertLineBefore") or item.hasKey("insert_line_before")
  let hasLineAfter = item.hasKey("insertLineAfter") or item.hasKey("insert_line_after")
  let hasBefore = item.hasKey("insertBefore") or item.hasKey("insert_before")
  let hasAfter = item.hasKey("insertAfter") or item.hasKey("insert_after")
  if hasLineBefore:
    let before = requireEditStringField(
      item, ["insertLineBefore", "insert_line_before"], "insert_missing", "insert_type")
    if not before.ok:
      return (false, TextEdit(), "edit insertLineBefore: " & before.err, before.code)
    if before.value.len == 0:
      return (false, TextEdit(), "insertLineBefore anchor is empty", "empty_or_missing_oldText")
    return (true, TextEdit(
      oldText: before.value.replace("\r\n", "\n"),
      newText: newF.value.replace("\r\n", "\n"),
      op: "insert_line_before"), "", "")
  if hasLineAfter:
    let after = requireEditStringField(
      item, ["insertLineAfter", "insert_line_after"], "insert_missing", "insert_type")
    if not after.ok:
      return (false, TextEdit(), "edit insertLineAfter: " & after.err, after.code)
    if after.value.len == 0:
      return (false, TextEdit(), "insertLineAfter anchor is empty", "empty_or_missing_oldText")
    return (true, TextEdit(
      oldText: after.value.replace("\r\n", "\n"),
      newText: newF.value.replace("\r\n", "\n"),
      op: "insert_line_after"), "", "")
  if hasBefore:
    let before = requireEditStringField(
      item, ["insertBefore", "insert_before"], "insert_missing", "insert_type")
    if not before.ok:
      return (false, TextEdit(), "edit insertBefore: " & before.err, before.code)
    if before.value.len == 0:
      return (false, TextEdit(), "insertBefore anchor is empty", "empty_or_missing_oldText")
    return (true, TextEdit(
      oldText: before.value.replace("\r\n", "\n"),
      newText: newF.value.replace("\r\n", "\n"),
      op: "insert_before"), "", "")
  if hasAfter:
    let after = requireEditStringField(
      item, ["insertAfter", "insert_after"], "insert_missing", "insert_type")
    if not after.ok:
      return (false, TextEdit(), "edit insertAfter: " & after.err, after.code)
    if after.value.len == 0:
      return (false, TextEdit(), "insertAfter anchor is empty", "empty_or_missing_oldText")
    return (true, TextEdit(
      oldText: after.value.replace("\r\n", "\n"),
      newText: newF.value.replace("\r\n", "\n"),
      op: "insert_after"), "", "")
  let oldF = requireEditStringField(
    item, ["oldText", "old_text", "search"], "oldText_missing", "oldText_type")
  if not oldF.ok:
    return (false, TextEdit(), "edit oldText: " & oldF.err, oldF.code)
  var op = item{"op"}.getStr
  if op.len == 0: op = "replace"
  if op notin SupportedEditOps:
    return (false, TextEdit(), "unsupported edit op: " & op, "malformed_edit")
  (true, TextEdit(
    oldText: oldF.value.replace("\r\n", "\n"),
    newText: newF.value.replace("\r\n", "\n"),
    op: op), "", "")

proc editToProposalJson(e: TextEdit): JsonNode =
  case e.op
  of "insert_before":
    %*{"insertBefore": e.oldText, "newText": e.newText}
  of "insert_after":
    %*{"insertAfter": e.oldText, "newText": e.newText}
  of "insert_line_before":
    %*{"insertLineBefore": e.oldText, "newText": e.newText}
  of "insert_line_after":
    %*{"insertLineAfter": e.oldText, "newText": e.newText}
  else:
    %*{"oldText": e.oldText, "newText": e.newText}

proc lineBoundsAround*(content: string; pos: int): tuple[lineStart, lineEnd: int] =
  ## Byte range of the line containing `pos` (lineEnd exclusive; may equal len).
  ## Language-agnostic: newline-delimited text only.
  var start = pos
  while start > 0 and content[start - 1] != '\n':
    dec start
  var stop = pos
  while stop < content.len and content[stop] != '\n':
    inc stop
  if stop < content.len and content[stop] == '\n':
    inc stop  # include trailing newline when present
  (start, stop)

proc looksLikeProcHeaderLine*(line: string): bool =
  ## True for a definition header whose body is on following indented lines.
  ## Language-agnostic heuristic for Nim/Python-like `proc foo =` / `def foo:`.
  let t = line.strip()
  if t.len == 0: return false
  let low = t.toLowerAscii
  let endsHeader = t.endsWith("=") or t.endsWith(":")
  if not endsHeader: return false
  low.startsWith("proc ") or low.startsWith("func ") or low.startsWith("method ") or
    low.startsWith("template ") or low.startsWith("macro ") or
    low.startsWith("iterator ") or low.startsWith("converter ") or
    low.startsWith("def ") or low.startsWith("class ") or
    low.startsWith("async def ")

proc insertPointAfterAnchoredLine*(content: string; anchorPos: int): int =
  ## For insert_line_after: if the anchor is a proc/def header, skip the indented
  ## body so a new sibling declaration is not glued into the existing one.
  let bounds = lineBoundsAround(content, anchorPos)
  var lineText = content[bounds.lineStart ..< bounds.lineEnd]
  if lineText.endsWith("\n"):
    lineText = lineText[0 ..< ^1]
  if not looksLikeProcHeaderLine(lineText):
    return bounds.lineEnd
  var i = bounds.lineEnd
  var lastBodyEnd = bounds.lineEnd
  while i < content.len:
    var ls = i
    var le = i
    while le < content.len and content[le] != '\n':
      inc le
    let raw = content[ls ..< le]
    let endWithNl = if le < content.len: le + 1 else: le
    if raw.len == 0:
      break
    if raw[0] in {' ', '\t'}:
      lastBodyEnd = endWithNl
      i = endWithNl
    else:
      break
  lastBodyEnd

proc normalizeLineInsertion*(text: string): string =
  ## Ensure inserted chunk is at least one line (leading/trailing newlines as needed).
  result = text.replace("\r\n", "\n")
  if result.len == 0:
    return "\n"
  if not result.endsWith("\n"):
    result.add('\n')

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
        let one = parseOneTextEdit(item)
        if not one.ok:
          result.parseOk = false
          result.refuseCode = one.code
          result.parseError = one.err
          return
        result.edits.add(one.edit)
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
        editsArr.add(editToProposalJson(e))
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
  ## insert_before / insert_after = textual (legacy). insert_line_* = new line(s).
  var updated = original.replace("\r\n", "\n")
  let baseline = updated
  var details: seq[string] = @[]
  var i = 0
  for ed in edits:
    inc i
    let op = if ed.op.len > 0: ed.op else: "replace"
    if ed.oldText.len == 0:
      return (false, original, "edit " & $i & ": empty oldText/anchor",
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
    case op
    of "insert_before":
      updated = updated[0 ..< pos] & ed.newText & updated[pos .. ^1]
      details.add("edit_" & $i & ":insert_before")
    of "insert_after":
      let at = pos + ed.oldText.len
      updated = updated[0 ..< at] & ed.newText & updated[at .. ^1]
      details.add("edit_" & $i & ":insert_after")
    of "insert_line_before":
      let bounds = lineBoundsAround(updated, pos)
      let chunk = normalizeLineInsertion(ed.newText)
      updated = updated[0 ..< bounds.lineStart] & chunk & updated[bounds.lineStart .. ^1]
      details.add("edit_" & $i & ":insert_line_before")
    of "insert_line_after":
      let at = max(pos + ed.oldText.len - 1, pos)
      let insertAt = insertPointAfterAnchoredLine(updated, at)
      let chunk = normalizeLineInsertion(ed.newText)
      updated = updated[0 ..< insertAt] & chunk & updated[insertAt .. ^1]
      details.add("edit_" & $i & ":insert_line_after")

    else:
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
  var createdTarget = false
  if not fileExists(dest):
    # Bootstrap: create missing file when a full body is provided.
    if dec.patchedContent.len == 0:
      result.ok = false
      result.refuseCode = "target_missing"
      result.message = "target not present in worktree: " & dec.targetFile
      return
    let parent = parentDir(dest)
    if parent.len > 0:
      createDir(parent)
    writeFile(dest, "")
    createdTarget = true
  let beforeRaw = readFile(dest)
  let before = beforeRaw.replace("\r\n", "\n")
  result.beforeHash = simpleHash(before)

  if not createdTarget and
      (dec.mode == "edits" or (dec.edits.len > 0 and dec.patchedContent.len == 0)):
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
    var node = editToProposalJson(e)
    node["old_len"] = %e.oldText.len
    node["new_len"] = %e.newText.len
    node["op"] = %(if e.op.len > 0: e.op else: "replace")
    edits.add(node)
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

proc buildMultiProposalFinding*(targets: seq[string]; exactProposal: string): string =
  ## Multi-file / multi-JSON reply: refused before any worktree write.
  var parts: seq[string] = @[]
  parts.add("Apply refused with refuse_code=multi_proposal.")
  parts.add("Response contained " & $targets.len &
            " proposals with target_file. No file was written.")
  parts.add("While project step applies a single file, reformulate as one " &
            "proposal or signal revise_plan if a prerequisite requires it.")
  parts.add("Targets observed: " & targets.join(", "))
  parts.add("Your exact first proposal payload:")
  parts.add("```json")
  parts.add(exactProposal)
  parts.add("```")
  parts.join("\n")

proc exactProposalPayload*(raw: string): string =
  ## Prefer normalized multi/single proposal JSON for recovery echo.
  let multi = countFixProposals(raw)
  if multi.count > 1:
    var arr = newJArray()
    for body in extractAllBalancedObjects(raw):
      try:
        let node = parseJson(body)
        if node{"target_file"}.getStr.len > 0:
          arr.add(node)
      except CatchableError:
        discard
    return pretty(arr)
  let dec = parseFixDecision(raw)
  if dec.exactProposalJson.len > 0:
    return dec.exactProposalJson
  extractJsonObject(raw)

type
  EditDiagnosis* = object
    targetFile*: string          ## declared target_file of the proposal
    foundInFile*: string         ## actual file holding the anchor (may differ)
    editIndex*: int
    oldText*: string
    matchCount*: int
    contexts*: seq[string]
    parseOk*: bool
    note*: string

  ProposalDiagnosis* = object
    rawFaithful*: string          ## single unmodified copy of model reply
    proposalCount*: int
    targets*: seq[string]
    edits*: seq[EditDiagnosis]
    malformedBlocks*: int
    needsRefuse*: bool            ## multi, missing, or ambiguous — no write
    refuseCode*: string
    finding*: string

proc editFieldFromNode(item: JsonNode; names: openArray[string]): string =
  for n in names:
    if item.hasKey(n) and item[n].kind == JString:
      return item[n].getStr.replace("\r\n", "\n")
  ""

proc listSourceRelPaths(sourceRoot: string): seq[string] =
  ## Language-agnostic text sources under src/ (and root *.ext common cases).
  result = @[]
  let srcDir = sourceRoot / "src"
  if dirExists(srcDir):
    for path in walkDirRec(srcDir):
      if fileExists(path):
        let rel = relativePath(path, sourceRoot).replace('\\', '/')
        result.add(rel)
  result.sort(system.cmp)

proc findAnchorAcrossTree*(
    sourceRoot, anchor, skipRel: string): seq[tuple[rel: string; count: int]] =
  ## Locate an anchor in other tree files when missing from the declared target.
  result = @[]
  if anchor.len == 0: return
  for rel in listSourceRelPaths(sourceRoot):
    if rel == skipRel: continue
    let absPath = sourceRoot / rel
    let body = readFile(absPath).replace("\r\n", "\n")
    let n = findNonOverlapPositions(body, anchor).len
    if n > 0:
      result.add((rel, n))

proc diagnoseEditItem(
    item: JsonNode; tf, content: string; fileExists: bool; ei: int;
    sourceRoot = ""): EditDiagnosis =
  result = EditDiagnosis(
    targetFile: tf, foundInFile: tf, editIndex: ei, parseOk: item.kind == JObject)
  if item.kind != JObject:
    result.note = "malformed_edit_element"
    return
  let one = parseOneTextEdit(item)
  if not one.ok:
    result.note =
      if one.code in ["empty_or_missing_oldText", "oldText_missing"]:
        "empty_or_missing_oldText"
      else: one.code
    return
  result.oldText = one.edit.oldText
  if result.oldText.len == 0:
    result.note = "empty_or_missing_oldText"
    return
  if not fileExists:
    result.note = "target_missing"
    result.matchCount = 0
    # Still search the tree so the model learns the real file.
    if sourceRoot.len > 0:
      let hits = findAnchorAcrossTree(sourceRoot, result.oldText, tf)
      if hits.len == 1:
        result.foundInFile = hits[0].rel
        result.matchCount = hits[0].count
        result.note = "anchor_wrong_file"
        result.contexts.add("anchor found in " & hits[0].rel &
                            " (declared target_file was " & tf & ")")
      elif hits.len > 1:
        result.note = "anchor_wrong_file"
        for h in hits:
          result.contexts.add("also in " & h.rel & " (" & $h.count & " match(es))")
    return
  let positions = findNonOverlapPositions(content, result.oldText)
  result.matchCount = positions.len
  if positions.len > 1:
    var oi = 0
    for pos in positions:
      inc oi
      result.contexts.add(
        "occurrence " & $oi & " of " & $positions.len & ":\n" &
        contextAroundMatch(content, pos, result.oldText.len))
    result.note = "anchor_ambiguous"
  elif positions.len == 0:
    result.note = "anchor_missing"
    result.foundInFile = ""
    if sourceRoot.len > 0:
      let hits = findAnchorAcrossTree(sourceRoot, result.oldText, tf)
      if hits.len >= 1:
        result.note = "anchor_wrong_file"
        result.foundInFile = hits[0].rel
        result.matchCount = hits[0].count
        result.contexts.add(
          "anchor NOT in declared target_file=" & tf &
          "; found in " & hits[0].rel & " (" & $hits[0].count & " match(es))")
        for h in hits[1 .. ^1]:
          result.contexts.add("also in " & h.rel & " (" & $h.count & " match(es))")
  else:
    result.foundInFile = tf
    let op = if one.edit.op.len > 0: one.edit.op else: "replace"
    result.note =
      case op
      of "insert_before": "insert_before_unique"
      of "insert_after": "insert_after_unique"
      of "insert_line_before": "insert_line_before_unique"
      of "insert_line_after": "insert_line_after_unique"
      else: "anchor_unique"

proc diagnoseRawAgainstTree*(sourceRoot, raw: string): ProposalDiagnosis =
  ## Read-only: one faithful raw copy + per-edit oldText counts in current tree.
  ## Never writes. Malformed / unreadable JSON is kept in rawFaithful and refused
  ## so a bounded recovery turn can reformulate (e.g. insertBefore/After).
  result.rawFaithful = raw
  result.edits = @[]
  result.targets = @[]
  for body in extractAllBalancedObjects(raw):
    try:
      let node = parseJson(body)
      if node.kind != JObject: continue
      let tf = node{"target_file"}.getStr
      if tf.len == 0: continue
      inc result.proposalCount
      result.targets.add(tf)
      let absPath = sourceRoot / tf
      let fileExists = fileExists(absPath)
      let content =
        if fileExists: readFile(absPath).replace("\r\n", "\n")
        else: ""
      let editsNode = node{"edits"}
      if editsNode != nil and editsNode.kind == JArray and editsNode.len > 0:
        var ei = 0
        for item in editsNode:
          inc ei
          result.edits.add(
            diagnoseEditItem(item, tf, content, fileExists, ei, sourceRoot))
      elif node.hasKey("patched_content"):
        var ed = EditDiagnosis(
          targetFile: tf, foundInFile: tf, editIndex: 1, parseOk: true,
          note: if fileExists: "patched_content_mode" else: "target_missing",
          matchCount: if fileExists: 1 else: 0)
        result.edits.add(ed)
      else:
        var ed = EditDiagnosis(
          targetFile: tf, foundInFile: tf, editIndex: 0, parseOk: true,
          note: "missing_edits")
        result.edits.add(ed)
    except CatchableError:
      if "\"target_file\"" in body:
        inc result.proposalCount
        inc result.malformedBlocks
        let key = "\"target_file\""
        let k = body.find(key)
        var tf = "(unparseable)"
        if k >= 0:
          let colon = body.find(':', k + key.len)
          let q1 = if colon >= 0: body.find('"', colon + 1) else: -1
          let q2 = if q1 >= 0: body.find('"', q1 + 1) else: -1
          if q1 >= 0 and q2 > q1:
            tf = body[q1+1 ..< q2]
        result.targets.add(tf)
        result.edits.add(EditDiagnosis(
          targetFile: tf, editIndex: 0, parseOk: false,
          note: "malformed_json_block", matchCount: -1))

  # Unreadable reply (e.g. Nim """ inside JSON): no balanced object extracted.
  if result.proposalCount == 0:
    let stripped = raw.strip()
    if stripped.len > 0 and ("target_file" in stripped or '{' in stripped or
                             stripped.startsWith("```")):
      result.needsRefuse = true
      result.refuseCode = "parse_error"
      result.malformedBlocks = 1
      result.edits.add(EditDiagnosis(
        targetFile: "(unparseable)", editIndex: 0, parseOk: false,
        note: "malformed_json_block", matchCount: -1))

  # Classify refuse without writing.
  if result.proposalCount > 1:
    result.needsRefuse = true
    result.refuseCode = "multi_proposal"
  else:
    for ed in result.edits:
      if ed.note in ["anchor_ambiguous", "anchor_missing", "anchor_wrong_file",
                     "target_missing", "empty_or_missing_oldText",
                     "malformed_edit_element", "missing_edits",
                     "malformed_json_block"]:
        result.needsRefuse = true
        if ed.note == "anchor_ambiguous":
          result.refuseCode = "anchor_ambiguous"
        elif ed.note == "anchor_wrong_file":
          if result.refuseCode.len == 0: result.refuseCode = "anchor_wrong_file"
        elif ed.note == "malformed_json_block":
          if result.refuseCode.len == 0: result.refuseCode = "parse_error"
        elif result.refuseCode.len == 0:
          result.refuseCode = ed.note
  if result.refuseCode.len == 0 and result.needsRefuse:
    result.refuseCode = "apply_refused"

  var parts: seq[string] = @[]
  parts.add("Read-only diagnosis (no file was written).")
  parts.add("Proposal count: " & $result.proposalCount &
            " (malformed blocks: " & $result.malformedBlocks & ").")
  if result.refuseCode == "parse_error":
    parts.add("JSON illisible ou non extractible. Reformule en JSON strict, " &
              "ou utilise insertBefore/insertAfter sur une ancre unique " &
              "vérifiée dans l'arbre courant (pas de \"\"\" hors chaîne JSON).")
  if result.refuseCode == "anchor_wrong_file":
    parts.add("Une ou plusieurs ancres appartiennent à un autre fichier que " &
              "target_file. Une étape = un seul target_file. Reformule: " &
              "soit une proposition pour le fichier où l'ancre a été trouvée, " &
              "soit revise_plan pour séparer helper (tasks) et CLI (demo_tasks).")
  if result.targets.len > 0:
    parts.add("Targets: " & result.targets.join(", "))
  if result.proposalCount > 1:
    parts.add("While project step applies a single file, reformulate as one " &
              "proposal or signal revise_plan if a prerequisite requires it.")
  for ed in result.edits:
    var line = "Edit " & $ed.editIndex & " declared_target=" & ed.targetFile &
               ": note=" & ed.note & " match_count=" & $ed.matchCount
    if ed.foundInFile.len > 0 and ed.foundInFile != ed.targetFile:
      line.add(" found_in_file=" & ed.foundInFile)
    elif ed.foundInFile.len > 0:
      line.add(" found_in_file=" & ed.foundInFile)
    parts.add(line)
    if ed.oldText.len > 0:
      parts.add("oldText/anchor:")
      parts.add("```")
      parts.add(ed.oldText)
      parts.add("```")
    for c in ed.contexts:
      parts.add(c)
  parts.add("Faithful raw response (single copy, including any malformed block):")
  parts.add("```")
  parts.add(raw)
  parts.add("```")
  result.finding = parts.join("\n")
