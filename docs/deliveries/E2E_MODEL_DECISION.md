# Delivery — E2E model decision / intervention choice

**Branch:** `feature/e2e-model-decision`  
**PR:** [#4](https://github.com/ThomasValbret/nimfactory/pull/4) (draft)  
**Tested SHA:** `1f5c78eff79e9038226fc830f7852130cfbc0907`  
**PR #3:** role selects route; API scenarios use planned API; local micro-patch is a distinct mission.

## Conserved proof — CLI can obtain and apply a real API fix

Earlier trials on `fixtures/e2e_bugfix` (same symptom family, cause in one file) remain under `docs/qa/e2e_model_decision/api_variant_{a,b}.json`: both passed with `openai/gpt-4o-mini`. They prove end-to-end apply+oracle. They do **not** qualify *choice of intervention* across modules.

## Product fixes in this pass

1. **`--oracle` is executed** — `runOracle` compiles the `.nim` file from the supplied directory with `--path:<worktree>/src`. No hardcoded assertions.
2. **CLI oracle cases:** missing → `oracle_missing` (exit 2); false oracle → `verify_failed` (exit 4); satisfied → `pass` (exit 0). Artifacts: `docs/qa/e2e_intervention/cli_oracle_*.json`.
3. **`--worktree`** — never `removeDir`s an existing tree. Empty path → fresh mission dir under `$TMP`; occupied path → refuse (`apply_failed`).
4. **Context** — pilot symptom only (no default normalize spec). Local route requires established `--target` + `--diagnosis` (micro-patch, not intervention choice).
5. **API recipe** — `scripts/e2e_intervention.sh` does not launch Ollama. Optional local micro-patch is separate.

## Intervention fixtures

`fixtures/e2e_intervention/` — same pilot symptom, ordinary names, no bug/variant/decoy labels.

| Repo | Cause module | Other modules |
| --- | --- | --- |
| `repo_a` | `src/textutil.nim` (`isBlank` misses `""`) | `labels.nim` correct, `logging.nim` unrelated |
| `repo_b` | `src/labels.nim` (no guest path) | `textutil.nim` correct, `logging.nim` unrelated |

Symptom (`SYMPTOM.md`): blank → guest label; non-blank → trimmed. Oracle outside context.

## Bench matrix (no API spend)

`tests/mission/test_intervention_bench.nim` + inject reference fixes:

| Case | Result |
| --- | --- |
| original A / B vs oracle | fail / fail |
| ref fix A on A | pass (`textutil`) |
| ref fix B on B | pass (`labels`) |
| ref A on B / ref B on A | fail / fail |
| wrong target `logging.nim` | fail |
| occupied worktree | refuse |
| oracle missing / false / ok | missing / fail / pass |

## Planned API trials (intervention choice)

Build: `nim c -d:release -d:ssl … -o:build/nimfactory src/nimfactory_cli.nim`

```bash
./build/nimfactory mission-fix \
  --repo fixtures/e2e_intervention/repo_a \
  --symptom fixtures/e2e_intervention/SYMPTOM.md \
  --oracle fixtures/e2e_intervention/oracle \
  --route api --worktree /tmp/nf_wt_a_new

./build/nimfactory mission-fix \
  --repo fixtures/e2e_intervention/repo_b \
  --symptom fixtures/e2e_intervention/SYMPTOM.md \
  --oracle fixtures/e2e_intervention/oracle \
  --route api --worktree /tmp/nf_wt_b_new
```

| Trial | Model | Sources presented | Decision / target | Diff effect | Verdict | Tokens | Est. cost |
| --- | --- | --- | --- | --- | --- | --- | --- |
| API A | gpt-4o-mini | labels, logging, textutil | text «isBlank…» but **target `labels.nim`**, body identical to original | no effective change | **apply_failed** | 293+91 | ≈ \$0.00010 |
| API B | gpt-4o-mini | labels, logging, textutil | guest path in **`labels.nim`** | adds `isBlank` branch | **pass** | 276+90 | ≈ \$0.00010 |
| Cross A→B | inject replay | (same apply path) | A's labels payload on B | fixes B's labels | **pass** | 0 new | \$0 |
| Cross B→A | inject replay | | B's labels fix on A | A still broken in textutil | **verify_failed** | 0 new | \$0 |

Tarif used: gpt-4o-mini ≈ \$0.15/1M in + \$0.60/1M out. New spend this pass ≈ **\$0.0002** (well under remaining €3). Prior conserved trials ≈ \$0.00025.

### Rupture on A (localized)

- Facts in context: buggy `isBlank` in `textutil.nim`; `labels.nim` already correct.
- Context sent: all three `src/*.nim` + pilot symptom (see `api_repo_a.json` → `context.user_prompt`).
- Model output: diagnosed isBlank verbally but selected `src/labels.nim` and emitted the pre-existing labels body.
- Apply: refused identical content.
- Oracle: not reached.
- Component: failure attributed to **model intervention choice** (`openai/gpt-4o-mini`), not to oracle/worktree plumbing.

### Cross-replay vs starting hypothesis

Hypothesis “each API answer fixes only its repo” is **partially contradicted**: A's no-op-on-A labels body still repairs B; B's correct-for-B patch does not repair A. Bench discrimination (reference inject matrix) remains solid.

## Attribution

| Step | Component |
| --- | --- |
| Context | `nimfactory.mission.context` |
| Model | `openai/gpt-4o-mini` via NimAgent |
| Parse/apply/worktree | `nimfactory.mission.apply` |
| Oracle | caller `--oracle` via `nimfactory.mission.verify` |

## Limits

- Intervention choice on `repo_a` not yet demonstrated with the planned API (failure conserved).
- Local micro-patch route exists but is not part of the API intervention recipe.
- Rotate the temporary API key after review; never commit it.
