import std/[os, json, locks, random, typedthreads]
import nimfactory
import nimfactory/budget/budget

proc tempDb(name: string): string =
  let base = getCurrentDir() / "build" / "f14-tmp"
  createDir(base)
  let p = base / ("ledger-" & name & "-" & $rand(1_000_000_000))
  let root = p & ".ledger"
  if dirExists(root):
    removeDir(root)
  p

proc scopeRun(): string = "proj-1/run-1"
proc scopePrep(): string = scopeRun() & "/prep-1"
proc scopeTask(): string = scopePrep() & "/task-1"

proc setupRunLedger(db: string): FileBudgetLedger =
  let l = openFileBudgetLedger(db)
  l.defineScope("proj-1", "1000000", 20)
  l.defineScope(scopeRun(), "500000", 10)
  l.defineScope(scopePrep(), "200000", 5)
  l.defineScope(scopeTask(), "100000", 2)
  l

block capabilitiesHonestNaming:
  let caps = fileBudgetLedgerCapabilities()
  doAssert caps.backend == "file_journal"
  doAssert caps.sharedInProcess
  doAssert caps.journalRecovery
  doAssert not caps.multiProcessLock

block usageMissingCounterNotZero:
  let u = usageFromJson(%*{"accounting_kind": "reported", "input_tokens": 10})
  doAssert not u.outputTokens.present
  doAssert not u.costPresent
  let (_, ok) = effectiveCostMicroUsd(u)
  doAssert not ok

block rejectNegativeMicroUsdAndSends:
  let db = tempDb("negative")
  let l = openFileBudgetLedger(db)
  l.defineScope("leaf", "100", 5)
  var raisedUsd = false
  try:
    discard l.reserve("leaf", "att-neg-usd", 1, "-50")
  except FactoryError as e:
    raisedUsd = true
    doAssert e.code == fecValidationFailed
  doAssert raisedUsd
  var raisedSends = false
  try:
    discard l.reserve("leaf", "att-neg-send", -3, "10")
  except FactoryError as e:
    raisedSends = true
    doAssert e.code == fecValidationFailed
  doAssert raisedSends
  var reserved = parseBigIntStr("0")
  for s in l.snapshot()["scopes"]:
    if s["scope"].getStr == "leaf":
      reserved = parseBigIntStr(s["reserved_microusd"].getStr)
  doAssert reserved == 0
  var raisedOver = false
  try:
    discard l.reserve("leaf", "att-over", 1, "120")
  except FactoryError as e:
    raisedOver = true
    doAssert e.code == fecBudgetExhausted
  doAssert raisedOver
  l.closeFileBudgetLedger()

block sharedInProcessHandlesShareAuthority:
  let db = tempDb("shared-handles")
  let l1 = openFileBudgetLedger(db)
  l1.defineScope("leaf", "100", 10)
  let l2 = openFileBudgetLedger(db)
  doAssert cast[pointer](l1) == cast[pointer](l2)
  discard l1.reserve("leaf", "att-a", 1, "70")
  var raised = false
  try:
    discard l2.reserve("leaf", "att-b", 1, "70")
  except FactoryError as e:
    raised = true
    doAssert e.code == fecBudgetExhausted
  doAssert raised
  var reserved = 0'i64
  for s in l1.snapshot()["scopes"]:
    if s["scope"].getStr == "leaf":
      reserved = parseBigIntStr(s["reserved_microusd"].getStr)
  doAssert reserved == 70
  l1.closeFileBudgetLedger()
  l2.closeFileBudgetLedger()

block symlinkParentsSharePhysicalAuthority:
  ## A1-R1: open both handles before reservation; symlink must not dual-count.
  let base = getCurrentDir() / "build" / "f14-tmp" /
             ("symlink-" & $getCurrentProcessId() & "-" & $rand(1_000_000_000))
  if dirExists(base): removeDir(base)
  createDir(base)
  let realDir = base / "real"
  createDir(realDir)
  let aliasDir = base / "alias"
  if symlinkExists(aliasDir) or fileExists(aliasDir) or dirExists(aliasDir):
    removeFile(aliasDir)
  createSymlink(realDir, aliasDir)
  let l1 = openFileBudgetLedger(realDir / "book")
  let l2 = openFileBudgetLedger(aliasDir / "book")
  doAssert cast[pointer](l1) == cast[pointer](l2)
  l1.defineScope("run", "100", 10)
  discard l1.reserve("run", "att-a", 1, "70")
  var raised = false
  try:
    discard l2.reserve("run", "att-b", 1, "70")
  except FactoryError as e:
    raised = true
    doAssert e.code == fecBudgetExhausted
  doAssert raised
  l1.closeFileBudgetLedger()
  l2.closeFileBudgetLedger()
  let l3 = openFileBudgetLedger(aliasDir / "book")
  var reserved = 0'i64
  for s in l3.snapshot()["scopes"]:
    if s["scope"].getStr == "run":
      reserved = parseBigIntStr(s["reserved_microusd"].getStr)
  doAssert reserved == 70
  var raised2 = false
  try:
    discard l3.reserve("run", "att-c", 1, "70")
  except FactoryError:
    raised2 = true
  doAssert raised2
  l3.closeFileBudgetLedger()

block persistFailureThenRetryCoherent:
  let db = tempDb("persist-fail")
  var l = openFileBudgetLedger(db)
  l.defineScope("leaf", "1000", 10)
  budgetLedgerTestPersistFail = true
  var failed = false
  try:
    discard l.reserve("leaf", "att-persist", 1, "55")
  except FactoryError as e:
    failed = true
    doAssert e.code == fecEffectOutcomeUnknown
  doAssert failed
  budgetLedgerTestPersistFail = false
  var reservedMem = 0'i64
  for s in l.snapshot()["scopes"]:
    if s["scope"].getStr == "leaf":
      reservedMem = parseBigIntStr(s["reserved_microusd"].getStr)
  doAssert reservedMem == 0
  let r2 = l.reserve("leaf", "att-persist", 1, "55")
  doAssert r2["state"].getStr == "reserved"
  l.closeFileBudgetLedger()
  l = openFileBudgetLedger(db)
  var reservedDisk = 0'i64
  for s in l.snapshot()["scopes"]:
    if s["scope"].getStr == "leaf":
      reservedDisk = parseBigIntStr(s["reserved_microusd"].getStr)
  doAssert reservedDisk == 55
  l.closeFileBudgetLedger()

block idempotencyConflictOnDifferentAmount:
  let db = tempDb("idempotency-conflict")
  let l = openFileBudgetLedger(db)
  l.defineScope("leaf", "500", 10)
  discard l.reserve("leaf", "att-x", 1, "10")
  var raised = false
  try:
    discard l.reserve("leaf", "att-x", 1, "90")
  except FactoryError as e:
    raised = true
    doAssert e.code == fecValidationFailed
  doAssert raised
  l.closeFileBudgetLedger()

block journalTailRecoveryWithoutSnapshot:
  let db = tempDb("journal-recovery")
  var l = openFileBudgetLedger(db)
  l.defineScope("leaf", "200", 5)
  discard l.reserve("leaf", "att-jr", 1, "80")
  let root = db & ".ledger"
  let statePath = root / "state.json"
  doAssert fileExists(statePath)
  removeFile(statePath)
  l.closeFileBudgetLedger()
  l = openFileBudgetLedger(db)
  var reserved = 0'i64
  for s in l.snapshot()["scopes"]:
    if s["scope"].getStr == "leaf":
      reserved = parseBigIntStr(s["reserved_microusd"].getStr)
  doAssert reserved == 80
  l.closeFileBudgetLedger()

block nestedReserveAndSettle:
  let db = tempDb("nested")
  var l = setupRunLedger(db)
  let r = l.reserve(scopeTask(), "att-nested-1", 1, "40000")
  doAssert r["state"].getStr == "reserved"
  let usage = %*{
    "accounting_kind": "reported",
    "input_tokens": 100,
    "output_tokens": 50,
    "cached_tokens": 25,
    "cost_microusd": "12000",
    "role": "main"
  }
  l.settle(r["reservation_id"].getStr, usage)
  let snap = l.snapshot()
  let scopes = snap["scopes"]
  var runSpent = ""
  for s in scopes:
    if s["scope"].getStr == scopeRun():
      runSpent = s["spent_microusd"].getStr
  doAssert parseBigIntStr(runSpent) == 12000
  l.closeFileBudgetLedger()

block idempotentReserveAndDuplicateSettle:
  let db = tempDb("idempotent")
  let l = setupRunLedger(db)
  let r1 = l.reserve(scopeTask(), "att-dup", 1, "10000")
  let r2 = l.reserve(scopeTask(), "att-dup", 1, "10000")
  doAssert r1["reservation_id"] == r2["reservation_id"]
  let usage = %*{"accounting_kind": "reported", "cost_microusd": "9000"}
  l.settle("rsv-att-dup", usage)
  l.settle("rsv-att-dup", usage)
  var spent = 0'i64
  for s in l.snapshot()["scopes"]:
    if s["scope"].getStr == scopeTask():
      spent = parseBigIntStr(s["spent_microusd"].getStr)
  doAssert spent == 9000
  l.closeFileBudgetLedger()

block releaseBeforeSendOnly:
  let db = tempDb("release")
  let l = setupRunLedger(db)
  let r = l.reserve(scopeTask(), "att-rel", 1, "15000")
  l.releaseBeforeSend(r["reservation_id"].getStr)
  var raised = false
  try:
    l.releaseBeforeSend("rsv-att-rel")
  except FactoryError as e:
    raised = true
    doAssert e.code == fecMissingRequiredInput
  doAssert raised
  l.closeFileBudgetLedger()

block unknownSendKeepsReserve:
  let db = tempDb("unknown")
  let l = setupRunLedger(db)
  let r = l.reserve(scopeTask(), "att-unk", 1, "30000")
  l.markUnknown(r["reservation_id"].getStr, "transport timeout after dispatch")
  let before = l.snapshot()
  var reservedRun = 0'i64
  for s in before["scopes"]:
    if s["scope"].getStr == scopeRun():
      reservedRun = parseBigIntStr(s["reserved_microusd"].getStr)
  doAssert reservedRun >= 30000
  var raised = false
  try:
    l.releaseBeforeSend(r["reservation_id"].getStr)
  except FactoryError as e:
    raised = true
    doAssert e.code == fecValidationFailed
  doAssert raised
  l.closeFileBudgetLedger()

block resumeAfterReserve:
  let db = tempDb("resume")
  var l = setupRunLedger(db)
  discard l.reserve(scopeTask(), "att-resume", 1, "22000")
  l.closeFileBudgetLedger()
  l = openFileBudgetLedger(db)
  let again = l.reserve(scopeTask(), "att-resume", 1, "22000")
  doAssert again["state"].getStr == "reserved"
  doAssert again["max_microusd"].getStr == "22000"
  l.closeFileBudgetLedger()

block obsoleteAttemptStillCounts:
  let db = tempDb("obsolete")
  let l = setupRunLedger(db)
  let r = l.reserve(scopeTask(), "att-old", 1, "18000")
  let usage = %*{
    "accounting_kind": "reported",
    "cost_microusd": "17500",
    "obsolete_attempt": true
  }
  l.settle(r["reservation_id"].getStr, usage)
  var spent = 0'i64
  for s in l.snapshot()["scopes"]:
    if s["scope"].getStr == scopeTask():
      spent = parseBigIntStr(s["spent_microusd"].getStr)
  doAssert spent == 17500
  l.closeFileBudgetLedger()

block preparerRelectorCosts:
  let db = tempDb("roles")
  let l = setupRunLedger(db)
  let prep = l.reserve(scopePrep(), "att-prep", 1, "8000")
  let refl = l.reserve(scopePrep(), "att-refl", 1, "5000")
  l.settle(prep["reservation_id"].getStr, %*{
    "accounting_kind": "reported",
    "cost_microusd": "7000",
    "role": "preparer",
    "local_resources": %*{"cpu_ms": 120}
  })
  l.settle(refl["reservation_id"].getStr, %*{
    "accounting_kind": "estimated",
    "provider_cost_microusd": "4500",
    "role": "reflector"
  })
  var prepSpent: int64
  for s in l.snapshot()["scopes"]:
    if s["scope"].getStr == scopePrep():
      prepSpent = parseBigIntStr(s["spent_microusd"].getStr)
  doAssert prepSpent == 11500
  l.closeFileBudgetLedger()

block concurrentNearCeiling:
  let db = tempDb("concurrent")
  let l = setupRunLedger(db)
  const nThreads = 8
  const each = "15000"
  var okCount = 0
  var failCount = 0
  var countersLock: Lock
  initLock(countersLock)
  type WorkerArg = (FileBudgetLedger, int)
  var threads: array[nThreads, Thread[WorkerArg]]
  proc worker(arg: WorkerArg) {.thread.} =
    let (ledger, tid) = arg
    let attempt = "att-conc-" & $tid
    try:
      discard ledger.reserve(scopeTask(), attempt, 1, each)
      acquire(countersLock)
      okCount += 1
      release(countersLock)
    except FactoryError as e:
      if e.code == fecBudgetExhausted:
        acquire(countersLock)
        failCount += 1
        release(countersLock)
      else:
        raise
  for i in 0 ..< nThreads:
    createThread(threads[i], worker, (l, i))
  joinThreads(threads)
  doAssert okCount >= 1
  doAssert failCount >= 1
  doAssert okCount + failCount == nThreads
  l.closeFileBudgetLedger()

block nestedSubtasksShareParent:
  let db = tempDb("subtasks")
  let l = setupRunLedger(db)
  let task2Scope = scopePrep() & "/task-2"
  l.defineScope(task2Scope, "100000", 2)
  discard l.reserve(scopeTask(), "att-t1", 1, "50000")
  discard l.reserve(task2Scope, "att-t2", 1, "40000")
  var runReserved: int64
  for s in l.snapshot()["scopes"]:
    if s["scope"].getStr == scopeRun():
      runReserved = parseBigIntStr(s["reserved_microusd"].getStr)
  doAssert runReserved == 90000
  discard l.reserve(scopeTask(), "att-t1b", 1, "50000")
  var raised = false
  try:
    discard l.reserve(scopeTask(), "att-t3", 1, "5000")
  except FactoryError as e:
    raised = true
    doAssert e.code == fecBudgetExhausted
  doAssert raised
  l.closeFileBudgetLedger()

echo "test_budget: ok"