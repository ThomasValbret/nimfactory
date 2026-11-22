## Task list helpers.
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

proc formatList*(tasks: openArray[Task]): string =
  var lines: seq[string] = @[]
  for t in tasks:
    lines.add($t.id & ". " & t.title)
  lines.join("\n")

proc csvFieldNeedsQuote*(s: string): bool =
  for c in s:
    if c in {',', '"', '\n', '\r'}:
      return true
  false

proc csvQuote*(s: string): string =
  if not csvFieldNeedsQuote(s):
    return s
  result = "\""
  for c in s:
    if c == '"': result.add("\"\"")
    else: result.add(c)
  result.add('"')

proc formatCsv*(tasks: openArray[Task]): string =
  var lines: seq[string] = @["id,title"]
  for t in tasks:
    lines.add($t.id & "," & csvQuote(t.title))
  lines.join("\n")
