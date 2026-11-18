## A.1 — F0 negative fixtures: missing fields, wrong types, duplicates, unknowns.
import std/[json, os]
import nimfactory

proc expectCode(body: proc (); code: FactoryErrorCode) =
  var raised = false
  try:
    body()
  except FactoryError as e:
    raised = true
    doAssert e.code == code, $e.code & " vs " & $code & ": " & e.msg
  doAssert raised

block metaOnlySchemaRejected:
  expectCode(proc () = discard metaFromJson(%*{"schema": MetaSchema}),
             fecMissingRequiredInput)

block metaEmptyIdsRejected:
  expectCode(proc () =
    discard metaFromJson(%*{
      "schema": MetaSchema,
      "message_id": "",
      "run_id": "run-1",
      "activation_id": "act-1",
      "attempt_id": "try-1",
      "epoch": 1,
      "correlation_id": "c",
      "causation_id": nil,
      "payload_schema": ResultSchema,
      "extensions": {}
    }), fecMissingRequiredInput)

block metaUnknownFieldRejected:
  expectCode(proc () =
    discard metaFromJson(%*{
      "schema": MetaSchema,
      "message_id": "m",
      "run_id": "r",
      "activation_id": "a",
      "attempt_id": "t",
      "epoch": 1,
      "correlation_id": "c",
      "causation_id": nil,
      "payload_schema": ResultSchema,
      "extensions": {},
      "telepathy": true
    }), fecValidationFailed)

block resultMissingStatusNotOk:
  expectCode(proc () =
    discard resultFromJson(%*{
      "schema": ResultSchema,
      "outputs": {},
      "needs": [],
      "diagnostics": []
    }), fecMissingRequiredInput)

block resultOutputsWrongType:
  expectCode(proc () =
    discard resultFromJson(%*{
      "schema": ResultSchema,
      "status": "ok",
      "outputs": 17,
      "needs": [],
      "diagnostics": []
    }), fecValidationFailed)

block resultUnknownFeatureField:
  expectCode(proc () =
    discard resultFromJson(%*{
      "schema": ResultSchema,
      "status": "ok",
      "outputs": {},
      "needs": [],
      "diagnostics": [],
      "required_features": ["telepathy"]
    }), fecValidationFailed)

block duplicateKeysRejected:
  expectCode(proc () =
    discard parseJsonStrict("""{"epoch":1,"epoch":2}"""), fecDuplicateKey)

block nestedDuplicateKeysRejected:
  expectCode(proc () =
    discard parseJsonStrict("""{"a":{"x":1,"x":2}}"""), fecDuplicateKey)

block validMetaStillOk:
  let m = metaFromJson(parseJsonStrict("""{
    "schema": "nimfactory.meta/0.1",
    "message_id": "msg-001",
    "run_id": "run-001",
    "activation_id": "act-001",
    "attempt_id": "try-001",
    "epoch": 1,
    "correlation_id": "prep-001",
    "causation_id": null,
    "payload_schema": "nimfactory.result/0.1",
    "extensions": {},
    "is_retransmission": false
  }"""))
  doAssert m.messageId == "msg-001"
  doAssert m.causationIsNull

echo "test_validation_strict: ok"
