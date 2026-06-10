#!/bin/bash
# 从 SwiftUI 渲染的 1024px 母版生成 AppIcon.icns（提交到仓库，打包时拷入 bundle）
set -euo pipefail
cd "$(dirname "$0")/.."

swift build > /dev/null
MASTER=/tmp/eureka-icon-1024.png
.build/debug/eureka --render-icon "$MASTER"

ICONSET=/tmp/Eureka.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
  sips -z $size $size "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" > /dev/null
  double=$((size * 2))
  sips -z $double $double "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" > /dev/null
done

OUT=Sources/EurekaApp/Resources/AppIcon.icns
iconutil -c icns "$ICONSET" -o "$OUT"
echo "✓ 已生成 $OUT"
