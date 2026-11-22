# Project run — première commande pilote

Date : 2026-11-22  
Branche : `feature/project-run` (worktree depuis `655f7ea`)  
**SHA du code exécuté (run API)** : `123d5157e6e3363e13442da5829b21a1e4946576`  
**SHA fonctionnel (lease/criteria)** : `4d2c68410c92ff5fcd3a1a73ca616b03f5ebc495`

## Commande utilisateur

```bash
nimfactory project run \
  --store PATH --project-id demo_tasks_cli \
  --cwd fixtures/demo_tasks_cli \
  --objective "Je veux pouvoir exporter mes tâches." \
  --refinement "Je veux du CSV sur la sortie standard et je veux garder l'affichage actuel par défaut." \
  --route api
```

Inject (preuve binaire) : même commande avec `--route inject --inject-dir fixtures/demo_tasks_cli/inject`.

Clé : `scripts/lib_load_openai_key.sh` charge `nimFactory/.keys` (avant le fallback legacy `/opt/.keys`).

## Régressions conditionnant l'usage

| # | Exigence | Preuve |
| --- | --- | --- |
| 1 | Deux départs simultanés → une seule tentative fournisseur | `claimProjectRunLease` ; second `project run` → `already_running`, 0 appel |
| 2 | Récupération épuisée survit au redémarrage → décision différente | `recovery_exhausted` + `revise_plan_pending` ; status/resume=`revise` ; step 0 appel |
| 3 | Commentaire seul échoue si l'étape promet une commande d'export | critères `export_command` ; `step_comment_only.json` → `verify_failed` |

```bash
nim c -r --path:src --path:vendor/NimAgentLibrary/src \
  tests/project/test_project_run_regressions.nim
```

## Critères et preuves après revise

Chaque étape porte `criteria`. L'oracle `verifyStepCriteria` applique `export_command` même hors dernière étape. Après `project revise`, une preuve `done` n'est conservée que si `proofCoversCriteria` et si les dépendances restent `done`.

## Qualification archives (inject)

`docs/qa/project_run/20261122T210117Z_inject`

- Verdict : **done**
- Interventions : ask → revise → step:add_csv_helpers → step:wire_export_csv
- Binaire :
  - `demo_tasks` / `list` → liste intacte
  - `export-csv` → `id,title` + titre à virgule quoté
- Appels API : **0** · coût : **$0**

## Route réelle (API) — clé `nimFactory/.keys`

`docs/qa/project_run/20261122T210420Z_api`

| Phase | Verdict | Détail |
| --- | --- | --- |
| `project run` | `apply_failed` | step 1 : `parse_error` (JSON modèle illisible) |
| `project step` retry | `recovery_exhausted` | `empty_or_missing_oldText` → recovery → même refus |
| status / resume | `revise` | sticky |
| step après épuisement | `revise_plan_needed` | **0** appel fournisseur |

Blocage explicable : décisions modèle non applicables sur la route réelle ; le pilote s'arrête sur revise sticky. Le parcours inject reste la preuve jusqu'au binaire.

## Dépenses

| Campagne | Appels (rôles) | USD estimé |
| --- | --- | --- |
| inject archive | 0 | 0 |
| api (ask/revise/step + retry + recovery) | 5 | **~$0.0017** |
| sticky step après épuisement | 0 | 0 |

## Fichiers

- `src/nimfactory/project/{pipeline,store,types,verify}.nim`
- `src/nimfactory/cli/cli.nim` — sous-commande `run`
- `scripts/{e2e_project_run,lib_load_openai_key}.sh`
- `tests/project/test_project_run_regressions.nim`
