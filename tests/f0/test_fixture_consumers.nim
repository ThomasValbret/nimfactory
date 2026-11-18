## Two independent consumers must read fixtures identically.
import std/[os, json]
import nimfactory

proc fixtureDir(): string =
  if dirExists("tests/fixtures/contracts"):
    return "tests/fixtures/contracts"
  if dirExists(getAppDir() / ".." / "fixtures" / "contracts"):
    return getAppDir() / ".." / "fixtures" / "contracts"
  "tests/fixtures/contracts"

proc consumerA(path: string): FactoryEnvelope =
  envelopeFromJson(parseJson(readFile(path)))

proc consumerB(path: string): FactoryEnvelope =
  # Independent parse path (re-parse string)
  let raw = readFile(path)
  let node = parseJson(raw)
  envelopeFromJson(node)

proc assertSame(a, b: FactoryEnvelope) =
  doAssert a.factory.messageId == b.factory.messageId
  doAssert a.factory.attemptId == b.factory.attemptId
  doAssert a.factory.isRetransmission == b.factory.isRetransmission
  doAssert a.factory.causationIsNull == b.factory.causationIsNull
  assertMessageEqual(a.message, b.message, "consumers: ")

for name in ["envelope_accents.json", "envelope_retransmit.json",
             "envelope_new_attempt.json"]:
  let path = fixtureDir() / name
  let a = consumerA(path)
  let b = consumerB(path)
  assertSame(a, b)

echo "test_fixture_consumers: ok"
