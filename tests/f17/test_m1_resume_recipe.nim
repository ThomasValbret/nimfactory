## F17 M1: oracle-first parity + two-process interrupt/resume via CLI binary.
import std/[os, osproc, json, strutils]

proc need(path: string) =
  doAssert fileExists(path), "missing " & path

let root = getCurrentDir()
need(root / "recipes/m1_diamond.json")
need(root / "tests/fixtures/m1/oracle_outputs.json")

let oracle = parseJson(readFile(root / "tests/fixtures/m1/oracle_outputs.json"))
let want = oracle["expected_result"]["branch_order"]
doAssert want.kind == JArray and want.len == 2

# Build CLI if needed
let cli = root / "build" / "nimfactory_cli"
let buildCmd = "nim c --hints:off --warnings:off --path:src --path:vendor/NimAgentLibrary/src " &
               "--nimcache:build/nimcache-cli -o:build/nimfactory_cli src/nimfactory_cli.nim"
doAssert execCmd(buildCmd) == 0

proc branchesOf(report: JsonNode): seq[string] =
  result = @[]
  for it in report{"outputs"}{"result"}{"items"}:
    result.add(it{"branch"}.getStr())

proc runCli(args: string; outFile: string): int =
  let cmd = cli & " " & args & " > " & outFile
  execCmd(cmd)

let tmp = root / "build" / "f17-m1"
createDir(tmp)

block oracleParitySeqConc:
  let sSeq = tmp / "seq.sqlite"
  let sConc = tmp / "conc.sqlite"
  if fileExists(sSeq): removeFile(sSeq)
  if fileExists(sConc): removeFile(sConc)
  doAssert runCli(
    "run --graph recipes/m1_diamond.json --store " & sSeq &
    " --run-id m1-seq --mode sequential --input tests/fixtures/m1/input.json",
    tmp / "seq.json") == 0
  doAssert runCli(
    "run --graph recipes/m1_diamond.json --store " & sConc &
    " --run-id m1-conc --mode concurrent --max-concurrency 2 --input tests/fixtures/m1/input.json",
    tmp / "conc.json") == 0
  let seqR = parseJson(readFile(tmp / "seq.json"))
  let concR = parseJson(readFile(tmp / "conc.json"))
  doAssert branchesOf(seqR) == @[want[0].getStr(), want[1].getStr()]
  doAssert branchesOf(seqR) == branchesOf(concR)
  doAssert seqR{"outputs"}{"result"}{"count"}.getInt ==
           oracle{"expected_result"}{"count"}.getInt

block twoProcessInterruptResume:
  let store = tmp / "brk.sqlite"
  if fileExists(store): removeFile(store)
  let spill = store & ".spill"
  if dirExists(spill): removeDir(spill)
  let ex1 = runCli(
    "run --graph recipes/m1_diamond.json --store " & store &
    " --run-id m1-brk --mode sequential --checkpoint-after 1 --input tests/fixtures/m1/input.json",
    tmp / "intr.json")
  doAssert ex1 == 5, "expected interrupt exit 5 got " & $ex1
  let intr = parseJson(readFile(tmp / "intr.json"))
  doAssert intr{"status"}.getStr == "interrupted"
  let ex2 = runCli(
    "resume --graph recipes/m1_diamond.json --store " & store &
    " --run-id m1-brk --mode sequential",
    tmp / "res.json")
  doAssert ex2 == 0, "resume exit " & $ex2
  let res = parseJson(readFile(tmp / "res.json"))
  doAssert res{"status"}.getStr == "completed"
  doAssert res{"run_id"}.getStr == "m1-brk"
  doAssert branchesOf(res) == @[want[0].getStr(), want[1].getStr()]
  var skipped = false
  for s in res{"skipped_validated"}:
    if s.getStr == "split:main": skipped = true
  doAssert skipped, $res{"skipped_validated"}
  # inspect reinvoke policy
  doAssert runCli("inspect --store " & store & " --run-id m1-brk", tmp / "insp.json") == 0
  let insp = parseJson(readFile(tmp / "insp.json")){"run"}
  var denied = false
  for p in insp{"reinvoke_policy"}:
    if p{"activation_id"}.getStr == "split:main" and
       p{"reinvoke_allowed"}.getBool == false:
      denied = true
  doAssert denied

echo "test_m1_resume_recipe: ok"
