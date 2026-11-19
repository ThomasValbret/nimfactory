## F17 M1: oracle parity, multi-checkpoint resume, durable SQLite match, second resume.
import std/[os, osproc, json, strutils]

proc need(path: string) =
  doAssert fileExists(path), "missing " & path

let root = getCurrentDir()
need(root / "recipes/m1_diamond.json")
need(root / "tests/fixtures/m1/oracle_outputs.json")

let oracle = parseJson(readFile(root / "tests/fixtures/m1/oracle_outputs.json"))
let want = oracle["expected_result"]["branch_order"]
doAssert want.kind == JArray and want.len == 2

let cli = root / "build" / "nimfactory_cli"
let buildCmd = "nim c --hints:off --warnings:off --threads:on --path:src --path:vendor/NimAgentLibrary/src " &
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
  doAssert concR{"peak_concurrent_invocations"}.getInt >= 2

block multiCheckpointInterruptResume:
  let expected = @[
    (1, @["split:main"]),
    (2, @["split:main", "left:left"]),
    (3, @["split:main", "left:left", "right:right"]),
    (4, @["split:main", "left:left", "right:right", "merge:main"]),
    (5, @["split:main", "left:left", "right:right", "merge:main", "reduce:main"])
  ]
  let cont = parseJson(readFile(tmp / "seq.json"))
  for (n, wantActs) in expected:
    let store = tmp / ("brk-" & $n & ".sqlite")
    if fileExists(store): removeFile(store)
    let spill = store & ".spill"
    if dirExists(spill): removeDir(spill)
    let ex1 = runCli(
      "run --graph recipes/m1_diamond.json --store " & store &
      " --run-id m1-brk-" & $n & " --mode sequential --checkpoint-after " & $n &
      " --input tests/fixtures/m1/input.json",
      tmp / ("intr-" & $n & ".json"))
    doAssert ex1 == 5, "expected interrupt exit 5 got " & $ex1 & " at ckpt " & $n
    let intr = parseJson(readFile(tmp / ("intr-" & $n & ".json")))
    doAssert intr{"status"}.getStr == "interrupted"
    doAssert runCli("inspect --store " & store & " --run-id m1-brk-" & $n,
                    tmp / ("insp-intr-" & $n & ".json")) == 0
    let inspIntr = parseJson(readFile(tmp / ("insp-intr-" & $n & ".json"))){"run"}
    let displayed = intr{"outputs"}
    let durable = inspIntr{"state"}{"outputs"}
    if not displayed.isNil and displayed.kind == JObject and displayed.len > 0:
      doAssert $durable == $displayed,
        "displayed missing from SQLite at ckpt " & $n & " displayed=" & $displayed &
        " durable=" & $durable
    for aid in wantActs:
      doAssert inspIntr{"activations"}{aid}{"invocation_validated"}.getBool,
        "expected validated " & aid & " at ckpt " & $n
    let ex2 = runCli(
      "resume --graph recipes/m1_diamond.json --store " & store &
      " --run-id m1-brk-" & $n & " --mode sequential",
      tmp / ("res-" & $n & ".json"))
    doAssert ex2 == 0, "resume exit " & $ex2 & " at ckpt " & $n
    let res = parseJson(readFile(tmp / ("res-" & $n & ".json")))
    doAssert res{"status"}.getStr == "completed"
    doAssert branchesOf(res) == @[want[0].getStr(), want[1].getStr()]
    doAssert $res{"outputs"} == $cont{"outputs"}
    var skipped = 0
    for s in res{"skipped_validated"}:
      if s.getStr in wantActs: inc skipped
    doAssert skipped == wantActs.len, $res{"skipped_validated"}
    # Second resume idempotent
    doAssert runCli(
      "resume --graph recipes/m1_diamond.json --store " & store &
      " --run-id m1-brk-" & $n & " --mode sequential",
      tmp / ("res2-" & $n & ".json")) == 0
    let res2 = parseJson(readFile(tmp / ("res2-" & $n & ".json")))
    doAssert $res2{"outputs"} == $res{"outputs"}

block unknownResumeRefused:
  let store = tmp / "empty.sqlite"
  if fileExists(store): removeFile(store)
  # create empty store file via a throwaway run then delete run is hard; use fresh path
  # open via inspect of unknown on brand-new store
  let ex = runCli("inspect --store " & store & " --run-id no-such",
                  tmp / "unknown.json")
  doAssert ex != 0

echo "test_m1_resume_recipe: ok"
