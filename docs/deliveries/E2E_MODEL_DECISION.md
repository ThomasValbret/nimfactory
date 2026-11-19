# Delivery — E2E intervention choice + no-op recovery

**Branch:** `feature/e2e-model-decision`  
**PR:** [#4](https://github.com/ThomasValbret/nimfactory/pull/4) (draft)  
**Tested SHA:** 

## Reference kept (prior campaign)

Fixtures, oracle and traces under `docs/qa/e2e_intervention/` (non-`campaigns/`) remain the accepted reference: A failed first try with **identical content / no effect**, B passed.

## Product changes

1. **Campaign script** (`scripts/e2e_intervention.sh`): continues after A failure; records exit code + verdict per trial; writes under `docs/qa/e2e_intervention/campaigns/<UTC-stamp>/` with `summary.json`.
2. **No-op recovery (API / inject-with-recovery)**: when `patched_content` equals the current file, one recovery turn returns to the model: chosen target, finding « contenu proposé identique à l’original », same authorized sources. May reconsider target or `{"cannot_fix":true,...}`. No expected target, no oracle. Initial success → zero recovery calls.
3. **Local route** unchanged: micro-patch only (`--target` + `--diagnosis`).

## Offline qualification (no API)

`tests/mission/test_noop_recovery.nim`:

| Case | Calls | Result |
| --- | --- | --- |
| no-op then recovery fix | 2 | pass |
| no-op then cannot_fix | 2 | model_cannot_fix |
| no-op then no-op again | 2 | apply_failed (stop) |
| initial success | 1 | pass (no recovery) |

Bench `test_intervention_bench.nim` still green.

## Campaign `20261119T110158Z` (live API)

Command:

```bash
bash scripts/e2e_intervention.sh
# loads /opt/.keys when OPENAI_API_KEY unset; needs -d:ssl binary
```

| Trial | Exit | Verdict | Calls | Recovery | Notes |
| --- | --- | --- | --- | --- | --- |
| API A | 4 | verify_failed | 1 | no | effective change on **wrong** file `labels.nim`; not a no-op → recovery not armed |
| API B | 0 | pass | 1 | no | `labels.nim` guest path |
| Cross A→B | — | pass | 1 inject | — | |
| Cross B→A | — | verify_failed | 1 inject | — | |

**Attempt detail A**

| Attempt | Target | Effective change | Oracle | Tokens |
| --- | --- | --- | --- | --- |
| 1 initial | `src/labels.nim` | yes (wrong) | fail | 293+92 |

**Attempt detail B**

| Attempt | Target | Effective change | Oracle | Tokens |
| --- | --- | --- | --- | --- |
| 1 initial | `src/labels.nim` | yes | pass | 276+93 |

Est. new spend ≈ \$0.0002 (gpt-4o-mini public rates). Global campaign `global_ok=false` (A + cross B→A).

**Live no-op recovery:** not exercised this run (A was not identical-to-original). Wiring covered offline; mark live API recovery as **not demonstrated on this campaign**.

## Repro

```bash
nim c -d:release -d:ssl --path:src --path:vendor/NimAgentLibrary/src \
  -o:build/nimfactory src/nimfactory_cli.nim
bash scripts/e2e_intervention.sh
```
