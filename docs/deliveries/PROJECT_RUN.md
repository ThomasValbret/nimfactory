# Project run — première commande pilote

Date : 2026-11-22  
Branche : `feature/project-run` (worktree depuis `655f7ea`)  
**SHA du code exécuté** : `4d2c68410c92ff5fcd3a1a73ca616b03f5ebc495`

## Commande utilisateur

```bash
nimfactory project run \
  --store PATH --project-id demo_tasks_cli \
  --cwd fixtures/demo_tasks_cli \
  --objective "Je veux pouvoir exporter mes tâches." \
  --refinement "Je veux du CSV sur la sortie standard et je veux garder l'affichage actuel par défaut." \
  --route inject --inject-dir fixtures/demo_tasks_cli/inject \
  --artifact-dir ART --worktree WT
```

Route API : même commande sans `--inject-dir`, `--route api` (clé requise).

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

Chaque étape porte `criteria` (plan ou inférence). L'oracle `verifyStepCriteria` applique `export_command` même hors dernière étape. Après `project revise`, une preuve `done` n'est conservée que si `proofCoversCriteria` et si les dépendances restent `done` ; sinon elle est droppée (`proof_kept` / `proof_dropped`).

## Qualification archives (inject)

`docs/qa/project_run/20261122T210117Z_inject`

- Verdict : **done**
- Interventions : ask → revise → step:add_csv_helpers → step:wire_export_csv
- Binaire observé (`worktrees/step_wire_export_csv/build/demo_tasks`) :
  - `demo_tasks` / `list` → liste intacte
  - `export-csv` → `id,title` + titre à virgule quoté
- Appels API : **0** · coût : **$0**

## Route réelle (API)

`docs/qa/project_run/20261122T210153Z_api`

- Blocage : **HTTP 401** `expired_secret_key` (clé OpenAI expirée)
- Aucune dépense facturable ; walk modèle non qualifié sur cette passe
- Offline inject reste la preuve de bout en bout jusqu'au binaire

## Dépenses

| Campagne | Appels | Jetons | USD |
| --- | --- | --- | --- |
| inject archive | 0 | 0 | 0 |
| api attempt | 0 completed | — | 0 |

## Fichiers

- `src/nimfactory/project/{pipeline,store,types,verify}.nim`
- `src/nimfactory/cli/cli.nim` — sous-commande `run`
- `scripts/e2e_project_run.sh`
- `tests/project/test_project_run_regressions.nim`
