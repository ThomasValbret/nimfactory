# Package
version       = "0.1.0"
author        = "nimfactory maintainers"
description   = "Local software factory engine: contracts, artifacts, graphs, preparation, budgets"
license       = "Apache-2.0"
srcDir        = "src"
binDir        = "build"
installExt    = @["nim"]
skipDirs      = @["tests", "docs", "examples", "recipes", "build"]

# Dependencies
requires "nim >= 2.4.0"
requires "nimagent >= 0.2.0"

# Local path pin: NimAgentLibrary @ bf22665ece77d7149dbe61df959a6024bf6b26f3
# Install with: nimble install -y --passNim:--path:/opt/NimAgentLibrary
# Or set NIMBLE_DIR / path override in nimble.paths

task setup, "Install local nimagent path dependency":
  exec "nimble install -y --verbose /opt/NimAgentLibrary"

task test, "Run F0 contract tests":
  exec "nim c -r --path:src --path:/opt/NimAgentLibrary/src tests/f0/test_contracts.nim"
  exec "nim c -r --path:src --path:/opt/NimAgentLibrary/src tests/f0/test_message_roundtrip.nim"
  exec "nim c -r --path:src --path:/opt/NimAgentLibrary/src tests/f0/test_fixture_consumers.nim"

task testf1, "Run F1 artifact tests":
  exec "nim c -r --path:src --path:/opt/NimAgentLibrary/src tests/f1/test_artifacts.nim"

task testf3, "Run F3 journal tests":
  exec "nim c -r --path:src --path:/opt/NimAgentLibrary/src tests/f3/test_journal.nim"

task testf4, "Run F4 graph tests":
  exec "nim c -r --path:src --path:/opt/NimAgentLibrary/src tests/f4/test_graph.nim"

task testf14, "Run F14 budget tests":
  exec "nim c -r --path:src --path:/opt/NimAgentLibrary/src tests/f14/test_budget.nim"

task testf17, "Run F17 qualification smoke":
  exec "nim c -r --path:src --path:/opt/NimAgentLibrary/src tests/f17/test_qualification_smoke.nim"

task testwavea, "Run wave A tests":
  testf1Task()
  testf3Task()
  testf4Task()
  testf14Task()
  testf17Task()
