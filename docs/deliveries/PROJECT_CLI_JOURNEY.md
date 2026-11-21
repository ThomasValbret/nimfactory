# Reçu — PROJECT_CLI_JOURNEY (premier parcours projet CLI)

## Lot / périmètre

Parcours CLI projet : `project ask|revise|step|status|resume`, fixture `demo_tasks_cli`, persistance SqliteRunStore, plan/révision gpt-4o-mini (ou inject), étape agent en worktree isolé, vérifs CSV + list défaut, reprise sans rejouer le plan.

Base inspectée : tip PR #4 `8363843` + commit clés `.keys` `d9a9b35` ; branche `feature/project-cli-journey`.

## Contrats consommés

- `SqliteRunStore` : `ensureRunId`, `putRunState`, `getRunState`, `appendEvent`, `recover` (inspect/events)
- Mission : `callPlannedApi` / `callFromInject`, `parseFixDecision`, `applyDecision` (worktree refuse-if-occupied)
- NimAgent : via adaptateur mission (`gpt-4o-mini`) — pas de second SDK

## Fichiers principaux

| Chemin | Rôle |
| --- | --- |
| `src/nimfactory/project/{types,store,plan_context,verify,pipeline}.nim` | Module projet |
| `src/nimfactory/project.nim` | Barrel |
| `src/nimfactory/cli/cli.nim` | Branchement CLI |
| `src/nimfactory/runtime/journal/run_store.nim` | `putRunState` / `getRunState` / `ensureRunId` |
| `fixtures/demo_tasks_cli/` | Fixture + injects |
| `scripts/e2e_project_cli_journey.sh` | E2E |
| `docs/qa/project_cli_journey/RECIPE.md` | Recette VPS |

### Exemple

```bash
./build/nimfactory project ask --store /tmp/p.sqlite --cwd fixtures/demo_tasks_cli \
  --objective "Je veux pouvoir exporter mes tâches." --route api
./build/nimfactory project revise --store /tmp/p.sqlite --project-id demo_tasks_cli \
  --refinement "Je veux du CSV sur stdout et garder list par défaut." --route api
./build/nimfactory project resume --store /tmp/p.sqlite --project-id demo_tasks_cli
./build/nimfactory project step --store /tmp/p.sqlite --project-id demo_tasks_cli --worktree /tmp/wt
./build/nimfactory inspect --store /tmp/p.sqlite --run-id project:demo_tasks_cli
```

## Commandes exécutées

```bash
nim c -d:release -d:ssl --path:src --path:vendor/NimAgentLibrary/src -o:build/nimfactory src/nimfactory_cli.nim
NF_PROJECT_ROUTE=inject bash scripts/e2e_project_cli_journey.sh
# → ok ; campagne docs/qa/project_cli_journey/20261121T223622Z (+ latest/)
NF_PROJECT_ROUTE=api bash scripts/e2e_project_cli_journey.sh
# → ask model_failed (api.openai.com unreachable in agent sandbox / DNS)
```

## Doublures vs réel

| Couche | Inject run | API run |
| --- | --- | --- |
| Planner / reviser / implementer | inject JSON (décisions modèle **non testées**) | non exécuté ici (réseau) |
| Apply edits + worktree | réel | — |
| Verify CSV/list/quote | réel déterministe | — |
| Resume / SQLite | réel ; 0 appel plan | — |

## Coûts

Inject vérifié : **0** USD, **0** tokens, `calls=0` par rôle (pas d’appel facturable).  
API : non mesurée dans cette session (indisponibilité réseau).

## Limites restantes

- Un seul `target_file` par step (héritage `parseFixDecision`) ; le mandat inject édite `src/demo_tasks.nim` uniquement.
- `project step` vérifie spécifiquement le parcours CSV de `demo_tasks_cli` (oracle métier du fixture, pas un oracle générique).
- Campagnes glob archivées non rejouées (hors périmètre).

## État

| Niveau | Statut |
| --- | --- |
| Composant project + CLI | utilisable |
| Intégration store/events/inspect | ok (inject E2E) |
| Parcours complet live LLM | **bloqué réseau** ici ; prêt VPS avec `.keys` |
