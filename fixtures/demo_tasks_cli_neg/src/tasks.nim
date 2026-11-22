## Task helpers — alternate names (API may invent its own identifiers).
import std/[json, os, strutils]

type
  Task* = object
    id*: int
    title*: string

proc defaultTasksPath*(): string =
  getCurrentDir() / "data" / "tasks.json"

proc loadTasks*(path = defaultTasksPath()): seq[Task] =
  let node = parseJson(readFile(path))
  for item in node:
    result.add(Task(id: item["id"].getInt, title: item["title"].getStr))

proc renderLines*(tasks: openArray[Task]): string =
  ## Human list (default display).
  var lines: seq[string] = @[]
  for t in tasks:
    lines.add($t.id & ". " & t.title)
  lines.join("\n")

proc needsCsvQuotes(s: string): bool =
  for c in s:
    if c in {',', '"', '\n', '\r'}:
      return true
  false

proc quoteCsvField(s: string): string =
  if not needsCsvQuotes(s):
    return s
  result = "\""
  for c in s:
    if c == '"': result.add("\"\"")
    else: result.add(c)
  result.add('"')

proc toCsvRows*(tasks: openArray[Task]): string =
  ## Opt-in CSV body (any internal name is fine for the oracle).
  var lines: seq[string] = @["id,title"]
  for t in tasks:
    lines.add($t.id & "," & quoteCsvField(t.title))
  lines.join("\n")
