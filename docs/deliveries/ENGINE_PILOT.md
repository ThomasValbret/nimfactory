# Livraison — Engine pilot (intégré Studio)

Date : 2026-11-24  
Branche : `feature/engine-pilot`  
**SHA publié** : `d519d49ac8c149186d873fa9d6470ce8d0974c04`

## Sources

| | SHA |
| --- | --- |
| Base précédente | `51564219c8534c0b16cfcd1396619cc0ed206c7e` |
| Studio proof adapter | `4aca8654f7b34ef15334b09218ba790bb2a9d71b` (`feature/studio-proof`) |
| Tip intégré | `d519d49ac8c149186d873fa9d6470ce8d0974c04` |

## Empreintes binaires

| Binaire | sha256 |
| --- | --- |
| `build/nimfactory` | `58e92444ba99a4aede714f8ac64a2c9035a50c4a6ffe442af8475603fdeaf665` |
| `build/nimfactory-studio` | `f20aff2eaf59c818601b4422ce01fd9426aaab48fd0140cf482c7291a2aafc62` |

## Périmètre

1. **Création de projet** — `patched_content` sur fichier absent = `create_file` (plus de refuse `target_missing` au diagnostic). Parcours ask→run→exécution pour « crée hello.py qui affiche bonjour » (dossier vide). Plus d’héritage CSV sans `recipe.verify=csv_journey`. Verify `generic_program`. Exemple 2 fichiers liés (`fixtures/linked_two_files`).
2. **done sur observations** — contrôles avec `status` / `observations` / `file_fingerprints` / `attempt`. Motifs absent/failed/not_run/stale. Rejeu `command_id` → reçu historique (`historical_receipt`, `new_provider_calls=0`). Status distingue `proof_freshness` vs fichiers courants.
3. **Studio** — adaptateur oracle runtime (cancel / CURRENT_DATE / persist), `served_tree`, projection observations.

Missions réservées Studio (dossier vide / dépôt inconnu) **non jouées**.

## Commandes

```bash
export PATH="/root/.nimble/bin:/root/.choosenim/toolchains/nim-2.4.0/bin:$PATH"
nim c -r --path:src --path:vendor/NimAgentLibrary/src \
  tests/project/test_project_run_regressions.nim
nim c -r --path:src --path:vendor/NimAgentLibrary/src \
  tests/project/test_loan_adapter.nim
python3 -m unittest tests.project.test_loan_oracle -v

nim c -d:release -d:ssl --path:src --path:vendor/NimAgentLibrary/src \
  -o:build/nimfactory src/nimfactory_cli.nim
nim e scripts/build_studio.nims

# Hello vide
./build/nimfactory project run \
  --store /tmp/engine_pilot_freeze/project.sqlite --project-id hello_empty \
  --cwd /tmp/engine_pilot_freeze/cwd \
  --objective "crée hello.py qui affiche bonjour" \
  --route inject --inject-dir fixtures/hello_empty/inject \
  --artifact-dir /tmp/engine_pilot_freeze/artifacts \
  --worktree /tmp/engine_pilot_freeze/worktrees \
  --command-id cmd-freeze-hello-1 --json

# Loan
./build/nimfactory project run \
  --store /tmp/engine_pilot_freeze/loan.sqlite --project-id loan_notebook \
  --cwd fixtures/loan_notebook \
  --objective "Je veux un carnet de prêts local avec restitution." \
  --route inject --inject-dir fixtures/loan_notebook/builder/inject \
  --artifact-dir /tmp/engine_pilot_freeze/loan_art \
  --worktree /tmp/engine_pilot_freeze/loan_wt \
  --command-id cmd-freeze-loan-1 --json
```

## Résultats (avant → après)

| Cas | Avant (5156421) | Après (d519d49) |
| --- | --- | --- |
| hello `patched_content` | refuse `target_missing` au diagnostic | `create_file` → apply → `done` · stdout `bonjour` |
| critères sans recipe | héritage `compile/list/export_command` | `file_exists` / `program_runs` / `stdout_bonjour` |
| loan comment-only | static string match faible | oracle adapter `mark_returned_effect=failed` |
| loan cancel / CURRENT_DATE | — | fail / pass (`test_loan_adapter`) |
| preuve mutée | — | `proof_freshness=stale` · motif exploitable |
| rejeu `command_id` | — | `historical_receipt` · `new_provider_calls=0` |

## Exemple de reçu CLI (réel)

```json
{
  "schema": "nimfactory.project_command/v1",
  "command": "run",
  "project_id": "hello_empty",
  "ok": true,
  "verdict": "done",
  "diff_origin": "inject",
  "attempt": {
    "kind": "run",
    "plan_version": 1,
    "accepted_tree_hash": "71D4BD5344CF49FF"
  },
  "controls_executed": [
    {"name": "file_exists", "status": "passed", "ok": true},
    {"name": "stdout_bonjour", "status": "passed", "ok": true},
    {"name": "program_runs", "status": "passed", "ok": true}
  ],
  "provider_calls": 2,
  "api_calls": 0
}
```

Loan tip : `verdict=done` · contrôles `schema_ok` / `mark_returned_effect` / `persistence_after_restart` = passed · API 0.

## Gel commun pour Studio

Candidat : tip `d519d49` + binaires ci-dessus. Handoff reçu : ce fichier + `docs/decisions/2026-11-23-engine-pilot-handoff.md` + `docs/decisions/2026-11-24-proof-receipt.md`.
