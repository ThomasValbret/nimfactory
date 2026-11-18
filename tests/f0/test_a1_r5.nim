## A1-R5 regressions: unicode keys, surrogate pairs, nested typed fields.
import std/json
import nimfactory

proc expectCode(body: proc (); code: FactoryErrorCode) =
  var raised = false
  try: body()
  except FactoryError as e:
    raised = true
    doAssert e.code == code, $e.code & " vs " & $code & ": " & e.msg
  doAssert raised

block unicodeEscapeDuplicateRejected:
  expectCode(proc () =
    discard parseJsonStrict("""{"epoch":1,"\u0065poch":2}"""), fecDuplicateKey)

block distinctUnicodeAndLiteralKeysAccepted:
  let n = parseJsonStrict("""{"\u0065":1,"0065":2}""")
  doAssert n.len == 2
  doAssert n["e"].getInt == 1
  doAssert n["0065"].getInt == 2

block surrogatePairDuplicateRejected:
  expectCode(proc () =
    discard parseJsonStrict("""{"😀":1,"\uD83D\uDE00":2}"""), fecDuplicateKey)

block singleSurrogatePairAccepted:
  let n = parseJsonStrict("""{"\uD83D\uDE00":1}""")
  doAssert n.hasKey("😀")
  doAssert n["😀"].getInt == 1

block nestedSurrogatePairDuplicateRejected:
  expectCode(proc () =
    discard parseJsonStrict("""{"outer":{"😀":1,"\uD83D\uDE00":2}}"""),
      fecDuplicateKey)

block needRequiredWrongTypeRejected:
  expectCode(proc () =
    discard resultFromJson(%*{
      "schema": ResultSchema,
      "status": "blocked",
      "outputs": {},
      "needs": [{"id": "n1", "target": "c", "selector": "s",
                 "required": "true", "reason": "x"}],
      "diagnostics": []
    }), fecValidationFailed)

block diagnosticWrongTypesRejected:
  expectCode(proc () =
    discard resultFromJson(%*{
      "schema": ResultSchema,
      "status": "ok",
      "outputs": {},
      "needs": [],
      "diagnostics": [{"code": 123, "phase": [], "message": false}]
    }), fecValidationFailed)

block errorRetryableWrongTypeRejected:
  expectCode(proc () =
    discard resultFromJson(%*{
      "schema": ResultSchema,
      "status": "failed",
      "outputs": {},
      "needs": [],
      "diagnostics": [],
      "error": {"code": "x", "phase": "p", "retryable": "true", "reason": "r"}
    }), fecValidationFailed)

echo "test_a1_r5: ok"
