## Reception tests: compile the oracle first, then run the binary only if compile OK.
## Assertions live only in that oracle — never hardcoded here, never in model context.

import std/[os, osproc, strutils, json, algorithm]

type
  VerifyPhase* = enum
    vpNone
    vpResolve
    vpCompile
    vpRun
    vpLaunch

  VerifyKind* = enum
    vkPass
    vkFunctionalFail   ## binary ran; functional check failed (e.g. quit(1), assert)
    vkCompileError     ## oracle/sources failed to compile
    vkLaunchError      ## compile OK but binary could not be started
    vkOracleMissing
    vkOther

  VerifyResult* = object
    ok*: bool
    kind*: VerifyKind
    phase*: VerifyPhase          ## furthest phase reached
    exitCode*: int               ## exit of the failing/successful terminal step
    compileExitCode*: int
    runExitCode*: int
    stdout*: string
    stderr*: string
    compileCommand*: string
    runCommand*: string
    command*: string             ## compat: last command attempted
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
  (true, files[0], "")

proc runOracle*(worktree, oracleDir: string): VerifyResult =
  ## Compile oracle against worktree sources; run binary only if compile succeeds.
  result.compileExitCode = -1
  result.runExitCode = -1
  result.phase = vpResolve
  let resolved = resolveOracleEntry(oracleDir)
  if not resolved.ok:
    result.ok = false
    result.kind = vkOracleMissing
    result.exitCode = 2
    result.message = resolved.message
    result.stderr = resolved.message
    result.oraclePath = oracleDir
    return
  result.oraclePath = resolved.path
  if not dirExists(worktree / "src"):
    result.ok = false
    result.kind = vkOther
    result.exitCode = 2
    result.message = "worktree missing src/ directory"
    result.stderr = result.message
    return

  let tmpDir = getTempDir() / ("nf_oracle_" & $getCurrentProcessId())
  createDir(tmpDir)
  let bin = tmpDir / "oracle_bin"
  let compileCmd = "nim c --hints:off --warnings:off --path:" &
                   quoteShell(worktree / "src") &
                   " -o:" & quoteShell(bin) & " " & quoteShell(resolved.path)
  result.compileCommand = compileCmd
  result.command = compileCmd
  result.phase = vpCompile
  let (cout, ccode) = execCmdEx(compileCmd)
  result.compileExitCode = ccode
  result.stdout = cout
  if ccode != 0:
    result.ok = false
    result.kind = vkCompileError
    result.exitCode = ccode
    result.stderr = cout
    result.message = "oracle compile error"
    return

  # Compilation succeeded — only now attempt to launch the binary.
  if not fileExists(bin):
    result.ok = false
    result.kind = vkLaunchError
    result.phase = vpLaunch
    result.exitCode = 127
    result.message = "oracle binary missing after successful compile"
    result.stderr = result.message
    return

  let runCmd = quoteShell(bin)
  result.runCommand = runCmd
  result.command = runCmd
  result.phase = vpRun
  try:
    let (rout, rcode) = execCmdEx(runCmd)
    result.runExitCode = rcode
    result.exitCode = rcode
    result.stdout = result.stdout & rout
    if rcode == 0:
      result.ok = true
      result.kind = vkPass
      result.message = "oracle reception passed"
    else:
      result.ok = false
      result.kind = vkFunctionalFail
      result.stderr = rout
      result.message = "oracle functional check failed"
  except OSError as e:
    result.ok = false
    result.kind = vkLaunchError
    result.phase = vpLaunch
    result.exitCode = 127
    result.message = "oracle binary launch failed: " & e.msg
    result.stderr = e.msg

proc verifyToJson*(v: VerifyResult): JsonNode =
  %*{
    "ok": v.ok,
    "kind": $v.kind,
    "phase": $v.phase,
    "exit_code": v.exitCode,
    "compile_exit_code": v.compileExitCode,
    "run_exit_code": v.runExitCode,
    "stdout": v.stdout,
    "stderr": v.stderr,
    "compile_command": v.compileCommand,
    "run_command": v.runCommand,
    "command": v.command,
    "oracle_path": v.oraclePath,
    "message": v.message
  }
