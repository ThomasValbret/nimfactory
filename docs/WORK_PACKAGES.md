# NimFactory — lots de travail F0–F17

Ce catalogue permet d'attribuer un lot par son identifiant, par exemple **« Occupe-toi de F1 »**. Le codeur applique d'abord [../AGENTS.md](../AGENTS.md), lit [ARCHITECTURE.md](ARCHITECTURE.md), les contrats communs ci-dessous, puis le lot demandé. Il n'a pas à ingérer toutes les implémentations voisines.

**État initial : à vérifier dans le dépôt.** Aucune case de livraison n'est prévalidée. Les noms F0–F17 correspondent un pour un aux anciens J00–J17 ; F1 est le stockage d'artefacts, pas un autre lot renuméroté.

## Lecture et limites d'un lot

Les chemins sont proposés pour faciliter les travaux séparés. F0 peut les ajuster en une seule cartographie commune, puis les figer. Les fichiers de façade et de composition sont partagés : un lot propose son export ou son raccordement sans réorganiser seul tout le programme.

Les dépendances ci-dessous sont des **ports**, sauf mention contraire. Elles ne constituent pas un ordre d'attente absolu. Les tests avec doublures appliquent les mêmes contrats que les adaptateurs finaux, et les reçus déclarent les raccordements encore manquants.

Chaque lot livre une bibliothèque utilisable depuis un petit consommateur, ses tests pertinents, une fixture ou recette minimale et un reçu. Il n'est pas nécessaire de développer une CLI privée par lot. Une commande d'exemple ou un test consommateur suffit jusqu'à F16.

Les critères « Réception » sont des obligations de comportement. Si une partie reste différée, le reçu le dit ; ne pas annoncer l'intégralité du lot terminée.

## Préambule et contrats communs

Version documentaire 0.2 de travail — 17 novembre 2026. Les identifiants de schémas 0.1 ci-dessous restent des propositions à stabiliser en F0 ; la version documentaire n'est pas leur version.

Ce document fixe des architectures attendues et des contrats d’échange pour des composants codables séparément. Il ne constitue ni un audit du code courant, ni une description de fonctionnalités déjà présentes. La logique métier fine des workflows reste définie par le responsable du projet. Les signatures et chemins sont proposés ; leur raccordement aux API réelles de NimAgent doit être effectué par un adaptateur commun.

**Périmètre.** Factory et agents en Nim ; logiciels produits dans plusieurs langages ; CLI initiale ; réemploi de Message ; tuyaux, graphes, boucles et préparation de chaque inférence à partir de chambres. Les préparateurs peuvent être déterministes ou utiliser des modèles spécialisés, dont de petits modèles. Distribution avec compilateur embarqué, interface graphique, exécution distribuée et adaptation automatique des recettes sont hors du premier périmètre.

**Principe d’intégration.** Les composants métier n’importent que les contrats et les ports qu’ils utilisent. Les dépendances concrètes sont assemblées à l’entrée du programme. Une implémentation en mémoire ou scriptée permet de développer chaque lot sans attendre les autres. Les doublures doivent appliquer les mêmes invariants observables que les adaptateurs réels.

**Message est la base de communication.** F0 relève sa définition et son codec réels. Les informations qu’il porte déjà sont réutilisées. Les métadonnées propres à la factory sont ajoutées dans ses métadonnées ou dans un compagnon FactoryMeta ; elles ne justifient pas un second système de messages. Les objets métier ci-dessous constituent ses charges utiles. Une enveloppe JSON de transport peut réunir factory et message, ce dernier conservant le codec commun. Les domaines ne prennent aucune dépendance sur un fournisseur LLM.

**Deux formats, une sémantique.** En mémoire : objets Nim typés et Message existant. À la frontière processus, au journal et dans les fixtures : JSON UTF-8 versionné ; NDJSON sur stdio, une enveloppe par ligne et journaux humains sur stderr. Les chemins de fichiers ne servent pas d’identités d’artefacts. Le transport HTTP ou distant pourra être ajouté plus tard sans changer les objets métier.

**Compatibilité.** Chaque objet racine porte schema avec nom et version. Version majeure inconnue ou option required_features inconnue : rejet explicite. Les extensions facultatives restent dans extensions. Un champ inconnu porteur d’une sémantique ne doit pas être silencieusement ignoré. JSON invalide, clés dupliquées et nombres non finis sont rejetés. Les montants sont des chaînes d’entiers en micro-USD, les durées des entiers en millisecondes, les dates en UTC ISO 8601. Les identifiants sont des chaînes opaques. Un ArtifactRef désigne un artefact immuable résolu et vérifié par F1. Les références de handler, d'instruction et de profil sont des types distincts, résolus dans leur registre versionné ; un suffixe _ref ne suffit pas à faire d'une chaîne un ArtifactRef.

Pour l’identité des structures JSON, utiliser une représentation canonique commune, idéalement JCS/RFC 8785, et SHA-256 ; ne pas improviser un tri de clés en le présentant comme une implémentation JCS. Un schéma JSON doit documenter les champs et être accompagné de validations Nim réellement exécutées et de vecteurs de compatibilité. Un schéma documentaire seul n’est pas un validateur.

**Métadonnées communes.** Illustratif ; les valeurs ne désignent aucun artefact réel :

```json
{
  "schema": "nimfactory.meta/0.1",
  "message_id": "msg-001",
  "run_id": "run-001",
  "activation_id": "act-001",
  "attempt_id": "try-001",
  "epoch": 1,
  "correlation_id": "prep-001",
  "causation_id": null,
  "payload_schema": "nimfactory.context-request/0.1",
  "extensions": {}
}
```

run_id identifie le travail global. activation_id identifie une invocation de nœud, donc aussi sa branche ou son itération. attempt_id change pour une nouvelle tentative de cette invocation. epoch distingue le propriétaire courant d’une ancienne exécution. message_id reste identique pour la retransmission du même message. Une tentative HTTP fournisseur possède en plus son propre inference_attempt_id et sa propre réservation.

### Contrat de résultat commun

```json
{
  "schema": "nimfactory.result/0.1",
  "status": "ok",
  "outputs": {
    "fragments_ref": "art-fragments-001"
  },
  "needs": [],
  "diagnostics": [],
  "read_set_ref": "art-readset-001",
  "usage_ref": null
}
```

Statuts : ok, partial, blocked, failed, cancelled. Un besoin absent et nécessaire produit blocked, ou partial si la recette autorise expressément une sortie partielle. partial ne satisfait pas implicitement un port requis. Une erreur comprend code, phase, retryable, références utiles et raison concise ; une exception brute n’est pas le protocole. Codes transversaux minimaux : schema_mismatch, missing_required_input, stale_snapshot, unsupported_capability, budget_exhausted, dependency_cycle, effect_outcome_unknown. Le codeur peut ajouter des codes de domaine versionnés.

**Interfaces, sous forme de signatures conceptuelles.** Elles ne prétendent pas compiler contre NimAgent actuel :

- ArtifactStore : put / read / describe.
- SnapshotSource : capture / resolve.
- ChamberStore : snapshot / read / propose / commit(expectedRevision).
- Producer : requirements(request) / prepare(request, handles).
- GraphValidator : validate(graph).
- NodeHandler : invoke(input, executionContext).
- ModelBroker : plan(task, capabilities, budget) / infer(inferenceRequest).
- BudgetLedger : reserve / settle / markUnknown / releaseBeforeSend.
- SeedAssembler : assemble(request, modelPlan, fragments).
- ProviderAdapter : materialize(seed, modelCapabilities).
- Cache : lookup / record / invalidate.
- RunStore : appendEvent / commitTransition / recover.
- Transport : publish / receive / acknowledge.

Une façade synchrone peut attendre un exécuteur asynchrone, mais elle ne crée pas une seconde implémentation de la logique et ne lance pas de boucle événementielle imbriquée.

### Résumé des lots

| Lot | Produit autonome | Ports requis pour le développement |
| --- | --- | --- |
| F0 | Contrats, codec et adaptateur Message | Message réel |
| F1 | Artefacts et instantanés | Contrats |
| F2 | Chambres | Contrats, ArtifactStore simulé |
| F3 | Journal et reprise durable | Contrats |
| F4 | Description et validation du graphe | Contrats, registre de nœuds simulé |
| F5 | Exécuteur et tuyaux | Contrats, RunStore et handlers simulés |
| F6 | Hôte de préparateurs | Contrats, chambres et broker simulés |
| F7 | Prompt builder | Contrats, recettes et broker optionnel |
| F8 | Factoriseur d’instructions | Contrats, règles de portée |
| F9 | Injecteur de skills et outils | Contrats, registre simulé |
| F10 | Mémoire de travail | Contrats, ChamberStore simulé |
| F11 | Sélection de sources et mémoire documentaire | Contrats, index simulé |
| F12 | Assembleur du seed | Contrats, fragments et adaptateur simulés |
| F13 | Routage de modèles | Contrats, fournisseurs et ledger simulés |
| F14 | Budget et comptabilité | Contrats, transactions locales |
| F15 | Cache et invalidation | Contrats, artefacts et dépendances simulés |
| F16 | CLI et inspection | Contrats, façades simulées |
| F17 | Banc de qualification | Fixtures communes et sorties publiques |

## Responsabilités communes et points d'intégration

| Objet partagé | Responsable | Obligation des autres lots |
| --- | --- | --- |
| Types, schemas et fixtures de transport | F0 | Proposer une extension et ses cas de compatibilité ; ne pas maintenir un codec divergent. |
| Adaptation du SDK et de Message | F0 | Consommer la façade commune ; signaler l'API réelle manquante. |
| Stockage d'artefacts et vérification | F1 | Fournir des origines exactes ; ne pas manipuler directement les fichiers internes. |
| État durable d'exécution | F3 | Soumettre les transitions par RunStore ; ne pas écrire directement ses tables. |
| Catalogue des handlers et validation | F4 | Déclarer les ports, versions et capacités de chaque handler. |
| État de réservation financière | F14 | Réserver par le port commun ; ne pas déduire le solde d'un cache local. |
| Composition applicative et CLI | F16 | Exposer une façade et une configuration ; proposer un raccordement minimal. |
| Oracles de qualification | F17 | Exposer des sorties vérifiables ; ne pas adapter l'oracle pour qu'il confirme une implémentation incorrecte. |

F0 et F16 peuvent appartenir au même intégrateur sans fusionner leurs responsabilités. F0 stabilise les interfaces ; F16 compose les adaptateurs effectivement livrés. Un agent affecté à F1 ne devient pas propriétaire du bootstrap, du journal ou de la CLI.

Les formats ci-dessus sont proposés ; F0 publie les formats exécutables. L'apparition d'un nouveau champ requis ou d'une nouvelle sémantique de contrôle est une évolution de contrat, même si JSON permet de l'encoder.

## F0 — Contrats et raccordement à Message

**Responsabilité de fichiers :** `src/nimfactory/contracts/`, `src/nimfactory/adapters/nimagent/`, `schemas/`, `tests/fixtures/contracts/`. Tests unitaires correspondants dans `tests/f0/`.

**Dépendances de développement :** SDK réellement inspecté ; aucun autre lot requis.

**Livraison attendue :** Cartographie SDK, contrats, codecs, validateurs, fixtures et façade minimale. Reçu : `docs/deliveries/F0.md`.

Livrer un paquet minimal de types, codecs, validations et interfaces. Relever les types publics déjà présents dans NimAgent pour Message, erreurs, usage, artefacts, résultats, contexte et événements. Réutiliser les types compatibles et documenter les adaptations ; la factory conserve ses données spécifiques sans dupliquer arbitrairement les concepts du SDK.

L’adaptateur définit comment une charge utile typée circule avec Message en mémoire et comment elle est sérialisée pour le transport. Les modules appelants ne construisent pas de JSON fournisseur. Si le Message existant ne porte pas une métadonnée, l’adaptateur conserve le compagnon associé ; aucune information nécessaire au routage ne disparaît au retour.

Livrer aussi des fixtures JSON positives et négatives, leur résultat attendu, les règles de version, les erreurs communes et un registre des schémas. Les fichiers de contrats ont un propriétaire unique ; les autres lots proposent leurs extensions à cet endroit.

Réception : aller-retour sans perte des identifiants, accents, références, erreurs et valeurs nulles autorisées ; rejet d’une version ou fonctionnalité obligatoire inconnue ; distinction entre nouvelle tentative et retransmission ; même lecture des fixtures par deux consommateurs indépendants.

## F1 — Artefacts immuables et instantanés de sources

**Responsabilité de fichiers :** `src/nimfactory/artifacts/`. Tests unitaires correspondants dans `tests/f1/`.

**Dépendances de développement :** Contrats F0 ; stockage local.

**Livraison attendue :** ArtifactStore et SnapshotSource utilisables, manifestes et ReadSet. Reçu : `docs/deliveries/F1.md`.

Le stockage contient des octets exacts et leur manifeste : identifiant, empreinte, type MIME, taille, origine et références de provenance. put retourne une référence immuable ; read vérifie taille et empreinte. La déduplication des octets n’efface pas les origines distinctes. Les textes normalisés ou extraits deviennent de nouveaux artefacts reliés à la source brute.

Le backend initial peut être un répertoire d’objets avec index transactionnel local. Définir atomicité de publication : un manifeste visible ne pointe jamais volontairement vers un fichier partiellement écrit. Les objets déposés avant un arrêt mais non référencés peuvent rester orphelins, sans nettoyage automatique.

SnapshotSource capture les révisions nécessaires à une préparation. Une source externe mutable est matérialisée en artefact avant utilisation. Un chemin seul, HEAD ou latest ne prouve pas une version. Le manifeste de snapshot donne les versions exactes des chambres, corpus, recettes et index utilisés. Les lectures supplémentaires s’ajoutent à un read set versionné ; elles ne changent pas silencieusement un snapshot déjà scellé.

Entrées : octets ou SourceCaptureRequest. Sorties : ArtifactRef, SourceSnapshot, ReadSet. Réception : interruption pendant écriture, altération d’objet, deux origines pour les mêmes octets, modification de la source après capture et reproduction de la lecture initiale.

## F2 — Chambres de contexte

**Responsabilité de fichiers :** `src/nimfactory/chambers/`. Tests unitaires correspondants dans `tests/f2/`.

**Dépendances de développement :** ArtifactStore F1, simulable ; contrats F0.

**Livraison attendue :** ChamberStore, handles, projections et commits avec révision attendue. Reçu : `docs/deliveries/F2.md`.

Une chambre est un espace logique avec schéma, révision, sources et politique de projection. Elle peut contenir des instructions, des compétences, une demande, des sources ou une mémoire de travail. Le type de chambre ne détermine pas à lui seul le rôle fournisseur du contenu.

Le handle remis au préparateur identifie les chambres et snapshots lisibles. Le préparateur demande une projection avec étape, objectif, type de contenu, références et budget. Il reçoit un résultat structuré distinguant found, empty, unavailable et truncated. Une absence de résultat n’est pas assimilée à une panne de lecture.

Les écritures passent par des propositions de changement puis commit avec expectedRevision. Deux écritures concurrentes ne se remplacent pas silencieusement. Les mémoires propres aux préparateurs ont leurs chambres distinctes ; leurs contenus ne sont pas propagés par défaut au consommateur principal. L’isolation d’accès est applicative dans le premier backend ; elle n’est pas une sandbox contre du code arbitraire.

Entrées : ChamberReadRequest et ChamberPatch. Sorties : ChamberSnapshot et ChangeReceipt. Réception : lecture d’une révision figée, refus d’un handle hors périmètre, conflit de révision et projection sans exposition des éléments non demandés.

## F3 — Journal d’exécution et reprise durable

**Responsabilité de fichiers :** `src/nimfactory/runtime/journal/`. Tests unitaires correspondants dans `tests/f3/`.

**Dépendances de développement :** Contrats F0 ; références d'artefacts sans importer F1.

**Livraison attendue :** RunStore durable, outbox, déduplication, reprise et état des effets inconnus. Reçu : `docs/deliveries/F3.md`.

Conserver événements, activations, tentatives, propriétaires, messages à délivrer et références des résultats. Backend proposé : SQLite local, derrière RunStore ; réutiliser un mécanisme durable du SDK s’il fournit déjà les garanties requises.

Le changement d’état d’une activation et l’ajout des messages qu’il produit sont validés dans une même transaction. Une outbox publie ensuite ces messages ; l’acquittement confirme leur prise en compte durable. La réception peut se produire plusieurs fois : la consommation reconnaît message_id et la même transition ne crée pas deux effets logiques.

La reprise reconstitue l’état depuis les données persistées. Une invocation déjà validée n’est pas redemandée par défaut. Une opération externe dont l’issue reste inconnue conserve ce statut et son reçu ; elle n’est pas convertie en succès ou réessayée automatiquement.

Un lease sert à suivre le propriétaire. Un nouvel epoch permet de refuser une livraison tardive d’un ancien propriétaire, sans prétendre arrêter son processus. Les effets externes nécessitent leur propre déduplication ou réconciliation ; le bus ne garantit pas un exactly-once universel.

Réception : arrêts avant/après commit et avant/après publication, doublons, ancien résultat après reprise et opération inconnue. Ce lot n’implémente pas la politique métier des reprises.

## F4 — Graphe, ports et validation

**Responsabilité de fichiers :** `src/nimfactory/graph/`. Tests unitaires correspondants dans `tests/f4/`.

**Dépendances de développement :** Contrats F0 ; registre de handlers simulable.

**Livraison attendue :** GraphSpec, descripteurs de ports, validateur et diagnostics. Reçu : `docs/deliveries/F4.md`.

GraphSpec contient des nœuds nommés, des handlers versionnés, leurs ports typés, les liaisons, paramètres, sous-graphes et règles de terminaison. Les formats de ports sont des schémas métier ; les charges utiles passent par Message selon F0.

Le socle de contrôle comprend sequence, branch, map, join, reduce, loop, subgraph et await_event. branch utilise des prédicats structurés comme equals, exists, all, any ; pas une chaîne évaluée comme code. Un routage LLM est un nœud distinct dont la sortie est ensuite validée.

map fixe un ensemble de branches pour une activation ; join déclare all_required, quorum ou first_success, avec politiques sur échecs, arrivées tardives et annulation. all_required est le défaut. Les éléments partiels ne comptent que si le contrat le permet. reduce déclare sa fonction et un ordre stable si elle n’est pas commutative.

Le validateur contrôle schémas, ports requis, handlers, références, cycles et règles de boucle. Les cycles sont exprimés par loop avec condition de sortie et limite ; un câblage cyclique implicite est refusé. La limite produit un état explicite, pas un succès artificiel. Le mode synchrone ou asynchrone n’appartient pas à la sémantique du graphe.

Réception : graphes valides en séquence, bifurcation, parallélisme et boucle ; refus d’un port incompatible, cycle non déclaré et join impossible. Ce lot peut se qualifier sans lancer un agent.

## F5 — Exécuteur, tuyaux et ordonnanceur local

**Responsabilité de fichiers :** `src/nimfactory/runtime/executor/`. Tests unitaires correspondants dans `tests/f5/`.

**Dépendances de développement :** GraphValidator F4, RunStore F3, Transport et NodeHandler ; doublures possibles.

**Livraison attendue :** Exécuteur séquentiel et concurrent borné, tuyaux et contexte d'invocation. Reçu : `docs/deliveries/F5.md`.

Exécuter les activations prêtes sur une machine ; proposer une stratégie séquentielle et une stratégie concurrente bornée pour le même GraphSpec. Réutiliser le modèle d’asynchronisme choisi dans le SDK et éviter une dépendance à deux boucles événementielles incompatibles.

Les tuyaux ont une capacité et une politique de pression : attendre, refuser ou déporter en stockage selon le contrat. Ne jamais jeter silencieusement un message. Le contexte d’exécution porte annulation, délai, handles, portée de budget, snapshot et IDs.

Une activation lit un instantané, puis livre ses sorties et propositions de changement. L’ordonnanceur publie ces résultats via RunStore ; il ne donne pas aux nœuds un dictionnaire global mutable non contrôlé. Les arrivées concurrentes sont jointes par activation, port et branche, sans dépendre de l’ordre temporel pour les agrégations censées être déterministes.

Le transport initial peut être en mémoire avec persistance assurée par F3. Un adaptateur stdio permet de tester les workers séparés avec le codec F0. Les handlers synchrones longs doivent pouvoir être exécutés hors de la boucle d’événements lorsque nécessaire.

Réception : mêmes résultats pour des handlers déterministes en modes séquentiel/concurrent, concurrence plafonnée, tuyau saturé, délai, annulation et absence d’activation doublée. Une annulation d’un appel externe peut laisser un résultat ou une dépense inconnus.

## F6 — Hôte commun de préparateurs

**Responsabilité de fichiers :** `src/nimfactory/preparation/host/`. Tests unitaires correspondants dans `tests/f6/`.

**Dépendances de développement :** Ports ChamberStore, ArtifactStore, ToolCatalog et ModelBroker ; implémentations remplaçables.

**Livraison attendue :** Hôte de producteurs, demandes de complément, bootstrap et limites de récursion. Reçu : `docs/deliveries/F6.md`.

Exécuter un ProducerSpec déclarant rôle, version, schémas d’entrée/sortie, chambres lisibles, outils requis et stratégie deterministic ou model_assisted. Un préparateur produit des fragments et des besoins ; il ne concatène pas arbitrairement le prompt final.

requirements identifie les entrées nécessaires et prepare effectue le travail. Un besoin découvert tardivement produit needs avec chambre, sélecteur, caractère requis et raison. La recette décide de fournir ce complément, puis de reprendre. Les outils sont obtenus via un port commun réutilisant les dispatchers existants, et leurs résultats sont des artefacts.

Les préparateurs utilisant un modèle reçoivent un seed issu d’une recette de démarrage déterministe : contrat, objectif local et données nécessaires. Ils peuvent demander d’autres préparations par les mêmes interfaces. Le parentage des préparations permet de détecter une dépendance circulaire ; profondeur, nombre de raffinements et dépenses sont plafonnés par la recette et le budget parent.

Garder séparés le calcul courant et les propositions d’amélioration de ProducerSpec. Les recettes d’une exécution sont figées par version. Un nouveau préparateur ne se substitue pas à celui d’une tâche en cours.

Réception : un producteur déterministe et un producteur simulé utilisant les mêmes sorties ; demande de complément ; préparation récursive qui termine ; cycle détecté ; résultats hors schéma refusés.

## F7 — Prompt builder et contrat de tâche

**Responsabilité de fichiers :** `src/nimfactory/preparation/prompt/`. Tests unitaires correspondants dans `tests/f7/`.

**Dépendances de développement :** Contrats F0 et gabarits ; Producer et ModelBroker optionnel.

**Livraison attendue :** TaskIntent, fragment de tâche et couverture des exigences. Reçu : `docs/deliveries/F7.md`.

Construire l’énoncé opérationnel de l’étape à partir de la demande originale, des corrections et de la recette. TaskIntent contient goal, expected_outputs, requirements, exclusions, acceptance_checks et source_refs. Les contraintes déjà structurées restent des objets identifiés ; leur formulation originale est récupérable.

Le mode déterministe utilise un gabarit et des champs validés. Le mode assisté peut extraire ou reformuler une demande libre. Sa sortie distingue exigences explicites et hypothèses proposées ; une hypothèse ne devient pas une exigence utilisateur par simple reformulation. Les contrôles établissent la présence des contraintes déclarées, sans prétendre prouver toute l’équivalence sémantique.

Sortie : TaskIntent et fragment de tâche, avec couverture des requirement_id. Une ambiguïté importante produit un besoin explicite. Le module ne récupère pas lui-même tout l’historique ; il travaille avec les sources remises ou demande un complément.

Réception : corrections successives de la demande, négation, exception, exigence ancienne, reformulation qui invente un objectif et demande contradictoire. Un petit modèle est candidat pour extraction/classification ; les contraintes exactes restent disponibles.

Exemple de ContextRequest transmis comme charge utile :

```json
{
  "schema": "nimfactory.context-request/0.1",
  "preparation_id": "prep-001",
  "task_ref": "art-task-001",
  "stage": "patch.prepare",
  "recipe_ref": "art-recipe-001",
  "snapshot_ref": "art-snapshot-001",
  "required_requirements": ["req-01", "req-03"],
  "required_outputs": ["patch_proposal"],
  "model_profile": "coding.default",
  "input_limit_tokens": 12000,
  "output_reserve_tokens": 2000,
  "max_preparation_depth": 2,
  "budget_scope": "run-001"
}
```

Ces limites sont illustratives. input_limit_tokens est une limite de l’entrée complète, distincte de la réserve de sortie ; l’adaptateur vérifie aussi leur compatibilité avec la fenêtre réelle du modèle. Une valeur de configuration n’atteste pas la capacité d’un fournisseur.

## F8 — Factoriseur d’instructions système et métier

**Responsabilité de fichiers :** `src/nimfactory/preparation/instructions/`. Tests unitaires correspondants dans `tests/f8/`.

**Dépendances de développement :** Contrats F0 ; catalogue et prédicats de portée.

**Livraison attendue :** Unités d'instruction, sélection déterministe et reçu de sélection. Reçu : `docs/deliveries/F8.md`.

Stocker des unités d’instruction versionnées : id, texte exact, provenance/autorité, portée, caractère obligatoire, dépendances et exclusions. La portée est un prédicat sur des métadonnées déclarées : étape, rôle, projet, opération ou outil. Une source documentaire ne gagne pas une autorité d’instruction parce qu’un modèle la classe comme utile.

Deux fonctions : préparer le catalogue à partir des sources de référence ; sélectionner les unités applicables pour l’étape. Un petit modèle peut proposer le découpage et les étiquettes du catalogue. La sélection des règles de portée connues reste déterministe. Les modifications de portée ou d’autorité nécessitent une adoption explicite dans la configuration, distincte de la production d’un seed.

La fermeture des dépendances conserve les clauses nécessaires. Un conflit se résout uniquement par une règle explicite de priorité, portée ou remplacement ; sinon il est signalé. Ne pas laisser l’ordre d’arrivée décider quelle instruction reste applicable. Les unités obligatoires sont protégées du simple classement de pertinence.

Sortie : fragments d’instructions et selection_receipt indiquant les unités retenues/exclues et les raisons. Réception : règle hors étape absente, règle obligatoire présente, exception conservée, dépendance ajoutée, conflit non masqué et deux ordres d’entrée donnant la même sélection.

## F9 — Injecteur de skills et catalogue d’outils

**Responsabilité de fichiers :** `src/nimfactory/preparation/skills/`. Tests unitaires correspondants dans `tests/f9/`.

**Dépendances de développement :** Contrats F0 ; catalogue de cartes et port ToolCatalog.

**Livraison attendue :** Sélection d'unités de skills, dépendances, ressources et exigences d'outils. Reçu : `docs/deliveries/F9.md`.

Une SkillCard possède id/version, tâches couvertes, préconditions, unités d’instructions, ressources, dépendances, incompatibilités, outils requis et recettes de vérification. Une carte peut être indexée par sous-capacité ; elle est découpée en unités cohérentes, avec leurs prérequis.

Le résolveur reçoit la tâche et le profil de l’étape. Il sélectionne par métadonnées, puis ferme les dépendances. Un petit modèle peut départager plusieurs candidats sur un index compact. Sa décision est une proposition d’identifiants ; seuls des identifiants disponibles et compatibles sont acceptés.

Le résultat comprend SelectedSkillUnits, ResourceRefs et ToolRequirements. ToolCatalog traduit les exigences en outils réellement enregistrés : nom, schéma, version et disponibilité. Les schémas complets n’entrent dans le seed que pour les outils disponibles à cet appel. La découverte différée d’un outil est elle-même une capacité réelle, avec un prochain appel correctement matérialisé.

Réception : seules les unités requises sont chargées, dépendance indispensable conservée, cycle entre cartes détecté, outil introuvable signalé et carte obsolète non sélectionnée après remplacement. Descriptions et catalogues non nécessaires restent hors du prompt principal.

## F10 — Mémoire de travail

**Responsabilité de fichiers :** `src/nimfactory/memory/`. Tests unitaires correspondants dans `tests/f10/`.

**Dépendances de développement :** ChamberStore F2, simulable ; contrats F0.

**Livraison attendue :** MemoryItem, MemoryPatch, règles de transition et projections. Reçu : `docs/deliveries/F10.md`.

Maintenir un état opérationnel et épistémique à partir de changements explicites, sans réécrire continuellement un résumé global. Types d’items : requirement, fact, hypothesis, decision, open_question, pending_action, tool_result et rejected_option. Chaque item possède id, révision, statut, source, portée et liens de remplacement ou contradiction.

Les changements sont des MemoryPatch avec expectedRevision. Une décision nouvelle peut remplacer une décision ancienne, mais l’historique et le lien restent disponibles. Une preuve ne devient pas une décision, une hypothèse ne devient pas un fait et un résultat non observé ne devient pas un succès.

La projection reçoit tâche/étape et sélectionne exigences actives, actions en cours, conclusions utiles et inconnues. Le transcript est une source d’événements ; les récents tours n’ont pas une priorité automatique. Une ancienne contrainte encore applicable reste projetable. Les échanges outils en cours sont identifiés afin que leur restitution respecte le protocole fournisseur.

Un petit modèle peut proposer des items depuis des observations narratives. Le commit, les transitions autorisées et les contrôles de références sont déterministes. Les désaccords non résolus sont conservés.

Réception : correction d’un fait, hypothèse réfutée, décision ancienne utile, deux observations contradictoires, double application du même événement, écriture concurrente et reprise d’une action en attente.

## F11 — Sources, recherche et sélection documentaire

**Responsabilité de fichiers :** `src/nimfactory/retrieval/`. Tests unitaires correspondants dans `tests/f11/`.

**Dépendances de développement :** ArtifactStore, SnapshotSource et port d'index ; doublures possibles.

**Livraison attendue :** EvidenceQuery, EvidenceBundle, extraits sourcés et dépendances négatives. Reçu : `docs/deliveries/F11.md`.

Fournir un port de recherche indépendant de la méthode : lookup par ID/symbole, recherche lexicale, graphe de relations ou recherche sémantique optionnelle. Aucun moteur vectoriel n’est obligatoire pour cette première version.

Une requête précise objectif local, corpus/snapshot, types d’éléments et limites. La réponse retourne candidats, références, plages exactes, score de recherche éventuel et état de couverture : complete_for_query, truncated ou unavailable. Le score de recherche ne prouve pas la vérité ou la pertinence finale.

Un sélecteur peut compléter les passages avec leurs dépendances : définition d’un symbole, parent d’une clause, contre-exemple connu ou source d’un résumé. Un petit modèle peut classer un petit ensemble de candidats et renvoyer leurs IDs, puis une extraction programmatique produit les passages exacts. Les synthèses éventuelles restent explicitement dérivées avec sources et limites.

Sortie : EvidenceBundle contenant les fragments, read set et besoins restant ouverts. Le read set inclut la version de l’index et les requêtes sans résultat, afin qu’un cache puisse être invalidé lorsqu’un élément auparavant absent apparaît.

Réception : source modifiée, passage tronqué, extrait dépendant d’une définition absente, contradiction utile et nouvel élément correspondant à une ancienne requête vide.

## F12 — Assembleur d’inférence, seed et matérialisation

**Responsabilité de fichiers :** `src/nimfactory/preparation/assembly/`. Tests unitaires correspondants dans `tests/f12/`.

**Dépendances de développement :** Fragments, ModelPlan, ArtifactStore, compteur et port ProviderAdapter ; doublures possibles.

**Livraison attendue :** SeedAssembler, InferenceSeed et PreparationReceipt ; aucune sélection autonome de nouveau modèle. Reçu : `docs/deliveries/F12.md`.

Recevoir ContextRequest et les résultats de préparateurs. Réunir leurs fragments sur un snapshot compatible, vérifier les dépendances, la couverture des exigences déclarées et le budget complet. Cet assembleur est principalement déterministe.

Un fragment contient son rôle sémantique et sa provenance ; le rôle API final est attribué par la politique de matérialisation, sans promotion automatique d’une source ou synthèse en instruction système. Les fragments peuvent pointer vers du texte exact, une extraction ou une synthèse dérivée.

```json
{
  "schema": "nimfactory.context-fragment/0.1",
  "fragment_id": "fragment-001",
  "kind": "instruction",
  "content_ref": "art-text-001",
  "origin_refs": ["art-policy-001"],
  "instruction_ref": "rule-007",
  "required": true,
  "covers_requirements": ["req-03"],
  "depends_on": ["fragment-002"],
  "scope": {"stages": ["patch.prepare"]},
  "derivation": "verbatim",
  "producer_ref": "art-producer-spec-001"
}
```

kind peut valoir instruction, task, memory, evidence ou tool_guidance. derivation vaut verbatim, extractive ou synthetic. instruction_ref doit désigner une unité applicable du catalogue F8 pour prétendre à une autorité d’instruction ; le champ seul ne la confère pas.

Assembler l’ensemble requis puis les éléments facultatifs selon la politique de sélection. Si les éléments requis dépassent la capacité, retourner blocked avec insufficiency ; ne pas les tronquer silencieusement. La sélection facultative est déterministe et préserve les dépendances. Une compaction ou recherche complémentaire est demandée à un préparateur, avec nouveau résultat inspectable.

Le compte d’entrée inclut messages, outils, schémas et enveloppes réellement matérialisés. Le mode de comptage et sa marge sont indiqués ; une estimation n’est pas présentée comme exacte. L’ordre est stable par politique, importance, dépendances et identifiant. Un fragment récent ne remplace pas un ancien par simple position.

InferenceSeed est immuable et référence : ContextRequest, snapshot, fragments sélectionnés, unités d’instruction, outils, binding fournisseur/modèle résolu, capacités et politique de sortie. La sélection du binding précède la matérialisation finale. Un changement de modèle demande une nouvelle matérialisation et un nouveau contrôle de fenêtre, outils, schémas et coût à partir des fragments d’origine. PreparationReceipt conserve inclusions, omissions, besoins et transformations hors du prompt. context_overview est facultatif, avec son propre destinataire et son budget ; il ne duplique pas automatiquement le seed.

L’adaptateur fournisseur matérialise les Message existants et les schémas d’outils. Il signale les rôles ou capacités non supportés ; aucun changement silencieux de niveau d’instruction ou de protocole. Pour des appels outils en cours, préserver les identifiants et les paires nécessaires.

Réception : même entrée et versions → même seed logique ; instruction obligatoire non perdue ; refus d’un fragment incohérent ; outil réellement invocable ; budget mesurant la requête complète ; aperçu absent lorsqu’inutile ; modification d’une source invalidant la préparation dépendante.

## F13 — Courtier de modèles, petits modèles et escalade

**Responsabilité de fichiers :** `src/nimfactory/inference/`. Tests unitaires correspondants dans `tests/f13/`.

**Dépendances de développement :** BudgetLedger F14, ProviderAdapter et validateurs ; doublures possibles.

**Livraison attendue :** ModelBroker, registre de profils/bindings, fournisseur scripté et protocole de repli. Reçu : `docs/deliveries/F13.md`.

Séparer ModelProfile (besoin logique) de ProviderBinding (fournisseur/modèle concret). Un registre décrit capacités, limites, coût connu/estimé, latence mesurée, mode local/distant et qualifications par type de tâche. Aucun nom de modèle ni prix n’est codé en dur dans les préparateurs.

Priorité proposée : règle déterministe, puis petit modèle qualifié, puis modèle plus capable si la politique le permet. Cette cascade n’est pas obligatoire pour une tâche où un appel direct au modèle fort est moins coûteux au total.

Les petits modèles sont candidats pour extraction de champs, classification d’étape, sélection d’IDs de skills, classement de passages, détection de doublons et propositions de changements de mémoire. Ils ne déterminent pas seuls l’autorité des instructions, la vérité des preuves, la disponibilité des outils ou la validité d’une modification du dépôt.

Chaque route associe tâche, profils autorisés, validateur, raisons de repli et limite d’effort. Une confidence déclarée par le modèle est un signal non calibré, jamais l’unique critère d’acceptation. Une sortie conforme au schéma peut être fausse : le validateur vérifie aussi les références, plages, contraintes et cas de domaine vérifiables.

```json
{
  "schema": "nimfactory.model-route/0.1",
  "task_kind": "evidence.select_ids",
  "preferred_profiles": ["small.selector", "strong.selector"],
  "output_schema": "nimfactory.evidence-selection/0.1",
  "validator": "source_ids_and_required_coverage/0.1",
  "escalate_on": ["invalid_output", "coverage_gap", "unsupported_case"],
  "max_provider_sends": 2,
  "on_exhausted": "blocked"
}
```

preferred_profiles ne décrit pas forcément deux envois : la route peut décider qu’un profil n’est pas qualifié et commencer au suivant. Tout nouvel appel de réparation, vérification par LLM ou repli compte dans max_provider_sends et le budget global.

Le protocole évite une dépendance circulaire : plan(task_kind, capabilities, budget) retourne un ModelPlan et un binding précis ; F12 prépare le seed pour ce binding ; infer(seed_ref, binding_ref) exécute cette tentative. Un repli retourne reprepare_required avec le prochain binding. Le contrôleur de la recette rappelle F12 à travers un port, puis rappelle infer pour le nouveau binding. Le broker est l'unique demandeur de réservation pour un envoi fournisseur : il réserve auprès de F14 avant de remettre la tentative au transport ; le contrôleur ne réserve pas une seconde fois. Le broker n’importe pas l’implémentation de l’assembleur. Les identifiants du modèle et sa version disponible sont figés dans le plan ; un alias fournisseur mutable reste signalée si sa version réelle ne peut être obtenue.

InferenceRequest contient seed_ref, binding_ref, schéma de sortie, limites, validation et portée budgétaire. InferenceResult sépare réponse brute, objet parsé, verdict, usage mesuré/estimé/inconnu et identifiants fournisseur. Les versions de modèle, options et route sont conservées. Les appels passent uniquement par ce port pour que leur coût soit observable.

Réception : petit modèle accepté sur preuve vérifiable, hallucination d’ID refusée, JSON valide mais incomplet refusé, escalade bornée, aucun envoi après budget épuisé et route forte directe pour un cas non qualifié.

## F14 — Budgets partagés et comptabilité

**Responsabilité de fichiers :** `src/nimfactory/budget/`. Tests unitaires correspondants dans `tests/f14/`.

**Dépendances de développement :** Contrats F0 ; backend transactionnel local.

**Livraison attendue :** Ledger atomique, états de réservation et réconciliation par tentative. Reçu : `docs/deliveries/F14.md`.

BudgetLedger est l’autorité pour les réservations. Les plafonds de projet, run, préparation et tâche sont imbriqués : une sous-tâche consomme le budget parent. Les appels simultanés réservent de façon atomique, avec montants et nombres d’envois maximum.

Réserver avant chaque envoi effectif au fournisseur, puis réconcilier à partir de l’usage reçu. Les retries opaques du transport sont désactivés ou raccordés au même mécanisme. Un timeout après émission conserve une réserve inconnue ; elle n’est pas rendue disponible parce que la réponse a disparu. releaseBeforeSend n’est autorisé que si l’absence d’envoi est établie.

Distinguer jetons d’entrée/sortie, jetons cachés lorsqu’ils sont rapportés, estimation, coût fournisseur et ressources locales. Une absence de compteur n’est pas un zéro. Un plafond monétaire strict nécessite une borne de prix et d’usage utilisable ; sinon ce mode signale une capacité non garantie au lieu de prétendre plafonner.

Les écritures sont idempotentes par inference_attempt_id. Si F3 et le ledger ne partagent pas la même transaction, leur réconciliation s’appuie sur cet identifiant et un état autoritatif, sans promettre une transaction distribuée. Les dépenses réelles d’une tentative devenue obsolète restent comptées même si son résultat n’est plus accepté.

Réception : deux réservations concurrentes proches du plafond ; reprise après réservation ; envoi inconnu ; doublon de reçu ; plusieurs sous-tâches et coût d’un relecteur ou préparateur inclus.

## F15 — Cache de préparations et invalidation

**Responsabilité de fichiers :** `src/nimfactory/cache/`. Tests unitaires correspondants dans `tests/f15/`.

**Dépendances de développement :** ArtifactStore et ReadSet ; versions de politiques et scopes.

**Livraison attendue :** CacheRecord, calcul de clé, invalidation et partage de calcul strictement borné par scope. Reçu : `docs/deliveries/F15.md`.

Mettre en cache les transformations pures, projections et seeds lorsque leurs dépendances sont connues. La clé comprend schéma de demande, tâche/étape, entrées exactes, snapshots, recette, préparateur, configuration, politique d’instructions et outils. Pour un résultat de modèle : fournisseur/modèle, options et politique de réutilisation également.

Le cache conserve le read set effectif et les dépendances négatives : recherches vides, absence de fichier, version d’index. Une simple clé sur le texte du prompt n’est pas suffisante pour garantir la fraîcheur.

Les invalidations parcourent un graphe de dépendances ; un changement de mémoire n’invalide pas les instructions indépendantes. Un changement de portée, d’autorité ou de périmètre de lecture invalide la réutilisation concernée. Deux préparations identiques concurrentes peuvent partager un calcul en cours, sans diffuser des données entre périmètres différents.

Une sortie stochastique réutilisée est un résultat antérieur valide selon la politique, pas une preuve que l’appel est déterministe. Les opérations à effets externes utilisent la déduplication et la reprise de F3, pas un cache de fonctions pures.

Réception : répétition sans recalcul, modification ciblée, nouveau document après recherche vide, évolution d’un outil, isolation des scopes et conservation d’un résultat valide malgré une modification sans rapport.

## F16 — CLI, inspection et assemblage local

**Responsabilité de fichiers :** `src/nimfactory/application/`, `src/nimfactory/cli/`, `src/nimfactory_cli.nim`. Tests unitaires correspondants dans `tests/f16/`.

**Dépendances de développement :** Façades publiques de tous les composants utilisés ; doublures explicites au début.

**Livraison attendue :** CLI, composition des adaptateurs, recettes de démonstration et parcours installé. Reçu : `docs/deliveries/F16.md`.

La CLI dépend des façades publiques et peut être développée avec des doublures. Proposer des commandes de validation du graphe, préparation du contexte, inspection du seed/reçu, exécution, reprise, événements et compteurs. Les noms exacts sont libres, mais les schémas de sortie sont communs.

Mode humain et mode JSON sont distincts. stdout machine contient uniquement du JSON/NDJSON ; stderr reçoit les diagnostics humains. Codes de sortie proposés : 0 succès, 2 entrée invalide, 3 blocage nécessitant résolution, 4 échec d’exécution, 130 interruption. Un résultat partial retourne 3 sauf politique d’acceptation explicite du run.

L’inspection affiche les sources, exigences couvertes, fragments omis et leur raison, budget mesuré/estimé, modèle choisi et état de reprise. L’affichage des textes bruts est explicite pour éviter de recopier tous les contenus à chaque commande.

Les dépendances concrètes sont composées ici ou dans une petite façade applicative. Le profil minimal fait fonctionner stockage, graphe, préparateurs déterministes et fournisseur simulé. Les fournisseurs, index et transports optionnels ne deviennent pas des dépendances obligatoires du noyau.

Réception : parcours depuis un consommateur du paquet installé, fonctionnement sans clé fournisseur en mode simulé, sortie JSON exploitable, reprise réelle sur disque et message d’erreur utile pour une capacité absente.

## F17 — Banc de qualification indépendant des implémentations

**Responsabilité de fichiers :** `tests/qualification/`, `tests/fixtures/qualification/`. Tests unitaires correspondants dans `tests/f17/`.

**Dépendances de développement :** Contrats F0 et façades publiques ; pas de lecture des implémentations pour fabriquer l'oracle.

**Livraison attendue :** Corpus, oracles, scénarios de panne et comparaison avec comptabilité complète. Reçu : `docs/deliveries/F17.md`.

Construire un corpus figé, des oracles explicites et des scénarios de panne à partir des contrats publics. Le banc peut être préparé avant les autres lots avec des sorties de référence. Il ne doit pas déduire le résultat attendu depuis le code testé.

Cas essentiels : vieille contrainte pertinente ; derniers tours inutiles ; skill volumineuse hors sujet ; dépendance indispensable d’une petite skill ; contradiction de mémoire ; correction utilisateur ; source changée ; recherche auparavant vide ; petit modèle produisant une sélection plausible mais fausse ; annulation et reprise ; boucle sans progrès ; budget concurrent ; effet fournisseur inconnu.

Comparer trois modes sur mêmes tâches, modèles et critères : assemblage simple historique, préparation par chambres déterministe, puis préparation hybride avec petits modèles. Mesurer qualité finale et erreurs de sélection, tokens totaux de tous les rôles, latence, coût fournisseur, consommation locale et reprises. Conserver un lot de tâches réservé à la qualification après réglage des recettes.

Les fixtures et fournisseurs scriptés démontrent les contrats et les reprises. Ils ne démontrent pas la qualité d’un modèle réel. Les expériences réelles constituent une campagne séparée, avec enveloppe explicite et mêmes données ; aucune dépense nouvelle n’est engagée par cette spécification.

Réception : un préparateur qui renvoie toujours la même sortie échoue sur les cas discriminants ; un cache périmé est détecté ; le mode simulé ne se présente pas comme qualification réelle ; toute comparaison compte la préparation et les évaluateurs LLM dans le coût.

## Ordre d’assemblage et travaux parallèles

F0 est le seul socle à stabiliser ensemble : définitions, adaptateur Message et fixtures. Pendant ce travail, les autres lots peuvent préparer leurs contrats locaux et cas de qualification. Ensuite :

| Vague | Lots pouvant être développés séparément | Résultat visé |
| --- | --- | --- |
| A | F1, F3, F4, F14 ; F17 commence | Stockage, durable, description du graphe, budgets et oracles |
| B | F2, F5, F13, F16 | Chambres, exécution, routage de modèles et CLI sur ports |
| C | F6, F7, F8, F9, F10, F11, F12, F15 | Préparateurs et fabrication du seed |
| D | Raccordement des adaptateurs et F17 | Parcours complet, pannes et comparaison mesurée |

Ces vagues indiquent l’ordre d’intégration, pas une interdiction de commencer un lot avec des doublures. Les dépendances restent des interfaces ; un codeur peut développer F12 avant le véritable F2 avec des fragments de référence.

## Jalons observables

1. M0 : même Message et mêmes charges utiles lus/écrits sans perte ; schémas et fixtures publiés.
2. M1 : graphes déterministes et tuyaux fonctionnels depuis la CLI, état durable et reprise.
3. M2 : chambres et préparateurs déterministes produisant un seed et un reçu inspectables.
4. M3 : ajout d’un petit modèle sur une tâche circonscrite, validation et escalade sous budget partagé.
5. M4 : invalidation sélective, graphes de préparateurs, boucle de complément et mesure comparative.

Pour commencer concrètement, répartir F0 à un intégrateur, puis F1, F4, F8, F10 et F17 à des travaux indépendants selon la capacité disponible. F3 et F14 peuvent aussi avancer séparément avec un contrat commun de réconciliation. Il n’est pas nécessaire d’ouvrir les dix-huit lots simultanément.

## Contenu attendu pour la revue de chaque livraison

- Identifiant du lot, dépôt, base SHA, candidat SHA et portée des changements.
- Schémas consommés/produits et versions, avec fixtures.
- Adaptateurs réels et doublures utilisés ; les doublures sont nommées comme telles.
- Exemple consommateur ou commande de recette qui ne dépend pas des chemins privés du checkout du codeur.
- Comportements vérifiés, résultats et limites ; tests pertinents de panne/concurrence si le lot porte ces garanties.
- Changements proposés au contrat commun et raison ; pas de fork silencieux du type Message.
- Dépendances restantes et écarts entre proposition et livraison.

La revue peut accepter un composant conforme à son contrat alors que son adaptateur final est encore à raccorder. Elle distingue conformité locale, intégration et preuve de bout en bout. Toute capacité déjà disponible dans NimAgent doit être réutilisée ou raccordée avant d’être reconstruite.

## Références de conception

Le découpage et les contrats ci-dessus sont une proposition adaptée à NimFactory. La cascade de modèles s’appuie sur le principe étudié par [FrugalGPT](https://arxiv.org/abs/2305.05176), sans reprendre ses chiffres comme promesse pour ce projet. [RFC 8785](https://www.rfc-editor.org/rfc/rfc8785.html) fournit la référence de canonicalisation JSON. [Graph API LangGraph](https://docs.langchain.com/oss/python/langgraph/graph-api) constitue un précédent pour les nœuds, transitions et sous-graphes. [Meta Context Engineering](https://arxiv.org/abs/2601.21557) étudie l’évolution des compétences qui construisent des artefacts de contexte ; cette évolution reste hors du premier jalon.

## Index des charges utiles à figer dans F0

Ce tableau complète les exemples ; les champs marqués ? sont facultatifs. Les listes ne dispensent pas de déclarer les enums, nullabilités, tailles et contraintes croisées dans les schémas livrés. Une ArtifactRef pointe vers un objet immuable du stockage F1 ; les références de registre conservent leur type et leur règle de résolution. Les limites de contexte s’appliquent à la requête fournisseur complète, pas à la seule somme des textes.

| Objet | Champs minimaux |
| --- | --- |
| SourceSnapshot | snapshot_id, captured_at, source_revisions[], chamber_revisions[], recipe_refs[], index_revisions[] |
| ChamberReadRequest | chamber_id, snapshot_ref, selector, purpose, max_bytes?, max_items? |
| ChamberReadResult | state, item_refs[], next_cursor?, omitted_count?, diagnostics[], read_set_ref |
| ChamberPatch | chamber_id, expected_revision, event_id, operations[], origin_refs[] |
| TaskIntent | task_id, source_refs[], goal, requirements[], exclusions[], hypotheses[], expected_outputs[], acceptance_checks[] |
| InstructionUnit | id, version, text_ref, authority_ref, scope, required, depends_on[], supersedes[] |
| SkillCard | id, version, capabilities[], applicability, instruction_unit_refs[], resource_refs[], requires_skills[], requires_tools[], verification_refs[] |
| MemoryItem | id, revision, kind, content_ref, status, source_refs[], scope, supersedes[], contradicts[] |
| EvidenceQuery | query_id, snapshot_ref, corpus_ids[], selector, required_topics[], max_candidates |
| EvidenceBundle | query_id, fragment_refs[], coverage_state, read_set_ref, needs[] |
| ProducerSpec | id, version, input_schema, output_schema, required_chambers[], required_tools[], strategy, recipe_ref |
| NodeInvocation | activation_id, attempt_id, epoch, handler_ref, input_refs, config_ref?, snapshot_ref, budget_scope |
| GraphSpec | graph_id, version, nodes[], edges[], entrypoints[], outputs, loop_specs[] |
| ModelPlan | plan_id, task_kind, candidates[], selected_binding_ref, validator_ref, remaining_sends, budget_scope |
| InferenceSeed | seed_id, request_ref, snapshot_ref, fragment_refs[], selected_instruction_ids[], tool_refs[], binding_ref, output_contract_ref, materialization_policy_ref |
| PreparationReceipt | seed_ref, read_set_ref, included[], omitted[], missing[], transformations[], coverage[], token_accounting, diagnostics[] |
| CacheRecord | key, output_refs, read_set_ref, producer_ref, policy_ref, created_at, validity |
| UsageReceipt | inference_attempt_id, reservation_id, binding_ref, sent_state, input_tokens?, output_tokens?, cached_tokens?, accounting_kind, cost_microusd?, source_ref? |

Les champs dynamiques du routage et de l’exécution vont dans les métadonnées communes ou NodeInvocation, selon le mapping F0 ; les duplications éventuelles sont validées pour égalité.

## Exemple de graphe minimal

Cet exemple représente un assemblage de deux préparations déterministes. Les contrats de ports appartiennent au registre de handlers. Le port d’entrée de la tâche est distribué par une entrée explicite ; chaque producteur renvoie un FragmentsBundle, y compris un bundle vide explicitement valide si aucune unité optionnelle ne s’applique.

```json
{
  "schema": "nimfactory.graph/0.1",
  "graph_id": "seed-basic",
  "version": 1,
  "nodes": [
    {"id": "task", "handler": "prompt.prepare@0.1"},
    {"id": "rules", "handler": "instructions.select@0.1"},
    {"id": "seed", "handler": "seed.assemble@0.1"}
  ],
  "entrypoints": [
    {"input": "context_request", "to": "task.request"},
    {"input": "context_request", "to": "rules.request"},
    {"input": "context_request", "to": "seed.request"},
    {"input": "model_plan", "to": "seed.model_plan"}
  ],
  "edges": [
    {"from": "task.fragments", "to": "seed.task_fragments"},
    {"from": "rules.fragments", "to": "seed.instruction_fragments"}
  ],
  "outputs": {"seed": "seed.seed", "receipt": "seed.receipt"},
  "loop_specs": []
}
```

Le handler seed.assemble exige ses ports request, model_plan, task_fragments et instruction_fragments ; il ne démarre pas après la première arrivée. Si une branche échoue, sa politique d’erreur débloque explicitement le run en échec/blocage ou en repli autorisé ; le join ne reste pas éternellement en attente. Les boucles de demande de complément et les chambres supplémentaires peuvent être ajoutées ensuite par la recette.

## Compléments de contrat pour une implémentation séparée

Ces précisions complètent les exemples sans présumer de la forme exacte de `Message`. F0 les encode dans les types et les fixtures effectivement retenus.

### Références, validation et identité

- `ArtifactRef` résout un objet immuable vérifié. `HandlerRef` résout un handler versionné. Une référence d'instruction se résout dans le catalogue figé par le snapshot. Ne pas confondre ces types sous prétexte qu'ils ont tous une forme textuelle.
- Les valeurs `art-…`, `rule-…` et `run-…` des exemples sont illustratives ; elles ne prouvent ni une existence d'objet ni une grammaire définitive.
- Le champ `schema` identifie le schéma racine. En version 0.1, seules les versions explicitement déclarées compatibles sont acceptées ; ne pas interpréter automatiquement toute version 0.x comme équivalente.
- Les champs métier inconnus sont rejetés, sauf espace `extensions` facultatif prévu par le schéma. Une capacité requise inconnue produit un échec explicite.
- Les entiers de taille non représentable sans perte dans le codec JSON retenu passent par une représentation textuelle déclarée. Les montants sont des entiers en micro-USD sérialisés en chaînes, sans calcul en flottants.
- Les hashes d'objets binaires portent sur leurs octets exacts. Les hashes de structures utilisent la canonicalisation commune. Les traces volatiles — timestamps, durée, nouvel identifiant d'exécution — ne modifient pas l'identité logique d'une transformation pure.
- Le schéma indique pour chaque champ s'il est obligatoire, facultatif ou nullable. Omission et `null` ne sont pas interchangeables par défaut.

### Charges utiles supplémentaires à stabiliser en F0

| Objet | Champs et invariants minimaux |
| --- | --- |
| `ArtifactManifest` | Identité du contenu, hash et algorithme, MIME, taille en octets ; origine et dérivations dans un enregistrement de provenance. Plusieurs provenances peuvent viser les mêmes octets sans écraser un manifeste existant. |
| `ReadSet` | Références et révisions effectivement lues ; sélecteurs, versions d'index et recherches sans résultat ; portée de lecture. Un cache ne peut pas omettre les dépendances négatives connues. |
| `ContextRequest` | Champs de l'exemple F7 ; parent de préparation optionnel, limites de raffinements et scope hérités de la recette. Le profil demandé et le binding résolu doivent être compatibles. |
| `NeedRequest` | Identifiant, préparation parente, chambre ou source cible, sélecteur, raison, caractère requis et limite de lecture ; un besoin ne donne pas lui-même un droit d'accès supplémentaire. |
| `FragmentsBundle` | Schéma, liste `fragment_refs`, `read_set_ref`, `needs`, diagnostics. Un bundle vide peut être valide ; une lecture indisponible ne doit pas se déguiser en liste vide. |
| `HandlerDescriptor` | Nom/version, schémas de ports d'entrée et de sortie, ports requis, paramètres, capacités et classe d'effet déclarée. Le code effectif reste responsable de respecter ce contrat. |
| `ModelProfile` | Identité/version, tâche ou capacité logique, contraintes et politique de qualification. Aucun nom de modèle nécessaire dans les producteurs. |
| `ProviderBinding` | Fournisseur, modèle/version si disponible, capacités, limites, options, prix ou état inconnu, référence de configuration. Les secrets sont fournis par l'environnement d'exécution, pas par les artefacts. |
| `InferenceRequest` | Seed, binding, contrat de sortie, validateur, limites et portée budgétaire. Toute matérialisation utilisée doit correspondre au seed et au binding déclarés. |
| `InferenceResult` | Réponse brute référencée, sortie parsée éventuelle, verdict, état de transport, usage et identifiants fournisseur ; `reprepare_required` transporte le prochain binding sans envoyer automatiquement. |
| `MemoryPatch` | Chambre cible, révision attendue, identifiant d'événement, opérations typées et sources ; événements rejoués reconnus. |
| `BudgetReservation` | Identifiant, tentative fournisseur, chaîne de scopes, limites réservées et état. Les transitions et compensations ont un propriétaire autoritatif. |
| `ChangeReceipt` | Révision attendue et observée, nouvelle révision si commit, références des changements ou conflit explicite. |

Les secrets ne sont pas inclus dans les clés de cache, seeds, reçus ou logs. Une référence de configuration peut identifier un profil d'accès sans porter la valeur du secret.

### Message, résultat et ports

La charge métier passe par le `Message` commun, directement ou par référence. Un `FactoryMeta` compagnon est permis si l'API réelle ne sait pas porter toutes les métadonnées. Le codec F0 doit préserver leur association en mémoire, lors du transport et après journalisation.

L'enveloppe de transport peut avoir deux champs `factory` et `message`. La forme de `message` est celle du codec existant, relevée en F0 ; ce document ne lui invente pas des champs de rôle ou de contenu.

Le résultat commun est l'enveloppe de livraison du handler. Son dictionnaire `outputs` référence les artefacts correspondant aux sorties déclarées. F0/F4 fixent un mapping explicite entre nom de sortie du résultat et port du handler : aucun rapprochement heuristique fondé sur un suffixe `_ref`.

Pour l'exemple du graphe, `task.fragments` et `rules.fragments` désignent chacun un port de type `FragmentsBundle`. Le bundle peut être résolu depuis l'artefact `fragments_ref` renvoyé par le handler. `seed.seed` et `seed.receipt` désignent respectivement `InferenceSeed` et `PreparationReceipt`. Ce mapping appartient au registre de handlers, pas à un parseur improvisé par F5.

Un `ok` signifie que les sorties requises du handler sont disponibles et valides. Un `partial` exige des sorties identifiées comme partielles et une politique de consommation déclarée. `blocked` fournit les besoins ou contraintes non satisfaits. `failed` décrit un échec. `cancelled` ne prouve pas qu'aucun effet externe n'a eu lieu.

### Limites de taille et de ressource

F0 fixe une configuration de limites : taille d'enveloppe NDJSON, taille des champs inline, profondeur JSON, nombre d'items et limites de lecture. Les contenus trop volumineux sont référencés dans F1 ; ils ne passent pas librement en inline.

Ces limites sont validées à l'entrée et signalent un diagnostic précis. Elles ne tronquent jamais implicitement une instruction ou un résultat. Les valeurs sont configurables ; aucune valeur arbitraire de ce document ne vaut benchmark.

### Snapshots, clôture et lectures complémentaires

Une source mutable est capturée avant sa consommation. Le snapshot fige les révisions disponibles, tandis que le read set enregistre ce qui a effectivement contribué au résultat.

Si une demande de complément reste dans ces révisions, elle enrichit les dépendances. Si elle exige une révision nouvelle, créer un nouveau snapshot, invalider les préparations concernées et produire un nouveau seed. Une préparation ne devient pas reproductible en enregistrant seulement le chemin actuel de ses fichiers.

Une chambre close reste hors du contexte du consommateur principal jusqu'à projection explicite. Le même principe vaut pour l'historique conservé côté fournisseur : sessions isolées ou état distant représenté et contrôlé. Ne pas prétendre maîtriser le seed tout en laissant un historique invisible être ajouté à l'appel.

### Effets et reprise

Chaque handler déclare une classe d'effet, par exemple lecture/pur, mutation locale transactionnelle, effet externe dédupliquable ou effet externe non réconcilié. F3/F5 utilisent cette information pour refuser un retry automatique incompatible ; la déclaration seule ne crée pas l'idempotence.

Un effet externe peut nécessiter un identifiant d'opération distinct, stable entre tentatives si le fournisseur accepte une clé de déduplication. Les tentatives d'envoi restent distinctes pour la comptabilité.

Une erreur de validation de réponse ne rembourse pas l'appel. Un résultat tardif refusé par l'epoch courant n'efface pas sa dépense. Une annulation ne signifie pas qu'un transport a arrêté le traitement distant.

### Progression et permissions de budget

Une recette fixe séparément les limites de boucle métier, de complément de contexte, de profondeur de préparation et de nombre d'envois fournisseur. Une seule limite globale d'itérations ne suffit pas à décrire ces mécanismes.

Le compteur des envois et les plafonds monétaires sont communs aux branches. Une politique locale ne peut pas augmenter le budget parent. Les retries des bibliothèques sont désactivés ou observés avant chacun de leurs envois.

La présente spécification autorise la réalisation et la qualification locale des composants ; elle n'accorde aucune enveloppe financière nouvelle. Une campagne réelle utilise un budget explicitement configuré et autorisé.

## Format de reçu de livraison

Créer `docs/deliveries/F<n>.md`, sans préremplir les résultats avant leur observation.

```markdown
# F<n> — Livraison
Date :
Périmètre demandé :
Base inspectée :
Révision testée ou diff non commité :
Version de Nim / révision NimAgent réellement utilisées :

## Réalisé
Comportements observables, interfaces et exemple consommateur.

## Contrats et intégrations
Contrats consommés/produits et changements.
Adaptateurs réels.
Doublures utilisées et raccordements manquants.

## Vérification
Commandes effectivement exécutées, résultats et artefacts de preuve.
Cas de panne ou concurrence pertinents.
Appels LLM réels : nombre, budget et coût mesuré/estimé/inconnu.

## Limites
Obligations non satisfaites, écarts et adaptations proposées.

## État
Conformité du composant :
Intégration réelle :
Parcours complet :
```

Un autre agent doit pouvoir reprendre ce reçu sans relire une conversation. Ne pas y copier de secrets ni des traces volumineuses récupérables par référence.

