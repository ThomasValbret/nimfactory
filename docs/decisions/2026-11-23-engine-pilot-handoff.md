# Handoff Studio — engine-pilot

Date : 2026-11-24  
Branche : `feature/engine-pilot`  
**SHA publié** : tip `d519d49ac8c149186d873fa9d6470ce8d0974c04` (PR #9 + loan persistence + engine pilot).  
Lire `git rev-parse origin/feature/engine-pilot` et `docs/deliveries/ENGINE_PILOT.md`.


## Base

- Parents de contrôle : `aad1a9b` (studio-run-merge) + `42593ca` (project-run) → arbre `ad47da0c…`
- Puis : PR #9 `67b4a27` (pas de patch inject silencieux en API) + `fix/studio-loan-persistence` (`05ea3b7`)

Le codeur Studio travaille sur cette base. CLI et Studio partagent `--store` / `--project-id` et le schéma `nimfactory.project_command/v1`.

## Reçu commun à afficher

Studio lit `GET /api/command?id=` et le snapshot `nimfactory.studio/v1`. Pas de second protocole.

Exemple (champs minimaux) :

```json
{
  "schema": "nimfactory.project_command/v1",
  "command": "run",
  "command_id": "cmd-loan-demo-1",
  "project_id": "loan_notebook",
  "status": "done",
  "ok": true,
  "verdict": "done",
  "message": "project run complete; accepted tree ready",
  "current_plan_version": 1,
  "next_action": "done",
  "attempt": {
    "kind": "run",
    "plan_version": 1,
    "source_tree": "/path/to/fixtures/loan_notebook",
    "accepted_tree_ref": "/path/to/artifacts/trees/mark_returned",
    "accepted_tree_hash": "A08595B857D1E260"
  },
  "diff_origin": "inject",
  "controls_requested": ["server_starts", "schema_ok", "mark_returned"],
  "controls_executed": [
    {
      "name": "mark_returned",
      "ok": true,
      "tree_ref": "/path/to/artifacts/trees/mark_returned",
      "tree_hash": "A08595B857D1E260",
      "observations": "UPDATE sets returned_on on open loan"
    }
  ],
  "observations": "loan app has mark_returned endpoint",
  "usage_by_role": {
    "implementer": {
      "prompt_tokens": 0,
      "completion_tokens": 0,
      "calls": 1,
      "estimated_usd": 0.0,
      "model": "injected"
    }
  },
  "provider_calls": 2,
  "api_calls": 0,
  "replayed": false
}
```

`diff_origin` ∈ `model` | `inject` | `historical_replay` | `deterministic_recipe` (ce dernier seulement si rejeu/route inject explicite).

## Décision `done`

Le moteur refuse `verdict=done` si un contrôle obligatoire est absent, échoué, ou exécuté sur un autre arbre que l’accepté livré.

## Trois témoins carnet

Oracle `fixtures/loan_notebook/oracle/verify_studio_change.py` + `tests/project/test_loan_oracle.py` :

1. commentaire seul → échec  
2. handler sans persistance `returned_on` → échec au redémarrage  
3. handler correct → succès before/after/restart  

Project run inject doit produire l’arbre du témoin 3 ; le verify moteur ne doit plus accepter le témoin 1.
