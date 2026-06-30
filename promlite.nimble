version       = "0.1.0"
author        = "Andrii Zahriadskyi"
description   = "Snapshot-oriented library for small long-running Prometheus exporters"
license       = "MIT"
gitUrl        = "https://github.com/zystem/nim-promlite.git"
url           = "https://github.com/zystem/nim-promlite"
srcDir        = "src"
skipDirs      = @["tests", "examples"]

requires "nim >= 2.0.0"

task test, "Run tests":
  exec "nim c -r --threads:on --path:src --nimcache:build/nimcache tests/t_basic.nim"
