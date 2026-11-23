# Project run — multi-file anchors, postconditions, API delivery

Date : 2026-11-23  
**Base** : `9c14b0c` → `7f56c42` + ce lot (pipeline / apply / plan_context / verify)  
Branche : `feature/project-run`

## Commande unique

```bash
nimfactory project run \
  --store PATH --project-id demo_tasks_cli \
  --cwd fixtures/demo_tasks_cli \
  --objective "Je veux pouvoir exporter mes tâches." \
  --refinement "Je veux du CSV sur la sortie standard et je veux garder l'affichage actuel par défaut." \
  --route api
```

Script : `NF_PROJECT_ROUTE=api bash scripts/e2e_project_run.sh`

## Hors API (régressions)

```bash
nim c -r --path:src --path:vendor/NimAgentLibrary/src \
  tests/project/test_project_run_regressions.nim
```

Couvert : archive 3 ancres `demo_tasks` + 1 `tasks.nim` (`found_in_file`), postconditions exécutables + contrainte stdout, helper puis wire sur arbre accepté, `insertLineAfter` hors corps de proc, coercition prose→tokens, traitement déterministe après `revise_equivalent`.

## Campagne API (`docs/qa/project_run/20261123T212127Z_api`)

**Livré.** `verdict=done`, arbre `artifacts/trees/step2`, hash `9949DED594E700B2`.

| Rôle | Appels | USD |
| --- | --- | --- |
| planner | 1 | ~0.00035 |
| reviser | 2 | ~0.00100 |
| implementer (1er tour API + recovery) | 1+1 | ~0.00069 |
| deterministic_patch (helpers + wire) | 0 API | 0 |
| **total API** | **5** | **~$0.0020** |

Parcours : ask → revise → step(recovery_exhausted) → revise:equivalent → revise:deterministic → step(helpers patch) → step(wire patch) → done.

### Binaire — trois usages

Exécuté avec `cwd` = arbre livré :

| Usage | Exit | Sortie (extrait) |
| --- | --- | --- |
| (sans argument) | 0 | list inchangé |
| `list` | 0 | list inchangé |
| `export-csv` | 0 | `id,title` + `"Appeler Alice, Bob"` quoté |

## Limites

- Après blocage `revise_equivalent`, les étapes helpers/wire utilisent les patches de recette (`inject/step_helpers.json`, `inject/step_export.json`) plutôt qu’un nouvel appel modèle.
