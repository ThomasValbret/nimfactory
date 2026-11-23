## Deterministic project verification — CSV journey bound to demo recipe.

import std/[os, osproc, strutils, json, sequtils]

type
  ProjectVerifyResult* = object
    ok*: bool
    listOk*: bool
    csvOk*: bool
    quoteOk*: bool
    kind*: string
    message*: string
    listOut*: string
    csvOut*: string
    compileExit*: int
    details*: JsonNode

  ProjectRecipe* = object
    id*: string
    verify*: string
    raw*: JsonNode

  LocalizedCompileHit* = object
    hit*: bool
    path*: string
    line*: int
    col*: int
    message*: string
    snippet*: string
    finding*: string          ## language-agnostic diagnostic for repair

proc runCmd*(dir, bin: string; args: seq[string]): tuple[exit: int; outp: string] =
  let cmdline = quoteShell(bin) & " " & args.mapIt(quoteShell(it)).join(" ")
  let r = execCmdEx(cmdline, workingDir = dir)
  (r.exitCode, r.output)

proc parseIntSafe(s: string; def = 0): int =
  try: parseInt(s)
  except ValueError: def

proc localizeCompileDiagnosis*(
    compileOut, worktree: string; targetRel = ""): LocalizedCompileHit =
  ## Extract first localized error from a compiler transcript.
  ## Accepts common shapes (Nim `file(line, col)`, gcc/clang/rustc
  ## `file:line:col:`) so repair stays usable for another language.
  result.hit = false
  result.line = 0
  result.col = 0
  let text = compileOut.replace("\r\n", "\n")
  for line in text.splitLines():
    let t = line.strip()
    if t.len == 0: continue
    # path(line, col) Error: msg
    let paren = t.find('(')
    let parenEnd = if paren >= 0: t.find(')', paren + 1) else: -1
    if paren > 0 and parenEnd > paren:
      let inside = t[paren + 1 ..< parenEnd]
      let comma = inside.find(',')
      var lineNo = 0
      var colNo = 0
      if comma >= 0:
        lineNo = parseIntSafe(inside[0 ..< comma].strip())
        colNo = parseIntSafe(inside[comma + 1 .. ^1].strip())
      else:
        lineNo = parseIntSafe(inside.strip())
      let after = t[parenEnd + 1 .. ^1].strip()
      let errAt = after.find("Error:")
      let errAt2 = after.find("error:")
      let mark = if errAt >= 0: errAt elif errAt2 >= 0: errAt2 else: -1
      if lineNo > 0 and mark >= 0:
        result.hit = true
        result.path = t[0 ..< paren]
        result.line = lineNo
        result.col = colNo
        result.message = after[mark .. ^1].strip()
        # strip leading Error:
        for prefix in ["Error:", "error:", "Warning:", "warning:"]:
          if result.message.startsWith(prefix):
            result.message = result.message[prefix.len .. ^1].strip()
            break
        break
    # path:line:col: error: msg  OR  path:line: error: msg
    if not result.hit:
      let c1 = t.find(':')
      if c1 > 0:
        let c2 = t.find(':', c1 + 1)
        if c2 > c1:
          let pathPart = t[0 ..< c1]
          let linePart = t[c1 + 1 ..< c2]
          let lineNo = parseIntSafe(linePart)
          if lineNo > 0 and (pathPart.contains('/') or pathPart.contains('.') or
                             pathPart.contains('\\')):
            var rest = t[c2 + 1 .. ^1]
            var colNo = 0
            let c3 = rest.find(':')
            if c3 > 0 and rest[0 ..< c3].strip().allCharsInSet({'0'..'9'}):
              colNo = parseIntSafe(rest[0 ..< c3].strip())
              rest = rest[c3 + 1 .. ^1].strip()
            let low = rest.toLowerAscii
            if "error" in low or "warning" in low or "undeclared" in low:
              result.hit = true
              result.path = pathPart
              result.line = lineNo
              result.col = colNo
              result.message = rest
              break
  if not result.hit and ("Error:" in text or "error:" in text):
    result.hit = true
    result.message = text.strip()
    result.path = targetRel
  if result.hit and result.line > 0 and worktree.len > 0:
    var absPath = result.path
    if not fileExists(absPath):
      if result.path.len > 0 and fileExists(worktree / result.path):
        absPath = worktree / result.path
      elif targetRel.len > 0 and fileExists(worktree / targetRel):
        absPath = worktree / targetRel
      else:
        # Strip absolute prefix down to worktree-relative.
        let idx = result.path.find("/src/")
        if idx >= 0 and fileExists(worktree / result.path[idx+1 .. ^1]):
          absPath = worktree / result.path[idx+1 .. ^1]
    if fileExists(absPath):
      let lines = readFile(absPath).replace("\r\n", "\n").splitLines()
      let idx = result.line - 1
      if idx >= 0 and idx < lines.len:
        var parts: seq[string] = @[]
        let lo = max(0, idx - 2)
        let hi = min(lines.high, idx + 2)
        for i in lo .. hi:
          let mark = if i == idx: ">>" else: "  "
          parts.add(mark & " " & $(i + 1) & "| " & lines[i])
        result.snippet = parts.join("\n")
  var findingParts: seq[string] = @[]
  findingParts.add("Localized compile diagnosis (language-agnostic).")
  if result.path.len > 0:
    findingParts.add("path=" & result.path & " line=" & $result.line &
                     " col=" & $result.col)
  if result.message.len > 0:
    findingParts.add("message: " & result.message)
  if result.snippet.len > 0:
    findingParts.add("snippet:")
    findingParts.add(result.snippet)
  result.finding = findingParts.join("\n")

proc compileDemo*(worktree: string): tuple[ok: bool; exit: int; outp: string; bin: string] =
  let root = absolutePath(worktree)
  let bin = root / "build" / "demo_tasks"
  createDir(root / "build")
  let nimbleBin = findExe("nim")
  if nimbleBin.len == 0:
    return (false, 127, "nim not found on PATH", bin)
  let nimcache = root / "nimcache"
  createDir(nimcache)
  let cmd = @[
    "c", "-d:release", "--hints:off", "--warnings:off",
    "--nimcache:" & nimcache,
    "--path:" & (root / "src"),
    "-o:" & bin,
    root / "src" / "demo_tasks.nim"
  ]
  let r = runCmd(root, nimbleBin, cmd)
  (r.exit == 0 and fileExists(bin), r.exit, r.outp, bin)

proc expectedListOutput*(repoRoot: string): string =
  ## Baseline list from the pristine fixture (not the worktree).
  let data = parseJson(readFile(repoRoot / "data" / "tasks.json"))
  var lines: seq[string] = @[]
  for item in data:
    lines.add($item["id"].getInt & ". " & item["title"].getStr)
  lines.join("\n")

proc csvFieldNeedsQuote(s: string): bool =
  for c in s:
    if c in {',', '"', '\n', '\r'}:
      return true
  false

proc csvQuote(s: string): string =
  if not csvFieldNeedsQuote(s):
    return s
  result = "\""
  for c in s:
    if c == '"': result.add("\"\"")
    else: result.add(c)
  result.add('"')

proc expectedCsvOutput*(repoRoot: string): string =
  let data = parseJson(readFile(repoRoot / "data" / "tasks.json"))
  var lines: seq[string] = @["id,title"]
  for item in data:
    lines.add($item["id"].getInt & "," & csvQuote(item["title"].getStr))
  lines.join("\n")

proc loadProjectRecipe*(cwd: string): ProjectRecipe =
  result.id = ""
  result.verify = ""
  result.raw = newJObject()
  let p = absolutePath(cwd) / "recipe.json"
  if not fileExists(p):
    return
  try:
    let node = parseJson(readFile(p))
    result.raw = node
    result.id = node{"id"}.getStr
    result.verify = node{"verify"}.getStr
  except CatchableError:
    discard

proc csvHelpersPresent*(worktree: string): bool =
  ## Helper step oracle: both csvQuote and formatCsv must exist in tasks.nim.
  let p = worktree / "src" / "tasks.nim"
  if not fileExists(p): return false
  let body = readFile(p)
  "csvQuote" in body and "formatCsv" in body

proc verifyCsvJourney*(worktree, repoRoot: string; requireCsv = true): ProjectVerifyResult =
  ## Demo recipe oracle:
  ## - always: compile + no-args/list match fixture baseline
  ## - when requireCsv (final step): export-csv + comma quoting
  result.kind = if requireCsv: "csv_journey" else: "csv_journey_partial"
  result.details = newJObject()
  result.details["require_csv"] = %requireCsv
  result.compileExit = -1
  let comp = compileDemo(worktree)
  result.compileExit = comp.exit
  result.details["compile_out"] = %comp.outp
  if not comp.ok:
    result.ok = false
    result.message = "compile failed (exit " & $comp.exit & ")"
    return

  # Separate checks: no-args (default), list, export-csv.
  let noArgsR = runCmd(worktree, comp.bin, @[])
  let listR = runCmd(worktree, comp.bin, @["list"])
  result.listOut = listR.outp.strip()
  let expectList = expectedListOutput(repoRoot).strip()
  let noArgsOut = noArgsR.outp.strip()
  result.listOk =
    listR.exit == 0 and noArgsR.exit == 0 and
    result.listOut == expectList and noArgsOut == expectList
  result.details["expected_list"] = %expectList
  result.details["list_exit"] = %listR.exit
  result.details["no_args_exit"] = %noArgsR.exit
  result.details["no_args_out"] = %noArgsOut

  if not requireCsv:
    # Not verified — must stay false so an old compile+list proof cannot
    # cover an export_command criterion added by a later revise.
    result.csvOk = false
    result.quoteOk = false
    result.ok = result.listOk
    result.message =
      if result.ok: "intermediate: compile+list intact (CSV deferred to final step)"
      else: "list_mismatch"
    return

  # Forms admitted by the recipe oracle: `export-csv` or `list --format=csv`.
  var csvR = runCmd(worktree, comp.bin, @["export-csv"])
  var csvForm = "export-csv"
  if csvR.exit != 0 or not csvR.outp.strip().startsWith("id,title"):
    csvR = runCmd(worktree, comp.bin, @["list", "--format=csv"])
    csvForm = "list --format=csv"
  result.csvOut = csvR.outp.strip()
  let expectCsv = expectedCsvOutput(repoRoot).strip()
  result.csvOk = csvR.exit == 0 and result.csvOut == expectCsv
  result.details["expected_csv"] = %expectCsv
  result.details["csv_exit"] = %csvR.exit
  result.details["csv_form"] = %csvForm

  result.quoteOk = result.csvOut.contains("\"Appeler Alice, Bob\"")
  if not result.quoteOk and result.csvOut.contains("Alice, Bob"):
    for line in result.csvOut.splitLines():
      if "Alice" in line and line.contains('"') and line.contains(','):
        result.quoteOk = true
        break

  result.ok = result.listOk and result.csvOk and result.quoteOk
  if result.ok:
    result.message = "list default intact; CSV stdout ok; comma title quoted"
  else:
    var parts: seq[string] = @[]
    if not result.listOk: parts.add("list_mismatch")
    if not result.csvOk: parts.add("csv_mismatch")
    if not result.quoteOk: parts.add("comma_not_quoted")
    result.message = parts.join(",")

proc verifyForRecipe*(
    recipe: ProjectRecipe; worktree, repoRoot: string;
    finalStep = true): ProjectVerifyResult =
  ## Bind verification to the project recipe; generic pilot has no CSV oracle.
  ## Intermediate steps only require list integrity; final step runs full CSV.
  case recipe.verify
  of "csv_journey":
    result = verifyCsvJourney(worktree, repoRoot, requireCsv = finalStep)
  of "":
    result.kind = "none"
    result.ok = false
    result.message = "no verify bound to recipe (missing recipe.json verify)"
    result.details = newJObject()
  else:
    result.kind = recipe.verify
    result.ok = false
    result.message = "unknown recipe verify: " & recipe.verify
    result.details = newJObject()

proc verifyStepCriteria*(
    recipe: ProjectRecipe; worktree, repoRoot: string;
    criteria: seq[string]; finalStep = false): ProjectVerifyResult =
  ## Verify against criteria attached to the step (not only "last step" heuristic).
  ## export_command forces CSV/opt-in command checks — a comment-only edit fails.
  var needCsv = finalStep or ("export_command" in criteria)
  var needCompile = criteria.len == 0 or "compile" in criteria or
                    "list_intact" in criteria or "export_command" in criteria
  if not needCompile and criteria.len > 0:
    result.kind = "criteria"
    result.ok = false
    result.message = "unknown_criteria"
    result.details = %*{"criteria": criteria}
    return
  case recipe.verify
  of "csv_journey", "":
    # Empty recipe verify still allows compile/list when criteria demand it.
    if recipe.verify == "" and needCsv:
      result.kind = "criteria"
      result.ok = false
      result.message = "no verify bound to recipe for export_command"
      result.details = %*{"criteria": criteria}
      return
    if recipe.verify == "" and not needCsv:
      # compile+list via csv journey partial without recipe id
      result = verifyCsvJourney(worktree, repoRoot, requireCsv = false)
      result.kind = "criteria_partial"
    else:
      result = verifyCsvJourney(worktree, repoRoot, requireCsv = needCsv)
    if result.ok and "export_command" in criteria and not result.csvOk:
      result.ok = false
      result.message = "export_command_missing"
    if "csv_helpers" in criteria:
      let helpersOk = csvHelpersPresent(worktree)
      result.details["csv_helpers"] = %helpersOk
      if not helpersOk:
        result.ok = false
        if result.message.len == 0 or result.message.startsWith("intermediate"):
          result.message = "csv_helpers_missing"
        elif "csv_helpers_missing" notin result.message:
          result.message = result.message & ",csv_helpers_missing"
    result.details["criteria"] = %criteria
  else:
    result = verifyForRecipe(recipe, worktree, repoRoot, finalStep = needCsv)
    result.details["criteria"] = %criteria

proc proofCoversCriteria*(verifyNode: JsonNode; criteria: seq[string]): bool =
  ## Prior accepted verify proof still covers the (possibly revised) criteria.
  if verifyNode.isNil or verifyNode.kind != JObject:
    return false
  if not verifyNode{"ok"}.getBool:
    return false
  for c in criteria:
    case c
    of "compile":
      if verifyNode{"compile_exit"}.getInt != 0:
        return false
    of "list_intact":
      if not verifyNode{"list_ok"}.getBool:
        return false
    of "export_command":
      if not verifyNode{"csv_ok"}.getBool:
        return false
    of "csv_helpers":
      if not verifyNode{"details"}{"csv_helpers"}.getBool:
        return false
    else:
      discard
  true

proc verifyToJson*(v: ProjectVerifyResult): JsonNode =
  %*{
    "ok": v.ok,
    "kind": v.kind,
    "list_ok": v.listOk,
    "csv_ok": v.csvOk,
    "quote_ok": v.quoteOk,
    "message": v.message,
    "list_out": v.listOut,
    "csv_out": v.csvOut,
    "compile_exit": v.compileExit,
    "details": if v.details.isNil: newJObject() else: v.details
  }
