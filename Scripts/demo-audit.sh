#!/bin/bash
# 安全审计演示：注入高危命令，验证灵动岛弹出红色告警卡（island=card-alert）。
# 用临时 spool / DB / codex 目录，完全隔离，不碰真实数据。
# 用法: Scripts/demo-audit.sh
set -e
cd "$(dirname "$0")/.."

swift build
BIN=.build/debug
export EUREKA_SPOOL_DIR=$(mktemp -d)
export EUREKA_DB_PATH=$(mktemp -d)/audit-demo.sqlite
export EUREKA_CODEX_SESSIONS=$(mktemp -d)   # 空目录，避免扫真实 Codex 数据
LOG=/tmp/eureka-audit-demo.log

"$BIN/eureka" > "$LOG" 2>&1 &
APP=$!
trap 'kill $APP 2>/dev/null || true; rm -rf "$EUREKA_SPOOL_DIR" "$EUREKA_CODEX_SESSIONS"' EXIT
sleep 2

step() { echo ""; echo "▶ $1"; }

step "普通命令（ls）→ 只记审计流水，不告警"
"$BIN/eureka-relay" inject --event post-tool-use --tool Bash --title "ls -la" --session auditdemo
sleep 2

step "高危命令（sudo rm -rf 绝对路径）→ 灵动岛红色告警卡"
"$BIN/eureka-relay" inject --event post-tool-use --tool Bash \
    --title "sudo rm -rf /tmp/demo-target" --session auditdemo
sleep 5

echo ""
echo "demo 结束。island 状态序列："
grep -E "island=|审计告警" "$LOG" | sed 's/\[eureka\] /  /'

echo ""
if grep -q "island=card-alert" "$LOG"; then
    echo "✓ 高危告警红卡已弹出"
else
    echo "✗ 未观察到 card-alert"
    exit 1
fi
