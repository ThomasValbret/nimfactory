# Recette — carnet de prêts (Python / SQLite)

## Rôles

| Rôle | Fournit |
| --- | --- |
| **Squelette** | `skeleton/app.py` + `schema.sql` — démarrage technique **sans** restitution |
| **Builder** | `builder/inject/step_mark_returned.json` — ajoute `POST /loans/{id}/return` |
| **Oracle** | `oracle/verify_studio_change.py` — avant/après sur l’**arbre accepté** NimFactory |

## Contrôle attendu

1. **Avant** (squelette) : `/return` échoue ; création d’un prêt identifiable (`note` unique).
2. NimFactory / Studio produit un arbre accepté (hash servi).
3. **Après** (même `LOAN_DB`) : redémarrage sur l’arbre accepté ; le prêt est retrouvé **sans** recréation ; `/return` réussit.

## Commandes

```bash
FIX=fixtures/loan_notebook
DEMO=/tmp/loan_nf_demo
mkdir -p "$DEMO"

# 1) Avant — échoue sur le squelette
LOAN_ORACLE_MODE=before LOAN_DB="$DEMO/loans.sqlite" LOAN_PORT=18181 \
  python3 "$FIX/oracle/verify_studio_change.py"

# 2) Production de l’arbre (inject)
build/nimfactory project run \
  --store "$DEMO/project.sqlite" --project-id loan_notebook \
  --cwd "$FIX" \
  --objective "Je veux un carnet de prêts local avec restitution." \
  --route inject --inject-dir "$FIX/builder/inject" \
  --artifact-dir "$DEMO/artifacts" --worktree "$DEMO/worktrees" \
  --json > "$DEMO/run.json"

TREE=$(python3 -c "import json;print(json.load(open('$DEMO/run.json')).get('delivered_tree') or '')")
SHA=$(python3 -c "import json;print(json.load(open('$DEMO/run.json')).get('delivered_hash') or '')")

# 3) Après — réussit sur l’arbre servi (même base)
LOAN_ORACLE_MODE=after \
LOAN_APP_AFTER="$TREE/skeleton/app.py" \
LOAN_DB="$DEMO/loans.sqlite" \
TREE_SHA="$SHA" LOAN_PORT=18181 \
  python3 "$FIX/oracle/verify_studio_change.py"
```

### Preuve de restitution persistante

L’oracle de réception vérifie que le prêt est ouvert avant le POST. Après la réponse HTTP, il redémarre le candidat sur la même base, relit le prêt par HTTP puis compare sa date de restitution à la ligne SQLite portant le même ID et la même note. Le champ `restart.checks` et `controls[]` portent les observations. Un HTTP 200 qui laisse `returned_on` nul fait échouer la qualification.

L’identité de l’arbre servi est **recalculée** sur le répertoire ouvert (`served_tree.hash`, FNV-1a aligné sur `tree_id.nim`). `TREE_SHA` éventuel du lanceur n’est qu’une revendication (`claimed_tree_sha`) ; il ne prouve pas l’identité.

Adaptateur Nim : `verifyLoanNotebook` invoque `LOAN_ORACLE_MODE=adapter` et refuse commentaire seul / 200 sans effet.
