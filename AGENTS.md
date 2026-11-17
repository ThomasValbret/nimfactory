# NimFactory — cadre de travail des agents

Version 0.2 de travail · 17 novembre 2026  
Statut : architecture proposée pour fonder le dépôt ; aucun lot n'est déclaré implémenté par ce document.

## 1. Mission du projet

NimFactory est un moteur local de production logicielle, écrit en Nim, qui compose des traitements déterministes et des agents. Les agents de la factory sont en Nim ; les logiciels qu'ils produisent peuvent utiliser d'autres langages.

La priorité initiale est la plomberie : contrats, communication, artefacts, chambres de contexte, graphes, tuyaux, boucles, préparation des inférences, reprise et CLI. Le responsable du projet conserve la conception fine des workflows métier.

NimAgent fournit les primitives réutilisables d'agent. La factory apporte la coordination et la préparation des travaux. Elle réutilise le type `Message` existant et ses mécanismes compatibles. Elle ne crée pas un deuxième SDK d'agents.

Le dépôt doit permettre de demander simplement : **« Occupe-toi de F1. »** Cette instruction désigne le lot F1 de [docs/WORK_PACKAGES.md](docs/WORK_PACKAGES.md), dans le cadre décrit ici et dans [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## 2. Comment prendre un lot

1. Lire ce fichier et l'architecture. Dans le catalogue, lire les contrats communs, le lot demandé, sa ligne dans la table des responsabilités et les critères de livraison. Charger ensuite les seuls voisins utiles.
2. Inspecter le dépôt réel : consignes locales, état Git, outils de compilation, implémentation existante et éventuel reçu `docs/deliveries/F<n>.md`. Le document décrit une cible, pas l'état du code.
3. Identifier les interfaces consommées et les chemins possédés. Réutiliser ce qui existe et compléter le lot sans réécrire les autres composants.
4. Si F0 est livré, utiliser ses contrats et fixtures. Sinon, relever l'écart et préparer les cas, interfaces proposées et doublures du lot ; ne pas créer silencieusement un protocole concurrent.
5. Implémenter la portion demandée, vérifier ses critères observables et raccorder les dépendances réellement disponibles. Les doublures doivent être signalées.
6. Livrer un reçu de réalisation et les limites restantes. Un lot accepté avec doublures n'est pas une intégration complète.

Les décisions techniques locales, correctifs nécessaires et vérifications réversibles font partie du travail. Ne pas multiplier les demandes de confirmation sur des détails déjà couverts. Une décision modifiant un contrat partagé doit être explicite et examinable, avec ses conséquences pour les consommateurs.

Une dépendance absente ne justifie ni d'arrêter toute activité utile ni d'implémenter à la place de son propriétaire un autre sous-système. Utiliser le port convenu et une doublure ; expliquer ce qui reste à intégrer. Si une ambiguïté empêche de définir correctement le contrat, isoler ce point et poursuivre ce qui n'en dépend pas.

## 3. Sources de vérité et changements

Les instructions actuelles du responsable du projet priment. Les contraintes métier de ce fichier s'appliquent à tous les lots. L'architecture précise les frontières ; le catalogue précise les obligations de chaque lot. Les schémas validés et leurs fixtures deviennent la définition exécutable des échanges.

Une divergence entre ces documents et le code doit être rapportée et résolue explicitement. Le code existant n'autorise pas à abandonner discrètement une exigence ; une proposition documentaire ne prouve pas qu'une API existe.

Les documents sont révisables. Une évolution locale compatible est accompagnée d'une mise à jour ciblée. Une évolution incompatible décrit migration, consommateurs touchés et changement de version ; elle ne se glisse pas dans un correctif sans rapport.

Ne pas affirmer avoir inspecté une version de NimAgent, exécuté un test, intégré un lot ou mesuré un coût sans preuve. L'état initial de tous les lots est **à vérifier**.

## 4. F0 — socle préalable et rôle d'intégration

F0 est un lot à part entière, confié à un responsable d'intégration. Il ne constitue pas une invitation pour chaque codeur à refaire le socle.

F0 doit :

- relever la révision exacte de NimAgent utilisée et les API publiques utiles : `Message`, codec, agent, outils, erreurs, usage, journal, stockage, annulation et asynchronisme ;
- consigner une matrice « besoin factory → API existante → adaptation ou manque », avec les chemins et symboles observés ;
- choisir la version de Nim et le profil de dépendances à partir du dépôt réellement utilisé ; documenter la commande de compilation ;
- fixer le mapping de `Message`, les métadonnées communes, les résultats, les identifiants et les contrats de ports nécessaires aux lots ;
- publier codecs, validations réellement exécutées et fixtures positives/négatives ; préciser les champs obligatoires, les extensions et les règles de compatibilité ;
- établir une façade publique minimale, un consommateur de test et des doublures contractuelles ;
- fixer le format de reçu de livraison, les commandes de contrôle et la responsabilité des fichiers communs.

F0 n'implémente pas le graphe, les chambres, le broker et tous les fournisseurs. Il stabilise leurs frontières. Les contrats sans besoin d'intégration immédiat peuvent rester documentés, tant que leur statut est explicite et que personne ne les importe comme des types disponibles.

Après livraison de F0, ses fichiers partagés ont un seul propriétaire à la fois. Les autres lots proposent des modifications ciblées, accompagnées de fixtures de compatibilité. Une petite adaptation au SDK est attendue ; une duplication du SDK ne l'est pas.

## 5. Invariants métier

### Contexte et instructions

- Chaque inférence reçoit un `InferenceSeed` explicite, issu d'une préparation inspectable.
- Les chambres restent externes à l'appel tant que leur projection n'est pas sélectionnée. Des titres dans un prompt ne constituent pas un cloisonnement.
- Une règle obligatoire applicable et ses exceptions ne disparaissent pas pour respecter une taille cible. Si elles ne tiennent pas, la préparation signale l'insuffisance.
- Le rôle système/métier vient d'une autorité configurée et d'une portée validée. Une source, un résultat outil ou une synthèse ne gagne pas cette autorité par son contenu.
- Les instructions, skills et outils sont sélectionnés pour l'étape. Aucun chargement automatique de tout le catalogue.
- L'ancienneté n'annule pas une contrainte ; la récence n'établit pas la pertinence.
- La reformulation sépare les exigences explicites, hypothèses et questions ouvertes. La demande originale reste accessible par référence.
- Les transformations conservent sources, versions et dépendances. Une synthèse ne remplace pas irréversiblement les preuves.

### Déterminisme et petits modèles

- Privilégier le code déterministe pour filtrer, valider, fermer les dépendances, réserver un budget, appliquer un changement et ordonnancer.
- Utiliser les petits modèles sur des tâches bornées et qualifiées : extraction, classification, classement ou proposition d'identifiants.
- Valider une sortie sur son schéma **et** sur ses références et critères de domaine. Une confiance déclarée ou un JSON valide ne démontre pas la justesse.
- Les préparateurs assistés utilisent le même outillage, avec recette de démarrage déterministe, parentage, limites de profondeur, d'itérations et de dépenses.
- Les recettes d'un run restent figées. L'amélioration automatique du système n'appartient pas au premier périmètre.
- Un cache de sortie LLM est une réutilisation, pas une garantie de reproductibilité du modèle.

### Exécution et coûts

- Le graphe décrit dépendances et contrôle ; le choix séquentiel/concurrent appartient à l'exécuteur.
- Les échanges passent par `Message` et les contrats communs ; les gros contenus sont des artefacts référencés.
- Les mutations partagées passent par des transitions validées ou des commits avec révision attendue.
- Reprise, retransmission et nouvelle tentative sont des situations distinctes.
- Une opération externe d'issue inconnue reste inconnue jusqu'à réconciliation. Ne pas la convertir en succès ou en retry automatique.
- Chaque envoi fournisseur, y compris réparation, relecture et repli, consomme le budget commun.
- Les coûts des préparateurs et évaluateurs comptent dans le bilan. Un compteur absent ne vaut pas zéro.
- Aucun appel payant n'est autorisé par ce fichier seul. Utiliser les budgets déjà explicitement accordés ; sinon qualifier avec des fournisseurs scriptés.

## 6. Organisation du travail

Les chemins proposés figurent dans le catalogue. Les lots dépendent de ports ; les adaptateurs concrets sont assemblés à l'entrée de l'application.

En travail parallèle, isoler les branches ou worktrees, ainsi que les sorties de build lorsque nécessaire. Ne pas effacer, déplacer ou réécrire le travail d'un autre agent. Ne pas modifier les contrats, la façade publique et la composition globale à plusieurs sans coordination.

Éviter les dépendances optionnelles dans le noyau. Ne pas ajouter de framework d'agents, base vectorielle, service distant ou deuxième boucle événementielle pour remplacer une primitive déjà disponible.

Ne pas coder d'interface graphique, de worker distribué, d'auto-modification de recette ou de compilateur embarqué dans ces lots. Le packaging autonome est une étape ultérieure ; il exigera l'inventaire réel des toolchains et dépendances des langages produits.

Ne pas lancer un déploiement, publication, changement de licence ou nettoyage destructif sans instruction correspondante. Cela ne suspend pas les corrections et contrôles ordinaires du lot.

## 7. Vérification et compte rendu

Vérifier les exigences observables avec des cas discriminants. Un test recopiant le résultat du code testé n'est pas un oracle. Les cas de panne, de reprise et de concurrence sont nécessaires lorsqu'ils portent la garantie du lot.

Employer les commandes du dépôt ; ne pas inventer une CI « verte ». Les tests réels de modèle restent séparés des tests scriptés. Un résultat obtenu uniquement avec des doublures est étiqueté comme tel.

Créer ou mettre à jour `docs/deliveries/F<n>.md` avec :

- lot, périmètre réalisé, base inspectée et révision testée si Git les fournit ;
- contrats consommés et modifiés, version du SDK effectivement vérifiée ;
- fichiers principaux, interfaces publiques et exemple d'utilisation ;
- commandes exécutées et résultats observés ;
- distinction entre doublures, intégrations réelles et campagne LLM éventuelle ;
- coûts mesurés, estimés ou inconnus, y compris zéro appel réel si c'est le cas ;
- limites, dépendances restantes et adaptations nécessaires ;
- état séparé de la conformité du composant, de son intégration et du parcours complet.

Ne pas annoncer un commit inexistant. Si des modifications restent non commitées, le préciser et identifier le diff contrôlé. Ne pas livrer un lot comme terminé si une obligation essentielle manque ; indiquer précisément ce qui est déjà utilisable.

## 8. Navigation

- [Architecture et frontières](docs/ARCHITECTURE.md)
- [Contrats, lots F0–F17 et critères de réception](docs/WORK_PACKAGES.md)
- `docs/deliveries/` : reçus à créer pendant le développement, pas résultats supposés.
- `docs/decisions/` : décisions transversales utiles, courtes, datées et motivées.

Les identifiants F0–F17 correspondent respectivement aux anciens J00–J17 de la note de conception. Ne pas créer deux séries de lots.

