# Livraison — Engine pilot

Date : 2026-11-24  
Branche : `feature/engine-pilot`  
Worktree : `/opt/nimFactory-engine-pilot`

## Gel (avant missions réservées Studio)

Ce reçu fige le candidat **avant** que Studio ne révèle ses deux missions
réservées (dossier vide ; dépôt inconnu). Les unitaires de découverte /
création de fichier existent ; les missions réservées ne sont pas jouées ici.

| | |
| --- | --- |
| **SHA publié** | voir `git rev-parse origin/feature/engine-pilot` après push |
| Empreinte binaire | `6a962ad02f7edfc4264e1f574cc8c663abfc0e02e561ccd69a35d760c50ea423` |

| Nim | 2.4.0 (`~/.choosenim/toolchains/nim-2.4.0`) |
| SDK | NimAgentLibrary via `vendor/NimAgentLibrary` |

## Base d’intégration

| Étape | SHA / arbre |
| --- | --- |
| Parents `464e6ad` | `aad1a9b` + `42593ca` |
| Arbre de contrôle | `ad47da0c8e45f2e3bf997cb034e6cf7dad51c5fd` (identique) |
| PR #9 | `67b4a27` |
| Adaptateur Studio loan persistence | `05ea3b7` |

## Périmètre réalisé

- Découverte sous budget (AGENTS / recipe / src|skeleton|…, cwd vide OK)
- Création de fichier absent via `patched_content`
- Prompts génériques (CSV/loan hors prompts communs ; inject API silencieux déjà coupé par PR #9)
- Verify loan durci : commentaires ignorés ; `returned_on = date('now')` exigé
- `proofCoversCriteria` strict + contrôles loan
- Reçu commun : `diff_origin`, `attempt`, `controls_requested` / `controls_executed`, `observations`
- Gate `done` : contrôles sur l’arbre accepté livré
- Trois témoins carnet (statique + oracle runtime + project run inject)

## Handoff Studio

Voir [docs/decisions/2026-11-23-engine-pilot-handoff.md](../decisions/2026-11-23-engine-pilot-handoff.md) — SHA + exemple `nimfactory.project_command/v1`.

## Commandes exécutées

```bash
export PATH="/root/.nimble/bin:/root/.choosenim/toolchains/nim-2.4.0/bin:$PATH"
nim c -r --path:src --path:vendor/NimAgentLibrary/src \
  tests/project/test_project_run_regressions.nim
# → ALL project run regression tests passed

python3 -m unittest tests.project.test_loan_oracle -v
# → OK (comment / no_change / correct)

nim c -d:release -d:ssl --path:src --path:vendor/NimAgentLibrary/src \
  -o:build/nimfactory src/nimfactory_cli.nim

FIX=fixtures/loan_notebook
DEMO=/tmp/loan_nf_demo_pilot
./build/nimfactory project run \
  --store "$DEMO/project.sqlite" --project-id loan_notebook \
  --cwd "$FIX" \
  --objective "Je veux un carnet de prêts local avec restitution." \
  --route inject --inject-dir "$FIX/builder/inject" \
  --artifact-dir "$DEMO/artifacts" --worktree "$DEMO/worktrees" \
  --json > "$DEMO/run.json"

# Oracle runtime (chemins absolus) — witness 3
LOAN_ORACLE_MODE=full \
  LOAN_APP_BEFORE="$PWD/$FIX/skeleton/app.py" \
  LOAN_APP_AFTER="$(python3 -c "import json;print(json.load(open('$DEMO/run.json'))['delivered_tree'])")/skeleton/app.py" \
  LOAN_DB="$DEMO/loans_oracle.sqlite" LOAN_PORT=18282 \
  TREE_SHA="$(python3 -c "import json;print(json.load(open('$DEMO/run.json'))['delivered_hash'])")" \
  python3 "$FIX/oracle/verify_studio_change.py"
```

## Résultats observés

| Contrôle | Résultat |
| --- | --- |
| Régressions project run | ALL passed |
| Oracle unittest 3 témoins | OK |
| `project run` loan inject | `verdict=done` · `diff_origin=inject` · contrôles sur arbre accepté |
| Arbre livré | `/tmp/loan_nf_demo_pilot/artifacts/trees/mark_returned` |
| Hash arbre | `FF71E55701495148` |
| Oracle full (absolu) | `ok=true` · restart `ok=true` |
| Doublures | inject (API 0) |
| Coût | 0 appel payant |

## Premier échec éventuel

Oracle lancé avec `LOAN_APP_BEFORE=fixtures/loan_notebook/skeleton/app.py` (chemin relatif) → `server failed to start` (`ok=false`). Relance avec chemin absolu → succès. Documenté pour Studio / lanceurs.

## Limites

- Missions réservées Studio (cwd vide réel, dépôt inconnu) **non jouées** (gel).
- Usage `model: injected` non encore normalisé dans `usage_by_role` pour inject.
- Intégration Studio UI : adapter loan persistence déjà mergé ; rejouer snapshot sur ce tip.
