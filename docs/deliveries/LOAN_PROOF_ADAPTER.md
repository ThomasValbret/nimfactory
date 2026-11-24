# Livraison — adaptateur d’observations + projection Studio

Date : 2026-11-24  
Branche : `feature/studio-proof`  
Base : `aad1a9b` · PR #10 intégrée : `05ea3b7`  
Contrat partagé : `docs/decisions/2026-11-24-proof-receipt.md`

## Périmètre publié (intégrable par le moteur)

| Chemin | Rôle |
| --- | --- |
| `src/nimfactory/project/verify.nim` | adaptateur → `controls[]` |
| `src/nimfactory/project/tree_id.nim` | empreinte arbre servi |
| `src/nimfactory/application/project_view.nim` | projection générique |
| `src/nimfactory/studio/{client,sources}.nim` + `nimfactory_studio.nim` | UI + preview |
| `fixtures/loan_notebook/oracle/verify_studio_change.py` | oracle indépendant |
| `tests/project/test_loan_oracle.py` | témoins publics |
| `tests/project/test_loan_adapter.nim` | témoins adaptateur |
| `docs/decisions/2026-11-24-proof-receipt.md` | contrat |
| ce reçu | livraison |

**Exclu de la branche publiée** : `docs/qa/transfer_reserved/` (missions + assertions hors contexte builder).

## Témoins publics (même note `oracle-witness-shared`)

| Cas | ok | loan_id | après redémarrage | hash recalculé | effect | persist |
| --- | --- | --- | --- | --- | --- | --- |
| comment | false | 1 | `NULL` | `231859FEE92A648D` | failed | **not_run** |
| no_change | false | 1 | `NULL` | `741AA98368AE80A9` | passed | failed |
| abort_tx | false | 1 | `NULL` | `AFB43B84A0562E9C` | passed (HTTP 200) | failed |
| current_date | true | 1 | `2026-11-24` | `947780A350AC2016` | passed | passed |
| correct | true | 1 | `2026-11-24` | `50206A213736FEB7` | passed | passed |

## Reproduction

```bash
cd /opt/nimFactory-studio-proof   # ou worktree à ce SHA
python3 -m unittest tests.project.test_loan_oracle -v
nim c -r --path:src --path:/opt/NimAgentLibrary/src tests/project/test_loan_adapter.nim
```

## Doublures

Inject / oracle scripté. Zéro appel payant.
