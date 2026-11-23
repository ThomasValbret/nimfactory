# Livraison — carnet de prêts sur arbre NimFactory

Date : 2026-11-23  
Branche : `feature/studio-run-merge`  
HEAD : `1344632bac673679cb1c4c008e7f3d213e7df7a3`  
Intégré depuis `261d273` : `9c14b0c`

## Périmètre

- Recette `fixtures/loan_notebook` liée à `verify=loan_notebook`
- Oracle avant/après sur l’arbre **accepté** (pas un patch manuel hors pipeline)
- Prêt identifiable + redémarrage serveur sur la même base SQLite

## Résultats observés

| | |
| --- | --- |
| SHA arbre servi | **`A08595B857D1E260`** |
| Chemin | `/tmp/loan_nf_demo/artifacts/trees/mark_returned` |
| Avant | `/return` échoue · prêt `oracle-ident-20261123T1958Z` créé |
| Après | prêt retrouvé sans recréation · `/return` ok |
| QA | `docs/qa/loan_notebook/20261123T190239Z` |

## Doublures

Route **inject** uniquement (zéro appel modèle payant).
