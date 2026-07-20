#!/bin/bash
# 打包 dist/lulu-lumei-dock.app（无 Xcode 路线：SwiftPM release + 手工组装 + ad-hoc 签名）
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BUILD=.build/release
APP=dist/lulu-lumei-dock.app
VERSION=$(git describe --tags --always 2>/dev/null || echo "0.1.0")

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD/eureka" "$APP/Contents/MacOS/eureka"
cp "$BUILD/eureka-relay" "$APP/Contents/MacOS/eureka-relay"

# 资源 bundle 放在 macOS 应用包的标准 Resources/ 目录，运行时由
# AppResources 解析；直接放在 .app 根目录会被 codesign --strict 拒绝。
# （只拷 app 自己的 bundle，测试 fixtures 不进发布包）
APP_BUNDLE="$BUILD/eureka_eureka.bundle"
[ -d "$APP_BUNDLE" ] || { echo "✗ 未找到 $APP_BUNDLE"; exit 1; }
PACKAGED_BUNDLE="$APP/Contents/Resources/eureka_eureka.bundle"
cp -R "$APP_BUNDLE" "$PACKAGED_BUNDLE"

# 在签名前验证发布包的关键资源，避免再发布一个启动即崩溃的 app。
[ -f "$PACKAGED_BUNDLE/pricing.json" ] || { echo "✗ 资源包缺少 pricing.json"; exit 1; }
[ -f "$PACKAGED_BUNDLE/mascots/lulu/idle-1.png" ] || { echo "✗ 资源包缺少内置吉祥物素材"; exit 1; }

# 应用图标（Scripts/make-icns.sh 生成并提交在仓库里）
if [ -f Sources/EurekaApp/Resources/AppIcon.icns ]; then
  cp Sources/EurekaApp/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

sed -e "s/__VERSION__/$VERSION/g" Scripts/Info.plist.template > "$APP/Contents/Info.plist"

# 由内向外 ad-hoc 签名（本机自用，无需公证）
codesign --force --sign - --identifier com.vinlee.eureka.relay "$APP/Contents/MacOS/eureka-relay"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

# 暂时隐藏构建目录里的资源 bundle，确保冒烟测试只能读打包后的路径，
# 不会被 SwiftPM 生成的构建机绝对路径回退掩盖问题。
SMOKE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lulu-lumei-dock-smoke.XXXXXX")
HIDDEN_BUILD_BUNDLE="${APP_BUNDLE}.package-smoke.$$"
cleanup_smoke() {
  if [ -d "$HIDDEN_BUILD_BUNDLE" ] && [ ! -e "$APP_BUNDLE" ]; then
    mv "$HIDDEN_BUILD_BUNDLE" "$APP_BUNDLE"
  fi
  rm -rf "$SMOKE_DIR"
}
trap cleanup_smoke EXIT
mv "$APP_BUNDLE" "$HIDDEN_BUILD_BUNDLE"
"$APP/Contents/MacOS/eureka" --render-mascot "$SMOKE_DIR"
[ -f "$SMOKE_DIR/mascot-idle.png" ] || { echo "✗ 打包资源运行时验证失败"; exit 1; }
cleanup_smoke
trap - EXIT

echo "✓ 打包完成: ${APP} (版本 ${VERSION})"
