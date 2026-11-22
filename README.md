# NimFactory

Moteur local de production logicielle en Nim (contrats, artefacts, graphes, préparation, budgets).

## Toolchain

- Nim **≥ 2.4.0** (vérifié : 2.4.0 via choosenim, `PATH` avec `/root/.nimble/bin`)
- NimAgent path : `/opt/NimAgentLibrary` @ `bf22665`

```bash
export PATH="/root/.nimble/bin:$PATH"
cd /opt/nimFactory
nim c -r --path:src --path:/opt/NimAgentLibrary/src tests/f0/test_contracts.nim
```

## Studio graphique

Le Studio ouvre un projet créé par la CLI et suit ses étapes en lecture seule. Le serveur natif et le client navigateur sont écrits en Nim. Le binaire embarque ses ressources. La compilation du Studio utilise Nim 2.4 et un compilateur C. L’exécution requiert la bibliothèque SQLite du système.

```sh
nim e scripts/build_studio.nims
build/nimfactory-studio --store /chemin/project.sqlite --project-id demo_tasks_cli
```

Ouvrir `http://127.0.0.1:8085`. Sur un VPS, un tunnel SSH vers ce port donne accès au même écran depuis le poste client. Le port est configurable avec `--port`. Pour activer la lecture du fichier cible accepté, ajouter `--trees /chemin/artifacts/trees`, le répertoire produit par les étapes du projet. Le diff et le reçu de vérification sont lus dans SQLite. L’onglet Code relit le fichier de l’étape et vérifie son empreinte enregistrée. Une source manquante, modifiée, binaire ou supérieure à 1 Mio est signalée comme indisponible.

`nimfactory project snapshot --store PATH --project-id ID` émet la même projection JSON que `GET /api/snapshot`. La vue rassemble état et séquences du journal dans une transaction de lecture, avec les 100 événements les plus récents. Le navigateur actualise cette vue toutes les deux secondes, y compris après une coupure. Il garde l’étape sélectionnée par identifiant. Les onglets Diff, Code et Vérification dépendent des données disponibles.

## Documents

- [AGENTS.md](AGENTS.md) — cadre agents
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- [docs/WORK_PACKAGES.md](docs/WORK_PACKAGES.md) — lots F0–F17
- [docs/deliveries/](docs/deliveries/) — reçus

## Tests

```bash
export PATH="/root/.nimble/bin:$PATH"
cd /opt/nimFactory
for t in tests/f0/test_contracts.nim tests/f0/test_message_roundtrip.nim \
         tests/f0/test_fixture_consumers.nim tests/f1/test_artifacts.nim \
         tests/f3/test_journal.nim tests/f4/test_graph.nim \
         tests/f14/test_budget.nim tests/f17/test_qualification_smoke.nim; do
  nim c -r --path:src --path:/opt/NimAgentLibrary/src "$t" || exit 1
done
```

## État

Vague A livrée (F0, F1, F3, F4, F14, début F17). Voir [docs/deliveries/WAVE_A.md](docs/deliveries/WAVE_A.md).
