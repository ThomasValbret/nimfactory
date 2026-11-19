# Delivery — edits integrity + ambiguous recovery (PR #4)

**Branch:** `feature/e2e-model-decision`  
**PR:** [#4](https://github.com/ThomasValbret/nimfactory/pull/4) (draft)  
**Budget cap:** €3  
**NimAgent pin:** `bf22665`  
**Clean tip before live recovery:** `75c4f7f576ab03973dd355131cc4e32a9a3d3990`

## Prior lots retained

- Cart pass `20261119T114309Z` (comment-leak caveat kept).
- Truncation failure `20261119T120527Z` (`output_truncated`).
- Ambiguous-anchor refuse `20261119T151407Z` (first edits-path run).

## Product — edits integrity

- Entire `edits` list validated before any target write.
- Malformed element / missing `newText` / non-string `newText` → refuse whole proposal.
- Explicit empty-string `newText` remains a valid deletion.
- CLI: `bash scripts/e2e_edits_integrity_cli.sh` — both counter-examples refuse; repo/worktree bytes intact; `vkNotRun` with exit codes **-1**.
- Offline suite: `tests/mission/test_edits_apply.nim`.

## Product — `anchor_ambiguous` → second turn

On `refuse_code=anchor_ambiguous`, the mission opens the existing second turn with:

- the model’s **exact** first proposal,
- match count,
- a few lines around **each** occurrence,
- the public symptom and authorized sources.

No historical fix, private oracle, or compile diagnosis. The engine never picks an occurrence.

## Campaign `20261119T173015Z` — replay + live recovery

| Field | Value |
| --- | --- |
| Tip | `75c4f7f` |
| Replay of | `20261119T151407Z` turn 1 (inject) |
| Recovery | **yes**, reason `anchor_ambiguous` |
| Paid OpenAI calls | **1** (`gpt-4o-mini`, ceiling 2048) |
| Tokens | 7526 + 67 |
| Est. cost | ≈ **$0.00117** |
| Turn 1 | `src/glob.nim`, edits applied **0**, `anchor_ambiguous` (2× `return pattern`) |
| Turn 2 | same target/decision/edits repeated; apply **0**; `anchor_ambiguous` again |
| Oracle | **oracle not run** both turns (`vkNotRun`, exits -1) |
| Public repro after model | not re-checked (no applied edit) |
| Verdict | **`apply_failed`** (conserved) |

### Judgment

Integrity controls held. The second turn ran with occurrence context; the model did **not** revise the ambiguous anchor (echoed the same proposal). Behavioural repair of the glob defect was not achieved on this archived run.
