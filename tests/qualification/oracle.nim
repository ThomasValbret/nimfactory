## Independent oracle evaluation — does not read production preparer implementations.

import std/[json, strutils, tables]
import types

proc a1Probe(obs: QualObservation): JsonNode =
  if obs.extensions.isNil or obs.extensions.kind != JObject:
    return newJNull()
  obs.extensions.getOrDefault("a1_probe")

proc a1Outcomes(obs: QualObservation): seq[JsonNode] =
  let probe = a1Probe(obs)
  if probe.isNil or probe.kind != JObject:
    return @[]
  let outs = probe.getOrDefault("outcomes")
  if outs.isNil or outs.kind != JArray:
    return @[]
  for item in outs:
    result.add item

proc a1OutcomeByStep(obs: QualObservation; stepId: string): JsonNode =
  for item in a1Outcomes(obs):
    if item{"step_id"}.getStr == stepId:
      return item
  newJNull()

proc a1FieldValue(outcome: JsonNode; fieldPath: string): string =
  if outcome.isNil or outcome.kind != JObject:
    return ""
  if fieldPath in outcome:
    let n = outcome[fieldPath]
    if n.kind == JString:
      return n.getStr
    return $n
  let parts = fieldPath.split('.')
  if parts.len == 2 and parts[0] == "fields":
    let fields = outcome.getOrDefault("fields")
    if fields.kind == JObject and parts[1] in fields:
      let n = fields[parts[1]]
      if n.kind == JString:
        return n.getStr
      return $n
  ""

proc evaluateCheck*(obs: QualObservation, check: OracleCheck): (bool, string) =
  case check.kind
  of ckInstructionMustInclude:
    if check.target in obs.selectedInstructionIds:
      return (true, "")
    return (false, "missing instruction " & check.target)
  of ckInstructionMustOmit:
    if check.target in obs.selectedInstructionIds:
      return (false, "must omit instruction " & check.target)
    return (true, "")
  of ckFragmentMustInclude:
    if check.target in obs.fragmentRefs:
      return (true, "")
    for fr in obs.fragmentRefs:
      if fr.startsWith(check.target) or check.target in fr:
        return (true, "")
    return (false, "missing fragment " & check.target)
  of ckFragmentMustOmit:
    if check.target in obs.fragmentRefs:
      return (false, "must omit fragment " & check.target)
    return (true, "")
  of ckOmittedMustCite:
    for om in obs.omitted:
      let id =
        if om.kind == JObject and om.hasKey("id"): om{"id"}.getStr else: ""
      let reason =
        if om.kind == JObject and om.hasKey("reason"): om{"reason"}.getStr
        else: ""
      if id == check.target or check.target.len == 0:
        if check.detail.len == 0 or check.detail in reason:
          return (true, "")
    return (false, "omitted entry missing reason for " & check.target)
  of ckMissingMustInclude:
    if check.target in obs.missing:
      return (true, "")
    return (false, "missing list should include " & check.target)
  of ckStatusMustBe:
    if obs.status == check.target:
      return (true, "")
    return (false, "status " & obs.status & " != " & check.target)
  of ckReadSetMustRecord:
    if check.target in obs.readSetEntries:
      return (true, "")
    return (false, "read_set missing " & check.target)
  of ckSnapshotMustMatch:
    if obs.snapshotRef == check.target:
      return (true, "")
    return (
      false,
      "snapshot " & obs.snapshotRef & " != " & check.target,
    )
  of ckMustNotUseSourceRevision:
    let bad = "src-rev:" & check.target
    for fr in obs.fragmentRefs:
      if bad in fr:
        return (false, "stale source revision in fragment " & fr)
    for inc in obs.included:
      if bad in inc:
        return (false, "stale source revision in included " & inc)
    return (true, "")
  of ckContradictionResolved:
    ## target = memory id that must appear included; detail = superseded id
    if check.target notin obs.included and
        check.target notin obs.fragmentRefs:
      return (false, "contradiction winner not included: " & check.target)
    if check.detail.len > 0:
      for fr in obs.fragmentRefs:
        if check.detail in fr:
          return (false, "superseded memory still present: " & check.detail)
      for inc in obs.included:
        if check.detail in inc and check.detail != check.target:
          return (false, "superseded memory still included: " & check.detail)
    return (true, "")
  of ckTokenAccountingIncludesRoles:
    for role in check.target.split(';'):
      let r = role.strip()
      if r.len == 0: continue
      if not hasKey(obs.tokenAccounting, r):
        return (false, "token_accounting missing role " & r)
    return (true, "")
  of ckModeMustBeSimulated:
    if obs.qualificationMode != QualificationModeSimulated:
      return (
        false,
        "qualification_mode must be simulated, got " & obs.qualificationMode,
      )
    return (true, "")
  of ckCacheInvalidIfSourceRevision:
    let ext = obs.extensions
    if ext.isNil:
      return (false, "extensions missing for cache check")
    if ext.kind == JObject and ext.hasKey("cache_hit"):
      if ext{"cache_hit"}.getBool and ext.getOrDefault("cache_source_revision").getStr != check.target:
        return (false, "stale cache not invalidated for revision change")
    return (true, "")
  of ckLoopRequiresProgressSignal:
    let needle = if check.target.len > 0: check.target else: "loop_no_progress"
    if needle in obs.diagnostics:
      return (true, "")
    return (false, "expected loop progress diagnostic " & needle)
  of ckBudgetScopesDistinct:
    if obs.extensions.isNil or obs.extensions.kind != JObject:
      return (false, "budget_scopes extension required")
    let scopes = obs.extensions{"budget_scopes"}
    if scopes.isNil or scopes.kind != JArray:
      return (false, "budget_scopes extension required")
    var seen: seq[string] = @[]
    for s in scopes:
      let v = s.getStr
      if v in seen:
        return (false, "duplicate budget scope " & v)
      seen.add v
    if scopes.len < 2:
      return (false, "expected concurrent budget scopes >= 2")
    return (true, "")
  of ckEffectUnknownNotSuccess:
    if "effect_outcome_unknown" in obs.diagnostics and obs.status == "ok":
      return (false, "unknown effect must not be reported as ok")
    if check.target.len > 0 and check.target notin obs.diagnostics:
      return (false, "missing provider-effect diagnostic " & check.target)
    return (true, "")
  of ckDiagnosticMustInclude:
    for d in obs.diagnostics:
      if d == check.target or d.startsWith(check.target & ":") or check.target in d:
        return (true, "")
    return (false, "diagnostic missing " & check.target)
  of ckA1ProbeMode:
    let probe = a1Probe(obs)
    if probe.isNil or probe.kind != JObject:
      return (false, "a1_probe extension missing")
    let mode = probe.getOrDefault("mode").getStr
    let expected =
      if check.detail.len > 0: check.detail
      else: check.target
    if mode != expected:
      return (false, "a1_probe.mode " & mode & " != " & expected)
    return (true, "")
  of ckA1OutcomeVerdict:
    let outcome = a1OutcomeByStep(obs, check.target)
    if outcome.isNil or outcome.kind != JObject:
      return (false, "a1 step missing " & check.target)
    let verdict = outcome{"verdict"}.getStr
    if verdict != check.detail:
      return (false, check.target & " verdict " & verdict & " != " & check.detail)
    return (true, "")
  of ckA1OutcomeErrorCode:
    let outcome = a1OutcomeByStep(obs, check.target)
    if outcome.isNil or outcome.kind != JObject:
      return (false, "a1 step missing " & check.target)
    let code = outcome.getOrDefault("error_code").getStr
    if code != check.detail:
      return (false, check.target & " error_code " & code & " != " & check.detail)
    return (true, "")
  of ckA1OutcomeFieldEquals:
    let dot = check.target.rfind('.')
    if dot < 0:
      return (false, "a1 field target needs step.field form")
    let stepId = check.target[0 ..< dot]
    let field = check.target[dot + 1 .. ^1]
    let outcome = a1OutcomeByStep(obs, stepId)
    let got =
      if field.startsWith("fields."):
        a1FieldValue(outcome, field)
      else:
        a1FieldValue(outcome, "fields." & field)
    if got != check.detail:
      return (
        false,
        stepId & "." & field & " = " & got & " expected " & check.detail,
      )
    return (true, "")
  of ckA1OutcomeNoMutation:
    let outcome = a1OutcomeByStep(obs, check.target)
    if outcome.isNil or outcome.kind != JObject:
      return (false, "a1 step missing " & check.target)
    if outcome.getOrDefault("state_mutated").getBool(false):
      return (false, check.target & " mutated durable state")
    return (true, "")

proc evaluateOracle*(
    obs: QualObservation, checks: seq[OracleCheck]
): OracleVerdict =
  result.passed = true
  result.failedChecks = @[]
  result.diagnostics = @[]
  for c in checks:
    let (ok, msg) = evaluateCheck(obs, c)
    if not ok:
      result.passed = false
      result.failedChecks.add c.id & ": " & msg

proc selfConsistentChecks*(checks: seq[OracleCheck]): seq[string] =
  ## Structural sanity: unique ids, non-empty discriminating checks.
  var ids: seq[string] = @[]
  for c in checks:
    if c.id.len == 0:
      result.add "check with empty id"
    if c.id in ids:
      result.add "duplicate check id " & c.id
    ids.add c.id