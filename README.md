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
