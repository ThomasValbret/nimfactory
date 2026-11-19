## Reception tests — kept OUT of the model context on purpose.
import std/strutils

# The mission runner compiles this against the worktree's normalize.nim.

proc normalize*(s: string): string

doAssert normalize("") == "EMPTY"
doAssert normalize("   ") == "EMPTY"
doAssert normalize(" hi ") == "hi"
doAssert normalize("x") == "x"
echo "oracle_normalize: ok"
