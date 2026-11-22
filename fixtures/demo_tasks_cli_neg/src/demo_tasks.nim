## Tasks CLI with alternate helper names — behaviour matches csv_journey recipe.
import std/[os, strutils]
import ./tasks

proc main() =
  let args = commandLineParams()
  let cmd = if args.len > 0: args[0] else: "list"
  case cmd
  of "list", "":
    echo renderLines(loadTasks())
  of "export-csv":
    echo toCsvRows(loadTasks())
  else:
    stderr.writeLine("unknown command: " & cmd)
    stderr.writeLine("usage: demo_tasks [list|export-csv]")
    quit(2)

when isMainModule:
  main()
