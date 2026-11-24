# Livraison — cible de contrôle NOTICE + intégration attempt-directory

Date : 2026-11-24  
Branche : `fix/engine-pilot-done-freshness`

## SHA

| | SHA |
| --- | --- |
| Base fraîcheur publiée | `ff64adcae4afac6791c80ee4f9869ec525bd01a8` |
| Intégré (collision reprise) | `598ca8ea283135995740b6a90dfbb0da8ee08285` → cherry-pick `067e6a4…` |
| Candidat commun (tip livraison) | `ea139aec42d06f356d85f64f1a4660d306de927a` |

## Empreintes binaires (candidat)

| Binaire | sha256 |
| --- | --- |
| `build/nimfactory` | `24c768f61763325b54748fcb8dcacc322ce3db70b906a98934fbf2f16e5197e0` |
| `build/nimfactory-studio` | `619a83bc00d8ba42dc8e347dc6b89d466ce1b859770ad365d3b10470d1493d74` |

## Périmètre

1. Publication fraîcheur / rejeu / `stdout_exact` (déjà sur origin).
2. Intégration `598ca8e` — worktree frais par tentative de `project run`.
3. **Contrôle lié à la cible du plan** — `file_exists:PATH` ; chemin attendu / observé / arbre examiné dans le reçu. Étape documentaire : NOTICE.txt suffit. Autre fichier + script préexistant → échec. Programme / stdout seulement à l’étape qui les demande.

## CLI — NOTICE (premier résultat avant → après)

| Cas | Avant | Après |
| --- | --- | --- |
| Plan « Créer NOTICE.txt », inject `OTHER.txt`, seed `hello.py` | **`done`** · `file_exists` ok via `hello.py` | **`verify_failed`** · `file_exists:NOTICE.txt` · `expected_path=NOTICE.txt` · `observed_path=` · `examined_tree` renseigné · obs « found other: hello.py » |

## CLI — projet public 2 étapes + verify_recheck

`fixtures/notice_then_hello` : NOTICE puis `hello.py` / `stdout_exact:bonjour`.

| Étape | Résultat |
| --- | --- |
| run → programme utilisable | `done` · stdout `bonjour` · contrôles NOTICE + hello avec chemins |
| muter `hello.py` → `print("hello")` · nouvel id | `proof_stale` · `verify_recheck.ok=false` · `program_runs` ok · `stdout_exact` fail (`observed=hello`) |

## Vérifications

```bash
nim c -r --path:src --path:vendor/NimAgentLibrary/src tests/project/test_project_run_regressions.nim
nim c -r --path:src --path:vendor/NimAgentLibrary/src tests/mission/test_intervention_bench.nim
nim c -r --path:src --path:vendor/NimAgentLibrary/src tests/project/test_loan_adapter.nim
python3 -m unittest tests.project.test_loan_oracle -v
```

Toutes OK (banc d’intervention : nimcache système accessible).

## Limites

- Coûts : 0 appel fournisseur (inject).
- Tip Studio figé `d519d49` non requalifié ici ; binaires ci-dessus = candidat commun de cette branche.
