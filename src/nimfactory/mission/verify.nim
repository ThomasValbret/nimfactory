## Reception tests: compile and run the oracle directory supplied by the caller.
## Assertions live only in that oracle — never hardcoded here, never in model context.

import std/[os, osproc, strutils, json, algorithm]

type
  VerifyResult* = object
    ok*: bool
    exitCode*: int
    stdout*: string
    stderr*: string
    command*: string
    oraclePath*: string
    message*: string

proc listOracleNimFiles(oracleDir: string): seq[string] =
  result = @[]
  if not dirExists(oracleDir):
    return
  for kind, path in walkDir(oracleDir):
    if kind == pcFile and path.endsWith(".nim"):
      result.add(path)
  result.sort()

proc resolveOracleEntry*(oracleDir: string): tuple[ok: bool; path: string; message: string] =
  if oracleDir.len == 0:
    return (false, "", "oracle path required (--oracle)")
  if not dirExists(oracleDir):
    return (false, "", "oracle directory not found: " & oracleDir)
  let files = listOracleNimFiles(oracleDir)
  if files.len == 0:
    return (false, "", "oracle directory has no .nim reception file: " & oracleDir)
  # Prefer a single entry; if several, take the first sorted name.
  (true, files[0], "")

proc runOracle*(worktree, oracleDir: string): VerifyResult =
  ## Execute the oracle file from `--oracle` against sources in the worktree.
  let resolved = resolveOracleEntry(oracleDir)
  if not resolved.ok:
    result.ok = false
    result.exitCode = 2
    result.message = resolved.message
    result.stderr = resolved.message
    result.oraclePath = oracleDir
    return
  result.oraclePath = resolved.path
  if not dirExists(worktree / "src"):
    result.ok = false
    result.exitCode = 2
    result.message = "worktree missing src/ directory"
    result.stderr = result.message
    return
  let tmpDir = getTempDir() / ("nf_oracle_" & $getCurrentProcessId())
  createDir(tmpDir)
  let bin = tmpDir / "oracle_bin"
  # Compile the caller-provided oracle with worktree sources on the path.
  let cmd = "nim c -r --hints:off --warnings:off --path:" & quoteShell(worktree / "src") &
            " -o:" & quoteShell(bin) & " " & quoteShell(resolved.path)
  result.command = cmd
  let (outp, code) = execCmdEx(cmd)
  result.exitCode = code
  result.stdout = outp
  result.ok = code == 0
  if not result.ok:
    result.stderr = outp
    result.message = "oracle reception failed"
  else:
    result.message = "oracle reception passed"

proc verifyToJson*(v: VerifyResult): JsonNode =
  %*{
    "ok": v.ok,
    "exit_code": v.exitCode,
    "stdout": v.stdout,
    "stderr": v.stderr,
    "command": v.command,
    "oracle_path": v.oraclePath,
    "message": v.message
  }
