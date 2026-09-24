#!/usr/bin/env bash
# 刷新随包价格目录快照 Sources/EurekaApp/Resources/pricing-catalog.json。
# 发版前运行（make pricing-catalog）：保证用户首次启动且离线时也有发版当天的价格。
# 解析 / 校验与 app 运行时同一套代码（eureka --build-pricing-catalog）。
set -euo pipefail

cd "$(dirname "$0")/.."
readonly OUT="Sources/EurekaApp/Resources/pricing-catalog.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() {
  local out="$1"; shift
  for url in "$@"; do
    if curl -fsSL --max-time 60 -o "$out" "$url"; then
      echo "已下载 $url" >&2
      return 0
    fi
    echo "下载失败 $url，换下一个镜像" >&2
  done
  return 1
}

fetch "$TMP/litellm.json" \
  "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json" \
  "https://cdn.jsdelivr.net/gh/BerriAI/litellm@main/model_prices_and_context_window.json"
fetch "$TMP/models-dev.json" "https://models.dev/api.json"

swift build >&2
.build/debug/eureka --build-pricing-catalog "$TMP/litellm.json" "$TMP/models-dev.json" "$OUT"
