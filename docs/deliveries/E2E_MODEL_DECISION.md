# Delivery — edits integrity + ambiguous recovery (PR #4)

**Branch:** `feature/e2e-model-decision`  
**PR:** [#4](https://github.com/ThomasValbret/nimfactory/pull/4) (draft)  
**Budget cap:** €3  
**NimAgent pin:** `bf22665`

## Prior lots retained

- Cart pass `20261119T114309Z` (comment-leak caveat kept).
- Truncation failure `20261119T120527Z` (`output_truncated`).
- Ambiguous-anchor refuse `20261119T151407Z` (first edits-path run).

## Product — edits integrity

- Entire `edits` list validated before any target write.
- Malformed element / missing `newText` / non-string `newText` → refuse whole proposal (`malformed_edit`, `newText_missing`, `newText_type`).
- Explicit empty-string `newText` remains a valid deletion.
- CLI counter-examples: `bash scripts/e2e_edits_integrity_cli.sh` (bytes intact after refuse).
- Oracle not executed → `kind=vkNotRun`, `ran=false`, `exit_code`/`compile_exit_code`/`run_exit_code` = **-1**, message `oracle not run`.

## Product — `anchor_ambiguous` → second turn

Recovery already capped at two provider calls. On `refuse_code=anchor_ambiguous` the mission
sends the model its **exact** proposal, the match count, and a few lines around each occurrence,
plus the public symptom. The engine never picks an occurrence. The model may revise the cause,
change target, refine anchors, or `cannot_fix`.

Offline: `tests/mission/test_edits_apply.nim` (incl. ambiguous→recovery inject).

## Recipe — replay `20261119T151407Z` + one live recovery

```bash
bash scripts/e2e_ambiguous_recovery_api.sh
```

- Turn 1: archived inject (same proposal as 151407Z).
- Turn 2: one real `gpt-4o-mini` call (2048 ceiling) via `--recovery-api`.
- Recovery request excludes historical fix, private oracle, and compile diagnosis.

### Live result (filled after clean-tip run)

| Field | Value |
| --- | --- |
| Clean tip | *pending* |
| Campaign | *pending* |
| Recovery | *pending* |
| Edits applied | *pending* |
| Repro / oracle | *pending* |
| Tokens / cost | *pending* |
| Verdict | *pending* |
