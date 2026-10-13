#!/bin/bash
# CLT 工具链把 libTestingMacros.dylib 放在编译器默认不扫描的 plugins/testing/ 子目录,
# 裸 `swift test` 会报 "plugin for module 'TestingMacros' not found"。
# 所有测试一律通过本脚本运行;参数原样透传(如 --filter XxxTests)。
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift test \
  -Xswiftc -load-plugin-library \
  -Xswiftc '/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib' \
  "$@"
