# Revue de la vague A — NimFactory

Date : 17 novembre 2026  
Dépôt : https://github.com/ThomasValbret/nimFactory  
Révision inspectée : `1e825005bcad9e046157f71c01bd6d4ac07ef288` — `Initial commit: NimFactory F0 and wave A.`  
Nature : revue indépendante du code et contre-exemples locaux. Aucun code de production modifié, aucun commit ni push effectué.

## Conclusion

**La vague A contient des briques utilisables, mais sa conformité globale n'est pas acquise. Une passe corrective A.1 est nécessaire avant de raccorder la vague B.**

Le statut « M0 atteint » doit être requalifié : les validateurs exécutés n'appliquent pas plusieurs contraintes des schémas publiés. M1 reste partiel, comme annoncé.

Les huit programmes de tests annoncés ne constituent pas huit garanties exhaustives. Deux ont été réexécutés ici, avec succès : F4 et F17. Des sondes séparées reproduisent quinze observations problématiques ou limites d'intégration sur les composants réels, sans SDK simulé.

## Périmètre et méthode

- Lecture de `AGENTS.md`, de l'architecture et des contrats pertinents ; inspection des reçus F0, F3, F14, du reçu WAVE_A, des ADR et du code F0/F1/F3/F4/F14/F17.
- Clone propre de la révision indiquée. Le dépôt était propre avant la création des seuls fichiers de cette revue.
- Compilateur **Nim 2.4.0**, construit depuis le tag officiel `nim-lang/Nim@v2.4.0`, commit `14991af742d0833503741fd9a0918133d1bcf8a4`, bootstrap achevé.
- Import direct des modules de production. Aucun faux module NimAgent ni remplacement des implémentations testées.
- SDK `bf22665ece77d7149dbe61df959a6024bf6b26f3` non récupérable via le transport Git disponible : une authentification est demandée. Les tests dépendant de la façade et de ce SDK n'ont donc pas été réexécutés.
- Aucun appel à un fournisseur de modèle. Les montants utilisés dans les sondes sont des données locales fictives.

## R1 — P1 — Les plafonds F14 peuvent être dépassés ou perdre leur réservation

Sources : [file_ledger.nim](https://github.com/ThomasValbret/nimFactory/blob/1e825005bcad9e046157f71c01bd6d4ac07ef288/src/nimfactory/budget/file_ledger.nim#L217), [ouverture du ledger](https://github.com/ThomasValbret/nimFactory/blob/1e825005bcad9e046157f71c01bd6d4ac07ef288/src/nimfactory/budget/file_ledger.nim#L44), [types.nim](https://github.com/ThomasValbret/nimFactory/blob/1e825005bcad9e046157f71c01bd6d4ac07ef288/src/nimfactory/budget/types.nim#L28).

### Observations exécutées

1. Avec un plafond de 100 micro-USD, une réservation de **−50** est acceptée, puis une réservation de **120** est acceptée. L'état affiche seulement 70 réservés.
2. Avec un maximum de deux envois, une réservation de **−3 envois** est acceptée, puis une réservation de cinq envois l'est également.
3. Deux handles ouverts sur le même répertoire, dans **le même processus**, autorisent chacun 70 pour un plafond de 100. Total autorisé : **140** ; le dernier snapshot conserve seulement 70. Il n'est pas nécessaire d'utiliser plusieurs processus pour observer le défaut.
4. Après une erreur de persistance provoquée sur `state.json.tmp`, un retry de la même tentative retourne `reserved`, alors qu'une réouverture retrouve **zéro réservation**.
5. Réutiliser un identifiant de tentative avec un montant différent retourne silencieusement la réservation précédente : une demande de 90 peut recevoir une réservation de 10 sans conflit signalé.

### Cause et conséquence

Le verrou est propre à chaque objet, qui garde un état mémoire indépendant. Les montants et nombres d'envois ne sont pas validés comme non négatifs. La mémoire est modifiée avant la persistance ; le retour idempotent peut ensuite éviter toute nouvelle écriture. Le journal append-only n'est pas relu par l'ouverture du ledger.

Le broker F13 ne peut pas s'appuyer sur ces opérations pour garantir un plafond partagé.

### Correction attendue

Valider domaines numériques et débordements ; identifier et refuser les reprises idempotentes contradictoires ; garantir une autorité unique par stockage et des mutations transactionnelles. Une seconde ouverture doit partager une autorité cohérente ou être refusée explicitement. Une erreur d'écriture ne doit laisser aucune réservation utilisable mais non durable.

Si le fichier journal est autoritatif, implémenter sa reprise ; sinon documenter l'autorité réelle du snapshot et assurer sa cohérence avec les retours API. Le choix SQLite ou fichiers reste une décision de backend, pas un remplacement des garanties.

Réception : valeurs négatives rejetées sans mutation ; deux handles ne dépassant pas le plafond ; panne d'écriture puis retry/reprise ; conflit d'idempotence ; tests existants de coûts inconnus conservés.

## R2 — P1 — F3 accepte une transition d'un ancien propriétaire

Source : [run_store.nim — commitTransition](https://github.com/ThomasValbret/nimFactory/blob/1e825005bcad9e046157f71c01bd6d4ac07ef288/src/nimfactory/runtime/journal/run_store.nim#L128).

### Observation exécutée

Créer un run à l'epoch 1, reprendre le bail à l'epoch 2, puis appeler `commitTransition` avec l'epoch 1 :

- l'appel réussit ;
- l'ancien état remplace l'état courant ;
- un nouveau message est ajouté à l'outbox.

La garde de `appendEvent` / `acceptHandlerDelivery` ne protège pas le chemin de mutation `commitTransition`.

### Correction attendue

Vérifier le propriétaire/epoch attendu dans la transaction qui modifie l'état et publie l'outbox. La vérification et l'écriture doivent être atomiques vis-à-vis d'une reprise. Un epoch manquant, obsolète ou non autorisé ne doit pas produire de mutation. Les relectures idempotentes déjà validées doivent avoir une sémantique explicite.

Réception : exactement le contre-exemple ci-dessus, puis course entre reprise et commit ; aucun nouvel état, événement ou message pour une transition refusée.

## R3 — P1 — F4 valide des graphes incomplets ou cycliques non bornés

Source : [validator.nim](https://github.com/ThomasValbret/nimFactory/blob/1e825005bcad9e046157f71c01bd6d4ac07ef288/src/nimfactory/graph/validator.nim#L252).

### Observations exécutées

- Un unique nœud `seed.assemble@0.1`, sans aucune entrée et sans aucune arête, est accepté avec statut `ok`, alors que ses quatre ports d'entrée sont requis.
- Un cycle ordinaire `a → b → a` est accepté dès qu'une boucle explicite valide existe dans une autre partie du graphe.

### Cause et conséquence

Le validateur vérifie les arêtes présentes, sans vérifier que tous les ports requis sont alimentés. La détection de cycle cherche seulement l'existence globale d'un nœud loop et d'une spécification de boucle ; elle ne vérifie pas que le cycle détecté appartient à cette boucle.

F5 pourrait recevoir comme exécutable un graphe impossible à démarrer ou contenant un cycle hors de toute borne déclarée.

### Correction attendue

Vérifier la satisfaction structurelle des ports requis et la couverture de chaque cycle par une structure de boucle précisément identifiée. Définir les règles pour plusieurs producteurs, branches conditionnelles et joins ; rejeter les structures non supportées.

Réception : ports requis absents ; cycle parasite à côté d'une boucle valide ; plusieurs cycles dont un seul déclaré ; graphes valides existants conservés.

## R4 — P1 — F1 perd des dépendances et réutilise l'identité de snapshots différents

Source : [snapshot.nim](https://github.com/ThomasValbret/nimFactory/blob/1e825005bcad9e046157f71c01bd6d4ac07ef288/src/nimfactory/artifacts/snapshot.nim#L46), [appendRead](https://github.com/ThomasValbret/nimFactory/blob/1e825005bcad9e046157f71c01bd6d4ac07ef288/src/nimfactory/artifacts/snapshot.nim#L102).

### Observations exécutées

- Deux appels successifs à `appendRead` produisent tous deux une version 2 avec le même identifiant. Le deuxième résultat conserve la source initiale et la seconde lecture, mais perd la première lecture ajoutée.
- Changer recette et version d'index sans modifier les octets sources produit le même `snapshotId`. Recharger l'ancien identifiant renvoie alors la nouvelle recette.
- Une nouvelle instance de `LocalSnapshotSource` ne sait pas recharger ce snapshot par son identifiant : les tables servant à cette opération sont seulement en mémoire.

### Cause et conséquence

`appendRead` repart toujours du read set initial. L'identité du snapshot ignore notamment les recettes, les index et les identifiants des sources. Les blobs sont conservés, mais cela ne suffit pas à rendre la résolution par identifiant durable.

F2, F11 et F15 hériteraient de dépendances perdues ou ambiguës : une modification pertinente pourrait ne plus invalider la préparation concernée.

### Correction attendue

Conserver des versions immuables cumulatives de read set, avec résolution explicite de la version précédente/courante. Calculer une identité couvrant les dépendances pertinentes selon le codec canonique convenu, sans champs volatils. Assurer une résolution durable, par artefact ou index versionné, qui ne remplace pas le sens d'une référence déjà délivrée.

Réception : trois ajouts successifs ; changement isolé de recette, d'index et d'identité de source ; ancien snapshot inchangé ; rechargement après nouvelle instance et nouveau processus.

## R5 — P1 — F0 n'applique pas les contraintes de ses propres schémas

Sources : [meta.nim](https://github.com/ThomasValbret/nimFactory/blob/1e825005bcad9e046157f71c01bd6d4ac07ef288/src/nimfactory/contracts/meta.nim#L76), [result.nim](https://github.com/ThomasValbret/nimFactory/blob/1e825005bcad9e046157f71c01bd6d4ac07ef288/src/nimfactory/contracts/result.nim#L117), [validate.nim](https://github.com/ThomasValbret/nimFactory/blob/1e825005bcad9e046157f71c01bd6d4ac07ef288/src/nimfactory/contracts/validate.nim#L24).

### Observations exécutées

- `metaFromJson({"schema":"nimfactory.meta/0.1"})` est accepté ; les identifiants obligatoires deviennent des chaînes vides.
- Un résultat sans statut, avec `outputs: 17` et une fonctionnalité inconnue est accepté : il devient **`ok`**, avec un entier à la place de l'objet des sorties.
- `parseJsonStrict` accepte `{"epoch":1,"epoch":2}` et conserve seulement la seconde valeur.

Les schémas publiés déclarent pourtant des champs requis, des types et `additionalProperties: false`. La conversion en objets Nim n'en constitue pas une validation complète.

### Correction attendue

Valider présence, types, nullabilité, domaines et champs inconnus avant toute conversion. Ne pas remplacer un statut absent par un succès. Rejeter les clés dupliquées au parsing, avant qu'une structure JSON les ait écrasées. Exécuter les mêmes fixtures négatives sur tous les chemins publics de désérialisation concernés.

Réception : matrice des champs requis et des types invalides, valeurs nulles, champs inconnus, versions/features, doublons JSON et cohérence enveloppe/payload.

## Points complémentaires

### F3 — Reprise de l'outbox à préciser

Après `publishPending`, fermeture sans acquittement puis réouverture, `recover` expose un message dans `outbox_pending`, mais `publishPending` retourne une liste vide. Le message n'est pas perdu dans le stockage ; il reste au statut `publishing`.

Le contrat avec F5 doit fournir un chemin explicite de redistribution des messages non acquittés : réarmement, réservation temporaire, ou consommation du résultat de `recover` avec sémantique documentée. Ne pas laisser supposer que rappeler `publishPending` suffit.

### F3 — Entrée incomplète provoquant un crash natif

Pendant la préparation des sondes, une transition contenant `activation_id` et `attempt_id`, mais pas `activation_state` / `attempt_state`, a provoqué un **SIGSEGV** à la ligne 150 de `run_store.nim` lors de la sérialisation d'un JsonNode nil. Le reçu F3 présente lui-même un exemple omettant ces champs.

Le rejeu principal ajoute explicitement ces deux objets pour isoler le défaut d'epoch. Prévoir un rejet typé ou une valeur absente correctement représentée, jamais un crash du processus.

### Packaging et preuves

- Le pin du SDK est documentaire : `requires nimagent >= 0.2.0` et des chemins `/opt/...` n'imposent pas son commit. Fournir une procédure de résolution reproductible et vérifier la révision réellement chargée.
- `nimble test` ne lance que F0 ; `testwavea` lance F1/F3/F4/F14/F17 sans F0. Le README donne bien une boucle des huit programmes, mais le reçu WAVE_A ne contient pas leur sortie. Prévoir une commande globale unique, des sorties conservées et un reçu lié au SHA.
- `SqliteBudgetLedger` est un alias de `FileBudgetLedger`. L'ADR l'indique, mais l'API reste trompeuse sur le backend ; utiliser un nom conforme ou un constructeur abstrait avec capacités déclarées.
- F17 est bien un début de banc : ses fixtures/oracles simulés ne qualifient pas les raccordements de production ni les modèles réels. Ce périmètre est correctement annoncé.
- Le type `Message` est importé du SDK ; aucun second type Message n'a été trouvé. L'adaptateur de sérialisation étendu est centralisé. Son équivalence exacte au SDK épinglé n'a pas été requalifiée ici.

## Exécutions et preuves

Fichiers joints :

- [Sondes de reproduction](review_probe.nim)
- [Observations brutes JSONL](review_observations.jsonl)

Le programme de sondes **affiche le comportement observé** et termine à zéro quand il a parcouru les cas. Son code de sortie n'est pas un verdict de conformité. Les quinze lignes JSONL doivent être comparées aux exigences décrites ci-dessus.

Les deux tests existants exécutés sans modification :

```text
test_graph: ok

F17 qualification smoke (mode=simulated, no LLM)
scenarios=14 discriminators=ok fake_preparer_fails=ok
test_qualification_smoke: ok
```

Commandes reproduisibles depuis la racine du dépôt, avec Nim 2.4.0 disponible sur PATH :

```sh
nim c -r --hints:off --warnings:off --skipUserCfg --skipParentCfg --path:src --nimcache:/tmp/nf-review-f4-cache --out:/tmp/nf-review-f4 tests/f4/test_graph.nim
nim c -r --hints:off --warnings:off --skipUserCfg --skipParentCfg --path:src --nimcache:/tmp/nf-review-f17-cache --out:/tmp/nf-review-f17 tests/f17/test_qualification_smoke.nim
nim c -r --hints:off --warnings:off --skipUserCfg --skipParentCfg --path:src --nimcache:/tmp/nf-review-probe-cache --out:/tmp/nf-review-probe docs/qa/review_probe.nim
```

Les exécutions de cette revue ont utilisé le chemin absolu du compilateur construit et des caches distincts. Les tests F0/F1/F3/F14 d'origine, dépendant de la façade, ne sont pas présentés comme réexécutés. Les sondes importent directement leurs composants réels et vérifient certains comportements qui leur manquaient.

## Passe corrective A.1 recommandée

Conserver les identifiants de lots. Réouvrir les obligations concernées de F0, F1, F3, F4 et F14 ; poursuivre F17 sur ces contre-exemples.

L'intégrateur :

1. fixe une base versionnée et la résolution exacte du SDK ;
2. coordonne les adaptations nécessaires des contrats communs ;
3. fait convertir les sondes en tests de non-régression qui exigent le comportement corrigé ;
4. fait vérifier les corrections par F17 indépendamment de leurs auteurs ;
5. relance les huit programmes, les cas ajoutés, un consommateur externe et les contrôles de reprise appropriés ;
6. publie un reçu A.1 distinguant résultats observés, limites et SHA testé.

Les cas de concurrence et de reprise doivent inclure les ouvertures séparées et les interruptions pertinentes, au-delà de simples hooks qui lèvent une exception.

La vague B pourra alors s'appuyer sur des garanties vérifiées. Des travaux de conception peuvent continuer sur les ports, mais ne pas déclarer leur intégration qualifiée sur les comportements défectueux.

