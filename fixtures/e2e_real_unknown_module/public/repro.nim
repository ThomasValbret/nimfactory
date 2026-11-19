## Public reproducer — safe to show operators; no oracle assertions.
## Run from repo root: nim c -r --hints:off --path:src ../public/repro.nim
## (script wrapper sets cwd to repo/)

import std/[os, sequtils, algorithm]
import glob

let root = getTempDir() / "nf_glob_public_repro_fs"
removeDir(root)
createDir(root)
for d in ["foo", "bar", "baz"]:
  createDir(root / d)
  writeFile(root / d / "a.txt", "x")

echo "input_pattern=*/a.txt"
echo "input_root_entries=foo/a.txt,bar/a.txt,baz/a.txt"
var got = toSeq(walkGlob("*/a.txt", root = root))
got.sort()
echo "observed=", got
