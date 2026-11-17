## Shared JSON validation helpers for factory schemas.
## parseJsonStrict rejects duplicate object keys before std/json collapse.

import std/[json, strutils, tables]
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

type
  ScanCtx = object
    s: string
    i: int

proc peek(c: ScanCtx): char =
  if c.i >= c.s.len: '\0' else: c.s[c.i]

proc advance(c: var ScanCtx) =
  if c.i < c.s.len: inc c.i

proc skipWs(c: var ScanCtx) =
  while c.i < c.s.len and c.s[c.i] in {' ', '\t', '\n', '\r'}:
    inc c.i

proc expectChar(c: var ScanCtx; ch: char) =
  skipWs(c)
  if peek(c) != ch:
    raise newFactoryError(fecInvalidJson,
      "expected '" & $ch & "' at " & $c.i, phase = "validate")
  advance(c)

proc parseStringRaw(c: var ScanCtx): string =
  expectChar(c, '"')
  result = ""
  while true:
    if c.i >= c.s.len:
      raise newFactoryError(fecInvalidJson, "unterminated string", phase = "validate")
    let ch = peek(c)
    advance(c)
    if ch == '"':
      return
    if ch == '\\':
      if c.i >= c.s.len:
        raise newFactoryError(fecInvalidJson, "bad escape", phase = "validate")
      let e = peek(c)
      advance(c)
      case e
      of '"', '\\', '/': result.add(e)
      of 'b': result.add('\b')
      of 'f': result.add('\f')
      of 'n': result.add('\n')
      of 'r': result.add('\r')
      of 't': result.add('\t')
      of 'u':
        # Consume 4 hex digits; keep as escaped form for duplicate detection only.
        for _ in 1 .. 4:
          if c.i >= c.s.len or peek(c) notin HexDigits:
            raise newFactoryError(fecInvalidJson, "bad unicode escape", phase = "validate")
          result.add(peek(c))
          advance(c)
      else:
        raise newFactoryError(fecInvalidJson, "bad escape", phase = "validate")
    else:
      result.add(ch)

proc skipNumber(c: var ScanCtx) =
  skipWs(c)
  if peek(c) == '-': advance(c)
  if peek(c) == '0':
    advance(c)
  elif peek(c) in {'1'..'9'}:
    while peek(c) in {'0'..'9'}: advance(c)
  else:
    raise newFactoryError(fecInvalidJson, "bad number", phase = "validate")
  if peek(c) == '.':
    advance(c)
    if peek(c) notin {'0'..'9'}:
      raise newFactoryError(fecInvalidJson, "bad fraction", phase = "validate")
    while peek(c) in {'0'..'9'}: advance(c)
  if peek(c) in {'e', 'E'}:
    advance(c)
    if peek(c) in {'+', '-'}: advance(c)
    if peek(c) notin {'0'..'9'}:
      raise newFactoryError(fecInvalidJson, "bad exponent", phase = "validate")
    while peek(c) in {'0'..'9'}: advance(c)

proc skipValue(c: var ScanCtx)

proc skipObject(c: var ScanCtx) =
  expectChar(c, '{')
  skipWs(c)
  var seen = initTable[string, bool]()
  if peek(c) == '}':
    advance(c)
    return
  while true:
    skipWs(c)
    let key = parseStringRaw(c)
    if key in seen:
      raise newFactoryError(fecDuplicateKey,
        "duplicate key: " & key, phase = "validate")
    seen[key] = true
    expectChar(c, ':')
    skipValue(c)
    skipWs(c)
    if peek(c) == ',':
      advance(c)
      continue
    elif peek(c) == '}':
      advance(c)
      return
    else:
      raise newFactoryError(fecInvalidJson, "expected , or }", phase = "validate")

proc skipArray(c: var ScanCtx) =
  expectChar(c, '[')
  skipWs(c)
  if peek(c) == ']':
    advance(c)
    return
  while true:
    skipValue(c)
    skipWs(c)
    if peek(c) == ',':
      advance(c)
      continue
    elif peek(c) == ']':
      advance(c)
      return
    else:
      raise newFactoryError(fecInvalidJson, "expected , or ]", phase = "validate")

proc skipValue(c: var ScanCtx) =
  skipWs(c)
  case peek(c)
  of '{': skipObject(c)
  of '[': skipArray(c)
  of '"': discard parseStringRaw(c)
  of '-', '0'..'9': skipNumber(c)
  of 't':
    for ch in "true":
      if peek(c) != ch:
        raise newFactoryError(fecInvalidJson, "expected true", phase = "validate")
      advance(c)
  of 'f':
    for ch in "false":
      if peek(c) != ch:
        raise newFactoryError(fecInvalidJson, "expected false", phase = "validate")
      advance(c)
  of 'n':
    for ch in "null":
      if peek(c) != ch:
        raise newFactoryError(fecInvalidJson, "expected null", phase = "validate")
      advance(c)
  else:
    raise newFactoryError(fecInvalidJson, "unexpected token", phase = "validate")

proc rejectDuplicateKeys*(raw: string) =
  var c = ScanCtx(s: raw, i: 0)
  skipValue(c)
  skipWs(c)
  if c.i != c.s.len:
    raise newFactoryError(fecInvalidJson, "trailing data after JSON", phase = "validate")

proc parseJsonStrict*(raw: string): JsonNode =
  rejectDuplicateKeys(raw)
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

proc requireField*(node: JsonNode; field: string; kinds: set[JsonNodeKind];
                   path = "") =
  let p = if path.len == 0: field else: path & "." & field
  if not node.hasKey(field):
    raise newFactoryError(fecMissingRequiredInput,
      "missing field: " & p, phase = "validate")
  if node[field].kind notin kinds:
    raise newFactoryError(fecValidationFailed,
      "wrong type for " & p, phase = "validate")

proc rejectUnknownKeys*(node: JsonNode; allowed: openArray[string]; path = "$") =
  var ok = initTable[string, bool]()
  for k in allowed: ok[k] = true
  for k, _ in node.pairs:
    if k notin ok:
      raise newFactoryError(fecValidationFailed,
        "unexpected field " & path & "." & k, phase = "validate")

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
