import std/strutils

proc isBlank*(s: string): bool =
  s.strip.len == 0

proc trimText*(s: string): string =
  s.strip()
