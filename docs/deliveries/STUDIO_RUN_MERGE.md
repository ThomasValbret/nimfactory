# Livraison — merge Studio workflow + auto-revise

Date : 2026-11-22  
Branche dédiée : `feature/studio-run-merge`  
Worktree : `/opt/nimFactory-studio-merge`

| Source | SHA |
| --- | --- |
| Studio workflow ops | `fe5b28d` |
| Project-run auto-revise + QA | `dedbe62` |
| **Merge testé** | `6995e8eafc05878bd7425d8b0dd705363d4149d3` |

## Préservé

- **Pause après étape** (`pauseAfterStep` / commande Studio `pause_after_step`)
- **Révision automatique** (`maxAutoRevises` / intervention `revise:auto`)
- Rejeu `command_id` (historique vs nouveaux appels)
- Consultation GET `/api/snapshot` pendant worker

## Vérifications d’interaction

| Cas | Résultat |
| --- | --- |
| Pause puis reprise | `paused_after_step` → reprise exécute l’étape suivante |
| Sortie non vide incorrecte | `verify_failed` · `csv_mismatch,comma_not_quoted` · contrôle `export-csv` « sortie non vide mais incorrecte » · `engine_verdict.output_incorrect=true` |
| Rejeu `pause-merge-1` | `replayed=true` · hist provider 2 · new 0 |
| Consultation pendant travail | poll snapshot avec `run_lease=active` / `worker_active` |
| Régressions project-run | ALL passed (lease, auto-revise, comment_only, inject…) |

## Verdicts moteur (UI)

Bandeau Situation + inspecteur exposent `workflow.engine_verdict` (`last_verdict`, proposition, `output_incorrect`).

## Nouveau projet → demande → aperçu local

- Snapshot bootstrap (`bootstrap=true`, commande `ask_plan`)
- POST `/api/command` `ask_plan` → plan v1 + `preview.steps` **sans** exécuter d’étapes
- Retransmission : `replayed=true`, new=0

Démo observée : projet `carnet_prets`, plan 2 étapes (`wire_loan_create`, `wire_loan_repay`).

## Recette carnet de prêts (Python/SQLite)

`fixtures/loan_notebook/`

| Rôle | Artefact |
| --- | --- |
| Squelette | `skeleton/app.py` + `schema.sql` |
| Builder | `builder/inject/` (+ `mark_returned` appliqué pour oracle) |
| Oracle | `oracle/verify_studio_change.py` — redémarre serveur, vérifie `/loans/{id}/return`, lit Studio |

Oracle : **ok** (server_starts, create/list, studio_reachable, restart, mark_returned).

## Routes — résultats séparés

### Inject (merge)

Commande :

```bash
build/nimfactory project run \
  --store … --cwd fixtures/demo_tasks_cli \
  --objective "Je veux pouvoir exporter mes tâches." \
  --refinement "…CSV…" \
  --route inject --inject-dir fixtures/demo_tasks_cli/inject
```

| | |
| --- | --- |
| Verdict | **done** |
| Interventions | ask → revise → add_csv_helpers → wire_export_csv |
| API | **0** · USD **0** |

### Réelle / API (merge)

```bash
NF_PROJECT_ROUTE=api bash scripts/e2e_project_run.sh
```

Archive : `docs/qa/project_run/20261122T235008Z_api`

| | |
| --- | --- |
| Verdict | **verify_failed** (`compile failed`) |
| Interventions | ask → revise → step:1 |
| Auto-revise | non déclenchée (échec compile, pas exhaustion) |
| API | **3** · ~**$0.0010** |

Référence antérieure `dedbe62` (`20261122T211734Z_api`) : ask → revise → recovery_exhausted → **revise:auto** → verify_failed compile · 6 appels · ~$0.0021.

## Commande VPS

```bash
export PATH="/root/.nimble/bin:$PATH"
cd /opt/nimFactory-studio-merge   # worktree feature/studio-run-merge

nim e scripts/build_studio.nims
nim c -d:release -d:ssl --hints:off --nimcache:build/nimcache_cli \
  --path:src --path:/opt/NimAgentLibrary/src \
  -o:build/nimfactory src/nimfactory_cli.nim

# Nouveau projet (aperçu local)
DEMO=/opt/nimFactory-studio-merge-demo
mkdir -p "$DEMO/artifacts/trees"
build/nimfactory-studio \
  --store "$DEMO/new.sqlite" \
  --project-id carnet_prets \
  --cwd fixtures/loan_notebook \
  --route inject \
  --inject-dir fixtures/loan_notebook/builder/inject \
  --artifact-dir "$DEMO/artifacts" \
  --port 18086

# Workflow ops (pause / reprise) — port 18085 si libre
# Oracle carnet
STUDIO_URL=http://127.0.0.1:18086 LOAN_PORT=18181 \
  python3 fixtures/loan_notebook/oracle/verify_studio_change.py
```

## Tests

```bash
nim c -r --path:src --path:/opt/NimAgentLibrary/src \
  tests/project/test_project_run_regressions.nim
nim c -r --path:src --path:/opt/NimAgentLibrary/src \
  tests/studio/test_project_view.nim
nim c -r --path:src --path:/opt/NimAgentLibrary/src \
  tests/studio/test_project_command.nim
```
