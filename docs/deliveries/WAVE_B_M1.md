# Vague B — premier parcours M1

Date : 2026-11-18  
Dépôt : https://github.com/ThomasValbret/nimfactory  
Branche : `feature/wave-b-m1`  
Base : `ae331bd57f7db6cbfdde8d02a74e6b819be7e872`  
Révision testée (contenu) : renseignée après commit  
SDK : `bf22665ece77d7149dbe61df959a6024bf6b26f3` (`pin_verified=yes`)

## Objectif

Depuis la CLI : valider puis exécuter un graphe déterministe, interrompre à un commit durable, reprendre dans un second processus, obtenir le même résultat qu’en continu ; activations validées non relancées.

## Lots

| Lot | Reçu | État |
| --- | --- | --- |
| F5 | [F5.md](F5.md) | Livré |
| F16 | [F16.md](F16.md) | Livré |
| F17 (M1) | [F17.md](F17.md) | Extension M1 livrée |

## Commandes exécutées

```bash
./scripts/test_wave_a.sh
# WAVE_A_TESTS_OK count=14 sdk=bf22665… pin_verified=yes

./scripts/test_wave_b_m1.sh
# WAVE_B_M1_OK count=4 sdk=bf22665… pin_verified=yes

./scripts/m1_resume_recipe.sh
# M1_RESUME_RECIPE_OK
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
| **M1** | **Atteint** — recette CLI interruption/reprise 2 processus OK |
| Vague B complète (F2/F13) | Non — hors de cette passe |

LLM : **0**.
