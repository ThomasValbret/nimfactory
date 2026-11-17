## Shared JSON validation helpers for factory schemas.

import std/[json, strutils]
import ./errors

proc rejectNonFiniteNumbers*(node: JsonNode; path = "$") =
  case node.kind
  of JFloat:
    let v = node.getFloat()
    if v != v or v == Inf or v == NegInf:
      raise newFactoryError(fecNonFiniteNumber,
        "non-finite number at " & path, phase = "validate")
  of JObject:
    for k, v in node.pairs:
      rejectNonFiniteNumbers(v, path & "." & k)
  of JArray:
    var i = 0
    for v in node:
      rejectNonFiniteNumbers(v, path & "[" & $i & "]")
      inc i
  else:
    discard

proc parseJsonStrict*(raw: string): JsonNode =
  try:
    result = parseJson(raw)
  except JsonParsingError as e:
    raise newFactoryError(fecInvalidJson, e.msg, phase = "validate")
  rejectNonFiniteNumbers(result)

proc requireObject*(node: JsonNode; path: string) =
  if node.isNil or node.kind != JObject:
    raise newFactoryError(fecValidationFailed, path & " must be object",
      phase = "validate")

proc requireStringField*(node: JsonNode; field: string) =
  if not node.hasKey(field) or node[field].kind != JString:
    raise newFactoryError(fecMissingRequiredInput,
      "missing string field: " & field, phase = "validate")

proc schemaVersionParts*(schema: string): tuple[name, version: string] =
  let parts = schema.rsplit('/', 1)
  if parts.len != 2:
    raise newFactoryError(fecSchemaMismatch, "invalid schema id: " & schema,
      phase = "validate")
  (parts[0], parts[1])

proc acceptSchema*(got, expected: string) =
  if got != expected:
    raise newFactoryError(fecSchemaMismatch,
      "expected schema " & expected & " got " & got, phase = "validate")
