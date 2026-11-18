# Qualification fixtures (F17 Wave A + A.1)

**Modes**

- `simulated` — contract-shaped reference observations and oracles (no LLM, no live preparer).
- `component_probe` — executed separately in `tests/f17/test_a1_component_probes.nim` against public façades; expectations come from `docs/qa/WAVE_A_REVIEW.md`, not from scraping implementation branches.

**Layout**

- `corpus_manifest.json` — frozen corpus index with SHA-256 per item
- `corpus/` — immutable bytes referenced by Wave A preparation scenarios
- `scenarios/` — Wave A discriminators plus `qual-a1-*` counterexample oracles (R1–R5)
- `a1/` — graph and probe inputs referenced by A.1 scenarios
- `fake_constant_observation.json` — constant preparer output used only to prove oracles are discriminating

Do not derive expected results from production preparer code in other lots.