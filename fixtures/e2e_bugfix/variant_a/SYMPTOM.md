Symptom observed by the pilot:
`normalize` must map empty / whitespace-only inputs to the sentinel `EMPTY`,
and otherwise return the trimmed text (including a single non-space character such as `x`).
Current behaviour fails the product check.
