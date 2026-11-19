## NimFactory CLI entrypoint (F16).
import std/os
import nimfactory/cli

when isMainModule:
  quit(runCli(commandLineParams()))
