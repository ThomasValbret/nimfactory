## F17 Wave A — contract-shaped qualification types (simulated mode only).
## Oracles are derived from public WORK_PACKAGES contracts, not from other lots' code.

import std/[json, tables, os]

const QualSchemaScenario* = "nimfactory.qualification.scenario/0.1"
const QualSchemaOracle* = "nimfactory.qualification.oracle/0.1"
const QualSchemaObservation* = "nimfactory.qualification.observation/0.1"
const QualSchemaCorpusManifest* = "nimfactory.qualification.corpus/0.1"
const QualificationModeSimulated* = "simulated"

type
  OracleCheckKind* = enum
    ckInstructionMustInclude
    ckInstructionMustOmit
    ckFragmentMustInclude
    ckFragmentMustOmit
    ckOmittedMustCite
    ckMissingMustInclude
    ckStatusMustBe
    ckReadSetMustRecord
    ckSnapshotMustMatch
    ckMustNotUseSourceRevision
    ckContradictionResolved
    ckTokenAccountingIncludesRoles
    ckModeMustBeSimulated
    ckCacheInvalidIfSourceRevision
    ckLoopRequiresProgressSignal
    ckBudgetScopesDistinct
    ckEffectUnknownNotSuccess
    ckDiagnosticMustInclude

  OracleCheck* = object
    id*: string
    kind*: OracleCheckKind
    target*: string
    detail*: string

  OracleVerdict* = object
    passed*: bool
    failedChecks*: seq[string]
    diagnostics*: seq[string]

  QualObservation* = object
    schema*: string
    qualificationMode*: string
    scenarioId*: string
    snapshotRef*: string
    selectedInstructionIds*: seq[string]
    fragmentRefs*: seq[string]
    included*: seq[string]
    omitted*: seq[JsonNode]
    missing*: seq[string]
    readSetEntries*: seq[string]
    status*: string
    diagnostics*: seq[string]
    tokenAccounting*: Table[string, string]
    extensions*: JsonNode

proc kindFromString(s: string): OracleCheckKind =
  case s
  of "instruction_must_include": ckInstructionMustInclude
  of "instruction_must_omit": ckInstructionMustOmit
  of "fragment_must_include": ckFragmentMustInclude
  of "fragment_must_omit": ckFragmentMustOmit
  of "omitted_must_cite": ckOmittedMustCite
  of "missing_must_include": ckMissingMustInclude
  of "status_must_be": ckStatusMustBe
  of "read_set_must_record": ckReadSetMustRecord
  of "snapshot_must_match": ckSnapshotMustMatch
  of "must_not_use_source_revision": ckMustNotUseSourceRevision
  of "contradiction_resolved": ckContradictionResolved
  of "token_accounting_includes_roles": ckTokenAccountingIncludesRoles
  of "mode_must_be_simulated": ckModeMustBeSimulated
  of "cache_invalid_if_source_revision": ckCacheInvalidIfSourceRevision
  of "loop_requires_progress_signal": ckLoopRequiresProgressSignal
  of "budget_scopes_distinct": ckBudgetScopesDistinct
  of "effect_unknown_not_success": ckEffectUnknownNotSuccess
  of "diagnostic_must_include": ckDiagnosticMustInclude
  else: raise newException(ValueError, "unknown oracle check kind: " & s)

proc parseOracleChecks*(j: JsonNode): seq[OracleCheck] =
  result = @[]
  if j.kind != JArray:
    raise newException(ValueError, "oracle.checks must be array")
  for item in j:
    if item{"kind"}.kind != JString:
      raise newException(ValueError, "check.kind must be string")
    result.add OracleCheck(
      id: item{"id"}.getStr,
      kind: kindFromString(item{"kind"}.getStr),
      target: item{"target"}.getStr,
      detail: item.getOrDefault("detail").getStr)

proc observationFromJson*(j: JsonNode): QualObservation =
  if j{"schema"}.getStr != QualSchemaObservation:
    raise newException(ValueError, "observation schema mismatch")
  result.schema = QualSchemaObservation
  result.qualificationMode = j{"qualification_mode"}.getStr
  result.scenarioId = j{"scenario_id"}.getStr
  result.snapshotRef = j{"snapshot_ref"}.getStr
  result.selectedInstructionIds = @[]
  for id in j{"selected_instruction_ids"}:
    result.selectedInstructionIds.add id.getStr
  result.fragmentRefs = @[]
  for fr in j{"fragment_refs"}:
    result.fragmentRefs.add fr.getStr
  result.included = @[]
  for inc in j{"included"}:
    result.included.add inc.getStr
  result.omitted = @[]
  for om in j{"omitted"}:
    result.omitted.add om
  result.missing = @[]
  for m in j{"missing"}:
    result.missing.add m.getStr
  result.readSetEntries = @[]
  for rs in j{"read_set_entries"}:
    result.readSetEntries.add rs.getStr
  result.status = j{"status"}.getStr
  result.diagnostics = @[]
  for d in j{"diagnostics"}:
    result.diagnostics.add d.getStr
  result.tokenAccounting = initTable[string, string]()
  if j{"token_accounting"}.kind == JObject:
    for k, v in j{"token_accounting"}.pairs:
      result.tokenAccounting[k] =
        if v.kind == JString: v.getStr else: $v
  result.extensions =
    if j.hasKey("extensions"): j{"extensions"} else: newJObject()

proc qualRoot*(): string =
  var dir = getCurrentDir()
  while dir.len > 0:
    if dirExists(dir / "tests" / "fixtures" / "qualification"):
      return dir / "tests" / "fixtures" / "qualification"
    let parent = parentDir(dir)
    if parent == dir: break
    dir = parent
  "tests/fixtures/qualification"

proc fixturesDir*(): string = qualRoot()
proc scenariosDir*(): string = qualRoot() / "scenarios"