# Delivery — oracle phases + novel follow-call API (PR #4)

**Branch:** `feature/e2e-model-decision`  
**PR:** [#4](https://github.com/ThomasValbret/nimfactory/pull/4) (draft)  
**Campaign tip SHA (pre-commit stamp):** `973b743858978a5235dc1066482caf9cc0d9a6c8`  
**Paid API calls this lot:** **1** (`gpt-4o-mini`, novel follow-call)  
**Estimated cost:** **≈ $0.00023** (734 prompt + 195 completion tokens; budget cap €3)

## Provenance (corrected, historical traces kept)

| Item | Value |
| --- | --- |
| Campaign `20261119T110158Z` `summary.json` sha field | `f8a2170` |
| Campaign/recovery feature commit | `d492dda` |
| Verify-recovery live campaign | `20261119T112212Z` (A failure conserved) |
| Offline oracle-phase lot | `20261119T113716Z` (`paid_api_calls=0`) |
| Novel follow-call API | `20261119T114309Z` |

## Product change (oracle phases)

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

## Campaign `20261119T114309Z` — novel follow-call (live API)

```bash
bash scripts/e2e_novel_followcall_api.sh
# key: /opt/.keys/api_provider_key (or OPENAI_API_KEY)
```

Fixture: `fixtures/e2e_novel_followcall/` — public `repro.nim` + private oracle; bug is extra `total += unit` after the qty loop in `src/cart.nim`.

| Step | Result |
| --- | --- |
| Original oracle | exit 1 (`AssertionDefect` on `lineTotal(bread,1)==120`) |
| Ref inject fix | `verdict=pass`, 0 paid calls |
| Live API (`gpt-4o-mini`) | `verdict=pass`, **1** call, recovery **false** |
| Target chosen | `src/cart.nim` |
| Tokens | 734 + 195 |
| Estimated USD | 0.0002271 |

**Model decision tested:** yes (real OpenAI route). First call produced an effective change; oracle `vkPass` / `vpRun`.

Key loading: scripts accept `/opt/.keys/api_provider_key` (directory layout) or a flat `/opt/.keys` file.

## Limits

- Historical intervention **A** failure remains conserved (`20261119T112212Z` / offline replay).
- Cost estimate is token×list price arithmetic in the campaign script; mission JSON still reports `cost_known=false` until pricing is wired in-mission.
- Uncommitted campaign stamp SHA is the tip **before** this receipt/script commit; re-stamp after publish if a SHA field must match HEAD.
