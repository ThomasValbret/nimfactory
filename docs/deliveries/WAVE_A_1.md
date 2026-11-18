# Vague A.1 — clôture et requalification M0

Date : 2026-11-18  
Dépôt : https://github.com/ThomasValbret/nimfactory  
Branche : `fix/wave-a1` (candidat accepté ; fusion préparée, vague B non ouverte)  
Candidat accepté : `2adb183001fe66110b67e48e56503403699f7d5c`  
Contenu fonctionnel : `fc3c45e8661aae00c30c9243972cacdfd577e3bc`  
Avis : [docs/qa/WAVE_A_1_ACCEPTANCE_REVIEW.md](../qa/WAVE_A_1_ACCEPTANCE_REVIEW.md)

## Toolchain / SDK

| Élément | Valeur | Qui l’a vérifié |
| --- | --- | --- |
| Nim | 2.4.0 | codeur + revue (hash compilateur revue : `14991af742d0833503741fd9a0918133d1bcf8a4`) |
| NimAgent | `bf22665ece77d7149dbe61df959a6024bf6b26f3` | **codeur** (`nimagent_pin_verified=yes`) ; revue : pin lu dans le script, SDK absent de son environnement |
| Réception | `scripts/test_wave_a.sh` — 11 tests + 3 sondes **obligatoires** | inchangé à la clôture |

## Statut A.1

**Clôturée.** Réserves A1-R1 à A1-R5 levées par l’avis favorable du 18 novembre 2026.

| Constat | Issue |
| --- | --- |
| A1-R1 F14 identité / symlinks | Levée |
| A1-R2 F1 recapture | Levée (confirmée, non rouverte) |
| A1-R3 F4 cycle résiduel | Levée (confirmée, non rouverte) |
| A1-R4 F3 epoch omis | Levée (confirmée, non rouverte) |
| A1-R5a/b F0 Unicode + structures | Levées |

## Preuves — distinction codeur / indépendantes

### Exécutions du codeur (versionnées)

| Preuve | Contenu |
| --- | --- |
| [a1r_full_suite.log](../qa/a1r_full_suite.log) | `nimfactory=fc3c45e…`, SDK `bf22665…`, `pin_verified=yes`, `WAVE_A_TESTS_OK count=14` |
| [a1_facade.log](../qa/a1_facade.log) | `wave_a1_facade: ok`, même pin SDK |
| Sondes livrées (verts) | [a1r_boundary_green.jsonl](../qa/a1r_boundary_green.jsonl), [a1r_frozen_green.jsonl](../qa/a1r_frozen_green.jsonl), [a1_probe_green.jsonl](../qa/a1_probe_green.jsonl) |

Ces 14/14 et la façade sont **attestées par le codeur**, pas revendiquées comme réexécution complète indépendante avec SDK.

### Exécutions indépendantes (revue d’acceptation)

Compilateur Nim 2.4.0 ; **sans SDK factice** ; **0 LLM**. Neuf programmes compilés/exécutés avec succès (les nombres de cas des sondes se recouvrent — ne pas les additionner) :

| Programme | Résultat observé par la revue |
| --- | --- |
| Originaux frozen (SHA `4e1f2c11…c28d249`) | 10/10, exit 0 |
| Originaux boundary (SHA `0c3b3dd0…f1cd27`) | 5/5, exit 0 |
| `a1_independent_probe.nim` livré | 10/10, exit 0 |
| `a1_frozen_previous_probe.nim` livré | 10/10, exit 0 |
| `a1r_boundary_probe.nim` livré | 5/5, exit 0 |
| `tests/f1/test_artifacts.nim` | ok |
| `tests/f3/test_journal.nim` | ok |
| `tests/f4/test_graph.nim` | ok |
| `tests/f17/test_qualification_smoke.nim` | 19 scénarios ; discriminators ok |

Détail et limites : [WAVE_A_1_ACCEPTANCE_REVIEW.md](../qa/WAVE_A_1_ACCEPTANCE_REVIEW.md).  
Les journaux `reviewer_verified_*` de la revue n’ont pas été fournis dans l’upload joint à cette clôture ; l’avis textuel versionné ci-dessus fait foi pour le dépôt.

## Réception obligatoire (conservée)

`scripts/test_wave_a.sh` échoue si un fichier manque ou si le SHA SDK ≠ pin :

- tests F0/F1/F3/F4/F14/F17 (dont `test_a1_r5`, `test_a1_component_probes`)
- `docs/qa/a1_independent_probe.nim`
- `docs/qa/a1_frozen_previous_probe.nim`
- `docs/qa/a1r_boundary_probe.nim`

## Verdicts séparés

| Objet | Verdict de clôture |
| --- | --- |
| **F0** | Réserves A1-R5 levées (périmètre revu) |
| **Composants A** | Réserves A1-R1…R4 levées |
| **M0** | **Requalifié** — avis favorable sur preuves **combinées** codeur (suite+SDK+façade) et indépendantes (neuf programmes sans SDK local) |
| **M1** | **Non atteint** (pas F5 / F16) |

## Limites (inchangées)

- Autorité F14 in-process ; multi-processus non garanti
- F17 : qualification simulée, pas de campagne modèles réels
- Revue d’acceptation : pas une preuve exhaustive de concurrence / panne système
- Vague B : **non commencée** dans cette passe

## Fusion

PR préparée : https://github.com/ThomasValbret/nimfactory/pull/1  
Base acceptée : `2adb183` (contenu `fc3c45e`) ; commits docs de clôture ensuite (`513838d`, `637e0ed`).  
Aucune modification fonctionnelle après acceptation. Merge non exécuté ici ; vague B non ouverte.
