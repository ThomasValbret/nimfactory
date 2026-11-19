# Vague B — M1 : reprise saturation / start / faux completed

Date : 2026-11-19  
PR : https://github.com/ThomasValbret/nimfactory/pull/2 (**ouverte**)  
Base des défauts : `2cd338b27dcb9bca3ea5dbd11da4f9db9adba0d3`  
SHA fonctionnel testé : `416c418143d1c1edbe96c3d0bb17497db5b40d98`  
SDK : `bf22665ece77d7149dbe61df959a6024bf6b26f3` · Nim 2.4.0  

## Correctifs de cette passe

1. **Diamant wait/cap1** — si `pending_inputs` est présent, ne pas republier les sorties validées (évite deferred bloqués aux ckpt 1 et 3). Chemin legacy inchangé sans snapshot.
2. **Démarrage durable** — `beginGraphRun` : seed puis `run:start` avec `run_inputs` + pending/ready. Reprise sans re-fournir l’input après crash post-start.
3. **Faux completed** — bases produites par le binaire `dd4fcf5` : diagnostic `false completed…` ; run vraiment complet → exit 0 sans réinvocation.

## Avant / après

| Cas | Sur `2cd338b` / `dd4fcf5` | Après correctif |
| --- | --- | --- |
| Diamant wait/cap1 × 10 | 4 échecs (ckpt 1,3 seq+conc) | 10/10 completed |
| Crash après `run:start` | entrées introuvables | resume = continu |
| Faux completed two/join | silencieux partiel | diagnostic explicite |

Preuves : `docs/qa/m1_resume3_red/`, `docs/qa/m1_resume3_green/`, `scripts/m1_resume3_regression.sh`.

## Suites

```text
WAVE_A_TESTS_OK count=14
WAVE_B_M1_OK count=8
M1_RESUME3_REGRESSION_OK
```

## Jalon

| Objet | Verdict |
| --- | --- |
| Entrées indépendantes (passe précédente) | Conservé |
| Trois cas reprise ci-dessus | **Corrigé** |
| Fusion PR #2 | **Non** — revue humaine |
| Mission modèle E2E | Branche dédiée (hors PR #2) |

LLM : **0** sur cette passe M1.
