# Vague A.1 — candidat post-revue indépendante

Date : 2026-11-18  
Dépôt : https://github.com/ThomasValbret/nimfactory  
Branche : `fix/wave-a1` (**non fusionnée** dans `main`)  
Base revue : `ed2344a9de504535ba48f6db91517645338a3f04`  
Révision testée (contenu) :   
Revue indépendante : [docs/qa/WAVE_A_1_INDEPENDENT_REVIEW.md](../qa/WAVE_A_1_INDEPENDENT_REVIEW.md)

## Toolchain / SDK (vérifiés)

| Élément | Valeur |
| --- | --- |
| Nim | 2.4.0 |
| NimAgent | `bf22665ece77d7149dbe61df959a6024bf6b26f3` |
| Pin vérifié | `scripts/test_wave_a.sh` échoue si SHA ≠ pin (`nimagent_pin_verified=yes`) |
| Build | `vendor/NimAgentLibrary` via `scripts/fetch_sdk.sh` |

## Preuves rouge → vert (A1-R1…R5)

Programme : `docs/qa/a1_independent_probe.nim` (sans façade).

| État | Preuve |
| --- | --- |
| Rouge (avant correctifs) | [docs/qa/a1_independent_observations.jsonl](../qa/a1_independent_observations.jsonl) — **failed=7/10** (revue) ; reproduction locale **failed=5/10** avant correctifs restants |
| Vert (après) | [docs/qa/a1_probe_green.jsonl](../qa/a1_probe_green.jsonl) — **failed=0/total=10**, exit 0 |

Témoins positifs conservés : doublon JSON littéral, handles F14 même chemin, epoch F3 explicite ancien, (et F4 cycle résiduel déjà rejeté).

### Correspondance défaut → correction → test

| ID | Lot | Défaut | Correction | Test |
| --- | --- | --- | --- | --- |
| A1-R1 | F14 | alias de chemin → deux autorités | `ledgerRoot` = `absolutePath(normalizedPath(...))` | probe `F14_equivalent_path_handles` |
| A1-R2 | F1 | recapture écrase read sets | `capture` réutilise chaîne si même `snapshotId` | probe `F1_recapture_readset_immutability` |
| A1-R3 | F4 | cycle évitant le contrôleur loop | cycles résiduels après retrait des loop | probe `F4_cycle_bypasses_loop_limit` |
| A1-R4 | F3 | epoch omis contourne la garde | `epoch` entier obligatoire + égalité owner | probe `F3_missing_epoch_mutation` |
| A1-R5 | F0 | `\uXXXX` mal décodé ; `required:"true"` | décodage Unicode ; types imbriqués needs | probe F0_* + `tests/f0/test_a1_r5.nim` |

## Qualification complète observée

```
./scripts/test_wave_a.sh
# nimagent_pin_verified=yes
# WAVE_A_TESTS_OK count=12 sdk=bf22665ece77d7149dbe61df959a6024bf6b26f3 pin_verified=yes
examples/wave_a1_facade.nim → wave_a1_facade: ok
```

Journal : [docs/qa/a1_full_suite.log](../qa/a1_full_suite.log), [docs/qa/a1_facade.log](../qa/a1_facade.log).  
LLM : **0**.

## Verdicts séparés

| Objet | Verdict |
| --- | --- |
| **F0** | Écarts A1-R5 corrigés et couverts ; Message SDK réel utilisé via façade |
| **Composants A (F1, F3, F4, F14)** | Écarts A1-R1…R4 corrigés ; tests existants + sondes vertes |
| **M0** | **Reste à requalifier** (pas déclaré atteint ici ; revue indépendante à renouveler) |
| **M1** | **Non atteint** (pas F5/F16) |

## Limites

- Pas de vague B, pas de merge `main`
- F14 : identité de chemin normalisée in-process ; multi-processus non garanti
- F17 : qualification simulée + probes ; pas M4/LLM

## Point d’arrêt

Candidat A.1 prêt pour **nouvelle revue** sur `fix/wave-a1`. Fusion après validation externe.
