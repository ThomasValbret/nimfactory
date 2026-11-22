# Livraison — intégration Studio + révision de plan

Date : 2026-11-22  
Branche : `feature/studio-revise-integration`  
SHA testé : 1caf8f60e92ff9808e601b87a7e61b8af9291991

## Base inspectée

| Source | SHA observé |
|---|---|
| `origin/feature/project-cli-journey` (PR #5) | `ed0d368` (+ cherry-pick local `0e75909` sticky `revise_plan`) |
| `origin/feature/studio-foundation` (PR #6) | `a6506d4` |
| `origin/main` | `ae331bd` |
| Merge-base Studio ↔ journey | `e8609ea` |

Worktree d’intégration : `/opt/nimFactory-studio-integration`  
Le worktree `/opt/nimFactory` (modifications locales concurrentes) n’a pas été écrasé.

## Périmètre réalisé

- Fusion Studio Nim (lecture) sur le tip journey + sticky `revise_plan`.
- Service partagé `executeRevisePlan` (`application/project_command.nim`) : CLI et Studio.
- Commande `revise_plan` : `project_id`, `expected_plan_version`, `refinement`, `command_id`.
- Idempotence via `nf_transitions` ; conflit de version explicite ; tentative `active` identifiable.
- Reçu moteur : `from_version` → `to_version`, delta d’étapes (ajoutées / retirées / conservées / acceptées perdues).
- Studio : POST `/api/command`, Origin/loopback, UI Workflow « Réviser le plan » selon `capabilities`.
- Projection snapshot : `capabilities` + champs `revise_plan_*`.

## Commandes de contrôle (VPS)

```bash
export PATH="/root/.nimble/bin:$PATH"
cd /opt/nimFactory-studio-integration   # ou clone de la branche

nim e scripts/build_studio.nims
nim c -d:release -d:ssl --hints:off --nimcache:build/nimcache_cli \
  --path:src --path:/opt/NimAgentLibrary/src \
  -o:build/nimfactory src/nimfactory_cli.nim

# Store de démonstration réutilisable (hors projets personnels)
DEMO=/opt/nimFactory-studio-demo
FIX=/opt/nimFactory-studio-integration/fixtures/demo_tasks_cli

build/nimfactory-studio \
  --store "$DEMO/project.sqlite" \
  --project-id studio_revise_demo \
  --trees "$DEMO/artifacts/trees" \
  --cwd "$FIX" \
  --route inject \
  --inject "$FIX/inject/plan_v2.json" \
  --artifact-dir "$DEMO/artifacts" \
  --port 8085
```

Tunnel Chromebook :

```bash
ssh -N -L 8085:127.0.0.1:8085 <user>@<vps>
# puis http://127.0.0.1:8085/
```

Vérifier après redémarrage :

```bash
build/nimfactory project status --store "$DEMO/project.sqlite" --project-id studio_revise_demo
build/nimfactory project snapshot --store "$DEMO/project.sqlite" --project-id studio_revise_demo
```

## Résultats observés (inject, $0 API)

| Cas | Résultat |
|---|---|
| Snapshot CLI == GET `/api/snapshot` | OK |
| Rechargement page / lecture pendant étape `running` | worker, bail (`owner_*`) et journal intacts |
| Studio revise v1→v2 | `plan_revised`, `provider_calls=1`, delta d’étapes |
| Retransmission même `command_id` | `replayed=true`, pas de 2ᵉ bump |
| 2ᵉ onglet resté sur v1 | `stale_plan_version`, HTTP 409, `provider_calls=0` |
| Origin étrangère | HTTP 403 |
| Navigateur : précision → reçu v1→v2 | OK |
| Step `add_csv_helpers` puis IDE Diff/Code/Vérification → Workflow | OK |
| Redémarrage Studio sur même store | retrouve v2 + preuves d’étape |
| Projet alt (ids/fichiers ≠ CSV) | revise OK (`touch_greet`/`wire_app`) |
| `revise_plan_needed` sticky | `next_action=revise`, status/resume sans appel fournisseur |

Tests unitaires : `tests/studio/test_project_view.nim`, `tests/studio/test_project_command.nim` OK.

## Limites restantes

- Seule la commande d’écriture `revise_plan` est exposée au Studio (pas ask/step/resume).
- Route Studio d’écriture démontrée en `inject` ; `api` possible via `--route api` mais non campagne payante ici.
- Usage reviser sous inject reste à 0 appels facturables (attendu).
- Fusion de `main` laissée à la revue ; base PR = `feature/project-cli-journey` pour un diff Studio+revise lisible.
- Le store `/opt/nimFactory-studio-demo` est une recette VPS locale, non versionnée dans Git.

## Coûts

Zéro appel payant. Route `inject` uniquement pour cette livraison.
