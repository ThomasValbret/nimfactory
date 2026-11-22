import std/[json, os, tempfiles, unittest]
import nimfactory/application/project_command
import nimfactory/project/pipeline

suite "Studio revise command receipts":
  let tmp = createTempDir("nf-cmd-", "")
  defer: removeDir(tmp)
  let root = getCurrentDir()
  let fix = root / "fixtures" / "demo_tasks_cli"
  let store = tmp / "project.sqlite"
  let art = tmp / "artifacts"
  createDir(art)

  test "idempotent command_id and stale expected version":
    var ask = defaultProjectRequest()
    ask.storePath = store
    ask.projectId = "cmd_demo"
    ask.cwd = fix
    ask.objective = "Je veux pouvoir exporter mes tâches."
    ask.route = "inject"
    ask.injectPath = fix / "inject" / "plan_v1.json"
    ask.artifactDir = art
    let asked = projectAsk(ask)
    check asked.ok
    check asked.doc.currentPlanVersion == 1

    var rev = ask
    rev.refinement = "CSV sur stdout, garder list."
    rev.injectPath = fix / "inject" / "plan_v2.json"
    rev.commandId = "same-cmd"
    rev.expectedPlanVersion = 1
    rev.expectPlanVersion = true
    let first = executeRevisePlan(rev)
    check first.ok
    check first.report{"to_version"}.getInt == 2
    check first.report{"provider_calls"}.getInt == 1
    check first.report{"plan_delta","added"}.len >= 1

    let replay = executeRevisePlan(rev)
    check replay.report{"replayed"}.getBool
    check replay.report{"to_version"}.getInt == 2
    check replay.report{"provider_calls"}.getInt == 1

    var stale = rev
    stale.commandId = "stale-cmd"
    stale.expectedPlanVersion = 1
    let blocked = executeRevisePlan(stale)
    check not blocked.ok
    check blocked.verdict == "stale_plan_version"
    check blocked.report{"provider_calls"}.getInt == 0
