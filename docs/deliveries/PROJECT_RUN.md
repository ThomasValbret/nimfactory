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

Couvert : archive 3 ancres `demo_tasks` + 1 `tasks.nim` (`found_in_file`), postconditions exécutables + contrainte stdout, helper puis wire sur arbre accepté, `insertLineAfter` hors corps de proc, coercition prose→tokens, conservation du blocage et du dernier arbre accepté après `revise_equivalent`.

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

Le résumé historique enregistre ces sorties. Le script de l’époque pouvait aussi sélectionner un binaire de travail. Le chemin réellement exécuté ne figure pas dans ce reçu.

| Usage | Exit | Sortie (extrait) |
| --- | --- | --- |
| (sans argument) | 0 | list inchangé |
| `list` | 0 | list inchangé |
| `export-csv` | 0 | `id,title` + `"Appeler Alice, Bob"` quoté |

## Correction du 24 novembre 2026

Le mécanisme d’injection implicite de la campagne historique a été retiré. Une révision équivalente renvoie son motif et conserve les étapes acceptées. Les rejeux explicites restent disponibles. Un plan avec une étape bloquée ne peut plus aboutir par simple relance.

La recette CSV recalcule l’empreinte du répertoire livré et compile ses sources dans un répertoire temporaire. Elle contrôle les trois usages à partir des données de référence de la fixture. Le résumé distingue le verdict moteur (`engine_ok`) de la qualification (`ok`, `delivery_check`). Un verdict favorable du moteur avec un arbre absent, périmé ou incorrect fait échouer la recette.

Vérifications hors ligne avec Nim 2.4.0 et le SDK épinglé. La suite `tests/project/test_project_run_regressions.nim` couvre aussi un ancien mandat qui demandait un patch implicite et la conservation du préfixe accepté après révision équivalente. La commande `NF_PROJECT_ROUTE=inject bash scripts/e2e_project_run.sh` exerce la livraison CSV. Aucune nouvelle campagne API pour ce correctif.
