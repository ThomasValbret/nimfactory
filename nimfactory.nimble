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

task test, "Run global Wave A (+A.1) suite":
  exec "bash scripts/test_wave_a.sh"

task testf0, "Run F0 contract tests":
  exec "nim c -r --path:src --path:vendor/NimAgentLibrary/src tests/f0/test_contracts.nim"
  exec "nim c -r --path:src --path:vendor/NimAgentLibrary/src tests/f0/test_message_roundtrip.nim"
  exec "nim c -r --path:src --path:vendor/NimAgentLibrary/src tests/f0/test_fixture_consumers.nim"
  exec "nim c -r --path:src --path:vendor/NimAgentLibrary/src tests/f0/test_validation_strict.nim"

task testwavea, "Alias of test (Wave A + A.1)":
  testTask()

task studio, "Build the local Studio server with its embedded Nim browser client":
  exec "nim e scripts/build_studio.nims"
