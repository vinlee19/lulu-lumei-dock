#!/bin/bash
# 灵动岛演示：用临时 spool 注入各场景事件，肉眼走查视觉与交互。
# 用法: Scripts/demo-island.sh
set -e
cd "$(dirname "$0")/.."

swift build
BIN=.build/debug
export EUREKA_SPOOL_DIR=$(mktemp -d)
LOG=/tmp/eureka-demo.log

"$BIN/eureka" > "$LOG" 2>&1 &
APP=$!
trap 'kill $APP 2>/dev/null || true; rm -rf "$EUREKA_SPOOL_DIR"' EXIT
sleep 2

step() { echo ""; echo "▶ $1"; }

step "单任务开始 → 顶部出现 compact 胶囊（呼吸点 + 计时）"
"$BIN/eureka-relay" inject --event user-prompt-submit --session demo1 --title "重构用户认证模块" --cwd /Users/me/work/auth-service
sleep 5

step "并发 +2 个任务 → 计数变 3"
"$BIN/eureka-relay" inject --event user-prompt-submit --session demo2 --title "修复 CI 失败用例" --cwd /Users/me/work/ci
"$BIN/eureka-relay" inject --event user-prompt-submit --session demo3 --title "写数据管道周报" --cwd /Users/me/work/report
sleep 4

step "demo2 完成 → 展开绿色完成卡，6 秒后自动收回 compact"
"$BIN/eureka-relay" inject --event stop --session demo2
sleep 9

step "demo3 请求权限 → 橙色等待卡常驻（不自动收）"
"$BIN/eureka-relay" inject --event notification-permission --session demo3
sleep 5

step "demo3 获批继续跑（心跳）→ 等待卡撤掉，回 compact"
"$BIN/eureka-relay" inject --event post-tool-use --session demo3
sleep 4

step "demo1、demo3 相继完成 → 两张完成卡排队逐显"
"$BIN/eureka-relay" inject --event stop --session demo1
"$BIN/eureka-relay" inject --event stop --session demo3
sleep 16

step "无任务 → 灵动岛完全隐藏"
sleep 3

echo ""
echo "demo 结束。island 状态序列："
grep "island=" "$LOG" | sed 's/\[eureka\] /  /'
