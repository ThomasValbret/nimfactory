## F17 Wave A smoke — simulated qualification oracles only (no real LLM calls).

import std/[os, strutils]
import ../qualification/[types, oracle, corpus, loader, fake_preparer]

proc repoRoot(): string =
  var dir = getCurrentDir()
  while dir.len > 0:
    if fileExists(dir / "nimfactory.nimble"):
      return dir
    let parent = parentDir(dir)
    if parent == dir: break
    dir = parent
  getCurrentDir()

proc main() =
  let root = repoRoot()
  if getCurrentDir() != root:
    setCurrentDir(root)

  echo "F17 qualification smoke (mode=simulated, no LLM)"

  for err in verifyFrozenCorpus():
    raise newException(AssertionDefect, "corpus: " & err)

  let scenarios = loadAllScenarios()
  doAssert scenarios.len >= 13,
    "expected essential discriminating scenarios, got " & $scenarios.len

  var discriminators: seq[string] = @[]
  for sc in scenarios:
    for err in selfConsistentChecks(sc.checks):
      raise newException(AssertionDefect, sc.id & " oracle structure: " & err)
    doAssert sc.schema == QualSchemaScenario
    doAssert sc.oracleSchema == QualSchemaOracle
    doAssert sc.referenceObservation.qualificationMode == QualificationModeSimulated,
      sc.id & " reference must be simulated"

    let refVerdict = evaluateOracle(sc.referenceObservation, sc.checks)
    doAssert refVerdict.passed, sc.id & " reference failed: " & refVerdict.failedChecks.join("; ")

    let fake = loadFakeConstantObservation()
    doAssert fake.qualificationMode == QualificationModeSimulated
    let fakeVerdict = evaluateOracle(fake, sc.checks)
    if sc.discriminating:
      doAssert not fakeVerdict.passed,
        sc.id & " constant fake preparer wrongly passed discriminating oracle"

    discriminators.add sc.discriminator

  let required = @[
    "old_constraint_relevant",
    "recent_turns_useless",
    "bulky_irrelevant_skill",
    "indispensable_small_skill_dependency",
    "memory_contradiction",
    "user_correction",
    "source_changed",
    "previously_empty_search",
    "plausible_false_small_model_id_selection",
    "cancel_resume",
    "loop_without_progress",
    "concurrent_budget",
    "unknown_provider_effect",
  ]
  for req in required:
    doAssert req in discriminators, "missing essential discriminator: " & req

  echo "scenarios=", $scenarios.len, " discriminators=ok fake_preparer_fails=ok"
  echo "test_qualification_smoke: ok"

main()