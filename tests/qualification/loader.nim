import std/[json, os, strutils]
import types

type
  QualScenario* = object
    id*: string
    discriminator*: string
    discriminating*: bool
    schema*: string
    oracleSchema*: string
    checks*: seq[OracleCheck]
    referenceObservation*: QualObservation
    counterexampleObservation*: QualObservation
    hasCounterexample*: bool
    qualificationMode*: string
    waveTag*: string
    expectedOraclePass*: bool

proc loadScenario*(path: string): QualScenario =
  let j = parseFile(path)
  if j{"schema"}.getStr != QualSchemaScenario:
    raise newException(ValueError, "scenario schema mismatch in " & path)
  result.id = j{"scenario_id"}.getStr
  result.discriminator = j{"discriminator"}.getStr
  result.discriminating = j.getOrDefault("discriminating").getBool
  result.schema = QualSchemaScenario
  let oracle = j{"oracle"}
  if oracle{"schema"}.getStr != QualSchemaOracle:
    raise newException(ValueError, "oracle schema mismatch in " & path)
  result.oracleSchema = QualSchemaOracle
  result.checks = parseOracleChecks(oracle{"checks"})
  result.referenceObservation = observationFromJson(j{"reference_observation"})
  result.qualificationMode = j.getOrDefault("qualification_mode").getStr(QualificationModeSimulated)
  result.waveTag = j.getOrDefault("wave").getStr("")
  result.hasCounterexample = j.hasKey("counterexample_observation")
  if result.hasCounterexample:
    result.counterexampleObservation = observationFromJson(j{"counterexample_observation"})
  if oracle.hasKey("expected_pass_for_reference"):
    result.expectedOraclePass = oracle{"expected_pass_for_reference"}.getBool
  else:
    result.expectedOraclePass = true

proc listScenarioFiles*(): seq[string] =
  let dir = scenariosDir()
  if not dirExists(dir):
    return @[]
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".json"):
      result.add path

proc loadAllScenarios*(): seq[QualScenario] =
  for path in listScenarioFiles():
    result.add loadScenario(path)