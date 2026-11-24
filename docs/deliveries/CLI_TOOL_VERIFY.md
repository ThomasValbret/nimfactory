# Livraison — vérification d’un outil CLI comme l’utilisateur

Date : 2026-11-24  
Branche : `fix/engine-pilot-cli-tool-verify`  
Base : `18c004d50d8823034b81e19b46b316689d205360`

## Où disparaissaient l’argument et le résultat (avant)

Chaîne plan → coerce → vérificateur :

1. Mandat / critères prose : « lit un fichier … **passé en argument** », « affiche exactement **le** nombre de caractères ».
2. `coerceExecutableCriteria` ne produisait que `program_runs` + parfois `stdout_exact:le` (article « le » pris pour littéral) — **aucun argv fichier**, **aucune paire entrée/sortie**.
3. `verifyGenericProgram` lançait `python3 longueur.py` **sans argument**.

Trace coercition (avant correctif) :

```
raw … "passé en argument" …
coerced: @["program_runs", "stdout_exact:le", "file_exists:longueur.py"]
```

## Correctif réutilisable

- Jeton `cli_case:INPUT::EXPECTED` (+ `recipe.cli_cases` / jeton `cli_cases`).
- Invocation : `python3 <entry> <INPUT>` sur l’arbre examiné.
- Reçu : `input`, `arguments`, `expected`, `observed`, `examined_tree`.
- Prose « passé en argument » → `cli_cases` ; fillers après « exactement » (le/la/nombre…) ignorés.

## SHA et empreintes

| | |
| --- | --- |
` 3c2be861190755345d3757ec8b4f0b3e056db9a2 `
| `build/nimfactory` | `7a53c0ac9dd78ffb7ceb1ba117f3a562bac1803a5a43a5b8767e19f1c2570959` |
| `build/nimfactory-studio` | `354444ae7d09ce449805916006aaf6664206211ca4e916811611e80ca96f17bc` |

## CLI — longueur.py (premier avant → après)

| | Avant (critères perdus) | Après (`cli_case` ×2) |
| --- | --- | --- |
| Verdict | `verify_failed` (traceback IndexError / usage) | `done` |
| Contrôles | `program_runs` args=`[longueur.py]` · `stdout_exact:le` | `cli_case:samples/a.txt::5` args=`[longueur.py, samples/a.txt]` obs `5` ; b→`11` |
| Constante `print(5)` | — | `proof_stale` · a ok · **b fail** (exp 11 obs 5) |

## word_tally

| Étape | Résultat |
| --- | --- |
| `project run` | `done` · `2 4 21` et `1 2 9` sur une ligne |
| Mutation multi-ligne Labels | `proof_stale` · `verify_recheck` rejoue les **mêmes** `samples/*.txt` · obs ≠ expected |

## Préservation

`notice_target_binding`, `loan_*` : OK dans `test_project_run_regressions` + `test_loan_adapter` / oracle Python.

## Commandes

```bash
nim c -r --path:src --path:vendor/NimAgentLibrary/src \
  tests/project/test_project_run_regressions.nim
nim c -d:release -d:ssl --path:src --path:vendor/NimAgentLibrary/src \
  -o:build/nimfactory src/nimfactory_cli.nim
nim e scripts/build_studio.nims
```
