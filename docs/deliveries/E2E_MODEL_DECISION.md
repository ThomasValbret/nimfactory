# Delivery — E2E model decision (software_fix)

**Branch:** `feature/e2e-model-decision`  
**Base:** `4de8a3d` (Wave B M1 tip; resume fixes remain on PR #2)  
**Tested SHA:** _(tip after this docs commit)_  
**PR #3 read:** role selects model/route; API scenarios use planned API; local missions use dedicated context constructors.

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
Build API : `nim c -d:release -d:ssl …` (HTTPS requis pour OpenAI).

## Planned API — essais réels (budget ≤ 3 €)

Après fourniture d’une clé temporaire 24 h, binaire recompilé avec `-d:ssl`. Budget alloué 3 € ; dépense estimée ≪ 0,01 €.

Commandes:

```bash
nim c -d:release -d:ssl --path:src --path:vendor/NimAgentLibrary/src \
  -o:build/nimfactory src/nimfactory_cli.nim

./build/nimfactory mission-fix \
  --repo fixtures/e2e_bugfix/variant_a \
  --oracle fixtures/e2e_bugfix/oracle \
  --worktree /tmp/nf_wt_api_a --route api

./build/nimfactory mission-fix \
  --repo fixtures/e2e_bugfix/variant_b \
  --oracle fixtures/e2e_bugfix/oracle \
  --worktree /tmp/nf_wt_api_b --route api
```

| Variante | Modèle | Sources fournies | Décision observée | Diff / cible | Verdict | Tokens / coût |
| --- | --- | --- | --- | --- | --- | --- |
| A | openai/`gpt-4o-mini` | `src/normalize.nim`, `src/util_misc.nim` + symptom | « Fixes handling of empty and whitespace-only strings » → `normalize.nim` | `if s.strip.len == 0: return "EMPTY"` | **pass** | prompt 327 + completion 116 ; ≈ \$0.00012 |
| B | openai/`gpt-4o-mini` | idem | « fix off-by-one error in normalize function » → `normalize.nim` | retire le gate `t.len <= 1` ; `result = t` | **pass** | prompt 338 + completion 139 ; ≈ \$0.00013 |

Tarif utilisé pour l’estimation : gpt-4o-mini ≈ \$0.15 / 1M input + \$0.60 / 1M output. Total deux appels ≈ **\$0.00025** (≪ 3 €). Usage reporté par NimAgent ; `provider_cost_microusd` non câblé → coût estimé ci-dessus.

Traces : `docs/qa/e2e_model_decision/api_variant_a.json`, `api_variant_b.json`.

Attribution : contexte = `nimfactory.mission.context` ; modèle = OpenAI/`gpt-4o-mini` ; parse/apply = `mission.apply` ; verify = `mission.verify` + oracle externe.

**Ce que l’essai API démontre :** la différence A/B dans `normalize.nim` parvient au modèle prévu via `buildApiContext` ; dans chaque cas le modèle choisit `src/normalize.nim` (pas le red herring), produit un correctif distinct adapté à la cause, et l’oracle de réception passe après application en worktree isolé.

État antérieur (clé absente) conservé : `api_unavailable.json` + avertissement Quentin.

## Essais route locale (micro-patch, non substitut de l’API)

| Variante | Modèle | Verdict | Notes |
| --- | --- | --- | --- |
| A | ollama/`qwen2.5-coder:7b` | pass | `local_variant_a.json` |
| B (1er) | idem | verify_failed | patch incorrect conservé : `local_variant_b_first_fail.json` |
| B | idem | pass | `local_variant_b.json` |

## Tests déterministes (non-qualifiants LLM)

```bash
nim c -r --path:src --path:vendor/NimAgentLibrary/src tests/mission/test_context_and_inject.nim
```

Couvre: contextes A≠B sans oracle; inject pass A/B; mauvaise cible échoue; API absente → diagnostic.

Les tests M1 / reprise restent sur PR #2 (non fusionnée ici).

## Limites

- Clé API fournie pour la campagne : ne pas la committer ; rotation après 24 h recommandée.
- Coût fournisseur estimé à partir des tokens + tarif public ; ledger F14 non branché sur cette mission.
- Route locale reste une mission micro-patch dédiée (PR #3), distincte de la qualification API.
