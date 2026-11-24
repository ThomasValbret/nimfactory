# Reprendre un projet après une vérification en échec

Base moteur `1503725590595440b5ed59d36d4971e085394f7c`. Contre-épreuve publique en injection avec Nim 2.4.0, zéro appel API. La syntaxe CLI et le format des reçus sont conservés.

Le plan demande un programme qui affiche « bonjour ». Une première proposition écrit un programme qui lève une exception. La seconde écrit le programme demandé. Chaque ligne du tableau correspond à un processus CLI distinct. Les trois commandes utilisent la même base SQLite, le même projet et la même racine `--worktree`.

| Commande | Base publiée recompilée | Avec le correctif |
| --- | --- | --- |
| Première tentative | `verify_failed`, un candidat sur disque | `verify_failed`, un candidat sur disque |
| Même identifiant après remplacement de la proposition | `replayed=true`, un candidat | `replayed=true`, un candidat |
| Nouvel identifiant avec la proposition corrigée | `apply_failed`, chemin déjà occupé | `done`, deux répertoires, premier programme conservé |

Le compteur d’étapes repartait de un à chaque invocation. Pour `project run`, l’applicateur réserve désormais un nouveau sous-répertoire au moment d’appliquer une proposition. L’essai et sa réparation disposent chacun d’un chemin propre. La commande directe qui reçoit un chemin exact occupé conserve son refus. La régression contrôle aussi le contenu du fichier dans l’arbre accepté.

Depuis la racine du dépôt, avec Nim 2.4.0 dans le PATH et le SDK à l’emplacement configuré par le projet, lancer les contrôles suivants.

```bash
nim c -r --path:src tests/project/test_project_run_regressions.nim
nim c -r --path:src tests/mission/test_intervention_bench.nim
nim c -r --path:src tests/project/test_loan_adapter.nim
python3 -m unittest tests.project.test_loan_oracle -v
```

Ces contrôles couvrent la reprise et les témoins publics. La vérification du chemin attendu par `file_exists`, le diagnostic de `missing_edits` et la qualification d’un nouveau binaire en transfert restent des travaux distincts.
