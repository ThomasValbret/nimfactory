# Relecture Studio 18c004d — magasin word_tally (1ᵉʳ essai, RO)

Date : 2026-11-24  
Magasin : `/tmp/qual_unknown_067e6a4/word_tally.sqlite` (chmod a-w ; aucun write de commande)  
Studio : tip `18c004d50d8823034b81e19b46b316689d205360` · binaire sha256 `1706754d0470dc58fc6b5c963cd60f71461d4f9e0c028ed70013221ea8d34c95`  
Arbres : `--trees /tmp/qual_unknown_067e6a4/art/trees`

## HTTP / projection

| | |
| --- | --- |
| `GET /api/snapshot` | **HTTP 200** (6807 octets) |
| `GET /` | HTTP 200 |
| Étape acceptée | `step1` — « Création du fichier de script principal tally.py » · status `done` |
| Étape affichée (active) | `step2` — « Ajout de la logique… » · status `pending` |
| Empreinte acceptée | `AAB37878B03070F9` |
| Empreinte recalculée (`served_tree.hash`) | `AAB37878B03070F9` |
| `matches_accepted` / `preview_tree_match` | **true** |
| Fichiers servis | `tally.py` (file_count=1) |

Premier essai **conservé tel quel** (pas de resume / revise / repair).

## Artefacts d’origine (disponibles)

### Plan v1 — `final_criteria`

1. Le fichier tally.py existe et est exécutable.
2. tally.py lit un fichier texte passé en argument.
3. tally.py affiche correctement le nombre de lignes, de mots et de caractères.

Critère d’étape acceptée (`step1`) : *« Le fichier tally.py est créé et contient un squelette de fonction principale. »* · contrôle moteur : `file_exists:tally.py` seulement.

### Mandat implémenteur (mandate_v1)

- Goal : outil Python lignes/mots/caractères.
- Constraints : pas de bibliothèques externes ; conventions Python.
- `final_criteria` : identiques au plan (pas de mention « une seule ligne » / « séparés par des espaces »).
- `agents_md_excerpt` : vide · `source_ids` : [].

## Atteinte de la contrainte « sur une seule ligne, séparés par des espaces »

**Non.** Elle figure dans l’objectif utilisateur du magasin, mais **n’apparaît ni dans les critères du plan v1, ni dans le mandat, ni dans la vérification de l’étape acceptée** (seul `file_exists:tally.py`). L’arbre accepté peut donc contenir une sortie multi-lignes libellée sans violer le critère de step1.
