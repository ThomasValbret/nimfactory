# Vague A.1-R — candidat post-contre-revue

Date : 2026-11-18  
Dépôt : https://github.com/ThomasValbret/nimfactory  
Branche : `fix/wave-a1` (**non fusionnée** dans `main`)  
Base contre-revue : `7737c6c93efe991b61c07c7a666f8f70656321c8`  
Révision testée (contenu) :   
Revue : [docs/qa/WAVE_A_1_R_REVIEW.md](../qa/WAVE_A_1_R_REVIEW.md)

## Toolchain / SDK (vérifiés)

| Élément | Valeur |
| --- | --- |
| Nim | 2.4.0 |
| NimAgent | `bf22665ece77d7149dbe61df959a6024bf6b26f3` |
| Pin vérifié | `scripts/test_wave_a.sh` échoue si SHA ≠ pin (`nimagent_pin_verified=yes`) |
| Build | `vendor/NimAgentLibrary` via `scripts/fetch_sdk.sh` |

## Périmètre de cette passe

Uniquement les restes **A1-R1** (F14 identité physique / symlinks) et **A1-R5** (Unicode complet, diagnostics, erreurs).  
F1 / F3 / F4 déjà confirmés : non rouverts. Pas de vague B. Pas de merge.

## Preuves rouge → vert

| Programme | Rouge | Vert |
| --- | --- | --- |
| Frontière A1-R (5 cas) | [a1r_boundary_red.jsonl](../qa/a1r_boundary_red.jsonl) failed=4/5 | [a1r_boundary_green.jsonl](../qa/a1r_boundary_green.jsonl) failed=0/5 |
| Sondes gelées discriminantes (10) | revue `ed2344a` failed=7/10 | [a1r_frozen_green.jsonl](../qa/a1r_frozen_green.jsonl) failed=0/10 |
| Suite + façade | — | [a1r_full_suite.log](../qa/a1r_full_suite.log), [a1_facade.log](../qa/a1_facade.log) |

### Correctifs

| ID | Lot | Correction |
| --- | --- | --- |
| A1-R1 | F14 | Après `createDir`, clé de registre = `expandFilename` (parents symboliques unifiés) |
| A1-R5a | F0 | Décodage `\uXXXX` avec paires de substituts UTF-16, comme `std/json` |
| A1-R5b | F0 | Validation typée de `diagnostics` et `error` ; schéma `error` aligné |

### Preuves de réception (obligatoires)

`scripts/test_wave_a.sh` échoue si un fichier manque. Liste figée :

- tests F0/F1/F3/F4/F14/F17 (dont `test_a1_r5`, `test_a1_component_probes`)
- `docs/qa/a1_independent_probe.nim` (formes discriminantes renforcées)
- `docs/qa/a1_frozen_previous_probe.nim` (équivalent des 10 sondes originales ; provenance documentée en tête de fichier — source reviewer SHA `4e1f2c11…` non fournie dans les uploads)
- `docs/qa/a1r_boundary_probe.nim` (5 cas de frontière)

## Qualification observée (sur contenu commité)

```
./scripts/test_wave_a.sh
# nimagent_pin_verified=yes
# WAVE_A_TESTS_OK count=14 sdk=bf22665ece77d7149dbe61df959a6024bf6b26f3 pin_verified=yes
examples/wave_a1_facade.nim → wave_a1_facade: ok
```

LLM : **0**.

## Verdicts séparés

| Objet | Verdict |
| --- | --- |
| **F0** | Restes A1-R5a/b corrigés et couverts |
| **Composants A** | A1-R1 (F14) corrigé ; F1/F3/F4 inchangés (déjà confirmés) |
| **M0** | **Reste à requalifier** |
| **M1** | **Non atteint** |

## Limites

- Identité F14 physique in-process (symlinks résolus) ; multi-processus non garanti
- Sondes « frozen » : équivalent discriminant, pas le binaire SHA exact du reviewer
- Pas de merge `main`, pas de vague B

## Point d’arrêt

Candidat prêt pour nouvelle revue externe sur `fix/wave-a1`.
