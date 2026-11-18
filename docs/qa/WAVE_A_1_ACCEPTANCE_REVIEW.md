# NimFactory — clôture de la revue corrective A.1

Date : 18 novembre 2026.

**Avis favorable à la clôture d'A.1 et à la requalification de M0 sur le candidat examiné. Les réserves A1-R1 à A1-R5 de cette revue sont levées. M1 reste non atteint.** Cet avis repose sur les exécutions indépendantes ci-dessous, la lecture des corrections et les preuves d'intégration versionnées du codeur ; il ne prétend pas reproduire localement toute la suite avec le SDK.

## Révisions et périmètre

- Candidat : `2adb183001fe66110b67e48e56503403699f7d5c`, branche `fix/wave-a1`.
- Contenu fonctionnel testé par le codeur : `fc3c45e8661aae00c30c9243972cacdfd577e3bc`.
- Diff entre ces révisions vérifié : uniquement reçu et journal de qualification ; aucun changement de source, tests, schémas, scripts, exemple ou configuration de build.
- Revue limitée à la clôture des constats précédents et à leurs régressions. Aucun nouvel audit général ni aucune ouverture de la vague B.
- Aucun code de production modifié, aucun commit, push ou merge effectué. Les nouveaux fichiers locaux sous `docs/qa/` sont des preuves de revue non publiées sur GitHub.

## Exécutions indépendantes

Compilateur utilisé : Nim 2.4.0, hash compilateur `14991af742d0833503741fd9a0918133d1bcf8a4`.

| Programme | Résultat réellement observé |
| --- | --- |
| Sondes originales de la première contre-revue, copiées sans modification | 10/10, exit 0 |
| Sondes originales de frontière, copiées sans modification | 5/5, exit 0 |
| `docs/qa/a1_independent_probe.nim` livré | 10/10, exit 0 |
| `docs/qa/a1_frozen_previous_probe.nim` livré | 10/10, exit 0 |
| `docs/qa/a1r_boundary_probe.nim` livré | 5/5, exit 0 ; inclut persistance du plafond après réouverture par le lien symbolique |
| `tests/f1/test_artifacts.nim` | `test_artifacts: ok` |
| `tests/f3/test_journal.nim` | `test_journal: ok` |
| `tests/f4/test_graph.nim` | `test_graph: ok` |
| `tests/f17/test_qualification_smoke.nim` | 19 scénarios ; `discriminators=ok fake_preparer_fails=ok` |

Soit neuf programmes compilés et exécutés avec succès. Les sondes se recouvrent : leurs nombres de cas ne doivent pas être additionnés pour annoncer une couverture indépendante plus large.

Les deux originaux sont conservés sous :

- `reviewer_original_frozen.nim` — SHA-256 `4e1f2c11a136941b0f73bb661626db3eb7da4299dcc88e6d86c22c1a8c28d249`.
- `reviewer_original_boundary.nim` — SHA-256 `0c3b3dd010ba5fd95bd37093f8263c8a33d50949a49b89e8f0f336f2ebf1cd27`.

Les sorties de cette revue sont les neuf fichiers `reviewer_verified_*.jsonl` / `reviewer_verified_*.log` joints. Les empreintes des originaux et les résumés des sorties ont été vérifiés.

Chaque programme a été compilé avec `nim c --hints:off --path:src`, cache et exécutable distincts sous `/tmp`, puis exécuté depuis la racine du candidat. Le PATH de compilation et d'exécution utilisait le compilateur Nim 2.4.0 ci-dessus. Aucun SDK factice ni appel fournisseur LLM.

## Clôture des constats

| Constat | Conclusion |
| --- | --- |
| A1-R1 — identité F14 | Le chemin du répertoire existant est résolu par `expandFilename`. Deux handles ouverts par le chemin réel et un parent symbolique partagent l'autorité. La seconde réservation de 70 est refusée sous plafond 100 ; après réouverture, 70 restent réservés et le plafond tient. |
| A1-R2 — recapture F1 | La sonde originale confirme la conservation de l'ancien read set et l'absence de réutilisation de son ID pour un autre contenu. Pas de modification supplémentaire de F1 dans cette passe. |
| A1-R3 — cycle F4 | Le graphe original avec déclaration de boucle valide et cycle résiduel est refusé. Les sondes livrées renforcent aussi le contrôle du diagnostic de cycle. Pas de modification supplémentaire de F4. |
| A1-R4 — epoch F3 | La transition mutante sans epoch est refusée ; état et outbox restent inchangés dans la sonde originale. Pas de modification supplémentaire de F3. |
| A1-R5a — Unicode | Le doublon entre caractère littéral et paire de substituts est refusé ; la clé valide encodée par une seule paire est conservée. Les doublons simples restent refusés. |
| A1-R5b — structures imbriquées | Les diagnostics mal typés et `error.retryable` mal typé sont rejetés. Les contrôles de types et de champs inconnus ont été complétés ; le schéma `error` décrit les mêmes champs. |

Les trois restes signalés lors de la revue de `7737c6c` sont donc corrigés sur les cas reproduits. Aucun blocage restant n'a été identifié dans ce périmètre de contre-revue.

## Preuves d'intégration du codeur et limites de la revue

Le journal versionné `docs/qa/a1r_full_suite.log` identifie maintenant le contenu `fc3c45e8661aae00c30c9243972cacdfd577e3bc`, le véritable SDK `bf22665ece77d7149dbe61df959a6024bf6b26f3`, `nimagent_pin_verified=yes` et `WAVE_A_TESTS_OK count=14`. Le journal de façade indique `wave_a1_facade: ok` et le même pin SDK.

Ces fichiers ont été lus et rapprochés du reçu et du script. Les 14/14 et la façade restent **des exécutions attestées par le codeur**, pas une réexécution complète indépendante : le SDK épinglé demeure absent de cet environnement. Les tests liés au SDK n'ont pas été remplacés par des doublures pour produire un résultat artificiel.

Par lecture, `scripts/test_wave_a.sh` vérifie l'égalité du SHA SDK et du pin attendu. Les onze programmes de test et les trois programmes de sondes sont désormais tous obligatoires ; un fichier manquant produit un échec. Les différences entre les sondes originales et les reconstructions du dépôt sont signalées dans leur provenance. Les originaux ont été exécutés séparément dans cette revue, ce qui évite de fonder l'avis uniquement sur ces reconstructions.

Cet avis ne constitue pas une preuve exhaustive de concurrence, de panne système ou de fonctionnement multi-processus. La limite documentée du ledger à une autorité dans le processus reste applicable. F17 reste une qualification simulée, sans campagne de modèles réels.

## Verdict et suite proposée

| Objet | Avis de revue |
| --- | --- |
| F0 | Réserves A1-R5 levées dans le périmètre revu |
| Composants A | Réserves A1-R1 à R4 levées ; pas de réouverture des constats déjà corrigés |
| M0 | Avis favorable à la requalification, sur preuves combinées du codeur et de cette revue |
| M1 | Non atteint : exécuteur F5 et CLI F16 encore absents |
| Fusion | Plus de blocage issu de cette revue pour proposer la fusion du candidat ; aucune fusion effectuée ici |

Consigne de clôture proposée : joindre cet avis et ses preuves à la PR, mettre à jour le reçu avec l'avis favorable sur M0 et conserver la distinction entre tests du codeur et exécutions indépendantes. Garder les tests de réception obligatoires et le SDK épinglé. Préparer la fusion d'A.1 sans commencer la vague B dans cette même passe. Une modification fonctionnelle ultérieure sortirait du candidat accepté et devrait être qualifiée selon son périmètre.
