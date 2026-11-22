# Project run — commande unique vers l’export

Date : 2026-11-22  
Branche : `feature/project-run`  
**SHA exécuté** : `1076ccd4d0b8e247b7e6c7b273c6dd346d809893`

## Commande unique

```bash
nimfactory project run \
  --store PATH --project-id demo_tasks_cli \
  --cwd fixtures/demo_tasks_cli \
  --objective "Je veux pouvoir exporter mes tâches." \
  --refinement "Je veux du CSV sur la sortie standard et je veux garder l'affichage actuel par défaut." \
  --route api
```

(Inject de qualification : ajouter `--route inject --inject-dir fixtures/demo_tasks_cli/inject`.)

## Changements livrés (depuis `affe5d4`)

- Rejeu des 3 sorties archivées (`archive_api_raw_parse_error`, `archive_api_raw_empty_oldtext`, sticky engine)
- JSON illisible → récupération bornée ; `insertBefore` / `insertAfter` sur ancre unique vérifiée
- Après épuisement, `run` demande une révision motivée (`revise:auto`) ; révision équivalente → motif conservé
- Critères rattachés à la recette + objectif d’étape ; commentaire seul échoue si export promis ; preuve compile+list ne couvre pas un export ajouté
- Comptage `ask` corrigé (`provider_calls` / `api_calls`)
- Mutex run↔step (lease + owner vivant) ; issue fournisseur `unknown` visible après interruption

## Qualification inject (binaire livré)

`docs/qa/project_run/20261122T211836Z_inject` — verdict **done**

| Usage | Résultat |
| --- | --- |
| (sans argument) | liste intacte |
| `list` | liste intacte |
| `export-csv` | `id,title` + `"Appeler Alice, Bob"` |

Appels API : 0 · USD : 0

## Campagne route réelle (API)

`docs/qa/project_run/20261122T211734Z_api` — **blocage** `verify_failed` (compile) après auto-revise

### Appels par rôle

| Rôle | Appels | USD est. |
| --- | --- | --- |
| planner | 1 | 0.000291 |
| reviser | 2 | 0.000898 |
| implementer | 2 | 0.000562 |
| implementer_recovery | 1 | 0.000330 |
| **total** | **6** | **~$0.0021** |

### Première sortie fautive / décision moteur

- Première faute : `recovery_exhausted` (`anchor_missing` après recovery) — raw conservé dans `first_faulty.txt`
- Décision moteur : `revise:auto` → plan v3 → step 1 appliqué → `verify_failed` (compile `undeclared identifier: 'cmd'`)
- Ask compté : **api_calls=1**

## Tests

```bash
nim c -r --path:src --path:vendor/NimAgentLibrary/src \
  tests/project/test_project_run_regressions.nim
```
