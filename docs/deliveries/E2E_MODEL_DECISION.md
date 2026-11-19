# Delivery — E2E model decision (software_fix)

**Branch:** `feature/e2e-model-decision`  
**Base:** `4de8a3d` (Wave B M1 tip; resume fixes remain on PR #2)  
**Tested SHA:** `79f8896ed80dd0458618b6657caab340fd34da0a`  
**PR #3 read:** decision — role selects model/route; API scenarios use planned API; if unavailable, receipt names cause + untested functions; local missions use dedicated context constructors.

## Mission

From the CLI (`mission-fix`), build context from a small buggy repo, call the model for the `software_fix` role, apply the returned patch in an isolated worktree, and run reception tests that are **never** part of the model context.

Two fixture variants share the same symptom but different root causes in `src/normalize.nim` (empty-string bypass vs off-by-one single-char). `src/util_misc.nim` is a red herring.

## Branchement applicatif

| Étape | Composant | Chemin |
| --- | --- | --- |
| CLI | `mission-fix` | `src/nimfactory/cli/cli.nim` |
| Contexte API | `buildApiContext` | `src/nimfactory/mission/context.nim` |
| Contexte local (micro-patch) | `buildLocalMicroPatchContext` | idem (prompt dédié, pas un tronquage API) |
| Appel prévu API | `callPlannedApi` → NimAgent `newOpenAIProvider` / `gpt-4o-mini` | `src/nimfactory/mission/provider.nim` |
| Appel local | `callLocalMicroPatch` → NimAgent `newOllamaProvider` | idem |
| Parse + worktree | `parseFixDecision` / `applyDecision` | `src/nimfactory/mission/apply.nim` |
| Réception | `runOracle` | `src/nimfactory/mission/verify.nim` |
| Orchestration | `runMission` | `src/nimfactory/mission/pipeline.nim` |

Handlers M1 (`demo.*`) restent hors de ce parcours. Réutilisation NimAgent : `Message`/agent/`runSync`, providers OpenAI & Ollama.

## Planned API (Quentin)

**Cause observée:** `OPENAI_API_KEY` unset → `verdict=api_unavailable`, exit 3.  
**Fonctions non testées avec l’API prévue:** `callPlannedApi/live`, parse/apply/oracle sur sortie API.  
Trace: `docs/qa/e2e_model_decision/api_unavailable.json`.

Travail indépendant poursuivi : constructeurs de contexte, apply/verify, tests inject (non-qualifiants LLM), essais route locale.

## Essais réels (route locale micro-patch)

Commandes:

```bash
nim c -d:release --path:src --path:vendor/NimAgentLibrary/src -o:build/nimfactory src/nimfactory_cli.nim

./build/nimfactory mission-fix \
  --repo fixtures/e2e_bugfix/variant_a \
  --oracle fixtures/e2e_bugfix/oracle \
  --worktree /tmp/nf_wt_a --route local --local-model qwen2.5-coder:7b

./build/nimfactory mission-fix \
  --repo fixtures/e2e_bugfix/variant_b \
  --oracle fixtures/e2e_bugfix/oracle \
  --worktree /tmp/nf_wt_b --route local --local-model qwen2.5-coder:7b
```

| Variante | Modèle | Sources fournies | Décision observée | Diff / cible | Verdict | Coût |
| --- | --- | --- | --- | --- | --- | --- |
| A | ollama/`qwen2.5-coder:7b` | `src/normalize.nim`, `src/util_misc.nim` + symptom | cible `normalize.nim` (pas util_misc) | patch EMPTY pour `len==0 or strip empty` | **pass** | local; usage reported (prompt≈267, completion≈98); provider_cost=0 |
| B (1er essai, symptom moins explicite) | idem | idem | cible correcte, patch garde `len==1 → EMPTY` | apply ok, oracle fail sur `"x"` | **verify_failed** conservé | `docs/qa/.../local_variant_b_first_fail.json` |
| B (symptom clarifié: single char non-space inchangé) | idem | idem | cible `normalize.nim`; `len==1 → return t` | **pass** | local; prompt≈278+ | |

Attribution: contexte = `nimfactory.mission.context`; modèle = ollama; parse/apply = `mission.apply`; verify = `mission.verify` + oracle externe.

Ce que l’essai démontre: la différence A/B dans `normalize.nim` arrive au modèle via le constructeur de contexte produit; le modèle choisit le bon fichier; le correctif appliqué change le résultat des tests de réception. La route API prévue n’a pas pu qualifier la même décision.

## Tests déterministes (non-qualifiants LLM)

```bash
nim c -r --path:src --path:vendor/NimAgentLibrary/src tests/mission/test_context_and_inject.nim
```

Couvre: contextes A≠B sans oracle; inject pass A/B; mauvaise cible échoue; API absente → diagnostic Quentin.

Les tests M1 / reprise restent sur PR #2.

## Limites

- Qualification API `gpt-4o-mini` bloquée sans clé.
- Route locale = mission micro-patch dédiée (PR #3), pas un substitut silencieux de l’API pour le rôle distant.
- Premier échec B conservé pour montrer qu’un mauvais patch échoue vraiment à la réception.
