## Constant-output fake preparer — must fail discriminating oracles (Wave A smoke only).

import std/[json, os]
import types

proc loadFakeConstantObservation*(): QualObservation =
  let path = fixturesDir() / "fake_constant_observation.json"
  observationFromJson(parseFile(path))