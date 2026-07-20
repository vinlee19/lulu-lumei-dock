#!/bin/bash
# 将本机钥匙串中的 Sparkle 私钥安全写入 GitHub Actions Secret；私钥只短暂落在 0600 临时文件。
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077

readonly REPOSITORY="vinlee19/lulu-lumei-dock"
readonly KEY_ACCOUNT="com.vinlee.eureka"
readonly SECRET_NAME="SPARKLE_EDDSA_PRIVATE_KEY"
readonly GENERATE_KEYS=".build/artifacts/sparkle/Sparkle/bin/generate_keys"

[[ -x "$GENERATE_KEYS" ]] || {
  echo "✗ Sparkle 工具未就位，请先运行 swift package resolve" >&2
  exit 1
}
command -v gh >/dev/null || { echo "✗ 未安装 GitHub CLI (gh)" >&2; exit 1; }
echo "· 检查 GitHub 登录状态"
gh auth status >/dev/null || { echo "✗ GitHub CLI 未登录" >&2; exit 1; }

PRIVATE_KEY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lulu-sparkle-key.XXXXXX")"
readonly PRIVATE_KEY_FILE="$PRIVATE_KEY_DIR/private-key.txt"
cleanup_key() { rm -rf "$PRIVATE_KEY_DIR"; }
trap cleanup_key EXIT

echo "· 从登录钥匙串导出到受限临时文件"
"$GENERATE_KEYS" --account "$KEY_ACCOUNT" -x "$PRIVATE_KEY_FILE" >/dev/null \
  || { echo "✗ 无法从钥匙串导出 Sparkle 私钥" >&2; exit 1; }
echo "· 写入 GitHub Actions Secret"
gh secret set "$SECRET_NAME" --repo "$REPOSITORY" < "$PRIVATE_KEY_FILE" \
  || { echo "✗ 无法写入 GitHub Actions Secret" >&2; exit 1; }

cleanup_key
trap - EXIT
echo "✓ 已配置 GitHub Actions Secret：$SECRET_NAME"
