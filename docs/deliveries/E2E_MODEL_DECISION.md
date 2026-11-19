# Delivery — block edits + real unknown-module retry (PR #4)

**Branch:** `feature/e2e-model-decision`  
**PR:** [#4](https://github.com/ThomasValbret/nimfactory/pull/4) (draft)  
**Budget cap:** €3  
**NimAgent pin:** `bf22665` (Code Zero `oldText`/`newText` edits at this revision)

## Cart lot retained

Campaign `20261119T114309Z` pass kept. Caveat unchanged: the buggy `lineTotal`
comment leaked the diagnosis into model context.

## Prior unknown-module failure conserved

Campaign `20261119T120527Z`: full-file rewrite truncated at completion **2048**
(`code=output_truncated`, message `Output truncated by provider`). First result kept.

## Product — bounded `edits` for API large-file repair

API `mission-fix` accepts Code Zero–style replacements reused for the product path:

```json
{
  "target_file": "src/….nim",
  "decision": "…",
  "edits": [{"oldText": "…", "newText": "…"}]
}
```

- Multiple replacements in the **chosen** file are allowed.
- Each `oldText` must match **exactly once** in the evolving buffer (missing → refuse; ambiguous → refuse).
- The set is written to the worktree **only if every** replacement validates; otherwise the target file stays the copied original (no partial write).
- Legacy `patched_content` remains readable; local micro-patch context constructor still requests `patched_content` only.
- Provider motif `output_truncated` / `Output truncated by provider` conserved on truncated API replies.
- When the oracle does not execute, reports say **`oracle not run`** (`phase=vpNone`).

Offline proof: `tests/mission/test_edits_apply.nim` — valid / missing / ambiguous / truncated.

## Real unknown-module retry (edits path)

Same upstream tree and symptom; historical fix stays in `reference/` only.

| Field | Value |
| --- | --- |
| Repo | https://github.com/haltcase/glob |
| Faulty SHA | [`589671a897c12398113605193130d1c60ffab282`](https://github.com/haltcase/glob/commit/589671a897c12398113605193130d1c60ffab282) |
| Historical fix | [`1fa54df5fa57e38adc43de2cb050c7748c305047`](https://github.com/haltcase/glob/commit/1fa54df5fa57e38adc43de2cb050c7748c305047) |
| Model / ceiling | `gpt-4o-mini`, max completion **2048**, ≤ 2 calls |

Private oracle extended: `*/a.txt` must return the three one-level hits and **exclude**
`deep/x/a.txt`. Validated on the historical fix body before the live call.

```bash
bash scripts/e2e_real_unknown_module_api.sh
```

### Live mission (filled after clean-tip run)

| Field | Value |
| --- | --- |
| Clean tip SHA | *pending commit* |
| Campaign | *pending* |
| Target / edits applied | *pending* |
| Public repro / oracle | *pending* |
| Calls / tokens / cost | *pending* |
| Verdict | *pending* |
