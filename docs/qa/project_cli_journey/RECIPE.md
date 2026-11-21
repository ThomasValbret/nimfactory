# Recette VPS — premier parcours projet CLI

## Base

| Champ | Valeur |
| --- | --- |
| Branche | `feature/project-cli-journey` |
| SHA de départ (tip PR #4) | `8363843` |
| Fixture | `fixtures/demo_tasks_cli/` |
| Store | SQLite `nf_runs.state_json` + `nf_events` (`run_id=project:<id>`) |
| Modèle planifié | `gpt-4o-mini` (roles `planner` / `reviser` / `implementer`) |

## Prérequis

```bash
cd /opt/nimFactory
export PATH="/root/.nimble/bin:${PATH:-}"
# Clé: env → .keys (gitignoré) → /opt/.keys
# Pour forcer inject (pas d'appel facturable):
#   NF_PROJECT_ROUTE=inject bash scripts/e2e_project_cli_journey.sh
```

## Commandes exactes (script)

```bash
NF_PROJECT_ROUTE=api bash scripts/e2e_project_cli_journey.sh
# ou
NF_PROJECT_ROUTE=inject bash scripts/e2e_project_cli_journey.sh
```

Le script enchaîne :

1. `project ask` — objectif « Je veux pouvoir exporter mes tâches. »
2. `project revise` — précision « Je veux du CSV sur la sortie standard et je veux garder l'affichage actuel par défaut. »
3. interruption simulée (fin de processus ; SQLite conservé)
4. `project resume` — rehydrate `plan_v2`, `billable_plan_calls=0`
5. `project step` — worktree isolé + edits + vérifs déterministes
6. `project status` + `inspect` / `events` sur `run_id=project:demo_tasks_cli`

## Vérifications déterministes (étape)

Sur le worktree :

1. `list` inchangé vs baseline fixture (titre avec virgule affiché tel quel)
2. `export-csv` → CSV sur stdout
3. champ `Appeler Alice, Bob` correctement quoté

## Artefacts inspectables

Sous `docs/qa/project_cli_journey/<STAMP>/` :

- `ask.json` / `revise.json` / `resume.json` / `step.json` / `status.json`
- `artifacts/plan_v1.json`, `plan_v2.json`, `mandate_v1.json`, `mandate_v2.json`, `mandate.json`
- `summary.json` — coûts/tokens par rôle
- copie stable : `docs/qa/project_cli_journey/latest/`

## Transcription courte (inject, vérifié)

Campagne : `docs/qa/project_cli_journey/20261121T223622Z` (SHA tip local au moment du run).

| Étape | Verdict | Notes |
| --- | --- | --- |
| ask | `plan_ready` | plan v1, 1 step pending |
| revise | `plan_revised` | plan v2 + mandat CSV opt-in |
| resume | `resumed` | `billable_plan_calls=0`, pending `implement_export` |
| step | `pass` | list ok, CSV ok, comma quoted |
| status | all `done` | usage inject = 0 tokens / 0 USD |

`untested` en inject : décisions modèle planner / reviser / implementer.

## Coûts par rôle

| Rôle | Inject (vérifié ici) | API (si clé + réseau) |
| --- | --- | --- |
| planner | 0 call facturable | 1× gpt-4o-mini |
| reviser | 0 | 1× gpt-4o-mini |
| implementer | 0 | 1× gpt-4o-mini (édits) |

Sur cette machine d’agent, `api.openai.com` n’était pas joignable (échec DNS / proxy sandbox) au moment de la recette ; le parcours inject a été exécuté de bout en bout. Sur le VPS avec `.keys` et réseau OpenAI : `NF_PROJECT_ROUTE=api`.

## Hors périmètre

- Campagnes glob archivées sous `docs/qa/e2e_intervention/campaigns/` : **intactes**.
- Pas de second SDK ; NimAgent `newAgent`/`runSync` pour les appels API.
