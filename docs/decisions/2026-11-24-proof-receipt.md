# Décision — reçu de preuve partagé (Studio ↔ moteur)

Date : 2026-11-24  
Base : `aad1a9b` + PR #10 `05ea3b7` · branche Studio `feature/studio-proof`  
Propriétaires : adaptateur/oracle/projection Studio (ce lot) · contrat `done` / intégration (codeur moteur)

## Trois questions utilisateur

1. Qu’a réellement changé le builder ? → `change` (`target_file`, `before_hash`, `after_hash`) + `readable_diff` + origine (`provider.route` / inject|api).
2. Quelle preuve sur la version ouverte ? → `controls[]` exécutés sur l’arbre servi + `served_tree` (hash recalculé, pas une chaîne lanceur).
3. Comment reprendre la main si échec ? → `next_action` / `engine_proposal` / commandes `capabilities.commands`.

## Schéma d’observation (exemple minimal)

```json
{
  "ok": false,
  "kind": "loan_notebook",
  "message": "return_not_persisted",
  "controls": [
    {"name": "schema_ok", "status": "passed", "observation": "skeleton/schema.sql present"},
    {"name": "mark_returned_effect", "status": "failed",
     "observation": {"http_ok": true, "returned_on": null, "loan_id": 1}},
    {"name": "persistence_after_restart", "status": "not_run",
     "observation": "skipped because effect failed"},
    {"name": "served_tree_identity", "status": "passed",
     "observation": {"hash": "…", "root": "…/worktree", "file_count": 12}}
  ],
  "served_tree": {"hash": "…", "root": "…", "claimed_tree_sha": ""},
  "details": {}
}
```

`status` ∈ `passed` | `failed` | `not_run`. Un contrôle `not_run` est affichable.  
`claimed_tree_sha` peut rappeler une valeur lanceur ; **seule** `served_tree.hash` (recalculée sur le répertoire servi) établit l’identité.

## Règles done (moteur)

- Les deux variantes défectueuses (commentaire seul ; HTTP 200 sans mutation SQLite) → `ok=false` → pas de transition `done`.
- Le vrai patch (restitution persistante après redémarrage) → `ok=true` si tous les contrôles exigés sont `passed`.
- Studio n’interprète plus `csv_ok` / `quote_ok` : il affiche `controls` fournis par le projet.

## Témoins prêts (PR #10)

`python -m unittest tests.project.test_loan_oracle` : comment → refuse ; no_change → refuse ; correct → accepte.
