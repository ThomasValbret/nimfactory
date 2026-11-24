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

proc csvHelpersPresent*(worktree: string): bool =
  ## Helper step oracle: both csvQuote and formatCsv must exist in tasks.nim.
  let p = worktree / "src" / "tasks.nim"
  if not fileExists(p): return false
  let body = readFile(p)
  "csvQuote" in body and "formatCsv" in body

proc stripPyComments*(src: string): string =
  ## Drop `# …` outside quotes so comment-only "/return" cannot fake a handler.
  var acc = ""
  for line in src.splitLines:
    var inStr = false
    var quote = '\0'
    var i = 0
    var cleaned = ""
    while i < line.len:
      let c = line[i]
      if inStr:
        cleaned.add(c)
        if c == '\\' and i + 1 < line.len:
          cleaned.add(line[i + 1])
          inc i
          inc i
          continue
        if c == quote:
          inStr = false
        inc i
      elif c in {'"', '\''}:
        inStr = true
        quote = c
        cleaned.add(c)
        inc i
      elif c == '#':
        break
      else:
        cleaned.add(c)
        inc i
    acc.add(cleaned)
    acc.add('\n')
  acc

proc fileContentFingerprint*(path: string): string =
  ## Short stable fingerprint of a verified file (not cryptographic).
  if not fileExists(path): return ""
  var h: uint64 = 14695981039346656037u64
  for c in readFile(path):
    h = h xor uint64(ord(c))
    h = h * 1099511628211u64
  toHex(h, 16)

proc controlNode*(
    name: string; ok: bool; status, observations: string;
    fingerprints: JsonNode; attempt: JsonNode = nil): JsonNode =
  result = %*{
    "name": name,
    "ok": ok,
    "status": status,           ## passed | failed | absent | unexecuted | stale
    "observations": observations,
    "file_fingerprints": fingerprints,
    "attempt": if attempt.isNil: newJObject() else: attempt
  }

proc loanPersistAssign*(body: string): bool =
  ## True when UPDATE assigns a real date expression (date('now') or CURRENT_DATE).
  let low = body.toLowerAscii
  "returned_on = date('now')" in low or
    "returned_on = date(\"now\")" in low or
    "returned_on=date('now')" in low or
    "returned_on=date(\"now\")" in low or
    "returned_on = current_date" in low or
    "returned_on=current_date" in low or
    "set returned_on = current_date" in low or
    "returned_on = date('now')" in body or
    "CURRENT_DATE" in body and "returned_on" in low

proc loanTransactionCancelled*(body: string): bool =
  ## UPDATE then rollback / no commit ⇒ cancelled transaction (must fail).
  let low = body.toLowerAscii
  let retAt = low.find("returned_on")
  if retAt < 0: return false
  let rb = low.find("rollback", retAt)
  let cm = low.find("commit", retAt)
  if rb >= 0 and (cm < 0 or rb < cm):
    return true
  # Explicit no-op assignment is a cancelled persist.
  "returned_on = returned_on" in low


proc normalizeControlNode*(n: JsonNode; fingerprints: JsonNode = nil): JsonNode =
  ## Unify Studio (observation/status) and engine (observations/ok/fingerprints).
  result = if n.isNil: newJObject() else: n.copy()
  let st = result{"status"}.getStr
  if not result.hasKey("ok"):
    result["ok"] = %(st == "passed")
  if not result.hasKey("observations"):
    let obs = result{"observation"}
    if obs != nil and obs.kind == JString:
      result["observations"] = obs
    elif obs != nil:
      result["observations"] = %($obs)
    else:
      result["observations"] = %""
  if not result.hasKey("file_fingerprints"):
    result["file_fingerprints"] =
      if fingerprints.isNil: newJObject() else: fingerprints
  if st in ["not_run", "skipped", "unexecuted"]:
    # Preserve Studio's not_run vocabulary; ok stays false.
    result["ok"] = %false

proc findLoanOracleScript(repoRoot: string): string =
  ## Oracle lives next to the recipe cwd, or under fixtures when cwd is repo root.
  let direct = repoRoot / "oracle" / "verify_studio_change.py"
  if fileExists(direct): return direct
  let viaFixture = repoRoot / "fixtures" / "loan_notebook" / "oracle" /
                   "verify_studio_change.py"
  if fileExists(viaFixture): return viaFixture
  ""

proc controlStatus(node: JsonNode; name: string): string =
  if node.isNil or node.kind != JArray: return "not_run"
  for c in node.getElems:
    if c.isNil: continue
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

  # Enrich controls for engine done-gate (ok / observations / fingerprints).
  let appFp = %*{"skeleton/app.py": fileContentFingerprint(app)}
  let schemaFp = %*{"skeleton/schema.sql": fileContentFingerprint(schema)}
  var enriched = newJArray()
  for c in controls:
    let name = c{"name"}.getStr
    let fp =
      if name in ["schema_ok"]: schemaFp
      elif name in ["app_present", "server_starts", "mark_returned",
                    "mark_returned_effect", "persistence_after_restart"]: appFp
      else: newJObject()
    var node = normalizeControlNode(c, fp)
    # Map Studio effect controls onto mark_returned criterion alias.
    if name == "mark_returned_effect":
      node["criterion_alias"] = %"mark_returned"
    enriched.add(node)
  # Alias mark_returned for criteria that still use the recipe token.
  var hasMark = false
  for c in enriched:
    if c{"name"}.getStr == "mark_returned": hasMark = true
  if "mark_returned" in criteria and not hasMark:
    let effect = controlStatus(enriched, "mark_returned_effect")
    let persist = controlStatus(enriched, "persistence_after_restart")
    let ok = effect == "passed" and persist == "passed"
    let st =
      if ok: "passed"
      elif effect in ["not_run", "unexecuted"] or persist in ["not_run", "unexecuted"]:
        "not_run"
      else: "failed"
    enriched.add(%*{
      "name": "mark_returned",
      "ok": ok,
      "status": st,
      "observations": "effect=" & effect & "; persistence=" & persist,
      "file_fingerprints": appFp,
      "criterion_alias": "mark_returned"
    })
  if "server_starts" in criteria:
    var hasSrv = false
    for c in enriched:
      if c{"name"}.getStr == "server_starts": hasSrv = true
    if not hasSrv:
      for c in enriched:
        if c{"name"}.getStr == "app_present":
          var alias = c.copy()
          alias["name"] = %"server_starts"
          enriched.add(alias)
          break
  result.details["controls"] = enriched
  controls = enriched


proc stdoutRuleFromCriterion*(c: string): tuple[kind, expected, name: string] =
  ## kind: exact | contains | none
  let cl = c.strip()
  let low = cl.toLowerAscii
  if low.startsWith("stdout_exact:"):
    return ("exact", cl[cl.find(':')+1 .. ^1].strip(), cl)
  if low.startsWith("stdout_contains:"):
    return ("contains", cl[cl.find(':')+1 .. ^1].strip(), cl)
  if low == "stdout_bonjour":
    return ("contains", "bonjour", "stdout_bonjour")
  if low == "run_stdout":
    return ("contains", "", "run_stdout")
  ("none", "", c)

proc verifyGenericProgram*(
    worktree, repoRoot: string; criteria: seq[string]): ProjectVerifyResult =
  ## Empty / novel projects: file presence, program exit, and stdout rules.
  ## program_runs = exit 0; stdout_exact/contains carry expected vs observed.
  result.kind = "generic_program"
  result.details = newJObject()
  result.details["criteria"] = %criteria
  var controls = newJArray()
  let attempt = %*{"kind": "generic_program", "worktree": worktree}

  proc findEntry(): string =
    for name in ["hello.py", "main.py", "app.py", "salut.py"]:
      if fileExists(worktree / name): return name
    for prefer in ["main.py", "hello.py", "app.py", "salut.py"]:
      for path in walkDirRec(worktree):
        if fileExists(path) and extractFilename(path) == prefer:
          return relativePath(path, worktree).replace('\\', '/')
    for path in walkDirRec(worktree):
      if path.endsWith(".py") and fileExists(path):
        return relativePath(path, worktree).replace('\\', '/')
    for name in ["hello.nim", "main.nim"]:
      if fileExists(worktree / name): return name
    ""

  let entry = findEntry()
  let entryAbs = if entry.len > 0: worktree / entry else: ""
  var fp = newJObject()
  if entry.len > 0:
    fp[entry] = %fileContentFingerprint(entryAbs)
    # Fingerprint sibling sources so a linked-file mutation invalidates proof.
    let siblingDir =
      if '/' in entry or '\\' in entry: parentDir(entryAbs) else: worktree
    if dirExists(siblingDir):
      for path in walkDirRec(siblingDir):
        if path.endsWith(".py") and fileExists(path):
          let rel = relativePath(path, worktree).replace('\\', '/')
          fp[rel] = %fileContentFingerprint(path)

  var needStdout = false
  for c in criteria:
    if stdoutRuleFromCriterion(c).kind != "none" or c == "run_stdout":
      needStdout = true
  let needFile =
    criteria.len == 0 or "file_exists" in criteria or "file_created" in criteria or
    "program_runs" in criteria or needStdout
  if needFile or "file_exists" in criteria or "file_created" in criteria:
    let ok = entry.len > 0 and fileExists(entryAbs)
    controls.add(controlNode(
      if "file_created" in criteria: "file_created" else: "file_exists",
      ok, if ok: "passed" else: "failed",
      if ok: "created file present: " & entry else: "no entry script found",
      fp, attempt))

  let needRun = "program_runs" in criteria or needStdout
  var exitCode = -1
  var observed = ""
  var ran = false
  if needRun:
    if entry.len == 0 or not fileExists(entryAbs):
      if "program_runs" in criteria:
        controls.add(controlNode("program_runs", false, "absent",
          "program_runs absent — no file to execute", fp, attempt))
    elif not entry.endsWith(".py"):
      if "program_runs" in criteria:
        controls.add(controlNode("program_runs", false, "failed",
          "unsupported entry language for generic run: " & entry, fp, attempt))
    else:
      let py = findExe("python3")
      if py.len == 0:
        if "program_runs" in criteria:
          controls.add(controlNode("program_runs", false, "failed",
            "python3 not on PATH", fp, attempt))
      else:
        let workDir =
          if '/' in entry or '\\' in entry: parentDir(entryAbs) else: worktree
        let script = extractFilename(entry)
        let r = runCmd(workDir, py, @[script])
        exitCode = r.exit
        observed = r.outp.replace("\r\n", "\n")
        ran = true
        result.details["stdout"] = %observed
        result.details["exit"] = %exitCode
        if "program_runs" in criteria:
          let ok = exitCode == 0
          controls.add(controlNode(
            "program_runs", ok, if ok: "passed" else: "failed",
            "exit=" & $exitCode & " stdout=" & observed.strip(),
            fp, attempt))

  for c in criteria:
    let rule = stdoutRuleFromCriterion(c)
    if rule.kind == "none": continue
    var ok = false
    var status = "failed"
    var obs = ""
    let expected = rule.expected
    if not ran:
      status = "absent"
      obs = "stdout not observed — program did not run"
    else:
      let got = observed.strip()
      let cmp =
        if rule.kind == "exact":
          if got == expected: "exact_match" else: "exact_mismatch"
        else:
          if expected.len == 0:
            if got.len > 0: "contains_nonempty" else: "contains_empty"
          elif expected.toLowerAscii in got.toLowerAscii: "contains_match"
          else: "contains_mismatch"
      # Do not use endsWith("match"): "exact_mismatch" ends with "match".
      ok = cmp in ["exact_match", "contains_match", "contains_nonempty"]
      status = if ok: "passed" else: "failed"
      obs = "rule=" & rule.kind & " expected=" & expected &
            " observed=" & got & " comparison=" & cmp
      if exitCode != 0 and rule.kind != "none":
        # Exit failure is separate from stdout rule; still record observed.
        obs = obs & " exit=" & $exitCode
    var node = controlNode(rule.name, ok, status, obs, fp, attempt)
    node["expected"] = %expected
    node["observed"] = %observed.strip()
    node["comparison_rule"] = %rule.kind
    controls.add(node)

  for c in criteria:
    var found = false
    for n in controls:
      if n{"name"}.getStr == c: found = true
      if c == "file_created" and n{"name"}.getStr == "file_exists": found = true
      if stdoutRuleFromCriterion(c).name == n{"name"}.getStr: found = true
    if not found:
      controls.add(controlNode(c, false, "unexecuted",
        "control " & c & " requested but not executed", newJObject(), attempt))

  result.details["controls"] = controls
  var allOk = controls.len > 0
  var messages: seq[string] = @[]
  for n in controls:
    if not n{"ok"}.getBool:
      allOk = false
      messages.add(n{"name"}.getStr & ":" & n{"observations"}.getStr)
  result.ok = allOk
  result.message =
    if result.ok and controls.len > 0: controls[^1]{"observations"}.getStr
    elif messages.len > 0: messages.join(" | ")
    else: "no generic controls executed"

proc verifyForRecipe*(
    recipe: ProjectRecipe; worktree, repoRoot: string;
    finalStep = true): ProjectVerifyResult =
  ## Bind verification to the project recipe; generic pilot has no CSV oracle.
  case recipe.verify
  of "csv_journey":
    result = verifyCsvJourney(worktree, repoRoot, requireCsv = finalStep)
  of "loan_notebook":
    let crit =
      if finalStep: @["server_starts", "schema_ok", "mark_returned"]
      else: @["server_starts", "schema_ok"]
    result = verifyLoanNotebook(worktree, repoRoot, crit)
  of "generic_program", "run_stdout", "":
    let crit =
      if finalStep: @["file_exists", "program_runs"]
      else: @["file_exists"]
    result = verifyGenericProgram(worktree, repoRoot, crit)
  else:
    result.kind = recipe.verify
    result.ok = false
    result.message = "unknown recipe verify: " & recipe.verify
    result.details = newJObject()

proc verifyStepCriteria*(
    recipe: ProjectRecipe; worktree, repoRoot: string;
    criteria: seq[string]; finalStep = false): ProjectVerifyResult =
  ## Verify against criteria attached to the step (not only "last step" heuristic).
  if recipe.verify == "loan_notebook":
    result = verifyLoanNotebook(worktree, repoRoot, criteria)
    return
  var genericTok =
    "file_exists" in criteria or "file_created" in criteria or
    "program_runs" in criteria or "stdout_bonjour" in criteria or
    "run_stdout" in criteria
  for c in criteria:
    if c.startsWith("stdout_exact:") or c.startsWith("stdout_contains:"):
      genericTok = true
  if recipe.verify in ["generic_program", "run_stdout"] or
     (recipe.verify == "" and genericTok):
    result = verifyGenericProgram(worktree, repoRoot, criteria)
    return
  if recipe.verify == "" and not genericTok:
    # No recipe and no generic tokens: do not fall into CSV by accident.
    if "export_command" in criteria or "list_intact" in criteria or
       "compile" in criteria:
      result.kind = "criteria"
      result.ok = false
      result.message = "no verify bound to recipe for CSV criteria"
      result.details = %*{"criteria": criteria}
      return
    result = verifyGenericProgram(worktree, repoRoot,
      if criteria.len > 0: criteria else: @["file_exists", "program_runs"])
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
  of "csv_journey":
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
  var controls: JsonNode = nil
  if verifyNode.hasKey("controls") and verifyNode["controls"].kind == JArray:
    controls = verifyNode["controls"]
  elif verifyNode.hasKey("details") and verifyNode["details"].kind == JObject and
       verifyNode["details"].hasKey("controls") and
       verifyNode["details"]["controls"].kind == JArray:
    controls = verifyNode["details"]["controls"]
  for c in criteria:
    case c
    of "compile":
      if verifyNode{"compile_exit"}.getInt != 0: return false
    of "list_intact":
      if not verifyNode{"list_ok"}.getBool: return false
    of "export_command":
      if not verifyNode{"csv_ok"}.getBool: return false
    of "csv_helpers":
      if verifyNode{"details"} == nil or
         not verifyNode{"details"}{"csv_helpers"}.getBool: return false
    of "server_starts", "schema_ok":
      if controls != nil:
        var hit = false
        for n in controls:
          let nm = n{"name"}.getStr
          if nm == c or (c == "server_starts" and nm == "app_present"):
            hit = true
            let st = n{"status"}.getStr
            if st notin ["passed", "passed_legacy"] and not n{"ok"}.getBool:
              return false
        if not hit: return false
      elif c == "schema_ok" and not verifyNode{"details"}{"schema_ok"}.getBool:
        return false
    of "mark_returned":
      if controlStatus(controls, "persistence_after_restart") == "passed":
        discard
      elif controlStatus(controls, "mark_returned") == "passed":
        discard
      elif controls != nil:
        var hit = false
        for n in controls:
          if n{"name"}.getStr in ["mark_returned", "mark_returned_effect"]:
            hit = true
            if not n{"ok"}.getBool and n{"status"}.getStr != "passed":
              return false
        if not hit: return false
      else:
        return false
    of "file_exists", "file_created", "program_runs", "stdout_bonjour", "run_stdout":
      if controls == nil: return false
      var hit = false
      for n in controls:
        if n{"name"}.getStr == c or (c == "file_created" and n{"name"}.getStr == "file_exists"):
          hit = true
          if not n{"ok"}.getBool: return false
      if not hit: return false
    else:
      if c.startsWith("stdout_exact:") or c.startsWith("stdout_contains:"):
        if controls == nil: return false
        var hit = false
        for n in controls:
          if n{"name"}.getStr == c:
            hit = true
            if not n{"ok"}.getBool: return false
        if not hit: return false
      else:
        return false
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
