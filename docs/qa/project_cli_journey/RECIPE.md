# Recette VPS — parcours projet CLI (concurrence + oracle CSV)

## Base

| Champ | Valeur |
| --- | --- |
| Branche | `feature/project-cli-journey` |
| Fixture | `fixtures/demo_tasks_cli/` (+ `recipe.json` → `verify=csv_journey`) |
| Négatif | `fixtures/demo_tasks_cli_neg/` (noms de fonctions alternatifs) |
| Modèle | `gpt-4o-mini` (`planner` / `reviser` / `implementer`) |

## Prérequis

```bash
cd /opt/nimFactory
export PATH="/root/.nimble/bin:${PATH:-}"
NF_PROJECT_ROUTE=inject bash scripts/e2e_project_cli_journey.sh
# Mission réelle (une campagne) :
NF_PROJECT_ROUTE=api bash scripts/e2e_project_cli_journey.sh
```

## Contrôles hors API

1. `{}` → `plan_failed`
2. **Concurrence** : step vivant (pause) + second processus sur le même store
   - `resume` → `verdict=active`, `action=wait`
   - second `step` → `already_running`, `provider_calls_this_command=0`
3. Kill du premier → `resume` → `interrupted` + `provider_attempt_unknown` + `retry_step`
4. Étapes chaînées sur `accepted_tree_ref` ; oracle comportemental (pas de noms de fonctions imposés)
5. Binaire : sans argument / `list` / `export-csv` (ou `list --format=csv`)
6. Négatif via `project step` sur `demo_tasks_cli_neg` → `verify_failed` / `list_mismatch`

## Transcription inject (vérifié)

Campagne : `docs/qa/project_cli_journey/20261122T014259Z`

| Étape | Verdict |
| --- | --- |
| empty `{}` | `plan_failed` |
| resume while alive | `active` |
| concurrent step | `already_running` (0 appel) |
| resume after kill | `interrupted` / `retry_step` |
| step1+step2 | `pass` (arbre chaîné + CSV) |
| neg step | `verify_failed` / `list_mismatch` |

## API (premier résultat)

Campagne : `docs/qa/project_cli_journey/api_20261122T014323Z`

- Erreur exacte : `Could not resolve host: api.openai.com` / `Name or service not known`
- Rôles non testés : **planner, reviser, implementer** (pas de substitution locale)

Dès que le DNS OpenAI répond :

```bash
NF_PROJECT_ROUTE=api bash scripts/e2e_project_cli_journey.sh
```
