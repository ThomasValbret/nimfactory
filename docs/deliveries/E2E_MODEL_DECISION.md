# Delivery — oracle phases, novel cart API, real unknown-module (PR #4)

**Branch:** `feature/e2e-model-decision`  
**PR:** [#4](https://github.com/ThomasValbret/nimfactory/pull/4) (draft)  
**Budget cap:** €3  
**Feature tip after this lot:** *(filled at commit)*

## Cart lot retained (novel follow-call)

| Item | Value |
| --- | --- |
| Campaign | `20261119T114309Z` |
| Stamp tip | `973b743` |
| Model | `gpt-4o-mini`, **1** call, **pass**, target `src/cart.nim` |
| Cost | ≈ $0.00023 |

**Caveat (method):** the buggy `lineTotal` comment stated the diagnosis explicitly
(`## Current: adds the unit price one extra time after the loop.`). That text was
in the model context. The cart pass therefore does **not** alone prove that
NimFactory can locate a responsible module when the pilot only has a reproducer.

## Provenance table

| Item | Value |
| --- | --- |
| Verify-recovery (A conserved) | `20261119T112212Z` |
| Offline oracle-phase | `20261119T113716Z` (0 paid) |
| Novel cart API | `20261119T114309Z` (1 paid) |
| Real unknown-module API | `20261119T120527Z` (1 paid, **failure conserved**) |

## Product change — nested `src/` collector

`collectSrcNim` / `buildApiContext` now walk **`src/**/*.nim` recursively**,
preserving relative paths (no flattening, no hand-picked culprit). Nested
packages such as `src/glob/regexer.nim` are included when present.

Offline check: `tests/mission/test_context_and_inject.nim` →
`sources=src/glob.nim,src/glob/regexer.nim`.

## Real unknown-module lot — question

Can NimFactory repair a real defect when a user can reproduce it but does not
know which module is responsible?

### Upstream case

| Field | Value |
| --- | --- |
| Repository | https://github.com/haltcase/glob |
| Issue | https://github.com/haltcase/glob/issues/29 |
| Faulty commit (fixture tree) | [`589671a897c12398113605193130d1c60ffab282`](https://github.com/haltcase/glob/commit/589671a897c12398113605193130d1c60ffab282) |
| Historical fix | [`1fa54df5fa57e38adc43de2cb050c7748c305047`](https://github.com/haltcase/glob/commit/1fa54df5fa57e38adc43de2cb050c7748c305047) |
| Layout kept | `src/glob.nim` (public `walkGlob`) → `src/glob/regexer.nim` (pattern compile) |

Symptom: `fixtures/e2e_real_unknown_module/SYMPTOM.md`.  
Historical diff / fixed body / cause notes: `reference/` (**out of model context**).  
Private oracle: `oracle/test_walk_shallow.nim`.  
Public reproducer: `public/repro.nim` (outside `repo/src`).

```bash
bash scripts/e2e_real_unknown_module_api.sh
# key: /opt/.keys/api_provider_key
```

### Independent controls (campaign `20261119T120527Z`)

| Control | Result |
| --- | --- |
| Public repro on faulty tree | exit 0, `observed=@[]` |
| Private oracle on faulty tree | exit 1 (`got=@[]`) |
| Oracle after historical fix body | exit 0, `oracle_glob_walk: ok` |
| Inject of historical fix | `bench_ref_historical_exit=0` |
| `buildApiContext` sources | `src/glob.nim`, `src/glob/regexer.nim` |

### Live mission (first result conserved)

| Field | Value |
| --- | --- |
| Tested SHA (pre-commit stamp) | `4bb2462c107b60fe7c23a5126df19e2d42d6ea1f` |
| Campaign | `20261119T120527Z` |
| Model | `gpt-4o-mini` |
| Calls | **1** (recovery not entered) |
| Tokens | 7051 prompt + 2048 completion |
| Estimated cost | **≈ $0.00229** |
| Provider | `ok=false`, `status=rsPartial`, warning **Output truncated by provider** |
| Verdict | **`model_failed`** |

Turn 1 (truncated JSON, not applied — no worktree diff):

- Intended `target_file`: `src/glob.nim` (correct module, not hand-selected)
- Intended decision excerpt: *Fix logic in walkGlobKinds to properly yield paths that match one-level glob patterns*
- `patched_content` cut off mid-file by the NimAgent default **`maxTokens=2048`** ceiling while rewriting the full `src/glob.nim` body
- Parse/apply skipped; oracle not run on a model patch

### Behavioural judgment

- **Module choice without spoilers:** yes — the model named `src/glob.nim` given only the symptom + recursive `src/` sources.
- **Repair achieved:** **no** on this first run — truncation prevented an applied patch, so public repro / private oracle were never re-checked against a model edit.
- A different patch than the historical `shouldDescend` diff would have been acceptable if behaviour matched; that bar was not reached here.
- Product limit exposed: full-file rewrite of a ~22 KiB module exceeds the default 2048 completion budget.

## Oracle-phase product change (prior)

`runOracle` compiles then runs; recovery only for no-op or launched functional fail.
Offline campaign `20261119T113716Z` conserved A’s failure with 0 paid calls.
