## F16 CLI smoke: validate / run / inspect / events shapes.
import std/[os, json, strutils]
import nimfactory/cli

proc tmpStore(): string =
  let p = getCurrentDir() / "build" / "f16-tmp" / "cli.sqlite"
  createDir(p.parentDir)
  if fileExists(p): removeFile(p)
  p

block validateOk:
  let code = runCli(@["validate", "--graph", "recipes/m1_diamond.json"])
  doAssert code == ExitOk

block runAndInspect:
  let store = tmpStore()
  let code = runCli(@[
    "run",
    "--graph", "recipes/m1_diamond.json",
    "--store", store,
    "--run-id", "cli-run-1",
    "--mode", "sequential",
    "--input", "tests/fixtures/m1/input.json"
  ])
  doAssert code == ExitOk, $code
  let code2 = runCli(@["inspect", "--store", store, "--run-id", "cli-run-1"])
  doAssert code2 == ExitOk
  let code3 = runCli(@["events", "--store", store, "--run-id", "cli-run-1"])
  doAssert code3 == ExitOk

block missingArgsInvalid:
  let code = runCli(@["run"])
  doAssert code == ExitInvalid

echo "test_cli: ok"
