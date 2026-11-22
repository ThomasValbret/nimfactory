# Recette VPS — parcours projet CLI (arbres chaînés + reprise)

## Base

| Champ | Valeur |
| --- | --- |
| Branche | `feature/project-cli-journey` |
| Fixture | `fixtures/demo_tasks_cli/` (+ `recipe.json` → `verify=csv_journey`) |
| Store | SQLite `nf_runs.state_json` + `nf_events` (`run_id=project:<id>`) |
| Modèle | `gpt-4o-mini` (roles `planner` / `reviser` / `implementer`) |

## Prérequis

```bash
cd /opt/nimFactory
export PATH="/root/.nimble/bin:${PATH:-}"
# Clé: env → .keys (gitignoré) → /opt/.keys
# Hors API (déterministe):
NF_PROJECT_ROUTE=inject bash scripts/e2e_project_cli_journey.sh
# Mission réelle:
NF_PROJECT_ROUTE=api bash scripts/e2e_project_cli_journey.sh
```

## Ce que le script vérifie (inject)

1. `{}` inject → `verdict=plan_failed` (pas de plan/mandat fabriqué)
2. `ask` → plan v1 ; `revise` → plan v2 à **2 étapes** (`add_csv_helpers` → `wire_export_csv`)
3. **Kill réel** pendant `step` (`NF_PROJECT_STEP_PAUSE_MS` + `kill -9`) ; `resume` → `interrupted` + `action=retry_step` + `provider_attempt_unknown`
4. `resume` sur store sain → `action=run_step`
5. Step 1 : helpers dans `tasks.nim` ; snapshot `accepted_tree_ref` + diff lisible
6. Step 2 : édite sur l’arbre accepté (réutilise `formatCsv`) ; vérif CSV complète
7. Binaire : sans argument / `list` / `export-csv` séparément
8. Patch qui remplace le défaut par du CSV → oracle `list_mismatch`

## Transcription courte (inject, vérifié)

Campagne : `docs/qa/project_cli_journey/20261122T004817Z`

| Étape | Verdict | Notes |
| --- | --- | --- |
| empty `{}` | `plan_failed` | `empty_plan` |
| ask | `plan_ready` | plan v1 |
| revise | `plan_revised` | 2 steps + mandat CSV |
| kill+resume | `interrupted` | `retry_step`, provider unknown |
| resume | `resumed` | `run_step`, `billable_plan_calls=0` |
| step1 | `pass` | tree hash persisté ; verify partielle |
| step2 | `pass` | source=tree step1 ; CSV ok |
| status | all `done` | |

## API (premier résultat conservé)

Campagne : `docs/qa/project_cli_journey/api_20261122T004713Z`

- `verdict=model_failed` — DNS / `Name or service not known` vers `api.openai.com`
- Rôles encore à qualifier sur un VPS avec réseau OpenAI : **planner, reviser, implementer**

Sur VPS joignable :

```bash
NF_PROJECT_ROUTE=api bash scripts/e2e_project_cli_journey.sh
# Le script suit toutes les étapes du plan renvoyé (boucle step).
# Capturer: ask.json, revise.json (change_notes / mandat), step*.json (diff), status.json (usage_by_role)
```

## Hors périmètre

- Campagnes glob sous `docs/qa/e2e_intervention/campaigns/` : intactes
- Pas de second SDK
