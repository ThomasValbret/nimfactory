# Delivery — verify-fail recovery (PR #4)

**Branch:** `feature/e2e-model-decision`  
**PR:** [#4](https://github.com/ThomasValbret/nimfactory/pull/4) (draft)  
**Tested tip SHA:**   
**Feature commit for this lot:**   

## Provenance (corrected)

| Claim | Value |
| --- | --- |
| Historical campaign dir | `docs/qa/e2e_intervention/campaigns/20261119T110158Z/` |
| `summary.json` `sha` field in that campaign | `f8a2170…` (binary/script tip when the run executed) |
| Campaign/recovery feature code first landed | `d492dda` |
| Prior receipt text that mentioned | `f2d5e38` |
| Base before this verify-recovery lot | `c253ca4` |
| This trial base (recorded in new summary) | tip after commit of this lot |

Historical traces are **not** overwritten. New evidence: `campaigns/20261119T112212Z/`.

Reference outside campaigns (A no-op / B pass) remains under `docs/qa/e2e_intervention/*.json`.

## Product change

Shared ceiling of **two** provider calls per mission:

1. Initial success → stop.
2. Recovery (one turn) when first outcome is:
   - proposed content **identical** to original (`noop`), or
   - patch **applied**, compiled, but **functional** oracle fails (`functional_fail`).
3. **Not** recovered: `compile_failed`, `oracle_missing` (kept distinct).

Recovery context (API): public symptom, authorized sources, first target/decision, first proposed file body, finding.  
**Excluded:** private oracle, assertions, reference target, variant name. No special-casing of particular symbols.

CLI: `--recovery-api` lets inject first turn + planned OpenAI recovery (`gpt-4o-mini`).

## Offline controls

`tests/mission/test_noop_recovery.nim`: no-op→recovery, functional_fail→recovery, compile_error no recovery, success stops at 1 call, cannot_fix / second no-op stop at 2.

## Campaign `20261119T112212Z`

```bash
bash scripts/e2e_verify_recovery.sh
# loads /opt/.keys when unset
```

### A — turn 1 replayed (inject), turn 2 real API

Inject file: `fixtures/e2e_intervention/inject/historical_a_20261119T110158Z.json` (exact body from `20261119T110158Z`).

| Tour | Provenance | Target | Diff effect | Oracle | Tokens | Cost |
| --- | --- | --- | --- | --- | --- | --- |
| 1 initial | inject historical A | `src/labels.nim` | effective (`return trimText`) | vkFunctionalFail | 0 (inject) | \$0 |
| 2 recovery | **openai/gpt-4o-mini** | `src/labels.nim` again | effective (`else: return trimText`) | vkFunctionalFail | 399+76 | ≈ \$0.000105 |

Verdict A: **verify_failed** (failure conserved). `provider_calls=2`, `recovery_reason=functional_fail`.

### B — success witness

| Tour | Model | Target | Oracle | Calls | Tokens | Cost |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | gpt-4o-mini | `src/labels.nim` | pass | **1** (no recovery) | 276+93 | ≈ \$0.000097 |

Sources presented (both): `labels.nim`, `logging.nim`, `textutil.nim`.

Est. new API spend this campaign ≈ **\$0.00020**.

## Repro

```bash
git checkout <tested-tip>
bash scripts/e2e_verify_recovery.sh
```
