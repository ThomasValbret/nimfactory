## Private reception oracle — never included in model context.
## Includes a depth case absent from the public reproducer: `*/a.txt` must
## match one-level paths and must not match a namesake two levels deeper.
import std/[os, sequtils, algorithm]
import glob

let root = getTempDir() / "nf_glob_oracle_fs"
removeDir(root)
createDir(root)
for d in ["foo", "bar", "baz"]:
  createDir(root / d)
  writeFile(root / d / "a.txt", "x")
createDir(root / "deep")
createDir(root / "deep" / "x")
writeFile(root / "deep" / "x" / "a.txt", "deep")

var got = toSeq(walkGlob("*/a.txt", root = root))
got.sort()
let expect = @["bar/a.txt", "baz/a.txt", "foo/a.txt"]
doAssert "deep/x/a.txt" notin got, "two-level namesake must be excluded: " & $got
doAssert got == expect, "got=" & $got & " expect=" & $expect
echo "oracle_glob_walk: ok"
