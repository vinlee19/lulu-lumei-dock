#!/bin/bash
# 生成两个可发布资产：版本 ZIP 与内含 archive EdDSA 签名的 appcast.xml。不会创建 GitHub Release。
set -euo pipefail
cd "$(dirname "$0")/.."

readonly PRODUCT_NAME="lulu-lumei-dock"
readonly REPOSITORY="vinlee19/lulu-lumei-dock"
readonly REPOSITORY_VERSION="$(tr -d '[:space:]' < VERSION)"
readonly RELEASE_VERSION="${1:-$REPOSITORY_VERSION}"
readonly RELEASE_TAG="v$RELEASE_VERSION"
readonly ARCHIVE_NAME="${PRODUCT_NAME}-${RELEASE_VERSION}.zip"
readonly ARCHIVE_PATH="dist/$ARCHIVE_NAME"
readonly APPCAST_PATH="dist/appcast.xml"
readonly SPARKLE_TOOLS=".build/artifacts/sparkle/Sparkle/bin"

if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; then
  echo "✗ 发布版本必须是纯数字点分格式，收到：$RELEASE_VERSION" >&2
  exit 1
fi
if [[ "$RELEASE_VERSION" != "$REPOSITORY_VERSION" ]]; then
  echo "✗ tag 版本 $RELEASE_VERSION 与 VERSION 文件 $REPOSITORY_VERSION 不一致" >&2
  exit 1
fi
if [[ -n "${GITHUB_REF_NAME:-}" && "$GITHUB_REF_NAME" != "$RELEASE_TAG" ]]; then
  echo "✗ 工作流 tag $GITHUB_REF_NAME 与 $RELEASE_TAG 不一致" >&2
  exit 1
fi

LULU_APP_VERSION="$RELEASE_VERSION" Scripts/build-app.sh

rm -f "$ARCHIVE_PATH" "$APPCAST_PATH"
ditto -c -k --sequesterRsrc --keepParent "dist/${PRODUCT_NAME}.app" "$ARCHIVE_PATH"

ARCHIVE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lulu-lumei-dock-release.XXXXXX")"
cleanup_release() { rm -rf "$ARCHIVE_DIR"; }
trap cleanup_release EXIT
cp "$ARCHIVE_PATH" "$ARCHIVE_DIR/$ARCHIVE_NAME"

generate_appcast() {
  "$SPARKLE_TOOLS/generate_appcast" \
    --account com.vinlee.eureka \
    --download-url-prefix "https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG/" \
    --link "https://github.com/$REPOSITORY/releases/tag/$RELEASE_TAG" \
    --versions "$RELEASE_VERSION" \
    --maximum-deltas 0 \
    --maximum-versions 1 \
    -o "$ARCHIVE_DIR/appcast.xml" \
    "$ARCHIVE_DIR"
}

if [[ -n "${SPARKLE_EDDSA_PRIVATE_KEY:-}" ]]; then
  # CI 私钥只通过 stdin 交给 Sparkle，绝不落盘或输出。
  printf '%s' "$SPARKLE_EDDSA_PRIVATE_KEY" \
    | "$SPARKLE_TOOLS/generate_appcast" \
        --ed-key-file - \
        --download-url-prefix "https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG/" \
        --link "https://github.com/$REPOSITORY/releases/tag/$RELEASE_TAG" \
        --versions "$RELEASE_VERSION" \
        --maximum-deltas 0 \
        --maximum-versions 1 \
        -o "$ARCHIVE_DIR/appcast.xml" \
        "$ARCHIVE_DIR"
else
  generate_appcast
fi

cp "$ARCHIVE_DIR/appcast.xml" "$APPCAST_PATH"
xmllint --noout "$APPCAST_PATH"

readonly ENCLOSURE_URL="$(xmllint --xpath \
  'string(//*[local-name()="enclosure"]/@url)' "$APPCAST_PATH")"
readonly ENCLOSURE_LENGTH="$(xmllint --xpath \
  'string(//*[local-name()="enclosure"]/@length)' "$APPCAST_PATH")"
readonly ENCLOSURE_SIGNATURE="$(xmllint --xpath \
  'string(//*[local-name()="enclosure"]/@*[local-name()="edSignature"])' "$APPCAST_PATH")"
readonly ACTUAL_LENGTH="$(stat -f '%z' "$ARCHIVE_PATH")"

[[ "$ENCLOSURE_URL" == "https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG/$ARCHIVE_NAME" ]] \
  || { echo "✗ appcast 下载 URL 不正确：$ENCLOSURE_URL" >&2; exit 1; }
[[ "$ENCLOSURE_LENGTH" == "$ACTUAL_LENGTH" ]] \
  || { echo "✗ appcast archive 长度与 ZIP 不一致" >&2; exit 1; }
[[ -n "$ENCLOSURE_SIGNATURE" ]] \
  || { echo "✗ appcast 缺少 EdDSA archive 签名" >&2; exit 1; }

verify_with_key() {
  "$SPARKLE_TOOLS/sign_update" --account com.vinlee.eureka --verify \
    "$ARCHIVE_PATH" "$ENCLOSURE_SIGNATURE"
}

if [[ -n "${SPARKLE_EDDSA_PRIVATE_KEY:-}" ]]; then
  printf '%s' "$SPARKLE_EDDSA_PRIVATE_KEY" \
    | "$SPARKLE_TOOLS/sign_update" --ed-key-file - --verify \
        "$ARCHIVE_PATH" "$ENCLOSURE_SIGNATURE"
else
  verify_with_key
fi

readonly ARCHIVE_SHA256="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
echo "✓ 发布资产已验证："
echo "  $ARCHIVE_PATH"
echo "  SHA-256: $ARCHIVE_SHA256"
echo "  $APPCAST_PATH"

cleanup_release
trap - EXIT
