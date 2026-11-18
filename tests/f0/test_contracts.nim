import std/[os, json, strutils]
import nimfactory
import nimagent/messages

proc fixtureDir(): string =
  if dirExists("tests/fixtures/contracts"):
    return "tests/fixtures/contracts"
  if dirExists(getAppDir() / ".." / "fixtures" / "contracts"):
    return getAppDir() / ".." / "fixtures" / "contracts"
  "tests/fixtures/contracts"

proc readFixture(name: string): string =
  readFile(fixtureDir() / name)

block metaOk:
  let m = metaFromJson(parseJson(readFixture("meta_ok.json")))
  doAssert m.messageId == "msg-001"
  doAssert m.causationIsNull
  let again = metaFromJson(metaToJson(m))
  doAssert again.messageId == m.messageId
  doAssert again.causationIsNull

block metaBadSchema:
  var raised = false
  try:
    discard metaFromJson(parseJson(readFixture("meta_bad_schema.json")))
  except FactoryError as e:
    raised = true
    doAssert e.code == fecSchemaMismatch
  doAssert raised

block metaUnknownFeature:
  var raised = false
  try:
    discard metaFromJson(parseJson(readFixture("meta_unknown_feature.json")))
  except FactoryError as e:
    raised = true
    doAssert e.code == fecUnknownRequiredFeature
  doAssert raised

block resultRoundtrip:
  var r = defaultResult(rsBlocked)
  r.needs.add(NeedItem(id: "n1", chamberOrSource: "ch-1", selector: "x",
                       required: true, reason: "missing"))
  r.readSetRef = "art-rs-1"
  r.errorCode = $fecMissingRequiredInput
  r.errorPhase = "prepare"
  r.errorReason = "need input"
  let j = resultToJson(r)
  let back = resultFromJson(j)
  doAssert back.status == rsBlocked
  doAssert back.needs.len == 1
  doAssert back.readSetRef == "art-rs-1"

block idsDistinct:
  let a = artifactRef("art-1")
  let h = handlerRef("prompt.prepare@0.1")
  doAssert $a == "art-1"
  doAssert $h == "prompt.prepare@0.1"

block stubArtifact:
  let store = newMemoryArtifactStore()
  let p1 = store.put("hello", "text/plain", "origin-a")
  let p2 = store.put("hello", "text/plain", "origin-b")
  doAssert $p1.id == $p2.id
  doAssert store.describe(p1.id).origin.contains("origin-a")
  doAssert store.describe(p1.id).origin.contains("origin-b")
  doAssert store.read(p1.id) == "hello"

echo "test_contracts: ok"
