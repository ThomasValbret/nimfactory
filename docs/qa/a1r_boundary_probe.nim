## Boundary probes for WAVE_A_1_R_REVIEW remainders A1-R1 / A1-R5.
## Exit 1 if any invariant fails. Includes one positive witness.
import std/[os, json, strutils, times]
import nimfactory/contracts/[validate, result, errors]
import nimfactory/budget/file_ledger

var failed = 0
var total = 0

proc note(caseId: string; pass: bool; observed: JsonNode) =
  inc total
  if not pass: inc failed
  echo $(%*{"case": caseId, "pass": pass, "observed": observed})

proc tmpRoot(): string =
  let p = getTempDir() / ("nf-a1r-bound-" & $epochTime().int & "-" & $getCurrentProcessId())
  createDir(p)
  p

proc reservedRun(snap: JsonNode): int =
  if snap.isNil or not snap.hasKey("scopes"): return 0
  for s in snap["scopes"]:
    if s{"scope"}.getStr == "run":
      return parseInt(s{"reserved_microusd"}.getStr("0"))
  0

block F14_symlink_same_storage:
  ## Both handles opened before first reservation; symlink parents must unify.
  let base = tmpRoot()
  let realDir = base / "real"
  createDir(realDir)
  let aliasDir = base / "alias"
  createSymlink(realDir, aliasDir)
  var l1 = openFileBudgetLedger(realDir / "book")
  var l2 = openFileBudgetLedger(aliasDir / "book")
  l1.defineScope("run", "100", 10)
  var r1ok = true
  var r2ok = true
  try: discard l1.reserve("run", "a1", 1, "70")
  except FactoryError: r1ok = false
  try: discard l2.reserve("run", "a2", 1, "70")
  except FactoryError: r2ok = false
  let shared = cast[pointer](l1) == cast[pointer](l2)
  let s1 = l1.snapshot()
  let s2 = l2.snapshot()
  let totalAuth = if shared: reservedRun(s1) else: reservedRun(s1) + reservedRun(s2)
  closeFileBudgetLedger(l1)
  closeFileBudgetLedger(l2)
  ## Persistence after reopen through the alias path.
  var l3 = openFileBudgetLedger(aliasDir / "book")
  var reopenRejected = false
  try: discard l3.reserve("run", "a3", 1, "70")
  except FactoryError: reopenRejected = true
  let after = reservedRun(l3.snapshot())
  closeFileBudgetLedger(l3)
  let pass = r1ok and (not r2ok) and shared and totalAuth <= 100 and
             reopenRejected and after <= 100
  note("F14_symlink_same_storage", pass, %*{
    "first_reserve_ok": r1ok,
    "second_reserve_rejected": not r2ok,
    "shared_handle": shared,
    "authorized_total": totalAuth,
    "ceiling": 100,
    "reopen_second_rejected": reopenRejected,
    "reserved_after_reopen": after,
    "first_state": s1,
    "second_state": s2
  })

block F0_surrogate_pair_duplicate:
  var rejected = false
  var parsed = newJNull()
  try:
    parsed = parseJsonStrict("""{"😀":1,"\uD83D\uDE00":2}""")
  except FactoryError:
    rejected = true
  note("F0_surrogate_pair_duplicate", rejected,
       %*{"rejected": rejected, "parsed": parsed})

block F0_single_surrogate_pair_valid:
  var accepted = false
  var reason = ""
  try:
    let n = parseJsonStrict("""{"\uD83D\uDE00":1}""")
    accepted = n.hasKey("😀") and n["😀"].getInt == 1
  except FactoryError as e:
    reason = e.msg
  note("F0_single_surrogate_pair_valid", accepted,
       %*{"accepted": accepted, "reason": reason})

block F0_diagnostic_wrong_types:
  var rejected = false
  try:
    discard resultFromJson(%*{
      "schema": ResultSchema, "status": "ok", "outputs": {},
      "needs": [],
      "diagnostics": [{"code": 123, "phase": [], "message": false}]
    })
  except FactoryError:
    rejected = true
  note("F0_diagnostic_wrong_types", rejected, %*{"rejected": rejected})

block F0_error_wrong_boolean:
  var rejected = false
  var decodedRetryable = true
  try:
    let r = resultFromJson(%*{
      "schema": ResultSchema, "status": "failed", "outputs": {},
      "needs": [], "diagnostics": [],
      "error": {"code": "x", "phase": "p", "retryable": "true", "reason": "r"}
    })
    decodedRetryable = r.errorRetryable
  except FactoryError:
    rejected = true
  note("F0_error_wrong_boolean", rejected,
       %*{"rejected": rejected, "decoded_retryable": decodedRetryable})

echo $(%*{"summary": "a1r_boundary_probes", "failed": failed, "total": total})
quit(if failed > 0: 1 else: 0)
