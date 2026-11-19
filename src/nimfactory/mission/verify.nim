## Reception tests run against the isolated worktree (oracle stays out of model context).

import std/[os, osproc, strutils, json]

type
  VerifyResult* = object
    ok*: bool
    exitCode*: int
    stdout*: string
    stderr*: string
    command*: string
    oraclePath*: string

proc runOracle*(worktree, oracleDir: string): VerifyResult =
  ## Compile a tiny driver that imports the worktree normalize module and
  ## evaluates the reception assertions (oracle body stays outside model context).
  let oracleSrc = oracleDir / "test_normalize.nim"
  result.oraclePath = oracleSrc
  let normalizePath = worktree / "src" / "normalize.nim"
  if not fileExists(normalizePath):
    result.ok = false
    result.stderr = "worktree missing src/normalize.nim"
    return
  let tmpDir = getTempDir() / ("nf_oracle_" & $getCurrentProcessId())
  createDir(tmpDir)
  let wrapper = tmpDir / "oracle_main.nim"
  let bin = tmpDir / "oracle_bin"
  let normImport = normalizePath.replace('\\', '/')
  writeFile(wrapper,
    "import \"" & normImport & "\"\n" &
    "doAssert normalize(\"\") == \"EMPTY\"\n" &
    "doAssert normalize(\"   \") == \"EMPTY\"\n" &
    "doAssert normalize(\" hi \") == \"hi\"\n" &
    "doAssert normalize(\"x\") == \"x\"\n" &
    "echo \"oracle_normalize: ok\"\n")
  let cmd = "nim c -r --hints:off --warnings:off -o:" & quoteShell(bin) &
            " " & quoteShell(wrapper)
  result.command = cmd
  let (outp, code) = execCmdEx(cmd)
  result.exitCode = code
  result.stdout = outp
  result.ok = code == 0 and outp.contains("oracle_normalize: ok")
  if not result.ok:
    result.stderr = outp

proc verifyToJson*(v: VerifyResult): JsonNode =
  %*{
    "ok": v.ok,
    "exit_code": v.exitCode,
    "stdout": v.stdout,
    "stderr": v.stderr,
    "command": v.command,
    "oracle_path": v.oraclePath
  }
