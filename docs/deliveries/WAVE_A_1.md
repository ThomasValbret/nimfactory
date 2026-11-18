# Vague A.1 — Corrections et requalification

Date : 2026-11-18  
Dépôt : https://github.com/ThomasValbret/nimfactory  
Branche : `fix/wave-a1` (non fusionnée dans `main`)  
Base inspectée : `1e825005bcad9e046157f71c01bd6d4ac07ef288`  
Révision F0 A.1 : `d9394d1983b453ff4f8e95f5c1177d5322d2d2caf3` (contrats)  
Révision testée (HEAD) : `18af230b29dbda520e4690958fb255299660c86e`  

## Toolchain et SDK

| Élément | Valeur vérifiée |
| --- | --- |
| Nim | 2.4.0 (`nim --version`, git hash compilateur `14991af7…`) |
| NimAgent | `bf22665ece77d7149dbe61df959a6024bf6b26f3` via `vendor/NimAgentLibrary` |
| Résolution build | `config.nims` + `scripts/fetch_sdk.sh` (pas de dépendance implicite à `/opt` pour compiler) |
| Commande globale | `./scripts/test_wave_a.sh` |

## Nature du « 8/8 » (clôture A) vs A.1

Le « 8/8 » de WAVE_A désignait **huit exécutables de tests** Nim (`nim c -r` sur huit fichiers), pas huit suites exhaustives ni la preuve de toutes les garanties d’interruption/concurrence.  
A.1 ajoute `test_validation_strict` et `test_a1_component_probes` ; la commande globale a observé **10/10 OK** :

1. `tests/f0/test_contracts.nim`
2. `tests/f0/test_message_roundtrip.nim`
3. `tests/f0/test_fixture_consumers.nim`
4. `tests/f0/test_validation_strict.nim` ← A.1
5. `tests/f1/test_artifacts.nim`
6. `tests/f3/test_journal.nim`
7. `tests/f4/test_graph.nim`
8. `tests/f14/test_budget.nim`
9. `tests/f17/test_qualification_smoke.nim` (19 scénarios dont 5 A.1)
10. `tests/f17/test_a1_component_probes.nim` ← A.1

Sortie observée :
```
WAVE_A_TESTS_OK count=10 sdk=bf22665ece77d7149dbe61df959a6024bf6b26f3
```
Consommateur façade : `examples/wave_a1_facade.nim` → `wave_a1_facade: ok`  
LLM : **0**

## Correspondance défaut → correction → test

| ID revue | Lot | Défaut | Correction | Preuve |
| --- | --- | --- | --- | --- |
| R5 | F0 | meta/result/doublons/inconnus | validateurs stricts | `test_validation_strict` |
| R4 | F1 | read sets non cumulatifs ; identité snapshot ; résolution non durable | versions immuables + identité canonique + index durable | `test_artifacts` + sondes F17 |
| R2 | F3 | commitTransition epoch obsolète | garde epoch dans la transaction | `test_journal` + F17 probes |
| F3+ | F3 | outbox publishing sans redistrib | `redistributeUnackedOutbox` | `test_journal` |
| F3+ | F3 | SIGSEGV états manquants | rejet typé | `test_journal` |
| R3 | F4 | ports requis non alimentés ; cycle parasite | validation structurelle | `test_graph` + F17 |
| R1 | F14 | négatifs, dual-handle, persist/idempotence | autorité partagée + domaines + conflits | `test_budget` + F17 |
| — | F14 | nom Sqlite trompeur | `FileBudgetLedger` ; alias déprécié | ADR + code |

Détails par lot : [F0.md](F0.md), [F1.md](F1.md), [F3.md](F3.md), [F4.md](F4.md), [F14.md](F14.md), [F17.md](F17.md).  
Revue source : [docs/qa/WAVE_A_REVIEW.md](../qa/WAVE_A_REVIEW.md).

## Doublures et intégrations

- Adaptateurs réels : Message NimAgent (pin vendor), SQLite système pour F3, artefacts disque F1, ledger fichier F14
- Doublures : registre handlers F4 simulé ; F17 oracles simulés + probes composants
- Pas de fork Message (seul `message_codec` factory)

## Limites restantes

- F16 partiel / seeds F12 : hors A.1
- F13 scripté prouve le broker, pas la qualité des petits modèles : hors A.1 (vague B)
- F17 : qualification A.1 des contre-exemples ; pas campagne LLM / M4
- F14 : backend fichier (pas SQLite) ; multi-processus dépend de l’autorité documentée dans F14.md
- M1 : **non atteint** (pas de CLI F16 ni exécuteur F5)

## Verdicts séparés

| Objet | Verdict A.1 |
| --- | --- |
| **F0** | Conforme aux critères de validation effective |
| **Composants A (F1, F3, F4, F14)** | Défauts revue corrigés et couverts par tests/probes |
| **F17** | Étendu aux cas A.1 ; mode simulé + component_probe |
| **M0** | **Atteint** après requalification A.1 (Message + validateurs/schémas) |
| **M1** | **Non atteint** (exécuteur/CLI hors périmètre) |

## Point d’arrêt

A.1 corrigée, testée, prête pour revue sur `fix/wave-a1`.  
**Pas** d’intégration vague B dans cette passe. **Pas** de merge `main`.
