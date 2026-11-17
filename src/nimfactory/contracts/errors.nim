## Cross-cutting factory error codes and structured diagnostics.

type
  FactoryErrorCode* = enum
    fecSchemaMismatch = "schema_mismatch"
    fecMissingRequiredInput = "missing_required_input"
    fecStaleSnapshot = "stale_snapshot"
    fecUnsupportedCapability = "unsupported_capability"
    fecBudgetExhausted = "budget_exhausted"
    fecDependencyCycle = "dependency_cycle"
    fecEffectOutcomeUnknown = "effect_outcome_unknown"
    fecValidationFailed = "validation_failed"
    fecUnknownRequiredFeature = "unknown_required_feature"
    fecDuplicateKey = "duplicate_key"
    fecNonFiniteNumber = "non_finite_number"
    fecInvalidJson = "invalid_json"

  FactoryError* = object of CatchableError
    code*: FactoryErrorCode
    phase*: string
    retryable*: bool
    refs*: seq[string]

  Diagnostic* = object
    code*: string
    phase*: string
    message*: string
    retryable*: bool
    refs*: seq[string]

proc newFactoryError*(code: FactoryErrorCode; msg: string;
                      phase = ""; retryable = false;
                      refs: seq[string] = @[]): ref FactoryError =
  result = newException(FactoryError, msg)
  result.code = code
  result.phase = phase
  result.retryable = retryable
  result.refs = refs

proc diagnostic*(code, phase, message: string; retryable = false;
                 refs: seq[string] = @[]): Diagnostic =
  Diagnostic(code: code, phase: phase, message: message,
             retryable: retryable, refs: refs)
