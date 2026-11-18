# NimFactory — contre-revue du candidat 7737c6c

18 novembre 2026. Branche `fix/wave-a1`.

- Candidat inspecté : `7737c6c93efe991b61c07c7a666f8f70656321c8`.
- Commit fonctionnel : `e401448f22ae4e9f43923a06cbe4f35fcce44648`.
- Le diff entre ces deux commits ne touche que le reçu.
- Aucun fichier de production modifié, aucun commit, push, merge ou appel fournisseur LLM pendant cette revue. Les ajouts locaux sous `docs/qa/` sont les preuves de revue, non publiées sur GitHub.

**Verdict : les dix contre-exemples/témoins originaux passent désormais, mais la fusion reste déconseillée pour deux domaines encore incomplets : identité du stockage F14 et validation F0. M0 reste à requalifier.**

## Ce qui est confirmé

Les sondes originales de la revue `ed2344a` ont été recopiées **sans aucune modification** sous `a1_frozen_previous_probe.nim`. Leur SHA-256, identique à celui de l'original conservé, est `4e1f2c11a136941b0f73bb661626db3eb7da4299dcc88e6d86c22c1a8c28d249`.

Sous Nim 2.4.0, leur compilation contre les modules de `7737c6c` puis leur exécution produisent **failed=0/10, exit 0**. Le binaire conservé de la revue précédente, compilé contre `ed2344a`, reproduit **failed=7/10, exit 1**. Les sorties sont dans `a1r_frozen_red.jsonl` et `a1r_frozen_green.jsonl`.

| Point précédent | Conclusion ciblée |
| --- | --- |
| A1-R1 — handles F14 utilisant `.` | Correction confirmée pour les alias lexicaux testés ; liens symboliques encore en défaut ci-dessous |
| A1-R2 — recapture F1 | Correction confirmée : ancien read set conservé, ID non réutilisé pour un autre contenu |
| A1-R3 — cycle contournant loop | Correction confirmée sur le graphe original, doté d'une déclaration de boucle valide |
| A1-R4 — epoch F3 omis | Correction confirmée : rejet, état et outbox inchangés dans la sonde originale |
| A1-R5 — doublons Unicode simples et `need.required` mal typé | Cas originaux corrigés ; décodage Unicode complet et autres structures typées encore incomplets |

Les quatre programmes existants, inchangés, passent aussi : `tests/f1/test_artifacts.nim`, `tests/f3/test_journal.nim`, `tests/f4/test_graph.nim` et `tests/f17/test_qualification_smoke.nim` (19 scénarios). Chaque programme a été compilé/exécuté avec `nim c -r --hints:off --path:src`, caches et exécutables distincts sous `/tmp`.

La suite complète a été tentée et s'arrête avec `Set NIMAGENT_SOURCE to a NimAgentLibrary clone`, exit 1. Une lecture Git du SDK distant a également échoué faute d'identification disponible. Les **12/12 et la façade sont donc les preuves rapportées par le codeur, pas des exécutions indépendantes revendiquées ici**. Aucun SDK de substitution n'a été utilisé. Le contrôle d'égalité SHA/pin ajouté au script est bien présent, vérifié par lecture.

## Reste A1-R1 — P1 — F14 accepte deux chemins symboliques du même stockage

Code : [file_ledger.nim, ligne 70](https://github.com/ThomasValbret/nimfactory/blob/7737c6c93efe991b61c07c7a666f8f70656321c8/src/nimfactory/budget/file_ledger.nim#L70).

`absolutePath(normalizedPath(...))` résout la forme textuelle du chemin, mais pas les liens symboliques. Le registre crée donc encore deux autorités en mémoire pour un répertoire physique unique.

Reproduction exécutée, dans un seul processus : créer un répertoire `real`, puis `alias` comme lien symbolique vers `real` ; ouvrir le ledger par `real/book`, définir un plafond de 100 ; ouvrir le second handle par `alias/book` **avant** la première réservation ; réserver 70 par chacun des deux handles.

Résultat : le lien est accepté et les deux réservations aussi, soit **140 autorisés pour un plafond de 100**. Ce n'est pas un problème de multi-processus et la restriction documentée sur celui-ci ne couvre pas ce cas.

Attendu : unifier l'identité du répertoire effectivement ouvert, liens symboliques des parents compris, ou refuser explicitement ces chemins avant d'autoriser des opérations. Le précédent rapport demandait déjà de couvrir les liens symboliques s'ils étaient acceptés. Tester deux handles ouverts avant les écritures, puis vérifier la persistance après réouverture.

Sonde : `F14_symlink_same_storage` dans `a1r_boundary_probe.nim`.

## Reste A1-R5a — P2 — les paires de substituts Unicode échappent au contrôle des doublons

Code : [validate.nim, ligne 69](https://github.com/ThomasValbret/nimfactory/blob/7737c6c93efe991b61c07c7a666f8f70656321c8/src/nimfactory/contracts/validate.nim#L69).

Le scanner convertit chaque séquence `\uXXXX` séparément en Rune. Il ne combine pas les paires de substituts, alors que le parseur JSON en aval les combine.

Entrée exécutée :

```json
{"😀":1,"\uD83D\uDE00":2}
```

Elle est acceptée et devient `{"😀":2}` : la première valeur disparaît. Le témoin `{"\uD83D\uDE00":1}` est correctement accepté et décodé par le parseur final ; il ne faut donc pas simplement interdire ces caractères valides.

Attendu : comparer les noms après le même décodage que le parseur JSON final. Préférer le réemploi de son décodeur de chaînes, ou implémenter complètement les règles nécessaires, plutôt qu'un traitement Unicode partiel. Garder le témoin valide, les doublons ASCII/BMP et le cas avec paire de substituts, y compris dans un objet imbriqué.

Sondes : `F0_surrogate_pair_duplicate`, `F0_single_surrogate_pair_valid`.

## Reste A1-R5b — P2 — divergence entre schéma et décodeur sur les champs imbriqués

Code : [result.nim, ligne 185](https://github.com/ThomasValbret/nimfactory/blob/7737c6c93efe991b61c07c7a666f8f70656321c8/src/nimfactory/contracts/result.nim#L185) et [ligne 204](https://github.com/ThomasValbret/nimfactory/blob/7737c6c93efe991b61c07c7a666f8f70656321c8/src/nimfactory/contracts/result.nim#L204).

Deux cas exécutés sont encore acceptés puis transformés :

- Un diagnostic avec `code:123`, `phase:[]`, `message:false` devient trois chaînes vides. Le schéma JSON du candidat rejette effectivement ces trois types ; cette divergence a aussi été vérifiée avec le validateur Python `jsonschema.Draft202012Validator` sur le schéma du dépôt.
- Une erreur avec `retryable:"true"` devient `retryable:false`. Les champs de `error` restent insuffisamment décrits dans le schéma et ne sont pas validés avant les conversions par défaut.

Attendu : terminer la validation de `diagnostics` et `error`, puis aligner schéma et code. Les champs réellement facultatifs peuvent avoir une valeur par défaut documentée ; les types incorrects doivent être rejetés. Le précédent rapport demandait déjà la validation des structures imbriquées et l'alignement des deux validateurs.

Sondes : `F0_diagnostic_wrong_types`, `F0_error_wrong_boolean`. Comparaison au schéma : `a1r_schema_observations.json`.

Au total, ces cinq sondes de frontière produisent **quatre échecs et un témoin positif**, exit 1. Sortie : `a1r_boundary_observations.jsonl`.

## Fiabilité des preuves de réception

Le programme ajouté au dépôt sous le nom `a1_independent_probe.nim` est une réécriture, pas la copie des sondes fournies. Deux changements expliquent pourquoi son rouge ne compte plus que cinq échecs :

1. **Budget** : le deuxième handle est désormais ouvert après la première réservation. Même avec deux autorités séparées, il peut alors charger les 70 déjà persistés et refuser la seconde réservation. Le défaut d'autorité partagée n'est plus discriminé par ce scénario.
2. **Graphe** : la fixture omet maintenant la condition de sortie de la boucle. Un autre motif d'invalidité suffit à faire passer une assertion qui vérifie seulement `status != ok`, même sans le contrôle des cycles résiduels.

Les corrections de ces deux cas sont néanmoins confirmées par les sondes originales inchangées. Il faut conserver ces sondes discriminantes dans la qualification future, afin qu'une régression des corrections soit détectée. Identifier explicitement les variantes et renforcer les assertions plutôt que changer silencieusement une preuve dite indépendante.

Autres ajustements de preuve, constatés par lecture :

- Le reçu laisse `Révision testée (contenu)` vide et le journal de suite affiche `nimfactory=ed2344a`. Cela peut correspondre à des tests effectués sur des changements non encore commités, mais ne rattache pas à lui seul la sortie à `e401448`. Relancer sur un contenu commité et identifier la révision réellement testée ; un commit ultérieur limité au reçu peut être distingué sans circularité.
- Le script teste le SHA SDK, mais les deux programmes supplémentaires restent conditionnels à l'existence de leurs fichiers. Leur absence peut encore réduire la campagne sans faire échouer le script. Inscrire explicitement tous les programmes requis dans la liste obligatoire.

## Passe corrective demandée

Conserver `fix/wave-a1` et limiter le prochain correctif aux restes A1-R1/A1-R5 et aux preuves. Ne pas rouvrir F1/F3/F4 au titre des contre-exemples maintenant corrigés, ni commencer la vague B dans cette passe.

1. Intégrer les sondes originales inchangées, avec leur provenance, ou des régressions équivalentes réellement discriminantes. Conserver une trace du fichier original.
2. Corriger l'identité physique du ledger ou refuser les liens symboliques ; terminer le décodage des noms JSON et la validation des diagnostics/erreurs.
3. Faire passer les dix sondes originales et les cinq sondes supplémentaires, puis la suite complète et la façade avec le SDK réel épinglé. Aucun appel LLM n'est nécessaire.
4. Rendre les tests de réception obligatoires, identifier le contenu réellement testé et publier le reçu avec les limites restantes. Garder séparés F0, composants A, M0 et M1.

Commandes de reproduction, depuis la racine du candidat avec Nim 2.4 sur PATH :

```sh
nim c -r --hints:off --path:src --nimcache:build/a1r-frozen-cache --out:build/a1r-frozen docs/qa/a1_frozen_previous_probe.nim
nim c -r --hints:off --path:src --nimcache:build/a1r-boundary-cache --out:build/a1r-boundary docs/qa/a1r_boundary_probe.nim
```

Sur `7737c6c`, la première commande réussit ; la seconde échoue avec les quatre écarts documentés. Cette revue ne prétend pas couvrir tous les scénarios de panne ou de concurrence du projet.
