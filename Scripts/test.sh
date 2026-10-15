#!/bin/bash
# 测试唯一入口。CLT 工具链把 libTestingMacros.dylib 放在编译器默认不扫描的
# plugins/testing/ 子目录,裸 `swift test` 会报 "plugin for module 'TestingMacros' not found";
# 完整 Xcode 工具链无此问题,且该路径根本不存在,加了反而报错——故按活动工具链判定,
# 本地(CLT)与 CI(macOS runner,完整 Xcode)共用同一入口。
# 参数原样透传(如 --filter XxxTests)。
set -euo pipefail
cd "$(dirname "$0")/.."

CLT_PLUGIN_LIB='/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
if [[ "$(xcode-select -p 2>/dev/null)" == "/Library/Developer/CommandLineTools" && -f "$CLT_PLUGIN_LIB" ]]; then
  exec swift test -Xswiftc -load-plugin-library -Xswiftc "$CLT_PLUGIN_LIB" "$@"
fi
exec swift test "$@"
