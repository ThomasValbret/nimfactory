# Vague B — M1 : correctif entrées pending au checkpoint

Date : 2026-11-19  
Dépôt : https://github.com/ThomasValbret/nimfactory  
Branche : `feature/wave-b-m1`  
PR : https://github.com/ThomasValbret/nimfactory/pull/2 (**ouverte**, fusion réservée à la revue)  
Base du défaut : `dd4fcf57e801c69cf0257edf06c140ef5a37b235`  
SHA fonctionnel testé : `2cd338b27dcb9bca3ea5dbd11da4f9db9adba0d3`  
SDK : `bf22665ece77d7149dbe61df959a6024bf6b26f3`  
Nim : 2.4.0  

## Défaut corrigé

À `--checkpoint-after 1`, une entrée initiale encore en attente (2ᵉ entrypoint) n’était pas durable. `resume` sans re-fournir l’input finalisait avec sorties partielles (`one` seul) ou `{}` (variante join).

## Correctif

- Snapshot `pending_inputs` / `ready` / `deferred` dans l’état de chaque commit d’activation (après fan-out).
- Restauration à la reprise ; diagnostic explicite si un ancien run n’a pas de snapshot récupérable.
- Activations déjà validées restent acquises.

## Preuves

| Artefact | Rôle |
| --- | --- |
| `docs/qa/m1_pending_input_red/` | Rouge CLI sur `dd4fcf5` |
| `docs/qa/m1_pending_input_green/` | Vert après correctif |
| `tests/f5/test_pending_resume.nim` | Réception unitaire + diagnostic irrécupérable |
| `scripts/m1_pending_input_recipe.sh` | Recette CLI deux graphes |

## Suites (régression)

```text
./scripts/test_wave_a.sh          → WAVE_A_TESTS_OK count=14
./scripts/test_wave_b_m1.sh       → WAVE_B_M1_OK count=6
./scripts/m1_resume_recipe.sh     → checkpoints 1–5 OK
./scripts/m1_pipe_backpressure_cli.sh → OK
```

## Jalon

| Objet | Verdict |
| --- | --- |
| Wait/cap1 + run_id/epoch | Conservés |
| Pending entrypoint resume | **Corrigé** |
| **M1** | Correctif livré — requalification sur SHA fonctionnel ci-dessous |
| Fusion PR #2 | **Non** — revue humaine |

LLM : **0**.
