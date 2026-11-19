## Buggy normalize — variant B (off-by-one: single-char inputs forced to EMPTY).
import std/strutils

proc normalize*(s: string): string =
  ## Spec: "" and whitespace-only → "EMPTY"; else trimmed text.
  let t = s.strip()
  if t.len == 0:
    return "EMPTY"
  # BUG: treats any 1-character payload as empty sentinel.
  if t.len <= 1:
    return "EMPTY"
  result = t
