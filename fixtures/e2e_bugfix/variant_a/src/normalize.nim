## Buggy normalize — variant A (raw empty string bypasses EMPTY sentinel).
import std/strutils

proc normalize*(s: string): string =
  ## Spec: "" and whitespace-only → "EMPTY"; else trimmed text.
  if s.len > 0 and s.strip.len == 0:
    return "EMPTY"
  # BUG: "" has len 0 so it skips the sentinel and returns "".
  result = s.strip()
