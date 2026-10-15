#!/bin/bash
# 组装 build/Raccoon.app:swift build → 拷贝二进制/资源 bundle → adhoc 签名
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"

swift build -c "$CONFIG"

APP="build/Raccoon.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Raccoon" "$APP/Contents/MacOS/Raccoon"
cp "Scripts/Info.plist" "$APP/Contents/Info.plist"

# SwiftPM 资源 bundle(rules.json、本地化)需与可执行文件同目录
# -L 必须:.build/$CONFIG 是符号链接(→ arm64-apple-macosx/$CONFIG),find 默认不跟随,会拷 0 个 bundle
find -L ".build/$CONFIG" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/MacOS/" \;
# 本机实测:resource_bundle_accessor 的首个候选是 Bundle.main.resourceURL = Contents/Resources,
# .app 内启动若 Resources/ 无 bundle 会 fatalError("unable to find bundle named …"),故两处都拷
find -L ".build/$CONFIG" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;

# 占位图标(若已生成;缺失不碍组装)
if [ -f "build/AppIcon.png" ]; then cp "build/AppIcon.png" "$APP/Contents/Resources/AppIcon.png"; fi

# 本机新版 codesign 不再自动深签未签名的嵌套 bundle,须先内后外逐层 adhoc 签名
find "$APP" -name "*.bundle" -exec codesign --force --sign - {} \;
codesign --force --sign - "$APP"
echo "✅ $APP"
