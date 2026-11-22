# Reçu — PROJECT_CLI_JOURNEY (arbres chaînés + reprise + intégrité pilote)

## Lot / périmètre

Suite PR #5 depuis `bf7f542` :

1. Persistance `accepted_tree_ref` / hash / diff lisible ; étape N+1 appliquée sur l’arbre accepté
2. Kill réel pendant `step` ; `resume` distingue terminé / interrompu ; issue fournisseur `unknown` sans rebill silencieux
3. Plus de plans/mandats fabriqués ; `{}` → `plan_failed` ; vérif CSV liée à `recipe.json` ; tests binaire + patch CSV défaut
4. Tentative API réelle archivée (premier résultat)

## Base inspectée

- Tip précédent : `bf7f542`
- Branche : `feature/project-cli-journey`

## Contrats

- Consommés : `SqliteRunStore`, mission `applyDecision` / `parseFixDecision` / provider inject|api
- Modifiés : `project/{types,pipeline,verify,store}` — pas de second SDK

## Fichiers principaux

| Chemin | Rôle |
| --- | --- |
| `src/nimfactory/project/pipeline.nim` | ask/revise/step/resume ; chaînage arbres ; pause kill |
| `src/nimfactory/project/verify.nim` | `recipe.json` → `csv_journey` (partiel / final) |
| `src/nimfactory/project/types.nim` | `interrupted`, `accepted_tree_*` |
| `fixtures/demo_tasks_cli/recipe.json` | liaison vérif CSV |
| `fixtures/demo_tasks_cli/inject/plan_v2.json` | 2 étapes chaînées |
| `scripts/e2e_project_cli_journey.sh` | E2E inject/api |

## Commandes exécutées

```bash
NF_PROJECT_ROUTE=inject bash scripts/e2e_project_cli_journey.sh
# → ok ; docs/qa/project_cli_journey/20261122T004817Z

# Premier résultat API (échec réseau, conservé) :
./build/nimfactory project ask --route api ...
# → docs/qa/project_cli_journey/api_20261122T004713Z  verdict=model_failed
```

## Doublures vs réel

| Couche | Inject | API |
| --- | --- | --- |
| Planner/reviser/implementer | inject (non qualifié modèle) | **indisponible** DNS |
| Apply + arbres acceptés | réel | — |
| Kill/resume SQLite | réel | — |
| Verify CSV recipe | réel | — |

## Coûts

- Inject : 0 USD / 0 tokens facturables
- API : 0 appel abouti (échec résolution `api.openai.com`)

## Limites

- Rôles **planner, reviser, implementer** restent à qualifier dès que l’API est joignable
- Un `target_file` par step (héritage mission)

## État

| Niveau | Statut |
| --- | --- |
| Composant (hors API) | utilisable — inject E2E vert |
| Intégration store/resume/arbres | ok |
| Parcours live LLM | bloqué réseau ; premier échec archivé |
