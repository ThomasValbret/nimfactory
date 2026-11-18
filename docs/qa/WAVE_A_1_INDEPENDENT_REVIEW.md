# NimFactory — revue indépendante de A.1

Date : 18 novembre 2026. Candidat : `fix/wave-a1` au commit **ed2344a9de504535ba48f6db91517645338a3f04**.

**Verdict : corrections réelles, mais fusion déconseillée en l'état. La conformité de F0 et des composants A reste à reprendre ; M0 n'est pas requalifié par cette revue. M1 reste non atteint.** Les écarts ci-dessous portent sur les garanties déjà annoncées, sans demander d'ouvrir la vague B.

La revue a utilisé un worktree détaché. Aucun fichier de production modifié, aucun commit, push, merge ou appel fournisseur LLM. Les seuls ajouts sont les preuves locales de revue sous `docs/qa/`.

## Vérifications réellement exécutées

Compilateur : Nim 2.4.0, construit depuis le tag officiel, hash compilateur `14991af742d0833503741fd9a0918133d1bcf8a4`.

| Programme du dépôt, inchangé | Résultat observé |
| --- | --- |
| `tests/f1/test_artifacts.nim` | `test_artifacts: ok` ; inclut son consommateur de rechargement dans un autre processus |
| `tests/f3/test_journal.nim` | `test_journal: ok` |
| `tests/f4/test_graph.nim` | `test_graph: ok` |
| `tests/f17/test_qualification_smoke.nim` | 19 scénarios ; `discriminators=ok fake_preparer_fails=ok` |

Chacun a été compilé et exécuté avec `nim c -r --hints:off --path:src`, un `--nimcache` et un `--out` distincts sous `/tmp`.

La commande `./scripts/test_wave_a.sh` a aussi été tentée : sortie 1, `Set NIMAGENT_SOURCE to a NimAgentLibrary clone`. Le SDK épinglé n'est pas disponible dans cet environnement. Les **10/10 du codeur ne sont donc pas annoncés comme reproduits ici**, et le codec Message/la façade liés au SDK ne sont pas requalifiés indépendamment. Aucun SDK factice n'a été substitué.

Le programme indépendant [a1_independent_probe.nim](a1_independent_probe.nim) importe les modules réels. Il termine avec le code 1 : **7 invariants échouent sur 10 sondes ciblées**. Les trois témoins positifs confirment le rejet d'un doublon JSON littéral, le plafond entre deux handles utilisant exactement le même chemin et le rejet d'un epoch explicitement ancien. Ce décompte décrit ces sondes, pas une mesure de couverture exhaustive.

Sortie complète : [a1_independent_observations.jsonl](a1_independent_observations.jsonl).

## A1-R1 — P1 — F14 : deux écritures du même chemin créent deux autorités

Localisation : [file_ledger.nim, ligne 414](https://github.com/ThomasValbret/nimfactory/blob/ed2344a9de504535ba48f6db91517645338a3f04/src/nimfactory/budget/file_ledger.nim#L414).

Le registre partagé est indexé par la chaîne `ledgerRoot(dbPath)`, sans résolution de l'identité du répertoire. Ouvrir `/tmp/.../alias-budget`, définir un plafond de 100, puis ouvrir `/tmp/..././alias-budget` crée deux objets pour le même stockage. Deux réservations distinctes de 70 sont toutes deux acceptées : **140 autorisés pour 100 disponibles**. Chaque objet croit n'avoir réservé que 70.

Ce défaut est reproduit séquentiellement dans un seul processus ; la limitation documentée sur le multi-processus ne l'explique pas. La correction A.1 fonctionne lorsque les chaînes de chemin sont identiques, ce que le témoin positif confirme.

Attendu : une identité de stockage commune pour chemins équivalents, ou un refus explicite des alias. Tester chemins relatifs/absolus, `.` et, si acceptés, liens symboliques. Le second handle doit voir la première réservation et refuser le dépassement ; vérifier aussi les données après fermeture et réouverture. Aucune exigence de backend distribué n'est ajoutée.

Sondes : `F14_same_path_handles`, `F14_equivalent_path_handles`.

## A1-R2 — P1 — F1 : une capture répétée réinitialise les read sets

Localisation : [snapshot.nim, ligne 76](https://github.com/ThomasValbret/nimfactory/blob/ed2344a9de504535ba48f6db91517645338a3f04/src/nimfactory/artifacts/snapshot.nim#L76), appelée par `capture`.

Reproduction : capturer une source stable ; ajouter la lecture `query-A` (v2) ; recapturer exactement la même requête ; ajouter `query-B`.

La deuxième capture conserve le même `snapshotId`, mais remplace son entrée d'index par le read set initial. Immédiatement après, une nouvelle instance ne retrouve plus l'ancienne v2. L'ajout suivant réutilise son identifiant pour d'autres entrées. Après réouverture, **l'identifiant ancien renvoie `source, query-B`, au lieu de `source, query-A`**.

La chaîne fonctionne pour des ajouts successifs sans recapture ; le défaut restant casse l'immuabilité et la résolution durable dès qu'une capture identique est répétée.

Attendu : décider explicitement si une recapture réutilise le snapshot et sa chaîne ou crée une nouvelle identité de capture/lecture. Dans les deux cas, toute référence déjà publiée doit continuer de résoudre exactement le même contenu. Ne pas écraser l'historique ni réutiliser un ID de read set avec un contenu différent. Tester la recapture puis les lectures anciennes et nouvelles depuis une instance neuve, idéalement un nouveau processus.

Sonde : `F1_recapture_readset_immutability`.

## A1-R3 — P1 — F4 : un cycle peut contourner le contrôleur de boucle

Localisation : [validator.nim, ligne 304](https://github.com/ThomasValbret/nimfactory/blob/ed2344a9de504535ba48f6db91517645338a3f04/src/nimfactory/graph/validator.nim#L304).

`loopCoversScc` considère une composante fortement connexe couverte dès qu'elle contient un nœud `loop` déclaré. Cela ne garantit pas que chacun de ses cycles traverse ce contrôleur.

Le graphe de la sonde contient `loop.body → a.in`, `a.out → b.in`, `b.out → a.next` et `b.out → loop.in`. `a` est un contrôle `sequence`, `b` un passthrough. Les ports sont alimentés sans producteurs ambigus ; la boucle déclare une sortie et une limite de trois itérations. Le validateur répond **`ok`, zéro diagnostic**, alors que le cycle `a → b → a` évite entièrement `loop`.

Attendu : refuser les cycles résiduels qui ne traversent pas le contrôle borné déclaré. Retirer les contrôleurs de boucle et chercher un cycle résiduel est un contrôle nécessaire utile ; vérifier aussi l'adéquation entre les liaisons et la déclaration de boucle. Conserver les fixtures de boucles légitimes. Cette revue démontre une acceptation structurelle incorrecte, pas une exécution infinie observée : F5 n'existe pas encore.

Sonde : `F4_cycle_bypasses_loop_limit`.

## A1-R4 — P1 — F3 : omettre epoch contourne la garde transactionnelle

Localisation : [run_store.nim, ligne 169](https://github.com/ThomasValbret/nimfactory/blob/ed2344a9de504535ba48f6db91517645338a3f04/src/nimfactory/runtime/journal/run_store.nim#L169).

Après `claimLease`, l'epoch courant vaut 2. Une transition inédite contenant activation, tentative, états et outbox mais **aucun champ epoch** est acceptée. Elle change l'état du run et publie une entrée d'outbox. Le code contrôle l'égalité uniquement si le champ existe, puis utilise par défaut 1 pour l'activation.

Le rejet d'un epoch explicitement ancien fonctionne. L'absence d'epoch ne doit pas donner un droit de mutation plus large qu'un epoch ancien.

Attendu : pour toute nouvelle transition d'exécution mutante, exiger un epoch entier valide et comparer au propriétaire courant dans la transaction, avant les écritures. Une opération administrative ou d'initialisation éventuellement exemptée doit avoir un chemin et un contrat explicites. Préserver la retransmission idempotente d'une transition déjà enregistrée. Tester que champ absent, mauvais type et epoch ancien ne modifient ni état ni outbox.

Sondes : `F3_explicit_stale_epoch`, `F3_missing_epoch_mutation`.

## A1-R5 — F0 : validation stricte encore incomplète

### P2 — Comparaison incorrecte des noms de clés JSON échappés

Localisation : [validate.nim, ligne 69](https://github.com/ThomasValbret/nimfactory/blob/ed2344a9de504535ba48f6db91517645338a3f04/src/nimfactory/contracts/validate.nim#L69).

Le scanner ajoute les quatre chiffres de `\uXXXX` à sa clé au lieu de décoder le caractère. Deux contre-exemples exécutés :

- `{"epoch":1,"\u0065poch":2}` est accepté et devient `{"epoch":2}` : le doublon réel a été silencieusement écrasé.
- `{"\u0065":1,"0065":2}` est rejeté comme doublon, alors que ses clés sont `e` et `0065`, donc distinctes.

Attendu : comparer les noms après décodage conforme aux mêmes règles que le parseur JSON, y compris les échappements Unicode. Ne pas introduire de normalisation Unicode supplémentaire qui confondrait d'autres noms distincts. Ajouter les deux fixtures et des variantes imbriquées.

Sondes : `F0_exact_duplicate`, `F0_unicode_duplicate`, `F0_distinct_unicode_keys`.

### P1 — Champs typés imbriqués remplacés par des valeurs par défaut

Localisation : [result.nim, ligne 140](https://github.com/ThomasValbret/nimfactory/blob/ed2344a9de504535ba48f6db91517645338a3f04/src/nimfactory/contracts/result.nim#L140).

Un besoin contenant `"required":"true"` est accepté et devient `required=false`. Une entrée invalide dégrade donc silencieusement le caractère obligatoire du besoin. Les schémas documentaires ne définissent pas non plus les champs des éléments de `needs` et `diagnostics`.

Attendu : valider les champs et types des structures imbriquées, avec obligations, nullabilités et politique de champs inconnus explicites. Aligner schémas JSON et décodeur Nim. Conserver les valeurs par défaut seulement pour les champs effectivement facultatifs, jamais pour masquer un type incorrect.

Sonde : `F0_need_wrong_boolean`.

## Provenance des preuves

Le reçu annonce `0090685d2d67e7ee8cfda05b31897b0b2a751c67` comme révision testée ; le candidat est `ed2344a`. Le diff vérifié entre les deux ne change que le reçu, pas le code. Cela n'est donc pas un blocage fonctionnel : distinguer simplement « révision testée » et « tête de branche » au prochain reçu, sans chercher à écrire le hash d'un commit dans ce même commit.

Par inspection, `scripts/test_wave_a.sh` affiche le SHA du SDK mais ne le compare pas au pin attendu quand `vendor/NimAgentLibrary/src` existe déjà. Avant la prochaine qualification, faire échouer le script en cas de dépendance différente et rendre obligatoires les programmes retenus pour la réception. Aucun résultat d'exécution avec un mauvais SDK n'est revendiqué ici.

## Consigne à transmettre au codeur

Poursuis la correction sur `fix/wave-a1`, sans fusionner ni ouvrir la vague B. Traite A1-R1 à A1-R5 comme des écarts aux garanties déjà promises. Commence par reproduire les contre-exemples, ajoute des assertions de non-régression aux suites des lots et à F17, puis corrige les invariants dans les composants. Ne modifie pas le contrat pour simplement accepter les entrées ou pertes d'historique constatées.

Les sondes indépendantes doivent être réutilisables sans import de la façade et sans SDK factice. Commandes depuis la racine du dépôt, avec Nim 2.4 sur PATH :

```sh
nim c --hints:off --path:src --nimcache:build/a1-review-cache --out:build/a1-review-probe docs/qa/a1_independent_probe.nim
./build/a1-review-probe
```

Sur `ed2344a`, le second programme doit sortir avec le code 1 et sept échecs. Après correction, les dix sondes doivent passer, en plus des tests existants. Le journal JSONL est une observation, pas l'oracle à recopier comme résultat attendu.

Relance ensuite la suite complète et le consommateur de façade avec le véritable SDK `bf22665ece77d7149dbe61df959a6024bf6b26f3`. Livre un nouveau SHA candidat, les preuves rouge/vert des cas concernés, la sortie de qualification, le pin SDK vérifié et un reçu révisé. Sépare les verdicts F0, composants A, M0 et M1. Une PR de revue peut rester ouverte ; la fusion attend la résolution des points ci-dessus.
