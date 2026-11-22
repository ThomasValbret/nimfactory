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

Le Studio ouvre un projet créé par la CLI. Le serveur natif et le client navigateur sont écrits en Nim. Le binaire embarque ses ressources. La compilation du Studio utilise Nim 2.4 et un compilateur C. L’exécution requiert la bibliothèque SQLite du système. La lecture reste non intrusive ; la révision de plan passe par la même logique métier que `nimfactory project revise`.

```sh
export PATH="/root/.nimble/bin:$PATH"
cd /opt/nimFactory
nim e scripts/build_studio.nims
nim c -d:release -d:ssl --hints:off --nimcache:build/nimcache_cli \
  --path:src --path:/opt/NimAgentLibrary/src \
  -o:build/nimfactory src/nimfactory_cli.nim

build/nimfactory-studio \
  --store /opt/nimFactory-studio-demo/project.sqlite \
  --project-id studio_revise_demo \
  --trees /opt/nimFactory-studio-demo/artifacts/trees \
  --cwd /opt/nimFactory/fixtures/demo_tasks_cli \
  --route inject \
  --inject /opt/nimFactory/fixtures/demo_tasks_cli/inject/plan_v2.json \
  --artifact-dir /opt/nimFactory-studio-demo/artifacts \
  --port 18085
```

Ouvrir `http://127.0.0.1:18085`. Sur ce VPS le port 8085 est déjà pris ; la démo utilise **18085**. Tunnel SSH depuis le Chromebook :

```sh
ssh -N -L 18085:127.0.0.1:18085 user@vps
```

Pour activer la lecture du fichier cible accepté, `--trees` pointe vers le répertoire `artifacts/trees` produit par les étapes. Dans Workflow, « Réviser le plan » apparaît quand le snapshot expose la capacité `revise_plan`. La commande POST `/api/command` exige `command_id`, `expected_plan_version` et `refinement`, reste sur loopback, et refuse une Origin étrangère.

`nimfactory project snapshot --store PATH --project-id ID` émet la même projection JSON que `GET /api/snapshot`. CLI et Studio partagent `executeRevisePlan` pour les reçus idempotents.

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
