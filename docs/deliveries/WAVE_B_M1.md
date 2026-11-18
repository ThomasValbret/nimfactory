# Vague B — correctif M1 (F5/F16/F17) — à requalifier

Date : 2026-11-18  
Dépôt : https://github.com/ThomasValbret/nimfactory  
Branche : `feature/wave-b-m1`  
PR : https://github.com/ThomasValbret/nimfactory/pull/2  
Base du correctif tuyau/contexte : `f7b3acaa0956f51a16b6f95f0a4776c371aca816`  
Révision testée (contenu) : `dd4fcf57e801c69cf0257edf06c140ef5a37b235`  
SDK : `bf22665ece77d7149dbe61df959a6024bf6b26f3` (`pin_verified=yes`)

## Objectif de cette passe

Corriger les deux écarts F5 restants (wait qui bloque l’ordonnanceur ; contexte worker sans `run_id`/`epoch`), conserver les 5 checkpoints, livrer rouge/vert, relancer A + M1. **M1 reste à requalifier.**

## Preuves rouge → vert

| Preuve | Artefact | Verdict |
| --- | --- | --- |
| Rouge reprise D1–D3 | `docs/qa/m1_resume_defects_red.jsonl` | Conservé |
| Vert reprise | `docs/qa/m1_resume_defects_green.jsonl` | Conservé |
| Rouge F5 gaps (wait hang + ctx) | `docs/qa/m1_f5_gaps_red.jsonl` | 2 défauts sur `f7b3aca` |
| Vert F5 gaps | `docs/qa/m1_f5_gaps_green.jsonl` | `failures=0` |
| CLI tuyau (timeout anti-hang) | `docs/qa/m1_pipe_backpressure_cli.log` | wait seq/conc + reject + spill |

## Lots

| Lot | Reçu | État |
| --- | --- | --- |
| F5 | [F5.md](F5.md) | Correctif tuyau/contexte livré |
| F16 | [F16.md](F16.md) | Conservé |
| F17 (M1) | [F17.md](F17.md) | **À requalifier** |

## Commandes exécutées

```bash
./scripts/test_wave_a.sh
# WAVE_A_TESTS_OK count=14 sdk=bf22665… pin_verified=yes

./scripts/test_wave_b_m1.sh
# WAVE_B_M1_OK count=5 sdk=bf22665… pin_verified=yes

./scripts/m1_resume_recipe.sh
# M1_RESUME_RECIPE_OK checkpoints=[1,2,3,4,5]

./scripts/m1_pipe_backpressure_cli.sh
# M1_PIPE_BACKPRESSURE_CLI_OK
```

## Jalon

| Objet | Verdict |
| --- | --- |
| M0 | Conservé (A.1) |
| **M1** | **À requalifier** — PR #2 ouverte |
| Vague B complète (F2/F13) | Non — hors de cette passe |

LLM : **0**.
