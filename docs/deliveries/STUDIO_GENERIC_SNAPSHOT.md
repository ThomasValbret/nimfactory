# Studio ouvre les projets en pause après une étape générique

Le défaut est reproduit sur `49ba135` avec un projet public. La première étape de `fixtures/notice_then_hello` crée NOTICE.txt en route inject et termine en `paused_after_step`. Studio lit le magasin SQLite au démarrage. La projection déréférençait le champ facultatif `observation` alors que le contrôle générique conserve son texte dans `observations`. Le processus quittait avec le signal 11 avant de servir sa première requête HTTP.

La projection lit les observations textuelles du moteur et conserve les observations structurées de l’adaptateur loan. Les anciens reçus dépourvus de contrôles nommés conservent leur affichage de compilation. La lecture est en transaction SQLite sans écriture.

| Projet ouvert par le binaire Studio corrigé | Résultat de GET /api/snapshot |
| --- | --- |
| NOTICE en pause après la première étape | HTTP 200, contrôle réussi, message « target present: NOTICE.txt », empreintes acceptée et recalculée `DAC9A1919AEA732A` |
| NOTICE puis hello, projet terminé | HTTP 200, sortie « bonjour », empreinte recalculée du dernier arbre `3693D81F78C47C1E` égale à celle acceptée |
| Programme générique avec vérification en échec | HTTP 200, échec de `program_runs` lisible, aucun arbre accepté |

Les tests `tests/studio/test_project_view.nim` et `tests/studio/test_project_command.nim` passent avec Nim 2.4.0. Pour rejouer le cas HTTP, créer un magasin via `project run` avec la fixture publique et `--pause-after-step`, puis ouvrir ce même magasin avec `nimfactory-studio --store … --project-id … --trees …/artifacts/trees`. Les vérifications ci-dessus ont été faites sur des magasins locaux en injection, sans appel API. Le magasin privé du premier essai word_tally reste chez l’évaluateur.

## Contre-épreuve du moteur sur une entrée en argument

La mission publique indépendante demande que longueur.py lise un fichier texte donné en argument et affiche sa longueur. Le plan injecté demande `file_exists:longueur.py` et `program_runs`. Deux fichiers contenant respectivement quatre et six caractères sont placés hors de l’arbre candidat.

| Candidat injecté | Depuis le terminal, avec les deux fichiers | Verdict du moteur |
| --- | --- | --- |
| Programme lisant le fichier passé en argument | 4 puis 6 | `verify_failed`, lancement sans argument |
| Programme écrivant la constante 4 | 4 puis 4 | `done`, sortie 4 et code 0 |

Cette contre-épreuve utilise deux programmes publics et un plan imposé. Le premier essai word_tally utilisait le modèle et s’est arrêté en pause après la première étape. Le besoin moteur à instruire est la conservation de l’entrée de test, de l’invocation et de la sortie attendue entre le plan, la vérification et le recontrôle de l’arbre.
