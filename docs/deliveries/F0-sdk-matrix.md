# F0 — Matrice besoin factory → API NimAgent

SDK inspecté : `/opt/NimAgentLibrary` @ `bf22665ece77d7149dbe61df959a6024bf6b26f3`

| Besoin factory | API existante | Chemin / symbole | Adaptation ou manque |
| --- | --- | --- | --- |
| Message unifié | `Message`, `Role`, `ToolCall`, `TokenUsage` | `src/nimagent/messages.nim` | Réutilisé tel quel en mémoire |
| Codec JSON Message | `messageToJson` / `messageFromJson` | `src/nimagent/memory/session.nim` | **Adaptation** : codec factory conserve `finishReason`, `cacheTokens`, `reasoningTokens`, `isReported` |
| Constructeurs Message | `systemMsg`, `userMsg`, `assistantMsg`, `toolMsg` | `messages.nim` | Réutilisés |
| Agent | `newAgent`, `run`, `runSync`, `runResult`, `runStream`, `runStructured` | `agent.nim`, `core/execution.nim` | Pas d’appel dans F0 ; port futur F13 |
| Résultat run | `RunResult`, `RunStatus` | `core/run_result.nim` | Mapping ultérieur vers `CommonResult` si besoin |
| Outils | `ToolRegistry`, `llmTool`, `callTool`, `agentTool` | `tools/registry.nim`, `tools/macros.nim` | Port ToolCatalog (lots F6/F9) |
| Erreurs | `ErrorKind`, erreurs runtime | `runtime/errors.nim` | Factory a ses codes transversaux ; pas de duplication SDK |
| Usage / coûts | `TokenUsage` ; opt-in `usage_costs` | `messages.nim`, `runtime/usage_costs.nim` | F14 compte ; broker unique réservateur |
| Journal | `ExecutionJournal`, `JournalEventKind` | `runtime/journal.nim` | F3 peut réutiliser ou SQLite derrière `RunStore` |
| Stockage | `MemoryStorageBackend`, `FileStorageBackend` | `storage/backend.nim` | Distinct de ArtifactStore F1 |
| Artefacts SDK | module `storage/artifacts` | export barrel | Ne remplace pas ArtifactStore factory |
| Async | `Future`/`async`/`await` via `async_compat` | `utils/async_compat.nim` | F5 suivra ce modèle ; pas de 2e boucle |
| Annulation | `stopRuntime` ; `rsSuspended` | `core/runtime.nim`, `run_result` | **Manque** : cancel générique d’un `run` ; documenté |
| JSON DOM | `json_compat` / `std/json` | `utils/json_compat.nim` | F0 utilise `std/json` |
| Validation schéma | `validation/json_schema` | module validation | Disponible ; F0 valide aussi en Nim dédié |

## Compilation documentée
```
export PATH="/root/.nimble/bin:$PATH"
cd /opt/nimFactory
nim c -r --path:src --path:/opt/NimAgentLibrary/src tests/f0/test_contracts.nim
```
