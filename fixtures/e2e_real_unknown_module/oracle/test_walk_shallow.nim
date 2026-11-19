## Private reception oracle — never included in model context.
import std/[os, sequtils, algorithm]
import glob

let root = getTempDir() / "nf_glob_oracle_fs"
removeDir(root)
createDir(root)
for d in ["foo", "bar", "baz"]:
  createDir(root / d)
  writeFile(root / d / "a.txt", "x")

var got = toSeq(walkGlob("*/a.txt", root = root))
got.sort()
let expect = @["bar/a.txt", "baz/a.txt", "foo/a.txt"]
doAssert got == expect, "got=" & $got & " expect=" & $expect
echo "oracle_glob_walk: ok"
