## Deterministic project verification — CSV journey bound to demo recipe.

import std/[os, osproc, strutils, json, sequtils, tempfiles, strtabs]
import ./tree_id

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

proc findLoanOracleScript(repoRoot: string): string =
  ## Oracle lives next to the recipe cwd, or under fixtures when cwd is repo root.
  let direct = repoRoot / "oracle" / "verify_studio_change.py"
  if fileExists(direct): return direct
  let viaFixture = repoRoot / "fixtures" / "loan_notebook" / "oracle" /
                   "verify_studio_change.py"
  if fileExists(viaFixture): return viaFixture
  ""

proc controlStatus(node: JsonNode; name: string): string =
  if node.isNil: return "not_run"
  for c in node.getElems:
    if c{"name"}.getStr == name:
      return c{"status"}.getStr
  "not_run"

proc runLoanOracleAdapter*(worktree, repoRoot: string): JsonNode =
  ## Invoke the independent Python oracle in adapter mode.
  ## Returns the full report (controls, served_tree, ok) or an error object.
  result = newJObject()
  let script = findLoanOracleScript(repoRoot)
  let app = worktree / "skeleton" / "app.py"
  if script.len == 0 or not fileExists(app):
    result["ok"] = %false
    result["error"] = %"oracle_or_app_missing"
    result["controls"] = %*[
      {"name": "mark_returned_effect", "status": "not_run",
       "observation": "oracle script or app missing"}]
    return
  let tmp = createTempDir("nf-loan-adapt-", "")
  let db = tmp / "loans.sqlite"
  let pid = tmp / "server.pid"
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  env["LOAN_ORACLE_MODE"] = "adapter"
  env["LOAN_APP_AFTER"] = absolutePath(app)
  env["LOAN_DB"] = db
  env["LOAN_PID"] = pid
  # Pick an ephemeral port.
  let portProbe = execCmdEx(
    "python3 -c \"import socket;s=socket.socket();s.bind(('127.0.0.1',0));" &
    "print(s.getsockname()[1]);s.close()\"")
  let port = if portProbe.exitCode == 0: portProbe.output.strip() else: "18281"
  env["LOAN_PORT"] = port
  let cmdline = quoteShell("python3") & " " & quoteShell(script)
  let ran = execCmdEx(cmdline, workingDir = worktree, env = env)
  try:
    removeDir(tmp)
  except OSError, IOError:
    discard
  if ran.output.len == 0:
    result["ok"] = %false
    result["error"] = %"oracle_empty_output"
    result["exit"] = %ran.exitCode
    return
  try:
    result = parseJson(ran.output)
  except JsonParsingError:
    result = %*{
      "ok": false,
      "error": "oracle_json_parse",
      "exit": ran.exitCode,
      "raw_tail": ran.output[^min(400, ran.output.len) .. ^1]
    }
  # Always attach Nim-side recomputed identity of the worktree served.
  let served = servedTreeManifest(worktree)
  result["served_tree_nim"] = served
  if result{"served_tree"}.isNil or result{"served_tree"}.kind != JObject:
    result["served_tree"] = served
  else:
    result["served_tree"]["nim_recomputed_hash"] = served{"hash"}
    result["served_tree"]["hashes_match"] =
      %(served{"hash"}.getStr == result{"served_tree"}{"hash"}.getStr)

proc verifyLoanNotebook*(
    worktree, repoRoot: string; criteria: seq[string]): ProjectVerifyResult =
  ## Loan notebook adapter: schema presence + runtime oracle observations.
  ## A comment mentioning /return or an HTTP 200 without SQLite mutation must fail.
  result.kind = "loan_notebook"
  result.details = newJObject()
  result.details["criteria"] = %criteria
  var controls = newJArray()
  let app = worktree / "skeleton" / "app.py"
  let schema = worktree / "skeleton" / "schema.sql"
  let schemaOk = fileExists(schema)
  let appOk = fileExists(app)
  result.details["schema_ok"] = %schemaOk
  result.details["app_ok"] = %appOk
  controls.add(%*{
    "name": "schema_ok",
    "status": if schemaOk: "passed" else: "failed",
    "observation": if schemaOk: "skeleton/schema.sql present" else: "missing"
  })
  controls.add(%*{
    "name": "app_present",
    "status": if appOk: "passed" else: "failed",
    "observation": if appOk: "skeleton/app.py present" else: "missing"
  })
  if not schemaOk or not appOk:
    result.ok = false
    result.message =
      if not schemaOk: "schema_missing"
      else: "app_missing"
    controls.add(%*{
      "name": "mark_returned_effect", "status": "not_run",
      "observation": "skipped: skeleton incomplete"})
    controls.add(%*{
      "name": "persistence_after_restart", "status": "not_run",
      "observation": "skipped: skeleton incomplete"})
    result.details["controls"] = controls
    return
  let served = servedTreeManifest(worktree)
  result.details["served_tree"] = served
  controls.add(%*{
    "name": "served_tree_identity",
    "status": if served{"hash"}.getStr.len > 0: "passed" else: "failed",
    "observation": served
  })
  if "mark_returned" notin criteria:
    ## Intermediate gate: structure only; effect not required yet.
    result.ok = schemaOk and appOk
    result.message = "loan skeleton schema+app present"
    controls.add(%*{
      "name": "mark_returned_effect", "status": "not_run",
      "observation": "criterion mark_returned not required on this step"})
    controls.add(%*{
      "name": "persistence_after_restart", "status": "not_run",
      "observation": "criterion mark_returned not required on this step"})
    result.details["controls"] = controls
    return
  ## Runtime adapter — distinguishes comment / noop-200 / durable return.
  let report = runLoanOracleAdapter(worktree, repoRoot)
  result.details["oracle"] = report
  if report{"controls"}.kind == JArray:
    for c in report["controls"]:
      let name = c{"name"}.getStr
      if name in ["schema_ok", "app_present", "served_tree_identity"]:
        continue
      controls.add(c)
  else:
    controls.add(%*{
      "name": "mark_returned_effect",
      "status": "failed",
      "observation": report{"error"}.getStr("oracle_failed")
    })
  result.details["controls"] = controls
  let effect = controlStatus(controls, "mark_returned_effect")
  let persist = controlStatus(controls, "persistence_after_restart")
  if report{"ok"}.getBool and effect == "passed" and persist == "passed":
    result.ok = true
    result.message = "loan return persisted after restart"
  else:
    result.ok = false
    if persist == "failed":
      result.message = "return_not_persisted"
    elif effect == "failed":
      result.message = "mark_returned_effect_failed"
    elif effect == "not_run" or persist == "not_run":
      result.message = "mark_returned_controls_incomplete"
    else:
      result.message = report{"error"}.getStr("loan_oracle_failed")

proc verifyForRecipe*(
    recipe: ProjectRecipe; worktree, repoRoot: string;
    finalStep = true): ProjectVerifyResult =
  ## Bind verification to the project recipe; generic pilot has no CSV oracle.
  ## Intermediate steps only require list integrity; final step runs full CSV.
  case recipe.verify
  of "csv_journey":
    result = verifyCsvJourney(worktree, repoRoot, requireCsv = finalStep)
  of "loan_notebook":
    let crit =
      if finalStep: @["server_starts", "schema_ok", "mark_returned"]
      else: @["server_starts", "schema_ok"]
    result = verifyLoanNotebook(worktree, repoRoot, crit)
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
  if recipe.verify == "loan_notebook":
    result = verifyLoanNotebook(worktree, repoRoot, criteria)
    return
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
    of "mark_returned":
      ## Require persisted effect, not a static string mention.
      let controls =
        if verifyNode{"controls"}.kind == JArray: verifyNode["controls"]
        else: verifyNode{"details", "controls"}
      if controlStatus(controls, "persistence_after_restart") != "passed":
        return false
    else:
      discard
  true

proc verifyToJson*(v: ProjectVerifyResult): JsonNode =
  result = %*{
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
  ## Promote project controls / served tree for Studio (generic, not CSV-specific).
  if not v.details.isNil:
    if v.details{"controls"} != nil:
      result["controls"] = v.details["controls"]
    if v.details{"served_tree"} != nil:
      result["served_tree"] = v.details["served_tree"]
