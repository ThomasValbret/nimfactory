# Delivery — oracle compile/run phases (PR #4)

**Branch:** `feature/e2e-model-decision`  
**PR:** [#4](https://github.com/ThomasValbret/nimfactory/pull/4) (draft)  
**Base:** `6f188ee`  
**Tested tip SHA:** _(stamp)_  
**Paid API calls this lot:** **0**

## Provenance (corrected, historical traces kept)

| Item | Value |
| --- | --- |
| Campaign `20261119T110158Z` `summary.json` sha field | `f8a2170` |
| Campaign/recovery feature commit | `d492dda` |
| Prior receipt citation | `f2d5e38` |
| Verify-recovery live campaign | `20261119T112212Z` (A failure conserved) |
| This offline lot campaign | `20261119T113716Z` |
| This lot base | `6f188ee` |

## Product change

`runOracle` now:

1. Resolves `--oracle` → missing ⇒ `oracle_missing`
2. **Compiles** the oracle against the worktree (`nim c`, no `-r`)
3. Records `phase=vpCompile`, `compile_exit_code`
4. **Runs** the binary only if compile exit is 0
5. Records `phase=vpRun`, `run_exit_code`
6. Launch failure after successful compile ⇒ `oracle_launch_failed` (no recovery)

Recovery (2nd model call) is authorized only for:

- identical proposed content (`noop`), or
- **functional** failure after a successful launch (`functional_fail`)

Compile failures do **not** recover.

## Table cases (before/after decision)

| Case | Oracle | Phase | Kind | Verdict | Recovery |
| --- | --- | --- | --- | --- | --- |
| `quit(1)` at run | `oracle_quit1` | `vpRun` | `vkFunctionalFail` | then recovery → `model_cannot_fix` (inject) | **yes** |
| `static: doAssert false` | `oracle_static_fail` | `vpCompile` | `vkCompileError` | `compile_failed` | **no** |

Offline tests: `tests/mission/test_oracle_phases.nim`.

## Campaign `20261119T113716Z` (inject only)

```bash
bash scripts/e2e_oracle_phase_offline.sh
```

| Trial | Injected | Network | Verifications | Verdict | Recovery |
| --- | --- | --- | --- | --- | --- |
| phase_quit1 | 2 | 0 | 1 | model_cannot_fix | yes (functional_fail) |
| phase_static_fail | 1 | 0 | 1 | compile_failed | no |
| offline_a_archived_failure | 2 | 0 | 2 | **verify_failed** | yes (A failure conserved) |
| offline_b_archived_success | 1 | 0 | 1 | pass | no |

`network_calls_total=0`, `paid_api_calls=0`.

## Next lot prepared (not API-run here)

`fixtures/e2e_novel_followcall/`: cart total too high; public `repro.nim`; bug in `cart.lineTotal` (extra unit after loop); private oracle `oracle/test_cart_total.nim`.  
Reserved for a real `mission-fix --route api` with the planned model. If API unavailable then: **model decision remains untested**.
