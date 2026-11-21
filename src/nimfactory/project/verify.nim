## Deterministic project verification for demo_tasks_cli CSV journey.

import std/[os, osproc, strutils, json, sequtils]

type
  ProjectVerifyResult* = object
    ok*: bool
    listOk*: bool
    csvOk*: bool
    quoteOk*: bool
    message*: string
    listOut*: string
    csvOut*: string
    compileExit*: int
    details*: JsonNode

proc runCmd(dir, bin: string; args: seq[string]): tuple[exit: int; outp: string] =
  let cmdline = quoteShell(bin) & " " & args.mapIt(quoteShell(it)).join(" ")
  let r = execCmdEx(cmdline, workingDir = dir)
  (r.exitCode, r.output)

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

proc verifyCsvJourney*(worktree, repoRoot: string): ProjectVerifyResult =
  ## (1) default list unchanged vs fixture baseline
  ## (2) CSV export on stdout
  ## (3) title with comma correctly quoted
  result.details = newJObject()
  result.compileExit = -1
  let comp = compileDemo(worktree)
  result.compileExit = comp.exit
  result.details["compile_out"] = %comp.outp
  if not comp.ok:
    result.ok = false
    result.message = "compile failed (exit " & $comp.exit & ")"
    return

  let listR = runCmd(worktree, comp.bin, @["list"])
  result.listOut = listR.outp.strip()
  let expectList = expectedListOutput(repoRoot).strip()
  result.listOk = listR.exit == 0 and result.listOut == expectList
  result.details["expected_list"] = %expectList
  result.details["list_exit"] = %listR.exit

  # Accept export-csv or --format=csv as the opt-in command.
  var csvR = runCmd(worktree, comp.bin, @["export-csv"])
  if csvR.exit != 0:
    csvR = runCmd(worktree, comp.bin, @["list", "--format=csv"])
  result.csvOut = csvR.outp.strip()
  let expectCsv = expectedCsvOutput(repoRoot).strip()
  result.csvOk = csvR.exit == 0 and result.csvOut == expectCsv
  result.details["expected_csv"] = %expectCsv
  result.details["csv_exit"] = %csvR.exit

  result.quoteOk = result.csvOut.contains("\"Appeler Alice, Bob\"") or
                   result.csvOut.contains("\"Appeler Alice, Bob\"")
  # Also accept RFC-style doubled quotes if present; primary check is comma field quoted.
  if not result.quoteOk and result.csvOut.contains("Alice, Bob"):
    # field with comma must be inside quotes somewhere on that line
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

proc verifyToJson*(v: ProjectVerifyResult): JsonNode =
  %*{
    "ok": v.ok,
    "list_ok": v.listOk,
    "csv_ok": v.csvOk,
    "quote_ok": v.quoteOk,
    "message": v.message,
    "list_out": v.listOut,
    "csv_out": v.csvOut,
    "compile_exit": v.compileExit,
    "details": if v.details.isNil: newJObject() else: v.details
  }
