# NimFactory — architecture proposée

Version 0.2 de travail · 17 novembre 2026  
Statut : proposition de départ, à confronter au SDK pendant F0. Ce fichier ne décrit pas une implémentation déjà auditée.

Cadre de contribution : [../AGENTS.md](../AGENTS.md). Contrats détaillés et lots : [WORK_PACKAGES.md](WORK_PACKAGES.md).

## 1. Intention et premier périmètre

NimFactory doit permettre de construire un workflow de production logicielle à partir de briques explicites : tâches, agents, traitements déterministes, outils, branches, boucles, contrôles et artefacts. La factory et ses agents sont en Nim. Le langage du logiciel produit dépend du projet et des compétences sélectionnées.

Le premier produit est une bibliothèque composable avec une CLI. Il doit fonctionner sur une machine, sans fournisseur LLM pour ses parcours déterministes et ses démonstrations scriptées.

Le cœur n'impose pas un workflow universel « planifier → coder → relire ». Il fournit les primitives permettant au responsable du projet de définir ses propres recettes. Un coordinateur peut être un graphe déterministe ; lorsqu'un choix demande un LLM, ce choix devient un nœud explicite, avec entrées, contrat de sortie et budget.

La distribution avec compilateur embarqué, l'interface graphique, le calcul distribué et la réécriture autonome des recettes restent ultérieurs. Un exécutable de factory ne rend pas automatiquement autonomes les toolchains de tous les langages qu'il produit.

## 2. Répartition avec NimAgent

| Élément | Responsabilité attendue |
| --- | --- |
| NimAgent | Primitives existantes d'agent, `Message`, appels et outils compatibles, événements et mécanismes déjà utilisables. Le périmètre exact est relevé en F0. |
| NimFactory | Graphe, activations, coordination, chambres, préparation du contexte, artefacts, budgets communs, reprise et CLI. |
| Adaptateur NimAgent | Mapping des types réels, métadonnées factory, codecs et accès aux capacités du SDK. |
| Recettes métier | Enchaînement des tâches, règles de choix, résultats attendus, compétences et critères d'acceptation. |
| Adaptateurs de projet | Outils, sources et compétences spécifiques : NimAgentLibrary, autres dépôts, autres langages. |

Une brique Code Zero déjà disponible est réutilisable comme composant de travail ; elle n'impose pas un produit ou une boucle séparés. Une fonctionnalité présente dans le SDK n'est pas recopiée dans la factory sans raison documentée.

Les signatures de ce document sont conceptuelles. F0 les raccorde aux noms, chemins et comportements réellement observés dans une révision précise du SDK.

## 3. Trois plans, une communication commune

**Le plan de contrôle** porte graphe, état des activations, transitions, besoins, annulations, reprise et budgets. Il reste inspectable sans lire tous les textes du contexte.

**Le plan des données** contient les objets immuables : sources, extraits, résultats d'outils, changements de mémoire, fragments, seeds, réponses et reçus. Les messages transportent surtout leurs références.

**Le plan de préparation** transforme une demande et des vues autorisées des chambres en entrée complète pour une inférence déterminée.

Les trois utilisent `Message`. Une charge utile métier et ses métadonnées factory sont ajoutées par l'adaptateur commun ; elles ne constituent pas un bus parallèle.

## 4. Modules et dépendances

| Chemin proposé | Contenu | Lots |
| --- | --- | --- |
| `src/nimfactory/contracts/` | Types, ports, identifiants, erreurs et codecs communs | F0 |
| `src/nimfactory/adapters/nimagent/` | Intégration du SDK et mapping de Message | F0, adaptations coordonnées |
| `src/nimfactory/artifacts/` | Octets, manifestes, snapshots et read sets | F1 |
| `src/nimfactory/chambers/` | Espaces révisés, projections et commits | F2 |
| `src/nimfactory/runtime/journal/` | États durables, événements, outbox et reprise | F3 |
| `src/nimfactory/graph/` | Définition, validation et compilation du graphe | F4 |
| `src/nimfactory/runtime/executor/` | Ordonnancement, tuyaux, annulation, délais | F5 |
| `src/nimfactory/preparation/host/` | Exécution des préparateurs et besoins | F6 |
| `src/nimfactory/preparation/prompt/` | Demande opérationnelle de l'étape | F7 |
| `src/nimfactory/preparation/instructions/` | Catalogue et sélection d'instructions | F8 |
| `src/nimfactory/preparation/skills/` | Compétences et exigences d'outils | F9 |
| `src/nimfactory/memory/` | État de travail, changements et projections | F10 |
| `src/nimfactory/retrieval/` | Recherche et sélection de sources | F11 |
| `src/nimfactory/preparation/assembly/` | Sélection finale, seed et reçu | F12 |
| `src/nimfactory/inference/` | Profils, bindings, routes, validation et inférence | F13 |
| `src/nimfactory/budget/` | Réservations et réconciliation d'usage | F14 |
| `src/nimfactory/cache/` | Réutilisation et invalidation | F15 |
| `src/nimfactory/application/`, `src/nimfactory/cli/` | Composition des adaptateurs et commandes | F16 |
| `tests/qualification/` | Scénarios et oracles indépendants | F17 |
| `schemas/`, `tests/fixtures/contracts/` | Contrats de référence et compatibilité | F0, extensions coordonnées |
| `recipes/`, `examples/` | Workflows déclaratifs et exemples minimaux | Chaque lot, intégration F16 |
| `docs/deliveries/`, `docs/decisions/` | Preuves de livraison et décisions transversales | Chaque lot |

Une façade publique `src/nimfactory.nim` expose les fonctions utiles ; `src/nimfactory_cli.nim` lance l'application. L'implémentation exacte de cette façade est fixée en F0, puis raccordée en F16.

Règles d'import :

- les domaines consomment des contrats et des ports, pas les implémentations voisines ;
- les dépendances concrètes sont injectées dans la couche application ;
- les détails fournisseur restent dans les adaptateurs d'inférence ;
- le broker ne dépend pas de l'implémentation de l'assembleur ;
- le journal ne dépend pas d'un préparateur métier ;
- le cache ne devient pas une source autoritaire d'état ;
- les contrats communs n'importent pas tout le SDK : réexport ciblé d'un type existant ou adaptation explicite, selon F0.

## 5. Objets fondamentaux

| Objet | Rôle |
| --- | --- |
| `ArtifactRef` | Référence résolvable et vérifiable à un contenu immuable. |
| `SourceSnapshot` | Ensemble figé de révisions de sources, chambres, recettes et index. |
| `ReadSet` | Lectures effectivement utilisées, y compris recherches vides et dépendances négatives. |
| `ChamberSnapshot` | Vue versionnée d'une chambre ; accès limité par un handle explicite. |
| `TaskIntent` | Objectif, exigences, exclusions, hypothèses, sorties et contrôles de la tâche. |
| `ContextRequest` | Demande de préparation pour une tâche, une étape et une recette. |
| `ContextFragment` | Contenu référencé, origine, rôle sémantique, portée et dépendances. |
| `InferenceSeed` | Description immuable de l'entrée retenue pour un binding et une politique de matérialisation. |
| `PreparationReceipt` | Justification des inclusions, omissions, transformations, limites et couverture. |
| `ModelPlan` | Route résolue, binding retenu, validateur et nombre d'envois restant. |
| `NodeInvocation` | Une tentative d'une activation, avec ses entrées, snapshot et contexte d'exécution. |

Un identifiant métier n'est pas une référence de stockage. `instruction_id`, `handler_ref` et `ArtifactRef` sont des types distincts même s'ils se sérialisent en chaînes. F0 fixe leur représentation exacte.

Un seed est une entrée structurée pour un appel ; il ne représente pas l'état latent du modèle. `context_overview` est une vue synthétique optionnelle destinée à un consommateur précis. Il ne doit pas devenir un second résumé obligatoire ajouté à chaque seed.

## 6. Construction d'une inférence

Le contrôleur de recette effectue les opérations suivantes, certaines pouvant être parallélisées :

1. Résoudre la tâche, l'étape, la recette et un snapshot de sources.
2. Obtenir un `ModelPlan` quand l'étape demande un modèle ; sa liaison concrète fixe les contraintes de matérialisation.
3. Déterminer les préparateurs requis et leur remettre uniquement leurs handles de lecture.
4. Produire la tâche opérationnelle, les instructions applicables, les unités de skills, la projection de mémoire et les preuves utiles.
5. Traiter les besoins complémentaires dans une boucle bornée, ou rendre un blocage explicite.
6. Fermer les dépendances, vérifier les exigences et sélectionner les fragments facultatifs.
7. Matérialiser l'entrée pour le binding retenu et contrôler la requête complète : rôles, messages, outils, schémas, fenêtre et réserve de sortie.
8. Sceller le seed et son reçu ; appeler le broker, qui réserve l'envoi auprès du ledger avant d'invoquer le fournisseur.
9. Valider la réponse, enregistrer les artefacts et proposer les changements d'état.
10. En cas de repli autorisé, obtenir le nouveau binding, rematérialiser et contrôler à nouveau avant un nouvel envoi.

Le broker retourne `reprepare_required` lorsqu'un autre binding est nécessaire. Le contrôleur rappelle l'assembleur par son port. Il n'existe pas de boucle d'import broker → assembleur → broker.

Le compte d'entrée couvre le payload fournisseur complet. Une estimation de tokens reste signalée comme telle. Si les éléments requis ne tiennent pas, la préparation est bloquée avec la cause ; la recette peut choisir une décomposition ou une autre capacité. Une troncature silencieuse est interdite.

Les reçus complets restent hors du prompt, sauf projection explicitement utile au modèle. Des sessions distinctes et la non-transmission des éléments non sélectionnés assurent le cloisonnement logique. Un état de session conservé côté fournisseur doit être désactivé ou représenté dans les entrées, le budget et les dépendances ; sinon le seed n'est pas complet.

## 7. Chambres et préparateurs

Une chambre conserve un domaine de contenu : instructions, métier, demande, mémoire, sources ou état propre à un préparateur. Elle n'est pas un LLM permanent. Le service de lecture peut appliquer une projection déterministe ; un préparateur plus élaboré peut ensuite traiter cette projection.

Les chambres sont révisées. Les écritures passent par `propose` puis `commit(expectedRevision)`. Un snapshot ne suit pas silencieusement les mises à jour de la source.

Une lecture supplémentaire peut enrichir le read set au sein des révisions figées. Si le complément exige une nouvelle révision non couverte, créer un nouveau snapshot et revalider les dépendances touchées. Ne pas mélanger discrètement deux versions d'une même source.

Chaque préparateur déclare :

- ses schémas d'entrée et de sortie ;
- les chambres et outils requis ;
- sa stratégie déterministe ou assistée ;
- sa recette et sa version ;
- les limites héritées du parent.

Les producteurs assistés disposent d'une recette de démarrage déterministe. Ils utilisent les mêmes interfaces et budgets que les autres, sans ouvrir une préparation récursive sans borne. Le parentage et les plafonds empêchent les cycles de besoins et les raffinements indéfinis.

L'isolation initiale est applicative entre composants coopératifs. Elle n'est pas une protection du système d'exploitation contre un plugin exécutant du code arbitraire.

## 8. Graphe, tuyaux et exécution

Le graphe décrit des nœuds, handlers versionnés, ports typés, entrées, sorties, branchements et boucles explicites. Le validateur rejette les liens incompatibles et les cycles non déclarés avant exécution.

Primitives attendues : `sequence`, `branch`, `map`, `join`, `reduce`, `loop`, `subgraph` et `await_event`. Leur implantation peut être progressive, avec capacités exposées et erreurs explicites pour celles qui manquent. Un graphe nécessitant une primitive absente ne doit pas être accepté comme exécutable.

Une activation identifie une occurrence d'un nœud, y compris branche et itération. Une tentative est une exécution de cette activation ; un retry crée une nouvelle tentative. Les données ne sont pas simplement déposées dans un dictionnaire global partagé.

Les tuyaux sont bornés et appliquent une pression explicite. Les transitions et résultats sont publiés par le journal. Les sorties d'une branche annulée ou d'un ancien propriétaire ne deviennent pas courantes par leur arrivée tardive.

Les joins déclarent leur condition de satisfaction et leurs politiques d'échec, d'annulation et d'arrivée tardive. Un `all_required` attend ses ports requis, mais termine en blocage/échec lorsqu'ils ne peuvent plus être fournis. Un résultat partiel n'est accepté que par contrat.

Les boucles ont une condition de sortie, un maximum d'itérations et, si utile, un critère de progrès. `await_event` persiste une attente corrélée et une échéance ; il ne repose pas sur un LLM interrogé en continu.

Le backend initial exécute sur une machine. Séquentiel et concurrent borné partagent la même sémantique. Une façade synchrone attend le même moteur sans imbriquer de boucle événementielle. Le choix technique d'asynchronisme suit les mécanismes compatibles déjà présents dans NimAgent.

## 9. Persistance, effets et reprise

L'ArtifactStore conserve les octets exacts et leurs manifestes. La publication est atomique : un manifeste visible ne pointe pas vers un objet partiellement écrit. La déduplication du contenu conserve ses différentes provenances.

Le RunStore conserve les états, tentatives, événements et messages à publier. Une transition d'état et son outbox sont écrites dans la même transaction lorsque cette garantie est revendiquée. SQLite local est une proposition de backend, pas une dépendance à imposer si le SDK fournit déjà le mécanisme adapté.

Le protocole accepte les retransmissions : `message_id` stable, consommation dédupliquée, acknowledgement après prise en compte durable. Un `epoch` distingue le propriétaire courant d'une ancienne exécution.

La reprise garantit la cohérence des transitions locales selon le contrat livré. Elle ne garantit pas un effet externe unique. Une écriture distante ou un appel fournisseur peut avoir réussi sans réponse reçue ; conserver `effect_outcome_unknown` jusqu'à réconciliation.

Le journal d'exécution et le ledger de budget ont des autorités distinctes. S'ils utilisent des transactions séparées, corréler et réconcilier par identifiant de tentative ; ne pas annoncer une atomicité globale inexistante.

## 10. Budgets, petits modèles et cache

Le BudgetLedger arbitre atomiquement les réservations de projet, run, tâche et préparation. Toute dépense descendante compte dans le parent. Le broker est l'unique demandeur de réservation pour chaque envoi fournisseur effectif, y compris retry et réparation ; le contrôleur de recette ne réserve pas une seconde fois. Désactiver les retries cachés ou les raccorder au même passage par le broker.

Un timeout après émission laisse un coût potentiel réservé. Une absence de compteurs ne signifie pas gratuité. Les prix et capacités sont des configurations versionnées, pas des constantes éparpillées dans les préparateurs.

Les modèles sont choisis par capacité et qualification de tâche. La route déterministe → petit modèle → modèle plus capable est disponible, mais un appel direct peut être préférable si la cascade coûterait davantage. Le choix doit se mesurer sur le coût et la qualité de l'ensemble du parcours.

Le cache enregistre les résultats et leurs dépendances effectives : versions, recettes, scopes, outils, lectures et recherches vides. Il ne dépend pas seulement du texte d'un prompt. Les effets externes utilisent la déduplication et la reprise, pas un cache de fonctions pures.

Une invalidation suit les dépendances concernées. Les préfixes stables peuvent aider un cache fournisseur, mais une éventuelle remise de tokens ne doit pas être confondue avec l'économie d'un appel évité.

## 11. Formats et déterminisme

En mémoire : objets Nim typés et `Message`. Aux frontières et dans les fixtures : JSON UTF-8 versionné. Sur stdio : NDJSON, un objet par ligne, diagnostics humains sur stderr.

Le contrat détaillé se trouve au début de [WORK_PACKAGES.md](WORK_PACKAGES.md). Les objets doivent avoir des validateurs effectifs. Une liste de types ou des fichiers JSON Schema sans contrôles exécutés ne suffisent pas.

Pour le contenu, l'empreinte porte sur les octets. Pour une structure JSON servant d'identité, utiliser le codec canonique commun et ses vecteurs de conformité, idéalement JCS/RFC 8785. Les nombres hors domaine de représentation admis doivent être encodés selon le schéma, sans conversion arrondie silencieuse.

« Déterministe » signifie : mêmes entrées, versions, configuration et dépendances → mêmes sorties logiques. Les horloges, UUID d'exécution, durées et événements de transport ne doivent pas polluer l'identité sémantique du calcul. F0 documente les champs inclus dans cette identité. Ce principe ne promet pas de reproduire une réponse LLM.

## 12. CLI et expérience de développement

Commandes conceptuelles : `validate`, `prepare`, `inspect`, `run`, `resume`, `events`, `costs`. F16 fixe la grammaire précise.

Le profil minimal propose un parcours complet avec fournisseur scripté, sans clé API. Le mode JSON doit être utilisable par un autre programme ; le mode humain permet de comprendre blocages, dépendances, sources et coût.

Les inspections montrent les références et raisons par défaut. L'impression du contenu brut est explicite pour éviter de transformer chaque diagnostic en duplication de la mémoire.

## 13. Progression et critères d'adéquation

| Jalon | Démonstration attendue |
| --- | --- |
| M0 — contrats | Message et charges utiles passent entre deux consommateurs sans perte ; erreurs et incompatibilités sont détectées. |
| M1 — plomberie | Un graphe déterministe s'exécute en CLI, bifurque, joint ses résultats et reprend après un arrêt. |
| M2 — préparation | Des chambres distinctes alimentent un seed inspectable ; une vieille contrainte utile est conservée et une skill hors sujet omise. |
| M3 — modèles bornés | Une tâche circonscrite utilise un petit modèle validé, avec repli éventuel et budget partagé réellement appliqué. |
| M4 — composition | Les besoins complémentaires terminent, le cache s'invalide correctement et les coûts complets sont comparés. |

La qualification distingue conformité d'un composant, intégration réelle et qualité de modèle. Un test scripté peut prouver le routage et la reprise ; il ne prouve pas les performances d'un modèle réel.

## 14. Décisions ouvertes réservées à F0 et aux intégrations

- Définition publique exacte de `Message` et extension de métadonnées la moins intrusive.
- Réutilisation des journaux, stockages, outils et compteurs existants.
- Version de Nim, dépendances minimales et backend d'asynchronisme.
- Représentation des références, des erreurs et des validations de schéma.
- Mécanisme de transaction local et partage éventuel entre journal et ledger.
- Capacités réellement supportées par les adaptateurs fournisseur.

Ces points sont des adaptations attendues, pas des motifs pour retarder tous les lots. Les interfaces et doublures servent précisément à permettre un travail séparé avant l'intégration.

## 15. Provenance

Cette proposition reprend la note [NimFactory — premiers jalons et contrats v0.1](https://app.notion.com/p/41b70f92670b8199b8f5e091d386bbcc), en la répartissant entre règles de dépôt, architecture et lots. Les lots historiques J00–J17 deviennent F0–F17, sans changement de correspondance. Tous les éléments nécessaires au démarrage sont présents dans ces trois fichiers ; la consultation de Notion n'est pas une dépendance de compilation ou de travail.

