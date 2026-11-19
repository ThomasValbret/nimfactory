# Delivery — block edits + real unknown-module retry (PR #4)

**Branch:** `feature/e2e-model-decision`  
**PR:** [#4](https://github.com/ThomasValbret/nimfactory/pull/4) (draft)  
**Budget cap:** €3  
**NimAgent pin:** `bf22665` (Code Zero `oldText`/`newText` edits)  
**Clean tip before live call:** `3b5caa27085238edbedad31649a253fe237756c3`

## Cart lot retained

Campaign `20261119T114309Z` pass kept. Caveat unchanged: the buggy `lineTotal`
comment leaked the diagnosis into model context.

## Prior unknown-module failure conserved

Campaign `20261119T120527Z`: full-file rewrite truncated at completion **2048**
(`code=output_truncated`). First result kept.

## Product — bounded `edits` for API large-file repair

API `mission-fix` accepts Code Zero–style replacements:

```json
{
  "target_file": "src/….nim",
  "decision": "…",
  "edits": [{"oldText": "…", "newText": "…"}]
}
```

- Multiple replacements in the chosen file allowed.
- Each `oldText` must match exactly once (missing / ambiguous → refuse entire set).
- Worktree target written only when every replacement validates; otherwise unchanged copy.
- Legacy `patched_content` still parsed; local micro-patch context still uses `patched_content`.
- Motif `output_truncated` / `Output truncated by provider` conserved.
- When oracle does not execute: message **`oracle not run`**, `phase=vpNone`.

Offline: `tests/mission/test_edits_apply.nim` — valid / missing / ambiguous / truncated.

## Real unknown-module retry (edits path)

| Field | Value |
| --- | --- |
| Repo | https://github.com/haltcase/glob |
| Faulty SHA | [`589671a`](https://github.com/haltcase/glob/commit/589671a897c12398113605193130d1c60ffab282) |
| Historical fix (out of context) | [`1fa54df`](https://github.com/haltcase/glob/commit/1fa54df5fa57e38adc43de2cb050c7748c305047) |
| Model / ceiling | `gpt-4o-mini`, completion **2048**, ≤ 2 calls |

Oracle extended before the call: `*/a.txt` finds one-level hits and excludes `deep/x/a.txt`
(verified on historical fix: pass; on faulty tree: fail).

### Independent controls (`20261119T151407Z`)

| Control | Result |
| --- | --- |
| Public repro | `observed=@[]` |
| Oracle on faulty | exit 1 |
| Oracle on historical fix | exit 0 (incl. depth exclusion) |
| Historical inject | pass |
| Context sources | `src/glob.nim`, `src/glob/regexer.nim` |

### Live mission (first result archived)

| Field | Value |
| --- | --- |
| Tip | `3b5caa2` |
| Campaign | `20261119T151407Z` |
| Calls | **1** (no recovery) |
| Tokens | 7129 + **67** |
| Est. cost | ≈ **$0.00111** |
| Provider | `ok=true`, completed (under 2048 ceiling) |
| Target | `src/glob.nim` |
| Mode | `edits` (1 proposed) |
| Edits applied | **0** — `oldText` `"return pattern"` ambiguous (2 matches) |
| Worktree target | unchanged (`before_hash == after_hash`) |
| Public repro after model | not re-checked (no applied edit) |
| Oracle | **oracle not run** |
| Verdict | **`apply_failed`** (conserved) |

### Judgment

The edits path unblocked short structured replies under the 2048 ceiling. The model
chose the right file without spoilers but proposed a non-unique anchor; the product
refused the write and left the tree intact. Behavioural repair of the glob defect was
**not** achieved on this first archived run.
