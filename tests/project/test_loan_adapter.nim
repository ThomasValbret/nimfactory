## Adapter observations: public witnesses including abort-tx and CURRENT_DATE.
import std/[os, json, strutils, tempfiles, unittest]
import nimfactory/project/verify
import nimfactory/project/tree_id

suite "loan notebook adapter observations":
  let fixture = getCurrentDir() / "fixtures" / "loan_notebook"
  check dirExists(fixture)

  proc candidate(addition: string): string =
    let root = createTempDir("loan-cand-", "")
    copyDir(fixture / "skeleton", root / "skeleton")
    let sk = readFile(fixture / "skeleton" / "app.py")
    let edit = parseJson(readFile(fixture / "builder" / "inject" /
                          "step_mark_returned.json"))["edits"][0]
    let anchor = edit["insertAfter"].getStr
    writeFile(root / "skeleton" / "app.py", sk.replace(anchor, anchor & addition))
    root

  proc correctText(): string =
    parseJson(readFile(fixture / "builder" / "inject" /
                       "step_mark_returned.json"))["edits"][0]["newText"].getStr

  proc statusOf(controls: JsonNode; name: string): string =
    for c in controls:
      if c{"name"}.getStr == name: return c{"status"}.getStr
    "missing"

  test "comment-only mention fails; persistence not_run":
    let root = candidate("        # /loans/{id}/return\n")
    defer: removeDir(root)
    let v = verifyLoanNotebook(root, fixture, @["server_starts", "schema_ok", "mark_returned"])
    check v.ok == false
    check statusOf(v.details["controls"], "mark_returned_effect") == "failed"
    check statusOf(v.details["controls"], "persistence_after_restart") == "not_run"

  test "HTTP 200 without SQLite mutation fails persistence":
    let noop = correctText().replace(
      "returned_on = date('now')", "returned_on = returned_on")
    let root = candidate(noop)
    defer: removeDir(root)
    let v = verifyLoanNotebook(root, fixture, @["server_starts", "schema_ok", "mark_returned"])
    check v.ok == false
    check statusOf(v.details["controls"], "persistence_after_restart") == "failed"

  test "aborted transaction after UPDATE fails despite HTTP 200":
    let abortTx = correctText().replace(
      "conn.commit()\n                if cur.rowcount == 0:",
      "conn.rollback()\n                if cur.rowcount == 0:")
    let root = candidate(abortTx)
    defer: removeDir(root)
    let v = verifyLoanNotebook(root, fixture, @["server_starts", "schema_ok", "mark_returned"])
    check v.ok == false
    check v.message == "return_not_persisted"
    check statusOf(v.details["controls"], "persistence_after_restart") == "failed"
    echo "abort_tx loan_id=", v.details{"oracle","adapter","loan_id"}
    echo "abort_tx served=", v.details{"served_tree","hash"}
    echo "abort_tx controls=", v.details["controls"]

  test "CURRENT_DATE durable return passes":
    let curDate = correctText().replace("date('now')", "CURRENT_DATE")
    let root = candidate(curDate)
    defer: removeDir(root)
    let v = verifyLoanNotebook(root, fixture, @["server_starts", "schema_ok", "mark_returned"])
    check v.ok
    check v.message == "loan return persisted after restart"
    check statusOf(v.details["controls"], "persistence_after_restart") == "passed"
    check treeFingerprint(root) == v.details{"served_tree","hash"}.getStr
    echo "current_date loan_id=", v.details{"oracle","adapter","loan_id"}
    echo "current_date served=", v.details{"served_tree","hash"}

  test "initial correct patch passes and exposes served_tree hash":
    let root = candidate(correctText())
    defer: removeDir(root)
    let v = verifyLoanNotebook(root, fixture, @["server_starts", "schema_ok", "mark_returned"])
    check v.ok
    check v.details{"served_tree","hash"}.getStr.len == 16
    check treeFingerprint(root) == v.details{"served_tree","hash"}.getStr
    check statusOf(v.details["controls"], "persistence_after_restart") == "passed"
    check proofCoversCriteria(verifyToJson(v), @["mark_returned"])
