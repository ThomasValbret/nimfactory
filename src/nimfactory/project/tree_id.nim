## Served-tree identity — fingerprint of the directory actually opened.
## Must match snapshotAcceptedTree hashing (pipeline) so preview can
## recompute and compare without trusting a launcher TREE_SHA string.

import std/[os, strutils, algorithm, json]

proc simpleContentHash*(s: string): string =
  ## FNV-1a 64-bit, hex uppercase width 16 (stable, not cryptographic).
  var h: uint64 = 14695981039346656037u64
  for c in s:
    h = h xor uint64(ord(c))
    h = h * 1099511628211u64
  toHex(h, 16)

const SkipTreeNames = ["nimcache", "build", ".git", "inject", ".nimfactory"]

proc pathSkipped*(relOrAbs: string): bool =
  ## Match snapshot copyTree exclusions (inject/.git/… at any path segment).
  let norm = relOrAbs.replace('\\', '/')
  for part in norm.split('/'):
    if part in SkipTreeNames:
      return true
  false

proc treeFingerprint*(root: string): string =
  ## Hash of relative paths + contents under `root`.
  ## Aligns with accepted-tree snapshot (pipeline.copyTree skip set).
  if root.len == 0 or not dirExists(root):
    return ""
  var paths: seq[string] = @[]
  for path in walkDirRec(root):
    let rel = relativePath(path, root).replace('\\', '/')
    if fileExists(path) and not pathSkipped(rel):
      paths.add(path)
  paths.sort()
  var acc = ""
  for p in paths:
    let rel = relativePath(p, root).replace('\\', '/')
    acc.add(rel)
    acc.add('\n')
    acc.add(readFile(p))
    acc.add('\n')
  simpleContentHash(acc)

proc servedTreeManifest*(root: string): JsonNode =
  ## File list + recomputed hash for Studio / oracle comparison.
  result = newJObject()
  result["root"] = %absolutePath(root)
  result["hash"] = %treeFingerprint(root)
  var files = newJArray()
  var n = 0
  if dirExists(root):
    var paths: seq[string] = @[]
    for path in walkDirRec(root):
      let rel = relativePath(path, root).replace('\\', '/')
      if fileExists(path) and not pathSkipped(rel):
        paths.add(rel)
    paths.sort()
    for rel in paths:
      files.add(%rel)
      inc n
  result["files"] = files
  result["file_count"] = %n
