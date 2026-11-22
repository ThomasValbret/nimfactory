# Recette — carnet de prêts (Python / SQLite)

## Rôles

| Rôle | Fournit |
| --- | --- |
| **Squelette** | `skeleton/app.py` + `schema.sql` — démarrage technique local |
| **Builder** | Plans/inject sous `builder/inject/` — fonctions métier demandées |
| **Oracle** | `oracle/verify_studio_change.py` — redémarrage serveur + vérif modification Studio |

## Premier parcours Studio

**Nouveau projet → demande → aperçu local** : commande `ask_plan` (pas d’étapes exécutées).

Demande type : « Je veux un carnet de prêts local en Python/SQLite, avec restitution. »

## Commandes

```bash
# Squelette seul
LOAN_PORT=18181 python3 fixtures/loan_notebook/skeleton/app.py

# Oracle (exige mark_returned après builder Studio)
STUDIO_URL=http://127.0.0.1:18085 LOAN_PORT=18181 \
  python3 fixtures/loan_notebook/oracle/verify_studio_change.py
```
