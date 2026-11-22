## Minimal tasks CLI — default: list tasks.
import std/[os, strutils]
import ./tasks

proc main() =
  let args = commandLineParams()
  let cmd = if args.len > 0: args[0] else: "list"
  case cmd
  of "list", "":
    echo formatList(loadTasks())
  else:
    stderr.writeLine("unknown command: " & cmd)
    stderr.writeLine("usage: demo_tasks [list]")
    quit(2)

when isMainModule:
  main()
