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
proc csvQuote(title: string): string =
  result = """" & title.replace("""", """"""""""""""""""""""""""""""""""" & """""

proc formatCsv(tasks: openArray[Task]): string =
  var lines: seq[string] = @[]
  lines.add("id,title")
  for t in tasks:
    lines.add($t.id & "," & csvQuote(t.title))
  lines.join("\n")

proc formatList*(tasks: openArray[Task]): string =
  var lines: seq[string] = @[]
  for t in tasks:
    lines.add($t.id & ". " & t.title)
  lines.join("\n")
