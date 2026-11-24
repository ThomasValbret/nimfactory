# Handoff moteur — SHA intégrable

**SHA :** `4aca8654f7b34ef15334b09218ba790bb2a9d71b`  
Branche : `origin/feature/studio-proof`  
Base : `05ea3b7` (PR #10) ← `aad1a9b`

## Chemins utiles

| Chemin | Usage |
| --- | --- |
| `docs/decisions/2026-11-24-proof-receipt.md` | contrat `controls[]` / `served_tree` / done |
| `src/nimfactory/project/verify.nim` | adaptateur (consommer avant `done`) |
| `src/nimfactory/project/tree_id.nim` | empreinte arbre servi |
| `src/nimfactory/application/project_view.nim` | projection Studio |
| `fixtures/loan_notebook/oracle/verify_studio_change.py` | oracle + mode `adapter` |
| `tests/project/test_loan_oracle.py` | 5 témoins publics |
| `docs/deliveries/LOAN_PROOF_ADAPTER.md` | reçu |

## Reproduction

```bash
git fetch origin feature/studio-proof && git checkout 4aca865
python3 -m unittest tests.project.test_loan_oracle -v
nim c -r --path:src --path:/opt/NimAgentLibrary/src tests/project/test_loan_adapter.nim
```

`docs/qa/transfer_reserved/` n’est **pas** sur cette branche (gitignore).

## Premier écart reproductible (reçu `command_id`)

Sur `project run --command-id …` aboutissant à `done`, le reçu générique
(`buildGenericReceipt` dans `project_command.nim`) **n’inclut pas**
`delivered_tree` / `delivered_hash`, alors que l’étape porte
`accepted_tree_hash` et que `projectRun` les écrit dans `prep.report`.

```bash
# Au SHA 4aca865
build/nimfactory project run --command-id e2e-loan-run-1 … --json
# → steps[0].result.accepted_tree_hash == "1EDE3D2530FC7058"
# → top-level delivered_hash is null
```

Attendu pour le moteur : propager `delivered_tree` / `delivered_hash` (et
idéalement `accepted_*`) dans le reçu avant d’autoriser la lecture « arbre
livré » côté CLI/Studio sans reconsulter l’étape.
