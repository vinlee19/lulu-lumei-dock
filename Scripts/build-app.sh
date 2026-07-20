#!/bin/bash
# 打包 dist/lulu-lumei-dock.app（SwiftPM release + 手工组装 + 由内向外签名）
set -euo pipefail
cd "$(dirname "$0")/.."

readonly PRODUCT_NAME="lulu-lumei-dock"
readonly APP_PATH="dist/${PRODUCT_NAME}.app"
readonly REPOSITORY_VERSION="$(tr -d '[:space:]' < VERSION)"
readonly APP_VERSION="${LULU_APP_VERSION:-$REPOSITORY_VERSION}"
readonly SIGNING_IDENTITY="${LULU_CODE_SIGN_IDENTITY:--}"

if [[ ! "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; then
  echo "✗ 版本号必须是纯数字点分格式（如 0.1.5），收到：$APP_VERSION" >&2
  exit 1
fi

if [[ "${LULU_SKIP_BUILD:-0}" != "1" ]]; then
  swift build -c release
fi

BUILD_PATH="$(swift build -c release --show-bin-path)"
readonly BUILD_PATH
readonly APP_BUNDLE="$BUILD_PATH/eureka_eureka.bundle"
readonly SPARKLE_SOURCE=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
readonly SPARKLE_PATH="$APP_PATH/Contents/Frameworks/Sparkle.framework"

[[ -x "$BUILD_PATH/eureka" ]] || { echo "✗ 未找到 release eureka" >&2; exit 1; }
[[ -x "$BUILD_PATH/eureka-relay" ]] || { echo "✗ 未找到 release eureka-relay" >&2; exit 1; }
[[ -d "$APP_BUNDLE" ]] || { echo "✗ 未找到 $APP_BUNDLE" >&2; exit 1; }
[[ -d "$SPARKLE_SOURCE" ]] || { echo "✗ 未找到 Sparkle 2.9.2 framework" >&2; exit 1; }
lipo "$BUILD_PATH/eureka" -verify_arch arm64 >/dev/null \
  || { echo "✗ release eureka 不含 arm64 架构" >&2; exit 1; }
lipo "$BUILD_PATH/eureka-relay" -verify_arch arm64 >/dev/null \
  || { echo "✗ release eureka-relay 不含 arm64 架构" >&2; exit 1; }

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" \
  "$APP_PATH/Contents/Frameworks"

cp "$BUILD_PATH/eureka" "$APP_PATH/Contents/MacOS/eureka"
cp "$BUILD_PATH/eureka-relay" "$APP_PATH/Contents/MacOS/eureka-relay"

# 资源 bundle 放在标准 Resources/ 目录；只拷应用自己的 bundle。
readonly PACKAGED_BUNDLE="$APP_PATH/Contents/Resources/eureka_eureka.bundle"
ditto "$APP_BUNDLE" "$PACKAGED_BUNDLE"
[[ -f "$PACKAGED_BUNDLE/pricing.json" ]] || { echo "✗ 资源包缺少 pricing.json" >&2; exit 1; }
[[ -f "$PACKAGED_BUNDLE/mascots/lulu/idle-1.png" ]] || { echo "✗ 资源包缺少内置吉祥物素材" >&2; exit 1; }

if [[ -f Sources/EurekaApp/Resources/AppIcon.icns ]]; then
  cp Sources/EurekaApp/Resources/AppIcon.icns "$APP_PATH/Contents/Resources/AppIcon.icns"
fi

# ditto 会保留 Sparkle.framework 的 Versions/Current 等必要符号链接。
ditto "$SPARKLE_SOURCE" "$SPARKLE_PATH"
[[ -L "$SPARKLE_PATH/Versions/Current" ]] || { echo "✗ Sparkle Versions/Current 符号链接丢失" >&2; exit 1; }
[[ -L "$SPARKLE_PATH/Sparkle" ]] || { echo "✗ Sparkle 顶层可执行文件符号链接丢失" >&2; exit 1; }
[[ -x "$SPARKLE_PATH/Versions/B/Autoupdate" ]] || { echo "✗ Sparkle 缺少 Autoupdate" >&2; exit 1; }
[[ -d "$SPARKLE_PATH/Versions/B/Updater.app" ]] || { echo "✗ Sparkle 缺少 Updater.app" >&2; exit 1; }
[[ -d "$SPARKLE_PATH/Versions/B/XPCServices/Installer.xpc" ]] || { echo "✗ Sparkle 缺少 Installer.xpc" >&2; exit 1; }
[[ -d "$SPARKLE_PATH/Versions/B/XPCServices/Downloader.xpc" ]] || { echo "✗ Sparkle 缺少 Downloader.xpc" >&2; exit 1; }

sed -e "s/__VERSION__/$APP_VERSION/g" Scripts/Info.plist.template \
  > "$APP_PATH/Contents/Info.plist"
plutil -lint "$APP_PATH/Contents/Info.plist" >/dev/null

# 主程序必须通过 @rpath 链接 Sparkle，并包含应用包内 Frameworks 的 rpath。
otool -L "$APP_PATH/Contents/MacOS/eureka" \
  | grep -Fq '@rpath/Sparkle.framework/Versions/B/Sparkle' \
  || { echo "✗ eureka 未通过 @rpath 链接 Sparkle" >&2; exit 1; }
otool -l "$APP_PATH/Contents/MacOS/eureka" \
  | grep -Fq '@executable_path/../Frameworks' \
  || { echo "✗ eureka 缺少 Contents/Frameworks rpath" >&2; exit 1; }

# Sparkle 官方手工签名顺序。禁止使用 codesign --deep 签名；--deep 只用于最终验证。
codesign --force --sign "$SIGNING_IDENTITY" \
  "$SPARKLE_PATH/Versions/B/XPCServices/Installer.xpc"
codesign --force --sign "$SIGNING_IDENTITY" --preserve-metadata=entitlements \
  "$SPARKLE_PATH/Versions/B/XPCServices/Downloader.xpc"
codesign --force --sign "$SIGNING_IDENTITY" \
  "$SPARKLE_PATH/Versions/B/Autoupdate"
codesign --force --sign "$SIGNING_IDENTITY" \
  "$SPARKLE_PATH/Versions/B/Updater.app"
codesign --force --sign "$SIGNING_IDENTITY" "$SPARKLE_PATH"
codesign --force --sign "$SIGNING_IDENTITY" --identifier com.vinlee.eureka.relay \
  "$APP_PATH/Contents/MacOS/eureka-relay"
codesign --force --sign "$SIGNING_IDENTITY" "$APP_PATH"

codesign --verify --strict "$SPARKLE_PATH/Versions/B/XPCServices/Installer.xpc"
codesign --verify --strict "$SPARKLE_PATH/Versions/B/XPCServices/Downloader.xpc"
codesign --verify --strict "$SPARKLE_PATH/Versions/B/Updater.app"
codesign --verify --strict "$SPARKLE_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# 暂时隐藏构建目录资源，确保冒烟运行只能读取打包后的 bundle；这也会验证 dyld 能加载内嵌 Sparkle。
SMOKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lulu-lumei-dock-smoke.XXXXXX")"
HIDDEN_BUILD_BUNDLE="${APP_BUNDLE}.package-smoke.$$"
cleanup_smoke() {
  if [[ -d "$HIDDEN_BUILD_BUNDLE" && ! -e "$APP_BUNDLE" ]]; then
    mv "$HIDDEN_BUILD_BUNDLE" "$APP_BUNDLE"
  fi
  rm -rf "$SMOKE_DIR"
}
trap cleanup_smoke EXIT
mv "$APP_BUNDLE" "$HIDDEN_BUILD_BUNDLE"
"$APP_PATH/Contents/MacOS/eureka" --render-mascot "$SMOKE_DIR"
[[ -f "$SMOKE_DIR/mascot-idle.png" ]] || { echo "✗ 打包后启动冒烟验证失败" >&2; exit 1; }
cleanup_smoke
trap - EXIT

echo "✓ 打包完成: ${APP_PATH}（版本 ${APP_VERSION}）"
