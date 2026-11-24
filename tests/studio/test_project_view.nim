import std/[json, os, tempfiles, unittest]
import nimfactory/application/project_view
import nimfactory/runtime/journal/[sqlite_ffi, schema]
import nimfactory/studio/sources
from nimfactory/mission/apply import simpleHash

suite "Studio project observation":
  let tmp = createTempDir("nf-studio-", "")
  defer: removeDir(tmp)
  let path = tmp / "store.sqlite"
  var writer: SqliteDb
  check sqlite3_open(path.cstring, addr writer) == SQLITE_OK
  defer: discard sqlite3_close(writer)
  applySchema(writer)

  test "unknown store cannot create a database":
    expect ProjectMissing: discard readProjectView(tmp / "absent.sqlite", "mission")
    check not fileExists(tmp / "absent.sqlite")

  test "a running step, an unknown provider outcome and the durable cursor survive repeat reads":
    let doc = %*{"kind":"project_mission", "project_id":"mission", "objective":"Ranger les livres",
      "steps":[{"id":"relier","status":"running","title":"Relier les volumes","depends_on":[],
        "result":{"provider_attempt":{"status":"unknown","owner_pid":12345,"owner_token":"private"}}}]}
    writer.runPrepared("INSERT INTO nf_runs(run_id,state_json,event_seq) VALUES(?,?,?)",
      ["project:mission", $doc, "107"])
    for i in 1..107:
      writer.runPrepared("INSERT INTO nf_events(run_id,seq,event_json) VALUES(?,?,?)",
        ["project:mission", $i, "{\"kind\":\"project.step\",\"step_id\":\"relier\"}"])
    writer.execSql("BEGIN IMMEDIATE")
    defer: writer.execSql("ROLLBACK")
    writer.runPrepared("UPDATE nf_runs SET state_json='{}' WHERE run_id=?", ["project:mission"])
    let first = readProjectView(path, "mission")
    check first == readProjectView(path, "mission")
    check first["cursor"].getInt == 107
    check first["events"].len == RecentEventLimit
    check first["events"][0]["seq"].getInt == 8
    check first["events"][99]["seq"].getInt == 107
    check first["steps"][0]["status"].getStr == "running"
    check first["steps"][0]["provider"] == %*{"status":"unknown"}
    check first["plan_versions"].len == 0
    check writer.queryAll("SELECT count(*) FROM nf_events", []) == @["107"]

  test "a branched plan retains its IDs, dependencies and optional artifacts":
    let steps = %*[
      {"id":"choose","title":"Choisir","status":"done"},
      {"id":"bind","title":"Relier","depends_on":["choose"],"status":"running"},
      {"id":"index","title":"Indexer","depends_on":["choose"],"status":"pending"},
      {"id":"deliver","title":"Livrer","depends_on":["bind","index"],"status":"pending"}]
    let doc = %*{"kind":"project_mission", "project_id":"books", "steps":steps,
      "plan_versions":[{"version":4,"steps":steps}], "current_plan_version":4}
    writer.runPrepared("INSERT INTO nf_runs(run_id,state_json) VALUES(?,?)", ["project:books", $doc])
    let view = readProjectView(path, "books")
    check view["steps"].len == 4
    check view["steps"][3]["depends_on"] == %*["bind","index"]
    check view["plan_versions"][0]["version"].getInt == 4
    check view["steps"][2]{"verify"} == nil
    check view["steps"][2]{"readable_diff"} == nil
    check view["events"].len == 0

  test "generic, structured and historical verification results can be reopened":
    let doc = %*{"kind":"project_mission", "project_id":"observations", "steps":[
      {"id":"generic","status":"done","result":{"verify":{"details":{"controls":[
        {"name":"file_exists:NOTICE.txt","status":"passed","observations":"target present: NOTICE.txt"},
        {"name":"program_runs","status":"unexecuted"}]}}}},
      {"id":"structured","status":"done","result":{"verify":{"controls":[
        {"name":"served_tree","status":"passed","observation":{"hash":"abc"},"observations":"hash=abc"}]}}},
      {"id":"legacy","status":"done","result":{"verify":{"compile_exit":0}}}]}
    writer.runPrepared("INSERT INTO nf_runs(run_id,state_json) VALUES(?,?)",
      ["project:observations", $doc])
    let steps = readProjectView(path, "observations")["steps"]
    let generic = steps[0]["controls_executed"]
    check generic[0]["message"].getStr == "target present: NOTICE.txt"
    check generic[0]["observation"] == generic[0]["message"]
    check generic[1]["status"].getStr == "unexecuted"
    check generic[1]["observation"].kind == JNull
    check steps[1]["controls_executed"][0]["observation"] == %*{"hash":"abc"}
    check steps[2]["controls_executed"][0]["name"].getStr == "compile"

  test "only matching accepted file bytes can be opened":
    let root = tmp / "trees"
    let tree = root / "record"
    createDir(tree / "src")
    let body = "let count = 3\n"
    writeFile(tree / "src/library.nim", body)
    let step = %*{"id":"record","accepted_tree_hash":"recorded-tree",
      "change":{"target_file":"src/library.nim","after_hash":simpleHash(body)}}
    check readAcceptedSource(root, step)["text"].getStr == body
    check readAcceptedSource("", step).isNil
    writeFile(tree / "src/library.nim", "other")
    check readAcceptedSource(root, step).isNil
    step["change"]["target_file"] = %"../outside"
    check readAcceptedSource(root, step).isNil
    when defined(posix):
      let outside = tmp / "outside.nim"
      writeFile(outside, body)
      createSymlink(outside, tree / "alias.nim")
      step["change"]["target_file"] = %"alias.nim"
      check readAcceptedSource(root, step).isNil
    expect ProjectMissing: discard readProjectView(path, "unknown")
