# Livraison — Studio workflow ops (parcours navigateur)

Date : 2026-11-22  
Branche : `feature/studio-workflow-ops`  
SHA testé : `18038fdd5bccbcfaf431f4fadbd2b8ba3bbf14f9`  
Worktree : `/opt/nimFactory-studio-ops`  
Base fast-forward : `origin/feature/project-run` @ `affe5d4`

## Périmètre réalisé

- Workflow consultable pendant les commandes longues (`run` / `resume` / `pause_after_step`) via worker thread + GET `/api/snapshot` live.
- Bandeau Situation : objectif, étape active, preuves, coût, prochaine décision / proposition moteur.
- Commandes Studio branchées sur le service commun `executeProjectCommand` / `performProjectCommand` + reçus idempotents `command_id`.
- Blocage explicable : étape, motif (`verify_failed` / `blocked_reason`), contrôles exécutés, proposition moteur.
- Révision : effet sur preuves (`proof_kept` / `proof_dropped` / delta) ; reprise ensuite.
- Round-trip IDE : diff / vérification depuis l’étape acceptée, retour à la même sélection.
- CLI : `--pause-after-step` / `--max-steps` ; `run`/`resume` via `executeProjectCommand` quand `command_id` est fourni.
- Retransmission : dépense historique vs nouveaux appels (`annotateSpend`, GET `/api/command?id=` inclus).
- `project run` n’applique une refinement déjà présente qu’une seule fois (pas de re-bump au resume).

## Commande de lancement (VPS)

```bash
export PATH="/root/.nimble/bin:$PATH"
cd /opt/nimFactory-studio-ops

nim e scripts/build_studio.nims
nim c -d:release -d:ssl --hints:off --nimcache:build/nimcache_cli \
  --path:src --path:/opt/NimAgentLibrary/src \
  -o:build/nimfactory src/nimfactory_cli.nim

DEMO=/opt/nimFactory-studio-demo
FIX=/opt/nimFactory-studio-ops/fixtures/demo_tasks_cli
# Port 8085 occupé par Chiasme sur ce VPS → 18085
export STUDIO_PORT=18085
export NIMFACTORY_STUDIO_DEMO_DELAY_MS=2500   # optionnel : rendu dual-tab observable en inject
# Défaut : bind loopback. Pour un navigateur distant Cursor :
#   export NIMFACTORY_STUDIO_BIND=0.0.0.0
#   export NIMFACTORY_STUDIO_ALLOW_HOSTS=<ip-vps>

"$DEMO/reopen.sh"
# ou :
build/nimfactory-studio \
  --store "$DEMO/project.sqlite" \
  --project-id studio_workflow_ops \
  --trees "$DEMO/artifacts/trees" \
  --cwd "$FIX" \
  --route inject \
  --inject-dir "$DEMO/inject" \
  --artifact-dir "$DEMO/artifacts" \
  --objective "Je veux pouvoir exporter mes tâches." \
  --refinement "Je veux du CSV sur la sortie standard et je veux garder l'affichage actuel par défaut." \
  --port 18085
```

Tunnel Chromebook :

```bash
ssh -N -L 18085:127.0.0.1:18085 <user>@<vps>
# puis http://127.0.0.1:18085/
```

## Parcours démontré (inject, $0 API)

| Étape | Observation navigateur / CLI |
| --- | --- |
| 2 onglets ouverts sur le même projet | Onglet 2 suit le plan via polling |
| Pause après l’étape | Worker actif (`run_lease=active`, `worker_active`) ; message « plan reste consultable » ; plan v1→v2 + `add_csv_helpers` ✓ |
| IDE depuis étape acceptée | Diff / vérification ; « Revenir au workflow » conserve `add_csv_helpers` sélectionné |
| Reprendre avec export injecté comment-only | `verify_failed` · `csv_mismatch,comma_not_quoted` ; étape active **Bloquée** ; contrôles compile/list/export-csv/apply ; proposition = motif |
| Réviser | Plan v3→v4 ; `proof_kept=[add_csv_helpers]` ; `proof_dropped=[]` |
| Reprendre après correction inject export | `wire_export_csv` ✓ ; `next_action=done` ; reçu `resume · done` |
| Rechargement page | Δ events = 0, Δ transitions = 0 — aucun travail |
| CLI retransmet `command_id` revise | `replayed=true`, `historical_provider_calls=1`, `new_provider_calls=0` |
| GET `/api/command?id=` | Même distinction historique / nouveaux |
| Snapshot CLI == GET `/api/snapshot` | OK |

## Coûts

Zéro appel payant. Route `inject` uniquement. Les compteurs « provider » inject mesurent les fixtures consommées, pas de facturation.

## Limites restantes

- Pause = arrêt après une étape réussie (`pauseAfterStep` / `maxSteps=1`), pas d’interruption mid-step fournisseur.
- La démo de blocage utilise un inject export volontairement défaillant puis corrigé avant reprise.
- Bind public (`NIMFACTORY_STUDIO_BIND` / `ALLOW_HOSTS`) réservé à la démo navigateur distant ; défaut = loopback.
- Worktree d’intégration Studio (`feature/studio-revise-integration`) laissé intact.

## Tests exécutés

- `tests/studio/test_project_view.nim` OK  
- `tests/studio/test_project_command.nim` OK  
