# Vague B — correctif M1 (F5/F16/F17) — à requalifier

Date : 2026-11-18  
Dépôt : https://github.com/ThomasValbret/nimfactory  
Branche : `feature/wave-b-m1`  
PR : https://github.com/ThomasValbret/nimfactory/pull/2  
Base du correctif : `a9f48b2db12df575a4cdb4b754be67a875e8b6cd`  
Révision testée (contenu) : `f7b3acaa0956f51a16b6f95f0a4776c371aca816`  
SDK : `bf22665ece77d7149dbe61df959a6024bf6b26f3` (`pin_verified=yes`)

## Objectif de cette passe

Corriger les trois défauts de reprise reproduits sur `a9f48b2`, faire échouer la recette si un résultat affiché manque dans SQLite, livrer preuves rouge/vert, relancer A + M1 + CLI. **M1 reste à requalifier.**

## Preuves rouge → vert

| Preuve | Artefact | Verdict |
| --- | --- | --- |
| Rouge (défauts D1/D2/D3) | `docs/qa/m1_resume_defects_red.jsonl` | 3 défauts présents sur arbre pré-correctif |
| Vert | `docs/qa/m1_resume_defects_green.jsonl` | `failures=0` après correctif |

## Lots

| Lot | Reçu | État |
| --- | --- | --- |
| F5 | [F5.md](F5.md) | Correctif livré |
| F16 | [F16.md](F16.md) | Correctif livré |
| F17 (M1) | [F17.md](F17.md) | Correctif livré — **à requalifier** |

## Commandes exécutées

```bash
./scripts/test_wave_a.sh
# WAVE_A_TESTS_OK count=14 sdk=bf22665… pin_verified=yes

./scripts/test_wave_b_m1.sh
# WAVE_B_M1_OK count=4 sdk=bf22665… pin_verified=yes

./scripts/m1_resume_recipe.sh
# M1_RESUME_RECIPE_OK checkpoints=[1,2,3,4,5] peak_concurrent=2
```

Journaux : `docs/qa/m1_*.jsonl`, `docs/qa/m1_wave_b_suite.log`, `docs/qa/m1_wave_a_guard.log`.

## Adaptateurs

- **Réels** : SqliteRunStore (F3), GraphValidator (F4), CLI/fs
- **Simulés** : handlers `demo.*`, tuyaux mémoire
- **Absents** : F2, F13, LLM

## Jalon

| Objet | Verdict |
| --- | --- |
| M0 | Conservé (A.1) |
| **M1** | **À requalifier** — correctif + preuves livrés sur PR #2 |
| Vague B complète (F2/F13) | Non — hors de cette passe |

LLM : **0**.
