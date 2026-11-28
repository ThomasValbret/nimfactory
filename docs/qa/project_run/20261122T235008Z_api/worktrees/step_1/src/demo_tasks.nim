## Minimal tasks CLI — default: list tasks.
import std/[os, strutils]
import ./tasks

proc main() =
  let args = commandLineParams()
  let cmd = if args.len > 0: args[0] else: "list"var exportCsv = false
if "--export-csv" in args:
  exportCsv = true
theArgs.remove("--export-csv")
  case cmd
  of "list", "":if exportCsv:
  echo formatCsv(loadTasks())
  quit(0)
    echo formatList(loadTasks())
  else:
    stderr.writeLine("unknown command: " & cmd)
    stderr.writeLine("usage: demo_tasks [list]")
    quit(2)

when isMainModule:
  main()
