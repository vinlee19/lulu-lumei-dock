#!/bin/bash
# 打包 dist/Eureka.app（无 Xcode 路线：SwiftPM release + 手工组装 + ad-hoc 签名）
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BUILD=.build/release
APP=dist/Eureka.app
VERSION=$(git describe --tags --always 2>/dev/null || echo "0.1.0")

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD/eureka" "$APP/Contents/MacOS/eureka"
cp "$BUILD/eureka-relay" "$APP/Contents/MacOS/eureka-relay"

# SwiftPM resource bundle 必须拷进 Resources/，否则 Bundle.module 运行时找不到 pricing.json
# （只拷 app 自己的 bundle，测试 fixtures 不进发布包）
APP_BUNDLE="$BUILD/eureka_eureka.bundle"
[ -d "$APP_BUNDLE" ] || { echo "✗ 未找到 $APP_BUNDLE"; exit 1; }
cp -R "$APP_BUNDLE" "$APP/Contents/Resources/"

sed -e "s/__VERSION__/$VERSION/g" Scripts/Info.plist.template > "$APP/Contents/Info.plist"

# 由内向外 ad-hoc 签名（本机自用，无需公证）
codesign --force --sign - --identifier com.vinlee.eureka.relay "$APP/Contents/MacOS/eureka-relay"
codesign --force --sign - "$APP"
codesign --verify "$APP"

echo "✓ 打包完成: ${APP} (版本 ${VERSION})"
