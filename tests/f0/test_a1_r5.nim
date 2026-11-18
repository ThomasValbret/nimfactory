## A1-R5 regressions: unicode duplicate keys + nested need types.
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

echo "test_a1_r5: ok"
