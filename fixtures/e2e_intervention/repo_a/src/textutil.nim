import std/strutils

proc isBlank*(s: string): bool =
  s.len > 0 and s.strip.len == 0

proc trimText*(s: string): string =
  s.strip()
