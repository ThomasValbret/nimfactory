## Resolve only a recorded, accepted target under the operator-selected trees directory.
import std/[os, strutils, json, unicode]
from nimfactory/mission/apply import simpleHash

proc readAcceptedSource*(treesRoot: string; step: JsonNode): JsonNode =
  if treesRoot.len == 0 or step{"accepted_tree_hash"}.getStr.len == 0:
    return nil
  let id = step{"id"}.getStr
  let target = step{"change","target_file"}.getStr
  let expected = step{"change","after_hash"}.getStr
  if id.len == 0 or id in [".", ".."] or id.find({'/', '\\', ':', '\0'}) >= 0 or
      expected.len == 0 or target.isAbsolute or target.find({'\\', ':', '\0'}) >= 0:
    return nil
  for component in target.split('/'):
    if component in ["", ".", ".."]: return nil
  let path = treesRoot / id / target
  const limit = 1024 * 1024
  try:
    if not fileExists(path) or expandFilename(path) != path or getFileSize(path) > limit:
      return nil
    let handle = open(path, fmRead)
    defer: handle.close()
    var body = newString(limit + 1)
    let size = handle.readBuffer(addr body[0], body.len)
    if size > limit: return nil
    body.setLen(size)
    if '\0' in body or validateUtf8(body) >= 0 or simpleHash(body) != expected:
      return nil
    return %*{"file":target, "text":body}
  except IOError, OSError:
    return nil
