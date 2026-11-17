# Qualification fixtures (F17 Wave A)

**Mode : `simulated`** — these files define independent oracles and reference observations. They do not assert real LLM quality.

- `corpus_manifest.json` — frozen corpus index with SHA-256 per item
- `corpus/` — immutable bytes referenced by scenarios
- `scenarios/` — failure/discriminating cases with explicit oracle checks
- `fake_constant_observation.json` — constant preparer output used only to prove oracles are discriminating

Do not derive expected results from production preparer code in other lots.