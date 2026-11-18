import std/[os, json]
import nimfactory
echo "version=", factoryVersion()
echo "sdk_pin=", NimAgentPinnedRevision
# F0 strict
var raised = false
try:
  discard metaFromJson(%*{"schema": MetaSchema})
except FactoryError:
  raised = true
doAssert raised
# F1 + F4 smoke
let store = newDirectoryArtifactStore(getTempDir() / "nf-a1-facade")
discard store.put("a1", "text/plain", "facade")
let reg = newSimulatedHandlerRegistry()
registerSeedBasicHandlers(reg)
echo "wave_a1_facade: ok"
