# Project run — line insert, compile repair, final vs postconditions

Date : 2026-11-22  
**SHA exécuté** : `8f91314de9a40fe6c339dc9e46ecd527ac3fc7e8`  
Branche : `feature/project-run` (depuis `dedbe62`)

## Commande unique

```bash
nimfactory project run \
  --store PATH --project-id demo_tasks_cli \
  --cwd fixtures/demo_tasks_cli \
  --objective "Je veux pouvoir exporter mes tâches." \
  --refinement "Je veux du CSV sur la sortie standard et je veux garder l'affichage actuel par défaut." \
  --route api
```

## Hors API

- Reproduction : `insertAfter` textuel colle `"list"if` (`archive_api_glue_list_if_first.json`)
- Contrat : `insertBefore`/`insertAfter` (textuel, legacy) vs `insertLineBefore`/`insertLineAfter` (nouvelle ligne)
- Réparation post-compile : candidat rejeté + diff + diagnostic localisé (Nim / gcc-like)
- Plan : `final_criteria` vs `postconditions` par étape
- Révision motivée : fingerprint/postconditions changent le traitement du blocage

```bash
nim c -r --path:src --path:vendor/NimAgentLibrary/src \
  tests/project/test_project_run_regressions.nim
```

## Campagne API (`docs/qa/project_run/20261122T230713Z_api`)

**Pas de binaire livré.** Première décision bloquante : `revise_plan_needed`.

| Rôle | Appels | USD |
| --- | --- | --- |
| planner | 1 | 0.000422 |
| reviser | 2 | 0.001206 |
| implementer | 2 | 0.000610 |
| implementer_recovery | 2 | 0.000538 |
| **total** | **7** | **~$0.0028** |

Parcours : ask → revise → step(`revise_plan`, recovery) → `revise:auto` → step(`revise_plan` encore).  
`maxAutoRevises=1` → arrêt. Première sortie fautive : `first_faulty.txt` (déjà `insertLine*`).
