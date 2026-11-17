import std/os
import nimfactory
echo "version=", factoryVersion()
echo "nimagent=", NimAgentPinnedDescribe
let reg = newSimulatedHandlerRegistry()
registerSeedBasicHandlers(reg)
let store = newDirectoryArtifactStore(getTempDir() / "nf-facade-smoke")
let put = store.put("facade", "text/plain", "smoke")
echo "artifact=", put.id
echo "wave_a_facade: ok"
